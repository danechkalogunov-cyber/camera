//
//  CameraLibrary.swift
//  VigilCore
//
//  The actor that owns the camera collection: add, remove, rename, reorder, enable, look up, and
//  broadcast every change so the sidebar and the grid can observe without polling.
//  Implements docs/spec-core.md §5.4 and §5.6, docs/API_CONTRACT.md §2 R-20, and
//  docs/REQUIREMENTS-CUSTOMER.md §R1.2/§R1.3 (the learned path and channel list are recorded here,
//  so the probe ladder and the channel enumeration each run once per device rather than per launch).
//
//  This type is the contract two other agents build on, so its shape is deliberately narrow:
//  * every mutation is a named method — there is no `inout` handle on the whole document,
//  * every mutation ends in `LibraryDocument.normalize()`, so no caller can leave the library in a
//    state the next load would have to repair,
//  * every mutation coalesces into a debounced write and appears on `changes()`,
//  * reordering is a permutation of one array, so a drag cannot renumber, tie, or drift.
//

#if os(macOS)

import Foundation
import VigilISAPI
import VigilProtocols

// MARK: - LibrarySnapshot

/// An immutable view of the library, taken at one revision.
///
/// Handed to the UI instead of a live reference: SwiftUI wants a value it can diff, and a value
/// cannot change under a view body halfway through drawing.
public struct LibrarySnapshot: Sendable, Hashable {

    /// Every camera, in the user's display order.
    public var cameras: [Camera]

    /// The channel inventory learned per camera, in camera order.
    public var channelInventories: [CameraChannelInventory]

    /// Increments on every committed mutation. Cheap way for a view to know it is looking at stale
    /// state, and the assertion handle for tests.
    public var revision: Int

    /// True when the document came from a newer Vigil. The UI must disable every editing
    /// affordance; every mutation on the library throws while it holds.
    public var isReadOnly: Bool

    /// When the document was last **persisted**, not when it was last changed in memory: a snapshot
    /// taken between a mutation and its debounced write still carries the previous write's stamp.
    public var updatedAt: Date

    /// Builds a snapshot.
    public init(cameras: [Camera],
                channelInventories: [CameraChannelInventory],
                revision: Int,
                isReadOnly: Bool,
                updatedAt: Date) {
        self.cameras = cameras
        self.channelInventories = channelInventories
        self.revision = revision
        self.isReadOnly = isReadOnly
        self.updatedAt = updatedAt
    }

    /// The camera with this identity, or `nil`.
    public func camera(_ id: CameraID) -> Camera? {
        cameras.first { $0.id == id }
    }

    /// The cameras the app may auto-connect, in display order.
    public var enabledCameras: [Camera] {
        cameras.filter(\.isEnabled)
    }

    /// The stored channel inventory for a camera, or `nil`.
    public func channelInventory(_ id: CameraID) -> CameraChannelInventory? {
        channelInventories.first { $0.cameraID == id }
    }
}

// MARK: - LibraryChange

/// What changed, and the library as it now stands.
public struct LibraryChange: Sendable, Hashable {

    /// Which mutation produced this event. Drives animation; never required for correctness, because
    /// ``snapshot`` is always complete.
    public var kind: LibraryChangeKind

    /// The library **after** the change.
    public var snapshot: LibrarySnapshot

    /// Builds a change event.
    public init(kind: LibraryChangeKind, snapshot: LibrarySnapshot) {
        self.kind = kind
        self.snapshot = snapshot
    }
}

/// The kinds of change a `CameraLibrary` reports.
public enum LibraryChangeKind: Sendable, Hashable {

    /// The first element every new subscriber receives: the state as it was when it subscribed.
    ///
    /// This is what makes `changes()` safe to call at any time. A subscriber can never miss a
    /// mutation that happened before it arrived, so no consumer needs a separate "read the current
    /// value first" step that could interleave with a write.
    case subscribed

    /// `load()` replaced the whole collection. Carries the recovery source when the corruption
    /// ladder ran, so the UI can raise the modal-once alert docs/spec-core.md §5.9 requires.
    case loaded(LibraryRecoverySource?)

    /// A camera was added.
    case added(CameraID)

    /// A camera was removed. Its credential and its recordings are **not** touched.
    case removed(CameraID)

    /// A camera's own fields changed: a rename, an enable, a learned capability, a `lastSeenAt`.
    case updated(CameraID)

