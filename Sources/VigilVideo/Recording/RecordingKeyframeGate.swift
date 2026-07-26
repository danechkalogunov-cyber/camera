//
//  RecordingKeyframeGate.swift
//  VigilVideo
//
//  The rule that decides whether a file opens at all: the first sample written into a passthrough
//  clip must be a keyframe, so everything before the first one is held back.
//  Implements docs/spec-core.md §9.4 and docs/FEATURES.md F-REC-01 acceptance 3.
//
//  Pure arithmetic over an injected `MediaInstant` — no CoreMedia object, no clock read, no I/O — so
//  it is exercised for real on Linux by the shadow harness under scratchpad/shadow-recording. The
//  whole-file `#if os(macOS)` is here only because `VigilVideo` is a macOS-only target
//  (.vigil/IMPL_RULES.md, "Layering").
//

#if os(macOS)

import VigilProtocols

// MARK: - RecordingKeyframeGate

/// Holds samples back until the first keyframe of the clip arrives.
///
/// **Why this is not optional and not a warning.** `AVAssetWriterInput` in passthrough mode accepts
/// whatever it is given. Hand it a P-frame first and it writes a perfectly well-formed MP4 whose
/// first sample references a picture that is not in the file: QuickTime shows a grey rectangle, VLC
/// shows macroblock soup, `AVAssetReader` reports no error, and the writer's `error` is `nil`. There
/// is no status code for this failure — the only defence is not to write the sample.
///
/// **Discarded, not queued.** The frames before the first keyframe are *dropped*, not buffered for
/// later: they decode to nothing without their missing references, so writing them after the
/// keyframe would reintroduce exactly the corruption above, one GOP later. "Buffer until a keyframe
/// arrives" therefore means "buffer the *decision*" — the writer is not even created until the gate
/// opens (see `RecordingClipWriter`), so a stream that never sends an IDR leaves no file behind
/// rather than a broken one.
///
/// A pre-roll buffer (F-REC-02) is the mechanism that makes the wait cost nothing, because it always
/// starts at a keyframe; it is a separate wave and this gate is what it will feed.
package struct RecordingKeyframeGate: Sendable {

    // MARK: - Nested Types

    /// What to do with one candidate sample.
    package enum Decision: Sendable, Hashable {

        /// The gate is open: write it.
        case write

        /// Not a keyframe and the gate is shut. Drop it; keep waiting.
        case holdAwaitingKeyframe

        /// As `holdAwaitingKeyframe`, and the camera should be asked for an IDR. Returned **once**
        /// per wait: `requestKeyframe` maps onto an ISAPI call, and asking once per frame is a
        /// denial of service against the camera dressed up as error handling.
        case holdAndRequestKeyframe

        /// No keyframe within the budget. The recording has failed and the caller must report
        /// `RecordingError.firstSampleNotKeyframe` — never open a file "anyway".
        case giveUp(waitedSeconds: Double)
    }

    // MARK: - Configuration

    /// How long to wait before asking the camera for an IDR. F-REC-01 acceptance 3 says five
    /// seconds; a Hikvision GOP is usually one to two seconds, so most clips never reach it.
    package var requestAfter: Duration

    /// How long to wait before failing. spec-core §9.4 specifies `max(3 × gopSeconds, 6 s)`; the
    /// caller passes that number, and the default here is the ceiling for an unknown GOP.
    package var giveUpAfter: Duration

    // MARK: - State

    /// When the wait started. Injected, never read from a clock (IMPL_RULES, "Determinism").
    package private(set) var openedWaitAt: MediaInstant

    /// True once a keyframe has been seen. From then on every sample is written.
    package private(set) var isOpen: Bool = false

    /// Samples dropped while the gate was shut. Surfaces in `RecordingProgress` so "recording
    /// started but the file is 0 bytes" is a number on screen rather than a mystery.
    package private(set) var heldCount: Int = 0

    /// True once `.holdAndRequestKeyframe` has been returned for this wait.
    package private(set) var didRequestKeyframe: Bool = false

    // MARK: - Initialisation

    /// Builds a shut gate.
    ///
    /// - Parameters:
    ///   - now: The instant the wait starts, from the owner's injected clock.
    ///   - requestAfter: Delay before a keyframe is requested.
    ///   - giveUpAfter: Delay before the recording fails. Must exceed `requestAfter` to be useful;
    ///     a smaller value simply means the request never happens.
    package init(now: MediaInstant,
                 requestAfter: Duration = .seconds(5),
                 giveUpAfter: Duration = .seconds(15)) {
        self.openedWaitAt = now
        self.requestAfter = requestAfter
        self.giveUpAfter = giveUpAfter
    }

    // MARK: - Package API

    /// Decides what happens to one sample.
    ///
    /// - Parameters:
    ///   - isKeyframe: True for an IDR (H.264 type 5) or IRAP (H.265 types 16–23). A sample whose
    ///     keyframe status could not be established must be passed as `false`: guessing `true`
    ///     is the broken-file outcome this type exists to prevent.
    ///   - now: The caller's clock reading for this sample.
    package mutating func admit(isKeyframe: Bool, now: MediaInstant) -> Decision {
        if isOpen { return .write }

        if isKeyframe {
            isOpen = true
            return .write
        }

        heldCount += 1

        let waited = now.seconds(since: openedWaitAt)
        if waited >= giveUpAfter.seconds {
            return .giveUp(waitedSeconds: waited)
        }
        if waited >= requestAfter.seconds, !didRequestKeyframe {
            didRequestKeyframe = true
            return .holdAndRequestKeyframe
        }
        return .holdAwaitingKeyframe
    }

    /// Shuts the gate again for a new segment, and restarts the wait at `now`.
    ///
    /// Every segment of a rotating recording is an independent file, so every segment's first sample
    /// must be a keyframe too. In practice the gate reopens on the very sample that triggered the
    /// rotation, because `RecordingSegmentPlanner` only rotates on a keyframe.
    package mutating func reset(now: MediaInstant) {
        openedWaitAt = now
        isOpen = false
        heldCount = 0
        didRequestKeyframe = false
    }
}

// `Duration.seconds` — the instance property, not the static factory — is `VigilProtocols`'
// own extension in Time/MediaInstant.swift. It is deliberately not redeclared here: a second,
// file-private copy would shadow the shared one and the two could drift.

#endif
