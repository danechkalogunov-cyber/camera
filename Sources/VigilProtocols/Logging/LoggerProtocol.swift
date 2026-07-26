//
//  LoggerProtocol.swift
//  VigilProtocols
//
//  The injected logging surface. The pure layer cannot import OSLog, so it logs through
//  this protocol and the app supplies the implementation.
//
//  Implements docs/API_CONTRACT.md §3.10 (rulings R-15, R-60).
//

// MARK: - Level and category

public enum LogLevel: Int, Sendable, Hashable, Codable, Comparable, CaseIterable {
    case debug, info, notice, warning, error, fault

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The complete, fixed set. Thirteen, from `ARCHITECTURE.md` §8.1. Do not invent strings at call
/// sites and do not add a fourteenth (API_CONTRACT §2 R-15, R-60).
///
/// The other two category lists in the specs map onto these: `decode → video`, `events → core`,
/// `record → core`, `playback → core`, `health → perf`, `store → storage`, `security → core`,
/// `config → storage`, `persistence → storage`, `credentials → core`.
public enum LogCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case app, discovery, rtsp, rtp, bitstream, isapi, transport
    case video, render, core, storage, ui, perf
}

// MARK: - Event

public struct LogEvent: Sendable {
    public var level: LogLevel
    public var category: LogCategory
    public var message: String
    /// MUST be pre-redacted by the caller. `OSLogLogger` interpolates it as `.public`, which is
    /// only correct because of that guarantee.
    public var metadata: [String: String]
    public var file: StaticString
    public var line: UInt

    public init(level: LogLevel, category: LogCategory, message: String,
                metadata: [String: String] = [:], file: StaticString = #fileID, line: UInt = #line) {
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
        self.file = file
        self.line = line
    }
}

// MARK: - Protocol

/// The pure layer cannot `import OSLog`, so it logs through this. Every pure type takes
/// `logger: any LoggerProtocol = NullLogger()` in its initialiser. Never a global.
public protocol LoggerProtocol: Sendable {
    /// Cheap gate so callers skip building strings for disabled levels.
    func isEnabled(_ level: LogLevel, _ category: LogCategory) -> Bool
    func log(_ event: LogEvent)
}

// Every convenience below is `@autoclosure` on both the message and the metadata, and checks
// `isEnabled` first: on the per-frame path the argument expressions must not be evaluated at all
// when the level is off.
public extension LoggerProtocol {

    @inline(__always)
    func debug(_ category: LogCategory, _ message: @autoclosure () -> String,
               _ metadata: @autoclosure () -> [String: String] = [:],
               file: StaticString = #fileID, line: UInt = #line) {
        guard isEnabled(.debug, category) else { return }
        log(LogEvent(level: .debug, category: category, message: message(),
                     metadata: metadata(), file: file, line: line))
    }

    @inline(__always)
    func info(_ category: LogCategory, _ message: @autoclosure () -> String,
              _ metadata: @autoclosure () -> [String: String] = [:],
              file: StaticString = #fileID, line: UInt = #line) {
        guard isEnabled(.info, category) else { return }
        log(LogEvent(level: .info, category: category, message: message(),
                     metadata: metadata(), file: file, line: line))
    }

    @inline(__always)
    func notice(_ category: LogCategory, _ message: @autoclosure () -> String,
                _ metadata: @autoclosure () -> [String: String] = [:],
                file: StaticString = #fileID, line: UInt = #line) {
        guard isEnabled(.notice, category) else { return }
        log(LogEvent(level: .notice, category: category, message: message(),
                     metadata: metadata(), file: file, line: line))
    }

    @inline(__always)
    func warning(_ category: LogCategory, _ message: @autoclosure () -> String,
                 _ metadata: @autoclosure () -> [String: String] = [:],
                 file: StaticString = #fileID, line: UInt = #line) {
        guard isEnabled(.warning, category) else { return }
        log(LogEvent(level: .warning, category: category, message: message(),
                     metadata: metadata(), file: file, line: line))
    }

    @inline(__always)
    func error(_ category: LogCategory, _ message: @autoclosure () -> String,
               _ metadata: @autoclosure () -> [String: String] = [:],
               file: StaticString = #fileID, line: UInt = #line) {
        guard isEnabled(.error, category) else { return }
        log(LogEvent(level: .error, category: category, message: message(),
                     metadata: metadata(), file: file, line: line))
    }

    @inline(__always)
    func fault(_ category: LogCategory, _ message: @autoclosure () -> String,
               _ metadata: @autoclosure () -> [String: String] = [:],
               file: StaticString = #fileID, line: UInt = #line) {
        guard isEnabled(.fault, category) else { return }
        log(LogEvent(level: .fault, category: category, message: message(),
                     metadata: metadata(), file: file, line: line))
    }

    /// Logs a failure at the level its severity implies, with its diagnostic code and metadata
    /// already attached. The one call site that must never be hand-rolled: a log line without the
    /// code cannot be traced back through the diagnostics bundle.
    @inline(__always)
    func failure(_ category: LogCategory, _ error: some VigilFailure,
                 file: StaticString = #fileID, line: UInt = #line) {
        let level: LogLevel
        switch error.severity {
        case .degraded: level = .notice
        case .recoverable: level = .warning
        case .fatal: level = .error
        }
        guard isEnabled(level, category) else { return }
        var metadata = error.logMetadata
        metadata["code"] = error.diagnosticCode
        log(LogEvent(level: level, category: category, message: error.userMessage,
                     metadata: metadata, file: file, line: line))
    }
}

// MARK: - Null implementation

/// The default logger for every pure type: enabled for nothing, costs nothing.
public struct NullLogger: LoggerProtocol {
    public init() {}
    public func isEnabled(_: LogLevel, _: LogCategory) -> Bool { false }
    public func log(_: LogEvent) {}
}
