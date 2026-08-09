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

    /// Created lazily and shared by manual and device-triggered recording for this camera.
    var recordingCoordinator: RecordingCoordinator?

    /// Keeps the compressed stream and pre-roll alive even when no tile currently displays it.
    var isMotionRecordingArmed = false

    /// Keeps this stream at PiP priority even when the main window is closed or occluded.
    var isPictureInPicture = false

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

    /// Audio remains muted until the user explicitly enables this camera.
    var isAudioMuted = true

    /// Becomes true on the first assembled audio buffer and enables the tile speaker action.
    var hasAudio = false

    /// Latest normalized RMS level, sampled at 10 Hz for the tile's two-point meter.
    var audioLevel: Float = 0

    /// The mode the global decode plan granted this camera. Unlike stream quality, this controls
    /// how many frames from that stream enter the decoder.
    var decodeMode: DecodeMode = .full

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

    // MARK: - Transitions

    /// Clears what a new connect attempt invalidates.
    ///
    /// ⚠️ Per **stream**, and the split from `AppSessionModel.beginConnecting()` is the point: that
    /// method also moved the window to the video screen, which is a fact about the application and
    /// must not happen once per camera when sixteen of them start together.
    func beginConnecting() {
        streamState = .resolving
        isReceivingMedia = false
        hasFirstPacket = false
        firstFrameLatency = nil
        retryInSeconds = nil
        attempt = 1
    }

    /// Cancels this stream's tasks, clears its per-session state, and hands back the controller and
    /// the pipeline so the caller can stop them off its own path.
    ///
    /// ⛔ The two objects are returned rather than stopped here, because stopping them is `async`
    /// and takes up to 1.5 s of polite socket teardown. A window that awaited that would freeze on
    /// every disconnect. The caller starts a detached `Task` for it; this method is synchronous so
    /// the state the window reads is already correct when it returns.
    ///
    /// ⚠️ `decodeTask` is dropped, not cancelled. Finishing ``frameContinuation`` ends its
    /// `for await` after the frames already queued, so the pipeline is never torn down under a
    /// half-submitted access unit. Cancelling would do exactly that.
    ///
    /// ⛔ The tile keeps its last picture: nothing here flushes the renderer (R-36, API_CONTRACT
    /// §4.9). A black rectangle where a frozen frame should be is how a stopped stream comes to look
    /// like a broken one.
    @discardableResult
    func teardown() -> (controller: StreamController?, pipeline: DecodePipeline?) {
        eventTask?.cancel()
        eventTask = nil
        tilePolicyTask?.cancel()
        tilePolicyTask = nil
        frameContinuation?.finish()
        frameContinuation = nil
        decodeTask = nil
        let outgoing = (controller: controller, pipeline: pipeline)
        controller = nil
        pipeline = nil
        activeRef = nil
        isReceivingMedia = false
        hasFirstPacket = false
        streamState = .idle
        retryInSeconds = nil
        firstFrameLatency = nil
        attemptStartedAt = nil
        decodeFailures = 0
        droppedByReason.removeAll()
        decodeMode = .full
        audioLevel = 0
        return outgoing
    }

    /// Whether this stream owns anything that has to be stopped.
    var isRunning: Bool { controller != nil || pipeline != nil }

    /// Whether the app is driving this camera at all.
    ///
    /// ⚠️ Wider than ``isRunning`` by one state, and the difference is a tile that narrates. A
    /// stream that is resolving an address has no controller yet, and the cell for it must show
    /// "Connecting…" rather than the *Not connected* card — the card offers to start a session that
    /// is already starting.
    var isActive: Bool { isRunning || streamState != .idle }

    // MARK: - What the tile says

    /// What a tile bound to this camera shows, in the vocabulary the views speak.
    ///
    /// The eleven `StreamState` cases collapse into four, exactly as `LiveConnectionState`
    /// documents: five transient states become one `connecting` phase ladder, and `failed`,
    /// `reconnecting` and `stopped` become `offline` carrying the diagnosis that tells them apart.
    ///
    /// ⚠️ On `CameraStream` and not on `AppSessionModel`, because it is a statement about **one
    /// camera** and a wall of sixteen needs sixteen of them. It read `self.streamState` on the
    /// session object for as long as there was only ever one camera to be wrong about.
    var liveState: LiveConnectionState {
        // ⛔ BEFORE EVERYTHING ELSE. A stopped session reports `StreamState.idle`, which the ladder
        // below reads as "resolving" — so pressing stop put a spinner over a picture that was
        // exactly where the user left it and never resolved, because nothing was connecting. The
        // user's own act is the first thing to check.
        if isPlaybackPaused { return .paused }
        switch streamState {
        case .idle, .resolving:
            return .connecting(.resolving)
        case .connecting:
            return .connecting(.connecting)
        case .authenticating:
            return .connecting(.authenticating)
        case .describing:
            return .connecting(.negotiating)
        case .settingUp:
            return .connecting(.opening)
        case .playing:
            // `isDisplayingPicture`, not `isReceivingMedia`: `Live` is a claim about the screen.
            if isDisplayingPicture { return .live }
            return .connecting(hasFirstPacket ? .waitingForKeyframe : .waitingForVideo)
        case .degraded:
            return .degraded(degradedCause)
        case .reconnecting, .failed, .stopped:
            return .offline(OfflineDetail(attempt: attempt,
                                          retryInSeconds: retryInSeconds,
                                          lastSeen: lastSeen,
                                          isPersistent: attempt >= 5,
                                          diagnosis: diagnosis))
        }
    }

    /// Whether a picture is actually on the glass.
    ///
    /// `TileRenderState.isReceivingFrames` goes true when a sample buffer reaches the display layer
    /// and false again on a flush, which is exactly the fact the status line needs.
    ///
    /// The fallback is deliberate and is the safe direction: with no tile mounted there is no render
    /// state to ask, so we fall back to the assembled-access-unit fact rather than narrating
    /// "connecting" over a stream that is running. A tile that *is* mounted and is not showing
    /// anything is the case worth catching, and this reports it.
    var isDisplayingPicture: Bool {
        renderState?.isReceivingFrames ?? isReceivingMedia
    }

    /// The measured reason the stream is degraded.
    ///
    /// Every case carries a number the user can act on, so this reports whichever measurement is
    /// actually non-zero rather than guessing (UX.md §14.1 rule 4).
    private var degradedCause: DegradedCause {
        if statistics.lossFraction > 0 {
            return .packetLoss(fraction: statistics.lossFraction)
        }
        if statistics.jitterMilliseconds > 0 {
            return .jitter(milliseconds: statistics.jitterMilliseconds)
        }
        return .decodeQueue(frames: statistics.decodeQueueDepth)
    }
}

