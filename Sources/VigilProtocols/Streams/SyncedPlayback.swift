//
//  SyncedPlayback.swift
//  VigilProtocols
//
//  One virtual playhead in absolute UTC, and the rules that keep several device-side playback
//  sessions on it.
//
//  Implements the decidable half of docs/FEATURES.md F-PLB-05, which that document calls "the
//  hardest feature in the app" and rates High risk. The risk is real and it is worth naming exactly:
//  every camera runs its own playback session against its own clock, Vigil cannot command them in
//  lockstep, and the only lever it has is "seek this one again". So the design is not synchronisation
//  — it is **measurement plus correction**, and everything here is the arithmetic of that.
//
//  ⛔ THE PLAYHEAD IS A TIME, NEVER A FRAME COUNT (acceptance 4). Two cameras recording the same
//  minute at 12 and 25 fps have different frame counts for it, so anything counted rather than
//  timed drifts apart by construction and no correction can fix it — it would be correcting towards
//  the wrong target.
//
//  ⚠️ What this file cannot do: the two criteria that are measurements on real hardware — steady
//  skew ≤ 250 ms on the reference cameras, and four 1080p sessions inside 60 % of the live budget —
//  are facts about devices and a Mac. This provides the number and the decision; whether the number
//  comes out small enough is not something arithmetic can promise.
//

import Foundation

// MARK: - SyncedPlayhead

/// Where the review is, in absolute UTC, and how it is moving.
///
/// Absolute UTC rather than a per-camera offset, because the cameras do not agree: each has its own
/// clock, often minutes out, and `spec-isapi.md`'s device-local quirk means some of them answer in
/// their own zone. One UTC instant is the only thing four devices can be asked about that means the
/// same to all of them; converting into each device's frame is the *seek*'s job, not the playhead's.
public struct SyncedPlayhead: Sendable, Hashable {

    /// The instant under review, in absolute UTC.
    public var instant: Date

    /// Playback speed as a multiplier. `1` is real time; `0` is not a legal value — a stopped
    /// playhead is ``isPaused``, which is a different thing from a rate of nothing.
    public var rate: Double

    /// Whether the review is held.
    public var isPaused: Bool

    public init(instant: Date, rate: Double = 1, isPaused: Bool = false) {
        self.instant = instant
        self.rate = rate > 0 ? rate : 1
        self.isPaused = isPaused
    }

    /// The playhead `seconds` of wall time later, at the current rate.
    ///
    /// A paused playhead does not move, which is what makes pause mean something to every camera at
    /// once: the correction below compares against this value, so a held review does not spend the
    /// pause re-seeking four cameras towards a moving target.
    public func advanced(byWallSeconds seconds: TimeInterval) -> SyncedPlayhead {
        guard !isPaused, seconds > 0 else { return self }
        var moved = self
        moved.instant = instant.addingTimeInterval(seconds * rate)
        return moved
    }
}

// MARK: - PlaybackCorrection

/// What one camera needs doing to stay with the playhead.
public enum PlaybackCorrection: Sendable, Hashable {

    /// Within tolerance. Leave it alone — a re-seek costs a whole RTSP session and five round trips,
    /// so correcting a camera that is 80 ms out would cost more sync than it bought.
    case hold

    /// Drifted past the threshold, or never started. Seek it to this instant.
    case seek(to: Date)

    /// This camera has nothing recorded at the playhead. It shows "No recording at this time" and
    /// rejoins by itself when coverage resumes — acceptance 3 asks for exactly that, and the
    /// rejoining is what makes it automatic rather than a dead tile the user has to poke.
    case awaitCoverage
}

// MARK: - SyncedPlaybackPolicy

/// The rules that keep several playback sessions on one playhead.
///
/// An enum of statics: there is no state here. `SyncedPlaybackPolicy` decides, whatever holds the
/// sessions applies, and a test can put any arrangement of positions and coverage in front of it.
public enum SyncedPlaybackPolicy {

