//
//  XMLNode.swift
//  VigilISAPI
//
//  The parsed XML tree and the path grammar used to read it: namespace-agnostic, case-insensitive,
//  tolerant of elements no firmware we have seen yet emits.
//  Implements docs/spec-isapi.md §7.2 and §7.3, and docs/API_CONTRACT.md §4.5.
//
//  There is no `Codable` decoding anywhere in this module by design (spec-isapi §7.1): the same
//  logical field arrives as `<SharpnessLevel>` and `<sharpnessLevel>`, as a single element on one
//  firmware and a list on the next, with `ver10`, `ver20` or no namespace at all. `CodingKeys`
//  cannot express "either of these", and a `DecodingError` cannot say which siblings *were* there.
//

import Foundation

// MARK: - XMLNode

/// One element of a parsed ISAPI document.
///
/// The tree is kept whole — including elements Vigil does not understand — so that a read-modify-
/// write `PUT` can echo unknown elements back untouched, and so a failed read can name the
/// siblings that *were* present.
public struct XMLNode: Sendable, Hashable {

    /// Local name with the original casing, namespace prefix stripped: `hik:Video` reads `Video`.
    public let name: String

    /// `name.lowercased()`, precomputed once. Every path match compares against this.
    public let key: String

    /// Attributes, keyed by lowercased name, values verbatim.
    public let attributes: [String: String]

    /// Concatenated character data, trimmed at the ends, interior whitespace preserved. CDATA is
    /// merged in. Empty when the element has only children.
    public let text: String

    /// Child elements in document order.
    public let children: [XMLNode]

    /// Builds a node. `key` is derived; callers never supply it.
    public init(name: String, attributes: [String: String] = [:],
                text: String = "", children: [XMLNode] = []) {
        self.name = name
        self.key = name.lowercased()
        self.attributes = attributes
        self.text = text
        self.children = children
    }

    // MARK: Reading

    /// The value at `path`, whether or not anything is there.
    ///
    /// Never traps and never throws: an absent path yields a value whose `exists` is `false` and
    /// whose typed accessors are `nil`. Use `XMLValue.required…()` where absence is a hard error.
    public subscript(_ path: String) -> XMLValue {
        let compiled = XMLPath(path)
        let match = compiled.resolve(from: self)
        return XMLValue(node: match.nodes.first, attribute: match.attribute,
                        path: path, parent: match.parent ?? self)
    }

    /// The first element at `path`, or `nil`. An `@attr` path never yields a node.
    public func node(_ path: String) -> XMLNode? {
        XMLPath(path).resolve(from: self).nodes.first
    }

    /// Every element at `path`, in document order. Empty when nothing matches.
    ///
    /// This is the answer to Hikvision's cardinality variance: a firmware that emits one
    /// `<TimeBlock>` and a firmware that emits eight are read by the same call, and the caller
    /// never has to know which it is talking to.
    public func nodes(_ path: String) -> [XMLNode] {
        XMLPath(path).resolve(from: self).nodes
    }

    /// True when at least one element or attribute matches `path`.
    public func has(_ path: String) -> Bool {
        let match = XMLPath(path).resolve(from: self)
        return !match.nodes.isEmpty || match.attribute != nil
    }

    /// The lowercased names of this element's direct children, for diagnostics.
    public var childKeys: [String] { children.map(\.key) }

    // MARK: Writing

    /// A copy with the text at `path` replaced.
    ///
    /// Only plain child-chain paths (`Video/videoQualityControlType`, alternation included) are
    /// supported; a path containing `*`, `**`, an index or an attribute returns the receiver
    /// unchanged, because a read-modify-write body must never guess where to write. When a
    /// segment is missing and `createIfMissing` is true the intermediate elements are appended in
    /// order; when it is false the receiver is returned unchanged.
    public func setting(_ path: String, to value: String,
                        createIfMissing: Bool = false) -> XMLNode {
        guard let names = XMLPath(path).plainChildChain(), !names.isEmpty else { return self }
        return setting(chain: names[...], to: value, createIfMissing: createIfMissing)
    }

