//
//  RecordingTerminationGuard.swift
//  VigilCore
//
//  The one thing standing between "the user pressed ⌘Q" and "the last recording is a garbage file":
//  a registry of live recorders and a bounded wait for every one of them to finish.
//  Implements docs/spec-core.md §9.8 (ordering, the 4 s shutdown budget) and docs/FEATURES.md
//  F-REC-01 acceptance 7.
//
//  **Why this file exists at all.** `AVAssetWriter.finishWriting` is asynchronous: until its handler
//  runs, the `moov` atom — the index without which no player can find a single frame — has not been
//  written. A process that exits before then leaves a file that looks the right size and plays not at
//  all. `exit()` does not wait, `deinit` does not wait, and there is no autorelease-pool trick that
//  makes it wait. The only correct shape is the one AppKit provides: return `.terminateLater` from
//  `applicationShouldTerminate`, do the asynchronous work, then reply.
//

#if os(macOS)

import Foundation
import VigilProtocols

// MARK: - RecordingTerminationOutcome

/// What happened during a bounded shutdown.
public struct RecordingTerminationOutcome: Sendable, Hashable {

    /// Files that were finished cleanly — `moov` written, `.partial` renamed away.
    public var finished: [RecordingSegmentRecord]

    /// Cameras whose recorder did not finish inside the budget.
    ///
    /// Their `.partial` files are still on disk and, because `movieFragmentInterval` defaults to two
    /// seconds, are playable up to their last completed fragment. The launch-time recovery scan
    /// adopts them. This is a bounded, named loss — at most two seconds — and it is the reason
    /// fragmentation is not optional.
    public var timedOut: [CameraID]

    /// True when everything finished cleanly.
    public var isClean: Bool { timedOut.isEmpty }
}

// MARK: - RecordingTerminationGuard

