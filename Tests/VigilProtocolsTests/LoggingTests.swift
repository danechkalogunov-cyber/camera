//
//  LoggingTests.swift
//  VigilProtocolsTests
//
//  The injected logging surface: the fixed category list, the level gate and the
//  failure convenience. Covers docs/API_CONTRACT.md §3.10 (rulings R-15, R-60).
//

import Foundation
import Testing
import VigilProtocols

/// Records what it is given. A class, because a logger is shared by reference in production too;
/// the lock keeps it usable from any isolation without relaxing Swift 6 checking.
private final class RecordingLogger: LoggerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LogEvent] = []
    private let minimum: LogLevel

    init(minimum: LogLevel = .debug) { self.minimum = minimum }

    var events: [LogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func isEnabled(_ level: LogLevel, _: LogCategory) -> Bool { level >= minimum }

    func log(_ event: LogEvent) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }
}

private final class SteppableLoggingClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant = MediaInstant.zero

    func now() -> MediaInstant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        instant = instant + duration
    }

    func sleep(for _: Duration) async throws {}
}

@Suite struct LoggingTests {

    @Test func thereAreExactlyThirteenLogCategories() {
        #expect(LogCategory.allCases.count == 13)
        let expected: Set<String> = ["app", "discovery", "rtsp", "rtp", "bitstream", "isapi",
                                     "transport", "video", "render", "core", "storage", "ui",
                                     "perf"]
        #expect(Set(LogCategory.allCases.map(\.rawValue)) == expected)
    }

    @Test func logLevelsOrderFromDebugToFault() {
        #expect(LogLevel.allCases.sorted() == [.debug, .info, .notice, .warning, .error, .fault])
        #expect(LogLevel.debug < LogLevel.fault)
    }

    @Test func nullLoggerIsEnabledForNothing() {
        let logger = NullLogger()
        for level in LogLevel.allCases {
            for category in LogCategory.allCases {
                #expect(!logger.isEnabled(level, category))
            }
        }
        logger.log(LogEvent(level: .fault, category: .app, message: "ignored"))
    }

    @Test func loggerConveniencesCarryTheirLevel() {
        let logger = RecordingLogger()
        logger.debug(.rtsp, "d")
        logger.info(.rtp, "i")
        logger.notice(.video, "n")
        logger.warning(.isapi, "w")
        logger.error(.storage, "e")
        logger.fault(.core, "f")
        #expect(logger.events.map(\.level) == [.debug, .info, .notice, .warning, .error, .fault])
        #expect(logger.events.map(\.category) == [.rtsp, .rtp, .video, .isapi, .storage, .core])
        #expect(logger.events.map(\.message) == ["d", "i", "n", "w", "e", "f"])
    }

    @Test func aDisabledLevelNeverEvaluatesItsMessage() {
        // The per-frame path builds no strings when the level is off; this is what @autoclosure
        // on the message is for.
        let logger = RecordingLogger(minimum: .warning)
        var evaluations = 0
        func expensiveMessage() -> String {
            evaluations += 1
            return "expensive"
        }
        logger.debug(.rtp, expensiveMessage())
        logger.info(.rtp, expensiveMessage())
        #expect(evaluations == 0)
        #expect(logger.events.isEmpty)

        logger.warning(.rtp, expensiveMessage())
        #expect(evaluations == 1)
        #expect(logger.events.count == 1)
    }

    @Test func aDisabledLevelNeverEvaluatesItsMetadata() {
        let logger = RecordingLogger(minimum: .error)
        var evaluations = 0
        func expensiveMetadata() -> [String: String] {
            evaluations += 1
            return ["k": "v"]
        }
        logger.notice(.core, "m", expensiveMetadata())
        #expect(evaluations == 0)
        logger.error(.core, "m", expensiveMetadata())
        #expect(evaluations == 1)
    }

    @Test func failureLogsTheDiagnosticCodeAtTheSeverityImpliedLevel() {
        let logger = RecordingLogger()
        logger.failure(.rtsp, RTSPError.authRejected)
        logger.failure(.rtp, RTPError.gap(count: 4))
        logger.failure(.transport, TransportError.connectTimeout)

        #expect(logger.events.count == 3)
        #expect(logger.events[0].level == .error)          // fatal
        #expect(logger.events[0].metadata["code"] == "VG-RTSP-0402")
        #expect(logger.events[1].level == .notice)         // degraded
        #expect(logger.events[1].metadata["code"] == "VG-RTP-0010")
        #expect(logger.events[1].metadata["gap"] == "4")
        #expect(logger.events[2].level == .warning)        // recoverable
        #expect(logger.events[2].metadata["code"] == "VG-NET-0001")
    }

    @Test func logEventCarriesItsCallSite() {
        let logger = RecordingLogger()
        logger.warning(.app, "here")
        let event = logger.events.first
        #expect(event?.file.description.hasSuffix("LoggingTests.swift") == true)
        #expect((event?.line ?? 0) > 0)
    }

    @Test func rateLimitedLoggerEmitsBudgetThenSuppressionSummary() {
        let base = RecordingLogger()
        let clock = SteppableLoggingClock()
        let logger = RateLimitedLogger(wrapping: base, limit: 2, window: .seconds(10), clock: clock)
        let event = LogEvent(level: .warning, category: .rtp, message: "packet gap",
                             file: "Receiver.swift", line: 42)

        for _ in 0..<4 { logger.log(event) }
        #expect(base.events.map(\.message) == ["packet gap", "packet gap"])

        clock.advance(by: .seconds(10))
        logger.log(event)
        #expect(base.events.map(\.message) == [
            "packet gap", "packet gap", "packet gap — suppressed 2 similar", "packet gap",
        ])
        #expect(base.events[2].metadata["suppressed"] == "2")
    }

    @Test func rateLimitKeysAreCallSitesNotNetworkControlledMessages() {
        let base = RecordingLogger()
        let clock = SteppableLoggingClock()
        let logger = RateLimitedLogger(wrapping: base, limit: 1, clock: clock)
        logger.log(LogEvent(level: .error, category: .isapi, message: "device said A",
                            file: "Parser.swift", line: 7))
        logger.log(LogEvent(level: .error, category: .isapi, message: "device said B",
                            file: "Parser.swift", line: 7))
        logger.log(LogEvent(level: .error, category: .isapi, message: "another site",
                            file: "Parser.swift", line: 8))
        #expect(base.events.map(\.message) == ["device said A", "another site"])
    }

    @Test func zeroLimitSuppressesEverythingAndReportsAtTheNextWindow() {
        let base = RecordingLogger()
        let clock = SteppableLoggingClock()
        let logger = RateLimitedLogger(wrapping: base, limit: 0, window: .seconds(1), clock: clock)
        let event = LogEvent(level: .notice, category: .perf, message: "overload",
                             file: "Budget.swift", line: 3)
        logger.log(event)
        logger.log(event)
        #expect(base.events.isEmpty)
        clock.advance(by: .seconds(1))
        logger.log(event)
        #expect(base.events.map(\.message) == ["overload — suppressed 2 similar"])
    }
}
