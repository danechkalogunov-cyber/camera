//
//  StartLineHeaderScanner.swift
//  VigilDiscovery
//
//  A deliberately lenient scanner for the first line and headers of an RTSP or HTTP response, used
//  by the fingerprints. Deliberately NOT VigilRTSP's parser: discovery must not depend on VigilRTSP,
//  and must accept malformed answers that a session parser is right to reject.
//  Implements docs/spec-discovery.md §6.6. Never throws, never traps, bounded by construction.
//

import Foundation

/// Scans a response's start line and headers.
///
/// Everything here is a fingerprint, not a session: the peer is an unknown device that may answer
/// with bare `\n`, a missing reason phrase, no body, Latin-1 bytes in a realm, or a megabyte of
/// header. All of that must produce a `Result` rather than an error, because the whole point is to
/// classify the device that sent it.
public struct StartLineHeaderScanner: Sendable {

    /// What a scan found.
    public struct Result: Sendable, Equatable {
        /// The first token of the start line, e.g. `RTSP/1.0` or `HTTP/1.1`. Empty if there was none.
        public var protocolToken: String
        /// The numeric status, or `nil` when the second token was not a number.
        public var statusCode: Int?
        /// Everything after the status code, trimmed. Often empty; some firmware omits it.
        public var reasonPhrase: String
        /// Lowercased header names to their last value; repeats are joined with `", "`.
        public var headers: [String: String]
        /// Up to 512 bytes of body, enough to sniff `<DeviceInfo` or `<ResponseStatus`.
        public var bodyPrefix: Data
        /// True when the header section hit `headerByteLimit` or the buffer ended mid-headers.
        public var isTruncated: Bool

        public init(protocolToken: String = "", statusCode: Int? = nil, reasonPhrase: String = "",
                    headers: [String: String] = [:], bodyPrefix: Data = Data(),
                    isTruncated: Bool = false) {
            self.protocolToken = protocolToken
            self.statusCode = statusCode
            self.reasonPhrase = reasonPhrase
            self.headers = headers
            self.bodyPrefix = bodyPrefix
            self.isTruncated = isTruncated
        }

        /// Case-insensitive header lookup.
        public func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    /// Bytes of body kept for sniffing.
    public static let bodyPrefixLimit = 512

    /// Scans `data`.
    ///
    /// Returns `nil` only for an empty buffer — anything with a byte in it is classified, since a
    /// device that answers with garbage still told us it exists. Header lines with no colon are
    /// skipped, continuation lines (leading space or tab) are folded onto the previous header, and
    /// non-UTF-8 bytes are decoded as ISO-8859-1 so a Latin-1 realm survives intact instead of
    /// turning the whole response into `nil`.
    ///
    /// - Parameter headerByteLimit: how many bytes of header section to consume before giving up and
    ///   setting `isTruncated`. Bounds the work a hostile peer can cause: a device that streams
    ///   headers forever costs us this many bytes and no more.
    public static func scan(_ data: Data, headerByteLimit: Int = 8_192) -> Result? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        var result = Result()

        var index = 0
        var lineIndex = 0
        var lastHeaderName: String?
        let scanLimit = min(bytes.count, max(headerByteLimit, 0))

        while index < scanLimit {
            guard let (line, next) = readLine(bytes, from: index, limit: scanLimit) else {
                // No terminator before the limit: what we have is the last line we will see.
                let tail = decodeLatin1Compatible(Array(bytes[index..<scanLimit]))
                if lineIndex == 0 { parseStartLine(tail, into: &result) }
                break
            }
            let text = decodeLatin1Compatible(line)
            index = next

            if lineIndex == 0 {
                parseStartLine(text, into: &result)
                lineIndex += 1
                continue
            }
            if text.isEmpty {
                // Blank line: headers are done, the rest is body.
                let bodyEnd = min(bytes.count, index + bodyPrefixLimit)
                result.bodyPrefix = Data(bytes[index..<bodyEnd])
                result.isTruncated = truncated
                return result
            }
            appendHeaderLine(text, into: &result, lastName: &lastHeaderName)
            lineIndex += 1
        }

        // We ran out of buffer (or budget) inside the header section.
        result.isTruncated = true
        if scanLimit < bytes.count { result.isTruncated = true }
        _ = truncated
        return result
    }

    // MARK: - Line reading

