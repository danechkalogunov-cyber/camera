//
//  RTSPWireDecoder.swift
//  VigilRTSP
//
//  The only place in Vigil where bytes off a socket become messages. A pure, deterministic,
//  split-invariant state machine: `ingest(bytes) -> [RTSPIncoming]` with no sockets, no clock and
//  no allocation for incomplete units. Feeding one byte at a time and feeding one megabyte at a
//  time must produce the identical event sequence — that is a property test, not a hope.
//  Implements docs/spec-rtsp.md §4 and §5.2–5.5, and docs/API_CONTRACT.md §4.3.
//

import Foundation

import VigilProtocols

// MARK: - Statistics

/// What the decoder saw. Every counter is a diagnosis a support log needs, and several of them
/// (`toleratedBareLF`, `midHeaderInterleavedFrames`) exist purely to prove that a leniency was
/// actually exercised against real firmware rather than only in a test.
public struct DecoderStatistics: Sendable, Equatable {

    /// Complete RTSP messages emitted, requests and responses together.
    public var messagesDecoded = 0
    /// `$` frames emitted, excluding zero-length ones.
    public var interleavedFramesDecoded = 0
    /// Payload bytes carried by those frames.
    public var interleavedBytes: UInt64 = 0
    /// Zero-length `$` frames, which are consumed and counted but never forwarded: a zero-byte RTP
    /// packet is not something a depacketizer should have to think about.
    public var emptyInterleavedFrames = 0
    /// Times resynchronization started.
    public var resyncEvents = 0
    /// Bytes thrown away by resynchronization.
    public var bytesDiscardedByResync: UInt64 = 0
    /// Lines terminated by a bare LF rather than CRLF (Hikvision DVR 3.1.x `ANNOUNCE`).
    public var toleratedBareLF = 0
    /// `$` frames accepted *inside* a header block (docs/spec-rtsp.md §5.4).
    public var midHeaderInterleavedFrames = 0
    /// Header lines with no colon, skipped rather than fatal.
    public var malformedHeaderLines = 0
    /// Continuation (obs-fold) lines folded into the preceding value.
    public var foldedHeaderLines = 0

    public init() {}
}

// MARK: - Decoder

/// The incremental RTSP wire decoder.
///
/// Hand it whatever the socket produced; it returns every complete unit it can build and keeps the
/// remainder. It never throws (API_CONTRACT §4.3): a framing failure arrives as
/// `RTSPIncoming.malformed`, *after* any events that were already complete in the same chunk, so a
/// `$` frame that shared a TCP segment with a fatal header is not lost.
///
/// Hostile input is bounded by construction. Every accumulation — start line, header line, header
/// block, field count, body, total buffer — has a limit, and hitting one is terminal: the decoder
/// drops its buffer, emits the fault and returns `[]` for every later call. There is no path in
/// which a peer that never sends CRLF can make this type allocate without bound.
public struct RTSPWireDecoder: Sendable {

    // MARK: - Limits

    /// Every ceiling the decoder enforces. Values are docs/spec-rtsp.md §17.
    public struct Limits: Sendable, Hashable {
        /// Longest start line accepted before the CRLF, and the cap on inter-message CRLF padding.
        public var maxStartLine = 4_096
        /// Longest single header line, folded continuations counted individually.
        public var maxHeaderLine = 8_192
        /// Largest header block in total.
        public var maxHeaderBlock = 32_768
        /// Most fields in one block.
        public var maxHeaderFields = 128
        /// Largest `Content-Length` accepted. 256 KiB: the biggest real SDP is under 2 KiB.
        public var maxBody = 262_144
        /// Buffered bytes that imply the parser is stuck rather than merely waiting.
        public var receiveHighWater = 2 << 20
        /// Bytes resynchronization may discard before giving up.
        public var maxResyncScan = 131_072
        /// Resyncs per minute the *session machine* tolerates. Carried here so one type owns every
        /// framing limit; the decoder itself does not measure time.
        public var maxResyncsPerMinute = 3
        /// Protocol ceiling on a `$` frame payload.
        public var maxInterleavedPayload = 65_535
        /// Consecutive valid frames a resynchronization candidate must chain before it is believed.
        public var resyncChainDepth = 2

