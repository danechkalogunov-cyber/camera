//
//  WSDiscoveryCodec.swift
//  VigilDiscovery
//
//  ONVIF WS-Discovery on the wire: the three byte-exact SOAP 1.2 Probe envelopes, and a total
//  decoder for ProbeMatches, Hello and Bye that survives anything else the group carries.
//  See docs/spec-discovery.md §5.2, §5.3, §5.5 and docs/API_CONTRACT.md §4.6.
//

import Foundation
import VigilProtocols

// MARK: - Probe variants

/// Which `Types` filter a Probe carries. The three values are the three probes of the §5.3
/// schedule, sent 500 ms apart, each with a fresh `MessageID`.
public enum WSDProbeTypes: Sendable, Equatable, CaseIterable {
    /// `dn:NetworkVideoTransmitter` — the standard ONVIF camera probe.
    case networkVideoTransmitter
    /// `dn:NetworkVideoTransmitter tds:Device` — also catches devices that advertise only the
    /// Device service, which some NVRs and encoders do.
    case networkVideoTransmitterAndDevice
    /// `<d:Probe/>` with no `Types` child — catches recorders advertising `NetworkVideoStorage` and
    /// firmware whose type matching is simply broken.
    case wildcard
}

// MARK: - Decode outcome

/// What a datagram received on the WS-Discovery group turned out to be.
public enum WSDDecodeOutcome: Sendable, Equatable {
    /// A `ProbeMatches` envelope. May be empty when a device answered with no matches.
    case probeMatches([WSDProbeMatch])
    /// An unsolicited `Hello`. Treated exactly like a ProbeMatch by the merge engine; the device
    /// just announced itself rather than being asked.
    case hello([WSDProbeMatch])
    /// A `Bye`: the device is leaving. The UI marks the row stale and keeps it, because a camera
    /// that rebooted is not a camera that vanished.
    case bye(endpointAddress: String)
    /// A well-formed SOAP envelope carrying some other action, e.g. `Resolve`. Ignored.
    case otherAction(String)
    /// Not a SOAP envelope at all: garbage, a different protocol on the shared group, or an
    /// oversized datagram. `prefixHex` is the first 16 bytes for the log.
    case notSOAP(prefixHex: String)
}

// MARK: - Codec

/// Encoder and decoder for ONVIF WS-Discovery.
///
/// Two facts drive the whole design and are easy to get wrong:
///
/// * The WS-Addressing namespace is the **2004/08** one while WS-Discovery is **2005/04**. Those two
///   different years are what ONVIF Core specifies, and mixing them is the single most common reason
///   a Probe is silently ignored by every camera on a network.
/// * Responses arrive as **unicast from arbitrary source ports**, so nothing may be filtered by
///   port; correlation is by `RelatesTo` and, when that is absent, not at all (§5.1, §5.5).
///
/// Nothing in this type ever sends, or can express, a credential: no `UsernameToken`, no
/// `PasswordDigest`, no ONVIF call beyond the Probe (§5.7, §6.10).
public enum WSDiscoveryCodec {

    // MARK: Wire constants

    /// The multicast group WS-Discovery probes travel on — the same group as SADP, a different port.
    public static let multicastGroup = IPv4Address.discoveryMulticastGroup

    /// The WS-Discovery port.
    public static let port: UInt16 = 3_702

    /// Largest datagram accepted; ONVIF ProbeMatches with many scopes reach ~2 kB.
    public static let maxDatagramBytes = 8_192

    /// Per-datagram caps from §5.5. Excess is truncated with a diagnostic — a hostile datagram must
    /// not be able to make us allocate proportionally to what it claims.
    public static let maxProbeMatchesPerDatagram = 64
    /// See `maxProbeMatchesPerDatagram`.
    public static let maxScopesPerMatch = 32
    /// See `maxProbeMatchesPerDatagram`.
    public static let maxXAddrsPerMatch = 8
    /// See `maxProbeMatchesPerDatagram`.
    public static let maxScopeCharacters = 512
    /// See `maxProbeMatchesPerDatagram`.
    public static let maxTypesPerMatch = 32

