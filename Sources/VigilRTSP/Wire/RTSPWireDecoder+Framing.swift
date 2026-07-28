//
//  RTSPWireDecoder+Framing.swift
//  VigilRTSP
//
//  Completing a header block, reading a start line, gating interleaved data and resynchronising after a
//  bad one.
//  Split from RTSPWireDecoder.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

import Foundation
import VigilProtocols

// MARK: - Header blocks, start lines and resynchronisation

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension RTSPWireDecoder {

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
    func interleavedVerdict(at offset: Int) -> FrameVerdict {
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
    func byte(at offset: Int) -> UInt8 { buffer[readIndex + offset] }

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
