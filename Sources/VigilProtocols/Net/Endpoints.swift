//
//  Endpoints.swift
//  VigilProtocols
//
//  Where a device's ISAPI control plane lives, and the one place a control-plane URL is built.
//  Implements docs/API_CONTRACT.md §3.14 and docs/spec-isapi.md §3.
//
//  Written by impl:isapi-a because `ISAPIClient.init(endpoint:…)` (API_CONTRACT §4.5) cannot
//  compile without it and the W1 file was still missing; the declarations are the contract's
//  verbatim shape. `RTSPEndpoint` is named in the same manifest row but nothing references it yet,
//  so it is left to its owner rather than guessed at here.
//

import Foundation

// MARK: - ISAPIEndpoint

/// Where a device's ISAPI control plane lives.
///
/// The type exists so that nothing string-concatenates a URL: `url(_:query:)` is the only way to
/// address the device, it brackets IPv6 exactly once, and it percent-encodes query values with
/// `+` escaped as `%2B` — Hikvision does not decode `+` as a space, and a `+` in a search
/// timestamp that arrives as a space is a silent wrong-day query.
public struct ISAPIEndpoint: Sendable, Hashable, Codable {

    /// IPv4 literal, IPv6 literal **without** brackets, or a DNS name.
    public var host: String

    /// TCP port. 80 for `http`, 443 for `https`; devices behind a proxy use anything.
    public var port: Int

    /// Whether to speak TLS. Plain HTTP on the LAN is the supported default.
    public var useTLS: Bool

    /// Path prefix, almost always `/ISAPI`. A device behind a reverse proxy may need `/cam1/ISAPI`;
    /// the field exists so a resource string never has to carry a site-specific prefix.
    public var pathPrefix: String

    /// Builds an endpoint. `host` is stored unbracketed even for IPv6.
    public init(host: String, port: Int = 80, useTLS: Bool = false, pathPrefix: String = "/ISAPI") {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.pathPrefix = pathPrefix
    }

    /// The scheme this endpoint speaks.
    public var scheme: String { useTLS ? "https" : "http" }

    /// The authority as it appears in a URL: IPv6 literals bracketed, the default port omitted.
    public var authority: String {
        let bracketed = Self.isIPv6Literal(host) ? "[\(host)]" : host
        let isDefaultPort = (useTLS && port == 443) || (!useTLS && port == 80)
        return isDefaultPort ? bracketed : "\(bracketed):\(port)"
    }

    /// The absolute path for `resource`, prefix included and percent-encoded.
    ///
    /// `resource` is written **without** the prefix, e.g. `/System/deviceInfo`; a leading slash is
    /// optional. The result is exactly what goes on the request line before the query, which makes
    /// it also exactly what Digest hashes as the first half of `digestURI` (spec-isapi §5.2).
    public func path(_ resource: String) -> String {
        let prefix = Self.normalisedPrefix(pathPrefix)
        let tail = resource.hasPrefix("/") ? resource : "/" + resource
        let joined = prefix + tail
        return PercentEncoding.encode(joined, allowing: .path)
    }

    /// The request-line URI for `resource`: path plus query, percent-encoded, no scheme or host.
    ///
    /// This is the value Digest hashes into `A2` (spec-isapi §5.2). Getting it wrong — dropping the
    /// query in particular — is the single most common cause of a permanent 401 against Hikvision,
    /// so the client never re-derives it and always asks here.
    public func requestURI(_ resource: String, query: [URLQueryItem] = []) -> String {
        let encoded = Self.encodedQuery(query)
        return encoded.isEmpty ? path(resource) : path(resource) + "?" + encoded
    }

    /// Builds the absolute URL for `resource`.
    ///
    /// - Parameters:
    ///   - resource: the path below the prefix, e.g. `/Streaming/channels/101/picture`.
    ///   - query: query items. Names and values are encoded as RFC 3986 `unreserved` only, so `&`,
    ///     `=`, `;` and `+` are all escaped and cannot be re-read as separators.
    /// - Returns: an absolute URL.
    /// - Throws: `ISAPIError.notConnected` when the host is empty or the pieces do not form a URL
    ///   `Foundation` will parse — a programming error or a corrupt camera record, never device
    ///   data, but it is reported rather than trapped because it arrives from persistence.
    public func url(_ resource: String, query: [URLQueryItem] = []) throws(ISAPIError) -> URL {
        guard !host.isEmpty else {
            throw ISAPIError.notConnected("ISAPIEndpoint has an empty host")
        }
        let text = "\(scheme)://\(authority)\(requestURI(resource, query: query))"
        guard let url = URL(string: text) else {
            throw ISAPIError.notConnected("cannot form a URL for \(scheme)://\(authority)")
        }
        return url
    }

    // MARK: Encoding helpers

    /// Percent-encodes query items into a `name=value&…` string, `+` included as `%2B`.
    ///
    /// An item with a `nil` value emits the bare name, which is how ISAPI spells its few
    /// valueless flags.
    static func encodedQuery(_ query: [URLQueryItem]) -> String {
        query.map { item in
            let name = PercentEncoding.encode(item.name, allowing: .queryComponent)
            guard let value = item.value else { return name }
            return name + "=" + PercentEncoding.encode(value, allowing: .queryComponent)
        }
        .joined(separator: "&")
    }

    /// Trims a prefix to the `/foo` shape: leading slash, no trailing slash, empty allowed.
    static func normalisedPrefix(_ raw: String) -> String {
        var prefix = raw
        while prefix.hasSuffix("/") { prefix.removeLast() }
        guard !prefix.isEmpty else { return "" }
        return prefix.hasPrefix("/") ? prefix : "/" + prefix
    }

    /// True for an IPv6 literal. A bare `:` is decisive: a DNS name cannot contain one, and a
    /// literal already carrying brackets is reported as *not* needing more.
    static func isIPv6Literal(_ host: String) -> Bool {
        host.contains(":") && !host.hasPrefix("[")
    }
}
