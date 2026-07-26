//
//  LibraryDocument.swift
//  VigilCore
//
//  The versioned on-disk shape of the camera library: the document itself, the coding rules that
//  make it byte-deterministic, and the normalisation every load and every mutation ends with.
//  Implements docs/spec-core.md §5.2, §5.3, §5.7, docs/API_CONTRACT.md §2 R-20, and
//  docs/REQUIREMENTS-CUSTOMER.md §R1.2 — the learned RTSP path is persisted here, which is what
//  makes the probe ladder run once per device ever rather than once per launch.
//
//  Two deliberate departures from spec-core §5.2, both recorded because a later owner has to know:
//
//  1. `cameras` is stored **in display order** and the array order *is* the order. spec-core sorts
//     by `Camera.orderIndex`, but `Model/Camera.swift` has no `orderIndex` in this slice and this
//     file may not add one. An explicit array is in fact the stronger form: it cannot develop gaps,
//     it cannot tie, and a reorder is a permutation rather than arithmetic. When `orderIndex` lands,
//     the 3→4 migration must seed it from the array index (`index * OrderIndex.step`) — doing
//     nothing would leave every camera on the same index and lose the user's order.
//  2. `groups`, `layouts`, `bookmarks`, `clips` and `settings` are not declared, because the types
//     do not exist yet. Any such key found in the file is preserved verbatim through
//     `unknownContent` and re-emitted on save, so a document written by a build that has them is
//     never silently truncated by a build that does not.
//

#if os(macOS)

import Foundation
import VigilISAPI
import VigilProtocols

// MARK: - LibraryRecoverySource

/// Which generation the corruption ladder actually opened (docs/spec-core.md §5.9).
///
/// Surfaced so the recovery alert can name it: "recovered from yesterday's backup" and "started
/// empty" are very different messages to a user with sixteen configured cameras.
public enum LibraryRecoverySource: String, Sendable, Hashable, Codable {

    /// `library.json.bak` — the generation before the one that failed to open.
    case backup

    /// `library.json.bak2` — two generations back.
    case secondBackup

    /// Nothing opened. The library is empty and the unreadable files are quarantined, not deleted.
    case freshStart
}

// MARK: - LibraryNormalizationReport

/// What `LibraryDocument.normalize()` had to repair.
///
/// Returned rather than logged from inside the pure function so the caller decides what deserves a
/// log line and what deserves a user-visible message: a dropped camera is worth telling the user
/// about, a repaired name is not.
public struct LibraryNormalizationReport: Sendable, Hashable {

    /// Records whose `host` or ports could not be repaired into something connectable. They are
    /// removed, because a record that cannot address a device is not a camera.
    public var droppedInvalidCameras: [CameraID] = []

    /// Duplicate `Camera.id` values. The survivor is the one with the newer `lastSeenAt`, else the
    /// earlier position in the file.
    public var droppedDuplicateCameras: [CameraID] = []

    /// Channel inventories whose camera is no longer in the library. Safe to discard: an inventory
    /// is a cache of something the device told us, so losing one costs one enumeration.
    public var droppedOrphanInventories: [CameraID] = []

    /// Records `Camera.validated()` rewrote — an empty name, a clamped channel, a bracketed IPv6
    /// host.
    public var repairedCameras: Int = 0

    /// True when normalisation changed anything at all. `false` is the fixed point that makes
    /// `normalize()` idempotent, and the second call in a row must always report it.
    public var didChange: Bool {
        !droppedInvalidCameras.isEmpty || !droppedDuplicateCameras.isEmpty
            || !droppedOrphanInventories.isEmpty || repairedCameras > 0
    }

    /// Builds an empty report.
    public init() {}
}

// MARK: - LibraryDocument

/// Everything Vigil persists about the user's cameras, and nothing else.
///
/// **No credential material, ever.** `Camera` has no password property and `Credential` is not
/// `Codable` (docs/API_CONTRACT.md §2 R-14), so the only thing that reaches this document is the
/// opaque `CredentialRef` UUID. `Tests/VigilCoreTests/LibrarySecretAbsenceTests.swift` encodes a
/// fully populated library and asserts the bytes contain no secret, rather than trusting this
/// paragraph.
public struct LibraryDocument: Sendable, Hashable, Codable {

