//
//  XMLReaderTests.swift
//  VigilISAPITests
//
//  The lenient reader against the variance real firmware ships: namespaces present, absent and
//  prefixed; casing in both directions; elements Vigil has never seen; a field that is one element
//  on one firmware and a list on the next; and hostile input.
//  Covers docs/spec-isapi.md §7.2–§7.4 and §7.6.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - Firmware variance

@Suite struct XMLNodeFirmwareVarianceTests {

    /// The `ver20` namespace, a `ver10` namespace and no namespace at all read identically: the
    /// reader is namespace-agnostic by design.
    @Test func xmlNodeReadsTheSameFieldWithAnyNamespace() throws {
        let ver20 = try ISAPIDocument(parsing: Data(SpecBodies.deviceInfo.utf8))
        let ver10 = try ISAPIDocument(parsing: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <DeviceInfo version="1.0" xmlns="http://www.hikvision.com/ver10/XMLSchema">
              <model>DS-2CD2385FWD-I</model>
            </DeviceInfo>
            """.utf8))
        let none = try ISAPIDocument(parsing: Data("""
            <DeviceInfo><model>DS-2CD2385FWD-I</model></DeviceInfo>
            """.utf8))
        #expect(ver20["model"].string == "DS-2CD2385FWD-I")
        #expect(ver10["model"].string == "DS-2CD2385FWD-I")
        #expect(none["model"].string == "DS-2CD2385FWD-I")
    }

    /// A `hik:` prefix — and a malformed declaration that does not bind it — is stripped rather
    /// than resolved, so a broken `xmlns` cannot hide a field.
    @Test func xmlNodeStripsNamespacePrefixesWithoutResolvingThem() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <hik:DeviceInfo>
              <hik:Video><hik:videoCodecType>H.265</hik:videoCodecType></hik:Video>
            </hik:DeviceInfo>
            """.utf8))
        #expect(document.rootName == "DeviceInfo")
        #expect(document["Video/videoCodecType"].string == "H.265")
    }

    /// Element names match case-insensitively in both directions: the reader finds
    /// `<sharpnessLevel>` when asked for `SharpnessLevel` and the reverse.
    @Test func xmlNodeMatchesElementNamesCaseInsensitively() throws {
        let lower = try ISAPIDocument(parsing: Data(
            "<Sharpness><sharpnessLevel>50</sharpnessLevel></Sharpness>".utf8))
        let upper = try ISAPIDocument(parsing: Data(
            "<Sharpness><SharpnessLevel>50</SharpnessLevel></Sharpness>".utf8))
        #expect(lower["SharpnessLevel"].int == 50)
        #expect(upper["sharpnessLevel"].int == 50)
        #expect(lower["SHARPNESSLEVEL"].int == 50)
    }

    /// Alternation reads whichever spelling the firmware used, left to right, and one call handles
    /// the `PTZChanelCap` / `PTZChannelCap` split.
    @Test func xmlNodeReadsFirstMatchingAlternative() throws {
        let misspelled = try ISAPIDocument(parsing: Data(
            "<Caps><PTZChanelCap><absolute>true</absolute></PTZChanelCap></Caps>".utf8))
        let corrected = try ISAPIDocument(parsing: Data(
            "<Caps><PTZChannelCap><absolute>true</absolute></PTZChannelCap></Caps>".utf8))
        #expect(misspelled["PTZChannelCap|PTZChanelCap/absolute"].bool == true)
        #expect(corrected["PTZChannelCap|PTZChanelCap/absolute"].bool == true)
    }

    /// Whole-path alternation absorbs a firmware that hoists an element out of its parent.
    @Test func xmlNodeReadsWholePathAlternation() throws {
        let nestedText = "<MotionDetection><MotionDetection><enabled>true</enabled>"
            + "</MotionDetection></MotionDetection>"
        let nested = try ISAPIDocument(parsing: Data(nestedText.utf8))
        let hoisted = try ISAPIDocument(parsing: Data(
            "<MotionDetection><enabled>true</enabled></MotionDetection>".utf8))
        #expect(nested["MotionDetection/enabled || enabled"].bool == true)
        #expect(hoisted["MotionDetection/enabled || enabled"].bool == true)
    }

    /// The same call reads a field that is a single element on one firmware and a list on another.
    @Test func xmlNodeReadsSingleValueAndListWithOneCall() throws {
        let single = try ISAPIDocument(parsing: Data("""
            <Schedule><TimeBlock><start>00:00</start></TimeBlock></Schedule>
            """.utf8))
        let many = try ISAPIDocument(parsing: Data("""
            <Schedule>
              <TimeBlock><start>00:00</start></TimeBlock>
              <TimeBlock><start>08:00</start></TimeBlock>
              <TimeBlock><start>16:00</start></TimeBlock>
            </Schedule>
            """.utf8))
        #expect(single.nodes("TimeBlock").count == 1)
        #expect(many.nodes("TimeBlock").count == 3)
        #expect(single.nodes("TimeBlock").first?["start"].string == "00:00")
        #expect(many.nodes("TimeBlock[]").count == 3)
        #expect(many["TimeBlock[2]/start"].string == "16:00")
        #expect(many["TimeBlock[9]/start"].exists == false)
    }

    /// Elements Vigil has never seen are ignored, not fatal: new firmware adds them constantly.
    @Test func xmlNodeIgnoresUnknownElements() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <StreamingChannel>
              <id>101</id>
              <somethingFromFirmware7><nested>1</nested></somethingFromFirmware7>
              <Video><videoCodecType>H.264</videoCodecType><newFieldToo>x</newFieldToo></Video>
            </StreamingChannel>
            """.utf8))
        #expect(document["id"].int == 101)
        #expect(document["Video/videoCodecType"].string == "H.264")
        #expect(document.root.childKeys.contains("somethingfromfirmware7"))
    }

    /// A real §12.1 body reads through the paths the endpoint layer will use, including the
    /// second channel of the list.
    @Test func xmlNodeReadsTheSpecStreamingChannelBody() throws {
        let document = try ISAPIDocument(parsing: Data(SpecBodies.streamingChannel.utf8))
        let channels = document.nodes("StreamingChannel")
        #expect(channels.count == 2)
        let main = try #require(channels.first)
        #expect(main["id"].int == 101)
        #expect(main["channelName"].string == "Driveway")
        #expect(main["Video/videoResolutionWidth"].int == 3840)
        #expect(main["Video/maxFrameRate"].int == 2000)          // fps × 100
        #expect(main["Video/keyFrameInterval"].int == 2000)      // milliseconds
        #expect(main["Video/GovLength"].int == 40)               // frames
        #expect(main["Video/SVC/enabled"].bool == false)
        #expect(main["Transport/Unicast/rtpTransportType"].string == "RTP/TCP")
        #expect(main.nodes("Transport/ControlProtocolList/ControlProtocol").count == 2)
        #expect(document["StreamingChannel[1]/Video/maxFrameRate"].int == 1250)
    }

    /// `*` walks exactly one level; `**` finds a field wherever a firmware buried it.
    @Test func xmlNodeSupportsWildcardAndDescendantSegments() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <Root>
              <A><target>one</target></A>
              <B><C><target>two</target></C></B>
            </Root>
            """.utf8))
        #expect(document["*/target"].string == "one")
        #expect(document.nodes("*/target").count == 1)
        #expect(document["**/target"].string == "one")
        #expect(document.nodes("**/target").count == 2)
        #expect(document["B/**/target"].string == "two")
    }

    /// `@attr` reads an attribute, and `.` addresses the receiving element.
    @Test func xmlNodeReadsAttributesAndSelf() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <storage><hddList size="2"><hdd><id>1</id></hdd><hdd><id>2</id></hdd></hddList></storage>
            """.utf8))
        #expect(document["hddList@size"].int == 2)
        #expect(document.nodes("hddList/hdd").count == 2)
        #expect(document["hddList@missing"].exists == false)
        let list = try #require(document.node("hddList"))
        #expect(list["."].exists)
        #expect(list["./hdd[0]/id"].int == 1)
    }

    /// A missing value names the parent and its actual children, which is the diagnostic a
    /// `DecodingError` cannot produce.
    @Test func xmlNodeMissingValueErrorNamesSiblings() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <StreamingChannel><id>101</id><Video><videoCodecType>H.264</videoCodecType></Video>
            </StreamingChannel>
            """.utf8))
        do {
            _ = try document["Video/videoResolutionWidth"].requiredInt()
            Issue.record("expected a malformed-response error")
        } catch {
            guard case let .malformedResponse(message) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(message.contains("Video/videoResolutionWidth"))
            #expect(message.contains("Video"))
            #expect(message.contains("videocodectype"))
        }
    }

    /// An empty element exists but has no value; an absent one does not exist. `<name/>` means
    /// "no name" everywhere ISAPI uses it.
    @Test func xmlNodeDistinguishesEmptyElementFromAbsentElement() throws {
        let document = try ISAPIDocument(parsing: Data("<Root><name/></Root>".utf8))
        #expect(document["name"].exists)
        #expect(document["name"].string == nil)
        #expect(document["other"].exists == false)
        #expect(document["name"].string(or: "fallback") == "fallback")
    }

    /// CDATA is merged into the element's text, and interior whitespace survives.
    @Test func xmlNodeMergesCDATAIntoText() throws {
        let document = try ISAPIDocument(parsing: Data(
            "<Root><channelName>Front <![CDATA[& Back]]> Door</channelName></Root>".utf8))
        #expect(document["channelName"].string == "Front & Back Door")
    }
}

