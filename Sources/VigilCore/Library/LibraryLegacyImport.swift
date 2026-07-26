//
//  LibraryLegacyImport.swift
//  VigilCore
//
//  The one-way door out of the prototype: the camera the customer configured in `UserDefaults`
//  becomes the first entry of `library.json`, keeping its Keychain handle and the RTSP path the
//  prototype already proved works.
//  Implements docs/REQUIREMENTS-CUSTOMER.md §R1.2 and §R1.4, and replaces
//  `Sources/Vigil/AppEnvironment.swift`'s `LastConnection` as the persistence of record.
//
//  This file exists because of one fact: **the customer has a working camera configured right now.**
//  Losing it is the first thing they would notice, so the import is written to be boring —
//  idempotent, additive, and unable to remove anything.
//
//  Two deliberate decisions:
//
//  1. **The `UserDefaults` keys are not deleted.** The shipped prototype still reads them
//     (`AppSessionModel.resume(_:)`), so clearing them here would break the running app's
//     type-nothing launch before the library-driven path replaces it. They are four small strings;
//     the cleanup belongs to the commit that makes the app resume from the library.
//  2. **Idempotency is a flag in the document, not an inference.** "Is there already a camera for
//     that host?" would resurrect the imported camera every launch after the user deleted it.
//

#if os(macOS)

import Foundation
import VigilProtocols

// MARK: - LegacyLastConnection

/// The prototype's remembered connection, exactly as `Sources/Vigil/AppEnvironment.swift` writes it.
///
/// Not a secret: the password lives in the Keychain and only the opaque `CredentialRef` is stored in
/// `UserDefaults`. The account name is here because Hikvision installs occasionally use something
/// other than `admin`, and the Keychain item is the only other place it exists.
public struct LegacyLastConnection: Sendable, Hashable {

    /// Camera address as the user typed it.
    public var host: String

    /// Device account name, `admin` unless the user changed it.
    public var account: String

    /// The Keychain handle for the password. **Carried through unchanged** — this is the field that
    /// makes the difference between "the customer's camera still works" and "the customer is asked
    /// for their password again".
    public var credentialRef: CredentialRef

    /// The RTSP path that actually produced video, or `nil` if the prototype never got that far.
    public var rtspPath: String?

    /// Builds a value. Used by the app when it reads `UserDefaults`, and by tests.
    public init(host: String, account: String, credentialRef: CredentialRef,
                rtspPath: String? = nil) {
        self.host = host
        self.account = account
        self.credentialRef = credentialRef
        self.rtspPath = rtspPath
    }

    // MARK: The prototype's keys

    /// `UserDefaults` key for the host, from `AppEnvironment.swift`.
    public static let hostKey = "vigil.lastConnection.host"

    /// `UserDefaults` key for the account.
    public static let accountKey = "vigil.lastConnection.account"

    /// `UserDefaults` key for the credential handle, a UUID string.
    public static let credentialRefKey = "vigil.lastConnection.credentialRef"

    /// `UserDefaults` key for the remembered RTSP path.
    public static let rtspPathKey = "vigil.lastConnection.rtspPath"

    /// Every key the prototype writes, so a caller can snapshot exactly these and nothing else.
    public static var defaultsKeys: [String] {
        [hostKey, accountKey, credentialRefKey, rtspPathKey]
    }

    // MARK: Reading

