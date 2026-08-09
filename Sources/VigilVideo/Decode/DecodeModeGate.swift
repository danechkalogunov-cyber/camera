//
//  DecodeModeGate.swift
//  VigilVideo
//
//  The executable half of F-DEC-06: turn an admitted DecodeMode into a per-frame decision.
//  Kept free of CoreMedia so the policy can be tested without constructing a decoder session.
//

#if os(macOS)

import VigilProtocols

/// Stateful frame admission for one decode pipeline.
///
/// Parameter sets are adopted by ``DecodePipeline`` before this gate runs. Dropping a frame here
/// therefore never loses a newly announced format. Keyframes always pass through the rate cap so a
/// recovery point cannot be delayed to make a numerical ceiling look exact.
package struct DecodeModeGate {
    package private(set) var mode: DecodeMode
    private var lastSubmittedPTS: MediaTimestamp?

    package init(mode: DecodeMode = .full) {
        self.mode = mode
    }

    package mutating func setMode(_ mode: DecodeMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        lastSubmittedPTS = nil
    }

    package mutating func reset() {
        lastSubmittedPTS = nil
    }

    /// Whether a video access unit should enter the CoreMedia/VideoToolbox path.
    package mutating func admits(_ frame: EncodedFrame) -> Bool {
        switch mode {
        case .paused, .jpegPoll:
            return false
        case .keyframesOnly:
            return frame.isKeyframe
        case .trim:
            // `.trim` is a transient pressure mode. Only frames the bitstream layer proved to be
            // disposable may be removed; referenced pictures are never guessed at here.
            return frame.isKeyframe || frame.dropClass == .required
        case .fpsCapped:
            return admitsUnderRateCap(frame)
        case .full:
            return true
        }
    }

    private mutating func admitsUnderRateCap(_ frame: EncodedFrame) -> Bool {
        guard frame.pts.isValid else { return true }
        if frame.isKeyframe {
            lastSubmittedPTS = frame.pts
            return true
        }
        guard let previous = lastSubmittedPTS else {
            lastSubmittedPTS = frame.pts
            return true
        }
        // A seek or a camera timestamp reset starts a new cadence immediately.
        guard frame.pts >= previous else {
            lastSubmittedPTS = frame.pts
            return true
        }
        let elapsed = (frame.pts - previous).seconds
        guard elapsed >= 1.0 / 15.0 else { return false }
        lastSubmittedPTS = frame.pts
        return true
    }
}

#endif  // os(macOS)
