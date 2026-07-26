//
//  MultipartStreamParser.swift
//  VigilISAPI
//
//  The incremental `multipart/mixed` reader behind the alert stream: boundary sniffing, bare-LF
//  tolerance, and a fixed memory budget no device can make it exceed.
//  Implements docs/spec-isapi.md §14.1 and §14.5.
//
//  The hard requirement is the memory bound. This parser is fed by a connection that stays open for
//  weeks, from a device that is entitled to send a 2 GiB "part", a part with no `Content-Length`,
//  or no delimiter at all. So in the body states it retains **at most `boundary.count + 4` bytes**:
//  body bytes are handed to the caller as they arrive and never accumulated here. Everything that
//  needs a whole part — the XML, the JPEG — accumulates one layer up, under its own cap.
//
//  It is a plain `struct` with `mutating` methods (API_CONTRACT §2 R-32): the actor that owns the
//  connection drives it, so it is deterministic and every hostile split is a unit test.
//

import Foundation
import VigilProtocols

// MARK: - MultipartStreamParser

/// Splits a `multipart/mixed` byte stream into parts, incrementally and in bounded memory.
public struct MultipartStreamParser: Sendable {

    // MARK: Limits

    /// The four caps, all enforced. None of them is reachable by a well-behaved device.
    public struct Limits: Sendable, Hashable {
        /// Per part. Beyond this the headers are abandoned and the parser resynchronises.
        public var maxHeaderBytes: Int = 8 * 1024
        /// XML parts. Real ones are under 2 KiB.
        public var maxTextPartBytes: Int = 256 * 1024
        /// JPEG parts.
        public var maxBinaryPartBytes: Int = 4 * 1024 * 1024
        /// Bytes before the first delimiter. Beyond this the stream is not multipart at all.
        public var maxPreambleBytes: Int = 64 * 1024

        public init(maxHeaderBytes: Int = 8 * 1024, maxTextPartBytes: Int = 256 * 1024,
                    maxBinaryPartBytes: Int = 4 * 1024 * 1024,
                    maxPreambleBytes: Int = 64 * 1024) {
            self.maxHeaderBytes = maxHeaderBytes
            self.maxTextPartBytes = maxTextPartBytes
            self.maxBinaryPartBytes = maxBinaryPartBytes
            self.maxPreambleBytes = maxPreambleBytes
        }
    }

    // MARK: Output

    /// What one `ingest` call produced, in order.
    public enum Output: Sendable, Hashable {
        /// A new part's headers, keys lowercased. `declaredLength` is its `Content-Length`.
        case partBegan(headers: [String: String], declaredLength: Int?)
        /// A chunk of the current part's body. Emitted as it arrives; never accumulated here.
        case partData(Data)
        /// The current part finished cleanly.
        case partEnded
        /// The part exceeded a limit. Its remaining bytes are discarded up to the next delimiter.
        /// Reported rather than thrown so the caller can count and log it and keep the stream.
        case partTruncated(reason: String)
        /// The closing `--boundary--` was seen. Nothing after it is parsed.
        case streamEnded
    }

    // MARK: State

    private enum State: Sendable {
        /// Before the first delimiter: everything is discarded.
        case preamble
        /// Positioned at the start of a delimiter line; consuming it.
        case delimiterLine
        /// Accumulating a part's header block.
        case headers
        /// `Content-Length` was given: exactly this many body bytes remain.
        case bodyCounted(remaining: Int)
        /// No `Content-Length`: scan for the delimiter, retaining only the carry.
        case bodyScanning
        /// Discarding bytes until the next delimiter.
        case resync
        /// The closing delimiter was seen.
        case ended
    }

    // MARK: Stored state

    /// `"--" + token`, as bytes. The delimiter on the wire.
    private let delimiter: [UInt8]
    /// `LF + delimiter`: what is actually searched for, so a bare occurrence of the token inside
    /// JPEG data that is not preceded by a line ending can never split a part.
    private let needle: [UInt8]
    private let limits: Limits

    private var buffer: [UInt8] = []
    /// Read offset into `buffer`. Compaction keeps `buffer.count - cursor` at the true retention.
    private var cursor: Int = 0
    private var state: State = .preamble
    private var preambleBytesSeen = 0
    private var headerBytesSeen = 0
    /// Bytes of the current part's body already emitted, against its cap.
    private var bodyBytesEmitted = 0
    /// The cap that applies to the current part.
    private var bodyCap = 0
    /// True once the current part was truncated, so no further data is emitted for it.
    private var bodyTruncated = false
    /// True while a `partBegan` has been emitted without a matching `partEnded`.
    private var partOpen = false

    // MARK: Init

