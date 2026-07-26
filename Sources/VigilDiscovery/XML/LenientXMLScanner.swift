//
//  LenientXMLScanner.swift
//  VigilDiscovery
//
//  The bounded XML event scanner both discovery decoders sit on. It turns a datagram's text into
//  start/text/end events iteratively — no recursion, no entity expansion, no allocation larger than
//  the input — because every byte it sees arrived unauthenticated over UDP.
//  See docs/spec-discovery.md §4.5.1, §5.5 and docs/API_CONTRACT.md §4.6.
//

// MARK: - Limits

/// Hard bounds every scan honours so that a hostile datagram cannot exhaust memory or stack.
///
/// The defaults are sized for the two discovery formats: a SADP `ProbeMatch` is 700–2 500 bytes and
/// two levels deep, an ONVIF `ProbeMatches` envelope is up to ~2 kB and five levels deep. Reaching
/// any bound stops the scan and is reported as `Outcome.hitLimit`; callers turn that into a
/// diagnostic and keep whatever was collected, because a truncated real camera is still a camera.
public struct XMLScanLimits: Sendable, Hashable {

    /// Maximum number of start tags processed. The scan stops once it is exceeded.
    public var maxElements: Int

    /// Maximum element nesting held on the stack. Reaching it stops the scan; neither wire format
    /// is ever deeper than five, so this only ever fires on a nesting bomb.
    public var maxDepth: Int

    /// Maximum UTF-8 bytes buffered for one text node or attribute value. Further bytes are
    /// dropped rather than buffered.
    public var maxTextBytes: Int

    /// Maximum attributes retained for one element. Further attributes are parsed (so the scan
    /// stays in sync) but discarded.
    public var maxAttributes: Int

    /// Maximum UTF-8 bytes retained for one element or attribute name; longer names are truncated.
    public var maxNameBytes: Int

    /// Creates a bound set. Every value is a hard stop, never a target.
    public init(maxElements: Int = 1_024,
                maxDepth: Int = 32,
                maxTextBytes: Int = 8_192,
                maxAttributes: Int = 16,
                maxNameBytes: Int = 128) {
        self.maxElements = maxElements
        self.maxDepth = maxDepth
        self.maxTextBytes = maxTextBytes
        self.maxAttributes = maxAttributes
        self.maxNameBytes = maxNameBytes
    }

    /// The bounds both discovery decoders use, derived from the 8 192-byte datagram cap (§4.1).
    public static let discovery = XMLScanLimits()
}

// MARK: - Scanner

/// A total, non-throwing XML reader that emits a flat event stream.
///
/// What it deliberately does **not** do, and why:
///
/// * **No entity expansion.** `<!DOCTYPE …>` and `<!ENTITY …>` declarations are skipped whole and
///   an undefined `&name;` is passed through verbatim, so the billion-laughs family of XML bombs
///   expands to nothing here. Only the five predefined entities and numeric character references
///   are decoded.
/// * **No recursion.** Nesting is a stack of names bounded by `XMLScanLimits.maxDepth`, so a
///   deeply nested document cannot overflow the Swift stack.
/// * **No validation.** Mismatched or missing end tags are reported through `Outcome.isBalanced`;
///   at end of input every still-open element is closed synthetically so a truncated datagram still
///   delivers the fields that did arrive.
///
/// Element and attribute names are reported as **lowercased local names** — any `prefix:` is
/// stripped — because both wire formats vary in case and namespace prefix across firmware.
public enum LenientXMLScanner {

    /// One parse event. `start` is always paired with an `end`, including for self-closing tags and
    /// for elements closed synthetically at end of input.
    public enum Event: Sendable, Equatable {
        /// An element opened. `name` is the lowercased local name; attribute keys are likewise.
        case start(name: String, attributes: [String: String])
        /// Character data inside the innermost open element, with entities decoded. Text outside
        /// any element (prolog whitespace) is discarded rather than reported.
        case text(String)
        /// An element closed, by an end tag, by being self-closing, or synthetically at input end.
        case end(name: String)
    }

