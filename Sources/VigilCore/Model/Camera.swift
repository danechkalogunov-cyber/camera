//
//  Camera.swift
//  VigilCore
//
//  The one persisted description of a device channel: where it lives, how to reach its stream, and
//  which Keychain item holds its password. Never the password itself.
//  Implements docs/spec-core.md §4.1 and docs/API_CONTRACT.md §4.8 / §5.12 (`Model/Camera.swift`).
//
//  Slice scope (.vigil/SLICE.md): the fields the first-light column needs. `groupID`, `orderIndex`,
//  `notes`, `macAddress`, `serialHint`, `audioEnabled`, `autoRecordOnMotion`,
//  `preferredCodec`, `timeZoneIdentifier`, `isONVIFFallback`, `jpegPollIntervalOverride` and
//  `isPinnedLive` are deliberately absent until the layers that read them exist; every one of them
//  is additive-with-default, so adding it later needs no migration (spec-core §4).
//

#if os(macOS)

import Foundation
import VigilProtocols
import VigilRTSP

/// Persistent identity tags from the library schema. `.none` selects automatic assignment.
public enum ColorTag: String, Sendable, Codable, Hashable, CaseIterable {
    case none, red, orange, yellow, green, teal, blue, purple, pink, graphite

    /// Maps the broader document vocabulary onto the six accessible UI identity colours.
    public var paletteIndex: Int? {
        switch self {
        case .none: nil
        case .blue, .teal: 0
        case .green: 1
        case .yellow: 2
        case .red, .orange: 3
        case .purple, .pink: 4
        case .graphite: 5
        }
    }
}

// MARK: - CameraValidationError

/// What `Camera.validated()` refuses to normalise away.
///
/// Only the two fields that make a connection impossible throw; everything else is repaired, on the
/// principle that a hand-edited `library.json` should open rather than take the app down with it.
public enum CameraValidationError: Error, Sendable, Hashable, CustomStringConvertible {

    /// The host is empty, or carries a scheme, a path, a port or userinfo — all of which mean the
    /// value came from a URL that was pasted into the wrong field.
    case invalidHost(String)

    /// A port outside 1...65535. Carries the offending value and the field it came from.
    case invalidPort(field: String, value: Int)

    public var description: String {
        switch self {
        case let .invalidHost(host):
            "invalid camera host \"\(Redact.host(host, salt: 0))\""
        case let .invalidPort(field, value):
            "invalid \(field) \(value); expected 1...65535"
        }
    }
}

// MARK: - Camera

/// One camera, or one channel of one NVR.
///
/// **No password property, ever** (API_CONTRACT §2 R-14): `credentialRef` is an opaque UUID handle
/// to a Keychain item, and `Credential` is not `Codable`, so a secret cannot reach `library.json`
/// even by accident.
///
/// Decoding is forgiving and encoding is exact (spec-core §4): every field but `id` and `host` is
/// decoded with a default, so a record written by an older build loads without a migration.
public struct Camera: Identifiable, Sendable, Codable, Hashable {

    // MARK: Identity

    /// Stable identity. Survives every edit, including a change of address.
    public var id: CameraID

    /// User-facing name. Not unique, 1...64 characters after validation.
    public var name: String

    /// IPv4 literal, IPv6 literal **without** brackets, or a DNS name. Never a URL.
    public var host: String

    /// ISAPI control-plane port. 80 by default, 443 when `useTLS`.
    public var httpPort: Int

    /// RTSP port. 554 by default, 322 for `tcpTLS`.
    public var rtspPort: Int

    /// Whether the ISAPI control plane speaks HTTPS. Independent of the RTSP transport.
    public var useTLS: Bool

    /// 1-based device video input. A camera is always 1; an NVR has one per input.
    public var channel: ChannelID

    /// The encoder to prefer. `nil` means "automatic" — there is no `.auto` case
    /// (API_CONTRACT §2 R-55) and `StreamProfile.Kind` does not exist.
    public var preferredQuality: StreamQuality?

    /// How RTP reaches us. `.tcpInterleaved` by default because it traverses every LAN and needs no
    /// inbound ports (customer requirement R1.6).
    public var transport: RTSPTransportKind