    /// Confidence penalty for a match we could not correlate to one of our own probes (§5.5).
    public static let uncorrelatedConfidencePenalty = -5

    /// The probe schedule: three probes at 0 / 500 / 1 000 ms, each with a fresh `MessageID` (§5.3).
    public static let probeSchedule: [WSDProbeTypes] = [
        .networkVideoTransmitter, .networkVideoTransmitterAndDevice, .wildcard,
    ]

    /// SOAP **1.2**. Not 1.1 — an ONVIF stack will not answer a 1.1 envelope.
    public static let soapNamespace = "http://www.w3.org/2003/05/soap-envelope"
    /// WS-Addressing, the 2004/08 revision ONVIF Core mandates.
    public static let addressingNamespace = "http://schemas.xmlsoap.org/ws/2004/08/addressing"
    /// WS-Discovery, the 2005/04 revision.
    public static let discoveryNamespace = "http://schemas.xmlsoap.org/ws/2005/04/discovery"
    /// The ONVIF network WSDL namespace, bound to `dn`.
    public static let networkWSDLNamespace = "http://www.onvif.org/ver10/network/wsdl"
    /// The ONVIF device WSDL namespace, bound to `tds` in probe 2.
    public static let deviceWSDLNamespace = "http://www.onvif.org/ver10/device/wsdl"
    /// The literal `To` address of a discovery probe.
    public static let discoveryToAddress = "urn:schemas-xmlsoap-org:ws:2005:04:discovery"

    // MARK: Probe encoding

    /// Encodes one Probe envelope, byte for byte as §5.2 specifies.
    ///
    /// CRLF line endings: SOAP over UDP tolerates either, and the gSOAP stacks nearly every ONVIF
    /// device is built on are happiest with CRLF. There is **no** trailing line break after
    /// `</e:Envelope>` — the datagram ends with the envelope.
    ///
    /// `MessageID` is `urn:uuid:` plus a lowercase hyphenated UUID, the form ONVIF's own examples
    /// use. `mustUnderstand="true"` is qualified with the envelope prefix on both `To` and `Action`.
    /// There is deliberately no `ReplyTo` (the anonymous default is what UDP wants) and no empty
    /// `Scopes` element (legal, but some firmware reads it as "match nothing").
    ///
    /// - Parameters:
    ///   - messageID: this probe's identifier. A **fresh** UUID per probe; all of a run's IDs go
    ///     into the set passed to `decodeProbeMatches`.
    ///   - types: which of the three schedule variants to send.
    public static func encodeProbe(messageID: UUID, types: WSDProbeTypes) -> Data {
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<e:Envelope xmlns:e=\"\(soapNamespace)\"")
        lines.append("            xmlns:w=\"\(addressingNamespace)\"")
        lines.append("            xmlns:d=\"\(discoveryNamespace)\"")
        if types == .networkVideoTransmitterAndDevice {
            lines.append("            xmlns:dn=\"\(networkWSDLNamespace)\"")
            lines.append("            xmlns:tds=\"\(deviceWSDLNamespace)\">")
        } else {
            lines.append("            xmlns:dn=\"\(networkWSDLNamespace)\">")
        }
        lines.append("  <e:Header>")
        lines.append("    <w:MessageID>urn:uuid:\(messageID.uuidString.lowercased())</w:MessageID>")
        lines.append("    <w:To e:mustUnderstand=\"true\">\(discoveryToAddress)</w:To>")
        lines.append("    <w:Action e:mustUnderstand=\"true\">\(discoveryNamespace)/Probe</w:Action>")
        lines.append("  </e:Header>")
        lines.append("  <e:Body>")
        switch types {
        case .networkVideoTransmitter:
            lines.append("    <d:Probe>")
            lines.append("      <d:Types>dn:NetworkVideoTransmitter</d:Types>")
            lines.append("    </d:Probe>")
        case .networkVideoTransmitterAndDevice:
            lines.append("    <d:Probe>")
            lines.append("      <d:Types>dn:NetworkVideoTransmitter tds:Device</d:Types>")
            lines.append("    </d:Probe>")
        case .wildcard:
            lines.append("    <d:Probe/>")
        }
        lines.append("  </e:Body>")
        lines.append("</e:Envelope>")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    // MARK: Decoding

