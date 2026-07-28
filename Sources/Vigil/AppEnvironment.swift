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

    /// **The one authentication counter in the process.**
    ///
    /// Every lane that touches a device shares this instance (API_CONTRACT §2 R-25 rule 4,
    /// docs/RULING-LOCKOUT.md §2.3): it reaches `VigilCore` through `CoreDependencies.governor` and
    /// `VigilISAPI` through `ISAPIClient.init`. Nothing else in the app may construct one, and after
    /// §2.4 nothing else *can* — `StreamController` no longer has a `governor:` parameter to default.
    ///
    /// A `static let`, so it is built exactly once, on first use, and outlives every controller. That
    /// is the point: the counter used to be a private field on `StreamController`, and
    /// `AppSessionModel.stopSession()`'s `controller = nil` destroyed it, so every press of a retry
    /// button granted two more sign-in attempts against a device that locks an account at about five.
    ///
    /// The store is what makes it survive a relaunch (§2.8). Without one, quit-and-relaunch hands a
    /// wrong password a fresh budget while the device's own thirty-minute lock is still running.
    static let governor = LockoutGovernor(
        clock: SystemMonotonicClock(),
        logger: ConsoleLogger(),
        store: LockoutDefaultsStore(defaults: .standard, wallClock: SystemWallClock()))

    /// Builds the live dependency set: system monotonic clock, real Keychain, system randomness and
    /// real sockets (`VigilTransport.RTSPConnection`).
    ///
    /// `CoreDependencies.live` is `VigilCore`'s single wiring point (docs/spec-core.md §2), so the
    /// app target deliberately has no say in which implementation of each protocol is used and a
    /// test can substitute the whole set without touching this file.
    ///
    /// The one deliberate override is the logger. `CoreDependencies.live` ships `NullLogger`
    /// because `VigilCore/Logging/OSLogLogger.swift` is W4 and has not landed, and a slice whose
    /// only acceptance test is "launch it and see whether video appears" must not fail silently.
    /// `withLogger` is `VigilCore`'s named accessor for exactly this substitution — it rebuilds the
    /// session factory with the new logger, which a memberwise re-spelling here would not.
    /// When `OSLogLogger` lands, this becomes `.withLogger(OSLogLogger())` and
    /// `Sources/Vigil/ConsoleLogger.swift` is deleted.
    static func bootstrap() -> CoreDependencies {
        CoreDependencies.live(governor: governor).withLogger(ConsoleLogger())
    }
}

// MARK: - LockoutDefaultsStore

/// `UserDefaults` persistence for the authentication tally, beside `LastConnection`.
///
/// Placed here rather than in `VigilProtocols` because the TTL needs wall time and the pure layer is
/// forbidden from reading a clock (docs/RULING-LOCKOUT.md §2.8). The implementation therefore owns
/// both halves of the freshness rule: it stamps on save and filters on load.
///
/// **Thirty minutes**, matching the firmware's documented lock window. A record older than that
/// describes a lock the device has already released, and holding it against the user would refuse a
/// sign-in for a reason that no longer exists. A record *younger* than that is kept, which is the
/// fail-safe direction.
///
/// What is stored is a host, an account, a small integer and a list of salted, truncated digests
/// (`SecretFingerprint`). No password and no secret material: the digests are salted with the
/// persisted `CredentialRef`, which is a per-device random UUID, so they cannot be matched against a
/// precomputed table and mean nothing to a reader who does not already know the device (§7).
///
/// `@unchecked Sendable` is required and is justified: `LockoutStore` inherits `Sendable` because the
/// governor is an actor that stores one, but `UserDefaults` is not `Sendable` on any platform Vigil
/// builds for (`LibraryLegacyImport` records the same fact). It *is* documented as thread-safe — every
/// accessor is atomic and the class exists to be read from anywhere — and both methods here do
/// nothing but call it, so the box is safe. Nothing else about this type is mutable.
struct LockoutDefaultsStore: LockoutStore, @unchecked Sendable {

