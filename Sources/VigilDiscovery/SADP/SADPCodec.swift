//
//  SADPCodec.swift
//  VigilDiscovery
//
//  Hikvision SADP on the wire: the byte-exact inquiry probe, and a total decoder that turns any
//  datagram on 239.255.255.250:37020 — including hostile and obfuscated ones — into a result value.
//  See docs/spec-discovery.md §4.2, §4.5, §4.8 and docs/API_CONTRACT.md §4.6.
//

import Foundation
import VigilProtocols

// MARK: - Decode result

/// What a datagram received on the SADP group turned out to be.
///
/// The group is shared: our own probes loop back, other discovery tools probe on it, and their
/// devices answer them. Every one of those is a distinct case rather than an error, because the only
/// truly wrong answer is to abort a discovery run over somebody else's traffic.
public enum SADPDecodeResult: Sendable, Equatable {

    /// A `ProbeMatch` answering our own run's `Uuid`, or one whose `Uuid` we could not check because
    /// the caller passed no expected value.
    case probeMatch(SADPProbeMatch)

    /// Our own probe, looped back by the local stack. Matched on `Uuid` plus `Types == inquiry`.
    case ownProbeEcho

    /// A probe from another SADP client on the LAN. Ignored as a device, but worth a diagnostic:
    /// it proves multicast reception works, which is exactly what a silent run cannot tell us.
    case foreignProbe(uuid: String)

    /// A `ProbeMatch` answering somebody else's `Uuid`. Still ingested — it is free information
    /// about a real device on our LAN — but scored down as corroborating rather than solicited.
    case foreignProbeMatch(SADPProbeMatch)

    /// A datagram that is not XML and could not be recovered (§4.8). The caller still emits a
    /// low-confidence device built from the UDP source address, because something Hikvision-shaped
    /// is demonstrably there.
    case opaque(SADPOpaquePayload)

    /// Not usable at all: empty, oversized, or XML whose root is neither `Probe` nor `ProbeMatch`.
    /// `prefixHex` is the first 16 bytes, lowercase, for a log line that can be diffed against a
    /// capture.
    case malformed(reason: String, prefixHex: String)
}

/// A SADP datagram whose payload was not plaintext XML and did not yield to recovery.
///
/// The entropy estimate is the point of this type: it lets a bug report distinguish "encrypted"
/// (≈7.9 bits/byte) from "scrambled" (≈4.5) without shipping the payload itself, so a future
/// version can act on real captures instead of speculation.
public struct SADPOpaquePayload: Sendable, Hashable, Codable {

    /// UDP source address of the datagram.
    public let source: IPv4Address
    /// Total byte length.
    public let length: Int
    /// First 32 bytes, lowercase hex, no separators.
    public let prefixHex: String
    /// Shannon entropy over the byte histogram, 0…8 bits per byte.
    public let entropyBitsPerByte: Double
    /// True when the payload begins with gzip (`1f 8b`) or zlib (`78 01|9c|da`) magic. We record
    /// the fact and deliberately do **not** inflate: no dependency-free inflate exists in the pure
    /// layer, and writing one for a case no capture has confirmed would be speculation (§4.8).
    public let looksCompressed: Bool

    /// Creates an opaque-payload record.
    public init(source: IPv4Address, length: Int, prefixHex: String,
                entropyBitsPerByte: Double, looksCompressed: Bool) {
        self.source = source
        self.length = length
        self.prefixHex = prefixHex
        self.entropyBitsPerByte = entropyBitsPerByte
        self.looksCompressed = looksCompressed
    }
}

// MARK: - Codec

/// Encoder and decoder for Hikvision's Search Active Devices Protocol.
///
/// SADP is plaintext XML over UDP multicast and is the richest single source discovery has: one
/// datagram carries MAC, serial, firmware, every port and — uniquely — whether the device has ever
/// been given a password. It is also **strictly read-only here**: Vigil never sends a SADP write of
/// any kind (no IP change, no password reset, no activation), which removes the entire class of
/// "we bricked the camera's network settings" failures (§4.8.5).
///
/// Nothing in this type ever sends, or can express, a credential (§6.10).
public enum SADPCodec {