    /// What the scan saw, for callers that must distinguish "truncated but usable" from "garbage".
    public struct Outcome: Sendable, Hashable {
        /// True when at least one start tag was parsed.
        public let sawElement: Bool
        /// True when every element was closed by a matching end tag before input ended.
        public let isBalanced: Bool
        /// Number of start tags parsed.
        public let elementCount: Int
        /// True when any bound in `XMLScanLimits` was reached, which also stops the scan.
        public let hitLimit: Bool
    }

    /// Scans `source` and delivers events to `handle` in document order.
    ///
    /// The closure is non-escaping and is called synchronously; a collector is normally a local
    /// `var` captured by it. The scan always terminates: every branch advances the cursor, and the
    /// three limits bound the work at O(input).
    ///
    /// - Parameters:
    ///   - source: the datagram text, already decoded from bytes by the caller.
    ///   - limits: the bounds to honour; `.discovery` unless a test needs something tighter.
    ///   - handle: receives each event in order.
    /// - Returns: a summary of what was parsed. Never throws and never traps, whatever the input.
    public static func scan(_ source: String,
                            limits: XMLScanLimits = .discovery,
                            handle: (Event) -> Void) -> Outcome {
        let bytes = Array(source.utf8)
        var index = 0
        var stack: [String] = []
        var pending: [UInt8] = []
        var elementCount = 0
        var hitLimit = false
        var balanced = true

        func appendText(_ byte: UInt8) {
            if pending.count < limits.maxTextBytes {
                pending.append(byte)
            } else {
                hitLimit = true
            }
        }

        func flushText() {
            guard !pending.isEmpty else { return }
            if !stack.isEmpty {
                handle(.text(decodedEntities(pending[...])))
            }
            pending.removeAll(keepingCapacity: true)
        }

        scanning: while index < bytes.count {
            guard bytes[index] == Byte.lessThan else {
                appendText(bytes[index])
                index += 1
                continue
            }
            flushText()

            if matches(bytes, at: index, "<!--") {
                index = skip(bytes, from: index + 4, past: "-->")
                continue
            }
            if matches(bytes, at: index, "<![CDATA[") {
                let start = index + 9
                let close = find(bytes, from: start, "]]>")
                let end = close ?? bytes.count
                if !stack.isEmpty, end > start {
                    let count = min(end - start, limits.maxTextBytes)
                    handle(.text(String(decoding: bytes[start..<(start + count)], as: UTF8.self)))
                    if end - start > count { hitLimit = true }
                }
                index = close.map { $0 + 3 } ?? bytes.count
                continue
            }
            if matches(bytes, at: index, "<?") {
                index = skip(bytes, from: index + 2, past: "?>")
                continue
            }
            if matches(bytes, at: index, "<!") {
                // DOCTYPE and any internal subset: skipped whole. This is what makes entity
                // expansion impossible rather than merely bounded.
                index = skipDeclaration(bytes, from: index + 2)
                continue
            }

            if matches(bytes, at: index, "</") {
                var cursor = index + 2
                let name = readName(bytes, from: &cursor, limit: limits.maxNameBytes)
                index = skip(bytes, from: cursor, past: ">")
                guard !name.isEmpty else { balanced = false; continue }
                if let position = stack.lastIndex(of: name) {
                    if stack.count > position + 1 { balanced = false }
                    while stack.count > position {
                        if let top = stack.popLast() { handle(.end(name: top)) }
                    }
                } else {
                    balanced = false            // an end tag for something never opened
                }
                continue
            }

            var cursor = index + 1
            let name = readName(bytes, from: &cursor, limit: limits.maxNameBytes)
            guard !name.isEmpty else {
                // A bare "<" that opens nothing: keep it as text rather than losing content.
                appendText(Byte.lessThan)
                index += 1
                continue
            }
            var attributes: [String: String] = [:]
            let close = readAttributes(bytes, from: &cursor, into: &attributes, limits: limits)
            index = cursor
            elementCount += 1
            if elementCount > limits.maxElements {
                hitLimit = true
                balanced = false
                break scanning
            }
            handle(.start(name: name, attributes: attributes))
            switch close {
            case .selfClosing:
                handle(.end(name: name))
            case .truncated:
                balanced = false
                handle(.end(name: name))
                break scanning
            case .open:
                if stack.count >= limits.maxDepth {
                    hitLimit = true
                    balanced = false
                    handle(.end(name: name))
                    break scanning
                }
                stack.append(name)
            }
        }

        flushText()
        if !stack.isEmpty {
            balanced = false
            while let top = stack.popLast() { handle(.end(name: top)) }
        }
        return Outcome(sawElement: elementCount > 0, isBalanced: balanced,
                       elementCount: elementCount, hitLimit: hitLimit)
    }

