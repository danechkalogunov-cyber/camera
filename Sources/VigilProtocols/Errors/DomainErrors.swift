//
//  DomainErrors.swift
//  VigilProtocols
//
//  The eleven domain error enums wrapped by `VigilError`, plus the three payload enums
//  they carry. All of them live here because a domain enum declared in its own module
//  would make `VigilProtocols` import that module, and the package would not link.
//
//  Implements docs/API_CONTRACT.md §3.9 (ruling R-10). The behaviour of every case —
//  code, severity, disposition and copy — is in DiagnosticCodes.swift.
//

// MARK: - Payload enums

// The three enums below are listed by API_CONTRACT §4.3 and §4.6 as belonging to `VigilRTSP` and
// `VigilDiscovery`, but `RTSPError.timeout` and `DiscoveryError.multicastUnavailable` /
// `.budgetExhausted` carry them, and R-10 puts those errors here. Declaring them in their own
// module would reintroduce exactly the import cycle R-10 exists to prevent, so they are declared
// here and those modules use them. See the deviation note in the W1 report.

/// Identifies which RTSP timer expired. One timer per id, at most one outstanding.
public enum RTSPTimerID: Hashable, Sendable {
    /// The keepalive `GET_PARAMETER` / `OPTIONS` cadence.
    case keepalive
    /// A specific request has gone unanswered; `cseq` identifies it.
    case requestTimeout(cseq: UInt32)
    /// `PLAY` succeeded but no RTP arrived. Strongly suggests UDP is being blocked.
    case firstMediaTimeout
    /// No bytes at all on the RTSP socket while playing.
    case dataIdle
    /// The session timeout the device advertised has elapsed without a keepalive.
    case sessionExpiry
    /// Waiting for the response to `TEARDOWN` before closing the socket anyway.
    case teardownGrace
}

/// Why multicast could not be used for discovery.
public enum MulticastUnavailableReason: String, Sendable, Hashable, Codable {
    /// The app is sandboxed without `com.apple.security.network.multicast`.
    case entitlementMissing
    /// macOS has not granted local-network access, or the user denied it.
    case localNetworkDenied
    /// No interface on this machine supports multicast.
    case noMulticastInterface
    /// Joining the group failed at the socket layer.
    case joinFailed
    /// The network dropped the datagrams: sent, but nothing ever came back on any interface.
    case noResponseOnAnyInterface
}

/// Which discovery budget was exhausted. Every one of these is a self-imposed cap that exists so a
/// sweep cannot look like a port scan to the network it is running on.
public enum BudgetKind: String, Sendable, Hashable, Codable {
    case datagrams, tcpConnects, httpRequests, fileDescriptors
}

// MARK: - Transport

/// Socket, TLS and egress-policy failures. Raised by `VigilTransport`, never by a parser.
public enum TransportError: Error, Sendable, Hashable, VigilFailure {
    /// The TCP handshake did not complete inside the connect timeout.
    case connectTimeout
    /// The peer answered with RST: something is listening on the host but not on that port.
    case connectRefused
    /// No route, or ICMP host-unreachable.
    case hostUnreachable
    /// The peer closed a connection we still needed.
    case peerClosed
    /// No bytes arrived within the read-idle window while the stream was supposed to be playing.
    case readIdleTimeout
    /// The TLS handshake failed for a reason that is not a trust decision.
    case tlsFailed(String)
    /// A leaf certificate we have never seen. `fingerprint` is the SHA-256 of the DER, hex.
    case tlsUntrusted(fingerprint: String)
    /// The leaf no longer matches the pin recorded on first use. Treated as hostile.
    case tlsPinMismatch(host: String)
    /// The multicast group could not be joined or the network is dropping the traffic.
    case multicastBlocked
    /// macOS refused local-network access. Nothing on the LAN is reachable until the user grants
    /// it in Privacy & Security.
    case localNetworkDenied
    /// `HostPolicy` refused the destination: Vigil talks to the LAN and nowhere else.
    case egressBlocked(host: String)
    /// Any other socket-layer failure, already reduced to a description string because the
    /// platform error type is not available in the pure layer.
    case network(String)
}

// MARK: - RTSP