        public init() {}
    }

    // MARK: - Phase

    /// Where the parser is. `.failed` is terminal.
    private enum Phase {
        case atBoundary
        case startLine
        case headers
        case body(need: Int)
        case interleavedPayload(channel: UInt8, need: Int)
        case resynchronizing(scanned: Int)
        case failed(RTSPFramingFault)
    }

    /// The message under construction.
    private struct Pending {
        enum Start {
            case response(RTSPStatus, reason: String)
            case request(RTSPMethod, uri: String)
        }
        var start: Start
        var headers = RTSPHeaders()
        var headerBytes = 0
    }

    /// One line, or a reason there is no line yet.
    private enum LineOutcome {
        case line(String)
        case needMore
        case tooLong(bytes: Int)
    }

    /// The verdict on a candidate `$` frame.
    private enum FrameVerdict {
        case accept(channel: UInt8, length: Int)
        case needMore
        case reject
    }

    // MARK: - State

    private let limits: Limits
    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var phase: Phase = .atBoundary
    private var pending: Pending?
    private var channels: Set<UInt8> = []
    private var paddingSkipped = 0

    /// Counters, readable at any time.
    public private(set) var statistics = DecoderStatistics()

    /// Creates a decoder. The default limits are the specified ones; a test may tighten them to
    /// reach a boundary without building a megabyte of input.
    public init(limits: Limits = .init()) {
        self.limits = limits
        buffer.reserveCapacity(4_096)
    }

    // MARK: - Configuration

    /// Adds channels negotiated by `SETUP`.
    ///
    /// Channels are **unioned**, never replaced, and must be registered *before* the `SETUP`
    /// request goes out: a device can start sending on a channel before it answers, and a frame on
    /// an unregistered channel is treated as corruption (docs/spec-rtsp.md §5.3).
    public mutating func registerInterleavedChannels(_ newChannels: Set<UInt8>) {
        channels.formUnion(newChannels)
    }

    /// Forgets every registered channel. Used when a session is torn down and the same connection
    /// is reused for a fresh `SETUP` ladder.
    public mutating func clearInterleavedChannels() { channels.removeAll(keepingCapacity: true) }

    /// The channels `$` frames are accepted on.
    public var registeredChannels: Set<UInt8> { channels }

    // MARK: - Introspection

    /// Bytes held pending more input. Zero once the decoder has failed.
    public var bufferedByteCount: Int { buffer.count - readIndex }

    /// Whether the decoder is scanning for a frame boundary after corruption.
    public var isResynchronizing: Bool {
        if case .resynchronizing = phase { return true }
        return false
    }

    /// The fault that stopped the decoder, or `nil` while it is healthy. Once set, `ingest` returns
    /// `[]` forever: the connection must be rebuilt.
    public var failure: RTSPFramingFault? {
        if case .failed(let fault) = phase { return fault }
        return nil
    }

    // MARK: - Ingest

    /// Appends bytes and drains every complete unit.
    ///
    /// Returns the units in wire order: interleaved frames, responses, server-initiated requests
    /// and at most one `.malformed`. Passing an empty collection is legal and re-drives the parser,
    /// which is how a caller polls after registering new channels.
    public mutating func ingest(_ bytes: some Collection<UInt8>) -> [RTSPIncoming] {
        if case .failed = phase { return [] }
        if !bytes.isEmpty { buffer.append(contentsOf: bytes) }
        var events: [RTSPIncoming] = []
        drain(into: &events)
        if case .failed = phase {} else if bufferedByteCount > limits.receiveHighWater {
            fail(.receiveBufferOverflow(bytes: bufferedByteCount), into: &events)
        }
        return events
    }

    // MARK: - Drain loop