    // MARK: Tuning

    /// The steady-state skew F-PLB-05 acceptance 2 asks for between any two cameras.
    ///
    /// ⚠️ A **target that is measured**, not a value anything here enforces. Nothing in this process
    /// can make a device seek more precisely; what the app can do is report the number honestly and
    /// correct the cameras that fall outside it.
    public static let targetSkew: TimeInterval = 0.25

    /// Beyond this a camera is re-seeked (acceptance 2's 500 ms).
    ///
    /// ⛔ Twice the target, and the gap between the two numbers is the whole of what stops this
    /// thrashing. Correcting at the target would re-seek a camera the moment it reached the figure
    /// the design calls acceptable — five round trips and a second of black to fix 250 ms — and the
    /// next sample would find it out again. Hysteresis is not a refinement here; without it the
    /// feature makes the picture worse than no synchronisation at all.
    public static let reseekThreshold: TimeInterval = 0.5

    /// Four, as the feature's own title says. The cap is the device's, not the Mac's: four
    /// simultaneous playback sessions is already more than several Hikvision models will open.
    public static let maximumCameras = 4

    // MARK: Deciding

    /// What to do about one camera.
    ///
    /// - Parameters:
    ///   - position: where that camera's session actually is, in absolute UTC, or `nil` when it has
    ///     no session yet — which is a seek, not a hold.
    ///   - playhead: where the review is.
    ///   - hasCoverage: whether this camera recorded anything at the playhead. Asked of the
    ///     camera's own index, because coverage is a fact about one device's card.
    public static func correction(position: Date?,
                                  playhead: SyncedPlayhead,
                                  hasCoverage: Bool) -> PlaybackCorrection {
        guard hasCoverage else { return .awaitCoverage }
        guard let position else { return .seek(to: playhead.instant) }
        // ⚠️ Paused is not "no correction". A held review is exactly when a drifted camera should be
        // brought back, because a seek costs the user nothing while nothing is moving — and it is
        // the only moment four cameras can be made to agree precisely.
        let drift = abs(position.timeIntervalSince(playhead.instant))
        guard drift > reseekThreshold else { return .hold }
        return .seek(to: playhead.instant)
    }

    /// The corrections for a whole set, in the order given.
    ///
    /// - Parameter cameras: each camera's current position and whether it has coverage at the
    ///   playhead. Beyond ``maximumCameras`` the extra cameras are told to await coverage rather
    ///   than started: admitting a fifth playback session is how a device stops answering the four
    ///   that were working.
    public static func corrections(
        for cameras: [(position: Date?, hasCoverage: Bool)],
        playhead: SyncedPlayhead
    ) -> [PlaybackCorrection] {
        cameras.enumerated().map { index, camera in
            guard index < maximumCameras else { return .awaitCoverage }
            return correction(position: camera.position,
                              playhead: playhead,
                              hasCoverage: camera.hasCoverage)
        }
    }

    // MARK: Measuring

    /// The widest gap between any two cameras, or `nil` when fewer than two are playing.
    ///
    /// This is acceptance 2's number, and it is deliberately measured **between the cameras** rather
    /// than against the playhead: four sessions each 300 ms behind the playhead are perfectly
    /// synchronised with each other, which is what a person comparing two views actually needs.
    public static func skew(of positions: [Date?]) -> TimeInterval? {
        let known = positions.compactMap { $0 }.map(\.timeIntervalSince1970)
        guard known.count > 1, let low = known.min(), let high = known.max() else { return nil }
        return high - low
    }

    /// Whether a set is inside the target skew. `true` for fewer than two cameras, because one
    /// camera cannot disagree with itself and reporting a failure there would be noise.
    public static func isWithinTarget(_ positions: [Date?]) -> Bool {
        guard let skew = skew(of: positions) else { return true }
        return skew <= targetSkew
    }
}
