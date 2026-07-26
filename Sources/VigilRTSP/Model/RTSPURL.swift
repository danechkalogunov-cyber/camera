//
//  RTSPURL.swift
//  VigilRTSP
//
//  A hand-written RTSP URL value type. `URL`/`URLComponents` are unusable here: they re-encode `=`
//  inside a path segment inconsistently across platforms, which mangles `…/trackID=1`, and
//  `URLComponents` rejects `rtsp://h/a?b=1;c=2`, which Hikvision emits.
//  Implements docs/spec-rtsp.md §10.1 and docs/API_CONTRACT.md §4.3.
//
//  Security invariant enforced by this file: userinfo is parsed but NEVER serialized. Neither
//  `requestLineForm` (the wire) nor `description` (the log) can contain a password.
//

import VigilProtocols

// MARK: - RTSPURL

/// An RTSP URL, lossless in the parts that matter and deliberately lossy in one: credentials are
/// held apart from every rendering.
///
/// The wire form and the printable form are separate properties on purpose. `requestLineForm` is
/// what goes on the request line and, byte for byte, into the Digest `uri=` parameter
/// (docs/spec-rtsp.md §6.4). `description` is what goes in a log line and additionally elides
/// secret-looking query values through `Redact`.
public struct RTSPURL: Sendable, Hashable, CustomStringConvertible {

    /// `"rtsp"` or `"rtsps"`, always lowercased.
    public var scheme: String

    /// Host as written, with IPv6 brackets stripped and any zone id (`%25en0`) kept.
    public var host: String

    /// The port in use: the one the URL carried, else 554 for `rtsp` and 322 for `rtsps`.
    public var port: Int

    /// Absolute path, percent-encoding **preserved verbatim**. Never normalised, never
    /// slash-trimmed: `…/Streaming/Channels/101` and `…/Streaming/Channels/101/` are different
    /// resources on some firmware.
    public var path: String

    /// Query without the `?`, verbatim, or `nil` when there was none. `starttime=…&endtime=…` on a
    /// playback URL lives here and is part of the Digest URI.
    public var query: String?

    /// Userinfo username, percent-decoded. Parsed out of `rtsp://user:pass@host/…` so it cannot be
    /// re-serialized by accident; the session machine passes it to `RTSPAuthenticator` instead.
    public var username: String?

    /// Userinfo password, percent-decoded. Never rendered by any member of this type.
    public var password: String?

    /// Whether `host` is an IPv6 literal and must be re-bracketed when rendered.
    public var isIPv6Literal: Bool

    /// Whether the port is written into `requestLineForm`.
    ///
    /// True when the source URL carried one. This is not cosmetic: Hikvision's Digest
    /// implementation hashes the URI it *parsed*, so a request line must reproduce the operator's
    /// URL exactly — `rtsp://host:554/x` and `rtsp://host/x` produce different `HA2` values, and
    /// dropping the redundant `:554` is precisely rung 2 of the URI-fallback ladder
    /// (docs/spec-rtsp.md §6.8), which would be a no-op if the port were always omitted.
    public var writesPort: Bool

    // MARK: - Construction

    /// Builds a URL from parts. `port` defaults to the scheme default and is then omitted from the
    /// request line unless `writesPort` is set.
    public init(scheme: String = "rtsp", host: String, port: Int? = nil, path: String,
                query: String? = nil, username: String? = nil, password: String? = nil,
                isIPv6Literal: Bool = false) {
        let normalizedScheme = ASCII.lowercased(scheme)
        self.scheme = normalizedScheme
        self.host = host
        self.port = port ?? RTSPURL.defaultPort(for: normalizedScheme)
        self.path = path.hasPrefix("/") ? path : "/" + path
        self.query = query
        self.username = username
        self.password = password
        self.isIPv6Literal = isIPv6Literal
        self.writesPort = port != nil
    }