    // MARK: Schema

    /// The version this build writes. Fixed at **3** by docs/API_CONTRACT.md §2 R-20; the file is
    /// versioned from its first byte so the first schema change is a migration and not a data-loss
    /// bug.
    public static let currentSchemaVersion = 3

    /// The version the document carries. Equal to ``currentSchemaVersion`` for anything this build
    /// wrote; greater means the file came from a newer Vigil and is opened read-only.
    public var schemaVersion: Int

    /// The build that last wrote the file, e.g. `"Vigil 1.0 (412)"`. Diagnostics only — never
    /// parsed to gate behaviour.
    public var generatedBy: String

    /// When the file was last written. Set by `LibraryStore` from its injected wall clock, so it is
    /// the one field this module does not let a caller choose.
    public var updatedAt: Date

    // MARK: Content

    /// Every camera, **in display order**. The array order is the user's order: the sidebar's drag
    /// to reorder is a permutation of this array and nothing else.
    public var cameras: [Camera]

    /// The channel inventory learned per camera (customer requirement R1.3), so an NVR's channel
    /// list is enumerated once and then read from disk.
    public var channelInventories: [CameraChannelInventory]

    /// True once the prototype's `UserDefaults` `LastConnection` has been folded into this
    /// document.
    ///
    /// A flag rather than an inference: if this were derived from "is there already a camera for
    /// that host", a user who deleted the imported camera would find it resurrected on the next
    /// launch. See `LibraryLegacyImport.swift`.
    public var didImportLegacyConnection: Bool

    // MARK: Runtime-only flags

    /// Set when the on-disk `schemaVersion` was greater than ``currentSchemaVersion``. Every write
    /// path refuses to run while it is true: silently downgrading a user's library is unacceptable
    /// (docs/spec-core.md §5.8, forward guard).
    ///
    /// Not encoded.
    public var isReadOnly: Bool = false

    /// Set when the file carried top-level keys this build does not know. Their bytes are kept in
    /// ``unknownContent`` and written back out on save.
    ///
    /// Not encoded.
    public var hadUnknownContent: Bool = false

    /// The unknown top-level keys, as a JSON object, exactly as they were read.
    ///
    /// This is the forward-compatibility guarantee: a build without `layouts` must not delete a
    /// user's layouts the first time it saves. `LibraryStore.save(_:)` merges these keys back in.
    ///
    /// Not encoded (it *is* encoded, in the sense that its contents are spliced into the file — but
    /// it has no key of its own).
    public var unknownContent: Data?

    /// Which generation the recovery ladder opened, when it ran. `nil` for a normal load.
    ///
    /// Not encoded.
    public var recoveredFrom: LibraryRecoverySource?

    // MARK: Coding keys