    // MARK: Wire constants

    /// The multicast group SADP probes and answers travel on.
    public static let multicastGroup = IPv4Address.discoveryMulticastGroup

    /// The SADP port, used for both the group and the preferred local bind.
    public static let port: UInt16 = 37_020

    /// Largest datagram accepted. A real `ProbeMatch` is 700–1 600 bytes; an NVR with many fields
    /// reaches ~2 500. Anything beyond this cap is refused without being parsed.
    public static let maxDatagramBytes = 8_192

    /// Ingest cap per run, and per source address per run (§4.5.5). A misbehaving device or a
    /// discovery-tool storm must not make the app allocate without bound.
    public static let maxDatagramsPerRun = 512
    /// See `maxDatagramsPerRun`.
    public static let maxDatagramsPerSource = 32

    /// Confidence penalty applied to a `ProbeMatch` that answered another client's probe (§13.2).
    public static let foreignProbeMatchConfidencePenalty = -10

    /// Confidence given to the degraded record built from an unrecoverable opaque datagram (§4.8.3).
    public static let opaquePayloadConfidence = 35

    // MARK: Probe

    /// Encodes the inquiry probe, byte for byte as §4.2 and the §14.1 hex dump specify.
    ///
    /// The shape is fixed and must not be adjusted: UTF-8, `\n` line endings only (old firmware
    /// chokes on `\r\n` in the prolog), no trailing NUL, no length prefix, no padding, and no
    /// optional `<MAC>` element — the official tool sends its own MAC and no firmware requires it,
    /// so omitting it keeps our MAC off every device on the LAN.
    ///
    /// The `Uuid` is uppercase, hyphenated and unbraced, which is exactly `UUID.uuidString`. One
    /// UUID is reused for a whole run across all retries and interfaces, so that looped-back probes
    /// and foreign answers can be told apart (§4.2).
    ///
    /// The encoded length is **129 bytes** for the standard form. The specification's prose says
    /// "121 bytes", but its own byte dump in §14.1 is 129 bytes long and the dump is what firmware
    /// sees; the dump wins, and the test asserts against it.
    public static func encodeProbe(uuid: UUID) -> Data {
        let text = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<Probe>\n"
            + "<Uuid>\(uuid.uuidString)</Uuid>\n"
            + "<Types>inquiry</Types>\n"
            + "</Probe>\n"
        return Data(text.utf8)
    }

    // MARK: Decode

    /// Decodes one datagram. Never throws and never traps, for any byte sequence of any length.
    ///
    /// The order of operations is: size guard, then a plaintext-XML test on the first non-blank
    /// byte, then the two bounded recovery attempts of §4.8, then degradation to `.opaque`. A
    /// document that fails to parse but still yielded a `Uuid` plus a `MAC` or an `IPv4Address` is
    /// returned as a partial `ProbeMatch` rather than discarded — Hikvision firmware ships documents
    /// with unescaped `&`, and strict parsing there means losing a real camera (§4.5.1).
    ///
    /// - Parameters:
    ///   - payload: the datagram bytes exactly as received.
    ///   - source: the UDP source address, which the XML does not carry.
    ///   - expectedUUID: this run's probe UUID. Pass `nil` to skip correlation entirely, in which
    ///     case every `ProbeMatch` is treated as solicited and no probe can be recognised as ours.
    ///   - receivedAt: arrival time from the injected clock.
    public static func decode(_ payload: Data,
                              from source: IPv4Address,
                              expectedUUID: UUID?,
                              receivedAt: Date) -> SADPDecodeResult {
        guard !payload.isEmpty else {
            return .malformed(reason: "empty datagram", prefixHex: "")
        }
        guard payload.count <= maxDatagramBytes else {
            return .malformed(reason: "datagram of \(payload.count) bytes exceeds the "
                                + "\(maxDatagramBytes)-byte cap",
                              prefixHex: hexString(Array(payload.prefix(16))))
        }
        let bytes = [UInt8](payload)

        if beginsWithMarkup(bytes) {
            return decodeMarkup(bytes, from: source, expectedUUID: expectedUUID,
                                receivedAt: receivedAt)
        }
        if let key = singleByteXORKey(bytes) {
            let recovered = bytes.map { $0 ^ key }
            let result = decodeMarkup(recovered, from: source, expectedUUID: expectedUUID,
                                      receivedAt: receivedAt)
            if case .malformed = result {
                return .opaque(opaquePayload(bytes, from: source))
            }
            return result
        }
        return .opaque(opaquePayload(bytes, from: source))
    }

