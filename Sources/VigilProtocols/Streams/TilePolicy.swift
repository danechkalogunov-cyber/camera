//
//  TilePolicy.swift
//  VigilProtocols
//
//  Axis 1 of the streaming policy: the class A–E table that turns a tile's backing size
//  into a choice of stream, plus the hysteresis that stops it flapping.
//
//  Implements docs/API_CONTRACT.md §2.2 (ruling R-21) and §3.7.
//

// MARK: - Class

/// Tile size class. Axis 1 of the tile policy (API_CONTRACT §2 R-21).
/// The input is the tile's **short edge in backing pixels**.
///
/// Ordering is by declaration, so `a < b < c < d < e` — note that a *smaller* class letter means a
/// *larger* tile. Comparisons exist for table-driven tests and for clamping, never for arithmetic.
public enum TileClass: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// ≥ 1080 px. 1-up, fullscreen, PiP, video wall.
    case a
    /// 480–1079 px. Sub, promoted to main when the sub is visibly soft and budget allows.
    case b
    /// 96–479 px. Sub. The 4×4 case.
    case c
    /// 1–95 px. ISAPI JPEG poll, no decode session at all.
    case d
    /// Hidden, occluded, or the window is minimised.
    case e

    /// Declaration rank, largest tile first. The raw values are letters for the specs and the
    /// diagnostics bundle, so the order is declared here rather than inherited.
    @usableFromInline var rank: Int {
        switch self {
        case .a: 0
        case .b: 1
        case .c: 2
        case .d: 3
        case .e: 4
        }
    }

    /// Lower bound of the class in backing pixels of the tile's short edge, or `nil` for class E,
    /// which is a visibility state and not a size band.
    @inlinable public var shortEdgeFloor: Int? {
        switch self {
        case .a: TilePolicy.classAFloor
        case .b: TilePolicy.classBFloor
        case .c: TilePolicy.classCFloor
        case .d: 1
        case .e: nil
        }
    }

    @inlinable public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

// MARK: - Choice

/// Which stream a tile wants, or none.
public enum StreamChoice: Sendable, Hashable, Codable {
    case stream(StreamQuality)
    /// ISAPI JPEG poll at the given interval. No RTSP session, no decode session, 0 DU.
    case jpegPoll(interval: Duration)
    case none
}

// MARK: - Context

public struct TileContext: Sendable, Hashable {
    /// Backing pixels, i.e. points × `backingScaleFactor`, rounded to integers. Supplied by
    /// `TileRenderState.pixelSize`; never points.
    public var pixelSize: Resolution
    public var isVisible: Bool
    public var isOccluded: Bool
    public var isFocused: Bool
    public var isSidebarThumbnail: Bool
    public var isOffscreenScroll: Bool
    public var isRecording: Bool
    /// Coded height of the device's sub stream, for the class-B promotion test. `nil` when unknown.
    public var subStreamHeight: Int?
    /// Some analog NVR channels have no sub stream.
    public var deviceSupportsSubStream: Bool
    /// The user's per-tile lock. When non-`nil`, automatic switching is disabled for this tile
    /// and the UI shows "Main (locked)".
    public var qualityOverride: StreamQuality?
    public var jpegPollIntervalOverride: Duration?

    public init(pixelSize: Resolution, isVisible: Bool = true, isOccluded: Bool = false,
                isFocused: Bool = false, isSidebarThumbnail: Bool = false,
                isOffscreenScroll: Bool = false, isRecording: Bool = false,
                subStreamHeight: Int? = nil, deviceSupportsSubStream: Bool = true,
                qualityOverride: StreamQuality? = nil, jpegPollIntervalOverride: Duration? = nil) {
        self.pixelSize = pixelSize
        self.isVisible = isVisible
        self.isOccluded = isOccluded
        self.isFocused = isFocused
        self.isSidebarThumbnail = isSidebarThumbnail
        self.isOffscreenScroll = isOffscreenScroll
        self.isRecording = isRecording
        self.subStreamHeight = subStreamHeight
        self.deviceSupportsSubStream = deviceSupportsSubStream
        self.qualityOverride = qualityOverride
        self.jpegPollIntervalOverride = jpegPollIntervalOverride
    }

    /// `min(width, height)` of the backing size — the single input to the class table.
    @inlinable public var shortEdge: Int { pixelSize.shortEdge }
}

// MARK: - Policy

/// The class A–E table, as a pure function. Deterministic, allocation-free, unit-tested on Linux.
public enum TilePolicy {

