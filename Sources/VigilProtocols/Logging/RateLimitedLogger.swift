//
//  RateLimitedLogger.swift
//  VigilProtocols
//
//  Synchronous, thread-safe suppression for repeated log sites.
//

#if canImport(os)
import os
#else
import Synchronization
#endif

/// Decorates a logger with a per-call-site event budget.
///
/// The first `limit` events from one level/category/file/line key pass during each window. Later
/// events are counted, and the next event after the window emits one suppression summary before
/// opening a fresh window. Call-site keys keep network-controlled messages from growing the state.
public struct RateLimitedLogger: LoggerProtocol {

    private let base: any LoggerProtocol
    private let clock: any MonotonicClock
    private let storage: Storage

    public init(wrapping base: any LoggerProtocol, limit: Int = 5,
                window: Duration = .seconds(10), clock: any MonotonicClock) {
        self.base = base
        self.clock = clock
        storage = Storage(limit: max(0, limit), window: max(.nanoseconds(1), window))
    }

    public func isEnabled(_ level: LogLevel, _ category: LogCategory) -> Bool {
        base.isEnabled(level, category)
    }

    public func log(_ event: LogEvent) {
        // Never call an arbitrary logger while holding our lock: a base may synchronously fan out
        // to another decorator, and lock composition must not turn logging into a deadlock path.
        for output in storage.accept(event, at: clock.now()) { base.log(output) }
    }
}

private extension RateLimitedLogger {

    struct Key: Hashable {
        var level: LogLevel
        var category: LogCategory
        var file: String
        var line: UInt
    }

    struct Entry {
        var startedAt: MediaInstant
        var emitted: Int
        var suppressed: Int
        var template: LogEvent
    }

    /// The lock owns the mutable dictionary, so this reference is checked `Sendable`: macOS 14 uses
    /// `OSAllocatedUnfairLock`, while Linux CI uses the stdlib's `Synchronization.Mutex`. The latter
    /// is never compiled into the macOS-14 product, where that type is unavailable.
    final class Storage: Sendable {
        private let limit: Int
        private let window: Duration
        #if canImport(os)
        private let entries = OSAllocatedUnfairLock<[Key: Entry]>(initialState: [:])
        #else
        private let entries = Mutex<[Key: Entry]>([:])
        #endif

        init(limit: Int, window: Duration) {
            self.limit = limit
            self.window = window
        }

        func accept(_ event: LogEvent, at now: MediaInstant) -> [LogEvent] {
            entries.withLock { entries in
                let key = Key(level: event.level, category: event.category,
                              file: event.file.description, line: event.line)
                guard var entry = entries[key] else {
                    entries[key] = Entry(startedAt: now, emitted: limit > 0 ? 1 : 0,
                                         suppressed: limit > 0 ? 0 : 1, template: event)
                    return limit > 0 ? [event] : []
                }

                if now - entry.startedAt >= window {
                    var output: [LogEvent] = []
                    if entry.suppressed > 0 {
                        var summary = entry.template
                        summary.message = "\(entry.template.message) — suppressed "
                            + "\(entry.suppressed) similar"
                        summary.metadata["suppressed"] = String(entry.suppressed)
                        output.append(summary)
                    }
                    entries[key] = Entry(startedAt: now, emitted: limit > 0 ? 1 : 0,
                                         suppressed: limit > 0 ? 0 : 1, template: event)
                    if limit > 0 { output.append(event) }
                    return output
                }

                if entry.emitted < limit {
                    entry.emitted += 1
                    entry.template = event
                    entries[key] = entry
                    return [event]
                }
                entry.suppressed += 1
                entry.template = event
                entries[key] = entry
                return []
            }
        }
    }
}
