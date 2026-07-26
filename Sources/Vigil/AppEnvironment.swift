//
//  AppEnvironment.swift
//  Vigil
//
//  Boots the one `CoreDependencies` value the whole process shares, and remembers the last camera
//  that produced a picture so a second launch needs no typing at all.
//  macOS-only. See docs/API_CONTRACT.md §4.12, docs/spec-core.md §2 and REQUIREMENTS-CUSTOMER §R1.
//

#if os(macOS)

import Foundation

import VigilCore
import VigilProtocols

// MARK: - AppEnvironment

/// Process-wide bootstrap.
///
/// The slice keeps this to the one thing the contract names: producing the `CoreDependencies`
/// value that every actor below is handed. There is no service locator and no global — the value
/// is created once in `VigilApp.init()` and passed down by copy.
enum AppEnvironment {

    /// Builds the live dependency set: system monotonic clock, real Keychain, system randomness and
    /// real sockets (`VigilTransport.RTSPConnection`).
    ///
    /// `CoreDependencies.live` is `VigilCore`'s single wiring point (docs/spec-core.md §2), so the
    /// app target deliberately has no say in which implementation of each protocol is used and a
    /// test can substitute the whole set without touching this file.
    ///
    /// The one deliberate exception is the logger. `CoreDependencies.live` uses `NullLogger`
    /// because `VigilCore/Logging/OSLogLogger.swift` is W4 and has not landed; when it does, this
    /// becomes `CoreDependencies.live.withLogger(OSLogLogger())` and the app starts writing to
    /// `com.vigil.app`'s subsystem. Until then the slice runs with logging off, which is worth
    /// saying out loud: a first-light failure on the customer's Mac will leave no trace in Console.
    static func bootstrap() -> CoreDependencies {
        CoreDependencies.live
    }
}

// MARK: - LastConnection

/// The host, account and Keychain handle of the last camera that actually produced a picture.
///
/// This is what turns the customer's R1 flow from "type an address and a password" into "type
/// nothing" on every launch after the first: the password itself never leaves the Keychain, and
/// only the opaque `CredentialRef` UUID is stored in `UserDefaults`. Nothing here is a secret —
/// the ref reveals neither the account nor the password (docs/spec-core.md §6.2) — but the account
/// name is stored too, because Hikvision installs occasionally use something other than `admin`
/// and asking again for it would break the promise.
///
/// Deliberately **not** `library.json`: persistence beyond the Keychain is out of scope for the
/// slice (`.vigil/SLICE.md`), and `UserDefaults` needs no schema, no migration and no atomic-write
/// engine. `ConfigStore` replaces this wholesale in W4.
struct LastConnection: Sendable, Hashable {

    // MARK: Stored Properties

    /// Camera address exactly as the user typed it, after trimming.
    var host: String

    /// Hikvision account name, `admin` unless the user changed it.
    var account: String

    /// Opaque Keychain handle for the password. Useless on its own.
    var credentialRef: CredentialRef

    /// The RTSP path that actually produced video last time, or `nil` if none has yet.
    ///
    /// R1.2 requires the `DESCRIBE` ladder to run **once per device, ever**. Persisting the winner
    /// is what makes the second launch skip four candidate probes, and it is the largest single
    /// saving available against R1.7's ten seconds. In W4 this belongs on
    /// `Camera.capabilities.resolvedRTSPPath` in `library.json`; here it rides along.
    var rtspPath: String?

    // MARK: Private Helpers

    private static let hostKey = "vigil.lastConnection.host"
    private static let accountKey = "vigil.lastConnection.account"
    private static let refKey = "vigil.lastConnection.credentialRef"
    private static let pathKey = "vigil.lastConnection.rtspPath"

    // MARK: API

    /// Reads the remembered connection, or `nil` when this is a first launch or the stored value is
    /// incomplete.
    ///
    /// A malformed or partially written record (a UUID string that no longer parses, an empty host)
    /// is treated as "nothing remembered" rather than as an error: the cost is one screen of typing,
    /// and there is no state worth recovering.
    static func load(from defaults: UserDefaults) -> LastConnection? {
        guard let host = defaults.string(forKey: hostKey), !host.isEmpty,
              let account = defaults.string(forKey: accountKey), !account.isEmpty,
              let rawRef = defaults.string(forKey: refKey),
              let uuid = UUID(uuidString: rawRef)
        else {
            return nil
        }
        let path = defaults.string(forKey: pathKey)
        return LastConnection(host: host,
                              account: account,
                              credentialRef: CredentialRef(uuid),
                              rtspPath: path?.isEmpty == false ? path : nil)
    }

    /// Stores this connection as the one to resume on the next launch.
    func save(to defaults: UserDefaults) {
        defaults.set(host, forKey: Self.hostKey)
        defaults.set(account, forKey: Self.accountKey)
        defaults.set(credentialRef.rawValue.uuidString, forKey: Self.refKey)
        if let rtspPath, !rtspPath.isEmpty {
            defaults.set(rtspPath, forKey: Self.pathKey)
        } else {
            defaults.removeObject(forKey: Self.pathKey)
        }
    }

    /// Forgets the remembered connection. Called when its credential no longer opens the camera, so
    /// the next launch shows the form instead of silently failing again.
    static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: hostKey)
        defaults.removeObject(forKey: accountKey)
        defaults.removeObject(forKey: refKey)
        defaults.removeObject(forKey: pathKey)
    }
}

#endif  // os(macOS)