/// Failures of the RTSP control plane: framing, status codes, authentication and session state.
public enum RTSPError: Error, Sendable, Hashable, VigilFailure {
    /// The response was not RTSP at all, or its start line did not parse.
    case malformedResponse
    /// The header block exceeded the cap before CRLFCRLF. Hostile or badly broken.
    case headerTooLarge(bytes: Int)
    /// A status we do not know how to act on.
    case unexpectedStatus(code: Int)
    /// 401 with a challenge we have not yet answered. One retry, with credentials.
    case unauthorized
    /// 401 again after we sent credentials: the password is wrong. **Terminal** — see R-25.
    case authRejected
    /// 403. The account exists but is not allowed to stream this channel.
    case accessForbidden
    /// The device demanded credentials and we have none stored for it.
    case credentialsMissing
    /// 405 for a method the session machine needs.
    case methodNotSupported
    /// The SDP described no track Vigil can play.
    case noSuitableTrack
    /// The SDP did not parse. The payload is the offending line or field.
    case sdpParse(String)
    /// 461, or a `Transport` header the device rewrote into something unusable.
    case transportRejected
    /// 454. The session id we hold has been forgotten by the device.
    case sessionNotFound
    /// 404 for the stream path. The channel or stream number is wrong for this firmware.
    case pathNotFound
    /// The `$` interleaved framing lost synchronisation. `recovered` is true when resynchronisation
    /// found the next valid frame without dropping the connection.
    case interleaveDesync(recovered: Bool)
    /// More requests are queued than the device could ever answer.
    case commandQueueOverflow
    /// The redirect chain exceeded its limit.
    case tooManyRedirects
    /// A timer expired. Which one it was decides what the session machine does next.
    case timeout(RTSPTimerID)
}

// MARK: - RTP

/// Depacketization failures. These are **counted, not fatal**: one malformed packet in a stream of
/// thousands must never end a session.
public enum RTPError: Error, Sendable, Hashable, VigilFailure {
    /// Fewer than 12 bytes, so there is not even a fixed header.
    case shortPacket(length: Int)
    /// The version field was not 2.
    case badVersion(UInt8)
    /// The CSRC count promised more bytes than the packet contains.
    case truncatedCSRC
    /// The header-extension length promised more bytes than the packet contains.
    case truncatedExtension
    /// The padding byte claimed more padding than the payload holds.
    case badPaddingLength(UInt8)
    /// A payload type not negotiated in the SDP.
    case unknownPayloadType(UInt8)
    /// An FU-A/FU fragment that does not fit its neighbours: no start, or a start inside a run.
    case badFragment
    /// A STAP-A/AP aggregation whose internal sizes overrun the packet.
    case aggregationOverflow
    /// The reorder buffer filled and `dropped` packets were discarded to make room.
    case jitterBufferOverflow(dropped: Int)
    /// `count` packets are missing from the sequence space and will not be waited for.
    case gap(count: Int)
    /// An SDP `a=rtpmap` encoding Vigil cannot depacketize.
    case unsupportedEncoding(String)
    /// A required `a=fmtp` parameter is absent, so the payload cannot be framed.
    case missingRequiredFmtp(String)
    /// An AAC mode outside the RFC 3640 subset Vigil implements.
    case unsupportedAACMode(String)
    /// The `AudioSpecificConfig` did not parse.
    case malformedAudioConfig(String)
    /// A clock rate of zero or a negative value: every timestamp computed from it would be wrong.
    case invalidClockRate(Int32)
}

// MARK: - Bitstream

/// H.264/H.265 syntax failures. Every one of these describes bytes that came from the network, so
/// each is a value a hostile device could produce deliberately.
public enum BitstreamError: Error, Sendable, Hashable, VigilFailure {
    /// A NAL unit with no bytes at all.
    case emptyNALUnit
    /// A NAL unit larger than the cap. Refused before it is copied.
    case tooLarge(bytes: Int)
    /// The reader ran off the end of the RBSP mid-syntax-element.
    case unexpectedEndOfData(atBit: Int)
    /// An exp-Golomb code with more leading zeros than any legal value can have.
    case malformedExpGolomb(leadingZeros: Int)
    /// A syntax element outside the range the standard allows for it.
    case valueOutOfRange(field: String, value: UInt64)
    /// The NAL type is not the one this parser was asked for.
    case wrongNALType(expected: UInt8, found: UInt8)
    /// `forbidden_zero_bit` was set, which means the byte stream is corrupt by definition.
    case forbiddenBitSet
    /// A temporal id outside `0...6`, or inconsistent with the VPS.
    case invalidTemporalID
    /// A skip count that would move the reader backwards.
    case negativeSkip
    /// Cropping offsets that leave no picture, or that exceed the coded size.
    case invalidCropping
    /// Legal syntax Vigil does not implement (scalable or multiview extensions, for instance).
    case unsupportedSyntax(String)
    /// A profile the hardware decoder will not accept.
    case unsupportedProfile(idc: UInt8)
    /// 4:4:4 or monochrome, which Vigil does not decode.
    case unsupportedChromaFormat(idc: UInt8)
    /// An SEI message whose payload runs past the end of the NAL unit.
    case truncatedSEI
    /// A length-prefixed NAL whose prefix runs past the end of the buffer.
    case truncatedLengthPrefix(atOffset: Int)
    /// An `avcC`/`hvcC` record with a version byte Vigil does not know.
    case unsupportedRecordVersion(UInt8)
    /// `lengthSizeMinusOne` other than 3: Vigil writes and expects 4-byte prefixes throughout.
    case unsupportedLengthSize(UInt8)
    /// A `sprop-parameter-sets` value that is not valid Base64.
    case invalidBase64
    /// No SPS/PPS (or VPS/SPS/PPS) is available yet, so no format can be built. Wait for an IRAP.
    case noParameterSets
}

