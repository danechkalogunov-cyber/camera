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
    enum Phase {
        case atBoundary
        case startLine
        case headers
        case body(need: Int)
        case interleavedPayload(channel: UInt8, need: Int)
        case resynchronizing(scanned: Int)
        case failed(RTSPFramingFault)
    }

    /// The message under construction.
    struct Pending {
        enum Start {
            case response(RTSPStatus, reason: String)
            case request(RTSPMethod, uri: String)
        }
        var start: Start
        var headers = RTSPHeaders()
        var headerBytes = 0
    }

    /// One line, or a reason there is no line yet.
    enum LineOutcome {
        case line(String)
        case needMore
        case tooLong(bytes: Int)
    }

    /// The verdict on a candidate `$` frame.
    enum FrameVerdict {
        case accept(channel: UInt8, length: Int)
        case needMore
        case reject
    }

    // MARK: - State

    let limits: Limits
    var buffer: [UInt8] = []
    var readIndex = 0
    var phase: Phase = .atBoundary
    var pending: Pending?
    var channels: Set<UInt8> = []
    var paddingSkipped = 0

    /// Counters, readable at any time.
    public internal(set) var statistics = DecoderStatistics()

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
}