    /// Explicit and stable: renaming a Swift property must never change a JSON key
    /// (docs/spec-core.md §4). These five keys are the persistence contract.
    enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedBy, updatedAt, cameras, channelInventories
        case didImportLegacyConnection
    }

    /// The keys this build understands. Anything else in the file is preserved verbatim.
    static let knownTopLevelKeys: Set<String> = [
        "schemaVersion", "generatedBy", "updatedAt", "cameras", "channelInventories",
        "didImportLegacyConnection",
    ]

    // MARK: Initialisation

    /// Builds a document. The defaults are the empty first-run library.
    public init(schemaVersion: Int = LibraryDocument.currentSchemaVersion,
                generatedBy: String = LibraryDocument.defaultGeneratedBy,
                updatedAt: Date = Date(timeIntervalSince1970: 0),
                cameras: [Camera] = [],
                channelInventories: [CameraChannelInventory] = [],
                didImportLegacyConnection: Bool = false) {
        self.schemaVersion = schemaVersion
        self.generatedBy = generatedBy
        self.updatedAt = updatedAt
        self.cameras = cameras
        self.channelInventories = channelInventories
        self.didImportLegacyConnection = didImportLegacyConnection
    }

    /// The `generatedBy` value used when the app does not supply one.
    ///
    /// A constant, not `Bundle.main.infoDictionary`: `Bundle` lookups are a launch-time crash
    /// surface in this project (docs/BUILD-VERIFICATION.md defect 5) and this string is diagnostic
    /// text, not behaviour. The app passes its real version through `LibraryStore.Options`.
    public static let defaultGeneratedBy = "Vigil"

    // MARK: Codable

    /// Forgiving decode: every field has a default, so a document written by an older build opens
    /// without a migration step and a document written by a newer one opens without throwing.
    ///
    /// `schemaVersion` defaults to 1 when absent, matching the migrator: an unversioned file is by
    /// definition the oldest shape.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generatedBy = try container.decodeIfPresent(String.self, forKey: .generatedBy)
            ?? LibraryDocument.defaultGeneratedBy
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? Date(timeIntervalSince1970: 0)
        cameras = try container.decodeIfPresent([Camera].self, forKey: .cameras) ?? []
        channelInventories = try container.decodeIfPresent([CameraChannelInventory].self,
                                                           forKey: .channelInventories) ?? []
        didImportLegacyConnection = try container.decodeIfPresent(
            Bool.self, forKey: .didImportLegacyConnection) ?? false
    }

    /// Exact encode: every persisted field is written, including the ones holding their default, so
    /// the file is self-describing and a diff shows real changes only.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedBy, forKey: .generatedBy)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(cameras, forKey: .cameras)
        try container.encode(channelInventories, forKey: .channelInventories)
        try container.encode(didImportLegacyConnection, forKey: .didImportLegacyConnection)
    }
}

// MARK: - Lookups

public extension LibraryDocument {

    /// The camera with this identity, or `nil`.
    ///
    /// A linear scan. The library is a user-curated list — sixteen cameras is a big installation,
    /// five hundred is the documented ceiling — so an index would cost more in invalidation bugs
    /// than it saves in comparisons.
    func camera(_ id: CameraID) -> Camera? {
        cameras.first { $0.id == id }
    }

    /// The position of a camera in display order, or `nil` when it is not in the library.
    func index(of id: CameraID) -> Int? {
        cameras.firstIndex { $0.id == id }
    }

    /// The cameras the app may auto-connect, in display order. A disabled camera stays in the
    /// library and stays in the sidebar; it simply never dials.
    var enabledCameras: [Camera] {
        cameras.filter(\.isEnabled)
    }

    /// The stored channel inventory for a camera, or `nil` when its device has never been
    /// enumerated.
    func channelInventory(_ id: CameraID) -> CameraChannelInventory? {
        channelInventories.first { $0.cameraID == id }
    }

    /// Any inventory enumerated from this device address, whichever camera owns it.
    ///
    /// The reuse path for R1.3: adding channel 7 of an NVR whose channel 1 is already in the
    /// library must not re-enumerate the device. Matched on host and control port, which together
    /// identify the device — the channel is a property of the record, not of the box.
    func channelInventory(host: String, httpPort: Int) -> CameraChannelInventory? {
        channelInventories.first { $0.host == host && $0.httpPort == httpPort }
    }

    /// The RTSP path template already learned for this device address, if any camera on it has one.
    ///
    /// This is the other half of "the ladder runs once per device, **ever**" (R1.2): the template is
    /// a firmware property, so the second channel of an NVR inherits it and probes nothing. The
    /// resolved absolute path is deliberately **not** inherited — that one is per channel.
    func learnedPathTemplate(host: String, rtspPort: Int) -> RTSPPathTemplate? {
        for camera in cameras where camera.host == host && camera.rtspPort == rtspPort {
            if let template = camera.capabilities?.rtspPathTemplate { return template }
        }
        return nil
    }
}

// MARK: - Normalisation

public extension LibraryDocument {