    /// Display order changed. No camera was added or removed.
    case reordered

    /// A camera's channel inventory was replaced.
    case inventoryUpdated(CameraID)

    /// The prototype's `UserDefaults` connection was folded in as a library entry.
    case importedLegacyConnection(CameraID)
}

// MARK: - LibraryMutationError

/// Why a mutation was refused.
///
/// Deliberately not a `VigilFailure`: these are caller mistakes and UI-level conditions, not device
/// or disk failures with a diagnostic code. Storage failures keep their own vocabulary
/// (`StorageError`) and surface through ``CameraLibrary/lastSaveError``.
public enum LibraryMutationError: Error, Sendable, Hashable, CustomStringConvertible {

    /// The document was written by a newer Vigil, so nothing may be written back.
    case readOnly(schemaVersion: Int)

    /// No camera with that identity is in the library.
    case unknownCamera(CameraID)

    /// A camera with that identity is already in the library. Adding it again would produce two
    /// records the user cannot tell apart; use a mutation instead.
    case duplicateCameraID(CameraID)

    /// The record cannot address a device. Carries the field-level reason.
    case invalidCamera(CameraValidationError)

    public var description: String {
        switch self {
        case let .readOnly(version):
            "library is read-only (schema \(version) is newer than this build)"
        case let .unknownCamera(id):
            "no camera \(id.short) in the library"
        case let .duplicateCameraID(id):
            "camera \(id.short) is already in the library"
        case let .invalidCamera(reason):
            "invalid camera: \(reason)"
        }
    }
}

// MARK: - CameraLibrary

