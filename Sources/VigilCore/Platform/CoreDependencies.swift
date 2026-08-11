//
//  CoreDependencies.swift
//  VigilCore
//
//  The one wiring point: everything time-, Keychain-, socket- or randomness-shaped is injected from
//  here, so every actor below can be driven by a test.
//  Implements docs/spec-core.md §2 and docs/API_CONTRACT.md §4.8 (`CoreDependencies`).
//
//  Slice scope. spec-core §2's struct also carries `fileSystem`, `diskSpace`, `pathMonitor`,
//  `occlusion`, `power`, `notifications`, `pasteboard`, `makeISAPIClient`, `makeDecodeSink` and
//  `decodeScheduler`. None of them has a consumer in the first-light column — there is no
//  `library.json`, no coordinator, no event centre and no decode budget yet — and a field whose
//  only implementation is a stub is worse than an absent one, because it looks wired. Each is
//  additive: adding one later changes this file and `live`, and nothing else.
//

#if os(macOS)

import Foundation
import VigilProtocols
import VigilRTSP
import VigilTransport

// MARK: - CoreDependencies

/// Everything `VigilCore` needs from the outside world.
///
/// A value, not a service locator: it is built once in the app target and passed down by copy, so
/// there is no global to reach for and no ordering problem at launch.
public struct CoreDependencies: Sendable {

    /// Monotonic time. Every timeout, backoff and deadline in this module is measured on it, and
    /// nothing calls `Date()` for control flow.
    public var clock: any MonotonicClock

    /// Structured logging. Pre-redacted at every call site in this module.
    public var logger: any LoggerProtocol

    /// The Keychain seam. `CredentialStore` is its only user.
    public var keychain: any KeychainProtocol

    /// Injected randomness: reconnect jitter and the Digest `cnonce`. Seed it in tests and a
    /// failing run reproduces exactly.
    public var random: any RandomSource

    /// Bounded redacted RTSP/SDP transcripts shared by all sessions and diagnostics export.
    public var rtspDiagnostics: RTSPDiagnosticRecorder

    /// Builds one RTSP session for a configured target.
    ///
    /// The arguments are the session's configuration, the credential to authenticate with, and a
    /// short camera id that appears in the connection's dispatch-queue label — so a sample of a
    /// stalled app names the camera.
    public var makeRTSPSession: RTSPSessionFactory

    /// The one per-device authentication counter, shared by every lane that touches a device
    /// (API_CONTRACT §2 R-25 rule 4, docs/RULING-LOCKOUT.md §2.3).
    ///
    /// **Non-optional, and there is no default anywhere.** `StreamController` used to take
    /// `governor: LockoutGovernor? = nil` and mint a private one when the argument was omitted —
    /// which is exactly what the one call site in the app did, so the counter lived and died with a
    /// controller and every rebuild granted two more attempts. A field with no default makes a
    /// private counter unrepresentable rather than merely discouraged.
    ///
    /// `StreamProbe` reads it from here too, which matters because the probe ladder is where the
    /// credentials are actually spent.
    public var governor: LockoutGovernor

    /// Builds a dependency set explicitly. Used by tests and by anything that needs to substitute
    /// one member of `live`.
    public init(clock: any MonotonicClock,
                logger: any LoggerProtocol,
                keychain: any KeychainProtocol,
                random: any RandomSource,
                governor: LockoutGovernor,
                rtspDiagnostics: RTSPDiagnosticRecorder = RTSPDiagnosticRecorder(),
                makeRTSPSession: @escaping RTSPSessionFactory) {
        self.clock = clock
        self.logger = logger
        self.keychain = keychain
        self.random = random
        self.governor = governor
        self.rtspDiagnostics = rtspDiagnostics
        self.makeRTSPSession = makeRTSPSession
    }

    /// The production set: the system monotonic clock, the real Keychain, the system random source
    /// and real sockets.
    ///
    /// A function rather than a `static let`, because the governor has to come from outside: it is
    /// the app that owns the one instance and that knows where it is persisted (`AppEnvironment`),
    /// and a `static let` here would either build a second, unpersisted counter or hand every caller
    /// a way to construct one.
    ///
    /// The logger is `NullLogger` until `Logging/OSLogLogger.swift` lands (W4, API_CONTRACT §5.12);
    /// substitute it with `withLogger(_:)` at the call site in the meantime rather than editing this
    /// function, so there is one place that knows what "live" means.
    public static func live(governor: LockoutGovernor) -> CoreDependencies {
        let diagnostics = RTSPDiagnosticRecorder()
        return CoreDependencies(
            clock: SystemMonotonicClock(),
            logger: NullLogger(),
            keychain: SystemKeychain(),
            random: SystemRandomSource(),
            governor: governor,
            rtspDiagnostics: diagnostics,
            makeRTSPSession: { config, credential, shortID in
                RTSPConnection(config: config,
                               credential: credential,
                               clock: SystemMonotonicClock(),
                               random: SystemRandomSource(),
                               logger: NullLogger(),
                               shortID: shortID,
                               diagnostics: diagnostics,
                               connectTimeout: StreamController.connectTimeout)
            })
    }

    /// A dependency set with a different logger, keeping everything else.
    ///
    /// The one field the app target genuinely has to override before `OSLogLogger` exists, so it
    /// gets a named accessor instead of a memberwise re-spelling that would silently drop a field
    /// added to `live` later. **The governor's identity is carried through**, not rebuilt: a copy
    /// here would be a second counter, which is the whole defect.
    public func withLogger(_ logger: any LoggerProtocol) -> CoreDependencies {
        let clock = clock
        let random = random
        return CoreDependencies(clock: clock,
                                logger: logger,
                                keychain: keychain,
                                random: random,
                                governor: governor,
                                rtspDiagnostics: rtspDiagnostics,
                                makeRTSPSession: { config, credential, shortID in
                                    RTSPConnection(config: config,
                                                   credential: credential,
                                                   clock: clock,
                                                   random: random,
                                                   logger: logger,
                                                   shortID: shortID,
                                                   diagnostics: rtspDiagnostics,
                                                   connectTimeout: StreamController.connectTimeout)
                                })
    }
}

// MARK: - Conformance

/// `RTSPConnection` already has exactly this surface; the conformance is the whole adapter.
///
/// Every requirement is satisfied by an existing member:
/// `connect() async throws(VigilError)` witnesses `connect() async throws` (a typed throw is a
/// subtype of an untyped one), the actor-isolated `events()`, `perform(_:)`, `sendRTCP(_:channel:)`,
/// `pauseReads()`, `resumeReads()` and `close()` witness the `async` requirements, and the
/// `nonisolated var isTLS` witnesses `var isTLS: Bool { get async }`.
///
/// **This declaration is the single point of coupling** between `VigilCore` and the shape of
/// `VigilTransport`. If `RTSPConnection`'s signatures move, this line fails to compile and nothing
/// else in the module does.
extension RTSPConnection: RTSPSessionDriving {}

#endif
