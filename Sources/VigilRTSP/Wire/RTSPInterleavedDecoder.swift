//
//  RTSPInterleavedDecoder.swift
//  VigilRTSP
//
//  The `$`-framing codec: one incremental decoder that demultiplexes interleaved RTP/RTCP frames
//  from RTSP messages arriving on the same socket, and resynchronises after corruption instead of
//  desynchronising forever.
//  Implements docs/spec-rtsp.md §4.3, §4.4, §5.2, §5.4 and §5.5.
//

import Foundation
import VigilProtocols

// MARK: - Statistics

/// Counters the session machine folds into `RTSPSessionStatistics` and the diagnostics pane shows.
/// Every tolerated deviation is counted: a stream that "works" while emitting 40 resyncs a minute
/// is a broken stream, and the only way to know is to have counted.
public struct RTSPInterleavedStatistics: Sendable, Hashable {

    /// Complete RTSP messages (responses and server requests) decoded.
    public var messagesDecoded = 0

    /// Interleaved frames emitted, excluding zero-length ones.
    public var interleavedFramesDecoded = 0

    /// Total payload bytes emitted, excluding the 4-byte framing headers.
    public var interleavedBytes: UInt64 = 0

    /// Frames whose length field was zero. Legal, useless, and seen on one DVR build.
    public var emptyFramesDropped = 0

    /// Times the decoder entered resynchronisation.
    public var resyncEvents = 0

    /// Bytes thrown away while resynchronising.
    public var bytesDiscardedByResync: UInt64 = 0

    /// Lines terminated by a bare LF rather than CRLF.
    public var toleratedBareLF = 0

    /// Header lines with no colon, skipped rather than fatal.
    public var malformedHeaderLines = 0

    /// `$` frames accepted **inside** a header block (docs/spec-rtsp.md §5.4).
    public var midHeaderInterleavedFrames = 0

    /// Header lines folded into their predecessor (obs-fold).
    public var foldedHeaderLines = 0

    /// Builds an all-zero counter set.
    public init() {}
}

// MARK: - RTSPInterleavedDecoder

/// Incremental, split-invariant decoder for the byte stream of an RTSP/TCP connection.
///
/// The connection carries three kinds of unit, interleaved arbitrarily: `$` media frames, responses
/// to our requests, and server-originated requests. At a **unit boundary** the two are told apart
/// by one byte — `0x24` cannot start an RTSP start line, since it is neither `R` nor a token
/// character. Inside a body there is no ambiguity either, because a body is consumed as an exact
/// opaque byte count and **never scanned for `$`**; that is what stops a `$` inside an SDP payload
/// from being mistaken for a frame header. Inside a *header block* the ambiguity is real — two
/// Hikvision firmware families emit a frame between header lines when a PLAY response races the
/// first RTP packet — and is settled by the plausibility gate of §5.4.
///
/// Feeding the same byte stream in any chunking produces an identical sequence of `RTSPIncoming`
/// values; the decoder never blocks, never copies an incomplete unit, and never throws. An
/// unrecoverable framing violation is latched into `failure` and every later `ingest` returns `[]`.
public struct RTSPInterleavedDecoder: Sendable {

    // MARK: Limits

    /// Every bound the decoder enforces. These are security limits, not tuning knobs: each one
    /// caps memory a hostile or broken device could make us allocate.
    public struct Limits: Sendable, Hashable {

        /// Maximum bytes before the start line's terminator.
        public var maxStartLineBytes = 4_096

        /// Maximum bytes in one header line, after unfolding.
        public var maxHeaderLineBytes = 8_192

        /// Maximum total header-block bytes.
        public var maxHeaderBlockBytes = 32_768

        /// Maximum header fields in one message.
        public var maxHeaderCount = 128

        /// Maximum `Content-Length` we will accept, 256 KiB.
        public var maxBodyBytes = 262_144

        /// High-water mark for buffered-but-undecodable bytes, 2 MiB.
        public var maxBufferedBytes = 2_097_152

        /// Protocol ceiling for one interleaved payload.
        public var maxInterleavedPayload = 65_535

        /// How many consecutive plausible frames a resync candidate must produce.
        public var resyncChainDepth = 2

        /// Maximum bytes discarded in one resynchronisation episode, 128 KiB.
        public var maxResyncScanBytes = 131_072