    /// Recursive worker for `setting(_:to:createIfMissing:)`.
    private func setting(chain: ArraySlice<[String]>, to value: String,
                         createIfMissing: Bool) -> XMLNode {
        guard let alternatives = chain.first else {
            return XMLNode(name: name, attributes: attributes, text: value, children: children)
        }
        let rest = chain.dropFirst()
        let index = children.firstIndex { child in
            alternatives.contains(child.key)
        }
        if let index {
            var updated = children
            updated[index] = children[index].setting(chain: rest, to: value,
                                                     createIfMissing: createIfMissing)
            return XMLNode(name: name, attributes: attributes, text: text, children: updated)
        }
        guard createIfMissing, let newName = alternatives.first else { return self }
        let fresh = XMLNode(name: newName).setting(chain: rest, to: value, createIfMissing: true)
        return XMLNode(name: name, attributes: attributes, text: text, children: children + [fresh])
    }

    // MARK: Serialization

    /// This subtree as XML bytes, unknown elements and attributes preserved.
    ///
    /// Attribute order is sorted by name so the output is byte-stable across runs — a
    /// `Dictionary`'s order is not, and a read-modify-write body that changes shape between two
    /// identical calls is untestable. No pretty-printing: one 5.2.x firmware rejects an indented
    /// `<PTZData>`.
    public func serialized(declaration: Bool = true) -> Data {
        var out = declaration ? "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" : ""
        append(to: &out)
        return Data(out.utf8)
    }

    /// Appends this subtree's XML text to `out`.
    private func append(to out: inout String) {
        out += "<" + name
        for attributeName in attributes.keys.sorted() {
            let value = attributes[attributeName] ?? ""
            out += " \(attributeName)=\"\(XMLEscaping.escape(value))\""
        }
        if children.isEmpty && text.isEmpty {
            out += "/>"
            return
        }
        out += ">"
        if !text.isEmpty { out += XMLEscaping.escape(text) }
        for child in children { child.append(to: &out) }
        out += "</" + name + ">"
    }
}

// MARK: - Path grammar

/// A compiled path expression.
///
/// Compilation is a handful of string splits over a literal that is almost always a compile-time
/// constant, so it is done on demand rather than memoised: the spec's `static let` cache would be
/// shared mutable state, which the pure layer may not hold without a lock, and the lock would cost
/// more than the split it saves. See the deviation note in the module result.
struct XMLPath: Sendable {

    /// One step of a path.
    enum Segment: Sendable, Hashable {

        /// `.` — the receiving element itself.
        case selfNode

        /// `*` — exactly one level, any name.
        case anyChild

        /// `**` — zero or more levels, breadth-first.
        case descendantOrSelf

        /// A named child with alternation and an optional index selector.
        case named(alternatives: [String], selector: Selector)

        /// `@attr` — an attribute of the addressed element. Terminal.
        case attribute(String)

        /// Which of several same-named siblings a segment addresses.
        enum Selector: Sendable, Hashable {
            /// No selector: every match, in document order.
            case any
            /// `[n]`, zero-based.
            case index(Int)
            /// `[]`, explicitly every sibling.
            case all
        }
    }

    /// Whole-path alternatives, split on `||` and tried left to right.
    let alternatives: [[Segment]]