    /// Last concrete transport that reached PLAY while ``transport`` was `.auto`.
    public var lastWorkingTransport: RTSPTransportKind?

    /// The Keychain handle for this device's password. Opaque; reveals not even the username.
    public var credentialRef: CredentialRef

    // MARK: Learned and additive

    /// What we have learned about the device, `nil` until the first successful probe. Carries the
    /// winning RTSP path template, so the R1.2 ladder runs at most once per device (R1.2).
    public var capabilities: DeviceCapabilities?

    /// When the record was created.
    public var createdAt: Date

    /// Last successful `PLAY` or ISAPI `200`. `nil` if the device has never answered.
    public var lastSeenAt: Date?

    /// `false` means never auto-connect. The record stays in the library.
    public var isEnabled: Bool

    /// User-selected identity colour. `.none` preserves the deterministic UUID-derived fallback.
    public var colorTag: ColorTag

    /// An absolute RTSP path typed by the user, e.g. `/Streaming/Channels/201`. **Empty in the
    /// zero-configuration flow** — R1.1 forbids ever asking for one — and honoured first when it is
    /// set, because a user who has overridden the path has a reason.
    public var rtspPathOverride: String?

    /// Jitter-buffer depth / latency trade-off for this camera.
    public var latencyPreset: LatencyPreset

    // MARK: Coding keys

    /// Explicit and stable: renaming a Swift property must never change the JSON key
    /// (spec-core §4). Coding keys are the persistence contract.
    enum CodingKeys: String, CodingKey {
        case id, name, host, httpPort, rtspPort, useTLS, channel, preferredQuality, transport
        case credentialRef, capabilities, createdAt, lastSeenAt, isEnabled, rtspPathOverride
        case latencyPreset, colorTag, lastWorkingTransport
    }

    // MARK: Initialisation

    /// Builds a camera record. Every argument but `host` has the default the connect form uses, so
    /// the R1.1 flow — address plus password — constructs one with two values.
    public init(id: CameraID = CameraID(),
                name: String = "",
                host: String,
                httpPort: Int = 80,
                rtspPort: Int = 554,
                useTLS: Bool = false,
                channel: ChannelID = .first,
                preferredQuality: StreamQuality? = nil,
                transport: RTSPTransportKind = .tcpInterleaved,
                lastWorkingTransport: RTSPTransportKind? = nil,
                credentialRef: CredentialRef = CredentialRef(),
                capabilities: DeviceCapabilities? = nil,
                createdAt: Date = Date(),
                lastSeenAt: Date? = nil,
                isEnabled: Bool = true,
                colorTag: ColorTag = .none,
                rtspPathOverride: String? = nil,
                latencyPreset: LatencyPreset = .balanced) {
        self.id = id
        self.name = name
        self.host = host
        self.httpPort = httpPort
        self.rtspPort = rtspPort
        self.useTLS = useTLS
        self.channel = channel
        self.preferredQuality = preferredQuality
        self.transport = transport
        self.lastWorkingTransport = lastWorkingTransport == .auto ? nil : lastWorkingTransport
        self.credentialRef = credentialRef
        self.capabilities = capabilities
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.isEnabled = isEnabled
        self.colorTag = colorTag
        self.rtspPathOverride = rtspPathOverride
        self.latencyPreset = latencyPreset
    }

    // MARK: Codable

