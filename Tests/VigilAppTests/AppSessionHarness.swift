//
//  AppSessionHarness.swift
//  VigilAppTests
//
//  What it takes to build an `AppSessionModel` in a test, which until now nothing could.
//
//  ⛔ THIS IS THE MISSING SEAM, AND ITS ABSENCE IS WHY THE APP TARGET SITS AT 2.83 % COVERAGE OF
//  9 114 LINES. `AppSessionModel` needs a `CoreDependencies` — a clock, a logger, a Keychain, a
//  randomness source, a lockout governor and an RTSP session factory — and the test target had a
//  double for none of them. So the one layer where every defect of the last week actually lived
//  (the resume path, the pause state, the archive's identity rule, what `disconnect` stops) was the
//  one layer no test could reach. Everything here exists to end that.
//
//  ⚠️ NOTHING HERE OPENS A SOCKET OR TOUCHES THE REAL KEYCHAIN. The Keychain is a dictionary, the
//  RTSP factory hands back a session that refuses to connect, and the defaults live in a scratch
//  suite that each test removes. A test that reaches the network is a test that fails on a train.
//

#if os(macOS)

import Foundation
import Security

@testable import Vigil
import VigilCore
import VigilProtocols
import VigilRTSP
import VigilTransport

// MARK: - InMemoryKeychain

/// `KeychainProtocol` over a dictionary, keyed the way Vigil keys its items.
///
/// The four calls answer the same `OSStatus` values the real Keychain does for the cases
/// `CredentialStore` branches on — `errSecDuplicateItem` on a second add, `errSecItemNotFound` on a
/// miss — because those branches are the whole reason the seam exists.
///
/// `@unchecked Sendable`, justified: the one mutable field is read and written only under `lock`.
final class InMemoryKeychain: KeychainProtocol, @unchecked Sendable {

    private let lock = NSLock()
    private var items: [String: [String: Any]] = [:]

    init() {}

    /// The primary key Vigil files by: `kSecAttrPath` = `/vigil/credential/<uuid>`.
    private func key(_ attributes: [String: Any]) -> String {
        attributes[kSecAttrPath as String] as? String ?? ""
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        let path = key(attributes)
        guard items[path] == nil else { return errSecDuplicateItem }
        items[path] = attributes
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let stored = items[key(query)] else { return errSecItemNotFound }
        // The real Keychain returns only what was asked for. Returning the whole item regardless
        // would let a test pass while the query forgot `kSecReturnData`, which is exactly the shape
        // of mistake this double is meant to catch.
        var answer: [String: Any] = stored
        if query[kSecReturnData as String] == nil {
            answer.removeValue(forKey: kSecValueData as String)
        }
        result = answer as CFTypeRef
        return errSecSuccess
    }

    func update(_ query: [String: Any], _ attributesToUpdate: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        let path = key(query)
        guard var stored = items[path] else { return errSecItemNotFound }
        for (name, value) in attributesToUpdate { stored[name] = value }
        items[path] = stored
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        let path = key(query)
        guard items.removeValue(forKey: path) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }

    /// How many items are filed. The assertion a credential test actually wants.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }
}

// MARK: - RefusingRTSPSession

/// An `RTSPSessionDriving` that fails to connect and does nothing else.
///
/// ⚠️ Deliberately *not* a working fake. A session that connected would put the controller into its
/// real state machine, and a test of "what does `disconnect` stop" would then be a test of the RTSP
/// machine's timing. The tests here are about the app layer's own decisions; anything that needs a
/// stream belongs in `VigilCoreTests`, where the machine has its own harness.
final class RefusingRTSPSession: RTSPSessionDriving, @unchecked Sendable {

    func connect() async throws {
        throw RTSPError.transportRejected
    }

    func events() async -> AsyncStream<RTSPConnectionEvent> {
        AsyncStream { $0.finish() }
    }