    /// Decodes one datagram. Never throws and never traps, for any bytes of any length.
    ///
    /// - Parameters:
    ///   - payload: the datagram bytes as received.
    ///   - source: the UDP source address. The source *port* is deliberately not a parameter,
    ///     because filtering on it would drop most real answers (§5.1).
    ///   - expectedMessageIDs: this run's probe `MessageID`s, in any of the accepted spellings.
    ///     A match whose `RelatesTo` is absent or unknown is still returned, flagged
    ///     `isCorrelated == false`; discarding those would lose every `Hello` and a good deal of
    ///     firmware that omits the header.
    ///   - receivedAt: arrival time from the injected clock.
    public static func decodeProbeMatches(_ payload: Data,
                                          from source: IPv4Address,
                                          expectedMessageIDs: Set<String>,
                                          receivedAt: Date) -> WSDDecodeOutcome {
        guard !payload.isEmpty else { return .notSOAP(prefixHex: "") }
        let prefixHex = SADPCodec.hexString(Array(payload.prefix(16)))
        guard payload.count <= maxDatagramBytes else { return .notSOAP(prefixHex: prefixHex) }

        let (text, _) = LenientXMLScanner.decodedText([UInt8](payload))
        var collector = EnvelopeCollector()
        _ = LenientXMLScanner.scan(text) { event in collector.apply(event) }

        guard collector.sawEnvelope else { return .notSOAP(prefixHex: prefixHex) }

        let expected = Set(expectedMessageIDs.map(normalizedMessageID))
        let correlated = collector.relatesTo.map { expected.contains(normalizedMessageID($0)) } ?? false
        let matches = collector.matches.map { fields in
            WSDProbeMatch(endpointAddress: fields.endpointAddress,
                          types: splitTypes(fields.types),
                          scopes: parseScopes(fields.scopes),
                          xAddrs: splitXAddrs(fields.xAddrs),
                          metadataVersion: fields.metadataVersion.flatMap(Int.init),
                          relatesTo: collector.relatesTo,
                          messageID: collector.messageID,
                          appSequenceInstanceID: collector.appSequenceInstanceID,
                          observedFrom: source,
                          receivedAt: receivedAt,
                          isCorrelated: correlated)
        }

        switch collector.bodyKind ?? actionKind(collector.action) {
        case .probeMatches: return .probeMatches(matches)
        case .hello: return .hello(matches)
        case .bye: return .bye(endpointAddress: matches.first?.endpointAddress ?? "")
        case .none: return .otherAction(collector.action ?? "")
        }
    }

    /// Splits and interprets a `Scopes` element, applying the §5.5 caps first: at most 32 scopes,
    /// each truncated to 512 characters. Everything surviving the caps is percent-decoded and kept
    /// in `ONVIFScopes.raw`, recognised or not.
    public static func parseScopes(_ raw: String) -> ONVIFScopes {
        let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        let bounded = tokens.prefix(maxScopesPerMatch).map { token -> String in
            token.count <= maxScopeCharacters ? String(token) : String(token.prefix(maxScopeCharacters))
        }
        return ONVIFScopes.parse(bounded.joined(separator: " "))
    }

    /// Reduces a message identifier to its comparable form: lowercased, trimmed, with a leading
    /// `urn:uuid:` or `uuid:` removed. Firmware differs on which spelling it echoes in `RelatesTo`,
    /// and a run that only accepted one spelling would drop half the answers on some networks.
    public static func normalizedMessageID(_ raw: String) -> String {
        var text = Substring(LenientXMLScanner.trimmingASCIIWhitespace(raw).lowercased())
        if text.hasPrefix("urn:uuid:") {
            text = text.dropFirst("urn:uuid:".count)
        } else if text.hasPrefix("uuid:") {
            text = text.dropFirst("uuid:".count)
        }
        return String(text)
    }

    // MARK: - Parsing helpers

