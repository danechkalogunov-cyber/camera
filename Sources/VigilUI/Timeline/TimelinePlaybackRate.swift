//
//  TimelinePlaybackRate.swift
//  VigilUI
//
//  The playback speed ladder: the stops the RTSP `Scale:` header offers, the shuttle that `J`/`K`/`L`
//  walk, and the invertible mapping between a stop and a slider position.
//  macOS-only. Implements docs/UX.md §7.5 and docs/FEATURES.md §13.
//
//  Discrete stops, not a continuous rate, because the wire is discrete: `Scale:` is honoured at
//  0.25, 0.5, 1, 2, 4 and 8 forwards and −1, −2, −4, −8 in reverse, and a device asked for 3.7×
//  either rounds silently or refuses. A slider that could express 3.7× would be lying about what the
//  camera can do.
//

#if os(macOS)

import Foundation

// MARK: - TimelinePlaybackRate

/// One stop on the speed ladder.
///
/// Ordered slowest-reverse to fastest-forward so the raw values can drive a slider directly and the
/// shuttle is a ±1 step. `normal` is the identity and is what `K` returns to.
package enum TimelinePlaybackRate: Int, Sendable, Hashable, CaseIterable, Comparable {

    case reverseEight, reverseFour, reverseTwo, reverseOne
    case quarter, half, normal, double, quadruple, octuple

    /// The multiplier the RTSP `Scale:` header carries. Negative for reverse.
    package var scale: Double {
        switch self {
        case .reverseEight: -8
        case .reverseFour: -4
        case .reverseTwo: -2
        case .reverseOne: -1
        case .quarter: 0.25
        case .half: 0.5
        case .normal: 1
        case .double: 2
        case .quadruple: 4
        case .octuple: 8
        }
    }

    /// The readout: `1×`, `¼×`, `−4×`.
    ///
    /// A true minus sign (U+2212), not a hyphen: it aligns with digits in the monospaced face the
    /// transport bar uses, where a hyphen sits high and short. Vulgar fractions for the sub-1×
    /// stops, because `0.25×` in a 46 pt reserved field beside `1×` reads as noise.
    package var label: String {
        switch self {
        case .reverseEight: "\u{2212}8\u{00D7}"
        case .reverseFour: "\u{2212}4\u{00D7}"
        case .reverseTwo: "\u{2212}2\u{00D7}"
        case .reverseOne: "\u{2212}1\u{00D7}"
        case .quarter: "\u{00BC}\u{00D7}"
        case .half: "\u{00BD}\u{00D7}"
        case .normal: "1\u{00D7}"
        case .double: "2\u{00D7}"
        case .quadruple: "4\u{00D7}"
        case .octuple: "8\u{00D7}"
        }
    }

    /// Whether this stop plays backwards.
    package var isReverse: Bool { scale < 0 }

    /// Whether audio is muted at this stop.
    ///
    /// UX.md §7.5: "Above 2× audio mutes automatically". Reverse is always muted — there is no
    /// meaningful way to play audio backwards, and every device that offers reverse video offers no
    /// audio with it.
    package var mutesAudio: Bool { isReverse || scale > 2 }

    /// Whether the decoder is expected to drop non-reference frames at this stop
    /// (docs/FEATURES.md §13: "At speeds > 2× the decoder drops non-reference frames").
    package var dropsNonReferenceFrames: Bool { abs(scale) > 2 }

    /// The forward-only stops, for the speed slider and menu — UX.md §7.5's `0.25, 0.5, 1, 2, 4, 8`.
    ///
    /// Reverse is reached with `J`, not with the slider: a slider spanning −8 to 8 gives 1× a
    /// meaningless centre position and makes the common 1×–2× adjustment a pixel wide.
    package static let forwardStops: [TimelinePlaybackRate] =
        [.quarter, .half, .normal, .double, .quadruple, .octuple]

    /// The shuttle ladder `J`/`L` walk. UX.md §7.5: `−8, −4, −2, −1, then 1, 2, 4, 8`.
    ///
    /// Note the omission of ¼× and ½×: the shuttle is a coarse control and stepping through them on
    /// the way from 1× to −1× would need four presses to reverse.
    package static let shuttleStops: [TimelinePlaybackRate] =
        [.reverseEight, .reverseFour, .reverseTwo, .reverseOne,
         .normal, .double, .quadruple, .octuple]

    package static func < (a: Self, b: Self) -> Bool { a.scale < b.scale }

    // MARK: Stepping

    /// One stop faster on the *forward* ladder, or `self` at the top. `⇧.`
    package var faster: TimelinePlaybackRate {
        Self.step(self, in: Self.forwardStops, by: 1)
    }

    /// One stop slower on the forward ladder, or `self` at the bottom. `⇧,`
    package var slower: TimelinePlaybackRate {
        Self.step(self, in: Self.forwardStops, by: -1)
    }

    /// One stop along the shuttle ladder. `L` is `+1`, `J` is `−1`.
    ///
    /// A rate not on the shuttle ladder (¼× or ½×) enters it at the nearest stop by scale, so
    /// pressing `L` at ½× goes to 2× rather than doing nothing.
    package func shuttled(by delta: Int) -> TimelinePlaybackRate {
        guard let index = Self.shuttleStops.firstIndex(of: self) else {
            let nearest = Self.nearest(toScale: scale, in: Self.shuttleStops)
            return Self.step(nearest, in: Self.shuttleStops, by: delta)
        }
        let moved = min(Self.shuttleStops.count - 1, max(0, index + delta))
        return Self.shuttleStops[moved]
    }

    static func step(_ rate: TimelinePlaybackRate, in ladder: [TimelinePlaybackRate],
                     by delta: Int) -> TimelinePlaybackRate {
        let index = ladder.firstIndex(of: rate) ?? ladder.firstIndex(of: nearest(toScale: rate.scale,
                                                                                in: ladder)) ?? 0
        return ladder[min(ladder.count - 1, max(0, index + delta))]
    }

    /// The stop in `ladder` whose scale is closest to `scale`. Ties go to the slower stop, because
    /// overshooting a speed the user asked for is the more surprising error.
    package static func nearest(toScale scale: Double,
                                in ladder: [TimelinePlaybackRate]) -> TimelinePlaybackRate {
        ladder.min { a, b in
            let da = abs(a.scale - scale)
            let db = abs(b.scale - scale)
            return da == db ? abs(a.scale) < abs(b.scale) : da < db
        } ?? .normal
    }

    // MARK: Slider mapping

    /// This rate's position on the forward slider, 0…1.
    ///
    /// Positional, not proportional to the scale: the six forward stops are placed at equal
    /// intervals, so every one of them is equally easy to hit. A slider proportional to scale would
    /// give ¼×, ½× and 1× the first ninth of its travel and 8× half of it.
    ///
    /// Exactly invertible with ``init(sliderPosition:)`` for every stop — asserted by a test, because
    /// a slider whose knob does not return to where it was put is the most visible kind of broken
    /// control.
    package var sliderPosition: Double {
        let stops = Self.forwardStops
        guard stops.count > 1 else { return 0 }
        guard let index = stops.firstIndex(of: self) else {
            return Self.nearest(toScale: scale, in: stops).sliderPosition
        }
        return Double(index) / Double(stops.count - 1)
    }

    /// The forward stop nearest `position` on a 0…1 slider.
    package init(sliderPosition position: Double) {
        let stops = Self.forwardStops
        guard position.isFinite, stops.count > 1 else {
            self = .normal
            return
        }
        let clamped = min(1, max(0, position))
        let index = Int((clamped * Double(stops.count - 1)).rounded())
        self = stops[min(stops.count - 1, max(0, index))]
    }
}

#endif  // os(macOS)
