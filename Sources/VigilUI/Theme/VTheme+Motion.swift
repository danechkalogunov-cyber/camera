//
//  VTheme+Motion.swift
//  VigilUI
//
//  Six springs, four curves, three repeaters, the timing constants, and the central reduceMotion
//  resolution so no call site has to branch on accessibility itself.
//  macOS-only. See docs/DESIGN.md §7 and docs/API_CONTRACT.md §4.11.
//

#if os(macOS)

import SwiftUI

// MARK: - Springs

extension VTheme.Motion {

    /// `spring(0.22, 0.86)` — 0.5 % overshoot, settles in ~0.30 s.
    ///
    /// Hover, press, toggle, checkbox, dot state, chip appear, icon swap.
    /// Equivalent to `.spring(duration: 0.22, bounce: 0.14)`.
    public static let micro = Animation.spring(response: 0.22, dampingFraction: 0.86,
                                               blendDuration: 0)

    /// `spring(0.34, 0.82)` — 1.1 % overshoot, settles in ~0.50 s. **The default.**
    ///
    /// Sidebar and inspector reveal, popover, layout change, tab switch, row insert.
    /// Equivalent to `.spring(duration: 0.34, bounce: 0.18)`.
    public static let standard = Animation.spring(response: 0.34, dampingFraction: 0.82,
                                                  blendDuration: 0)

    /// `spring(0.50, 0.70)` — 4.6 % overshoot, settles in ~0.95 s.
    ///
    /// Reserved for exactly three things: tile → fullscreen, cinema enter and exit, and the
    /// video-wall handoff. Using it anywhere else makes the app feel slow (§7.1).
    public static let expressive = Animation.spring(response: 0.50, dampingFraction: 0.70,
                                                    blendDuration: 0)

    /// `spring(0.16, 1.00)` — critically damped, no overshoot, settles in ~0.22 s.
    ///
    /// Segmented thumb, keycap depress, PTZ nudge, stepper, sort-arrow flip.
    public static let snap = Animation.spring(response: 0.16, dampingFraction: 1.00,
                                              blendDuration: 0)

    /// `spring(0.42, 0.95, blend 0.10)` — settles in ~0.55 s.
    ///
    /// Anything the user was dragging and let go of: timeline pan and zoom, digital-zoom settle,
    /// the mosaic divider, scroll-to-item. The blend duration is what makes the hand-off from a
    /// 1:1 drag to the settle invisible.
    public static let glide = Animation.spring(response: 0.42, dampingFraction: 0.95,
                                               blendDuration: 0.10)

    /// `spring(0.30, 0.62)` — 8.4 % overshoot, settles in ~0.70 s.
    ///
    /// Rejection and limit feedback **only**: a PTZ head at a mechanical limit, the timeline at
    /// 00:00, an invalid drop. Bounce that is not a rejection is bounce for its own sake (P5).
    public static let rubber = Animation.spring(response: 0.30, dampingFraction: 0.62,
                                                blendDuration: 0)
}

// MARK: - Curves

extension VTheme.Motion {

    /// 180 ms. Entrance opacity, blur-in, scrim in, chrome reveal.
    public static let fadeIn = Animation.timingCurve(0.00, 0.00, 0.20, 1.00, duration: 0.18)

    /// 120 ms. Exit opacity, chrome dismiss, scrim out. **Exits are always faster than entrances.**
    public static let fadeOut = Animation.timingCurve(0.40, 0.00, 1.00, 1.00, duration: 0.12)

    /// 240 ms. First-frame reveal, appearance switch, thumbnail replace, patrol advance.
    public static let crossfade = Animation.easeInOut(duration: 0.24)

    /// 280 ms. Emphasised decelerate for non-spring position moves: toast slide, banner drop.
    public static let emphasized = Animation.timingCurve(0.32, 0.72, 0.00, 1.00, duration: 0.28)
}

// MARK: - Repeaters

extension VTheme.Motion {

    /// A 2 s full cycle. The live-dot pulse and the recording border.
    ///
    /// ⛔ Driven by the **single** window-wide pulse clock published as `\.vPulsePhase`, never by
    /// sixteen independent `PhaseAnimator`s: unison is the difference between a professional
    /// cockpit and a Christmas tree, and the budget allows four animation drivers window-wide
    /// (§7.5, §7.9).
    public static let breathe = Animation.easeInOut(duration: 1.0)
        .repeatForever(autoreverses: true)

    /// A 1.15 s sweep. The skeleton shimmer, driven by one `TimelineView` for the whole window.
    public static let shimmer = Animation.linear(duration: 1.15)
        .repeatForever(autoreverses: false)

    /// A 0.9 s rotation. The reconnect ring and every indeterminate progress ring.
    public static let spin = Animation.linear(duration: 0.90)
        .repeatForever(autoreverses: false)

    /// 200 ms linear. A sparkline path interpolation — linear because the data arrives at a fixed
    /// 1 Hz and any easing reads as jitter (§7.4 #32).
    public static let sparkline = Animation.linear(duration: 0.20)
}

// MARK: - Timing constants

extension VTheme.Motion {

    /// The delays and dwell times that are not themselves animations (§7.2).
    @MainActor
    public enum Delay {

