//
//  PipelineHarness.swift
//  VigilTestKit
//
//  Wires SyntheticRTSPServer ↔ RTSPSessionMachine ↔ RTPTrackReceiver over an in-memory wire and a
//  virtual clock. Nothing is stubbed on the client side: the real state machine authenticates, the
//  real SDP parser reads the real SDP, and the real depacketizer consumes bytes generated to
//  RFC 6184 / RFC 7798. What comes out the far end is compared against the camera's ground truth.
//  Implements docs/ARCHITECTURE.md §10.2 (`PipelineHarness`).
//

import Foundation
import VigilProtocols
import VigilRTP
import VigilRTSP

// MARK: - Harness

/// Drives the whole pure pipeline from synthetic bytes, on a virtual clock.
public struct PipelineHarness {

    // MARK: Configuration

    private let profile: SyntheticCameraProfile
    private let host: String
    private let logger: RecordingLogger

    // MARK: Parties

    private var server: SyntheticRTSPServer
    private var machine: RTSPSessionMachine
    private var receiver: RTPTrackReceiver?

    // MARK: Wire

    /// Bytes the client wrote that the camera has not consumed yet.
    private var clientToServer = Data()

    /// Bytes the camera wrote that the client has not read yet.
    private var serverToClient: [UInt8] = []

    /// Index into the hostile-split size cycle.
    private var splitCursor = 0

    /// Virtual nanoseconds since the run started.
    private var nowNanos: UInt64 = 0

    /// `true` once ``start()`` has driven the machine's first step.
    private var started = false

    // MARK: Accumulated results

    private var report = HarnessReport()
    private var pendingTiming: RTSPTrackTimingSeed?
    private var timers: [RTSPTimerID: MediaInstant] = [:]
    private var firstFrameNanos: UInt64?

    // MARK: Init

    /// Creates a harness for `profile`.
    ///
    /// - Parameters:
    ///   - host: the address written into the client's RTSP URL and the camera's SDP. Never
    ///     resolved; nothing here opens a socket.
    ///   - logger: captures whatever the client logs, for assertions that have no other trace.
    public init(profile: SyntheticCameraProfile, host: String = "192.0.2.10",
                logger: RecordingLogger = RecordingLogger()) {
        self.profile = profile
        self.host = host
        self.logger = logger
        server = SyntheticRTSPServer(profile: profile, host: host)

        let text = "rtsp://\(host)\(profile.streamPath)"
        // A URL this fixture builds itself cannot be malformed; the fallback keeps the initialiser
        // total rather than force-unwrapping, which the pure layer forbids outright.
        let url = RTSPURL(string: text) ?? RTSPURL(string: "rtsp://\(host)/") ?? .fallback
        var config = RTSPSessionConfig(url: url)
        config.transport = .tcpInterleaved
        config.isTLS = false
        config.allowBasicOverPlaintext = true
        config.closesOnGetParameter = !profile.supportsGetParameter

        let credential = profile.authMode.requiresCredential
            ? Credential(account: profile.username, secret: profile.password)
            : nil
        machine = RTSPSessionMachine(config: config, credential: credential,
                                     random: SplitMix64RandomSource(seed: profile.seed &+ 0x1F),
                                     now: MediaInstant.zero)
        report.groundTruth = server.groundTruth
    }

    // MARK: Running

    /// Runs until `frames` access units have been delivered, the session fails, or `virtualTimeout`
    /// of virtual time elapses.
    ///
    /// - Parameter stepNanos: how far the virtual clock moves per iteration. One millisecond is
    ///   fine grained enough for a 30 fps stream and coarse enough that a ten-minute soak is
    ///   600 000 iterations rather than 600 million.
    @discardableResult
    public mutating func run(untilFrames frames: Int,
                             virtualTimeout: Duration = .seconds(30),
                             stepNanos: UInt64 = 1_000_000) -> HarnessReport {
        drive(untilFrames: frames, limitNanos: nanoseconds(of: virtualTimeout),
              stepNanos: Swift.max(stepNanos, 1))
    }

