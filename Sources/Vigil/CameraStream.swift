//
//  CameraStream.swift
//  Vigil
//
//  One camera's live media path and everything the window says about it: the controller, the decode
//  chain, the frame handle a tile attaches to, the counters, and the archive position.
//  macOS-only. Step 1 of F-LIV-01 (`ЧТО-НЕ-СДЕЛАНО` §4) — see the note below.
//
//  ⛔ WHY THIS TYPE EXISTS AT ALL, GIVEN THAT NOTHING YET HOLDS TWO OF THEM.
//
//  `AppSessionModel` owned one camera's stream *and* the application's own state — the connect form,
//  which screen is showing, the Keychain, the defaults — in one object, so "a second camera" and "a
//  second application" were the same edit. That is the whole of why F-LIV-01 reads "трогает
//  `AppSessionModel` целиком": there was no seam to cut along, and the first job is to make one.
//
//  Everything here is per **camera**. Everything left on `AppSessionModel` is per **application**.
//  The line is not a matter of taste: ask "would a second camera need its own copy of this?" and the
//  answer is yes for all of it and no for the six that stayed. A second `StreamController`, a second
//  decode pipeline, a second frame handle for a second tile, a second set of counters for a second
//  status line — none of those can be shared, and every one of them was a stored property on the
//  application object.
//
//  ⚠️ THIS STEP CHANGES NO BEHAVIOUR, DELIBERATELY. `AppSessionModel` keeps every property name it
//  had, as a forwarder onto its one `CameraStream`, so all ~1300 lines of session logic and all 44
//  uses of `session.camera` in the window compile and run exactly as before. A refactor that moves
//  storage and rewrites behaviour in the same commit cannot be reviewed, and cannot be bisected when
//  the picture goes black on hardware nobody here can reach.
//
//  What the remaining steps need from this file: the dictionary (`[CameraID: CameraStream]`), a
//  decoder budget across the set (`F-DEC-06`), tiles binding to `frames` per camera rather than to
//  the window's one handle, and the inspector, timeline, recorder and event feed addressing the
//  selected camera rather than "the one".
//

#if os(macOS)

import Foundation
import Observation

import VigilCore
import VigilISAPI
import VigilProtocols
import VigilRender
import VigilUI
import VigilVideo

// MARK: - CameraStream

/// The live media path for one camera.
///
/// `@Observable` because the window reads these during body evaluation, and `@MainActor` for the
/// same reason `AppSessionModel` is: every property is touched from a SwiftUI body or a callback
/// that arrives on the main actor. The media path itself never touches this object — the decode
/// loop talks to `tileSink`, `telemetry` and `backlog`, all of which are `Sendable` and own their
/// own synchronisation.
@MainActor
@Observable
final class CameraStream {

    // MARK: - Identity

    /// The camera being connected or streamed, or `nil` before the first connect.
    ///
    /// Optional and not a `let`, because a stream exists before its camera does: the connect form
    /// writes `streamState` and the diagnosis while the user is still typing an address.
    var camera: Camera?

    /// Keychain handle of the camera currently being connected, so the first frame can be
    /// remembered against the right item.
    var activeRef: CredentialRef?

    // MARK: - The controller and the decode chain

    /// The live controller, handed to the video screen so it can attach its display layer.
    var controller: StreamController?

    /// The decode pipeline this session feeds. Rebuilt per session, like the controller.
    var pipeline: DecodePipeline?

    var eventTask: Task<Void, Never>?
    var decodeTask: Task<Void, Never>?
    var tilePolicyTask: Task<Void, Never>?
    var frameContinuation: AsyncStream<EncodedFrame>.Continuation?

    /// The attach point this camera's tile registers with.
    ///
    /// ⚠️ One per **camera**, and it used to be one per window — "SwiftUI keeps the tile mounted
    /// across a reconnect, and so must its frame source", which is true and is why it outlives the
    /// controller, but says nothing about there being only one. With N cameras there are N tiles and
    /// N sources, and the tile has to attach to its own.
    let frames = FrameStreamHandle()

    /// The adapter between the decode pipeline and whichever tile is mounted for this camera.
    let tileSink = TileVideoSink()

    /// Counts what this stream is doing, for the inspector and the status bar.
    ///
    /// `Sendable` and lock-guarded, so the detached frame loop and the event loop can both fold into
    /// it without hopping to the main actor.
    let telemetry = StreamStatisticsCollector()

    /// Frames waiting between the network and the decoder. Feeds the inspector's decode queue.
    let backlog = FrameBacklog()

    /// The recorder's inlet into this camera's encoded-frame path.
    let recordingTap = RecordingTap()

    // MARK: - What the window says about it

    /// The controller's last reported state.
    var streamState: StreamState = .idle

    /// Whether any RTP has arrived, which is what separates "no video is arriving" from "waiting
    /// for a keyframe" in the connecting narration.
    var hasFirstPacket: Bool = false

    /// Whether a complete access unit has been assembled.
    ///
    /// ⛔ Not "the user can see the camera", and it must never be what says `Live`: an access unit
    /// that assembled can still fail to decode, and the difference on screen is a black well wearing
    /// a `Live` chip with no narration. ``renderState`` is the authority on pixels.
    var isReceivingMedia: Bool = false

    /// The mounted tile's own render state, or `nil` while no tile is mounted.
    var renderState: TileRenderState?

    /// The negotiated stream format, once the camera has described it.
    var format: StreamFormat?

    var statistics = StreamStatistics()

    /// The named cause of the current failure, in `VigilUI`'s vocabulary.
    var diagnosis: ConnectDiagnosis?

    /// Which reconnect attempt we are on. `1` until the controller says otherwise.
    var attempt: Int = 1

    /// Seconds until the next reconnect, when one is scheduled.
    var retryInSeconds: Int?

    /// When media was last flowing, for the offline card's "Last seen" line.
    var lastSeen: Date?

    /// Time from `start()` to the first assembled access unit. The R1.7 measurement.
    var firstFrameLatency: Duration?

    /// When the current connect attempt began, for the video screen's elapsed counter.
    var attemptStartedAt: Date?

    /// When a keyframe recovery was last forced, so a decoder that keeps asking cannot put the
    /// session into a restart loop.
    var lastRecoveryAt: Date?

    /// Consecutive decode failures reported by the renderer, reset when one triggers a recovery.
    var decodeFailures = 0

    /// Frames dropped, per `FrameDropReason.rawValue`, for this session.
    var droppedByReason: [String: Int] = [:]

    /// The RTSP path the ladder settled on, persisted only once a frame has arrived.
    var resolvedPath: String?

    /// Set by the "Try Port 8554" remedy, and only by it.
    var rtspPort: Int = 554

    // MARK: - Archive playback

    /// Counts archive seeks so a superseded one can stop instead of finishing into a stale session.
    var seekGeneration: UInt64 = 0

    /// When the current archive seek was asked for, so the wait can be measured rather than guessed.
    var seekStartedAt: MediaInstant?

    /// The archive address being played, or `nil` when the picture is live.
    var playback: PlaybackLocator?

    /// How fast the archive is playing, and in which direction.
    var playbackRate: TimelinePlaybackRate = .normal

    /// A paused archive retains its locator but owns no streaming session.
    var isPlaybackPaused = false

    // MARK: - Initialisation

    /// Creates an idle stream with no camera.
    init() {}
}

#endif  // os(macOS)