// MARK: - CameraStreamSet

/// Every camera Vigil has a media path for, keyed by identity. Step 2 of F-LIV-01.
///
/// ⛔ WHY A TYPE RATHER THAN A DICTIONARY ON `AppSessionModel`. Two reasons, and the second is the
/// one that decided it. The filing rule is not `streams[id] = stream`: the app reuses one
/// `CameraStream` when the user switches cameras, so filing has to *remove the entry it was under*
/// before adding the new one, or the map grows a stale key per switch pointing at a stream that is
/// now showing something else. That rule needs tests. And `AppSessionModel` cannot be built in a
/// test — it needs a `CoreDependencies` with a Keychain, an RTSP factory and a lockout governor,
/// none of which the app test target has a double for. A rule that lives here is checkable today;
/// the same rule inlined into the session object would be checkable only on the user's Mac.
///
/// ⚠️ Nothing is removed when a stream stops. A camera that has gone offline keeps its entry,
/// because the offline card is drawn from exactly the state the stopped stream still holds — last
/// seen, attempt count, diagnosis. Entries go when the *camera* goes, which is ``forget(_:)``.
@MainActor
@Observable
final class CameraStreamSet {

    /// The streams, by camera. Read-only from outside: every write goes through the filing rule.
    private(set) var streams: [CameraID: CameraStream] = [:]

    /// Creates an empty set.
    init() {}

    /// The stream for a camera, created and remembered on first ask.
    ///
    /// Idempotent: asking twice for the same camera returns the same object, which is what lets a
    /// tile, the inspector and the recorder all address one media path without any of them owning
    /// it.
    func stream(for camera: Camera) -> CameraStream {
        if let existing = streams[camera.id] {
            // The record may have been edited — a rename, a new port — since the stream was filed.
            existing.camera = camera
            return existing
        }
        let fresh = CameraStream()
        fresh.camera = camera
        streams[camera.id] = fresh
        return fresh
    }

    /// The stream already filed for an identity, or `nil`. Never creates one.
    func stream(for id: CameraID) -> CameraStream? { streams[id] }

    /// Files a stream under whichever camera it is currently pointed at.
    ///
    /// ⚠️ The removal is the point. `AppSessionModel` has one long-lived stream that changes camera
    /// when the user switches, so filing without unfiling would leave the previous camera's key
    /// pointing at a stream that is now showing a different picture — and the *next* thing to ask
    /// the set for that camera would be handed the wrong one.
    ///
    /// A stream with no camera is filed nowhere: an unnamed stream cannot be addressed, and giving
    /// it a key would mean inventing one.
    func file(_ stream: CameraStream) {
        for (id, filed) in streams where filed === stream && id != stream.camera?.id {
            streams.removeValue(forKey: id)
        }
        if let id = stream.camera?.id {
            streams[id] = stream
        }
    }

    /// Drops a camera's stream and hands it back, so the caller can tear its tasks down.
    ///
    /// Returns `nil` when nothing was filed, which is the ordinary case for a camera that was never
    /// connected — deleting one from the library is not an error.
    @discardableResult
    func forget(_ id: CameraID) -> CameraStream? {
        streams.removeValue(forKey: id)
    }

    /// Every filed stream, in no particular order.
    ///
    /// ⚠️ Unordered deliberately: the *stage* decides which camera is in which cell, and a set that
    /// offered an order would invite a caller to trust it.
    var all: [CameraStream] { Array(streams.values) }

    /// How many cameras have a media path. Drives the decoder budget in `F-DEC-06`.
    var count: Int { streams.count }

    /// How many of them are actually being driven — connecting counts, stopped does not.
    ///
    /// This is what a concurrency budget has to count: a stream that is resolving an address is
    /// already holding a socket and is about to hold a decoder, and a budget that only counted
    /// playing streams would let a click storm start sixteen of them at once.
    var activeCount: Int { streams.values.filter(\.isActive).count }
}

#endif  // os(macOS)
