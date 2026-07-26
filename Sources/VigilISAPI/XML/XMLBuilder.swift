//
//  XMLBuilder.swift
//  VigilISAPI
//
//  The ordered request-body builder and the escaping rules both it and `XMLNode.serialized` use.
//  Implements docs/spec-isapi.md §8.
//
//  Element **order matters** to Hikvision's XML validator on several firmwares (notably
//  `<PTZData>` and `<CMSearchDescription>`), so nothing here is backed by a dictionary and nothing
//  sorts. What the caller adds, in the order it adds it, is what goes on the wire.
//

import Foundation

// MARK: - Escaping

/// The five entity substitutions ISAPI bodies need, and nothing else.
///
/// No numeric character references, no pretty-printing: a smaller body and one fewer thing for a
/// 5.2.x parser to reject.
enum XMLEscaping {

    /// Escapes `&`, `<`, `>`, `"` and `'` in that order of checking. `&` must be first or the
    /// escapes escape each other.
    static func escape(_ text: String) -> String {
        guard text.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" || $0 == "\"" || $0 == "'" })
        else { return text }
        var out = ""
        out.reserveCapacity(text.count + 8)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }
}

// MARK: - XMLBuilder

/// An ordered XML body builder.
///
/// Always emits `<?xml version="1.0" encoding="UTF-8"?>` and a newline: some 5.2.x firmwares reject
/// a body without the declaration with `invalidXMLFormat`, and the declaration costs 39 bytes.
///
/// Namespace policy (spec-isapi §8): constructed bodies (`PTZData`, `CMSearchDescription`,
/// `TwoWayAudioChannel`) carry **no** `xmlns` and **no** `version`; read-modify-write bodies echo
/// back the attributes exactly as they were received on the `GET`, which is what
/// `init(root:attributes:)` is for.
public struct XMLBuilder: Sendable {

    /// The root element's name.
    private let root: String

    /// The root element's attributes, in the order given.
    private let attributes: [(String, String)]

    /// Serialized children, already escaped, in insertion order.
    private var body: String = ""

    /// Starts a body with `root` as the document element.
    public init(_ root: String, attributes: [(String, String)] = []) {
        self.root = root
        self.attributes = attributes
    }

    // MARK: Adding

    /// Appends `<name>value</name>` with `value` escaped.
    public mutating func add(_ name: String, _ value: String) {
        body += "<\(name)>\(XMLEscaping.escape(value))</\(name)>"
    }

    /// Appends an integer-valued element, rendered without grouping or a sign for positives.
    public mutating func add(_ name: String, _ value: Int) {
        body += "<\(name)>\(value)</\(name)>"
    }

    /// Appends a boolean-valued element as `true`/`false` — the only spelling every firmware
    /// accepts on input, even though several emit `yes`/`no` on output.
    public mutating func add(_ name: String, _ value: Bool) {
        body += "<\(name)>\(value ? "true" : "false")</\(name)>"
    }

    /// Appends an element only when `value` is non-`nil`. The common shape of a PUT that must not
    /// send a field the caller did not set.
    public mutating func addIfPresent(_ name: String, _ value: String?) {
        if let value { add(name, value) }
    }

    /// Appends an integer element only when `value` is non-`nil`.
    public mutating func addIfPresent(_ name: String, _ value: Int?) {
        if let value { add(name, value) }
    }

    /// Appends a boolean element only when `value` is non-`nil`.
    public mutating func addIfPresent(_ name: String, _ value: Bool?) {
        if let value { add(name, value) }
    }

    /// Appends a nested element built by `build`.
    ///
    /// The nested builder's own root is `name`; its declaration is dropped, so nesting never
    /// produces a second `<?xml …?>`.
    public mutating func addChild(_ name: String, attributes: [(String, String)] = [],
                                  _ build: (inout XMLBuilder) -> Void) {
        var child = XMLBuilder(name, attributes: attributes)
        build(&child)
        body += child.elementString
    }

    /// Appends a pre-escaped fragment verbatim.
    ///
    /// The one way to put arbitrary text into a body, and therefore the one thing a caller can get
    /// wrong: nothing is escaped, nothing is validated. Tests and round-tripped subtrees only.
    public mutating func addRaw(_ xmlFragment: String) {
        body += xmlFragment
    }

    // MARK: Output

    /// The root element with no declaration.
    var elementString: String {
        var out = "<" + root
        for (name, value) in attributes {
            out += " \(name)=\"\(XMLEscaping.escape(value))\""
        }
        if body.isEmpty { return out + "/>" }
        return out + ">" + body + "</" + root + ">"
    }

    /// The complete document, declaration included.
    public var stringValue: String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + elementString
    }

    /// The complete document as UTF-8 bytes — what goes in the request body.
    public func data() -> Data { Data(stringValue.utf8) }
}