    /// Compiles `literal`. A malformed literal compiles to a path that matches nothing rather than
    /// throwing: paths are constants in this module, and a throwing accessor would push `try` into
    /// every read of every optional field.
    init(_ literal: String) {
        alternatives = literal
            .components(separatedBy: "||")
            .map { Self.compile($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Compiles one whole-path alternative into segments.
    private static func compile(_ text: String) -> [Segment] {
        text.split(separator: "/", omittingEmptySubsequences: true).compactMap { raw in
            let piece = raw.trimmingCharacters(in: .whitespaces)
            switch piece {
            case "": return nil
            case ".": return .selfNode
            case "*": return .anyChild
            case "**": return .descendantOrSelf
            default: break
            }
            if piece.hasPrefix("@") {
                return .attribute(String(piece.dropFirst()).lowercased())
            }
            var body = piece
            var selector = Segment.Selector.any
            if body.hasSuffix("]"), let open = body.lastIndex(of: "[") {
                let inside = String(body[body.index(after: open)..<body.index(before: body.endIndex)])
                body = String(body[body.startIndex..<open])
                if inside.isEmpty {
                    selector = .all
                } else if let n = Int(inside), n >= 0 {
                    selector = .index(n)
                } else {
                    // An unparseable selector must not silently become "every sibling".
                    return .named(alternatives: [], selector: .any)
                }
            }
            let names = body.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { $0.lowercased() }
            return .named(alternatives: names, selector: selector)
        }
    }

    /// The result of resolving a path: the matched elements, the matched attribute (if the path
    /// ended in `@attr`), and the element the last segment searched inside — the parent whose
    /// children a diagnostic enumerates.
    struct Match: Sendable {
        var nodes: [XMLNode] = []
        var attribute: String?
        var parent: XMLNode?
    }

    /// Resolves against `root`, trying whole-path alternatives in order; the first that matches
    /// anything wins. When none matches, the result carries the parent of the *first* alternative
    /// so the error message names the siblings the caller most likely meant.
    func resolve(from root: XMLNode) -> Match {
        var firstMiss: Match?
        for segments in alternatives {
            let match = Self.resolve(segments[...], cursors: [root], parent: root)
            if !match.nodes.isEmpty || match.attribute != nil { return match }
            if firstMiss == nil { firstMiss = match }
        }
        return firstMiss ?? Match(nodes: [], attribute: nil, parent: root)
    }

    /// Walks `segments` from `cursors`. `parent` is the element the previous segment matched in.
    private static func resolve(_ segments: ArraySlice<Segment>,
                                cursors: [XMLNode],
                                parent: XMLNode?) -> Match {
        guard let segment = segments.first else {
            return Match(nodes: cursors, attribute: nil, parent: parent)
        }
        let rest = segments.dropFirst()
        switch segment {
        case .selfNode:
            return resolve(rest, cursors: cursors, parent: parent)

        case .anyChild:
            let next = cursors.flatMap(\.children)
            return resolve(rest, cursors: next, parent: cursors.first ?? parent)

        case .descendantOrSelf:
            var seen: [XMLNode] = []
            var queue = cursors
            while !queue.isEmpty {
                let node = queue.removeFirst()
                seen.append(node)
                queue.append(contentsOf: node.children)
            }
            return resolve(rest, cursors: seen, parent: cursors.first ?? parent)

        case let .named(alternatives, selector):
            var matched: [XMLNode] = []
            var searched: XMLNode? = parent
            for cursor in cursors {
                guard let hits = firstMatchingAlternative(alternatives, in: cursor) else { continue }
                if searched == nil || matched.isEmpty { searched = cursor }
                switch selector {
                case .any, .all:
                    matched.append(contentsOf: hits)
                case let .index(n):
                    if n < hits.count { matched.append(hits[n]) }
                }
            }
            if matched.isEmpty { searched = cursors.first ?? parent }
            return resolve(rest, cursors: matched, parent: searched)

        case let .attribute(name):
            let value = cursors.compactMap { $0.attributes[name] }.first
            return Match(nodes: [], attribute: value, parent: cursors.first ?? parent)
        }
    }

    /// The children of `cursor` matching the first alternative that matches anything.
    ///
    /// Left-to-right: `Sharpness/SharpnessLevel|sharpnessLevel` reads the capitalised spelling when
    /// the firmware emits it and the lowercase one when it does not, never both.
    private static func firstMatchingAlternative(_ alternatives: [String],
                                                 in cursor: XMLNode) -> [XMLNode]? {
        for candidate in alternatives {
            let hits = cursor.children.filter { $0.key == candidate }
            if !hits.isEmpty { return hits }
        }
        return nil
    }

    /// The path as a plain chain of child-name alternatives, or `nil` when it uses any feature a
    /// write cannot follow (`*`, `**`, an index, an attribute, or whole-path alternation).
    func plainChildChain() -> [[String]]? {
        guard alternatives.count == 1, let segments = alternatives.first else { return nil }
        var out: [[String]] = []
        for segment in segments {
            guard case let .named(names, selector) = segment, selector == .any, !names.isEmpty else {
                return nil
            }
            out.append(names)
        }
        return out
    }
}