        /// Builds the default limits of docs/spec-rtsp.md §17.
        public init() {}
    }

    // MARK: Phase

    private enum Phase: Equatable {
        case atBoundary
        case interleavedPayload(channel: UInt8, need: Int)
        case headers
        case body(need: Int)
        case resynchronizing
        case failed
    }

    /// Accumulated state of the message currently being decoded.
    private struct Accumulator {
        var startLine = ""
        var fields: [(name: String, value: String)] = []
        var headerBytes = 0
    }

    // MARK: Stored Properties

    private let limits: Limits
    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var phase = Phase.atBoundary
    private var message = Accumulator()
    private var registeredChannels: Set<UInt8> = []
    private var resyncScanned = 0

    /// The framing failure that ended this decoder, or `nil` while it is healthy. Terminal.
    public private(set) var failure: RTSPError?

    /// Running counters.
    public private(set) var statistics = RTSPInterleavedStatistics()

    // MARK: Initialisation

    /// Builds a decoder with the given limits.
    public init(limits: Limits = .init()) {
        self.limits = limits
    }

    // MARK: Public API

    /// Declares the interleaved channels the peer may legally use.
    ///
    /// Registration happens **before** the corresponding `SETUP` is sent, never after the response:
    /// a mid-session SETUP of a third track can race the first frames on its channel, and a frame
    /// on an unregistered channel triggers a resynchronisation.
    public mutating func registerInterleavedChannels(_ channels: Set<UInt8>) {
        registeredChannels.formUnion(channels)
    }

    /// Channels currently accepted.
    public var interleavedChannels: Set<UInt8> { registeredChannels }

    /// Bytes buffered but not yet decodable.
    public var bufferedByteCount: Int { buffer.count - readIndex }

    /// True while the decoder is scanning for the next valid unit boundary.
    public var isResynchronizing: Bool { phase == .resynchronizing }

    /// Appends `bytes` and drains every complete unit.
    ///
    /// Never throws and never partially emits: a unit appears in the result only once all of its
    /// bytes have arrived. After a terminal failure the result is always empty — check `failure`.
    public mutating func ingest(_ bytes: some Collection<UInt8>) -> [RTSPIncoming] {
        guard failure == nil else { return [] }
        buffer.append(contentsOf: bytes)
        var out: [RTSPIncoming] = []
        drain(into: &out)
        compact()
        if failure == nil, bufferedByteCount > limits.maxBufferedBytes {
            fail(.headerTooLarge(bytes: bufferedByteCount))
        }
        return out
    }

    // MARK: - Decode loop

    private mutating func drain(into out: inout [RTSPIncoming]) {
        while failure == nil {
            switch phase {
            case .failed:
                return

            case .atBoundary:
                skipPadding()
                guard let first = peek(0) else { return }
                if first == 0x24 {
                    guard available >= 4 else { return }
                    guard let channel = peek(1), let high = peek(2), let low = peek(3) else { return }
                    let length = Int(high) << 8 | Int(low)
                    guard registeredChannels.contains(channel) else {
                        beginResync()
                        continue
                    }
                    consume(4)
                    if length == 0 {
                        statistics.emptyFramesDropped += 1
                        continue
                    }
                    phase = .interleavedPayload(channel: channel, need: length)
                } else {
                    message = Accumulator()
                    phase = .headers
                }

            case let .interleavedPayload(channel, need):
                guard available >= need else { return }
                out.append(.interleaved(channel: channel, payload: Data(take(need))))
                statistics.interleavedFramesDecoded += 1
                statistics.interleavedBytes += UInt64(need)
                phase = .atBoundary

            case .headers:
                guard decodeHeaderLines(into: &out) else { return }

            case let .body(need):
                guard available >= need else { return }
                let body = Data(take(need))
                emitMessage(body: body, into: &out)
                phase = .atBoundary

            case .resynchronizing:
                guard resynchronize() else { return }
            }
        }
    }

    // MARK: - Header block