    /// How long a stored tally is held against the user.
    static let timeToLive: TimeInterval = 30 * 60

    private static let recordsKey = "vigil.lockout.records"
    private static let stampKey = "vigil.lockout.savedAt"

    private let defaults: UserDefaults
    private let wallClock: any WallClock

    /// Builds a store.
    ///
    /// - Parameters:
    ///   - defaults: where to write. `.standard` in the app.
    ///   - wallClock: the only clock that can measure a TTL across a relaunch. Injected so a test
    ///     never waits thirty minutes.
    init(defaults: UserDefaults, wallClock: any WallClock) {
        self.defaults = defaults
        self.wallClock = wallClock
    }

    /// Records still inside the TTL, or none.
    ///
    /// A malformed, truncated or half-written store is "nothing remembered" rather than an error: the
    /// cost is one budget and no correctness, and there is no state here worth recovering.
    func loadRecords() -> [LockoutRecord] {
        let savedAt = defaults.double(forKey: Self.stampKey)
        guard savedAt > 0 else { return [] }
        let age = wallClock.now.timeIntervalSince1970 - savedAt
        // A negative age means the system clock moved backwards since the write. Trust the record
        // rather than discard it: discarding is the fail-open direction, and a wrong clock must not be
        // a way to reset the counter.
        guard age < Self.timeToLive else { return [] }
        guard let data = defaults.data(forKey: Self.recordsKey),
              let decoded = try? JSONDecoder().decode([LockoutRecord].self, from: data)
        else { return [] }
        return decoded
    }

    /// Replaces the stored set and stamps it as of now.
    ///
    /// A failure to encode is swallowed on purpose: a governor that could not persist is still
    /// completely correct for this process, and there is nothing the user could do about it.
    func saveRecords(_ records: [LockoutRecord]) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: Self.recordsKey)
            defaults.removeObject(forKey: Self.stampKey)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.recordsKey)
        defaults.set(wallClock.now.timeIntervalSince1970, forKey: Self.stampKey)
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

    /// The name the user gave this camera, or `nil` if they never renamed it.
    ///
    /// **Keyed by nothing, on purpose.** `Camera.id` is minted fresh on every launch — `makeCamera`
    /// builds the record from the remembered host, not from a stored document — so a per-`CameraID`
    /// name store would forget the name on the next launch and be silently useless. The host is the
    /// only identity that survives a relaunch today, and this record is already the thing keyed by
    /// it. `ConfigStore` in W4 replaces the arrangement wholesale.
    ///
    /// Last in the declaration order and defaulted, so the memberwise initialiser's existing four
    /// call sites still compile unchanged.
    var name: String?

    // MARK: Private Helpers

    private static let hostKey = "vigil.lastConnection.host"
    private static let accountKey = "vigil.lastConnection.account"
    private static let refKey = "vigil.lastConnection.credentialRef"
    private static let pathKey = "vigil.lastConnection.rtspPath"
    private static let nameKey = "vigil.lastConnection.name"

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
        let name = defaults.string(forKey: nameKey)
        return LastConnection(host: host,
                              account: account,
                              credentialRef: CredentialRef(uuid),
                              rtspPath: path?.isEmpty == false ? path : nil,
                              name: name?.isEmpty == false ? name : nil)
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
        if let name, !name.isEmpty {
            defaults.set(name, forKey: Self.nameKey)
        } else {
            defaults.removeObject(forKey: Self.nameKey)
        }
    }

    /// Forgets the remembered connection. Called when its credential no longer opens the camera, so
    /// the next launch shows the form instead of silently failing again.
    static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: hostKey)
        defaults.removeObject(forKey: accountKey)
        defaults.removeObject(forKey: refKey)
        defaults.removeObject(forKey: pathKey)
        defaults.removeObject(forKey: nameKey)
    }
}

#endif  // os(macOS)