    /// Reads one line ending in `\n` (with an optional preceding `\r`), returning its bytes without
    /// the terminator and the index after it. `nil` when no terminator appears before `limit`.
    private static func readLine(_ bytes: [UInt8], from start: Int,
                                 limit: Int) -> ([UInt8], Int)? {
        var cursor = start
        while cursor < limit {
            if bytes[cursor] == UInt8(ascii: "\n") {
                var end = cursor
                if end > start, bytes[end - 1] == UInt8(ascii: "\r") { end -= 1 }
                return (Array(bytes[start..<end]), cursor + 1)
            }
            cursor += 1
        }
        return nil
    }

    /// Decodes bytes as UTF-8, falling back to ISO-8859-1 so no byte sequence can defeat the scan.
    private static func decodeLatin1Compatible(_ bytes: [UInt8]) -> String {
        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        return String(String.UnicodeScalarView(bytes.map { UnicodeScalar($0) }))
    }

    // MARK: - Parsing

    /// Splits `RTSP/1.0 401 Unauthorized` into its three parts. A missing status or reason is fine.
    private static func parseStartLine(_ line: String, into result: inout Result) {
        let trimmed = line.trimmedASCII()
        guard !trimmed.isEmpty else { return }
        var parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return }
        result.protocolToken = String(parts.removeFirst())
        if let statusText = parts.first {
            result.statusCode = Int(statusText)
            if result.statusCode != nil { parts.removeFirst() }
        }
        result.reasonPhrase = parts.joined(separator: " ").trimmedASCII()
    }

    /// Folds one header line into `result`. Continuation lines extend the previous header; lines
    /// with no colon are dropped, which is what a device emitting a stray banner line produces.
    private static func appendHeaderLine(_ line: String, into result: inout Result,
                                         lastName: inout String?) {
        if let first = line.first, first == " " || first == "\t" {
            guard let name = lastName, let existing = result.headers[name] else { return }
            result.headers[name] = existing + " " + line.trimmedASCII()
            return
        }
        guard let colon = line.firstIndex(of: ":") else { return }
        let name = String(line[line.startIndex..<colon]).trimmedASCII().lowercased()
        guard !name.isEmpty else { return }
        let value = String(line[line.index(after: colon)...]).trimmedASCII()
        if let existing = result.headers[name], !existing.isEmpty {
            result.headers[name] = existing + ", " + value
        } else {
            result.headers[name] = value
        }
        lastName = name
    }

    // MARK: - Auth challenges

    /// Parses a `WWW-Authenticate` value into its scheme and parameters.
    ///
    /// Handles `Digest realm="IP Camera(52799)", nonce="…", qop="auth"` and `Basic realm="x"`,
    /// tolerates unquoted values, stray whitespace and a trailing comma, and lowercases parameter
    /// names while preserving value case — a realm is a fingerprint and its capitalisation matters.
    /// Returns `nil` when there is no scheme token at all.
    public static func authChallenge(_ value: String) -> (scheme: String, params: [String: String])? {
        let trimmed = value.trimmedASCII()
        guard !trimmed.isEmpty else { return nil }
        var remainder = Substring(trimmed)
        guard let spaceIndex = remainder.firstIndex(of: " ") else {
            return (String(remainder), [:])
        }
        let scheme = String(remainder[remainder.startIndex..<spaceIndex])
        remainder = remainder[remainder.index(after: spaceIndex)...]

        var params: [String: String] = [:]
        var name = ""
        var value = ""
        var readingName = true
        var inQuotes = false
        var escaped = false

        func commit() {
            let key = name.trimmedASCII().lowercased()
            if !key.isEmpty { params[key] = value.trimmedASCII().unquotedASCII() }
            name = ""
            value = ""
            readingName = true
        }

        for character in remainder {
            if escaped {
                value.append(character)
                escaped = false
            } else if inQuotes {
                if character == "\\" {
                    escaped = true
                } else {
                    if character == "\"" { inQuotes = false }
                    value.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
                value.append(character)
            } else if character == "=", readingName {
                readingName = false
            } else if character == "," {
                commit()
            } else if readingName {
                name.append(character)
            } else {
                value.append(character)
            }
        }
        commit()
        return (scheme, params)
    }
}

// MARK: - String helpers

extension String {
    /// Trims ASCII space, tab, CR and LF from both ends.
    func trimmedASCII() -> String {
        var view = Substring(self)
        while let first = view.first, first == " " || first == "\t" || first == "\r"
                || first == "\n" {
            view = view.dropFirst()
        }
        while let last = view.last, last == " " || last == "\t" || last == "\r" || last == "\n" {
            view = view.dropLast()
        }
        return String(view)
    }

    /// Strips one pair of surrounding double quotes, if present.
    func unquotedASCII() -> String {
        guard count >= 2, hasPrefix("\""), hasSuffix("\"") else { return self }
        return String(dropFirst().dropLast())
    }
}