    /// Consumes header lines until the block ends. Returns `false` when it needs more bytes.
    private mutating func decodeHeaderLines(into out: inout [RTSPIncoming]) -> Bool {
        while true {
            if peek(0) == 0x24 {
                switch interleavedFrameAtLineBoundary() {
                case .needsMoreBytes:
                    return false
                case let .frame(channel, payload):
                    out.append(.interleaved(channel: channel, payload: payload))
                    statistics.interleavedFramesDecoded += 1
                    statistics.interleavedBytes += UInt64(payload.count)
                    statistics.midHeaderInterleavedFrames += 1
                    continue
                case .notAFrame:
                    break                   // Fall through: treat it as an ordinary header line.
                }
            }

            guard let line = readLine() else {
                let limit = message.startLine.isEmpty ? limits.maxStartLineBytes
                                                      : limits.maxHeaderLineBytes
                if available > limit { fail(.headerTooLarge(bytes: available)) }
                return false
            }

            if message.startLine.isEmpty {
                guard isPlausibleStartLine(line) else {
                    beginResync()
                    return true
                }
                message.startLine = line
                continue
            }

            if line.isEmpty {
                return finishHeaderBlock(into: &out)
            }

            message.headerBytes += line.utf8.count + 2
            guard message.headerBytes <= limits.maxHeaderBlockBytes,
                  message.fields.count < limits.maxHeaderCount else {
                fail(.headerTooLarge(bytes: message.headerBytes))
                return true
            }

            if let first = line.first, first == " " || first == "\t" {
                if message.fields.isEmpty {
                    statistics.malformedHeaderLines += 1      // A fold with nothing to fold into.
                } else {
                    statistics.foldedHeaderLines += 1
                    message.fields[message.fields.count - 1].value += " " + SDPText.trimmedOWS(line)
                }
                continue
            }

            guard let (name, value) = SDPText.splitOnce(line, separator: ":") else {
                statistics.malformedHeaderLines += 1          // Hikvision has leaked SDP in here.
                continue
            }
            message.fields.append((SDPText.trimmedOWS(name), SDPText.trimmedOWS(value)))
        }
    }

    /// Decides the body length and either emits the message or waits for its body.
    /// Returns `false` only when more bytes are needed.
    private mutating func finishHeaderBlock(into out: inout [RTSPIncoming]) -> Bool {
        let headers = RTSPHeaders(message.fields.map { ($0.name, $0.value) })
        switch bodyLength(headers) {
        case let .failure(error):
            fail(error)
            return true
        case let .success(need):
            if need == 0 {
                emitMessage(body: Data(), into: &out)
                phase = .atBoundary
            } else {
                phase = .body(need: need)
            }
            return true
        }
    }

    /// `Content-Length`, validated. Absent means zero, except on a successful SDP response where
    /// its absence is unrecoverable: there is no "read to end of connection" mode on a connection
    /// that also carries interleaved media.
    private func bodyLength(_ headers: RTSPHeaders) -> Result<Int, RTSPError> {
        let values = headers.all("Content-Length")
        guard !values.isEmpty else {
            let contentType = headers.first("Content-Type").map(SDPText.lowercasedASCII) ?? ""
            if contentType.hasPrefix("application/sdp"), isSuccessResponse {
                return .failure(.malformedResponse)
            }
            return .success(0)
        }
        guard Set(values).count == 1, let length = Int(SDPText.trimmedOWS(values[0])),
              length >= 0 else {
            return .failure(.malformedResponse)
        }
        guard length <= limits.maxBodyBytes else {
            return .failure(.headerTooLarge(bytes: length))
        }
        return .success(length)
    }

    /// True when the accumulated start line is a 2xx status line.
    private var isSuccessResponse: Bool {
        guard let status = RTSPStartLine.status(of: message.startLine) else { return false }
        return (200...299).contains(status)
    }

    /// Builds the `RTSPIncoming` for the accumulated message. A start line we cannot classify is
    /// dropped rather than guessed at; it cannot happen, because `isPlausibleStartLine` already
    /// accepted it, but dropping is the safe branch.
    private mutating func emitMessage(body: Data, into out: inout [RTSPIncoming]) {
        let headers = RTSPHeaders(message.fields.map { ($0.name, $0.value) })
        let cseq = headers.first("CSeq").flatMap { UInt32(SDPText.trimmedOWS($0)) }
        if let (status, reason) = RTSPStartLine.response(message.startLine) {
            out.append(.response(RTSPResponse(status: RTSPStatus(rawValue: status),
                                              reasonPhrase: reason,
                                              headers: headers,
                                              body: body,
                                              cseq: cseq)))
            statistics.messagesDecoded += 1
        } else if let (method, uri) = RTSPStartLine.request(message.startLine) {
            out.append(.request(RTSPRequest(method: method,
                                            uri: uri,
                                            headers: headers,
                                            body: body,
                                            cseq: cseq ?? 0)))
            statistics.messagesDecoded += 1
        }
        message = Accumulator()
    }

