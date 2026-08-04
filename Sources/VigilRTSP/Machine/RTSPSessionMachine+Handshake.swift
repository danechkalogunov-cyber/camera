//
//  RTSPSessionMachine+Handshake.swift
//  VigilRTSP
//
//  The four requests that open a session: OPTIONS, DESCRIBE, SETUP, PLAY.
//  Split from RTSPSessionMachine.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

import Foundation
import VigilProtocols

// MARK: - The handshake

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension RTSPSessionMachine {

    // MARK: - OPTIONS

    mutating func onOptions(_ response: RTSPResponse, now: MediaInstant) -> [RTSPAction] {
        if let publicValue = response.headers.first("Public") {
            serverPublicMethods = RTSPResponseFields.methods(publicValue)
        }
        keepaliveMethod = chooseKeepaliveMethod()
        guard !isProbe else { return closeNormally() }
        return transition(to: .awaitingDescribe) + describeRequest(now: now)
    }

    /// `GET_PARAMETER` when the device advertises it — the least intrusive keepalive and what every
    /// current Hikvision build wants — then `SET_PARAMETER`, then `OPTIONS`, which RFC 2326 §10.1
    /// permits with a `Session` header and every build accepts.
    func chooseKeepaliveMethod() -> RTSPMethod {
        if serverPublicMethods.contains(.getParameter), !config.closesOnGetParameter {
            return .getParameter
        }
        if serverPublicMethods.contains(.setParameter) { return .setParameter }
        return .options
    }

    // MARK: - DESCRIBE

    mutating func onDescribe(_ response: RTSPResponse, now: MediaInstant) -> [RTSPAction] {
        let parsed: SDPDocument
        do {
            parsed = try SDPParser.parse(response.body)
        } catch {
            return advanceLadderOrFail(error)
        }
        document = parsed

        let contentBase = response.headers.first("Content-Base")
        let contentLocation = response.headers.first("Content-Location")
        aggregateURI = ControlURLResolver.resolve(control: parsed.sessionControl,
                                                  contentBase: contentBase,
                                                  contentLocation: contentLocation,
                                                  requestURI: config.url)
        // Hikvision's session-level `a=control` is the request URI plus a trailing slash, and its
        // own wire trace (docs/spec-rtsp.md §11.1) then sends `PLAY` to the URI *without* the
        // slash. Prefer the verbatim request URI whenever the two differ only by that slash: it is
        // what the device logged at DESCRIBE time, and it keeps the digest URI identical across
        // DESCRIBE, PLAY and TEARDOWN — a mismatch there is a mysterious 401 on PLAY alone.
        let requestForm = config.url.requestLineForm
        if aggregateURI == requestForm + "/" || requestForm == aggregateURI + "/" {
            aggregateURI = requestForm
        }
        var actions = buildTracks(from: parsed, contentBase: contentBase,
                                  contentLocation: contentLocation)
        actions.append(.log(.sdpParsed(trackCount: negotiatedTracks.count,
                                       codecs: negotiatedTracks.map(\.encodingName))))

        let hasVideo = negotiatedTracks.contains { $0.kind == .video && $0.codec?.isVideo == true }
        guard hasVideo else {
            return actions + advanceLadderOrFail(.noSuitableTrack)
        }

        if isProbe {
            // The probe ladder wants the tracks, not a session: report and close cleanly so the
            // driver can cache the winning path and start a real session against it.
            actions += negotiatedTracks.map { RTSPAction.emitTrack($0) }
            return actions + closeNormally()
        }

        setupOrder = Array(negotiatedTracks.indices)
        setupCursor = 0
        return actions + startNextSetup(now: now)
    }

    /// Turns the SDP into tracks, resolving each `a=control` and dropping the ones we cannot use.
    /// A dropped track is a log line, never a failure: an unusable audio track must not cost the
    /// user their video.
    private mutating func buildTracks(from parsed: SDPDocument,
                                      contentBase: String?,
                                      contentLocation: String?) -> [RTSPAction] {
        var actions: [RTSPAction] = []
        var built: [RTSPTrack] = []

        for media in parsed.media {
            guard built.count < config.maxTracks else { break }
            let wanted: Bool = switch media.kind {
            case .video: true
            case .audio: config.setupAudio
            case .application: config.setupMetadataTrack
            }
            guard wanted else {
                actions.append(.log(.trackSkipped(index: media.index, reason: "not requested")))
                continue
            }
            guard media.clockRate > 0 else {
                actions.append(.log(.trackSkipped(index: media.index, reason: "no clock rate")))
                continue
            }
            let codec = media.codec
            if media.kind == .video, codec == nil {
                actions.append(.log(.trackSkipped(index: media.index,
                                                  reason: "unsupported encoding "
                                                      + media.encodingName)))
                continue
            }
            if media.kind == .video, media.packetizationMode == 2 {
                actions.append(.log(.trackSkipped(index: media.index,
                                                  reason: "interleaved packetization mode")))
                continue
            }

            let control: String
            if let raw = media.control, raw != "*" {
                control = ControlURLResolver.resolve(control: raw, contentBase: contentBase,
                                                     contentLocation: contentLocation,
                                                     requestURI: config.url)
            } else {
                control = aggregateURI
            }
            actions.append(.log(.trackControlResolved(index: media.index, uri: control,
                                                      viaBase: contentBase ?? "request-uri")))

            built.append(RTSPTrack(
                id: media.index,
                kind: media.kind,
                codec: codec,
                encodingName: media.encodingName,
                payloadType: media.payloadType,
                clockRate: UInt32(max(media.clockRate, 0)),
                channelCount: media.channels.map(Int.init),
                controlURI: control,
                parameterSets: media.parameterSets,
                fmtpParameters: media.fmtp,
                packetizationMode: media.packetizationMode,
                spropMaxDONDiff: media.spropMaxDONDiff,
                aacConfig: media.aacConfig,
                aacSizeLength: media.fmtp["sizelength"].flatMap(Int.init),
                aacIndexLength: media.fmtp["indexlength"].flatMap(Int.init),
                aacIndexDeltaLength: media.fmtp["indexdeltalength"].flatMap(Int.init),
                hintedDimensions: media.hintedDimensions,
                hintedFramerate: media.framerate,
                bandwidthKbps: media.bandwidthKbps))
        }
        negotiatedTracks = built
        return actions
    }

    // MARK: - SETUP

    private mutating func startNextSetup(now: MediaInstant) -> [RTSPAction] {
        guard setupCursor < setupOrder.count else { return sendPlay(now: now) }
        let index = setupOrder[setupCursor]
        var actions = transition(to: .settingUp(trackIndex: setupCursor, of: setupOrder.count))
        let transport: String
        switch config.transport {
        case .udpUnicast:
            guard let ports = config.udpClientPorts(forTrack: setupCursor) else {
                return actions + terminate(.transportRejected)
            }
            negotiatedTracks[index].clientPorts = ports
            actions.append(.prepareUDP(trackID: negotiatedTracks[index].id, ports: ports))
            transport = "RTP/AVP;unicast;client_port=\(ports.rtp)-\(ports.rtcp)"
        case .tcpInterleaved, .tcpTLS:
            let channels = requestedChannels(forSetupAt: setupCursor)
            // Register before sending: frames can race the SETUP response.
            decoder.registerInterleavedChannels([channels.lowerBound, channels.upperBound])
            transport = "RTP/AVP/TCP;unicast;interleaved=\(channels.lowerBound)-\(channels.upperBound)"
        case .udpMulticast:
            return actions + terminate(.transportRejected)
        }
        actions += request(.setup, uri: negotiatedTracks[index].controlURI,
                           extra: [("Transport", transport)], trackIndex: index, now: now)
        return actions
    }

    mutating func onSetup(_ response: RTSPResponse,
                                  request: PendingRequest,
                                  now: MediaInstant) -> [RTSPAction] {
        var actions: [RTSPAction] = []
        if let value = response.headers.first("Session") {
            let parsed = RTSPResponseFields.session(value)
            sessionIdentifier = parsed.id
            if let seconds = parsed.timeoutSeconds, !didAdoptSessionTimeout {
                // The timeout usually appears only on the first SETUP response: cache it and never
                // let a later omission reset it.
                sessionTimeout = config.clampedSessionTimeout(seconds: seconds)
                didAdoptSessionTimeout = true
            }
            actions.append(.log(.sessionEstablished(id: parsed.id,
                                                    timeoutSeconds: Int(sessionTimeout.seconds))))
        }

        guard let index = request.trackIndex, negotiatedTracks.indices.contains(index) else {
            return actions + terminate(.malformedResponse)
        }
        let requested = requestedChannels(forSetupAt: setupCursor)
        if let transport = response.headers.first("Transport") {
            if config.transport == .udpUnicast {
                negotiatedTracks[index].serverPorts = RTSPResponseFields.udpPortPair(
                    transport, parameter: "server_port")
            } else if let channels = RTSPResponseFields.interleavedChannels(transport) {
                decoder.registerInterleavedChannels([channels.lowerBound, channels.upperBound])
                negotiatedTracks[index].interleavedChannels = channels
            } else {
                negotiatedTracks[index].interleavedChannels = requested
                actions.append(.log(.assumedInterleavedChannels(requested)))
            }
            negotiatedTracks[index].ssrc = RTSPResponseFields.ssrc(transport)
        } else if config.transport != .udpUnicast {
            negotiatedTracks[index].interleavedChannels = requested
            actions.append(.log(.assumedInterleavedChannels(requested)))
        }

        actions.append(.emitTrack(negotiatedTracks[index]))
        setupCursor += 1
        return actions + startNextSetup(now: now)
    }

    private func requestedChannels(forSetupAt cursor: Int) -> ClosedRange<UInt8> {
        let rtp = UInt8(truncatingIfNeeded: 2 * cursor)
        return rtp...(rtp &+ 1)
    }

    // MARK: - PLAY

    mutating func onPlay(_ response: RTSPResponse, now: MediaInstant) -> [RTSPAction] {
        playRangeText = response.headers.first("Range") ?? requestedRangeText
        playScale = response.headers.first("Scale").flatMap(Double.init) ?? requestedScale ?? 1.0
        playRateControlDisabled = SDPText.lowercasedASCII(
            response.headers.first("Rate-Control") ?? "") == "no"
        let entries = RTSPResponseFields.rtpInfo(response.headers.first("RTP-Info"))

        var actions = transition(to: .playing)
        hasPlayed = true

        for (position, track) in negotiatedTracks.enumerated() {
            let entry = matchRTPInfo(entries, track: track, position: position)
            actions.append(.emitTiming(RTSPTrackTiming(
                trackID: track.id,
                clockRate: track.clockRate,
                initialSequence: entry?.seq,
                initialRTPTimestamp: entry?.rtptime,
                absoluteStart: nil,
                scale: playScale,
                isRateControlDisabled: playRateControlDisabled,
                playResponseInstant: now)))
        }

        // Media buffered while PLAY was in flight is released only now, after every timing seed.
        for frame in preplayBuffer {
            actions.append(.emitMedia(channel: frame.channel, payload: frame.payload))
        }
        if !preplayBuffer.isEmpty {
            lastMediaAt = now
            preplayBuffer.removeAll()
        }

        actions.append(.ready(RTSPSessionDescription(
            tracks: negotiatedTracks,
            sessionID: sessionIdentifier ?? "",
            sessionTimeout: sessionTimeout,
            transport: config.transport,
            rangeText: playRangeText,
            scale: playScale,
            isRateControlDisabled: playRateControlDisabled,
            serverPublicMethods: serverPublicMethods,
            sdp: document ?? SDPDocument())))

        if lastMediaAt == nil {
            actions.append(.setTimer(.firstMediaTimeout, deadline: now + config.firstMediaTimeout))
        } else {
            actions.append(.setTimer(.dataIdle, deadline: now + config.dataIdleTimeout))
        }
        actions.append(.setTimer(.keepalive, deadline: now + keepaliveInterval))
        return actions
    }

    /// Matches an `RTP-Info` entry to a track: exact control URI first, then the last path segment
    /// (Hikvision NVRs answer with a **relative** `url=trackID=1`), then positional order when the
    /// entry count matches the track count.
    private func matchRTPInfo(_ entries: [RTSPResponseFields.RTPInfoEntry],
                              track: RTSPTrack,
                              position: Int) -> RTSPResponseFields.RTPInfoEntry? {
        if let exact = entries.first(where: { $0.url == track.controlURI }) { return exact }
        let wanted = RTSPResponseFields.lastPathSegment(track.controlURI)
        if !wanted.isEmpty,
           let loose = entries.first(where: {
               RTSPResponseFields.lastPathSegment($0.url) == wanted
           }) {
            return loose
        }
        guard entries.count == negotiatedTracks.count, entries.indices.contains(position) else {
            return nil
        }
        return entries[position]
    }
}
