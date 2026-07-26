//
//  SADPXMLReader.swift
//  VigilDiscovery
//
//  The flat, case-folding reader SADP datagrams are parsed with: element name to trimmed text, last
//  value wins, plus the bare-ampersand repair real Hikvision firmware needs.
//  See docs/spec-discovery.md §4.5.1 and docs/API_CONTRACT.md §4.6.
//

/// Reads a SADP `Probe` or `ProbeMatch` datagram into a flat dictionary.
///
/// SADP documents are two levels deep and their element names vary in case and, on some OEM
/// firmware, carry a namespace prefix. Depth is therefore ignored entirely: the reader keys on the
/// **lowercased local name** of every non-root element, and the last occurrence wins. Nothing is
/// dropped — unknown elements are what `SADPProbeMatch.raw` is for, because firmware variance is the
/// norm and the device-details inspector shows the lot.
///
/// Nothing here throws. A malformed document yields whatever elements closed before the damage,
/// with `isWellFormed == false` so the caller can apply the §4.5.1 recovery rule.
public enum SADPXMLReader {

    /// The result of reading one datagram.
    public struct Document: Sendable, Hashable {

        /// Lowercased local name of the first element, or `nil` when the text held no element at
        /// all. `probematch` and `probe` are the only two values SADP produces.
        public let rootName: String?

        /// Every non-root element: lowercased local name to text, trimmed of ASCII whitespace.
        ///
        /// Trimming resolves a contradiction in the specification, which asks for trimmed values in
        /// §4.5.1 and calls them un-trimmed in the §4.5 struct comment: firmware indents its XML, so
        /// un-trimmed values would put newlines inside every field.
        public let elements: [String: String]

        /// True when every element closed properly before the input ended. False for a truncated
        /// datagram, a mismatched end tag, or a document that hit a scan limit.
        public let isWellFormed: Bool

        /// True when a bound in `XMLScanLimits` was reached and the scan stopped early.
        public let hitLimit: Bool

        /// Creates a document. Exposed so tests can drive the decoders without a datagram.
        public init(rootName: String?, elements: [String: String],
                    isWellFormed: Bool, hitLimit: Bool) {
            self.rootName = rootName
            self.elements = elements
            self.isWellFormed = isWellFormed
            self.hitLimit = hitLimit
        }
    }

    /// Maximum distinct element names retained. A SADP `ProbeMatch` has about thirty; the cap only
    /// bites on a datagram built to make us allocate.
    public static let maxRetainedElements = 256

    /// Parses `text` into a `Document`. Total: every input, including the empty string and pure
    /// binary reinterpreted as text, produces a value rather than an error.
    ///
    /// - Parameters:
    ///   - text: the datagram, already decoded from bytes.
    ///   - limits: scan bounds; `.discovery` unless a test needs something tighter.
    public static func read(_ text: String, limits: XMLScanLimits = .discovery) -> Document {
        var elements: [String: String] = [:]
        var rootName: String?
        var depth = 0
        var buffers: [String] = []

        let outcome = LenientXMLScanner.scan(escapingBareAmpersands(text), limits: limits) { event in
            switch event {
            case let .start(name, _):
                if rootName == nil { rootName = name }
                depth += 1
                buffers.append("")
            case let .text(value):
                if !buffers.isEmpty { buffers[buffers.count - 1] += value }
            case let .end(name):
                let value = buffers.popLast() ?? ""
                depth -= 1
                guard depth > 0 else { return }        // the root carries no value of its own
                if elements[name] != nil || elements.count < maxRetainedElements {
                    elements[name] = LenientXMLScanner.trimmingASCIIWhitespace(value)
                }
            }
        }

        return Document(rootName: rootName, elements: elements,
                        isWellFormed: outcome.isBalanced && !outcome.hitLimit,
                        hitLimit: outcome.hitLimit)
    }

    /// Escapes a bare `&` — one not already starting a character reference — as `&amp;`.
    ///
    /// Hikvision firmware ships `ProbeMatch` documents with an unescaped `&` inside
    /// `DeviceDescription` ("Lobby & Dock"). A strict parser throws the whole datagram away, which
    /// means throwing away a real camera, so §4.5.1 requires this single sanitising pass before
    /// parsing. An `&` is left alone when it is followed by one to eight name characters and a `;`.
    ///
    /// The specification writes that test as `[A-Za-z#]{1,8};`, which would rewrite the numeric
    /// reference `&#38;` into `&amp;#38;`; digits are included here so numeric references survive.
    /// Since `&amp;` decodes back to `&`, escaping is idempotent in effect either way.
    public static func escapingBareAmpersands(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard bytes.contains(UInt8(ascii: "&")) else { return text }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 8)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "&") else {
                out.append(bytes[index])
                index += 1
                continue
            }
            if startsCharacterReference(bytes, at: index) {
                out.append(bytes[index])
            } else {
                out.append(contentsOf: Array("&amp;".utf8))
            }
            index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// True when `bytes[index]` is an `&` followed by 1…8 name characters and a `;`.
    private static func startsCharacterReference(_ bytes: [UInt8], at index: Int) -> Bool {
        var cursor = index + 1
        let limit = min(index + 9, bytes.count)
        while cursor < limit {
            let byte = bytes[cursor]
            if byte == UInt8(ascii: ";") { return cursor > index + 1 }
            guard isReferenceNameByte(byte) else { return false }
            cursor += 1
        }
        return false
    }

    private static func isReferenceNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "#"):
            true
        default:
            false
        }
    }
}