    // MARK: - Tag internals

    /// How a start tag ended: normally, self-closing, or by running off the end of the input.
    private enum TagClose {
        case open
        case selfClosing
        case truncated
    }

    private static func readAttributes(_ bytes: [UInt8],
                                       from cursor: inout Int,
                                       into attributes: inout [String: String],
                                       limits: XMLScanLimits) -> TagClose {
        var kept = 0
        while cursor < bytes.count {
            skipWhitespace(bytes, from: &cursor)
            guard cursor < bytes.count else { break }
            let byte = bytes[cursor]
            if byte == Byte.greaterThan {
                cursor += 1
                return .open
            }
            if byte == Byte.slash {
                cursor += 1
                skipWhitespace(bytes, from: &cursor)
                if cursor < bytes.count, bytes[cursor] == Byte.greaterThan {
                    cursor += 1
                    return .selfClosing
                }
                continue
            }
            let name = readName(bytes, from: &cursor, limit: limits.maxNameBytes)
            guard !name.isEmpty else {
                cursor += 1                     // never stall on an unexpected byte
                continue
            }
            skipWhitespace(bytes, from: &cursor)
            guard cursor < bytes.count, bytes[cursor] == Byte.equals else { continue }
            cursor += 1
            skipWhitespace(bytes, from: &cursor)
            let value = readAttributeValue(bytes, from: &cursor, limit: limits.maxTextBytes)
            if kept < limits.maxAttributes {
                attributes[name] = value
                kept += 1
            }
        }
        return .truncated
    }

    private static func readAttributeValue(_ bytes: [UInt8], from cursor: inout Int,
                                           limit: Int) -> String {
        guard cursor < bytes.count else { return "" }
        let quote = bytes[cursor]
        let start: Int
        let end: Int
        if quote == Byte.doubleQuote || quote == Byte.singleQuote {
            start = cursor + 1
            var scan = start
            while scan < bytes.count, bytes[scan] != quote { scan += 1 }
            end = scan
            cursor = min(scan + 1, bytes.count)
        } else {
            start = cursor
            var scan = cursor
            while scan < bytes.count, !isNameTerminator(bytes[scan]) { scan += 1 }
            end = scan
            cursor = scan
        }
        let count = min(end - start, limit)
        guard count > 0 else { return "" }
        return decodedEntities(bytes[start..<(start + count)])
    }