    /// Runs steps until one cannot make progress.
    ///
    /// The iteration cap is a safety net, not a design element: every step either consumes at least
    /// one byte or moves to a phase that will. Two transitions per buffered byte is the worst legal
    /// case, so exceeding it means a step is not making progress, and stopping with a framing fault
    /// is the only honest response — a parser that spins on network data is a denial of service.
    private mutating func drain(into events: inout [RTSPIncoming]) {
        var iterations = 0
        let cap = 2 * buffer.count + 64
        while iterations <= cap {
            iterations += 1
            switch phase {
            case .failed:
                return
            case .atBoundary:
                if !stepBoundary(into: &events) { return }
            case .startLine:
                if !stepStartLine(into: &events) { return }
            case .headers:
                if !stepHeaders(into: &events) { return }
            case .body(let need):
                if !stepBody(need: need, into: &events) { return }
            case .interleavedPayload(let channel, let need):
                if !stepInterleavedPayload(channel: channel, need: need, into: &events) { return }
            case .resynchronizing(let scanned):
                if !stepResync(scanned: scanned, into: &events) { return }
            }
        }
        fail(.unrecoverableFraming(scanned: bufferedByteCount), into: &events)
    }

    // MARK: - Steps

    /// At a unit boundary: skip padding, then choose between a `$` frame and a message.
    ///
    /// The choice is unambiguous by construction: `0x24` is neither a token character nor `R`, so
    /// it cannot begin an RTSP start line (docs/spec-rtsp.md §5.4).
    private mutating func stepBoundary(into events: inout [RTSPIncoming]) -> Bool {
        var skip = 0
        while skip < bufferedByteCount, byte(at: skip) == 0x0D || byte(at: skip) == 0x0A { skip += 1 }
        if skip > 0 {
            paddingSkipped += skip
            consume(skip)
            if paddingSkipped > limits.maxStartLine {
                fail(.startLineTooLong(bytes: paddingSkipped), into: &events)
                return true
            }
        }
        guard bufferedByteCount > 0 else { return false }
        guard byte(at: 0) == 0x24 else {
            paddingSkipped = 0
            phase = .startLine
            return true
        }
        guard bufferedByteCount >= 4 else { return false }
        let channel = byte(at: 1)
        guard channels.contains(channel) else {
            events.append(.malformed(.unknownInterleavedChannel(channel)))
            beginResync()
            return true
        }
        let length = Int(byte(at: 2)) << 8 | Int(byte(at: 3))
        consume(4)
        paddingSkipped = 0
        guard length > 0 else {
            statistics.emptyInterleavedFrames += 1
            phase = .atBoundary
            return true
        }
        phase = .interleavedPayload(channel: channel, need: length)
        return true
    }

    /// Copies a complete interleaved payload out. The only copy the media path ever makes here.
    private mutating func stepInterleavedPayload(channel: UInt8, need: Int,
                                                 into events: inout [RTSPIncoming]) -> Bool {
        guard bufferedByteCount >= need else { return false }
        let payload = Data(buffer[readIndex ..< readIndex + need])
        consume(need)
        statistics.interleavedFramesDecoded += 1
        statistics.interleavedBytes += UInt64(need)
        events.append(.interleaved(channel: channel, payload: payload))
        phase = .atBoundary
        return true
    }

    /// Parses a start line into a pending message.
    private mutating func stepStartLine(into events: inout [RTSPIncoming]) -> Bool {
        switch takeLine(maxLength: limits.maxStartLine) {
        case .needMore:
            return false
        case .tooLong(let bytes):
            fail(.startLineTooLong(bytes: bytes), into: &events)
            return true
        case .line(let text):
            guard let start = parseStartLine(text, into: &events) else { return true }
            pending = Pending(start: start)
            phase = .headers
            return true
        }
    }