/// Tracks live recorders and finishes them on the way out.
///
/// One per app. Recorders register themselves; the registry holds them **weakly**, so a recorder that
/// is finished and released in the normal course of events does not have to remember to unregister
/// for the app to be able to quit.
public actor RecordingTerminationGuard {

    // MARK: - Nested Types

    /// A weak handle to one recorder.
    ///
    /// A box rather than a `weak var` in a dictionary, because Swift has no weak-value dictionary.
    /// The box is actor-confined and never escapes, which is why it does not need to be `Sendable`.
    private final class WeakRecorder {
        weak var recorder: ClipRecorder?
        let camera: CameraID

        init(recorder: ClipRecorder, camera: CameraID) {
            self.recorder = recorder
            self.camera = camera
        }
    }

    // MARK: - Stored Properties

    private var registry: [ObjectIdentifier: WeakRecorder] = [:]
    private let clock: any MonotonicClock
    private let logger: any LoggerProtocol

    /// True once a shutdown has begun, so a recording cannot be started into a dying process.
    public private(set) var isTerminating = false

    // MARK: - Initialisation

    /// Builds a guard.
    ///
    /// - Parameters:
    ///   - clock: Monotonic time, for the budget. Injected, so a test can expire a budget without
    ///     spending three real seconds per case.
    ///   - logger: Structured logging.
    public init(clock: any MonotonicClock, logger: any LoggerProtocol) {
        self.clock = clock
        self.logger = logger
    }

    // MARK: - Public API

    /// Registers a recorder. Idempotent.
    public func register(_ recorder: ClipRecorder, camera: CameraID) {
        registry[ObjectIdentifier(recorder)] = WeakRecorder(recorder: recorder, camera: camera)
    }

    /// Unregisters a recorder. Optional — the registry holds weak references — but it keeps the
    /// dictionary from accumulating dead entries in a long session.
    public func unregister(_ recorder: ClipRecorder) {
        registry.removeValue(forKey: ObjectIdentifier(recorder))
    }

    /// How many recorders are still alive. Feeds the menu bar extra's global recording count.
    public func activeCount() -> Int {
        registry.values.reduce(into: 0) { count, entry in
            if entry.recorder != nil { count += 1 }
        }
    }

    /// Finishes every live recorder, giving each one at most `budgetPerRecorder`.
    ///
    /// **Call this from `applicationShouldTerminate`**, which must return
    /// `NSApplication.TerminateReply.terminateLater`, and call
    /// `NSApplication.shared.reply(toApplicationShouldTerminate: true)` once this returns.
    /// `VigilCore` does not import AppKit, so those two lines belong to the app target; without them
    /// the process exits while the writers are still flushing and this method never gets to run.
    ///
    /// Recorders are finished **concurrently**, because the budget is per recorder rather than
    /// cumulative: sixteen cameras must not need forty-eight seconds, and the work is a file flush,
    /// not CPU.
    ///
    /// - Parameters:
    ///   - reason: Recorded in each clip. `.appQuitting` by default.
    ///   - budgetPerRecorder: How long to wait for one recorder. Three seconds, per F-REC-01
    ///     acceptance 7.
    /// - Returns: The clean records, and the cameras that ran out of time.
    public func finishAll(reason: RecordingEndReason = .appQuitting,
                          budgetPerRecorder: Duration = .seconds(3))
        -> RecordingTerminationOutcomeTask {
        isTerminating = true
        let live = registry.values.compactMap { entry -> (ClipRecorder, CameraID)? in
            guard let recorder = entry.recorder else { return nil }
            return (recorder, entry.camera)
        }
        registry.removeAll()
        let clock = clock
        let logger = logger

        // Returned as a task rather than awaited here so the caller can hand it straight to the
        // `.terminateLater` reply without this actor staying blocked for the whole budget — a
        // recorder that registers during shutdown would otherwise deadlock behind it.
        return RecordingTerminationOutcomeTask(task: Task {
            await Self.finish(live, reason: reason, budget: budgetPerRecorder,
                              clock: clock, logger: logger)
        })
    }

    /// Abandons every live recorder without waiting for `finishWriting`.
    ///
    /// The last resort, for a shutdown path with no time at all. Every file is left as a fragmented
    /// `.partial`, playable up to its last completed fragment. Prefer `finishAll`: this loses the
    /// `moov` atom on purpose.
    public func abandonAll(reason: RecordingEndReason = .appQuitting) async
        -> [RecordingSegmentRecord] {
        isTerminating = true
        let live = registry.values.compactMap(\.recorder)
        registry.removeAll()
        var records: [RecordingSegmentRecord] = []
        for recorder in live {
            records.append(contentsOf: await recorder.abandon(reason: reason))
        }
        logger.warning(.core, "all recordings abandoned without a clean finish",
                       ["count": String(live.count)])
        return records
    }

    // MARK: - Private Helpers

    /// Finishes every recorder concurrently, each under its own budget.
    private static func finish(_ live: [(ClipRecorder, CameraID)],
                               reason: RecordingEndReason,
                               budget: Duration,
                               clock: any MonotonicClock,
                               logger: any LoggerProtocol) async -> RecordingTerminationOutcome {
        guard !live.isEmpty else {
            return RecordingTerminationOutcome(finished: [], timedOut: [])
        }

        var finished: [RecordingSegmentRecord] = []
        var timedOut: [CameraID] = []

        await withTaskGroup(of: (CameraID, [RecordingSegmentRecord]?).self) { group in
            for (recorder, camera) in live {
                group.addTask {
                    let records = await withinBudget(budget, clock: clock) {
                        await recorder.finish(reason: reason)
                    }
                    return (camera, records)
                }
            }
            for await (camera, records) in group {
                if let records {
                    finished.append(contentsOf: records)
                } else {
                    timedOut.append(camera)
                }
            }
        }

        if timedOut.isEmpty {
            logger.info(.core, "all recordings finished cleanly on quit",
                        ["files": String(finished.count)])
        } else {
            logger.error(.core, "recordings did not finish within the shutdown budget; their "
                         + "fragmented partial files were left in place",
                         ["cameras": timedOut.map(\.short).joined(separator: ","),
                          "budgetSeconds": String(format: "%.1f", budget.seconds)])
        }
        return RecordingTerminationOutcome(finished: finished, timedOut: timedOut)
    }

    /// Runs `work`, returning `nil` if `budget` elapses first.
    ///
    /// The timeout **stops waiting**; it cannot stop the flush. Once `finishWriting` is in flight
    /// there is no API to interrupt it, so cancelling the loser is all that is available — and it is
    /// enough, because the file being flushed is fragmented and therefore already playable. Pretending
    /// otherwise, by calling `abandon()` on a recorder that is mid-finish, would only queue behind the
    /// very work we are trying not to wait for.
    private static func withinBudget(_ budget: Duration, clock: any MonotonicClock,
                                     _ work: @escaping @Sendable () async
                                     -> [RecordingSegmentRecord]) async -> [RecordingSegmentRecord]? {
        await withTaskGroup(of: [RecordingSegmentRecord]?.self) { group in
            group.addTask { await work() }
            group.addTask {
                // A cancelled sleep throws, which is the normal path when the work won the race.
                try? await clock.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - RecordingTerminationOutcomeTask

/// A handle to a shutdown in progress.
///
/// The task is exposed rather than awaited inside the actor so that `finishAll` returns immediately
/// and the guard's executor stays free. The app target awaits `value` and only then replies to
/// `applicationShouldTerminate`.
public struct RecordingTerminationOutcomeTask: Sendable {

    private let task: Task<RecordingTerminationOutcome, Never>

    init(task: Task<RecordingTerminationOutcome, Never>) {
        self.task = task
    }

    /// The outcome, once every recorder has finished or run out of time.
    public var value: RecordingTerminationOutcome {
        get async { await task.value }
    }
}

#endif
