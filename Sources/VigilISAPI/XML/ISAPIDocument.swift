//
//  ISAPIDocument.swift
//  VigilISAPI
//
//  The parser: a SAX walk that builds the whole tree on an explicit stack, with the hard caps and
//  the XXE defences that make it safe to point at a device on an untrusted network.
//  Implements docs/spec-isapi.md §7.6 and docs/API_CONTRACT.md §4.5.
//
//  `XMLParser` (SAX) is the only XML API that is reliably present on both macOS and Linux
//  corelibs; `XMLDocument`/XPath is not. Namespaces are stripped by hand rather than by the
//  parser's namespace processing, because Hikvision firmware ships malformed namespace
//  declarations and the parser's own handling of them varies between the two platforms.
//

import Foundation
import VigilProtocols
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - ISAPIDocument

/// A parsed ISAPI response document.
///
/// Paths are relative to the **root's children**: the root element's own name is never part of a
/// path, because the same payload appears under `<StreamingChannel>` and `<StreamingChannelList>`
/// depending on the endpoint and the caller should not have to care.
public struct ISAPIDocument: Sendable {

    /// Largest body this parser will look at. `/System/capabilities` peaks near 90 KiB and a 4K
    /// JPEG snapshot near 1.5 MiB, so 8 MiB is a wide margin around anything legitimate.
    public static let maximumBytes = 8 << 20

    /// Deepest element nesting accepted. Real documents reach eight; sixty-four is a defence
    /// against a hostile body that would otherwise grow the stack without bound.
    public static let maximumDepth = 64

    /// The document element.
    public let root: XMLNode

    /// True when the parser hit an error *after* the root element closed and the tree was kept —
    /// some firmware appends a stray NUL byte to every response.
    public let hasTrailingGarbage: Bool

    /// True when the body declared a non-UTF-8 encoding and was read byte-for-byte as Latin-1.
    /// Only free-text fields (channel names) are affected; the UI shows them with a placeholder.
    public let nonUTF8Payload: Bool

    /// Wraps an already-built tree. Used by tests and by the few endpoints that synthesise a
    /// document from a non-XML response.
    public init(root: XMLNode, hasTrailingGarbage: Bool = false, nonUTF8Payload: Bool = false) {
        self.root = root
        self.hasTrailingGarbage = hasTrailingGarbage
        self.nonUTF8Payload = nonUTF8Payload
    }

    /// Parses `data`.
    ///
    /// - Throws: `ISAPIError.responseTooLarge` beyond 8 MiB; `ISAPIError.malformedResponse` for a
    ///   body that is not XML at all (an HTML login page, which a device with web-auth
    ///   misconfigured returns with HTTP 200), for nesting beyond 64 levels, and for a parse
    ///   failure before the root element closed. A failure *after* the root closed is tolerated and
    ///   reported through `hasTrailingGarbage`.
    public init(parsing data: Data) throws(ISAPIError) {
        guard data.count <= Self.maximumBytes else {
            throw ISAPIError.responseTooLarge(bytes: data.count)
        }
        guard Self.looksLikeXML(data) else {
            throw ISAPIError.malformedResponse("not XML: body begins \"\(Self.preview(data))\"")
        }

        var payload = data
        var transcoded = false
        if Self.declaresLegacyChineseEncoding(data), let recoded = Self.transcodeLatin1(data) {
            payload = recoded
            transcoded = true
        }

        let builder = XMLTreeBuilder(maximumDepth: Self.maximumDepth)
        let parser = XMLParser(data: payload)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let completed = parser.parse()

        guard let parsed = builder.root else {
            if builder.depthExceeded {
                throw ISAPIError.malformedResponse(
                    "XML nested deeper than \(Self.maximumDepth) levels")
            }
            let reason = builder.failureDescription ?? parser.parserError.map(String.init(describing:))
            throw ISAPIError.malformedResponse("XML parse failed: \(reason ?? "unknown error")")
        }
        if builder.depthExceeded {
            throw ISAPIError.malformedResponse("XML nested deeper than \(Self.maximumDepth) levels")
        }
        guard parsed.key != "html" else {
            throw ISAPIError.malformedResponse("not XML: the device returned an HTML page")
        }
        root = parsed
        // A failure once the root has closed is trailing garbage, not a broken document.
        hasTrailingGarbage = !completed
        nonUTF8Payload = transcoded
    }

    // MARK: Reading

    /// The document element's name, original casing.
    public var rootName: String { root.name }

    /// The value at `path`, relative to the root's children.
    public subscript(_ path: String) -> XMLValue { root[path] }