    public static let dwell: Duration = .milliseconds(750)
    public static let deadBand: Double = 0.15
    /// Class boundaries in backing pixels of the tile's short edge.
    public static let classAFloor = 1080
    public static let classBFloor = 480
    public static let classCFloor = 96
    /// Class-B promotion fires when the sub stream's coded height is below this fraction of the
    /// tile's short edge — i.e. the sub is visibly soft.
    public static let promotionSoftnessRatio = 0.75

    /// JPEG cadence for a class-D stage tile, before the polling-surface scale.
    public static let stagePollInterval: Duration = .seconds(1)
    /// JPEG cadence for a sidebar row thumbnail.
    public static let sidebarPollInterval: Duration = .seconds(5)
    /// JPEG cadence for an offscreen or menu-bar thumbnail.
    public static let offscreenPollInterval: Duration = .seconds(15)

    /// The class this tile falls into right now, with no hysteresis applied — `clearsDeadBand`
    /// and the 750 ms `dwell` are the caller's job.
    ///
    /// Order of precedence, which is not the same as the order of the table:
    /// 1. **Recording wins over everything.** A recording stream is never occlusion-paused and
    ///    never demoted (FEATURES.md F-DEC-06 rule 5), and it records the main stream, so a
    ///    recording tile is class A whatever its size or visibility.
    /// 2. Hidden, occluded or zero-sized ⇒ class E.
    /// 3. Sidebar rows and scrolled-off tiles are JPEG-poll surfaces ⇒ class D, whatever their
    ///    pixel size; they never hold a decode session.
    /// 4. Otherwise the short-edge table.
    ///
    /// `isFocused` deliberately does **not** promote the class: focus is an admission-priority
    /// input (`StreamPriority.focused`), not a size input, and a focused 300 px tile still wants
    /// the sub stream.
    public static func tileClass(for context: TileContext) -> TileClass {
        if context.isRecording { return .a }
        if !context.isVisible || context.isOccluded { return .e }
        if context.isSidebarThumbnail || context.isOffscreenScroll { return .d }

        let edge = context.shortEdge
        if edge >= classAFloor { return .a }
        if edge >= classBFloor { return .b }
        if edge >= classCFloor { return .c }
        if edge >= 1 { return .d }
        return .e
    }

    /// Which stream to pull. Does not consider the decode budget — that is Axis 2.
    ///
    /// A per-tile `qualityOverride` wins for every class that pulls a stream at all, which is what
    /// "Main (locked)" means; it does not resurrect a hidden tile, because pausing an invisible
    /// tile is the other axis and is not the "automatic switching" the lock disables.
    ///
    /// A device with no sub stream (some analog NVR inputs) gets `.main` wherever the table asks
    /// for `.sub`: a stream that does not exist cannot be pulled.
    ///
    /// The `.jpegPoll` interval it returns is the single-surface cadence. A caller that knows how
    /// many surfaces are polling the same device must call `jpegInterval(for:pollingSurfaces:)`
    /// itself, or the device sees one request per second per tile instead of one in total.
    public static func choice(for context: TileContext) -> StreamChoice {
        let tile = tileClass(for: context)
        switch tile {
        case .e:
            return .none
        case .d:
            if let override = context.qualityOverride { return .stream(override) }
            return .jpegPoll(interval: jpegInterval(for: context, pollingSurfaces: 1))
        case .a:
            return .stream(context.qualityOverride ?? .main)
        case .b:
            if let override = context.qualityOverride { return .stream(override) }
            guard context.deviceSupportsSubStream else { return .stream(.main) }
            return .stream(promotesFromSub(context) ? .main : .sub)
        case .c:
            if let override = context.qualityOverride { return .stream(override) }
            return .stream(context.deviceSupportsSubStream ? .sub : .main)
        }
    }

    /// True when the sub stream would be visibly soft in this tile: its coded height is below
    /// `promotionSoftnessRatio` × the tile's short edge. An unknown sub height does **not**
    /// promote — we do not spend a main stream on a guess.
    ///
    /// The budget half of the rule ("…and the decode budget admits it") is Axis 2 and lives in
    /// `DecodeAdmitting`; this function answers only the picture-quality half.
    public static func promotesFromSub(_ context: TileContext) -> Bool {
        guard let height = context.subStreamHeight, height > 0 else { return false }
        return Double(height) < promotionSoftnessRatio * Double(context.shortEdge)
    }