    /// Repairs the document in place and reports what it had to do.
    ///
    /// Pure and idempotent: `normalize()` twice reports `didChange == false` the second time, which
    /// is asserted by a test. Runs after every load and after every mutation, so no caller can put
    /// the library into a state the next load would have to fix.
    ///
    /// The rules, in order:
    ///
    /// 1. Every camera goes through `Camera.validated()`. A record that throws — an empty host, a
    ///    host that is really a pasted URL, a port outside `1...65535` — is **dropped**, because it
    ///    cannot address a device. Everything else is repaired silently.
    /// 2. Duplicate `Camera.id`s collapse to one: the newer `lastSeenAt` wins, and with no
    ///    `lastSeenAt` on either the earlier position wins. Display order is otherwise untouched.
    /// 3. Channel inventories are de-duplicated by camera, sorted into camera order for a stable
    ///    diff, and orphans are dropped.
    ///
    /// Display order is never re-sorted. The array *is* the order (see the file header).
    @discardableResult
    mutating func normalize() -> LibraryNormalizationReport {
        var report = LibraryNormalizationReport()

        var kept: [Camera] = []
        kept.reserveCapacity(cameras.count)
        var seen: [CameraID: Int] = [:]

        for camera in cameras {
            let repaired: Camera
            do {
                repaired = try camera.validated()
            } catch {
                report.droppedInvalidCameras.append(camera.id)
                continue
            }
            if repaired != camera { report.repairedCameras += 1 }

            if let position = seen[repaired.id] {
                report.droppedDuplicateCameras.append(repaired.id)
                if Self.prefersReplacement(existing: kept[position], candidate: repaired) {
                    kept[position] = repaired
                }
                continue
            }
            seen[repaired.id] = kept.count
            kept.append(repaired)
        }
        cameras = kept

        var inventories: [CameraChannelInventory] = []
        var seenInventories = Set<CameraID>()
        for inventory in channelInventories {
            guard seen[inventory.cameraID] != nil else {
                report.droppedOrphanInventories.append(inventory.cameraID)
                continue
            }
            guard seenInventories.insert(inventory.cameraID).inserted else { continue }
            inventories.append(inventory.normalized())
        }
        // Camera order, so the file's diff moves an inventory only when its camera moves.
        inventories.sort { left, right in
            (seen[left.cameraID] ?? 0) < (seen[right.cameraID] ?? 0)
        }
        if inventories != channelInventories { channelInventories = inventories }

        return report
    }

    /// Which of two records with the same identity survives: the one seen more recently.
    ///
    /// Written out rather than inlined because the `nil` cases are the interesting ones — a record
    /// that has never connected must never displace one that has.
    private static func prefersReplacement(existing: Camera, candidate: Camera) -> Bool {
        switch (existing.lastSeenAt, candidate.lastSeenAt) {
        case (nil, .some): true
        case let (.some(old), .some(new)): new > old
        default: false
        }
    }
}

// MARK: - LibraryCoding

/// The encoder and decoder the library file is written and read with.
///
/// Byte-for-byte determinism is a requirement, not a nicety (docs/spec-core.md §5.3): identical
/// state must produce identical bytes, or `LibraryStore`'s "skip the write when nothing changed"
/// check never fires and a slider drag rewrites the disk forty times a second.
public enum LibraryCoding {

    /// Pretty-printed, key-sorted, slashes unescaped, dates as `2026-07-26T14:25:30Z`.
    ///
    /// Pretty-printing a machine file is deliberate: this document is the export format, the
    /// support attachment and the thing a user may paste into an email. A 500-camera library is
    /// about 380 KB pretty-printed, which is free.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dataEncodingStrategy = .base64
        encoder.nonConformingFloatEncodingStrategy = .throw
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISAPITime.iso8601UTC(date))
        }
        return encoder
    }

    /// Accepts every date form Vigil has ever written: ISO-8601 UTC, ISO-8601 with an offset or
    /// fractional seconds, and the bare `timeIntervalSince1970` number that schema 1 used.
    ///
    /// A date that parses as none of those throws `DecodingError.dataCorrupted`, which the store
    /// treats as corruption and answers with the recovery ladder — the alternative, substituting
    /// "now", would silently move a camera's `createdAt` and make the corruption invisible.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                if let reading = ISAPITime.parse(text) { return reading.date }
                if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "unparseable date \"\(text)\"")
            }
            let seconds = try container.decode(Double.self)
            return Date(timeIntervalSince1970: seconds)
        }
        return decoder
    }
}

#endif
