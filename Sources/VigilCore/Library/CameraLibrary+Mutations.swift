//
//  CameraLibrary+Mutations.swift
//  VigilCore
//
//  Everything that changes the library: membership, fields, the channel inventory, order, and the
//  persistence underneath them.
//  Split from CameraLibrary.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

#if os(macOS)

import Foundation
import VigilISAPI
import VigilProtocols

// MARK: - Mutations and persistence

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension CameraLibrary {

    // MARK: Mutations — membership

    /// Adds a camera, at the end of the list or at an explicit position.
    ///
    /// The record is validated and repaired first (`Camera.validated()`), so a name typed as spaces
    /// becomes `Camera <host>` rather than an unnamed row. When another camera on the same device
    /// address has already learned an RTSP path template, the new record **inherits** it: the
    /// template is a property of the firmware, not of the channel, and R1.2 requires the ladder to
    /// run once per device ever — adding channel 7 of a probed NVR must probe nothing.
    ///
    /// - Parameters:
    ///   - camera: the record. Its `id` must not already be in the library.
    ///   - index: display position. `nil` appends; out-of-range values are clamped.
    /// - Returns: the record as stored, after validation and inheritance.
    /// - Throws: ``LibraryMutationError``.
    @discardableResult
    public func add(_ camera: Camera, at index: Int? = nil) throws(LibraryMutationError) -> Camera {
        try requireWritable()
        guard document.camera(camera.id) == nil else {
            throw LibraryMutationError.duplicateCameraID(camera.id)
        }
        var prepared = try validate(camera)

        if prepared.capabilities?.rtspPathTemplate == nil,
           let inherited = document.learnedPathTemplate(host: prepared.host,
                                                        rtspPort: prepared.rtspPort) {
            var capabilities = prepared.capabilities ?? DeviceCapabilities()
            capabilities.rtspPathTemplate = inherited
            prepared.capabilities = capabilities
            logger.debug(.storage, "new camera inherited a learned RTSP path template",
                         ["template": inherited.rawValue,
                          "host": Redact.host(prepared.host, salt: 0)])
        }

        let position = min(max(index ?? document.cameras.count, 0), document.cameras.count)
        document.cameras.insert(prepared, at: position)
        commit(.added(prepared.id))
        return prepared
    }

    /// Removes a camera and its channel inventory.
    ///
    /// Its Keychain credential, its recordings and its bookmarks are **not** touched. Deleting a
    /// camera must never delete the user's media (docs/spec-core.md §5.7 invariant 10), and the
    /// credential belongs to `CredentialStore` — the returned record carries the `credentialRef` so
    /// a caller that does want it gone can ask for that explicitly.
    ///
    /// - Returns: the removed record, for undo and for credential cleanup.
    @discardableResult
    public func remove(_ id: CameraID) throws(LibraryMutationError) -> Camera {
        try requireWritable()
        guard let index = document.index(of: id) else {
            throw LibraryMutationError.unknownCamera(id)
        }
        let removed = document.cameras.remove(at: index)
        document.channelInventories.removeAll { $0.cameraID == id }
        commit(.removed(id))
        return removed
    }

    /// Copies a camera immediately after the original, ready to be edited as another channel.
    ///
    /// Connection settings and the Keychain reference deliberately carry over: duplication is the
    /// shortcut for adding another channel of the same recorder. Runtime identity does not. The
    /// copy receives a fresh identifier and creation date, has never been seen, and does not inherit
    /// the original camera's channel inventory. A unique display name keeps the two sidebar rows
    /// distinguishable while still allowing the user to rename either one later.
    ///
    /// - Parameters:
    ///   - id: the camera to copy.
    ///   - newID: identity for the copy. Exposed for deterministic importers and tests.
    /// - Returns: the copied record as stored.
    @discardableResult
    public func duplicate(_ id: CameraID,
                          as newID: CameraID = CameraID()) throws(LibraryMutationError) -> Camera {
        try requireWritable()
        guard let index = document.index(of: id) else {
            throw LibraryMutationError.unknownCamera(id)
        }
        guard document.camera(newID) == nil else {
            throw LibraryMutationError.duplicateCameraID(newID)
        }

        var copy = document.cameras[index]
        copy.id = newID
        copy.name = Self.copyName(for: copy.name, among: document.cameras.map(\.name))
        copy.createdAt = wallClock.now
        copy.lastSeenAt = nil
        let prepared = try validate(copy)
        document.cameras.insert(prepared, at: index + 1)
        commit(.added(prepared.id))
        return prepared
    }

    /// Finder-style suffixing without treating duplicate camera names as invalid generally.
    static func copyName(for original: String, among names: [String]) -> String {
        let occupied = Set(names)
        for suffix in 2...Int.max {
            let marker = " (\(suffix))"
            let prefix = original.prefix(max(0, 64 - marker.count))
            let candidate = "\(prefix)\(marker)"
            if !occupied.contains(candidate) { return candidate }
        }
        return original
    }

    // MARK: Mutations — fields

    /// Renames a camera.
    ///
    /// The name is trimmed, stripped of newlines and capped at 64 characters; an empty result becomes
    /// `Camera <host>`, because a nameless row in the sidebar is worse than a generated name.
    @discardableResult
    public func rename(_ id: CameraID, to name: String) throws(LibraryMutationError) -> Camera {
        try modify(id) { camera in camera.name = name }
    }

    /// Enables or disables auto-connect for a camera. The record stays in the library either way.
    @discardableResult
    public func setEnabled(_ isEnabled: Bool,
                           for id: CameraID) throws(LibraryMutationError) -> Camera {
        try modify(id) { camera in camera.isEnabled = isEnabled }
    }

    /// Assigns an explicit identity colour, or restores UUID-derived automatic assignment.
    @discardableResult
    public func setColorTag(_ colorTag: ColorTag,
                            for id: CameraID) throws(LibraryMutationError) -> Camera {
        try modify(id) { camera in camera.colorTag = colorTag }
    }

    /// Applies an arbitrary edit to one camera, then validates, normalises, persists and broadcasts.
    ///
    /// The general entry point, so a caller needing a field this type has no named method for does
    /// not have to reach around the actor. Two fields are restored after the body runs: `id` and
    /// `credentialRef`. Changing either would silently orphan the record's identity or its Keychain
    /// item — those are `remove`-then-`add` and a `CredentialStore` operation respectively, not an
    /// edit.
    @discardableResult
    public func modify(
        _ id: CameraID,
        _ body: @Sendable (inout Camera) -> Void
    ) throws(LibraryMutationError) -> Camera {
        try requireWritable()
        guard let index = document.index(of: id) else {
            throw LibraryMutationError.unknownCamera(id)
        }
        let original = document.cameras[index]
        var edited = original
        body(&edited)
        edited.id = original.id
        edited.credentialRef = original.credentialRef

        let validated = try validate(edited)
        guard validated != original else { return original }
        document.cameras[index] = validated
        commit(.updated(id))
        return validated
    }

    /// Records what a successful probe learned, so the R1.2 ladder never runs for this camera again.
    ///
    /// Merges rather than replaces: a probe that learned only the resolved path must not erase a
    /// firmware version learned earlier. `probedAt` is stamped from the injected wall clock when the
    /// caller leaves it `nil`.
    @discardableResult
    public func recordProbeResult(
        _ capabilities: DeviceCapabilities,
        for id: CameraID
    ) throws(LibraryMutationError) -> Camera {
        let now = wallClock.now
        return try modify(id) { camera in
            var merged = camera.capabilities ?? DeviceCapabilities()
            if let template = capabilities.rtspPathTemplate { merged.rtspPathTemplate = template }
            if let path = capabilities.resolvedRTSPPath, !path.isEmpty {
                merged.resolvedRTSPPath = path
            }
            if let codec = capabilities.videoCodec { merged.videoCodec = codec }
            if let firmware = capabilities.firmwareVersion, !firmware.isEmpty {
                merged.firmwareVersion = firmware
            }
            merged.probedAt = capabilities.probedAt ?? now
            camera.capabilities = merged
        }
    }

    /// Stamps `lastSeenAt` from the injected wall clock. Called on a successful `PLAY` or ISAPI 200.
    @discardableResult
    public func markSeen(_ id: CameraID) throws(LibraryMutationError) -> Camera {
        let now = wallClock.now
        return try modify(id) { camera in camera.lastSeenAt = now }
    }

    // MARK: Mutations — channel inventory

    /// Stores (or replaces) a camera's channel inventory.
    ///
    /// - Throws: `.unknownCamera` when no such camera is in the library. An inventory without its
    ///   camera would be dropped by the next normalisation anyway, and silently discarding it would
    ///   hide the caller's mistake.
    public func recordChannelInventory(
        _ inventory: CameraChannelInventory
    ) throws(LibraryMutationError) {
        try requireWritable()
        guard document.camera(inventory.cameraID) != nil else {
            throw LibraryMutationError.unknownCamera(inventory.cameraID)
        }
        document.channelInventories.removeAll { $0.cameraID == inventory.cameraID }
        document.channelInventories.append(inventory.normalized())
        commit(.inventoryUpdated(inventory.cameraID))
    }

    /// Stores the ISAPI layer's merged channel list for a camera, stamped with the injected clock.
    ///
    /// The convenience the R1.3 enumeration path calls: it takes `VigilISAPI.DeviceChannel` values
    /// straight from `ChannelInventory.merge(...)` and fills in the device address from the camera
    /// record, so no caller has to remember that host and port are part of the inventory's identity.
    public func recordChannelInventory(
        for id: CameraID,
        deviceChannels: [DeviceChannel],
        source: ChannelInventorySource = .isapi
    ) throws(LibraryMutationError) {
        try requireWritable()
        guard let camera = document.camera(id) else {
            throw LibraryMutationError.unknownCamera(id)
        }
        try recordChannelInventory(CameraChannelInventory(cameraID: id,
                                                          host: camera.host,
                                                          httpPort: camera.httpPort,
                                                          deviceChannels: deviceChannels,
                                                          source: source,
                                                          enumeratedAt: wallClock.now))
    }

    // MARK: Mutations — order

    /// Moves the cameras at `offsets` so they sit before the camera currently at `destination`.
    ///
    /// The semantics are exactly SwiftUI's `onMove(perform:)`, so a sidebar can forward its
    /// `IndexSet` and `Int` unchanged: `destination` is an index into the list **before** the move,
    /// and `destination == count` means "to the end". Offsets outside the collection are ignored;
    /// relative order among the moved cameras is preserved, which is what makes a multi-row drag
    /// behave.
    ///
    /// - Returns: `true` when the order actually changed.
    @discardableResult
    public func moveCameras(fromOffsets offsets: IndexSet,
                            toOffset destination: Int) throws(LibraryMutationError) -> Bool {
        try requireWritable()
        let reordered = Self.moving(document.cameras, fromOffsets: offsets, toOffset: destination)
        guard reordered.map(\.id) != document.cameras.map(\.id) else { return false }
        document.cameras = reordered
        commit(.reordered)
        return true
    }

    /// Moves one camera to an absolute display position, clamped to the collection.
    ///
    /// The programmatic form — "put this camera third" — as opposed to the drag form above.
    @discardableResult
    public func moveCamera(_ id: CameraID,
                           to index: Int) throws(LibraryMutationError) -> Bool {
        try requireWritable()
        guard let current = document.index(of: id) else {
            throw LibraryMutationError.unknownCamera(id)
        }
        let target = min(max(index, 0), document.cameras.count - 1)
        guard target != current else { return false }
        let camera = document.cameras.remove(at: current)
        document.cameras.insert(camera, at: target)
        commit(.reordered)
        return true
    }

    /// Sets the display order explicitly.
    ///
    /// Forgiving on purpose, because the caller is a view that may be one revision behind: unknown
    /// identifiers are ignored, duplicates are taken at their first appearance, and any camera the
    /// list does not mention keeps its relative order and follows the ones that were named. A list
    /// that names every camera therefore reorders exactly, and a stale list can never delete a row.
    ///
    /// - Returns: `true` when the order actually changed.
    @discardableResult
    public func setOrder(_ ids: [CameraID]) throws(LibraryMutationError) -> Bool {
        try requireWritable()
        var remaining = document.cameras
        var ordered: [Camera] = []
        ordered.reserveCapacity(remaining.count)
        for id in ids {
            guard let index = remaining.firstIndex(where: { $0.id == id }) else { continue }
            ordered.append(remaining.remove(at: index))
        }
        ordered.append(contentsOf: remaining)
        guard ordered.map(\.id) != document.cameras.map(\.id) else { return false }
        document.cameras = ordered
        commit(.reordered)
        return true
    }

    /// The pure permutation behind ``moveCameras(fromOffsets:toOffset:)``.
    ///
    /// Written out rather than taken from SwiftUI's `move(fromOffsets:toOffset:)`, because VigilCore
    /// must not import SwiftUI — and because an off-by-one here silently scrambles the user's list,
    /// which is the kind of arithmetic that deserves its own test vectors.
    static func moving<Element>(_ elements: [Element],
                                fromOffsets offsets: IndexSet,
                                toOffset destination: Int) -> [Element] {
        let valid = offsets.filter { $0 >= 0 && $0 < elements.count }.sorted()
        guard !valid.isEmpty else { return elements }
        let moving = Set(valid)
        let moved = valid.map { elements[$0] }
        var remainder: [Element] = []
        remainder.reserveCapacity(elements.count - moved.count)
        for (index, element) in elements.enumerated() where !moving.contains(index) {
            remainder.append(element)
        }
        // `destination` indexes the ORIGINAL array, so every moved element ahead of it shifts the
        // insertion point one to the left.
        let shift = valid.filter { $0 < destination }.count
        let insertion = min(max(destination - shift, 0), remainder.count)
        remainder.insert(contentsOf: moved, at: insertion)
        return remainder
    }

    // MARK: Persistence

    /// Writes now and waits for the bytes to land.
    ///
    /// Called on quit, before sleep, before an export and before a diagnostics bundle — every point
    /// where the debounce's 500 ms could otherwise be the difference between saved and lost. Also
    /// the deterministic way for a test to make a write happen.
    ///
    /// A read-only document is a no-op, not an error: quitting must not fail because the library
    /// belongs to a newer Vigil.
    public func flush() async throws(StorageError) {
        saveTask?.cancel()
        saveTask = nil
        firstDirtyAt = nil
        guard !document.isReadOnly else {
            isDirty = false
            return
        }
        let pending = document
        isDirty = false
        do {
            _ = try await store.save(pending)
            lastSaveError = nil
        } catch {
            isDirty = true
            lastSaveError = error
            throw error
        }
    }

    /// True when there are changes the store has not yet written.
    public var hasUnsavedChanges: Bool { isDirty }

    // MARK: Private

    /// Refuses every mutation while the document belongs to a newer Vigil.
    func requireWritable() throws(LibraryMutationError) {
        guard !document.isReadOnly else {
            throw LibraryMutationError.readOnly(schemaVersion: document.schemaVersion)
        }
    }

    /// `Camera.validated()`, with its typed error re-wrapped so callers handle one error domain.
    func validate(_ camera: Camera) throws(LibraryMutationError) -> Camera {
        do {
            return try camera.validated()
        } catch {
            throw LibraryMutationError.invalidCamera(error)
        }
    }

    /// Ends every mutation: normalise, bump the revision, schedule the write, tell the observers.
    func commit(_ kind: LibraryChangeKind) {
        let report = document.normalize()
        if report.didChange {
            logger.debug(.storage, "library normalised after a mutation",
                         ["repaired": String(report.repairedCameras),
                          "droppedInvalid": String(report.droppedInvalidCameras.count)])
        }
        revision += 1
        markDirty()
        broadcast(kind)
    }

    /// Marks the document dirty and makes sure a coalescing writer is running.
    private func markDirty() {
        isDirty = true
        if firstDirtyAt == nil { firstDirtyAt = clock.now() }
        guard saveTask == nil else { return }
        saveGeneration += 1
        let generation = saveGeneration
        saveTask = Task { [weak self] in
            await self?.runSaveLoop(generation: generation)
        }
    }

    /// Waits out the debounce, writes, and repeats while more changes have arrived.
    ///
    /// On failure the dirty flag is **kept** and the write is retried on the backoff ladder; after
    /// `maxSaveRetries` consecutive failures the loop exits with the state still dirty and
    /// ``lastSaveError`` set, so the next mutation — or an explicit ``flush()`` — tries again. The
    /// pending state is never dropped.
    private func runSaveLoop(generation: Int) async {
        var failures = 0
        while isDirty, !Task.isCancelled {
            let wait = debounceInterval()
            if wait > .zero {
                do {
                    try await clock.sleep(for: wait)
                } catch {
                    break
                }
            }
            guard !Task.isCancelled else { break }

            let pending = document
            isDirty = false
            firstDirtyAt = nil
            do {
                _ = try await store.save(pending)
                lastSaveError = nil
                failures = 0
            } catch {
                isDirty = true
                lastSaveError = error
                logger.failure(.storage, error)
                failures += 1
                guard failures < options.maxSaveRetries else { break }
                let backoff = Self.retryBackoff[min(failures - 1, Self.retryBackoff.count - 1)]
                do {
                    try await clock.sleep(for: backoff)
                } catch {
                    break
                }
            }
        }
        if generation == saveGeneration { saveTask = nil }
    }

    /// How long to wait before the next write: the debounce, but never past the coalescing ceiling.
    private func debounceInterval() -> Duration {
        guard let firstDirtyAt else { return options.debounce }
        let elapsed = clock.now() - firstDirtyAt
        let untilCeiling = options.maxCoalesceLatency - elapsed
        return min(options.debounce, max(.zero, untilCeiling))
    }
}

#endif
