//
//  RecordingLogger.swift
//  VigilTestKit
//
//  A logger that keeps every event so a test can assert on what the code under test said, not only
//  on what it returned. Useful where the observable behaviour *is* a log line — an interleave
//  desynchronisation that recovered, for example, leaves no other trace.
//  Implements docs/API_CONTRACT.md §4.13.
//

import Foundation
import VigilProtocols

// MARK: - RecordingLogger

/// Records every `LogEvent` at or above `minimumLevel`.
///
/// The storage is a class behind a lock because `LoggerProtocol` is `Sendable` and its `log` method
/// is non-mutating: a struct with value storage could not record anything. The lock is uncontended
/// in a single-threaded test and costs nothing that matters here.
public struct RecordingLogger: LoggerProtocol {

    /// Shared mutable storage.
    private final class Storage: @unchecked Sendable {
        // @unchecked is justified: every access to `events` is inside `lock`, and `lock` is the
        // only other stored property. There is no way to reach `events` without holding it.
        private let lock = NSLock()
        private var events: [LogEvent] = []

        func append(_ event: LogEvent) {
            lock.lock()
            defer { lock.unlock() }
            events.append(event)
        }

        func snapshot() -> [LogEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            events.removeAll()
        }
    }

    private let storage = Storage()

    /// Events below this level are dropped without being recorded.
    public let minimumLevel: LogLevel

    /// Creates a logger. The default records everything, which is what a failing test wants.
    public init(minimumLevel: LogLevel = .debug) {
        self.minimumLevel = minimumLevel
    }

    public func isEnabled(_ level: LogLevel, _: LogCategory) -> Bool {
        level >= minimumLevel
    }

    public func log(_ event: LogEvent) {
        guard event.level >= minimumLevel else { return }
        storage.append(event)
    }

    // MARK: Inspection

    /// Every recorded event, oldest first.
    public var events: [LogEvent] { storage.snapshot() }

    /// Recorded messages, oldest first.
    public var messages: [String] { storage.snapshot().map(\.message) }

    /// Events at `level`.
    public func events(at level: LogLevel) -> [LogEvent] {
        storage.snapshot().filter { $0.level == level }
    }

    /// Events in `category`.
    public func events(in category: LogCategory) -> [LogEvent] {
        storage.snapshot().filter { $0.category == category }
    }

    /// `true` when any recorded message contains `fragment`.
    public func containsMessage(_ fragment: String) -> Bool {
        storage.snapshot().contains { $0.message.contains(fragment) }
    }

    /// Discards everything recorded so far.
    public func reset() { storage.clear() }
}