    /// Reads one header line, an obs-fold continuation, a mid-block `$` frame, or the blank line
    /// that ends the block.
    private mutating func stepHeaders(into events: inout [RTSPIncoming]) -> Bool {
        if bufferedByteCount > 0, byte(at: 0) == 0x24 {
            switch interleavedVerdict(at: 0) {
            case .needMore:
                return false
            case .accept(let channel, let length):
                let payload = Data(buffer[readIndex + 4 ..< readIndex + 4 + length])
                consume(4 + length)
                statistics.interleavedFramesDecoded += 1
                statistics.interleavedBytes += UInt64(length)
                statistics.midHeaderInterleavedFrames += 1
                events.append(.interleaved(channel: channel, payload: payload))
                return true
            case .reject:
                break                                   // it is a (malformed) header line after all
            }
        }
        switch takeLine(maxLength: limits.maxHeaderLine) {
        case .needMore:
            return false
        case .tooLong(let bytes):
            fail(.headerLineTooLong(bytes: bytes), into: &events)
            return true
        case .line(let text):
            guard var message = pending else {
                fail(.malformedStartLine(text), into: &events)
                return true
            }
            if text.isEmpty {
                pending = message
                return finishHeaderBlock(into: &events)
            }
            message.headerBytes += text.utf8.count + 2
            guard message.headerBytes <= limits.maxHeaderBlock else {
                fail(.headerBlockTooLarge(bytes: message.headerBytes), into: &events)
                return true
            }
            if let first = text.utf8.first, first == 0x20 || first == 0x09 {
                if message.headers.foldIntoLast(text) {
                    statistics.foldedHeaderLines += 1
                } else {
                    statistics.malformedHeaderLines += 1     // a fold with nothing to fold into
                }
                pending = message
                return true
            }
            guard let colon = text.firstIndex(of: ":") else {
                statistics.malformedHeaderLines += 1         // Hikvision has leaked `a=` lines here
                pending = message
                return true
            }
            let name = String(text[text.startIndex ..< colon])
            guard RTSPHeaderScanner.isToken(Substring(name)) else {
                statistics.malformedHeaderLines += 1
                pending = message
                return true
            }
            message.headers.append(name, String(text[text.index(after: colon)...]))
            guard message.headers.fields.count <= limits.maxHeaderFields else {
                fail(.tooManyHeaderFields(count: message.headers.fields.count), into: &events)
                return true
            }
            pending = message
            return true
        }
    }

    /// Copies exactly `need` body bytes and emits the message.
    private mutating func stepBody(need: Int, into events: inout [RTSPIncoming]) -> Bool {
        guard bufferedByteCount >= need else { return false }
        let body = Data(buffer[readIndex ..< readIndex + need])
        consume(need)
        emitPending(body: body, into: &events)
        return true
    }

    // MARK: - Header block completion

    /// Decides the body length and either emits the message or moves to `.body`.
    private mutating func finishHeaderBlock(into events: inout [RTSPIncoming]) -> Bool {
        guard let message = pending else {
            phase = .atBoundary
            return true
        }
        var status: RTSPStatus?
        if case .response(let value, _) = message.start { status = value }
        switch bodyLength(of: message.headers, status: status) {
        case .fault(let fault):
            fail(fault, into: &events)
            return true
        case .bytes(let need):
            if need == 0 {
                emitPending(body: Data(), into: &events)
            } else {
                phase = .body(need: need)
            }
            return true
        }
    }

    /// The outcome of reading `Content-Length`.
    private enum BodyLength {
        case bytes(Int)
        case fault(RTSPFramingFault)
    }