    /// Reads an element or attribute name, strips any `prefix:` and lowercases the ASCII letters.
    private static func readName(_ bytes: [UInt8], from cursor: inout Int, limit: Int) -> String {
        var name: [UInt8] = []
        var colonIndex = -1
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if isNameTerminator(byte) { break }
            if byte == Byte.colon { colonIndex = name.count }
            if name.count < limit { name.append(byte) }
            cursor += 1
        }
        if colonIndex >= 0, colonIndex + 1 <= name.count {
            name.removeFirst(colonIndex + 1)
        }
        for position in name.indices where name[position] >= Byte.upperA && name[position] <= Byte.upperZ {
            name[position] &+= 32
        }
        return String(decoding: name, as: UTF8.self)
    }

    // MARK: - Entity decoding

    /// Decodes the five predefined entities and numeric character references, and passes anything
    /// else — including an undefined `&name;` and a bare `&` — through byte for byte.
    private static func decodedEntities(_ bytes: ArraySlice<UInt8>) -> String {
        guard bytes.contains(Byte.ampersand) else {
            return String(decoding: bytes, as: UTF8.self)
        }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard bytes[index] == Byte.ampersand else {
                out.append(bytes[index])
                index += 1
                continue
            }
            // A reference is at most "&#x10FFFF;" — 10 bytes. Anything longer is not one.
            let limit = min(index + 12, bytes.endIndex)
            var terminator = index + 1
            while terminator < limit, bytes[terminator] != Byte.semicolon { terminator += 1 }
            guard terminator < limit, bytes[terminator] == Byte.semicolon else {
                out.append(bytes[index])
                index += 1
                continue
            }
            let body = bytes[(index + 1)..<terminator]
            if let replacement = expansion(of: body) {
                out.append(contentsOf: replacement)
                index = terminator + 1
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func expansion(of body: ArraySlice<UInt8>) -> [UInt8]? {
        switch String(decoding: body, as: UTF8.self) {
        case "amp":  return [Byte.ampersand]
        case "lt":   return [Byte.lessThan]
        case "gt":   return [Byte.greaterThan]
        case "quot": return [Byte.doubleQuote]
        case "apos": return [Byte.singleQuote]
        default: break
        }
        guard body.first == Byte.hash, body.count >= 2 else { return nil }
        let digits = body.dropFirst()
        let value: UInt32?
        if digits.first == Byte.lowerX || digits.first == Byte.upperX {
            value = UInt32(String(decoding: digits.dropFirst(), as: UTF8.self), radix: 16)
        } else {
            value = UInt32(String(decoding: digits, as: UTF8.self), radix: 10)
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return Array(String(scalar).utf8)
    }

    // MARK: - Byte helpers

    private enum Byte {
        static let lessThan = UInt8(ascii: "<")
        static let greaterThan = UInt8(ascii: ">")
        static let slash = UInt8(ascii: "/")
        static let equals = UInt8(ascii: "=")
        static let colon = UInt8(ascii: ":")
        static let doubleQuote = UInt8(ascii: "\"")
        static let singleQuote = UInt8(ascii: "'")
        static let ampersand = UInt8(ascii: "&")
        static let semicolon = UInt8(ascii: ";")
        static let hash = UInt8(ascii: "#")
        static let lowerX = UInt8(ascii: "x")
        static let upperX = UInt8(ascii: "X")
        static let upperA = UInt8(ascii: "A")
        static let upperZ = UInt8(ascii: "Z")
        static let openBracket = UInt8(ascii: "[")
        static let closeBracket = UInt8(ascii: "]")
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isNameTerminator(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || byte == Byte.slash || byte == Byte.greaterThan
            || byte == Byte.lessThan || byte == Byte.equals
            || byte == Byte.doubleQuote || byte == Byte.singleQuote
    }

    private static func skipWhitespace(_ bytes: [UInt8], from cursor: inout Int) {
        while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
    }

    private static func matches(_ bytes: [UInt8], at index: Int, _ literal: String) -> Bool {
        let pattern = Array(literal.utf8)
        guard index + pattern.count <= bytes.count else { return false }
        for offset in pattern.indices where bytes[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    private static func find(_ bytes: [UInt8], from index: Int, _ literal: String) -> Int? {
        let pattern = Array(literal.utf8)
        guard !pattern.isEmpty, index >= 0 else { return nil }
        var cursor = index
        while cursor + pattern.count <= bytes.count {
            if matches(bytes, at: cursor, literal) { return cursor }
            cursor += 1
        }
        return nil
    }

    /// Index just past `literal`, or the end of input when it never appears. Always advances.
    private static func skip(_ bytes: [UInt8], from index: Int, past literal: String) -> Int {
        guard let hit = find(bytes, from: index, literal) else { return bytes.count }
        return hit + literal.utf8.count
    }

    /// Skips a `<! … >` declaration, including a bracketed internal subset, without reading it.
    private static func skipDeclaration(_ bytes: [UInt8], from index: Int) -> Int {
        var cursor = index
        var inSubset = false
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte == Byte.openBracket { inSubset = true }
            if byte == Byte.closeBracket { inSubset = false }
            if byte == Byte.greaterThan, !inSubset { return cursor + 1 }
            cursor += 1
        }
        return bytes.count
    }
}