    /// Shannon entropy of a payload over its byte histogram, in bits per byte (0…8).
    ///
    /// Used only for diagnostics: ≈7.9 says encrypted, ≈4.5 says scrambled, ≈4.9 is what the XML we
    /// expected would score. Returns 0 for an empty payload.
    public static func shannonEntropyBitsPerByte(_ payload: some Collection<UInt8>) -> Double {
        guard !payload.isEmpty else { return 0 }
        var histogram = [Int](repeating: 0, count: 256)
        for byte in payload { histogram[Int(byte)] += 1 }
        let total = Double(payload.count)
        var entropy = 0.0
        for count in histogram where count > 0 {
            let probability = Double(count) / total
            entropy -= probability * log2(probability)
        }
        return entropy
    }

    /// Splits a Hikvision `DeviceSN` into its model prefix and the remainder.
    ///
    /// The serial is `<MODEL><YYYYMMDD><LETTERS><DIGITS>[suffix]`, and the only reliable landmark is
    /// the manufacturing date. The scan therefore finds the **last** eight-digit window that is a
    /// plausible date — year 2005…2035, month 01…12, day 01…31 — and splits there. "Last" matters:
    /// `DS-7616NI-K2/16P1620201105AAWR…` has a `16` glued to the model, and only the later window
    /// parses as a date.
    ///
    /// - Returns: the model, or `nil` when no window qualifies or the model part would be empty,
    ///   and the remainder — which for a `nil` model is the whole input. Never traps on a short,
    ///   empty or non-ASCII serial.
    public static func splitSerial(_ sn: String) -> (model: String?, remainder: String) {
        let bytes = Array(sn.utf8)
        guard bytes.count >= 8 else { return (nil, sn) }
        var split = -1
        var index = 0
        while index + 8 <= bytes.count {
            if isPlausibleDate(bytes, at: index) { split = index }
            index += 1
        }
        guard split > 0 else { return (nil, sn) }
        let model = String(decoding: bytes[0..<split], as: UTF8.self)
        let remainder = String(decoding: bytes[split...], as: UTF8.self)
        return (model.isEmpty ? nil : model, remainder)
    }

    // MARK: - Markup path

    private static func decodeMarkup(_ bytes: [UInt8],
                                     from source: IPv4Address,
                                     expectedUUID: UUID?,
                                     receivedAt: Date) -> SADPDecodeResult {
        let (text, encoding) = decodedText(bytes)
        let document = SADPXMLReader.read(text)
        guard let root = document.rootName else {
            return .malformed(reason: "payload contains no XML element",
                              prefixHex: hexString(Array(bytes.prefix(16))))
        }
        switch root {
        case "probematch":
            return probeMatchResult(document, from: source, expectedUUID: expectedUUID,
                                    receivedAt: receivedAt, encoding: encoding, bytes: bytes)
        case "probe":
            return probeResult(document, expectedUUID: expectedUUID)
        default:
            return .malformed(reason: "unexpected root element <\(root)>",
                              prefixHex: hexString(Array(bytes.prefix(16))))
        }
    }

    private static func probeMatchResult(_ document: SADPXMLReader.Document,
                                         from source: IPv4Address,
                                         expectedUUID: UUID?,
                                         receivedAt: Date,
                                         encoding: SADPPayloadEncoding,
                                         bytes: [UInt8]) -> SADPDecodeResult {
        let match = SADPProbeMatch(elements: document.elements,
                                   observedFrom: source,
                                   receivedAt: receivedAt,
                                   payloadEncoding: encoding,
                                   isRecoveredFromMalformedXML: !document.isWellFormed)
        if !document.isWellFormed {
            // §4.5.1 recovery rule: salvage only when the datagram still identifies a device.
            let identifies = match.mac != nil || match.ipv4Address != nil
            guard match.uuid != nil, identifies else {
                return .malformed(reason: "truncated ProbeMatch without Uuid and MAC/IPv4Address",
                                  prefixHex: hexString(Array(bytes.prefix(16))))
            }
        }
        guard let expectedUUID, let uuid = match.uuid,
              uuid.caseInsensitiveCompare(expectedUUID.uuidString) != .orderedSame else {
            return .probeMatch(match)
        }
        return .foreignProbeMatch(match)
    }