// MARK: - ISAPI

/// Hikvision control-plane failures, spanning HTTP, authentication and the device's own status
/// documents.
public enum ISAPIError: Error, Sendable, Hashable, VigilFailure {
    /// No usable connection to the device. The payload names what was being attempted.
    case notConnected(String)
    /// The request did not complete inside its budget.
    case timedOut(resource: String, seconds: Double)
    /// The task was cancelled by Vigil, not by the device.
    case cancelled
    /// The response body exceeded the cap for its endpoint and was abandoned unparsed.
    case responseTooLarge(bytes: Int)
    /// 401 after credentials were supplied: the password is wrong. **Terminal** — see R-25.
    case authenticationFailed(username: String)
    /// The device has locked the account after repeated failures. `retryAfter` is its own estimate
    /// in seconds, when it supplies one.
    case accountLocked(retryAfter: Double?)
    /// Vigil's own lockout governor refused to send: `failures` credentialed 401s have already
    /// been seen for this device, and one more could lock the user out of their camera.
    case authBlockedLocally(failures: Int)
    /// The device offered only authentication schemes Vigil does not implement.
    case unsupportedAuthentication(String)
    /// 403: the account is valid but lacks the permission this endpoint needs.
    case insufficientPermission(resource: String)
    /// The camera has never been activated and has no admin password yet.
    case deviceNotActivated
    /// Any other HTTP status.
    case http(status: Int, resource: String)
    /// A `ResponseStatus` document with a device status code and optional sub-status string.
    case device(statusCode: Int, sub: String?)
    /// The endpoint does not exist on this firmware. Cached as a negative capability.
    case notSupported(resource: String)
    /// 404 for a resource that should exist.
    case notFound(resource: String)
    /// The device is busy — usually another client holds the resource.
    case deviceBusy
    /// The change was accepted but needs a reboot before it takes effect.
    case rebootRequired
    /// The XML did not parse, or lacked an element the caller requires.
    case malformedResponse(String)
    /// The `Content-Type` was not what the endpoint promises.
    case unexpectedContentType(expected: String, got: String?)
    /// The multipart alert stream violated its own boundary protocol.
    case multipartProtocolError(String)
    /// The alert stream ended after `afterBytes` bytes.
    case streamEnded(afterBytes: Int)
    /// One multipart part exceeded the per-part cap.
    case partTooLarge(bytes: Int, limit: Int)
    /// `https` was requested on a platform build without TLS support.
    case tlsUnavailableOnThisPlatform
}

// MARK: - Discovery

/// Failures of SADP, WS-Discovery and the subnet sweep.
public enum DiscoveryError: Error, Sendable, Hashable, VigilFailure {
    /// The interface list could not be read.
    case interfaceEnumerationFailed(errno: Int32)
    /// Every interface was loopback, down, or outside the policy.
    case noEligibleInterfaces
    /// The ARP table could not be read, so MAC addresses will be missing.
    case arpReadFailed(errno: Int32)
    /// Multicast is not available; the caller falls back to a unicast sweep.
    case multicastUnavailable(MulticastUnavailableReason)
    /// A discovery socket could not bind its port.
    case channelBindFailed(port: UInt16, String)
    /// The prefix would sweep more hosts than the policy permits.
    case prefixTooWide(bits: UInt8, hostCount: Int)
    /// The probe datagram could not be sent.
    case probeSendFailed
    /// A self-imposed rate or resource budget ran out mid-sweep.
    case budgetExhausted(BudgetKind)
    /// The user stopped the scan.
    case cancelled
}

// MARK: - Decode