    /// `Content-Length` rules (docs/spec-rtsp.md §3.4 and §4.4).
    ///
    /// Absent means zero — there is no "read to end of connection" mode on a socket that also
    /// carries media. The one exception is a successful `application/sdp` response, where an absent
    /// length makes the body unframeable and the device unusable. Duplicated headers that disagree
    /// are refused outright: on a LAN it is a firmware bug rather than request smuggling, but the
    /// safe reading is the same one.
    private func bodyLength(of headers: RTSPHeaders, status: RTSPStatus?) -> BodyLength {
        let values = headers.all("Content-Length")
        guard let first = values.first else {
            let contentType = headers.first("Content-Type").map { ASCII.lowercased($0) } ?? ""
            if let status, status.isSuccess, contentType.hasPrefix("application/sdp") {
                let cseq = headers.int("CSeq").flatMap { UInt32(exactly: $0) }
                return .fault(.missingContentLength(cseq: cseq))
            }
            return .bytes(0)
        }
        if let disagreeing = values.first(where: { $0 != first }) {
            return .fault(.conflictingContentLength(first, disagreeing))
        }
        guard let declared = Int(first), declared >= 0 else {
            return .fault(.malformedContentLength(first))
        }
        guard declared <= limits.maxBody else {
            return .fault(.bodyTooLarge(declared: declared, limit: limits.maxBody))
        }
        return .bytes(declared)
    }

    /// Emits the pending message and returns to a unit boundary.
    private mutating func emitPending(body: Data, into events: inout [RTSPIncoming]) {
        defer {
            pending = nil
            phase = .atBoundary
            paddingSkipped = 0
        }
        guard let message = pending else { return }
        let cseq = message.headers.int("CSeq").flatMap { UInt32(exactly: $0) }
        switch message.start {
        case .response(let status, let reason):
            events.append(.response(RTSPResponse(status: status, reasonPhrase: reason,
                                                 headers: message.headers, body: body, cseq: cseq)))
        case .request(let method, let uri):
            events.append(.request(RTSPRequest(method: method, uri: uri, headers: message.headers,
                                               body: body, cseq: cseq ?? 0)))
        }
        statistics.messagesDecoded += 1
    }

    // MARK: - Start line

    /// Parses a start line, or records a fault and returns `nil`.
    ///
    /// Leniencies, each justified in docs/spec-rtsp.md §3.1: several spaces between tokens, a
    /// missing reason phrase, and `RTSP/1.1` treated as 1.0. An `HTTP/1.x` status line is singled
    /// out because an HTTP server on port 554 is a common misconfiguration and "not RTSP at all"
    /// is a far more useful diagnosis than "malformed".
    private mutating func parseStartLine(_ text: String,
                                         into events: inout [RTSPIncoming]) -> Pending.Start? {
        var cursor = text.startIndex
        let head = RTSPWireDecoder.takeField(text, from: &cursor)
        guard !head.isEmpty else {
            recover(.malformedStartLine(text), into: &events)
            return nil
        }
        if ASCII.hasPrefixIgnoringCase(head.utf8, "http/") {
            fail(.notRTSP(startLine: text), into: &events)
            return nil
        }
        if ASCII.hasPrefixIgnoringCase(head.utf8, "rtsp/") {
            let code = RTSPWireDecoder.takeField(text, from: &cursor)
            guard head.hasPrefix("RTSP/1."), code.count == 3,
                  code.utf8.allSatisfy(ASCII.isDigit), let value = Int(code) else {
                recover(.malformedStartLine(text), into: &events)
                return nil
            }
            // The reason phrase is free text that may itself contain runs of spaces, so it is the
            // rest of the line rather than the third whitespace-delimited field.
            let reason = String(RTSPHeaderScanner.trimmingOWS(text[cursor...]))
            return .response(RTSPStatus(rawValue: value), reason: reason)
        }
        let uri = RTSPWireDecoder.takeField(text, from: &cursor)
        let version = RTSPWireDecoder.takeField(text, from: &cursor)
        let trailing = RTSPHeaderScanner.trimmingOWS(text[cursor...])
        guard !uri.isEmpty, version.hasPrefix("RTSP/1."), trailing.isEmpty else {
            recover(.malformedStartLine(text), into: &events)
            return nil
        }
        guard let method = RTSPMethod(rawValue: String(head)) else {
            recover(.unknownMethod(String(head)), into: &events)
            return nil
        }
        return .request(method, uri: String(uri))
    }