    /// The first element at `path`, or `nil`.
    public func node(_ path: String) -> XMLNode? { root.node(path) }

    /// Every element at `path`, in document order.
    public func nodes(_ path: String) -> [XMLNode] { root.nodes(path) }

    /// True when anything matches `path`.
    public func has(_ path: String) -> Bool { root.has(path) }

    // MARK: Sniffing

    /// True when the first non-whitespace byte is `<`.
    ///
    /// This is the check that turns "missing element `DeviceInfo/model`" — a confusing message
    /// about a document that was never XML — into "the device returned an HTML page".
    public static func looksLikeXML(_ data: Data) -> Bool {
        for byte in data {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF: continue   // whitespace and a UTF-8 BOM
            case UInt8(ascii: "<"): return true
            default: return false
            }
        }
        return false
    }

    /// The first 48 bytes as printable text, for an error message. Control bytes become `.`.
    static func preview(_ data: Data) -> String {
        let head = data.prefix(48).map { byte -> Character in
            (byte >= 0x20 && byte < 0x7F) ? Character(UnicodeScalar(byte)) : "."
        }
        return String(head)
    }

    /// True when the XML declaration names `gb2312` or `gbk`.
    static func declaresLegacyChineseEncoding(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(128), as: UTF8.self).lowercased()
        guard head.hasPrefix("<?xml") else { return false }
        return head.contains("gb2312") || head.contains("gbk") || head.contains("gb18030")
    }

    /// Reads `data` as Latin-1 and re-encodes it as UTF-8 with a UTF-8 declaration.
    ///
    /// A deliberate approximation: the multi-byte GB sequences become mojibake rather than the
    /// right glyphs, but every ASCII element name, number and enumeration value — everything the
    /// app makes a decision from — survives intact, and the alternative on Linux is a parse
    /// failure that loses the whole response. Callers see `nonUTF8Payload == true`.
    static func transcodeLatin1(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        var rewritten = text
        for spelling in ["gb2312", "GB2312", "gbk", "GBK", "gb18030", "GB18030"] {
            rewritten = rewritten.replacingOccurrences(of: "encoding=\"\(spelling)\"",
                                                       with: "encoding=\"UTF-8\"")
            rewritten = rewritten.replacingOccurrences(of: "encoding='\(spelling)'",
                                                       with: "encoding='UTF-8'")
        }
        return Data(rewritten.utf8)
    }
}

// MARK: - Tree builder

/// The SAX delegate. Builds nodes on an explicit stack — no recursion, so the depth cap is enforced
/// by counting rather than by the C stack running out.
///
/// Not `Sendable` and never needs to be: it is created, driven and dropped inside one synchronous
/// call to `ISAPIDocument.init(parsing:)`.
private final class XMLTreeBuilder: NSObject, XMLParserDelegate {

    /// One open element.
    private struct Frame {
        var name: String
        var attributes: [String: String]
        var text: String
        var children: [XMLNode]
    }

    /// Open elements, outermost first.
    private var stack: [Frame] = []

    /// The finished document element, set when the outermost element closes.
    private(set) var root: XMLNode?

    /// True once an element was opened beyond the depth cap.
    private(set) var depthExceeded = false

    /// The parse error, when one occurred.
    private(set) var failureDescription: String?

    /// The cap this builder enforces.
    private let maximumDepth: Int

    init(maximumDepth: Int) {
        self.maximumDepth = maximumDepth
    }

    /// Strips a namespace prefix: `hik:Video` becomes `Video`, `Video` stays `Video`.
    private static func localName(_ raw: String) -> String {
        guard let colon = raw.lastIndex(of: ":") else { return raw }
        return String(raw[raw.index(after: colon)...])
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard stack.count < maximumDepth else {
            depthExceeded = true
            parser.abortParsing()
            return
        }
        var lowered: [String: String] = [:]
        lowered.reserveCapacity(attributeDict.count)
        for (name, value) in attributeDict where !name.hasPrefix("xmlns") {
            lowered[Self.localName(name).lowercased()] = value
        }
        stack.append(Frame(name: Self.localName(elementName), attributes: lowered,
                           text: "", children: []))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard let frame = stack.popLast() else { return }
        let node = XMLNode(name: frame.name,
                           attributes: frame.attributes,
                           text: frame.text.trimmingCharacters(in: .whitespacesAndNewlines),
                           children: frame.children)
        if stack.isEmpty {
            root = node
        } else {
            stack[stack.count - 1].children.append(node)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        failureDescription = "line \(parser.lineNumber) column \(parser.columnNumber): "
            + String(describing: parseError)
    }
}