/// The single owner of the camera collection.
///
/// Nothing else may hold a mutable library. Views take snapshots, the connect path asks questions,
/// and everything that changes goes through a method here — which is what makes the debounced write,
/// the normalisation and the change broadcast unskippable.
public actor CameraLibrary {

    // MARK: Options

    /// Write-coalescing behaviour, from docs/spec-core.md §5.6.
    public struct Options: Sendable {

        /// How long to wait after a mutation before writing, so a burst becomes one write.
        public var debounce: Duration

        /// The ceiling on that wait during continuous editing. Bounds worst-case data loss: a drag
        /// that lasts ten seconds still gets written every two.
        public var maxCoalesceLatency: Duration

        /// How many consecutive failed writes to retry before giving up and leaving the state dirty
        /// with ``CameraLibrary/lastSaveError`` set for the UI to surface.
        public var maxSaveRetries: Int

        /// Builds options.
        public init(debounce: Duration = .milliseconds(500),
                    maxCoalesceLatency: Duration = .seconds(2),
                    maxSaveRetries: Int = 5) {
            self.debounce = debounce
            self.maxCoalesceLatency = maxCoalesceLatency
            self.maxSaveRetries = maxSaveRetries
        }
    }

    // MARK: Stored properties

    private let store: LibraryStore
    private let clock: any MonotonicClock
    private let wallClock: any WallClock
    private let logger: any LoggerProtocol
    private let options: Options

    private var document: LibraryDocument
    private var revision = 0
    private var subscribers: [UUID: AsyncStream<LibraryChange>.Continuation] = [:]

    private var isDirty = false
    private var firstDirtyAt: MediaInstant?
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = 0

    /// The last write failure, or `nil` when the last write succeeded.
    ///
    /// Non-`nil` means there are unsaved changes: the store keeps the dirty state and the UI owes
    /// the user the "Vigil can't save your settings" banner (docs/spec-core.md §5.5 step 10).
    public private(set) var lastSaveError: StorageError?

    /// How many change subscribers are attached. Diagnostics and tests only.
    public var subscriberCount: Int { subscribers.count }

    /// The buffer depth of each `changes()` stream.
    ///
    /// Every event carries a complete snapshot, so `.bufferingNewest` is safe: a slow consumer loses
    /// intermediate *animation hints*, never state. The alternative — unbounded buffering — would let
    /// a stalled view hold every snapshot of a 500-camera library in memory.
    private static let changeBufferDepth = 32

    /// The write-retry ladder, in seconds, from docs/spec-core.md §5.5 step 10.
    private static let retryBackoff: [Duration] = [
        .seconds(1), .seconds(2), .seconds(5), .seconds(15), .seconds(60),
    ]

    // MARK: Initialisation

    /// Builds a library over a store. Performs no I/O: call ``load()`` exactly once, at launch.
    ///
    /// - Parameters:
    ///   - store: the persistence layer. One store per directory; two libraries over one directory
    ///     would each believe they owned it.
    ///   - clock: monotonic time, for the write debounce only. Injected so a test drives coalescing
    ///     with `VirtualClock` instead of sleeping.
    ///   - wallClock: wall time, for `createdAt`, `lastSeenAt` and `probedAt`. The only source of
    ///     dates in this actor — nothing here calls `Date()`.
    ///   - logger: structured log sink. Hosts are redacted; no credential is ever logged.
    ///   - options: see ``Options``.
    public init(store: LibraryStore,
                clock: any MonotonicClock = SystemMonotonicClock(),
                wallClock: any WallClock = SystemWallClock(),
                logger: any LoggerProtocol = NullLogger(),
                options: Options = Options()) {
        self.store = store
        self.clock = clock
        self.wallClock = wallClock
        self.logger = logger
        self.options = options
        document = LibraryDocument(updatedAt: wallClock.now)
    }

    // MARK: Loading

    /// Loads the document, or recovers it, or creates it. Call once, before anything reads.
    ///
    /// Deliberately performs no write, even after a migration or a recovery: the evidence stays on
    /// disk until the user's first real change (docs/spec-core.md §5.9).
    ///
    /// - Returns: the outcome, so the app can raise the recovery alert, honour read-only mode, and
    ///   hand any `rekeyRequests` to `CredentialStore`.
    @discardableResult
    public func load() async -> LibraryLoadOutcome {
        let outcome = await store.load()
        document = outcome.document
        revision += 1
        logger.info(.storage, "library loaded",
                    ["cameras": String(document.cameras.count),
                     "schema": String(document.schemaVersion),
                     "readOnly": String(document.isReadOnly)])
        broadcast(.loaded(document.recoveredFrom))
        return outcome
    }

    // MARK: Reading

    /// The current state, as a value.
    public func snapshot() -> LibrarySnapshot {
        LibrarySnapshot(cameras: document.cameras,
                        channelInventories: document.channelInventories,
                        revision: revision,
                        isReadOnly: document.isReadOnly,
                        updatedAt: document.updatedAt)
    }

    /// Every camera, in display order.
    public func cameras() -> [Camera] { document.cameras }

    /// The camera with this identity, or `nil`.
    public func camera(_ id: CameraID) -> Camera? { document.camera(id) }

    /// The cameras the app may auto-connect, in display order.
    public func enabledCameras() -> [Camera] { document.enabledCameras }

    /// The stored channel inventory for a camera, or `nil` when its device was never enumerated.
    public func channelInventory(_ id: CameraID) -> CameraChannelInventory? {
        document.channelInventory(id)
    }

    /// Any channel inventory already learned for this device address, whichever camera owns it.
    ///
    /// The R1.3 reuse path: adding channel 7 of an NVR whose channel 1 is already configured must
    /// not re-enumerate the device.
    public func channelInventory(host: String, httpPort: Int) -> CameraChannelInventory? {
        document.channelInventory(host: host, httpPort: httpPort)
    }

    /// Whether the R1.2 `DESCRIBE` ladder still has to run for this camera.
    ///
    /// `false` when the user set an explicit path, or when a previous probe's template or resolved
    /// path was persisted — which is the whole mechanism behind "the ladder runs once per device,
    /// **ever**". A camera not in the library answers `true`: it has certainly never been probed.
    public func needsPathProbe(_ id: CameraID) -> Bool {
        guard let camera = document.camera(id) else { return true }
        if let override = camera.rtspPathOverride, !override.isEmpty { return false }
        guard let capabilities = camera.capabilities else { return true }
        if capabilities.rtspPathTemplate != nil { return false }
        if let resolved = capabilities.resolvedRTSPPath, !resolved.isEmpty { return false }
        return true
    }

    /// The document itself. For the diagnostics bundle and the export path, which need the version
    /// and the timestamps as well as the cameras.
    public func documentSnapshot() -> LibraryDocument { document }

    // MARK: Observing

    /// A stream of every change, starting with a ``LibraryChangeKind/subscribed`` event carrying the
    /// current state.
    ///
    /// One stream per consumer; a consumer that stops iterating is unsubscribed automatically. The
    /// initial replay closes the gap between "ask for the current value" and "start observing", which
    /// is otherwise a race the UI loses by drawing an empty sidebar.
    public nonisolated func changes() -> AsyncStream<LibraryChange> {
        let identity = UUID()
        let (stream, continuation) = AsyncStream<LibraryChange>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.changeBufferDepth))
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeSubscriber(identity) }
        }
        Task { await self.addSubscriber(identity, continuation) }
        return stream
    }

    private func addSubscriber(_ identity: UUID,
                               _ continuation: AsyncStream<LibraryChange>.Continuation) {
        subscribers[identity] = continuation
        continuation.yield(LibraryChange(kind: .subscribed, snapshot: snapshot()))
    }

    private func removeSubscriber(_ identity: UUID) {
        subscribers.removeValue(forKey: identity)
    }

    private func broadcast(_ kind: LibraryChangeKind) {
        guard !subscribers.isEmpty else { return }
        let change = LibraryChange(kind: kind, snapshot: snapshot())
        for continuation in subscribers.values {
            continuation.yield(change)
        }
    }

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
    private func requireWritable() throws(LibraryMutationError) {
        guard !document.isReadOnly else {
            throw LibraryMutationError.readOnly(schemaVersion: document.schemaVersion)
        }
    }

    /// `Camera.validated()`, with its typed error re-wrapped so callers handle one error domain.
    private func validate(_ camera: Camera) throws(LibraryMutationError) -> Camera {
        do {
            return try camera.validated()
        } catch {
            throw LibraryMutationError.invalidCamera(error)
        }
    }

    /// Ends every mutation: normalise, bump the revision, schedule the write, tell the observers.
    private func commit(_ kind: LibraryChangeKind) {
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

// MARK: - Legacy import mechanics

// The policy, the `UserDefaults` key names and the template inference live in
// `LibraryLegacyImport.swift`; only the state mutation is here, because `document` and `commit` are
// file-private to this one.
extension CameraLibrary {

    /// Inserts the prototype's remembered camera at position 0 and records that it has happened.
    ///
    /// See `CameraLibrary.importLegacyConnection(_:)` for the contract. Returns `nil` when the import
    /// has already run, in which case nothing is written.
    func performLegacyImport(
        _ connection: LegacyLastConnection
    ) throws(LibraryMutationError) -> LegacyImportResult? {
        try requireWritable()
        guard !document.didImportLegacyConnection else { return nil }

        // Belt to the flag's braces: a document that already holds this Keychain handle was imported
        // by a build that predates the flag, or by a hand-edit. Record it and do nothing.
        if let existing = document.cameras.first(where: { $0.credentialRef
            == connection.credentialRef }) {
            document.didImportLegacyConnection = true
            commit(.updated(existing.id))
            return nil
        }

        let now = wallClock.now
        let template = connection.rtspPath.flatMap {
            RTSPPathTemplate.matching(path: $0, channel: .first)
        }
        var capabilities: DeviceCapabilities?
        if let path = connection.rtspPath, !path.isEmpty {
            // `probedAt` is when the path was *adopted*: the prototype never recorded when it
            // learned it, and this field only drives the "last probed" staleness label. `lastSeenAt`
            // is deliberately left `nil` for the opposite reason — it decides which of two records
            // with one identity survives, and inventing a fresh timestamp there could let this
            // record displace one that really did connect.
            capabilities = DeviceCapabilities(rtspPathTemplate: template,
                                              resolvedRTSPPath: path,
                                              probedAt: now)
        }

        let imported = Camera(host: connection.host,
                              credentialRef: connection.credentialRef,
                              capabilities: capabilities,
                              createdAt: now)
        let prepared = try validate(imported)
        document.cameras.insert(prepared, at: 0)
        document.didImportLegacyConnection = true
        commit(.importedLegacyConnection(prepared.id))

        logger.notice(.storage, "imported the prototype's remembered connection into the library",
                      ["host": Redact.host(prepared.host, salt: 0),
                       "hasResolvedPath": String(capabilities?.resolvedRTSPPath != nil),
                       "template": template?.rawValue ?? "unrecognised"])
        return LegacyImportResult(camera: prepared,
                                  account: connection.account,
                                  didRecogniseTemplate: template != nil)
    }
}

#endif