    /// Parses leniently.
    ///
    /// Accepts a missing scheme (assumes `rtsp://`), a missing path (becomes `/`), userinfo with or
    /// without a password, an IPv6 literal in brackets with a zone id, and a query containing `;`,
    /// `?` or `=`. Returns `nil` — never a half-parsed value — for: an empty string, a scheme other
    /// than `rtsp`/`rtsps`, an empty host, or a port that is not 1…65535.
    ///
    /// Percent-encoding in the path and query is preserved exactly as written. Only userinfo is
    /// decoded, because a password containing `@`, `#` or `/` is normal on Hikvision devices and
    /// the decoded form is what Digest hashes.
    public init?(string: String) {
        var rest = Substring(string).trimmingASCIIWhitespace()
        guard !rest.isEmpty else { return nil }

        var parsedScheme = "rtsp"
        if let separator = rest.firstRange(of: "://") {
            parsedScheme = ASCII.lowercased(String(rest[rest.startIndex ..< separator.lowerBound]))
            guard parsedScheme == "rtsp" || parsedScheme == "rtsps" else { return nil }
            rest = rest[separator.upperBound...]
        }

        // Authority runs to the first '/', '?' or '#'.
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        var authority = rest[rest.startIndex ..< authorityEnd]
        let remainder = rest[authorityEnd...]

        var parsedUser: String?
        var parsedPassword: String?
        if let at = authority.lastIndex(of: "@") {
            let userinfo = authority[authority.startIndex ..< at]
            authority = authority[authority.index(after: at)...]
            if let colon = userinfo.firstIndex(of: ":") {
                parsedUser = RTSPURL.percentDecoded(userinfo[userinfo.startIndex ..< colon])
                parsedPassword = RTSPURL.percentDecoded(userinfo[userinfo.index(after: colon)...])
            } else {
                parsedUser = RTSPURL.percentDecoded(userinfo)
            }
        }

        var parsedHost: String
        var bracketed = false
        var portText: Substring = ""
        if authority.first == "[" {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            bracketed = true
            parsedHost = String(authority[authority.index(after: authority.startIndex) ..< close])
            let afterBracket = authority[authority.index(after: close)...]
            if afterBracket.first == ":" { portText = afterBracket.dropFirst() }
        } else if let colon = authority.lastIndex(of: ":") {
            parsedHost = String(authority[authority.startIndex ..< colon])
            portText = authority[authority.index(after: colon)...]
        } else {
            parsedHost = String(authority)
        }
        guard !parsedHost.isEmpty else { return nil }

        var parsedPort: Int?
        if !portText.isEmpty {
            guard portText.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(portText), value > 0, value <= 65_535 else { return nil }
            parsedPort = value
        }

        var parsedPath = "/"
        var parsedQuery: String?
        if !remainder.isEmpty {
            if let mark = remainder.firstIndex(of: "?") {
                let head = remainder[remainder.startIndex ..< mark]
                parsedPath = head.isEmpty ? "/" : String(head)
                parsedQuery = String(remainder[remainder.index(after: mark)...])
            } else {
                parsedPath = String(remainder)
            }
        }

        self.scheme = parsedScheme
        self.host = parsedHost
        self.port = parsedPort ?? RTSPURL.defaultPort(for: parsedScheme)
        self.path = parsedPath.hasPrefix("/") ? parsedPath : "/" + parsedPath
        self.query = parsedQuery
        self.username = parsedUser
        self.password = parsedPassword
        self.isIPv6Literal = bracketed
        self.writesPort = parsedPort != nil
    }

    // MARK: - Rendering

    /// The wire form for a request line: **no userinfo**, port present exactly when the source URL
    /// carried one, path and query verbatim.
    ///
    /// This string is the Digest `uri=` value. Two independent reasons make userinfo unacceptable
    /// here: RTSP is plaintext, so the password would reach the device's own log; and some firmware
    /// answers `400` to a request line that carries it.
    public var requestLineForm: String {
        var text = scheme + "://" + renderedHost
        if writesPort || port != RTSPURL.defaultPort(for: scheme) { text += ":\(port)" }
        text += path
        if let query { text += "?" + query }
        return text
    }

    /// The same URL with the port always explicit. The inverse of URI-fallback rung 2.
    public var absoluteFormWithPort: String {
        var text = scheme + "://" + renderedHost + ":\(port)" + path
        if let query { text += "?" + query }
        return text
    }

