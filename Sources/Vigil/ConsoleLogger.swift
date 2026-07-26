//
//  ConsoleLogger.swift
//  Vigil
//
//  A minimal `LoggerProtocol` over `os.Logger`, so a first-light failure on the customer's Mac
//  leaves a trace in Console.app instead of nothing at all.
//  macOS-only. See docs/API_CONTRACT.md §2 R-15, R-60 and docs/ARCHITECTURE.md §8.1.
//

#if os(macOS)

import Foundation
import os

import VigilProtocols

// MARK: - ConsoleLogger

/// Writes every module's log events to the unified log under `com.vigil.app`.
///
/// **Temporary, and deliberately so.** `VigilCore/Logging/OSLogLogger.swift` is the real one
/// (manifest §5.12, W4): it applies `Redact` before emitting, honours the log-level preference and
/// feeds `LogExporter` for the diagnostics bundle. This does none of that. It exists because
/// `CoreDependencies.live` currently ships `NullLogger`, and shipping the slice with logging off
/// would mean the one thing the customer is asked to do — launch it and see whether video appears —
/// produces no evidence when it does not. Delete this file when `OSLogLogger` lands.
///
/// **Redaction.** `LogEvent.message` and `metadata` are documented as pre-redacted by the caller,
/// which is what makes `.public` interpolation correct here. Nothing in this file inspects or
/// reformats either: a logger that re-parses a message is a logger that can leak one.
struct ConsoleLogger: LoggerProtocol {

    // MARK: - Stored Properties

    /// The lowest level that reaches the log. `debug` is off by default: the frame path calls
    /// `isEnabled` before building its strings, and leaving debug on costs allocations per packet.
    private let minimumLevel: LogLevel

    /// Reverse-DNS subsystem for every line.
    private let subsystem: String

    // MARK: - Initialisation

    /// Creates a logger writing to the given subsystem.
    ///
    /// - Parameters:
    ///   - subsystem: reverse-DNS subsystem, matching `CFBundleIdentifier` so that
    ///     `log stream --subsystem com.vigil.app` catches everything.
    ///   - minimumLevel: events below this are dropped by `isEnabled`, before their message is
    ///     built.
    init(subsystem: String = "com.vigil.app", minimumLevel: LogLevel = .info) {
        self.subsystem = subsystem
        self.minimumLevel = minimumLevel
    }

    // MARK: - LoggerProtocol

    func isEnabled(_ level: LogLevel, _ category: LogCategory) -> Bool {
        level >= minimumLevel
    }

    func log(_ event: LogEvent) {
        // The `Logger` is built per event rather than cached in a dictionary: this type must be
        // `Sendable` (`LoggerProtocol` requires it), and building the handle here keeps the only
        // stored state two value types instead of depending on `os.Logger`'s own conformance.
        // The cost lands on `info` and above only, because `isEnabled` has already run.
        let logger = Logger(subsystem: subsystem, category: event.category.rawValue)
        let line = event.metadata.isEmpty
            ? event.message
            : "\(event.message) \(Self.render(event.metadata))"
        // `.public` is correct only because the caller has already redacted; see the type's note.
        logger.log(level: Self.type(for: event.level), "\(line, privacy: .public)")
    }

    // MARK: - Private Helpers

    /// `key=value` pairs, sorted so two runs of the same failure produce comparable lines.
    private static func render(_ metadata: [String: String]) -> String {
        metadata.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    private static func type(for level: LogLevel) -> OSLogType {
        switch level {
        case .debug: return .debug
        case .info: return .info
        // `notice` is the unified log's default level; `os.Logger` spells it `.default`.
        case .notice: return .default
        case .warning: return .error
        case .error: return .error
        case .fault: return .fault
        }
    }
}

#endif  // os(macOS)