    /// Accepts a status line, a request line, or a request line whose method we do not implement
    /// (which we answer with `501` rather than dropping the connection).
    private func isPlausibleStartLine(_ line: String) -> Bool {
        RTSPStartLine.response(line) != nil || RTSPStartLine.request(line) != nil
    }

    // MARK: - Interleaved frames inside a header block

    private enum LineBoundaryFrame {
        case frame(channel: UInt8, payload: Data)
        case notAFrame
        case needsMoreBytes
    }

    /// The §5.4 plausibility gate. **Every** condition is required, because a false positive here
    /// swallows part of a header block: a registered channel, a sane length, the whole frame
    /// present, and an RTP/RTCP version field of 2 in the first payload byte.
    private mutating func interleavedFrameAtLineBoundary() -> LineBoundaryFrame {
        guard available >= 4 else { return .needsMoreBytes }
        guard let channel = peek(1), let high = peek(2), let low = peek(3) else {
            return .needsMoreBytes
        }
        guard registeredChannels.contains(channel) else { return .notAFrame }
        let length = Int(high) << 8 | Int(low)
        guard length >= 4, length <= limits.maxInterleavedPayload else { return .notAFrame }
        guard available >= 4 + length else { return .needsMoreBytes }
        guard let versionByte = peek(4), versionByte >> 6 == 2 else { return .notAFrame }
        consume(4)
        return .frame(channel: channel, payload: Data(take(length)))
    }

    // MARK: - Resynchronisation

    private mutating func beginResync() {
        statistics.resyncEvents += 1
        resyncScanned = 0
        phase = .resynchronizing
    }

    /// Scans forward one byte at a time for the lowest offset that starts either a plausible chain
    /// of interleaved frames or an RTSP status line. Returns `false` when it needs more bytes.
    ///
    /// Chain validation to depth 2 makes a false positive require two independent 4-byte
    /// coincidences plus a valid RTP version field; on random data that is below 2⁻⁴⁰ per offset.
    private mutating func resynchronize() -> Bool {
        while true {
            guard resyncScanned <= limits.maxResyncScanBytes else {
                fail(.interleaveDesync(recovered: false))
                return true
            }
            guard available > 0 else { return false }
            switch candidate(atOffset: 0) {
            case .accept:
                phase = .atBoundary
                return true
            case .reject:
                consume(1)
                resyncScanned += 1
                statistics.bytesDiscardedByResync += 1
            case .undecided:
                return false
            }
        }
    }

    private enum CandidateVerdict { case accept, reject, undecided }

    private func candidate(atOffset offset: Int) -> CandidateVerdict {
        if peek(offset) == 0x24 {
            switch frameChain(atOffset: offset, depth: limits.resyncChainDepth) {
            case .accept: return .accept
            case .undecided: return .undecided
            case .reject: break
            }
        }
        return statusLineCandidate(atOffset: offset)
    }

    /// The seven bytes `RTSP/1.` — hoisted out of the scan loop, which runs per discarded byte.
    private static let statusLinePrefix: [UInt8] = Array("RTSP/1.".utf8)

    /// `RTSP/1.<digit><space>` — the only byte sequence that can start a message we care about.
    private func statusLineCandidate(atOffset offset: Int) -> CandidateVerdict {
        let prefix = Self.statusLinePrefix
        guard available - offset >= prefix.count + 2 else {
            // The tail could still become a status line once more bytes arrive.
            for (index, byte) in prefix.enumerated() where offset + index < available {
                if peek(offset + index) != byte { return .reject }
            }
            return .undecided
        }
        for (index, byte) in prefix.enumerated() where peek(offset + index) != byte {
            return .reject
        }
        guard let digit = peek(offset + prefix.count), digit >= 0x30, digit <= 0x39,
              peek(offset + prefix.count + 1) == 0x20 else { return .reject }
        return .accept
    }