    /// Takes the next whitespace-delimited field, leaving `cursor` just past it.
    ///
    /// Several spaces or tabs between start-line tokens are tolerated (docs/spec-rtsp.md §3.1), so
    /// leading whitespace is skipped before the field is read.
    private static func takeField(_ text: String, from cursor: inout String.Index) -> Substring {
        while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
        let start = cursor
        while cursor < text.endIndex, text[cursor] != " ", text[cursor] != "\t" {
            cursor = text.index(after: cursor)
        }
        return text[start ..< cursor]
    }

    // MARK: - Interleaved gate

    /// Whether the bytes at `offset` are a `$` frame, per the §5.4 heuristic.
    ///
    /// Every condition is required, and the order matters: the cheap rejections (magic, channel,
    /// length, RTP version bits) are decided from five bytes, so a genuinely malformed header line
    /// that begins with `$` is classified without waiting for data that will never come. Only after
    /// the frame looks real do we insist on having all of it.
    ///
    /// The magic check belongs **here**, not at the call sites, because the resynchronization chain
    /// validates links 2…n through this function at offsets derived from the *previous* link's
    /// length field. If a length is wrong — a truncated write, a firmware quirk, corruption — that
    /// offset lands mid-packet, and a link accepted without its magic byte would let the decoder
    /// lock onto a false boundary and hand garbage to the depacketizer, which surfaces as malformed
    /// frames several layers away from the cause.
    private func interleavedVerdict(at offset: Int) -> FrameVerdict {
        guard bufferedByteCount - offset >= 5 else { return .needMore }
        guard byte(at: offset) == 0x24 else { return .reject }
        let channel = byte(at: offset + 1)
        guard channels.contains(channel) else { return .reject }
        let length = Int(byte(at: offset + 2)) << 8 | Int(byte(at: offset + 3))
        guard length >= 4, length <= limits.maxInterleavedPayload else { return .reject }
        guard byte(at: offset + 4) >> 6 == 2 else { return .reject }     // RTP/RTCP version must be 2
        guard bufferedByteCount - offset >= 4 + length else { return .needMore }
        return .accept(channel: channel, length: length)
    }

    // MARK: - Resynchronization

    /// Enters resynchronization.
    private mutating func beginResync() {
        statistics.resyncEvents += 1
        pending = nil
        paddingSkipped = 0
        phase = .resynchronizing(scanned: 0)
    }

    /// Scans for the next thing that is certainly a unit boundary.
    ///
    /// Two candidates, lowest offset wins: a chain of `resyncChainDepth` valid interleaved frames,
    /// or the nine bytes `"RTSP/1.0 "`. A candidate is only ever accepted or rejected on complete
    /// evidence — never on "the buffer happens to end here" — because a decision that depends on
    /// where a TCP segment boundary fell would break split invariance, which is the one property
    /// this whole file is built to keep.
    private mutating func stepResync(scanned: Int, into events: inout [RTSPIncoming]) -> Bool {
        var offset = 0
        while true {
            if scanned + offset > limits.maxResyncScan {
                fail(.unrecoverableFraming(scanned: scanned + offset), into: &events)
                return true
            }
            let remaining = bufferedByteCount - offset
            if remaining < 9 { return pauseResync(scanned: scanned, discarding: offset) }
            if matchesStatusLine(at: offset) {
                finishResync(discarding: offset)
                return true
            }
            if byte(at: offset) == 0x24 {
                switch chainVerdict(at: offset) {
                case .accept:
                    finishResync(discarding: offset)
                    return true
                case .needMore:
                    return pauseResync(scanned: scanned, discarding: offset)
                case .reject:
                    break
                }
            }
            offset += 1
        }
    }

    /// Whether `"RTSP/1."` starts at `offset`. Nine bytes are required before this is asked, so a
    /// status line split across two ingests is never half-matched.
    private func matchesStatusLine(at offset: Int) -> Bool {
        let marker = Array("RTSP/1.".utf8)
        guard bufferedByteCount - offset >= marker.count else { return false }
        for (index, expected) in marker.enumerated() where byte(at: offset + index) != expected {
            return false
        }
        return true
    }

