//
//  LibrarySchemaMigration.swift
//  VigilCore
//
//  The schema migration chain for `library.json`, operating on untyped JSON so the codebase never
//  accumulates `CameraV1`, `CameraV2`, … forever.
//  Implements docs/spec-core.md §5.8 and docs/API_CONTRACT.md §2 R-20 (schema 3).
//
//  The chain exists on day one on purpose. The customer has a camera configured *now*; the first
//  time this document's shape changes, a missing migration step is not an inconvenience, it is the
//  user's camera list disappearing. Writing the engine before it is needed costs an hour, and the
//  1→2 and 2→3 steps below are the two the specification already describes, so a file written by
//  either beta shape still opens.
//

#if os(macOS)

import Foundation
import VigilISAPI
import VigilProtocols

// MARK: - LibraryRekeyRequest

/// One camera whose credential handle was rewritten by a migration.
///
/// Schema 2 wrote `credentialRef` as `"host:port:user"`, which leaked the username into the file.
/// Schema 3 replaces it with a fresh opaque UUID — which orphans the Keychain item, so
/// `CredentialStore` must re-tag the existing item under the new handle. That work belongs to the
/// Keychain owner, so the migration reports it rather than doing it.
///
/// Carries no secret. `account` is the username, which is not a secret but is never logged next to a
/// realm (docs/API_CONTRACT.md §3.13).
public struct LibraryRekeyRequest: Sendable, Hashable {

    /// The camera whose handle changed.
    public var cameraID: CameraID

    /// The freshly minted handle now stored in the document.
    public var credentialRef: CredentialRef

    /// Host from the legacy composite reference, for locating the old Keychain item.
    public var host: String

    /// Port from the legacy composite reference. `nil` when it was not a number.
    public var port: Int?

    /// Username from the legacy composite reference.
    public var account: String

    /// Builds a request.
    public init(cameraID: CameraID, credentialRef: CredentialRef, host: String, port: Int?,
                account: String) {
        self.cameraID = cameraID
        self.credentialRef = credentialRef
        self.host = host
        self.port = port
        self.account = account
    }
}

// MARK: - LibraryMigrationContext

/// Everything a migration step needs from outside itself, plus what it has to report back.
///
/// The credential-handle factory is injected for the same reason clocks are: a migration that
/// mints `UUID()` internally cannot be asserted on, and "the migration produced the right number of
/// fresh handles" is exactly the property a test must pin.
public struct LibraryMigrationContext: Sendable {

    /// Mints a new Keychain handle. `CredentialRef()` in production.
    public var makeCredentialRef: @Sendable () -> CredentialRef

    /// Cameras whose credential handle this migration rewrote.
    public var rekeyRequests: [LibraryRekeyRequest] = []

    /// Human-readable notes for the log line and the diagnostics manifest, e.g. `"2→3: 3 cameras
    /// re-keyed"`.
    public var notes: [String] = []

    /// Builds a context.
    public init(makeCredentialRef: @escaping @Sendable () -> CredentialRef = { CredentialRef() }) {
        self.makeCredentialRef = makeCredentialRef
    }
}

// MARK: - LibrarySchemaMigration

/// One step of the chain, from `from` to `from + 1`.
///
/// Steps operate on `[String: Any]` — the parsed JSON root — and never on Swift models, so a step
/// written today keeps working when `Camera` gains a field tomorrow.
///
/// A **struct of one closure**, not a protocol with static requirements as docs/spec-core.md §5.8
/// spells it. The reason is concrete rather than aesthetic: `[any SchemaMigration.Type]` plus
/// `$0.from` crashes the Swift 6.1.2 compiler in SILGen (signal 11, `alloc_stack
/// $@opened(...) Self`) as soon as a second file reads the array. The value form has the same shape
/// at every call site, costs nothing, and cannot take a build down.
public struct LibrarySchemaMigration: Sendable {

    /// The version this step upgrades from.
    public let from: Int

    /// The version this step produces. Always `from + 1`; asserted by a test over the whole chain.
    public let to: Int

    /// Rewrites the document in place.
    ///
    /// Throws `StorageError.corruptDocument` when the document is so far from the expected shape
    /// that transforming it would invent data. Never throws for a *missing* field: absent means
    /// "take the default", which is what makes additive changes migration-free.
    public let apply: @Sendable (inout [String: Any],
                                inout LibraryMigrationContext) throws(StorageError) -> Void

    /// Builds a step. `to` must be `from + 1`; `LibrarySchemaMigrator.isChainComplete` is the check.
    public init(from: Int,
                to: Int,
                apply: @escaping @Sendable (inout [String: Any],
                                            inout LibraryMigrationContext)
                    throws(StorageError) -> Void) {
        self.from = from
        self.to = to
        self.apply = apply
    }
}