        /// 0 s. Hover chrome appears immediately.
        public static let hoverIn: Double = 0

        /// 0.26 s. Hover chrome lingers, so moving between two buttons in a tile toolbar does not
        /// flicker.
        public static let hoverOut: Double = 0.26

        /// 0.018 s per item in a staggered entrance.
        public static let stagger: Double = 0.018

        /// 12 items. After the twelfth, remaining items all use the twelfth delay (216 ms), which
        /// is also the cap on simultaneous entrance springs (§7.8, §7.9).
        public static let staggerCap: Int = 12

        /// 0.50 s. Hover to tooltip.
        public static let tooltip: Double = 0.50

        /// 0.08 s. A press visual is held at least this long even on a fast click, so a click is
        /// always *seen*.
        public static let pressMin: Double = 0.08

        /// 1.20 s. Optimistic UI reverts and shows an error if the device has not confirmed.
        public static let optimisticTimeout: Double = 1.20

        /// 2.50 s. Cinema-mode chrome auto-hide.
        public static let idleChromeHide: Double = 2.50

        /// 0.22 s. If the first frame arrives sooner, the skeleton is still shown this long, which
        /// prevents a flash.
        public static let skeletonMin: Double = 0.22

        /// 0.12 s. The cross-fade that replaces every geometry change under reduced motion.
        public static let reducedCrossfade: Double = 0.12

        /// 1.5 s. The debounce before a degraded banner is allowed to appear (§7.4 #39).
        public static let degradedDebounce: Double = 1.5

        /// 4 s, or 6 s when the toast carries an action. `.error` toasts never auto-dismiss.
        public static let toastDwell: Double = 4

        /// See ``toastDwell``.
        public static let toastDwellWithAction: Double = 6
    }
}

// MARK: - reduceMotion resolution

extension VTheme.Motion {

    /// The reduced-motion cross-fade: 120 ms, used wherever a position or scale change has to
    /// become an opacity change (§7.10 rule 2).
    public static let reducedFallback = Animation.easeInOut(duration: Delay.reducedCrossfade)

    /// Resolves a motion token against the user's reduced-motion setting.
    ///
    /// This is the whole point of the token layer for motion: a call site asks for the animation it
    /// wants and gets the accessible one automatically, so no view has to remember to branch and no
    /// view can forget (§7.10).
    ///
    ///     withAnimation(VTheme.Motion.resolved(.standard, reduced: !motionEnabled)) { … }
    ///
    /// - Parameters:
    ///   - token: the animation the interaction is specified with.
    ///   - reduced: `true` when `\.vMotionEnabled` is false — that is, when
    ///     `accessibilityReduceMotion` is on, `accessibilityPrefersCrossFadeTransitions` is on, or
    ///     `VMotionGovernor` has reached tier T3 (§7.9).
    ///   - fallback: what to use instead. The default is the 120 ms cross-fade; pass `nil` only for
    ///     motion that must stop dead, and prefer ``resolvedLoop(_:reduced:)`` for that.
    /// - Returns: `token` when motion is allowed, otherwise `fallback`.
    /// The default `fallback` is spelled as a literal rather than as ``reducedFallback`` so that
    /// this signature matches API_CONTRACT.md §4.11 exactly; the two are the same 120 ms curve.
    public static func resolved(_ token: Animation,
                                reduced: Bool,
                                fallback: Animation? = .easeInOut(duration: 0.12)) -> Animation? {
        reduced ? fallback : token
    }

    /// Resolves a **looping** token: `breathe`, `shimmer`, `spin`.
    ///
    /// Continuous motion stops entirely under reduced motion — it does not slow down and it does
    /// not cross-fade (§7.10 rule 3). The caller is then obliged by rule 1 to keep showing the
    /// state statically: a pulse becomes a static dot, never nothing, and a wait longer than 3 s
    /// gains a text narration.
    ///
    /// - Returns: `token`, or `nil` when motion is reduced.
    public static func resolvedLoop(_ token: Animation, reduced: Bool) -> Animation? {
        reduced ? nil : token
    }

    /// Resolves a token for motion that is the **user's own movement** — timeline snapping, drag
    /// tracking, digital zoom, scrolling.
    ///
    /// Functional motion is kept under reduced motion (§7.10 rule 4), so this returns the token
    /// unchanged. It exists so that the choice is visible in the diff rather than looking like a
    /// call site that forgot to resolve.
    public static func functional(_ token: Animation) -> Animation? {
        token
    }

    /// The entrance delay for the item at `index` in a staggered list.
    ///
    /// Capped at ``Delay/staggerCap``: items past the twelfth all share the 216 ms delay, which
    /// keeps the total entrance under the 220 ms budget and the number of concurrent springs
    /// within the window-wide limit of 24 (§7.8, §7.9). Negative indices clamp to 0.
    public static func stagger(_ index: Int) -> Double {
        Double(min(max(index, 0), Delay.staggerCap)) * Delay.stagger
    }

    /// The entrance delay for the item at `index`, or 0 when motion is reduced or the governor has
    /// reached tier T1, where stagger is the first thing dropped (§7.9).
    public static func stagger(_ index: Int, reduced: Bool) -> Double {
        reduced ? 0 : stagger(index)
    }
}

#endif  // os(macOS)