    /// Runs for a fixed span of virtual time regardless of how many frames arrive. Used for loss,
    /// degradation and soak tests, where the interesting quantity is what happened over a period.
    @discardableResult
    public mutating func run(forVirtualTime span: Duration,
                             stepNanos: UInt64 = 1_000_000) -> HarnessReport {
        drive(untilFrames: Int.max, limitNanos: nanoseconds(of: span),
              stepNanos: Swift.max(stepNanos, 1))
    }

    /// The report as it stands, without running further.
    public var currentReport: HarnessReport { finishedReport() }

    // MARK: The loop

    private mutating func drive(untilFrames target: Int, limitNanos: UInt64,
                                stepNanos: UInt64) -> HarnessReport {
        start()
        let deadline = nowNanos &+ limitNanos
        while nowNanos < deadline, report.frames.count < target, report.failure == nil,
              !report.transportClosed {
            nowNanos &+= stepNanos
            let media = server.tick(nowNanos: nowNanos)
            if !media.isEmpty { serverToClient.append(contentsOf: media) }
            pump()
            fireDueTimers()
            tickReceiver()
        }
        return finishedReport()
    }

    /// Opens the session: the machine believes a transport just connected, then is told to start.
    ///
    /// `transportReady` alone produces nothing — it only resets per-connection nonce state — so the
    /// `.start` command is what actually puts OPTIONS on the wire. That is the driver's job in
    /// production and the harness's job here.
    private mutating func start() {
        guard !started else { return }
        started = true
        apply(machine.transportReady(isTLS: false, now: instant))
        apply(machine.handle(.start, now: instant))
        apply(machine.step(now: instant))
        pump()
    }

    /// Moves bytes in both directions until neither side has anything more to say.
    ///
    /// Bounded: each side can legitimately answer the other, but a fixture and a client that keep
    /// answering each other forever is a bug, and a bounded loop turns it into a failed assertion
    /// instead of a hung test run.
    private mutating func pump() {
        var iterations = 0
        var steppedWithoutWork = false
        while iterations < 512 {
            iterations += 1
            var didWork = false

            if !clientToServer.isEmpty {
                let outgoing = clientToServer
                clientToServer = Data()
                let answer = server.ingest(outgoing)
                if !answer.isEmpty { serverToClient.append(contentsOf: answer) }
                didWork = true
            }

            report.peakBufferedBytes = Swift.max(report.peakBufferedBytes, serverToClient.count)

            if !serverToClient.isEmpty, report.failure == nil {
                let size = Swift.min(readSize(), serverToClient.count)
                let chunk = Array(serverToClient[0..<size])
                serverToClient.removeFirst(size)
                apply(machine.ingest(chunk, now: instant))
                didWork = true
            }

            // With both directions idle, give the machine a chance to start whatever it queued
            // while a request was outstanding. Doing this only once per quiet period keeps the
            // loop from spinning on a machine that has nothing to do.
            if !didWork {
                if steppedWithoutWork { break }
                steppedWithoutWork = true
                let actions = machine.step(now: instant)
                if actions.isEmpty { break }
                apply(actions)
            } else {
                steppedWithoutWork = false
            }
        }
    }

    /// How many bytes the client is allowed to read at once, per the transport-shape quirks.
    private mutating func readSize() -> Int {
        if let drip = profile.quirks.slowDripBytes { return drip }
        if profile.quirks.contains(.splitAtHostileOffsets) {
            // Sizes chosen to land inside the status line, across the header terminator and across
            // the four-byte `$` interleave header rather than on any natural boundary.
            let cycle = [1, 3, 2, 7, 5, 4, 11]
            let size = cycle[splitCursor % cycle.count]
            splitCursor += 1
            return size
        }
        return Int.max
    }

    /// Fires every timer whose deadline has passed, most overdue first.
    private mutating func fireDueTimers() {
        let due = timers.filter { $0.value.nanoseconds <= instant.nanoseconds }
        guard !due.isEmpty else { return }
        for (id, _) in due.sorted(by: { $0.value.nanoseconds < $1.value.nanoseconds }) {
            timers[id] = nil
            apply(machine.timerFired(id, now: instant))
        }
        pump()
    }