    /// Forgiving decode: only `id` and `host` are required. A missing field takes the same default
    /// the initialiser uses, so purely additive schema changes need no migration step.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CameraID.self, forKey: .id)
        host = try container.decode(String.self, forKey: .host)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        httpPort = try container.decodeIfPresent(Int.self, forKey: .httpPort) ?? 80
        rtspPort = try container.decodeIfPresent(Int.self, forKey: .rtspPort) ?? 554
        useTLS = try container.decodeIfPresent(Bool.self, forKey: .useTLS) ?? false
        channel = try container.decodeIfPresent(ChannelID.self, forKey: .channel) ?? .first
        preferredQuality = try container.decodeIfPresent(StreamQuality.self,
                                                         forKey: .preferredQuality)
        transport = try container.decodeIfPresent(RTSPTransportKind.self, forKey: .transport)
            ?? .tcpInterleaved
        let learned = try container.decodeIfPresent(RTSPTransportKind.self,
                                                    forKey: .lastWorkingTransport)
        lastWorkingTransport = learned == .auto ? nil : learned
        credentialRef = try container.decodeIfPresent(CredentialRef.self, forKey: .credentialRef)
            ?? CredentialRef()
        capabilities = try container.decodeIfPresent(DeviceCapabilities.self, forKey: .capabilities)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        colorTag = (try? container.decodeIfPresent(ColorTag.self, forKey: .colorTag)) ?? .none
        rtspPathOverride = try container.decodeIfPresent(String.self, forKey: .rtspPathOverride)
        latencyPreset = try container.decodeIfPresent(LatencyPreset.self, forKey: .latencyPreset)
            ?? .balanced
    }

    /// Exact encode: every field is written, including the ones that hold their default, so the
    /// document is self-describing and diffable.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(httpPort, forKey: .httpPort)
        try container.encode(rtspPort, forKey: .rtspPort)
        try container.encode(useTLS, forKey: .useTLS)
        try container.encode(channel, forKey: .channel)
        try container.encodeIfPresent(preferredQuality, forKey: .preferredQuality)
        try container.encode(transport, forKey: .transport)
        try container.encodeIfPresent(lastWorkingTransport, forKey: .lastWorkingTransport)
        try container.encode(credentialRef, forKey: .credentialRef)
        try container.encodeIfPresent(capabilities, forKey: .capabilities)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(rtspPathOverride, forKey: .rtspPathOverride)
        try container.encode(latencyPreset, forKey: .latencyPreset)
        // ⛔ WRITTEN, AND IT WAS NOT. The property, the coding key and the *decoder* all existed;
        // this one line did not, so a colour chosen in the camera's settings was encoded away on
        // the next save and read back as `.none`. The symptom is the mildest kind — a tag that
        // quietly reverts on relaunch — and the cause is the kind a hand-written `encode(to:)`
        // invites: adding a property updates the decoder, because a missing key throws there, and
        // silently skips the encoder, because a missing line throws nothing at all.
        try container.encode(colorTag, forKey: .colorTag)
    }
}

// MARK: - Derived values

public extension Camera {

    /// The Hikvision streaming channel id for a quality: `channel * 100 + quality`. Channel 2 sub
    /// is 202.
    func streamingChannelID(for quality: StreamQuality) -> StreamingChannelID {
        StreamingChannelID(channel: channel, quality: quality)
    }

    /// The RTSP path to use, in the precedence the customer requirement fixes: an explicit user
    /// override, then the template the R1.2 probe ladder learned and persisted, then the current
    /// firmware's form.
    ///
    /// The last fallback exists so a camera with no capabilities record still gets one sensible
    /// attempt before the ladder runs; it is never a substitute for probing.
    func rtspPath(for quality: StreamQuality) -> String {
        if let override = rtspPathOverride, !override.isEmpty {
            return override.hasPrefix("/") ? override : "/" + override
        }
        if let template = capabilities?.rtspPathTemplate,
           let path = template.path(channel: channel, quality: quality) {
            return path
        }
        return "/Streaming/Channels/\(streamingChannelID(for: quality))"
    }

    /// The stream URL for a quality. Credentials are **never** part of it: `RTSPURL` cannot
    /// serialise userinfo, and Digest takes the credential separately (spec-core §6.1 rule 4).
    ///
    /// The port is always written, because Hikvision's Digest implementation hashes the URI it
    /// parsed and the request line must reproduce it exactly (docs/spec-rtsp.md §6.8).
    func rtspURL(for quality: StreamQuality) -> RTSPURL {
        rtspURL(path: rtspPath(for: quality))
    }