    /// True when a change from `current` to `proposed` clears the 15 % dead band.
    ///
    /// Growing into a larger class requires the short edge to reach **115 %** of that class's
    /// floor; shrinking out of the current class requires it to fall to **85 %** of the current
    /// class's floor. Between those two values — 408…552 px around the 480 px B/C boundary, for
    /// instance — no change is permitted, so a window drag that wobbles across a threshold
    /// produces at most one switch.
    ///
    /// Returns `false` when `current == proposed` (there is nothing to change) and `true` for any
    /// transition involving class E, which is a boolean visibility state with no continuum to
    /// oscillate along; the 750 ms `dwell` is what damps occlusion flapping.
    public static func clearsDeadBand(current: TileClass, proposed: TileClass,
                                      shortEdge: Int) -> Bool {
        guard current != proposed else { return false }
        if current == .e || proposed == .e { return true }

        if proposed < current {
            // Growing: the proposed (larger) class's floor must be exceeded by the dead band.
            guard let floor = proposed.shortEdgeFloor else { return true }
            return Double(shortEdge) >= Double(floor) * (1 + deadBand)
        }
        // Shrinking: the short edge must fall below the current class's floor by the dead band.
        guard let floor = current.shortEdgeFloor else { return true }
        return Double(shortEdge) <= Double(floor) * (1 - deadBand)
    }

    /// JPEG cadence for class D and for non-tile surfaces.
    /// Stage tile 1 s, sidebar row 5 s, offscreen / menu-bar 15 s, scaled by the number of
    /// simultaneously polling surfaces so a device never sees more than 1 request per second.
    ///
    /// A per-tile `jpegPollIntervalOverride` wins outright — it is a user setting, and a user who
    /// asks for a slower poll must not have it sped up by the scaling rule.
    /// `pollingSurfaces` below 1 is treated as 1.
    public static func jpegInterval(for context: TileContext, pollingSurfaces: Int) -> Duration {
        if let override = context.jpegPollIntervalOverride { return override }

        let base: Duration
        if context.isSidebarThumbnail {
            base = sidebarPollInterval
        } else if context.isOffscreenScroll || !context.isVisible || context.isOccluded {
            base = offscreenPollInterval
        } else {
            base = stagePollInterval
        }

        // One request per second across every polling surface on the device: with N surfaces each
        // waiting N seconds, the aggregate rate is 1 Hz however they are phased.
        let aggregateFloor = Duration.seconds(max(1, pollingSurfaces))
        return base > aggregateFloor ? base : aggregateFloor
    }
}

// MARK: - Stateful selection

/// Applies the policy's dead band and dwell time to successive layout measurements.
///
/// Layout is deliberately sampled by the application rather than driving a reconnect directly
/// from every SwiftUI geometry notification.  The selector is value-typed and clock-agnostic so
/// callers can feed a monotonic timestamp and tests never have to sleep.
public struct TilePolicySelector: Sendable {
    public private(set) var tileClass: TileClass?
    public private(set) var choice: StreamChoice?

    private var candidate: (tileClass: TileClass, choice: StreamChoice, since: Duration)?

    public init() {}

    /// Returns a new choice only after it has remained eligible for ``TilePolicy/dwell``.
    /// The first usable measurement is adopted immediately; this avoids adding 750 ms to initial
    /// connection while still damping all subsequent resize-driven changes.
    public mutating func ingest(_ context: TileContext, at now: Duration) -> StreamChoice? {
        let proposedClass = TilePolicy.tileClass(for: context)
        let proposedChoice = TilePolicy.choice(for: context)
        guard let currentClass = tileClass, let currentChoice = choice else {
            tileClass = proposedClass
            choice = proposedChoice
            candidate = nil
            return proposedChoice
        }
        guard proposedChoice != currentChoice else {
            candidate = nil
            return nil
        }
        guard proposedClass == currentClass
                || TilePolicy.clearsDeadBand(current: currentClass, proposed: proposedClass,
                                             shortEdge: context.shortEdge) else {
            candidate = nil
            return nil
        }
        if let candidate,
           candidate.tileClass == proposedClass, candidate.choice == proposedChoice {
            guard now - candidate.since >= TilePolicy.dwell else { return nil }
            tileClass = proposedClass
            choice = proposedChoice
            self.candidate = nil
            return proposedChoice
        }
        candidate = (proposedClass, proposedChoice, now)
        return nil
    }
}
