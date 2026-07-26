//
//  RTSPHeaders.swift
//  VigilRTSP
//
//  Ordered, case-insensitive, duplicate-preserving header container. Order is kept so a serialized
//  request is byte-stable against a golden fixture; duplicates are kept because `WWW-Authenticate`
//  legitimately appears twice on Hikvision firmware that offers Digest and Basic.
//  Implements docs/spec-rtsp.md §2.2 and docs/API_CONTRACT.md §4.3.
//

import VigilProtocols

/// An RTSP header block.
///
/// Name comparison is **ASCII-only** case folding (RFC 2326 §12 header names are ASCII tokens).
/// Unicode folding is forbidden here: `İ`.lowercased() is `i̇` in Swift, so a Turkish-locale-shaped
/// name would compare equal to `i…` and let a header be smuggled past a lookup.
///
/// Values are stored OWS-trimmed (leading and trailing space and horizontal tab removed), which is
/// what every caller wants and what RFC 2326 §12 allows a receiver to do.
public struct RTSPHeaders: Sendable, Equatable, Sequence, CustomStringConvertible {

    // MARK: - Field

    /// One header line, remembering the casing it arrived in so a round trip is byte-exact.
    public struct Field: Sendable, Equatable, Hashable {

        /// Original casing, as sent or received.
        public let name: String
        /// OWS-trimmed value. May be empty: `Session:` with nothing after it is legal-ish and seen.
        public var value: String
        /// `name` folded with ASCII rules; the key every lookup compares against.
        public let lowercasedName: String

        /// Creates a field, trimming the value and precomputing the folded name.
        public init(name: String, value: String) {
            self.name = name
            self.value = RTSPHeaders.trimmingOWS(value)
            self.lowercasedName = ASCII.lowercased(name)
        }
    }

    // MARK: - Storage

    /// Every field, in the order it was added or received. At most `maxHeaderFields` (128) of them
    /// after a decode, so the linear scans below are bounded.
    public private(set) var fields: [Field] = []

    /// An empty block.
    public init() {}

    /// Builds a block from ordered pairs. Duplicate names are preserved as duplicates, not merged.
    public init(_ pairs: [(String, String)]) {
        fields.reserveCapacity(pairs.count)
        for pair in pairs { fields.append(Field(name: pair.0, value: pair.1)) }
    }

    // MARK: - Lookup

    /// The first value for `name`, case-insensitively, or `nil` when the header is absent.
    public func first(_ name: String) -> String? {
        let key = ASCII.lowercased(name)
        return fields.first { $0.lowercasedName == key }?.value
    }

    /// Every value for `name`, in receive order. Empty when the header is absent.
    public func all(_ name: String) -> [String] {
        let key = ASCII.lowercased(name)
        return fields.compactMap { $0.lowercasedName == key ? $0.value : nil }
    }

    /// Every value for `name` joined with `", "`, for the list-valued headers (`Public`,
    /// `Unsupported`, `Allow`), which RFC 2326 §12 says may be split across lines. `nil` when the
    /// header is absent, so a caller can tell "absent" from "present and empty".
    public func joined(_ name: String) -> String? {
        let values = all(name)
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    /// Whether any field carries `name`.
    public func has(_ name: String) -> Bool { first(name) != nil }

    /// The first value for `name` parsed as a base-10 `Int`, or `nil` when absent or not a number.
    ///
    /// Strict on purpose: `Int("12 ")` and `Int("+12")` fail here, because a `Content-Length` that
    /// needs guessing is a framing risk, not a convenience.
    public func int(_ name: String) -> Int? {
        guard let value = first(name) else { return nil }
        return Int(value)
    }

    // MARK: - Mutation

    /// Replaces every field named `name` with a single field carrying `value`, at the position of
    /// the first one. Appends when the header is absent.
    public mutating func set(_ name: String, _ value: String) {
        let key = ASCII.lowercased(name)
        let replacement = Field(name: name, value: value)
        guard let index = fields.firstIndex(where: { $0.lowercasedName == key }) else {
            fields.append(replacement)
            return
        }
        var kept: [Field] = []
        kept.reserveCapacity(fields.count)
        for (position, field) in fields.enumerated() {
            if position == index {
                kept.append(replacement)
            } else if field.lowercasedName != key {
                kept.append(field)
            }
        }
        fields = kept
    }

    /// Adds a field, keeping any existing field of the same name. This is how a second
    /// `WWW-Authenticate` or a folded continuation reaches the block.
    public mutating func append(_ name: String, _ value: String) {
        fields.append(Field(name: name, value: value))
    }

    /// Inserts a field at the front. Used by the serializer to guarantee `CSeq` leads a request
    /// that was assembled without one.
    public mutating func insertFirst(_ name: String, _ value: String) {
        fields.insert(Field(name: name, value: value), at: 0)
    }

    /// Removes every field named `name`.
    public mutating func remove(_ name: String) {
        let key = ASCII.lowercased(name)
        fields.removeAll { $0.lowercasedName == key }
    }

    /// Appends `continuation` to the last field's value, separated by one space.
    ///
    /// This is obs-folding (a header line beginning with SP or HTAB). Returns `false` when there is
    /// no previous field to fold into, which makes the line malformed rather than fatal.
    @discardableResult
    package mutating func foldIntoLast(_ continuation: String) -> Bool {
        guard let index = fields.indices.last else { return false }
        let trimmed = RTSPHeaders.trimmingOWS(continuation)
        if fields[index].value.isEmpty {
            fields[index].value = trimmed
        } else if !trimmed.isEmpty {
            fields[index].value += " " + trimmed
        }
        return true
    }

    // MARK: - Sequence

    public func makeIterator() -> IndexingIterator<[Field]> { fields.makeIterator() }

    /// One line per field, with secrets removed. Safe to log; not the wire form.
    ///
    /// `Authorization` and `WWW-Authenticate` values are elided whole by `Redact`, so a password
    /// equivalent cannot reach a log line through a header dump.
    public var description: String {
        Redact.secrets(in: fields.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
    }

    // MARK: - OWS

    /// Removes leading and trailing SP and HTAB. Other whitespace (CR, LF, NUL) is left alone: it
    /// cannot appear inside a decoded value, and silently eating it would hide a framing bug.
    package static func trimmingOWS(_ text: String) -> String {
        var bytes = Array(text.utf8)
        while let last = bytes.last, last == 0x20 || last == 0x09 { bytes.removeLast() }
        var start = 0
        while start < bytes.count, bytes[start] == 0x20 || bytes[start] == 0x09 { start += 1 }
        return String(decoding: bytes[start...], as: UTF8.self)
    }
}
