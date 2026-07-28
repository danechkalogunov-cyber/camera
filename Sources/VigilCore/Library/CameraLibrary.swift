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

    let store: LibraryStore
    let clock: any MonotonicClock
    let wallClock: any WallClock
    let logger: any LoggerProtocol
    let options: Options

    var document: LibraryDocument
    var revision = 0
    private var subscribers: [UUID: AsyncStream<LibraryChange>.Continuation] = [:]

    var isDirty = false
    var firstDirtyAt: MediaInstant?
    var saveTask: Task<Void, Never>?
    var saveGeneration = 0

    /// The last write failure, or `nil` when the last write succeeded.
    ///
    /// Non-`nil` means there are unsaved changes: the store keeps the dirty state and the UI owes
    /// the user the "Vigil can't save your settings" banner (docs/spec-core.md §5.5 step 10).
    public internal(set) var lastSaveError: StorageError?

    /// How many change subscribers are attached. Diagnostics and tests only.
    public var subscriberCount: Int { subscribers.count }

    /// The buffer depth of each `changes()` stream.
    ///
    /// Every event carries a complete snapshot, so `.bufferingNewest` is safe: a slow consumer loses
    /// intermediate *animation hints*, never state. The alternative — unbounded buffering — would let
    /// a stalled view hold every snapshot of a 500-camera library in memory.
    private static let changeBufferDepth = 32

    /// The write-retry ladder, in seconds, from docs/spec-core.md §5.5 step 10.
    static let retryBackoff: [Duration] = [
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

    func broadcast(_ kind: LibraryChangeKind) {
        guard !subscribers.isEmpty else { return }
        let change = LibraryChange(kind: kind, snapshot: snapshot())
        for continuation in subscribers.values {
            continuation.yield(change)
        }
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