/// VideoToolbox and parameter-set failures. `status` values are raw `OSStatus`, kept as `Int32`
/// so this enum stays pure.
public enum DecodeError: Error, Sendable, Hashable, VigilFailure {
    /// Any VideoToolbox status we do not map to a specific case.
    case vt(status: Int32)
    /// `kVTVideoDecoderBadDataErr`. Drop to the next keyframe; do **not** restart the session.
    case badData
    /// `kVTInvalidSessionErr`. Recreate the session and wait for an IDR.
    case invalidSession
    /// `kVTVideoDecoderMalfunctionErr`. Recreate once.
    case malfunction
    /// The stream changed to a format the current session cannot be reconfigured for.
    case formatChangeUnsupported
    /// No hardware decoder for this codec on this machine. Degraded, not fatal.
    case noHardwareDecoder
    /// `DecodeBudget` refused the reservation.
    case budgetDenied(DenialReason)
    /// A frame arrived before any parameter set did.
    case missingParameterSets
    /// A parameter set of zero length, which CoreMedia rejects.
    case emptyParameterSet(index: Int)
    /// More parameter sets than the format description will accept.
    case tooManyParameterSets(count: Int)
    /// `CMVideoFormatDescriptionCreateFromH264ParameterSets` (or the H.265 form) failed.
    case formatDescriptionFailed(status: Int32)
    /// `CMBlockBufferCreateWithMemoryBlock` failed.
    case blockBufferFailed(status: Int32)
    /// `CMSampleBufferCreateReady` failed.
    case sampleBufferFailed(status: Int32)
    /// The pixel-buffer pool could not be created or is exhausted.
    case pixelBufferPoolFailed(status: Int32)
    /// A codec/profile combination Vigil cannot decode on this machine.
    case unsupportedFormat(codec: VideoCodec, detail: String)
}

// MARK: - Render

/// Metal and layer failures. All of them fall back to `AVSampleBufferDisplayLayer` rather than
/// failing a stream.
public enum RenderError: Error, Sendable, Hashable, VigilFailure {
    /// No Metal device. A VM, or a stripped GPU.
    case metalUnavailable
    /// Runtime MSL compilation failed. SwiftPM cannot compile `.metal`, so this is the shipping
    /// path (API_CONTRACT §2 R-38) and its failure must be survivable.
    case shaderCompilationFailed(String)
    /// The render pipeline state could not be built from compiled functions.
    case pipelineCompileFailed(String)
    /// `CVMetalTextureCacheCreate` failed.
    case textureCacheFailed(status: Int32)
    /// A texture could not be created from a pixel buffer.
    case textureCreationFailed
    /// The layer had no drawable this frame. Common under heavy load; skip the frame.
    case drawableUnavailable
    /// The command buffer completed with an error.
    case commandBufferFailed(code: Int, detail: String)
    /// The GPU was removed (eGPU unplugged, or a driver reset).
    case deviceRemoved
    /// A pixel format Vigil has no shader for.
    case unsupportedPixelFormat(UInt32)
    /// A window or tile capture failed.
    case captureFailed(String)
    /// The video-wall atlas would exceed the device's maximum texture size.
    case atlasTooLarge(requested: Resolution, max: Int)
}

// MARK: - Storage

/// `library.json`, `events.json` and the settings documents.
public enum StorageError: Error, Sendable, Hashable, VigilFailure {
    /// The destination is not writable.
    case notWritable(path: String)
    /// The document is present but not valid JSON, or not the shape we expect.
    case corruptDocument(String)
    /// Written by a newer Vigil. The library opens **read-only**; it is never migrated backwards.
    case schemaTooNew(found: Int, supported: Int)
    /// A migration step for this version is missing.
    case missingMigration(from: Int)
    /// The root of the document is not a JSON object.
    case notAnObject
    /// The volume is full. `needBytes` is what the write required.
    case diskFull(needBytes: Int64)
    /// The atomic replace failed, so the previous document is still in place.
    case atomicReplaceFailed
    /// The document exceeded the sanity cap and was not loaded.
    case documentTooLarge(bytes: Int)
}

// MARK: - Credential

/// Keychain failures. `status` values are raw `OSStatus`, kept as `Int32` for purity.
public enum CredentialError: Error, Sendable, Hashable, VigilFailure {
    /// Any Keychain status, with the operation that produced it.
    case keychainStatus(Int32, operation: String)
    /// No item for this reference.
    case notFound
    /// An item already exists for this reference.
    case duplicate
    /// The user dismissed the unlock prompt.
    case userCancelledUnlock
    /// The Keychain is locked and could not be unlocked.
    case keychainLocked
    /// The app is missing the keychain-access-group entitlement.
    case missingEntitlement
    /// The stored item was not the shape Vigil wrote.
    case decodeFailed
}

// MARK: - Recording

/// Clip recording failures.
public enum RecordingError: Error, Sendable, Hashable, VigilFailure {
    /// The first sample handed to the writer was not a keyframe, so the clip would not open.
    case firstSampleNotKeyframe
    /// `AVAssetWriter` reported a failure.
    case writerFailed(String)
    /// The destination folder cannot be written to.
    case destinationUnwritable(path: String)
    /// Free space fell below the reserve while recording.
    case spaceBelowReserve(freeBytes: Int64)
    /// The destination folder disappeared — an unmounted volume, usually.
    case folderUnavailable
    /// The stream's format changed mid-clip; passthrough recording cannot span that.
    case formatChangedMidClip
}