    /// The stream URL for an explicit path. Used by the probe ladder, which owns the path it is
    /// testing rather than taking it from the record it is about to fill in.
    /// - Parameter path: a path, optionally with a query — `/Streaming/tracks/101?starttime=…`.
    ///
    /// **The query is split out rather than left in the path**, and that is load-bearing for
    /// playback. `RTSPURL.formWithoutQuery` is rung 1 of the Digest URI-fallback ladder
    /// (spec-rtsp.md §6.8): some firmware hashes `uri=` without the query, and the ladder only
    /// works if `RTSPURL` knows which part *is* the query. Leaving `?starttime=…` inside `path`
    /// produces a string that looks right, authenticates on most cameras, and fails with an endless
    /// 401 loop on the ones the ladder exists for — the classic "playback works on some cameras"
    /// bug spec-isapi.md §15.6 warns about.
    func rtspURL(path: String) -> RTSPURL {
        let (bare, query) = Self.splitQuery(path)
        let usesRTSPTLS = transport == .tcpTLS
            || (transport == .auto && lastWorkingTransport == .tcpTLS)
        return RTSPURL(scheme: usesRTSPTLS ? "rtsps" : "rtsp",
                       host: host,
                       port: rtspPort,
                       path: bare,
                       query: query,
                       isIPv6Literal: host.contains(":"))
    }

    /// Everything before the first `?`, and the query without it.
    ///
    /// Not `URLComponents`: it rejects `rtsp://h/a?b=1;c=2`, which Hikvision emits, and has been
    /// observed to reorder query items — and spec-isapi.md §15.6 rule 2 requires the query to be
    /// passed through verbatim.
    private static func splitQuery(_ path: String) -> (path: String, query: String?) {
        guard let mark = path.firstIndex(of: "?") else { return (path, nil) }
        let query = String(path[path.index(after: mark)...])
        return (String(path[..<mark]), query.isEmpty ? nil : query)
    }

    /// Filesystem-safe name used for folders, diagnostics and file names.
    ///
    /// Lowercased ASCII alphanumerics and dashes only, collapsed, trimmed, capped at 40 characters,
    /// and never empty — a camera called `"🎥"` still produces a usable folder name.
    var slug: String {
        let source = name.isEmpty ? host : name
        var out = ""
        var lastWasDash = false
        for character in source.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(character), character.isASCII {
                out.unicodeScalars.append(character)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 40 { out = String(out.prefix(40)) }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "camera-\(id.short)" : out
    }

    /// A copy with a display name that is never empty. Used by log lines and by the connect form,
    /// which lets the user leave the name blank.
    var displayName: String { name.isEmpty ? host : name }
}

// MARK: - Validation

public extension Camera {

    /// Returns a normalised copy, or throws for the two fields that cannot be repaired.
    ///
    /// Repairs: an empty or whitespace-only name becomes `"Camera <host>"`; a name over 64
    /// characters is truncated; newlines are stripped; an IPv6 host keeps its zone id but loses its
    /// brackets; a channel outside 1...256 is clamped. Throws `.invalidHost` when the host is empty
    /// or looks like a URL, and `.invalidPort` for a port outside 1...65535 — both of those make the
    /// record unusable, and silently substituting a default would connect to the wrong device.
    func validated() throws(CameraValidationError) -> Camera {
        var copy = self

        var trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.hasPrefix("["), trimmedHost.hasSuffix("]"), trimmedHost.count > 2 {
            trimmedHost = String(trimmedHost.dropFirst().dropLast())
        }
        guard !trimmedHost.isEmpty,
              !trimmedHost.contains("/"),
              !trimmedHost.contains("@"),
              !trimmedHost.contains(" "),
              !trimmedHost.lowercased().hasPrefix("rtsp:"),
              !trimmedHost.lowercased().hasPrefix("http:"),
              !trimmedHost.lowercased().hasPrefix("https:") else {
            throw CameraValidationError.invalidHost(host)
        }
        copy.host = trimmedHost

        guard (1...65_535).contains(httpPort) else {
            throw CameraValidationError.invalidPort(field: "httpPort", value: httpPort)
        }
        guard (1...65_535).contains(rtspPort) else {
            throw CameraValidationError.invalidPort(field: "rtspPort", value: rtspPort)
        }

        var trimmedName = name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty { trimmedName = "Camera \(trimmedHost)" }
        if trimmedName.count > 64 { trimmedName = String(trimmedName.prefix(64)) }
        copy.name = trimmedName

        copy.channel = ChannelID(min(max(channel.value, 1), 256))

        if let override = rtspPathOverride {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.rtspPathOverride = trimmed.isEmpty ? nil : trimmed
        }
        return copy
    }
}

#endif