    func perform(_ command: RTSPCommand) async {}
    func sendRTCP(_ payload: Data, channel: UInt8) async {}
    func pauseReads() async {}
    func resumeReads() async {}
    func close() async {}

    var isTLS: Bool { get async { false } }
}

// MARK: - AppSessionHarness

/// Builds a session model over doubles, and cleans up after itself.
@MainActor
struct AppSessionHarness {

    let keychain = InMemoryKeychain()
    let defaults: UserDefaults
    let suiteName: String
    let model: AppSessionModel

    /// Creates a model whose every dependency is a double.
    ///
    /// The defaults live in their own suite so one test's remembered connection cannot be another's
    /// — and so nothing is left on the machine that ran them: ``tearDown()`` removes the domain.
    init() {
        suiteName = "vigil.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let clock = VirtualTestClock()
        let dependencies = CoreDependencies(
            clock: clock,
            logger: NullLogger(),
            keychain: keychain,
            random: SplitMix64RandomSource(seed: 7),
            governor: LockoutGovernor(clock: clock),
            makeRTSPSession: { _, _, _ in RefusingRTSPSession() })
        model = AppSessionModel(dependencies: dependencies, defaults: defaults)
    }

    /// Removes the scratch defaults domain. Call it at the end of every test that builds a harness.
    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A camera record that is not in any library.
    func camera(host: String = "192.168.1.64", name: String = "Front door") -> Camera {
        Camera(name: name, host: host)
    }

    /// A remembered connection, with everything a test does not name defaulted.
    ///
    /// The record has seven fields and most tests care about one or two of them, so building it
    /// inline made every arrangement four lines of noise around the field under test. The defaults
    /// are the ones a first successful connect would leave behind.
    func remembered(
        host: String = "192.168.1.64",
        account: String = "admin",
        ref: CredentialRef = CredentialRef(),
        path: String? = nil,
        name: String? = nil,
        id: CameraID? = nil,
        overlay: Bool = true
    ) -> LastConnection {
        LastConnection(
            host: host,
            account: account,
            credentialRef: ref,
            rtspPath: path,
            name: name,
            cameraID: id,
            showsVideoOverlay: overlay)
    }

    /// The same, already stored — which is what a test that starts from "a camera is remembered"
    /// actually wants.
    @discardableResult
    func remember(
        host: String = "192.168.1.64",
        account: String = "admin",
        ref: CredentialRef = CredentialRef(),
        path: String? = nil,
        name: String? = nil,
        id: CameraID? = nil,
        overlay: Bool = true
    ) -> LastConnection {
        let record = remembered(
            host: host, account: account, ref: ref, path: path, name: name, id: id,
            overlay: overlay)
        record.save(to: defaults)
        return record
    }
}

// MARK: - VirtualTestClock

/// A monotonic clock that never sleeps.
///
/// `VigilTestKit.VirtualClock` is the shared one, but this target does not depend on that module
/// and adding the dependency to reach a six-line type is not worth the coupling.
///
/// `@unchecked Sendable`, justified: one lock, one field.
final class VirtualTestClock: MonotonicClock, @unchecked Sendable {

    private let lock = NSLock()
    private var nanoseconds: Int64 = 0

    func now() -> MediaInstant {
        lock.lock()
        defer { lock.unlock() }
        return MediaInstant(nanoseconds: nanoseconds)
    }

    /// Records the delay and returns at once: a test that waited would be measuring the machine.
    func sleep(for duration: Duration) async throws {
        advance(by: Int64(duration.components.seconds * 1_000_000_000
                          + duration.components.attoseconds / 1_000_000_000))
        try Task.checkCancellation()
    }

    func sleep(until deadline: MediaInstant) async throws {
        let gap = deadline.nanoseconds - now().nanoseconds
        if gap > 0 { advance(by: gap) }
        try Task.checkCancellation()
    }

    private func advance(by amount: Int64) {
        lock.lock()
        defer { lock.unlock() }
        nanoseconds += amount
    }
}

#endif  // os(macOS)