// MARK: - LibraryMigrationResult

/// The outcome of running the chain.
public struct LibraryMigrationResult: Sendable {

    /// The migrated document bytes, ready to decode.
    public var data: Data

    /// The steps that ran, as `"1→2"`, `"2→3"`. Empty when the file was already current.
    public var applied: [String]

    /// Cameras whose Keychain item needs re-tagging (see ``LibraryRekeyRequest``).
    public var rekeyRequests: [LibraryRekeyRequest]

    /// Notes for the log and the diagnostics manifest.
    public var notes: [String]

    /// Builds a result.
    public init(data: Data, applied: [String], rekeyRequests: [LibraryRekeyRequest],
                notes: [String]) {
        self.data = data
        self.applied = applied
        self.rekeyRequests = rekeyRequests
        self.notes = notes
    }
}

// MARK: - LibrarySchemaMigrator

/// Runs the chain, in ascending order, one step at a time.
public enum LibrarySchemaMigrator {

    /// Every registered step, ascending.
    ///
    /// A computed property rather than a stored `static let`: rebuilding two values costs nothing,
    /// and a stored global would need a concurrency annotation to justify itself.
    public static var steps: [LibrarySchemaMigration] {
        [LibrarySchemaMigration(from: 1, to: 2, apply: LibraryMigration1to2.apply),
         LibrarySchemaMigration(from: 2, to: 3, apply: LibraryMigration2to3.apply)]
    }

    /// True when the chain covers every version from 1 to the current one with no gap and no
    /// duplicate. A test asserts it; nothing checks it at runtime, because a broken chain is a
    /// programmer error that must fail the build, not the user's launch.
    public static var isChainComplete: Bool {
        let all = steps
        var version = 1
        while version < LibraryDocument.currentSchemaVersion {
            let matches = all.filter { $0.from == version }
            guard matches.count == 1, let step = matches.first, step.to == version + 1 else {
                return false
            }
            version = step.to
        }
        return true
    }

    /// Migrates `data` up to ``LibraryDocument/currentSchemaVersion``.
    ///
    /// - Parameters:
    ///   - data: the file's bytes, exactly as read.
    ///   - context: injected dependencies; also collects rekey requests and notes.
    /// - Returns: the migrated bytes plus what happened. When the document is already current the
    ///   bytes are re-serialised anyway, which normalises key order and costs one pass.
    /// - Throws: `.notAnObject` when the root is not a JSON object, `.corruptDocument` when the
    ///   bytes are not JSON at all, `.schemaTooNew` when the file came from a newer Vigil — the
    ///   caller must then open read-only and write nothing — and `.missingMigration` when a step is
    ///   absent, which is a programmer error surfaced rather than silently skipped.
    public static func migrate(
        _ data: Data,
        context: inout LibraryMigrationContext
    ) throws(StorageError) -> LibraryMigrationResult {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw StorageError.corruptDocument("not JSON: \(error.localizedDescription)")
        }
        guard var root = parsed as? [String: Any] else { throw StorageError.notAnObject }

        var version = (root["schemaVersion"] as? Int) ?? 1
        guard version <= LibraryDocument.currentSchemaVersion else {
            throw StorageError.schemaTooNew(found: version,
                                            supported: LibraryDocument.currentSchemaVersion)
        }
        guard version >= 1 else { throw StorageError.corruptDocument("schemaVersion \(version)") }

        let all = steps
        var applied: [String] = []
        while version < LibraryDocument.currentSchemaVersion {
            guard let step = all.first(where: { $0.from == version }) else {
                throw StorageError.missingMigration(from: version)
            }
            try step.apply(&root, &context)
            version = step.to
            root["schemaVersion"] = version
            applied.append("\(step.from)→\(step.to)")
        }

        // Shape normalisation, not a version migration: runs on **every** load, including a document
        // already at the current schema. See `canonicaliseCredentialRefs`.
        let rewritten = LibraryMigrationJSON.canonicaliseCredentialRefs(&root)
        if rewritten > 0 {
            context.notes.append("credentialRef shape normalised on \(rewritten) cameras")
        }

        let migrated: Data
        do {
            migrated = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.sortedKeys, .prettyPrinted])
        } catch {
            throw StorageError.corruptDocument("migrated document is not serialisable")
        }
        return LibraryMigrationResult(data: migrated,
                                      applied: applied,
                                      rekeyRequests: context.rekeyRequests,
                                      notes: context.notes)
    }
}

// MARK: - Migration 1 → 2

/// Schema 1 → 2: one `port` became `httpPort` + `rtspPort`, and dates were UNIX numbers.
///
/// Shipped in the 0.4 beta per docs/spec-core.md §5.8. The date half is belt-and-braces —
/// `LibraryCoding.makeDecoder()` still accepts a bare number — but a migrated document must be
/// canonical, or the *next* schema change inherits two date formats to reason about.
public enum LibraryMigration1to2 {