    private static func probeResult(_ document: SADPXMLReader.Document,
                                    expectedUUID: UUID?) -> SADPDecodeResult {
        let uuid = document.elements["uuid"].map(LenientXMLScanner.trimmingASCIIWhitespace) ?? ""
        if let expectedUUID, uuid.caseInsensitiveCompare(expectedUUID.uuidString) == .orderedSame {
            return .ownProbeEcho
        }
        return .foreignProbe(uuid: uuid)
    }

    // MARK: - Payload classification

    /// True when the first non-blank, non-BOM byte is `<`.
    private static func beginsWithMarkup(_ bytes: [UInt8]) -> Bool {
        var index = 0
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
        return index < bytes.count && bytes[index] == UInt8(ascii: "<")
    }

    /// Finds a single-byte XOR key that reveals `<?xml` or `<Probe` at the start of the payload.
    ///
    /// Bounded by construction: 255 keys against at most six bytes each. Key 0 is excluded because
    /// it is the identity, which the plaintext test above has already rejected.
    private static func singleByteXORKey(_ bytes: [UInt8]) -> UInt8? {
        let candidates = [Array("<?xml".utf8), Array("<Probe".utf8)]
        for key in UInt8(1)...UInt8(255) {
            for pattern in candidates where pattern.count <= min(16, bytes.count) {
                var matched = true
                for offset in pattern.indices where bytes[offset] ^ key != pattern[offset] {
                    matched = false
                    break
                }
                if matched { return key }
            }
        }
        return nil
    }

    private static func opaquePayload(_ bytes: [UInt8], from source: IPv4Address)
        -> SADPOpaquePayload {
        SADPOpaquePayload(source: source,
                          length: bytes.count,
                          prefixHex: hexString(Array(bytes.prefix(32))),
                          entropyBitsPerByte: shannonEntropyBitsPerByte(bytes),
                          looksCompressed: looksCompressed(bytes))
    }

    /// gzip (`1f 8b`) or zlib (`78 01`, `78 9c`, `78 da`) magic.
    private static func looksCompressed(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        if bytes[0] == 0x1F, bytes[1] == 0x8B { return true }
        return bytes[0] == 0x78 && (bytes[1] == 0x01 || bytes[1] == 0x9C || bytes[1] == 0xDA)
    }

    /// Decodes bytes to text, falling back to a byte-for-scalar ISO-8859-1 reading when the payload
    /// is not valid UTF-8 (§4.5.2). Never fails: every byte sequence has a Latin-1 reading.
    private static func decodedText(_ bytes: [UInt8]) -> (String, SADPPayloadEncoding) {
        let candidate = String(decoding: bytes, as: UTF8.self)
        if Array(candidate.utf8) == bytes { return (candidate, .utf8) }
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for byte in bytes { scalars.append(Unicode.Scalar(byte)) }
        return (String(scalars), .isoLatin1Fallback)
    }

    /// True when the eight bytes at `index` are digits forming a plausible manufacturing date.
    private static func isPlausibleDate(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index >= 0, index + 8 <= bytes.count else { return false }
        var digits = [Int](repeating: 0, count: 8)
        for offset in 0..<8 {
            let byte = bytes[index + offset]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return false }
            digits[offset] = Int(byte - UInt8(ascii: "0"))
        }
        let year = digits[0] * 1000 + digits[1] * 100 + digits[2] * 10 + digits[3]
        let month = digits[4] * 10 + digits[5]
        let day = digits[6] * 10 + digits[7]
        return (2005...2035).contains(year) && (1...12).contains(month) && (1...31).contains(day)
    }

    /// Lowercase hex with no separators, for log lines and fixtures.
    static func hexString(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