// MARK: - Typed values

@Suite struct XMLValueTypedReadTests {

    /// Every accepted boolean spelling, and two that are not.
    @Test func xmlValueAcceptsTheFullBooleanVocabulary() throws {
        for spelling in ["true", "TRUE", "1", "yes", "on", "enable", "enabled", "open", " Yes "] {
            let document = try ISAPIDocument(parsing: Data("<R><flag>\(spelling)</flag></R>".utf8))
            #expect(document["flag"].bool == true, "\(spelling) should read true")
        }
        for spelling in ["false", "FALSE", "0", "no", "off", "disable", "disabled", "close"] {
            let document = try ISAPIDocument(parsing: Data("<R><flag>\(spelling)</flag></R>".utf8))
            #expect(document["flag"].bool == false, "\(spelling) should read false")
        }
        for spelling in ["maybe", "2"] {
            let document = try ISAPIDocument(parsing: Data("<R><flag>\(spelling)</flag></R>".utf8))
            #expect(document["flag"].bool == nil, "\(spelling) should read nil")
        }
    }

    /// Integers tolerate a leading `+`, surrounding whitespace and a trailing unit.
    @Test func xmlValueIntToleratesSignsAndTrailingUnits() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <R><a> 1250 </a><b>+1250</b><c>1250 kbps</c><d>-5</d><e>kbps</e><f></f></R>
            """.utf8))
        #expect(document["a"].int == 1250)
        #expect(document["b"].int == 1250)
        #expect(document["c"].int == 1250)
        #expect(document["d"].int == -5)
        #expect(document["e"].int == nil)
        #expect(document["f"].int == nil)
        #expect(document["e"].int(or: 7) == 7)
    }

    /// A comma decimal separator is a number, not junk: some firmwares localise the field.
    @Test func xmlValueDoubleAcceptsCommaDecimalSeparator() throws {
        let document = try ISAPIDocument(parsing: Data("<R><x>1,5</x><y>2.25</y></R>".utf8))
        #expect(document["x"].double == 1.5)
        #expect(document["y"].double == 2.25)
    }

    /// Out-of-range junk is clamped rather than dropped, so a control still renders.
    @Test func xmlValueClampsOutOfRangeIntegers() throws {
        let document = try ISAPIDocument(parsing: Data("<R><b>255</b><c>-4</c><d>x</d></R>".utf8))
        #expect(document["b"].int(clampedTo: 0...100, or: 50) == 100)
        #expect(document["c"].int(clampedTo: 0...100, or: 50) == 0)
        #expect(document["d"].int(clampedTo: 0...100, or: 50) == 50)
    }

    /// Hex and Base64 fields decode, with whitespace stripped, and reject malformed input.
    @Test func xmlValueDecodesHexAndBase64() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <R><grid>ff00 ff00</grid><odd>abc</odd><b64>SGVsbG8=</b64><bad>!!!</bad></R>
            """.utf8))
        #expect(document["grid"].hexData == Data([0xFF, 0x00, 0xFF, 0x00]))
        #expect(document["odd"].hexData == nil)
        #expect(document["b64"].base64Data == Data("Hello".utf8))
        #expect(document["bad"].base64Data == nil)
    }

    /// A UUID-ish value loses its braces; a session token that is not a UUID still survives.
    @Test func xmlValueStripsBracesFromUUIDStrings() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <R><a>{48343131-3435-3234-3138-343131343535}</a><b>session-17</b></R>
            """.utf8))
        #expect(document["a"].uuidString == "48343131-3435-3234-3138-343131343535")
        #expect(document["b"].uuidString == "session-17")
    }

    /// The required variants throw with the raw text when a value is present but unreadable, and
    /// report absence as absence.
    @Test func xmlValueRequiredReadsDistinguishMissingFromMalformed() throws {
        let document = try ISAPIDocument(parsing: Data("<R><n>abc</n></R>".utf8))
        do {
            _ = try document["n"].requiredInt()
            Issue.record("expected a throw")
        } catch {
            guard case let .malformedResponse(message) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(message.contains("\"abc\""))
            #expect(message.contains("expected an integer"))
        }
        do {
            _ = try document["absent"].requiredString()
            Issue.record("expected a throw")
        } catch {
            guard case let .malformedResponse(message) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(message.contains("missing absent"))
        }
    }
}

// MARK: - Parser hardening

@Suite struct ISAPIDocumentParsingTests {

    /// An HTML login page — what a device with web authentication misconfigured returns, with
    /// HTTP 200 — is reported as "not XML", never as a missing element.
    @Test func isapiDocumentRejectsAnHTMLLoginPage() {
        let page = Data("<html><head><title>Login</title></head><body>user</body></html>".utf8)
        #expect(throws: ISAPIError.self) { try ISAPIDocument(parsing: page) }
        let plain = Data("Not XML at all".utf8)
        #expect(ISAPIDocument.looksLikeXML(plain) == false)
        #expect(ISAPIDocument.looksLikeXML(Data("  \n<Root/>".utf8)))
    }

    /// The 8 MiB cap is enforced before any parsing happens.
    @Test func isapiDocumentRejectsAnOversizeBody() {
        let big = Data(repeating: UInt8(ascii: "<"), count: ISAPIDocument.maximumBytes + 1)
        do {
            _ = try ISAPIDocument(parsing: big)
            Issue.record("expected responseTooLarge")
        } catch {
            #expect(error == ISAPIError.responseTooLarge(bytes: ISAPIDocument.maximumBytes + 1))
        }
    }

    /// Nesting beyond 64 levels is refused by counting, not by exhausting the stack.
    @Test func isapiDocumentRejectsNestingBeyondTheDepthCap() {
        let depth = ISAPIDocument.maximumDepth + 5
        var text = ""
        for level in 0..<depth { text += "<e\(level)>" }
        for level in stride(from: depth - 1, through: 0, by: -1) { text += "</e\(level)>" }
        #expect(throws: ISAPIError.self) { try ISAPIDocument(parsing: Data(text.utf8)) }
    }

    /// Sixty-four levels exactly is still accepted: the cap is a limit, not an off-by-one.
    @Test func isapiDocumentAcceptsExactlyTheDepthCap() throws {
        let depth = ISAPIDocument.maximumDepth
        var text = ""
        for level in 0..<depth { text += "<e\(level)>" }
        text += "leaf"
        for level in stride(from: depth - 1, through: 0, by: -1) { text += "</e\(level)>" }
        let document = try ISAPIDocument(parsing: Data(text.utf8))
        #expect(document.rootName == "e0")
    }

    /// An external entity is never resolved: the XXE payload cannot read a file, and the document
    /// still parses so a device with a broken DTD is not unreadable.
    @Test func isapiDocumentIgnoresExternalEntityPayloads() {
        let hostile = """
            <?xml version="1.0"?>
            <!DOCTYPE foo [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
            <DeviceInfo><deviceName>&xxe;</deviceName></DeviceInfo>
            """
        let document = try? ISAPIDocument(parsing: Data(hostile.utf8))
        if let document {
            #expect(document["deviceName"].string?.contains("root:") != true)
        }
    }

    /// A stray NUL after the root element is trailing garbage: the tree is kept and flagged.
    @Test func isapiDocumentToleratesTrailingGarbageAfterTheRoot() throws {
        var bytes = Data(SpecBodies.userCheckOK.utf8)
        bytes.append(0x00)
        let document = try ISAPIDocument(parsing: bytes)
        #expect(document["statusValue"].int == 200)
    }

    /// A document truncated *before* the root closes is an error, not a half tree.
    @Test func isapiDocumentRejectsATruncatedDocument() {
        let truncated = Data("<DeviceInfo><model>DS-2CD".utf8)
        #expect(throws: ISAPIError.self) { try ISAPIDocument(parsing: truncated) }
    }

    /// A `gb2312` declaration does not lose the response: ASCII fields survive and the document
    /// says the payload was not UTF-8.
    @Test func isapiDocumentFallsBackForLegacyChineseEncoding() throws {
        var bytes = Data("<?xml version=\"1.0\" encoding=\"gb2312\"?><DeviceInfo><model>DS-2</model>"
                         .utf8)
        bytes.append(contentsOf: [0xD6, 0xD0])       // a GB-encoded character in a free-text field
        bytes.append(contentsOf: Data("<deviceName>x</deviceName></DeviceInfo>".utf8))
        let document = try ISAPIDocument(parsing: bytes)
        #expect(document["model"].string == "DS-2")
        #expect(document.nonUTF8Payload)
    }

    /// An empty body is not a document.
    @Test func isapiDocumentRejectsAnEmptyBody() {
        #expect(throws: ISAPIError.self) { try ISAPIDocument(parsing: Data()) }
    }

    /// A UTF-8 BOM before the declaration parses.
    @Test func isapiDocumentAcceptsAByteOrderMark() throws {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data("<Root><a>1</a></Root>".utf8))
        let document = try ISAPIDocument(parsing: bytes)
        #expect(document["a"].int == 1)
    }
}

// MARK: - Round-trip

@Suite struct XMLNodeRoundTripTests {

    /// Serialization preserves elements and attributes Vigil does not understand, which is what
    /// makes a read-modify-write PUT safe (§17.1).
    @Test func xmlNodeSerializationPreservesUnknownElements() throws {
        let original = """
            <Color version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">\
            <brightnessLevel>50</brightnessLevel><futureField>keep me</futureField></Color>
            """
        let document = try ISAPIDocument(parsing: Data(original.utf8))
        let serialized = document.root.serialized(declaration: false)
        let text = String(decoding: serialized, as: UTF8.self)
        #expect(text.contains("<futureField>keep me</futureField>"))
        #expect(text.contains("version=\"2.0\""))
        let reparsed = try ISAPIDocument(parsing: serialized)
        #expect(reparsed["futureField"].string == "keep me")
        #expect(reparsed["brightnessLevel"].int == 50)
    }

    /// `setting` replaces one value and leaves everything else — including the attributes the
    /// device sent — untouched.
    @Test func xmlNodeSettingReplacesOneValueOnly() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <Color version="2.0"><brightnessLevel>50</brightnessLevel>\
            <contrastLevel>40</contrastLevel><unknown>x</unknown></Color>
            """.utf8))
        let updated = document.root.setting("brightnessLevel", to: "75")
        let text = String(decoding: updated.serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<brightnessLevel>75</brightnessLevel>"))
        #expect(text.contains("<contrastLevel>40</contrastLevel>"))
        #expect(text.contains("<unknown>x</unknown>"))
        #expect(text.contains("version=\"2.0\""))
    }

    /// Writing a nested path works, an absent one is only created when asked, and a path the
    /// writer cannot follow leaves the tree alone.
    @Test func xmlNodeSettingHonoursCreateIfMissing() throws {
        let document = try ISAPIDocument(parsing: Data(
            "<Video><enabled>true</enabled></Video>".utf8))
        let untouched = document.root.setting("Extra/level", to: "9")
        #expect(untouched.node("Extra") == nil)
        let created = document.root.setting("Extra/level", to: "9", createIfMissing: true)
        #expect(created.node("Extra/level")?.text == "9")
        let wildcard = document.root.setting("**/enabled", to: "false")
        #expect(wildcard["enabled"].bool == true)
    }

    /// Serialized text escapes the five entities, so a channel name with an ampersand round-trips.
    @Test func xmlNodeSerializationEscapesEntities() throws {
        let node = XMLNode(name: "channelName", text: "Front & <Back> \"Door\"")
        let text = String(decoding: node.serialized(declaration: false), as: UTF8.self)
        #expect(text == "<channelName>Front &amp; &lt;Back&gt; &quot;Door&quot;</channelName>")
        let reparsed = try ISAPIDocument(parsing: node.serialized())
        #expect(reparsed.root.text == "Front & <Back> \"Door\"")
    }
}