    /// Splits a `Types` element, stripping every `prefix:`, e.g. `dn:NetworkVideoTransmitter
    /// tds:Device` becomes `["NetworkVideoTransmitter", "Device"]`.
    static func splitTypes(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .prefix(maxTypesPerMatch)
            .map { token in
                guard let colon = token.lastIndex(of: ":") else { return String(token) }
                return String(token[token.index(after: colon)...])
            }
    }

    /// Splits an `XAddrs` element on whitespace, order preserved, capped per §5.5.
    static func splitXAddrs(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .prefix(maxXAddrsPerMatch)
            .map(String.init)
    }

    /// The kind of body an `Action` header names, or `nil` when it names something else.
    private static func actionKind(_ action: String?) -> BodyKind? {
        guard let action, let slash = action.lastIndex(of: "/") else { return nil }
        switch action[action.index(after: slash)...].lowercased() {
        case "probematches": return .probeMatches
        case "hello": return .hello
        case "bye": return .bye
        default: return nil
        }
    }

    /// Which WS-Discovery message a body holds.
    enum BodyKind: Sendable, Equatable {
        case probeMatches
        case hello
        case bye
    }

    /// The raw text of one `ProbeMatch`, `Hello` or `Bye` element, before interpretation.
    struct MatchFields: Sendable, Equatable {
        var endpointAddress: String?
        var types = ""
        var scopes = ""
        var xAddrs = ""
        var metadataVersion: String?
    }

    /// Accumulates the paths §5.5 names and ignores everything else.
    ///
    /// Matching is on **local names only** — never on prefixes, and never requiring a namespace
    /// declaration, because cheap firmware emits envelopes with no declarations at all and refusing
    /// those would mean refusing the devices most in need of being found.
    struct EnvelopeCollector {
        private(set) var sawEnvelope = false
        private(set) var action: String?
        private(set) var messageID: String?
        private(set) var relatesTo: String?
        private(set) var appSequenceInstanceID: String?
        private(set) var bodyKind: BodyKind?
        private(set) var matches: [MatchFields] = []
        /// Number of `ProbeMatch` elements dropped by the per-datagram cap.
        private(set) var droppedMatches = 0

        private var stack: [String] = []
        private var buffers: [String] = []
        private var current: MatchFields?

        mutating func apply(_ event: LenientXMLScanner.Event) {
            switch event {
            case let .start(name, attributes):
                stack.append(name)
                buffers.append("")
                switch name {
                case "envelope" where stack.count == 1:
                    sawEnvelope = true
                case "appsequence":
                    appSequenceInstanceID = attributes["instanceid"] ?? appSequenceInstanceID
                case "probematches":
                    bodyKind = .probeMatches
                case "probematch":
                    current = MatchFields()
                case "hello":
                    bodyKind = .hello
                    current = MatchFields()
                case "bye":
                    bodyKind = .bye
                    current = MatchFields()
                default:
                    break
                }

            case let .text(value):
                if !buffers.isEmpty { buffers[buffers.count - 1] += value }

            case let .end(name):
                let value = LenientXMLScanner.trimmingASCIIWhitespace(buffers.popLast() ?? "")
                if !stack.isEmpty { stack.removeLast() }
                finish(name, value)
            }
        }

        private mutating func finish(_ name: String, _ value: String) {
            switch name {
            case "messageid" where messageID == nil && !value.isEmpty:
                messageID = value
            case "relatesto" where relatesTo == nil && !value.isEmpty:
                relatesTo = value
            case "action" where action == nil && !value.isEmpty:
                action = value
            case "address" where stack.last == "endpointreference":
                if current != nil, !value.isEmpty { current?.endpointAddress = value }
            case "types" where current != nil:
                current?.types = value
            case "scopes" where current != nil:
                current?.scopes = value
            case "xaddrs" where current != nil:
                current?.xAddrs = value
            case "metadataversion" where current != nil:
                current?.metadataVersion = value
            case "probematch", "hello", "bye":
                if let fields = current {
                    if matches.count < WSDiscoveryCodec.maxProbeMatchesPerDatagram {
                        matches.append(fields)
                    } else {
                        droppedMatches += 1
                    }
                }
                current = nil
            default:
                break
            }
        }
    }
}