    /// Splits the port and canonicalises every date. A camera that is not a JSON object is dropped:
    /// there is nothing in it to migrate and keeping it would fail the validating decode that
    /// follows.
    public static func apply(_ root: inout [String: Any],
                             context: inout LibraryMigrationContext) throws(StorageError) {
        LibraryMigrationJSON.canonicaliseDate(&root, "updatedAt")

        var migrated: [[String: Any]] = []
        var dropped = 0
        for element in root["cameras"] as? [Any] ?? [] {
            guard var camera = element as? [String: Any] else {
                dropped += 1
                continue
            }
            if let port = camera["port"] as? Int {
                if camera["httpPort"] == nil { camera["httpPort"] = port }
                camera.removeValue(forKey: "port")
            }
            if camera["httpPort"] == nil { camera["httpPort"] = 80 }
            if camera["rtspPort"] == nil { camera["rtspPort"] = 554 }
            LibraryMigrationJSON.canonicaliseDate(&camera, "createdAt")
            LibraryMigrationJSON.canonicaliseDate(&camera, "lastSeenAt")
            if var capabilities = camera["capabilities"] as? [String: Any] {
                LibraryMigrationJSON.canonicaliseDate(&capabilities, "probedAt")
                camera["capabilities"] = capabilities
            }
            migrated.append(camera)
        }
        if root["cameras"] != nil { root["cameras"] = migrated }
        context.notes.append("1→2: \(migrated.count) cameras, \(dropped) unreadable entries dropped")
    }
}

// MARK: - Migration 2 → 3

/// Schema 2 → 3: `credentialRef` was `"host:port:user"`, and layouts stored `cells` as an object.
///
/// Shipped in the 0.9 beta per docs/spec-core.md §5.8. Vigil has no `Layout` type in this slice, so
/// the layout half rewrites the untyped JSON and leaves it in the document's preserved unknown
/// content — the shape a future `Layout` owner expects, rather than a v2 shape hiding inside a
/// document that claims to be v3.
public enum LibraryMigration2to3 {

    /// Mints a fresh handle for every composite `credentialRef` and reports it for re-tagging.
    public static func apply(_ root: inout [String: Any],
                             context: inout LibraryMigrationContext) throws(StorageError) {
        var migrated: [[String: Any]] = []
        var rekeyed = 0
        for element in root["cameras"] as? [Any] ?? [] {
            guard var camera = element as? [String: Any] else { continue }
            if let raw = camera["credentialRef"] as? String,
               UUID(uuidString: raw) == nil,
               let legacy = LibraryMigrationJSON.parseCompositeCredentialRef(raw) {
                let ref = context.makeCredentialRef()
                camera["credentialRef"] = ref.rawValue.uuidString
                rekeyed += 1
                if let idText = camera["id"] as? String, let uuid = UUID(uuidString: idText) {
                    context.rekeyRequests.append(
                        LibraryRekeyRequest(cameraID: CameraID(uuid),
                                            credentialRef: ref,
                                            host: legacy.host,
                                            port: legacy.port,
                                            account: legacy.account))
                }
            }
            migrated.append(camera)
        }
        if root["cameras"] != nil { root["cameras"] = migrated }

        var convertedLayouts = 0
        var layouts: [[String: Any]] = []
        for element in root["layouts"] as? [Any] ?? [] {
            guard var layout = element as? [String: Any] else { continue }
            if let cells = layout["cells"] as? [String: Any] {
                layout["assignments"] = LibraryMigrationJSON.assignments(fromCells: cells)
                layout.removeValue(forKey: "cells")
                convertedLayouts += 1
            }
            layouts.append(layout)
        }
        if root["layouts"] != nil { root["layouts"] = layouts }

        context.notes.append("2→3: \(rekeyed) cameras re-keyed, \(convertedLayouts) layouts "
                             + "converted")
    }
}

// MARK: - LibraryMigrationJSON

/// Untyped-JSON helpers shared by the steps. Internal: migrations are the only sane caller.
enum LibraryMigrationJSON {

    /// Rewrites `key` from a UNIX timestamp number to an ISO-8601 UTC string, in place.
    ///
    /// Leaves a value that is already a string alone, and leaves an absent key absent — a `null`
    /// `lastSeenAt` means "never seen", which is different from epoch zero.
    static func canonicaliseDate(_ object: inout [String: Any], _ key: String) {
        guard let value = object[key] else { return }
        if let number = value as? NSNumber, !(value is NSString) {
            object[key] = ISAPITime.iso8601UTC(Date(timeIntervalSince1970: number.doubleValue))
        }
    }