    /// - Parameters:
    ///   - boundary: the token **verbatim** from the `Content-Type` header, quotes already
    ///     stripped. Angle brackets and leading dashes are part of the token and must not be
    ///     removed: `boundary=<boundary>` really does mean the delimiter is `--<boundary>`.
    ///   - limits: the memory caps.
    public init(boundary: String, limits: Limits = .init()) {
        let token = Array(boundary.utf8)
        delimiter = [0x2D, 0x2D] + token
        needle = [0x0A] + delimiter
        self.limits = limits
    }

    /// Extracts the boundary token from a `Content-Type` header value.
    ///
    /// Only surrounding double quotes are stripped. Every other character — including angle
    /// brackets and leading dashes — belongs to the token, which is why
    /// `multipart/mixed;boundary=--myboundary` has the delimiter `----myboundary`.
    ///
    /// Returns `nil` when the header carries no `boundary` parameter; the caller then falls back
    /// to sniffing the first delimiter line out of the stream.
    public static func boundary(fromContentType header: String) -> String? {
        for parameter in header.split(separator: ";").dropFirst() {
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 9 else { continue }
            let prefix = trimmed.prefix(9)
            guard prefix.lowercased() == "boundary=" else { continue }
            var value = String(trimmed.dropFirst(9))
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Sniffs a delimiter out of the first bytes of a stream whose header carried no boundary.
    ///
    /// Looks for the first line matching `--<1…70 non-space characters>` and adopts it, returning
    /// the token without its leading `--`. Seen on exactly one 5.1.x build, but a stream with no
    /// boundary is otherwise unparseable.
    public static func sniffBoundary(inPreamble bytes: Data, limit: Int = 512) -> String? {
        var line: [UInt8] = []
        for byte in bytes.prefix(limit) {
            if byte == 0x0A {
                if let token = Self.token(fromDelimiterLine: line) { return token }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        return Self.token(fromDelimiterLine: line)
    }

    private static func token(fromDelimiterLine line: [UInt8]) -> String? {
        var trimmed = line
        while trimmed.last == 0x0D || trimmed.last == 0x20 || trimmed.last == 0x09 {
            trimmed.removeLast()
        }
        guard trimmed.count > 2, trimmed[0] == 0x2D, trimmed[1] == 0x2D else { return nil }
        let token = Array(trimmed.dropFirst(2))
        guard !token.isEmpty, token.count <= 70,
              !token.contains(where: { $0 == 0x20 || $0 == 0x09 }) else { return nil }
        return String(decoding: token, as: UTF8.self)
    }

    // MARK: Feeding

    /// Feeds bytes and returns everything they completed.
    ///
    /// Never throws for device misbehaviour that can be recovered from: an oversized header, an
    /// oversized part and garbage between parts all resynchronise and report `.partTruncated`.
    /// The one unrecoverable case is a preamble that never contains a delimiter, which means the
    /// response is not multipart at all and no amount of further reading will help.
    public mutating func ingest(_ bytes: Data) throws(ISAPIError) -> [Output] {
        if case .ended = state { return [] }
        buffer.append(contentsOf: bytes)
        var output: [Output] = []
        while try step(&output) {}
        compact()
        return output
    }

    /// Called when the byte stream ends. Closes an open part so the consumer can flush it.
    public mutating func finish() -> [Output] {
        var output: [Output] = []
        if partOpen {
            // Any bytes still held are body, not a delimiter prefix: a stream that ends mid-part
            // has no more delimiters coming.
            if available > 0, !bodyTruncated, case .bodyScanning = state {
                let tail = Data(buffer[cursor..<buffer.count])
                output.append(.partData(tail))
            }
            output.append(.partEnded)
            partOpen = false
        }
        cursor = buffer.count
        compact()
        state = .ended
        return output
    }

    // MARK: Introspection

    /// Bytes currently retained. In the body states this must never exceed
    /// `boundary.count + 4`; the test suite asserts it directly.
    var retainedByteCount: Int { buffer.count - cursor }

    /// True while the parser is inside a part body, where the memory bound applies.
    var isInBodyState: Bool {
        switch state {
        case .bodyCounted, .bodyScanning: true
        default: false
        }
    }

    // MARK: Machine

    private var available: Int { buffer.count - cursor }

    /// Runs one transition. Returns `true` when it made progress and should be called again.
    private mutating func step(_ output: inout [Output]) throws(ISAPIError) -> Bool {
        switch state {
        case .preamble: return try stepPreamble(&output)
        case .delimiterLine: return stepDelimiterLine(&output)
        case .headers: return stepHeaders(&output)
        case .bodyCounted(let remaining): return stepBodyCounted(remaining, &output)
        case .bodyScanning: return stepBodyScanning(&output)
        case .resync: return stepResync(&output)
        case .ended: return false
        }
    }

    /// Discards everything before the first delimiter.
    private mutating func stepPreamble(_ output: inout [Output]) throws(ISAPIError) -> Bool {
        // The stream's very first delimiter has no preceding line ending, so it is matched
        // directly; every later one is found through `needle`.
        if matchDelimiterAtCursor() != nil {
            state = .delimiterLine
            return true
        }
        if let index = search(needle) {
            preambleBytesSeen += index - cursor
            cursor = index + 1          // step over the LF, leaving the buffer on "--token"
            state = .delimiterLine
            return true
        }
        // Nothing found: keep only what could still be the start of a delimiter.
        let keep = min(available, needle.count)
        preambleBytesSeen += available - keep
        cursor = buffer.count - keep
        guard preambleBytesSeen <= limits.maxPreambleBytes else {
            throw ISAPIError.multipartProtocolError(
                "no multipart delimiter in the first \(preambleBytesSeen) bytes")
        }
        return false
    }

    /// Consumes a `--boundary` or `--boundary--` line.
    private mutating func stepDelimiterLine(_ output: inout [Output]) -> Bool {
        guard let lineEnd = indexOfLineFeed() else {
            // A closing delimiter at the very end of a stream may have no line ending at all; the
            // rest is handled by `finish()`. Until then, wait — but not forever. Stepping past the
            // delimiter first is what stops `resync` matching it again and looping.
            if available > delimiter.count + 16 {
                cursor += delimiter.count
                state = .resync
                return true
            }
            return false
        }
        var line = Array(buffer[cursor..<lineEnd])
        cursor = lineEnd + 1
        while line.last == 0x0D || line.last == 0x20 || line.last == 0x09 { line.removeLast() }
        let isClosing = line.count >= delimiter.count + 2
            && Array(line.suffix(2)) == [0x2D, 0x2D]
            && Array(line.prefix(delimiter.count)) == delimiter
        if isClosing {
            state = .ended
            output.append(.streamEnded)
            return false
        }
        headerBytesSeen = 0
        state = .headers
        return true
    }

    /// Accumulates a header block, terminated by `CRLFCRLF` or `LFLF`.
    private mutating func stepHeaders(_ output: inout [Output]) -> Bool {
        guard let end = indexOfHeaderTerminator() else {
            headerBytesSeen = available
            if headerBytesSeen > limits.maxHeaderBytes {
                output.append(.partTruncated(reason: "headers exceeded \(limits.maxHeaderBytes) B"))
                cursor = buffer.count
                state = .resync
                return true
            }
            return false
        }
        let block = Array(buffer[cursor..<end.blockEnd])
        cursor = end.next
        var headers: [String: String] = [:]
        for rawLine in Self.splitLines(block) {
            guard let colon = rawLine.firstIndex(of: 0x3A) else { continue }
            let name = String(decoding: rawLine[..<colon], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(decoding: rawLine[rawLine.index(after: colon)...], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = value
        }
        let declared = headers["content-length"].flatMap { Int($0) }
        let contentType = headers["content-type"] ?? ""
        bodyCap = Self.isTextual(contentType) ? limits.maxTextPartBytes : limits.maxBinaryPartBytes
        bodyBytesEmitted = 0
        bodyTruncated = false
        partOpen = true
        output.append(.partBegan(headers: headers, declaredLength: declared))
        // A declared length is exact and needs no scanning at all, which is the cheap path and the
        // one every current firmware takes. A negative length is nonsense and is ignored.
        if let declared, declared >= 0 {
            state = .bodyCounted(remaining: declared)
        } else {
            state = .bodyScanning
        }
        return true
    }

    /// Emits exactly `Content-Length` bytes, then expects the delimiter.
    private mutating func stepBodyCounted(_ remaining: Int, _ output: inout [Output]) -> Bool {
        if remaining == 0 {
            output.append(.partEnded)
            partOpen = false
            state = .resync
            return true
        }
        guard available > 0 else { return false }
        let take = min(remaining, available)
        // The chunk is materialised before the mutating call so the read of `buffer` and the
        // exclusive access to `self` do not overlap.
        let chunk = Data(buffer[cursor..<(cursor + take)])
        cursor += take
        state = .bodyCounted(remaining: remaining - take)
        emitBody(chunk, &output)
        return true
    }

    /// Emits body bytes while scanning for the delimiter, retaining only the carry.
    private mutating func stepBodyScanning(_ output: inout [Output]) -> Bool {
        if let index = search(needle) {
            // The CRLF (or LF) immediately before a delimiter belongs to the delimiter, not to the
            // body — dropping it is what keeps a JPEG byte-exact.
            var bodyEnd = index
            if bodyEnd > cursor, buffer[bodyEnd - 1] == 0x0D { bodyEnd -= 1 }
            let chunk = bodyEnd > cursor ? Data(buffer[cursor..<bodyEnd]) : Data()
            cursor = index + 1
            if !chunk.isEmpty { emitBody(chunk, &output) }
            output.append(.partEnded)
            partOpen = false
            state = .delimiterLine
            return true
        }
        let keep = min(available, needle.count)
        let releasable = available - keep
        guard releasable > 0 else { return false }
        let chunk = Data(buffer[cursor..<(cursor + releasable)])
        cursor += releasable
        emitBody(chunk, &output)
        return false
    }

    /// Discards bytes until the next delimiter, retaining only the carry.
    private mutating func stepResync(_ output: inout [Output]) -> Bool {
        if matchDelimiterAtCursor() != nil {
            if partOpen { output.append(.partEnded); partOpen = false }
            state = .delimiterLine
            return true
        }
        if let index = search(needle) {
            if partOpen { output.append(.partEnded); partOpen = false }
            cursor = index + 1
            state = .delimiterLine
            return true
        }
        let keep = min(available, needle.count)
        cursor = buffer.count - keep
        return false
    }

    // MARK: Helpers

    /// Emits body bytes, enforcing the part cap exactly once.
    ///
    /// Over the cap the excess is dropped and `.partTruncated` is reported once; the stream itself
    /// survives, because one oversized JPEG must not cost the device its whole event feed.
    private mutating func emitBody(_ chunk: Data, _ output: inout [Output]) {
        guard !bodyTruncated else { return }
        let remainingBudget = bodyCap - bodyBytesEmitted
        if chunk.count <= remainingBudget {
            bodyBytesEmitted += chunk.count
            output.append(.partData(chunk))
            return
        }
        if remainingBudget > 0 {
            let head = chunk.prefix(remainingBudget)
            bodyBytesEmitted += head.count
            output.append(.partData(Data(head)))
        }
        bodyTruncated = true
        output.append(.partTruncated(reason: "part exceeded \(bodyCap) B"))
    }

    /// True when the delimiter starts exactly at the cursor — the stream's first delimiter, and
    /// the one that follows a `Content-Length` body with no separating blank line.
    private func matchDelimiterAtCursor() -> Int? {
        guard available >= delimiter.count else { return nil }
        for (offset, byte) in delimiter.enumerated() where buffer[cursor + offset] != byte {
            return nil
        }
        return cursor
    }

    /// Index of the first byte of `pattern` at or after `cursor`, or `nil`.
    private func search(_ pattern: [UInt8]) -> Int? {
        guard !pattern.isEmpty, available >= pattern.count else { return nil }
        let first = pattern[0]
        let last = buffer.count - pattern.count
        var index = cursor
        while index <= last {
            if buffer[index] == first {
                var matched = true
                for offset in 1..<pattern.count where buffer[index + offset] != pattern[offset] {
                    matched = false
                    break
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }

    /// Index of the next LF at or after the cursor.
    private func indexOfLineFeed() -> Int? {
        var index = cursor
        while index < buffer.count {
            if buffer[index] == 0x0A { return index }
            index += 1
        }
        return nil
    }

    /// Finds `CRLFCRLF` or `LFLF`, tolerating the mixture Hikvision 5.2.x sends in one stream.
    private func indexOfHeaderTerminator() -> (blockEnd: Int, next: Int)? {
        var index = cursor
        while index < buffer.count {
            guard buffer[index] == 0x0A else { index += 1; continue }
            // Look back over an optional CR, then require another line ending immediately.
            var blockEnd = index
            if blockEnd > cursor, buffer[blockEnd - 1] == 0x0D { blockEnd -= 1 }
            var next = index + 1
            if next < buffer.count, buffer[next] == 0x0D { next += 1 }
            if next < buffer.count, buffer[next] == 0x0A { return (blockEnd, next + 1) }
            index += 1
        }
        return nil
    }

    /// Splits a header block on CRLF or LF, dropping empty lines.
    private static func splitLines(_ block: [UInt8]) -> [ArraySlice<UInt8>] {
        var lines: [ArraySlice<UInt8>] = []
        var start = block.startIndex
        var index = block.startIndex
        while index < block.endIndex {
            if block[index] == 0x0A {
                var end = index
                if end > start, block[end - 1] == 0x0D { end -= 1 }
                if end > start { lines.append(block[start..<end]) }
                start = index + 1
            }
            index += 1
        }
        if start < block.endIndex { lines.append(block[start..<block.endIndex]) }
        return lines
    }

    /// True for the content types whose parts are accumulated as text.
    private static func isTextual(_ contentType: String) -> Bool {
        let lowered = contentType.lowercased()
        return lowered.contains("xml") || lowered.hasPrefix("text/") || lowered.isEmpty
    }

    /// Drops consumed bytes so `buffer.count - cursor` is the real retention.
    private mutating func compact() {
        guard cursor > 0 else { return }
        if cursor >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else {
            buffer.removeFirst(cursor)
        }
        cursor = 0
    }
}