    /// Builds a connection from key/value pairs, or `nil` when the record is absent or incomplete.
    ///
    /// The value-typed entry point, so the parsing is testable without touching a real defaults
    /// domain. A partially written record — a UUID that no longer parses, an empty host — reads as
    /// "nothing remembered", exactly as the prototype treats it: the cost is one screen of typing,
    /// and there is no state worth recovering.
    public static func from(values: [String: String]) -> LegacyLastConnection? {
        guard let host = values[hostKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty,
              let account = values[accountKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !account.isEmpty,
              let rawRef = values[credentialRefKey],
              let uuid = UUID(uuidString: rawRef) else {
            return nil
        }
        let path = values[rtspPathKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LegacyLastConnection(host: host,
                                    account: account,
                                    credentialRef: CredentialRef(uuid),
                                    rtspPath: path?.isEmpty == false ? path : nil)
    }

    /// Reads the record straight out of a defaults domain.
    ///
    /// Synchronous and `nonisolated` on purpose: `UserDefaults` is not `Sendable`, so the read must
    /// happen **before** the value crosses into the library actor. Call it at the call site, pass the
    /// result in — hoisting the read out is the same discipline that a `@Sendable` closure forces
    /// (docs/BUILD-VERIFICATION.md defect 2).
    public static func read(from defaults: UserDefaults) -> LegacyLastConnection? {
        var values: [String: String] = [:]
        for key in defaultsKeys {
            if let value = defaults.string(forKey: key) { values[key] = value }
        }
        return from(values: values)
    }
}

// MARK: - LegacyImportResult

/// What the import did, so the caller can finish the parts that are not the library's business.
public struct LegacyImportResult: Sendable, Hashable {

    /// The camera as stored, at position 0 of the library.
    public var camera: Camera

    /// The device account name from the prototype's record.
    ///
    /// The library stores no username — it belongs with the password, in the Keychain item. Handed
    /// back so the caller can re-label that item for the new camera with
    /// `CredentialStore.updateAttributes(CredentialDescriptor(camera:account:))`, which keeps
    /// Keychain Access truthful without the library ever holding the value.
    public var account: String

    /// True when a template was recognised in the remembered path, so every other quality and
    /// channel of this device also resolves without probing.
    public var didRecogniseTemplate: Bool

    /// Builds a result.
    public init(camera: Camera, account: String, didRecogniseTemplate: Bool) {
        self.camera = camera
        self.account = account
        self.didRecogniseTemplate = didRecogniseTemplate
    }
}

// MARK: - The import

public extension CameraLibrary {

    /// Folds the prototype's remembered connection into the library as the **first** entry.
    ///
    /// Idempotent in three independent ways, because this runs at every launch and must never
    /// produce a second copy:
    ///
    /// * the document's `didImportLegacyConnection` flag is set once and persisted,
    /// * a camera already holding that `credentialRef` short-circuits the import and sets the flag,
    /// * `nil` — no remembered connection — changes nothing at all and writes nothing, so a genuine
    ///   first run does not dirty the document.
    ///
    /// What the imported record carries:
    ///
    /// * the same `credentialRef`, so the Keychain item the customer's password already lives in is
    ///   still the one the camera uses. Nothing is re-entered.
    /// * `capabilities.resolvedRTSPPath` set to the remembered path, which `StreamController` uses as
    ///   its order-zero candidate — so the first connection after the upgrade skips the ladder
    ///   entirely (R1.2).
    /// * `capabilities.rtspPathTemplate` when that path is recognisably one of the ladder's rungs, so
    ///   the *other* qualities and channels of the same device resolve without probing either.
    /// * `lastSeenAt`, because the prototype only remembers a connection that produced a picture.
    ///
    /// - Parameter connection: the value read from `UserDefaults`; pass `nil` when there is none.
    /// - Returns: what was imported, or `nil` when there was nothing to do.
    /// - Throws: ``LibraryMutationError/readOnly(schemaVersion:)`` when the document belongs to a
    ///   newer Vigil, and ``LibraryMutationError/invalidCamera(_:)`` if the remembered host cannot be
    ///   repaired into something connectable.
    @discardableResult
    func importLegacyConnection(
        _ connection: LegacyLastConnection?
    ) throws(LibraryMutationError) -> LegacyImportResult? {
        guard let connection else { return nil }
        return try performLegacyImport(connection)
    }

    /// Reads the prototype's record from a defaults domain and imports it.
    ///
    /// A convenience for the app target. The read happens inside this `nonisolated`-safe call before
    /// any hop, so the non-`Sendable` `UserDefaults` never crosses an isolation boundary.
    @discardableResult
    func importLegacyConnection(
        fromDefaults values: [String: String]
    ) throws(LibraryMutationError) -> LegacyImportResult? {
        try importLegacyConnection(LegacyLastConnection.from(values: values))
    }
}

// MARK: - Template inference

/// Recognising a remembered absolute path as one of the ladder's rungs.
public extension RTSPPathTemplate {

    /// The template that renders `path` for `channel`, or `nil` when none does.
    ///
    /// Tried across every quality, because the remembered path is whichever one happened to be
    /// playing. Comparison is case-insensitive and tolerates a missing leading slash, which is the
    /// shape a hand-edited value tends to have.
    ///
    /// `.onvifStreamURI` is never returned: it renders no path, and claiming a path came from ONVIF
    /// when it did not would send a re-probe down the wrong branch.
    static func matching(path: String, channel: ChannelID) -> RTSPPathTemplate? {
        let normalised = Self.normalisedPath(path)
        guard !normalised.isEmpty else { return nil }
        for template in RTSPPathTemplate.allCases {
            for quality in StreamQuality.allCases {
                guard let rendered = template.path(channel: channel, quality: quality) else {
                    continue
                }
                if Self.normalisedPath(rendered).compare(normalised,
                                                         options: .caseInsensitive) == .orderedSame {
                    return template
                }
            }
        }
        return nil
    }

    /// Trims whitespace, drops a trailing slash, and guarantees a leading one.
    private static func normalisedPath(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return "" }
        return text.hasPrefix("/") ? text : "/" + text
    }
}

#endif