    /// Splits a schema-2 `"host:port:user"` credential reference.
    ///
    /// Returns `nil` for anything that is not at least `host:port:user`, so a value that is merely
    /// unrecognised is left in place for the validating decode to reject, rather than being turned
    /// into a plausible-looking wrong answer. An IPv6 host is written with brackets in this legacy
    /// form, so the split is on the **last two** colons.
    static func parseCompositeCredentialRef(_ raw: String) -> (host: String, port: Int?,
                                                               account: String)? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let account = String(parts[parts.count - 1])
        let port = Int(parts[parts.count - 2])
        let host = parts[0..<(parts.count - 2)].joined(separator: ":")
        guard !host.isEmpty, !account.isEmpty else { return nil }
        return (host, port, account)
    }

    /// Whether the `CredentialRef` in this build encodes as `{"rawValue": "…"}` rather than as the
    /// bare JSON string docs/spec-core.md §5.2's sample document shows.
    ///
    /// Determined by encoding a probe rather than by asserting one shape, because the answer is not
    /// this module's to choose: `VigilProtocols.CredentialRef` currently takes Swift's synthesised
    /// `Codable`, which writes the object form, while its own doc comment and the specification's
    /// sample library both show the string form. Whichever way that is settled, the byte on disk
    /// changes — and a `credentialRef` that fails to decode is the customer being asked for their
    /// camera password again.
    static let credentialRefEncodesAsJSONObject: Bool = {
        guard let data = try? JSONEncoder().encode([CredentialRef()]) else { return true }
        for byte in data {
            if byte == UInt8(ascii: "[") || byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") {
                continue
            }
            return byte == UInt8(ascii: "{")
        }
        return true
    }()

    /// Rewrites every camera's `credentialRef` into the shape this build's decoder expects.
    ///
    /// Accepts both forms in both directions, so the handle survives whichever way
    /// `CredentialRef.Codable` is spelled: a file written by the object form still opens after the
    /// type is given single-value coding, and the specification's documented string form opens today.
    /// A value that is neither — the schema-2 composite, say — is left exactly as it is for the step
    /// that owns it.
    ///
    /// - Returns: how many records were rewritten.
    @discardableResult
    static func canonicaliseCredentialRefs(_ root: inout [String: Any]) -> Int {
        guard let cameras = root["cameras"] as? [Any] else { return 0 }
        var rewritten = 0
        var normalised: [Any] = []
        normalised.reserveCapacity(cameras.count)
        for element in cameras {
            guard var camera = element as? [String: Any] else {
                normalised.append(element)
                continue
            }
            let value = camera["credentialRef"]
            let uuidText: String? = {
                if let text = value as? String { return UUID(uuidString: text) == nil ? nil : text }
                if let object = value as? [String: Any], let text = object["rawValue"] as? String {
                    return UUID(uuidString: text) == nil ? nil : text
                }
                return nil
            }()

            if let uuidText {
                let wanted: Any = credentialRefEncodesAsJSONObject ? ["rawValue": uuidText]
                    : uuidText
                if !Self.isSameCredentialRefShape(value, wanted) {
                    camera["credentialRef"] = wanted
                    rewritten += 1
                }
            } else if value != nil {
                // Unusable: a hand-edited value, or a schema-2 composite in a document that claims
                // to be schema 3. Dropping the key costs this one camera's saved password, because
                // `Camera` mints a fresh handle for an absent one. Leaving it in place would throw
                // out of the decode and cost the user their **entire** library.
                camera.removeValue(forKey: "credentialRef")
                rewritten += 1
            }
            normalised.append(camera)
        }
        if rewritten > 0 { root["cameras"] = normalised }
        return rewritten
    }

    /// Whether an existing JSON value is already the shape the decoder wants, so an unchanged
    /// document reports zero rewrites and the log stays quiet on a normal launch.
    private static func isSameCredentialRefShape(_ value: Any?, _ wanted: Any) -> Bool {
        if let left = value as? String, let right = wanted as? String { return left == right }
        if let left = value as? [String: Any], let right = wanted as? [String: Any] {
            return left.count == right.count
                && left["rawValue"] as? String == right["rawValue"] as? String
        }
        return false
    }

    /// Converts a schema-2 `cells` object — `{"0": "UUID", "3": "UUID"}` — into the schema-3
    /// `assignments` array, ascending by cell index.
    ///
    /// A key that is not an integer, or a value that is not a string, is dropped: a cell index that
    /// cannot be ordered cannot be drawn.
    static func assignments(fromCells cells: [String: Any]) -> [[String: Any]] {
        cells.compactMap { key, value -> (Int, [String: Any])? in
            guard let index = Int(key), index >= 0, let cameraID = value as? String else {
                return nil
            }
            return (index, ["cellIndex": index, "cameraID": cameraID])
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }
}

#endif