    /// The same URL with no port and no query: URI-fallback rungs 1 and 2 combined
    /// (docs/spec-rtsp.md §6.8).
    package var formWithoutQuery: String {
        var text = scheme + "://" + renderedHost
        if writesPort || port != RTSPURL.defaultPort(for: scheme) { text += ":\(port)" }
        return text + path
    }

    /// The same URL with a default port removed, keeping the query. URI-fallback rung 2.
    package var formWithoutDefaultPort: String {
        var text = scheme + "://" + renderedHost
        if port != RTSPURL.defaultPort(for: scheme) { text += ":\(port)" }
        text += path
        if let query { text += "?" + query }
        return text
    }

    /// The log-safe form: the request-line form with secret-looking query values elided.
    ///
    /// Credentials cannot appear because `requestLineForm` never carries them; `Redact.url` then
    /// removes a `?password=…` or `?token=…` that an operator pasted into the path. This is why the
    /// printable form and the wire form are different properties rather than one string.
    public var description: String { Redact.url(requestLineForm) }

    /// Host rendered for a URL: IPv6 literals get their brackets back.
    private var renderedHost: String { isIPv6Literal ? "[\(host)]" : host }

    // MARK: - Derivation

    /// Appends a control component with exactly one `/` between, keeping the query.
    ///
    /// `rtsp://h/Streaming/Channels/101` + `trackID=1` → `rtsp://h/Streaming/Channels/101/trackID=1`.
    /// The base query is carried onto the track URI, which is what a playback `SETUP` needs: the
    /// device matches `?starttime=` on every track URL (docs/spec-rtsp.md §8.3).
    /// An empty `control`, or `"*"`, returns the URL unchanged.
    public func appendingControl(_ control: String) -> RTSPURL {
        guard !control.isEmpty, control != "*" else { return self }
        var copy = self
        let base = path.hasSuffix("/") ? String(path.dropLast()) : path
        let tail = control.hasPrefix("/") ? String(control.dropFirst()) : control
        copy.path = base + "/" + tail
        return copy
    }

    /// Loose equivalence, used to match an `RTP-Info` `url=` against a track's control URL.
    ///
    /// Case-insensitive on scheme and host, exact on path except for one trailing slash, and
    /// ignores the query — devices routinely echo a track URL with the playback query dropped.
    /// Strings that do not parse are compared verbatim after trimming, so a relative `trackID=1`
    /// still matches itself.
    package static func equivalent(_ first: String, _ second: String) -> Bool {
        guard let left = RTSPURL(string: first), let right = RTSPURL(string: second) else {
            return String(Substring(first).trimmingASCIIWhitespace())
                == String(Substring(second).trimmingASCIIWhitespace())
        }
        func normalizedPath(_ url: RTSPURL) -> String {
            url.path.count > 1 && url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        }
        return left.scheme == right.scheme
            && ASCII.lowercased(left.host) == ASCII.lowercased(right.host)
            && left.port == right.port
            && normalizedPath(left) == normalizedPath(right)
    }

    // MARK: - Helpers

    /// 554 for `rtsp`, 322 for `rtsps` (docs/spec-rtsp.md §17).
    package static func defaultPort(for scheme: String) -> Int { scheme == "rtsps" ? 322 : 554 }

    /// Percent-decodes userinfo, falling back to the raw text when the escape sequence is invalid —
    /// a password is not worth refusing a URL over, and the device will simply reject the login.
    private static func percentDecoded(_ text: Substring) -> String {
        PercentEncoding.decodeOrNil(String(text)) ?? String(text)
    }
}

// MARK: - Substring trimming

extension Substring {

    /// Drops leading and trailing ASCII space, tab, CR and LF. Unicode whitespace is left alone:
    /// a URL with a non-breaking space in it is malformed, and hiding that helps nobody.
    fileprivate func trimmingASCIIWhitespace() -> Substring {
        var slice = self
        while let first = slice.first, first == " " || first == "\t" || first == "\r" || first == "\n" {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last == " " || last == "\t" || last == "\r" || last == "\n" {
            slice = slice.dropLast()
        }
        return slice
    }
}