    /// Gives the RTP receiver its timer slice, so buffer drains and statistics windows advance.
    private mutating func tickReceiver() {
        guard var active = receiver else { return }
        let result = active.tick(instant)
        receiver = active
        absorb(result)
    }

    // MARK: Actions

    /// Records one action name, keeping the trace bounded.
    ///
    /// `setTimer(dataIdle)` fires on every media arrival, so an uncapped trace would grow linearly
    /// with packet count and the harness would be the thing with unbounded growth in a test whose
    /// job is to prove there is none. The most recent entries are the ones a failure needs.
    private mutating func trace(_ entry: String) {
        report.actionTrace.append(entry)
        if report.actionTrace.count > 4_096 {
            report.actionTrace.removeFirst(report.actionTrace.count - 4_096)
        }
    }

    private mutating func apply(_ actions: [RTSPAction]) {
        for action in actions {
            switch action {
            case let .send(data):
                trace("send(\(data.count))")
                clientToServer.append(data)

            case let .sendInterleaved(channel, payload):
                trace("sendInterleaved(\(channel))")
                var framed = Data([0x24, channel])
                let length = UInt16(clamping: payload.count)
                framed.append(UInt8(truncatingIfNeeded: length >> 8))
                framed.append(UInt8(truncatingIfNeeded: length))
                framed.append(payload)
                clientToServer.append(framed)

            case let .setTimer(id, deadline):
                trace("setTimer(\(id))")
                timers[id] = deadline

            case let .cancelTimer(id):
                trace("cancelTimer(\(id))")
                timers[id] = nil

            case .emitTrack:
                trace("emitTrack")
                makeReceiverIfNeeded()

            case let .emitTiming(timing):
                trace("emitTiming")
                pendingTiming = RTSPTrackTimingSeed(
                    clockRate: timing.clockRate,
                    initialSequence: timing.initialSequence,
                    initialRTPTimestamp: timing.initialRTPTimestamp,
                    absoluteStart: timing.absoluteStart,
                    scale: timing.scale,
                    isRateControlDisabled: timing.isRateControlDisabled,
                    playResponseInstant: timing.playResponseInstant
                )
                applyPendingTiming()

            case let .emitMedia(channel, payload):
                deliverMedia(channel: channel, payload: payload)

            case .ready:
                trace("ready")
                makeReceiverIfNeeded()
                applyPendingTiming()

            case let .stateChanged(state):
                trace("state(\(state))")

            case let .log(event):
                trace("log(\(event))")

            case let .setReadBackpressure(paused):
                trace("backpressure(\(paused))")

            case let .fail(error):
                trace("fail(\(error))")
                report.failure = error

            case let .closeTransport(reason):
                trace("close(\(reason))")
                report.transportClosed = true

            case let .reconnect(url, _):
                trace("reconnect(\(url.host))")
            }
        }
    }

    // MARK: Media path

    /// Hands one interleaved payload to the RTP receiver.
    ///
    /// The even channel carries RTP and the odd one RTCP, per RFC 2326 §10.12. A payload on any
    /// other channel is counted in the trace and dropped, which is what a client should do.
    private mutating func deliverMedia(channel: UInt8, payload: Data) {
        makeReceiverIfNeeded()
        applyPendingTiming()
        guard var active = receiver else {
            trace("mediaBeforeTrack(\(channel))")
            return
        }
        let result: RTPIngestResult
        if channel % 2 == 0 {
            result = active.ingestRTP(payload, at: instant)
        } else {
            result = active.ingestRTCP(payload, at: instant)
        }
        receiver = active
        absorb(result)
    }

    /// Records frames and events from one receiver result, and answers any outbound RTCP.
    private mutating func absorb(_ result: RTPIngestResult) {
        if !result.frames.isEmpty, firstFrameNanos == nil {
            firstFrameNanos = nowNanos
        }
        report.frames.append(contentsOf: result.frames)
        report.events.append(contentsOf: result.events)
        // Outbound RTCP goes back through the session machine rather than straight onto the wire,
        // so the `$` framing under test is the real one and not the harness's own.
        for payload in result.outboundRTCP {
            apply(machine.handle(.sendRTCP(channel: server.videoChannel &+ 1, payload: payload),
                                 now: instant))
        }
    }