    /// Validates `resyncChainDepth` consecutive frames starting at `offset`.
    ///
    /// Every link is checked in full, magic byte included: the whole point of chaining is that one
    /// coincidental four-byte pattern is not evidence of a frame boundary. A link that fails is a
    /// `.reject` for the *candidate*, not for the connection — the caller advances one byte and
    /// keeps scanning, so a bad length field costs a resynchronization rather than desynchronizing
    /// the stream permanently or discarding the buffer.
    private func chainVerdict(at offset: Int) -> FrameVerdict {
        var cursor = offset
        var remaining = max(1, limits.resyncChainDepth)
        var firstChannel: UInt8 = 0
        var firstLength = 0
        while remaining > 0 {
            switch interleavedVerdict(at: cursor) {
            case .reject:
                return .reject
            case .needMore:
                return .needMore
            case .accept(let channel, let length):
                if cursor == offset {
                    firstChannel = channel
                    firstLength = length
                }
                cursor += 4 + length
                remaining -= 1
            }
        }
        return .accept(channel: firstChannel, length: firstLength)
    }

    /// Drops `offset` bytes and keeps scanning on the next ingest.
    private mutating func pauseResync(scanned: Int, discarding offset: Int) -> Bool {
        if offset > 0 {
            consume(offset)
            statistics.bytesDiscardedByResync += UInt64(offset)
        }
        phase = .resynchronizing(scanned: scanned + offset)
        return false
    }

    /// Drops `offset` bytes and returns to a unit boundary.
    private mutating func finishResync(discarding offset: Int) {
        if offset > 0 {
            consume(offset)
            statistics.bytesDiscardedByResync += UInt64(offset)
        }
        phase = .atBoundary
    }

    // MARK: - Faults

    /// Records a terminal fault: emit it, drop the buffer, answer nothing ever again.
    private mutating func fail(_ fault: RTSPFramingFault, into events: inout [RTSPIncoming]) {
        events.append(.malformed(fault))
        phase = .failed(fault)
        pending = nil
        buffer.removeAll(keepingCapacity: false)
        readIndex = 0
    }

    /// Records a recoverable fault: emit it and resynchronize on the same connection.
    private mutating func recover(_ fault: RTSPFramingFault, into events: inout [RTSPIncoming]) {
        events.append(.malformed(fault))
        beginResync()
    }

    // MARK: - Buffer

    /// The byte `offset` past the read cursor. Callers check `bufferedByteCount` first.
    private func byte(at offset: Int) -> UInt8 { buffer[readIndex + offset] }

    /// Advances the read cursor and compacts when the dead prefix is worth removing.
    ///
    /// Compaction thresholds keep the amortized cost linear: without them, `Data.removeFirst` per
    /// message is quadratic in the stream length, which is measurable at sixteen 1080p streams.
    private mutating func consume(_ count: Int) {
        readIndex += count
        if readIndex > 8_192 || readIndex > buffer.count / 2 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }

    /// Reads one CRLF- or LF-terminated line, consuming it.
    ///
    /// Returns `.needMore` when no LF has arrived yet — including the case where the CR of a CRLF
    /// is the last byte of a chunk, which is why the terminator search looks for LF and inspects
    /// the byte before it rather than searching for the two-byte sequence.
    private mutating func takeLine(maxLength: Int) -> LineOutcome {
        var index = readIndex
        while index < buffer.count {
            guard buffer[index] == 0x0A else {
                index += 1
                continue
            }
            let hasCR = index > readIndex && buffer[index - 1] == 0x0D
            let lineEnd = hasCR ? index - 1 : index
            let consumed = index + 1 - readIndex
            if consumed > maxLength { return .tooLong(bytes: consumed) }
            let text = String(decoding: buffer[readIndex ..< lineEnd], as: UTF8.self)
            if !hasCR { statistics.toleratedBareLF += 1 }
            consume(consumed)
            return .line(text)
        }
        if bufferedByteCount > maxLength { return .tooLong(bytes: bufferedByteCount) }
        return .needMore
    }
}
