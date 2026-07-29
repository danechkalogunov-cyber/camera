//
//  RecordingRenameVerdictTests.swift
//  VigilCoreTests
//
//  The rule that decides whether a failed `.partial` → final rename actually lost anything.
//  Covers the race between `ClipRecorder.closeCurrentSegment` and the library's orphan sweep.
//

#if os(macOS)

import Testing
@testable import VigilCore

// MARK: - RecordingRenameVerdictSuite

/// `FileManager.moveItem` throws the same `NSFileNoSuchFileError` whether the file never moved or
/// somebody else moved it first, so the verdict is read from the disk afterwards rather than from
/// the error. These four cases are the whole rule.
@Suite("RecordingRenameVerdict") struct RecordingRenameVerdictSuite {

    /// The race that produced the bug: the orphan sweep renamed the live `.partial` while
    /// `finishWriting` was still running, so by the time the recorder tried, the file was already at
    /// its destination. Reporting this as a failure recorded the clip against the `.partial` path
    /// and the clip disappeared from the library.
    @Test func renameVerdictTreatsAFileAlreadyAtItsDestinationAsMoved() {
        #expect(RecordingRenameVerdict.after(partialExists: false, finalExists: true)
                == .alreadyThere)
    }

    /// An ordinary failure — a full volume, a permission — leaves the file where it was. The clip
    /// keeps its provisional name, which is honest.
    @Test func renameVerdictKeepsTheProvisionalNameWhenNothingMoved() {
        #expect(RecordingRenameVerdict.after(partialExists: true, finalExists: false)
                == .stillPartial)
    }

    /// ⛔ Both present is **not** `alreadyThere`. Some other clip owns the final name — a previous
    /// segment, or a file the user put there — and this recording is still the `.partial` one.
    /// Claiming the name would attribute a different file to this segment.
    @Test func renameVerdictDoesNotClaimAFinalNameSomethingElseOccupies() {
        #expect(RecordingRenameVerdict.after(partialExists: true, finalExists: true)
                == .stillPartial)
    }

    /// Neither exists: the file was deleted mid-flight. There is nothing to report as a clip, and
    /// the one thing that must not happen is calling this a success.
    @Test func renameVerdictReportsAVanishedFileRatherThanInventingOne() {
        let verdict = RecordingRenameVerdict.after(partialExists: false, finalExists: false)
        #expect(verdict == .vanished)
        #expect(verdict != .alreadyThere)
    }
}

#endif