    /// Builds the RTP receiver from the SDP the camera advertised.
    ///
    /// This is the "six-line adapter" API_CONTRACT §4.4 says lives in the fixture on Linux: it turns
    /// an `SDPMediaDescription` into an `RTPTrackFormat` so `VigilRTP` never has to know about RTSP.
    /// Doing it by re-parsing the advertised SDP rather than reading it out of the session machine
    /// keeps the fixture independent of the machine's track representation, and exercises the real
    /// SDP parser on the real bytes into the bargain.
    private mutating func makeReceiverIfNeeded() {
        guard receiver == nil, report.setupFailure == nil else { return }
        let document: SDPDocument
        do {
            document = try SDPParser.parse(Data(server.advertisedSDP.utf8))
        } catch {
            report.setupFailure = "SDP parse failed: \(error)"
            return
        }
        guard let video = document.media.first(where: { $0.kind == .video }) else {
            report.setupFailure = "advertised SDP has no video media description"
            return
        }
        let format: RTPTrackFormat
        do {
            format = try RTPTrackFormat(payloadType: video.payloadType,
                                        encodingName: video.encodingName,
                                        clockRate: video.clockRate,
                                        channels: video.channels,
                                        fmtp: video.fmtp,
                                        parameterSets: video.parameterSets)
        } catch {
            report.setupFailure = "RTPTrackFormat rejected the SDP media description: \(error)"
            return
        }
        // TCP interleaved cannot reorder, so `.passthrough` is right — except when the fixture is
        // deliberately reordering to exercise the buffer, which no real TCP path would do.
        let mode: ReorderBuffer.Mode = profile.quirks.reorderWindow == nil ? .passthrough : .adaptive
        do {
            receiver = try RTPTrackReceiver(format: format, reorderMode: mode, latency: .balanced,
                                            cname: "vigil-testkit@\(host)", startTime: instant)
        } catch {
            report.setupFailure = "RTPTrackReceiver could not be created: \(error)"
        }
    }

    /// Seeds the receiver with RTP-Info once both the receiver and the timing exist.
    private mutating func applyPendingTiming() {
        guard let timing = pendingTiming, var active = receiver else { return }
        active.seed(timing)
        receiver = active
        pendingTiming = nil
    }

    // MARK: Finishing

    private func finishedReport() -> HarnessReport {
        var out = report
        out.groundTruth = server.groundTruth
        out.requests = server.receivedRequests
        out.serverState = server.state
        out.challengeCount = server.challengeCount
        out.authenticatedRequestCount = server.authenticatedRequestCount
        out.credentialRejections = server.rejections
        out.logEvents = logger.events
        out.virtualElapsed = .nanoseconds(Int64(clamping: nowNanos))
        out.timeToFirstFrame = firstFrameNanos.map { .nanoseconds(Int64(clamping: $0)) }
        return out
    }

    /// The current virtual instant.
    private var instant: MediaInstant { MediaInstant(nanoseconds: Int64(clamping: nowNanos)) }

    /// Whole nanoseconds in `duration`, saturating rather than trapping.
    private func nanoseconds(of duration: Duration) -> UInt64 {
        let parts = duration.components
        let total = Double(parts.seconds) * 1_000_000_000
            + Double(parts.attoseconds) / 1_000_000_000
        return total <= 0 ? 0 : UInt64(Swift.min(total, 9.0e18))
    }
}

// MARK: - URL fallback

private extension RTSPURL {

    /// A last-resort URL used only if the fixture's own well-formed string failed to parse, which
    /// would itself be a bug worth surfacing as a failed connection rather than a crash.
    static var fallback: RTSPURL {
        RTSPURL(scheme: "rtsp", host: "127.0.0.1", port: 554, path: "/", query: nil)
    }
}