    /// Validates up to `depth` consecutive interleaved frames starting at `offset`. A frame whose
    /// header validates but whose payload runs past the buffer end terminates the chain
    /// successfully — that is the "partial but consistent" tail of §5.5.
    private func frameChain(atOffset offset: Int, depth: Int) -> CandidateVerdict {
        var cursor = offset
        var validated = 0
        while validated < depth {
            guard available - cursor >= 4 else { return .undecided }
            guard peek(cursor) == 0x24, let channel = peek(cursor + 1),
                  let high = peek(cursor + 2), let low = peek(cursor + 3) else { return .reject }
            guard registeredChannels.contains(channel) else { return .reject }
            let length = Int(high) << 8 | Int(low)
            guard length >= 4, length <= limits.maxInterleavedPayload else { return .reject }
            guard let versionByte = peek(cursor + 4) else { return .undecided }
            guard versionByte >> 6 == 2 else { return .reject }
            cursor += 4 + length
            validated += 1
            if cursor >= available { return .accept }       // Consistent up to the buffer end.
        }
        return .accept
    }

    // MARK: - Buffer primitives

    private var available: Int { buffer.count - readIndex }

    private func peek(_ offset: Int) -> UInt8? {
        let index = readIndex + offset
        guard index >= 0, index < buffer.count else { return nil }
        return buffer[index]
    }

    private mutating func consume(_ count: Int) {
        readIndex = min(readIndex + count, buffer.count)
    }

    private mutating func take(_ count: Int) -> ArraySlice<UInt8> {
        let start = readIndex
        let end = min(start + count, buffer.count)
        readIndex = end
        return buffer[start..<end]
    }

    /// Skips CR and LF padding between messages; some firmware pads, and RFC 2326 allows it.
    private mutating func skipPadding() {
        while let byte = peek(0), byte == 0x0D || byte == 0x0A {
            consume(1)
        }
    }

    /// Reads one CRLF- or LF-terminated line, or `nil` when the terminator has not arrived.
    /// The returned string never contains the terminator.
    private mutating func readLine() -> String? {
        var index = readIndex
        while index < buffer.count {
            if buffer[index] == 0x0A {
                var end = index
                if end > readIndex, buffer[end - 1] == 0x0D {
                    end -= 1
                } else {
                    statistics.toleratedBareLF += 1
                }
                let line = String(decoding: buffer[readIndex..<end], as: UTF8.self)
                readIndex = index + 1
                return line
            }
            index += 1
        }
        return nil
    }

    /// Drops consumed bytes once they dominate the buffer. Compacting on every call would be
    /// quadratic; compacting never would grow the buffer without bound on a long-lived session.
    private mutating func compact() {
        guard readIndex > 0, readIndex > 8_192 || readIndex > buffer.count / 2 else { return }
        buffer.removeFirst(readIndex)
        readIndex = 0
    }

    private mutating func fail(_ error: RTSPError) {
        failure = error
        phase = .failed
    }
}

// MARK: - Start-line parsing

/// Start-line recognisers, lenient in exactly the ways real firmware needs (docs/spec-rtsp.md §3.1):
/// multiple spaces between tokens, a missing reason phrase, and `RTSP/1.1` in a status line.
enum RTSPStartLine {

    /// `RTSP/1.0 200 OK` → `(200, "OK")`. `nil` when the line is not a status line.
    static func response(_ line: String) -> (status: Int, reason: String)? {
        guard line.hasPrefix("RTSP/1.") else { return nil }
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count >= 2, fields[1].count == 3, let status = Int(fields[1]),
              status >= 100, status <= 999 else { return nil }
        return (status, fields.count > 2 ? String(fields[2]) : "")
    }

    /// The status code of a status line, or `nil`.
    static func status(of line: String) -> Int? { response(line)?.status }

    /// `DESCRIBE rtsp://h/p RTSP/1.0` → `(.describe, "rtsp://h/p")`. `nil` when the line is not a
    /// request line **or** names a method we do not model; the caller answers those with `501`
    /// after a resynchronisation rather than trying to represent them.
    static func request(_ line: String) -> (method: RTSPMethod, uri: String)? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3, fields[2].hasPrefix("RTSP/1."),
              let method = RTSPMethod(rawValue: String(fields[0])) else { return nil }
        return (method, String(fields[1]))
    }
}
