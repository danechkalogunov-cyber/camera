//
//  DigestChallenge.swift
//  VigilISAPI
//
//  The `WWW-Authenticate` challenge: parsing it, and the RFC 2069 / RFC 2617 arithmetic that
//  answers it.
//  Implements docs/spec-isapi.md §5.1 and §5.2.
//
//  The **no-`qop` (RFC 2069) form is first-class here, not a fallback**: Hikvision 5.1.x–5.5.x
//  firmware challenges with `realm`, `nonce` and `stale` and nothing else, which is the majority of
//  the installed base. A client that assumes `qop=auth` computes a response those devices reject,
//  and the symptom — a permanent 401 that looks exactly like a wrong password — costs the user
//  their account after five attempts.
//

import Foundation
import VigilProtocols

// MARK: - Challenge

/// A parsed `WWW-Authenticate: Digest …` challenge.
public struct DigestChallenge: Sendable, Hashable {

    /// The protection realm, verbatim. Hikvision's contains parentheses and a space:
    /// `IP Camera(51253)`. It is hashed into `HA1` byte for byte, so it is never normalised.
    public var realm: String

    /// The server nonce, verbatim.
    public var nonce: String

    /// The opaque value to echo back, when the device sent one.
    public var opaque: String?

    /// Offered quality-of-protection values, lowercased. **Empty means RFC 2069 no-`qop` mode**,
    /// which is a different response formula, not a missing option.
    public var qop: [String]

    /// The hash algorithm the device asked for.
    public var algorithm: Algorithm

    /// True when the device says the nonce merely expired. A stale challenge is **not** an
    /// authentication failure and must not count towards the lockout budget (R-25).
    public var stale: Bool

    /// The `domain` list, when present. Advisory only; Vigil authenticates per request.
    public var domain: [String]

    /// Which digest algorithm the challenge named.
    public enum Algorithm: Sendable, Hashable {
        /// `MD5`, or absent — the default.
        case md5
        /// `MD5-sess`.
        case md5sess
        /// Anything else, e.g. `SHA-256`. Carried so the error can name it.
        case unsupported(String)
    }

    /// Builds a challenge.
    public init(realm: String, nonce: String, opaque: String? = nil, qop: [String] = [],
                algorithm: Algorithm = .md5, stale: Bool = false, domain: [String] = []) {
        self.realm = realm
        self.nonce = nonce
        self.opaque = opaque
        self.qop = qop
        self.algorithm = algorithm
        self.stale = stale
        self.domain = domain
    }

    /// True when `qop=auth` was offered and Vigil will use it.
    public var usesQOPAuth: Bool { qop.contains("auth") }

    // MARK: Parsing

    /// The Digest challenge in `headers`, preferring Digest when Basic is offered alongside it.
    ///
    /// Multiple `WWW-Authenticate` headers, and several schemes inside one header, both occur.
    /// Returns `nil` when no Digest challenge is present.
    public static func parse(headers: HTTPHeaders) -> DigestChallenge? {
        for value in headers.all("WWW-Authenticate") {
            for section in sections(value) where section.scheme == "digest" {
                if let challenge = parse(parameters: section.parameters) { return challenge }
            }
        }
        return nil
    }

    /// True when the response offers Basic authentication.
    public static func offersBasic(headers: HTTPHeaders) -> Bool {
        headers.all("WWW-Authenticate").contains { value in
            sections(value).contains { $0.scheme == "basic" }
        }
    }

    /// Parses a single header value, e.g. `Digest realm="x", nonce="y"`.
    public static func parse(header: String) -> DigestChallenge? {
        for section in sections(header) where section.scheme == "digest" {
            if let challenge = parse(parameters: section.parameters) { return challenge }
        }
        return nil
    }

    /// The `nextnonce` from an `Authentication-Info` header, when the device sent one. Rare, but
    /// 6.x firmware does, and adopting it saves a 401 round trip on the next request.
    public static func nextNonce(headers: HTTPHeaders) -> String? {
        guard let value = headers["Authentication-Info"] else { return nil }
        return parameters(in: value)["nextnonce"]
    }

    /// Builds a challenge from an already-split parameter list. `realm` and `nonce` are required;
    /// everything else has a documented default.
    static func parse(parameters: [String: String]) -> DigestChallenge? {
        guard let realm = parameters["realm"], let nonce = parameters["nonce"] else { return nil }
        let algorithm: Algorithm
        switch parameters["algorithm"]?.lowercased() {
        case nil, "md5": algorithm = .md5
        case "md5-sess": algorithm = .md5sess
        case let other?: algorithm = .unsupported(parameters["algorithm"] ?? other)
        }
        let qop = (parameters["qop"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return DigestChallenge(
            realm: realm,
            nonce: nonce,
            opaque: parameters["opaque"],
            qop: qop,
            algorithm: algorithm,
            stale: parameters["stale"]?.lowercased() == "true",
            domain: (parameters["domain"] ?? "").split(separator: " ").map(String.init))
    }

    /// One authentication scheme and its parameters.
    struct Section: Sendable {
        var scheme: String
        var parameters: [String: String]
    }

    /// Splits a header value into scheme sections.
    ///
    /// A fragment whose text before the first space contains no `=` starts a new scheme — which is
    /// how `Digest realm="IP Camera(51253)", nonce="…", Basic realm="…"` splits correctly even
    /// though the realm contains a space.
    static func sections(_ value: String) -> [Section] {
        var out: [Section] = []
        var scheme: String?
        var parameters: [String: String] = [:]

        for fragment in splitHonouringQuotes(value, separator: ",") {
            let trimmed = fragment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            var remainder = trimmed
            if let space = trimmed.firstIndex(of: " "),
               !trimmed[trimmed.startIndex..<space].contains("=") {
                if let scheme { out.append(Section(scheme: scheme, parameters: parameters)) }
                scheme = String(trimmed[trimmed.startIndex..<space]).lowercased()
                parameters = [:]
                remainder = String(trimmed[trimmed.index(after: space)...])
                    .trimmingCharacters(in: .whitespaces)
            } else if !trimmed.contains("="), scheme == nil {
                // A scheme with no parameters at all, e.g. `Negotiate`.
                out.append(Section(scheme: trimmed.lowercased(), parameters: [:]))
                continue
            }
            guard let separator = remainder.firstIndex(of: "=") else { continue }
            let name = String(remainder[remainder.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces).lowercased()
            let raw = String(remainder[remainder.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            parameters[name] = unquoted(raw)
        }
        if let scheme { out.append(Section(scheme: scheme, parameters: parameters)) }
        return out
    }

    /// Parameters of a single-scheme header value such as `Authentication-Info`.
    static func parameters(in value: String) -> [String: String] {
        var out: [String: String] = [:]
        for fragment in splitHonouringQuotes(value, separator: ",") {
            let trimmed = fragment.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces).lowercased()
            let raw = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            out[name] = unquoted(raw)
        }
        return out
    }

    /// Splits on `separator`, ignoring separators inside double quotes.
    static func splitHonouringQuotes(_ value: String, separator: Character) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        for character in value {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == separator, !inQuotes {
                out.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        out.append(current)
        return out
    }

    /// Removes one layer of surrounding double quotes, if present.
    static func unquoted(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        return String(raw.dropFirst().dropLast())
    }
}

// MARK: - Digest arithmetic

/// The RFC 2069 / RFC 2617 string constructions, isolated so they can be tested against published
/// vectors without an actor, a socket or a clock.
///
/// All hashing is over UTF-8 bytes and all hex is lowercase. `auth-int` is not implemented: no
/// Hikvision firmware offers it, and implementing it would mean buffering every upload body.
package enum HTTPDigest {

    /// `HA1 = MD5(username ":" realm ":" password)`.
    package static func ha1(username: String, realm: String, password: String) -> String {
        MD5.hexDigest("\(username):\(realm):\(password)")
    }

    /// `MD5-sess` HA1: `MD5(HA1 ":" nonce ":" cnonce)`.
    package static func sessionHA1(base: String, nonce: String, cnonce: String) -> String {
        MD5.hexDigest("\(base):\(nonce):\(cnonce)")
    }

    /// `HA2 = MD5(method ":" digestURI)`.
    ///
    /// `digestURI` is the request-line URI **including the query string**. For
    /// `GET /ISAPI/Streaming/channels/101/picture?videoResolutionWidth=640` it is everything after
    /// the authority, `?640` included. Hashing the path alone is the single most common cause of a
    /// permanent 401 against Hikvision, because every parameterised request then fails while the
    /// unparameterised ones work.
    package static func ha2(method: String, uri: String) -> String {
        MD5.hexDigest("\(method):\(uri)")
    }

    /// RFC 2069 (no `qop`) response: `MD5(HA1 ":" nonce ":" HA2)`.
    package static func response(ha1: String, nonce: String, ha2: String) -> String {
        MD5.hexDigest("\(ha1):\(nonce):\(ha2)")
    }

    /// RFC 2617 `qop=auth` response: `MD5(HA1 ":" nonce ":" nc ":" cnonce ":" qop ":" HA2)`.
    package static func response(ha1: String, nonce: String, nonceCount: String,
                                 cnonce: String, qop: String, ha2: String) -> String {
        MD5.hexDigest("\(ha1):\(nonce):\(nonceCount):\(cnonce):\(qop):\(ha2)")
    }

    /// Eight lowercase hex digits, as `nc` goes on the wire.
    package static func nonceCountHex(_ value: UInt32) -> String {
        var out = ""
        out.reserveCapacity(8)
        for shift in stride(from: 28, through: 0, by: -4) {
            let nibble = UInt8((value >> UInt32(shift)) & 0xF)
            out.append(Character(UnicodeScalar(nibble < 10 ? 0x30 + nibble : 0x57 + nibble)))
        }
        return out
    }

    /// The `Authorization` header value for a challenge.
    ///
    /// Emits, in this order: `username`, `realm`, `nonce`, `uri`, `response`, then `algorithm`
    /// only for `MD5-sess`, then `qop`/`nc`/`cnonce` only in `qop` mode, then `opaque` when the
    /// device sent one. `qop=auth` is **unquoted** per RFC 7616 — Hikvision accepts both spellings
    /// but some proxies do not.
    ///
    /// - Parameters:
    ///   - challenge: the parsed challenge being answered.
    ///   - credential: the account. The password never appears in the output.
    ///   - method: the HTTP verb, upper-case.
    ///   - uri: the request-line URI, path **and** query.
    ///   - cnonce: 16 hex characters from the injected random source. Ignored in no-`qop` mode.
    ///   - nonceCount: the per-(realm, nonce) counter, starting at 1.
    /// - Returns: the header value, or `nil` when the algorithm is one Vigil cannot compute.
    package static func authorization(challenge: DigestChallenge, credential: Credential,
                                      method: String, uri: String,
                                      cnonce: String, nonceCount: UInt32) -> String? {
        let baseHA1 = ha1(username: credential.account, realm: challenge.realm,
                          password: credential.secret)
        let secret: String
        switch challenge.algorithm {
        case .md5:
            secret = baseHA1
        case .md5sess:
            secret = sessionHA1(base: baseHA1, nonce: challenge.nonce, cnonce: cnonce)
        case .unsupported:
            return nil
        }
        let hashedRequest = ha2(method: method, uri: uri)
        let counter = nonceCountHex(nonceCount)
        let digest: String
        if challenge.usesQOPAuth {
            digest = response(ha1: secret, nonce: challenge.nonce, nonceCount: counter,
                              cnonce: cnonce, qop: "auth", ha2: hashedRequest)
        } else {
            digest = response(ha1: secret, nonce: challenge.nonce, ha2: hashedRequest)
        }

        var parts = [
            "username=\"\(escapeQuoted(credential.account))\"",
            "realm=\"\(escapeQuoted(challenge.realm))\"",
            "nonce=\"\(escapeQuoted(challenge.nonce))\"",
            "uri=\"\(uri)\"",
            "response=\"\(digest)\"",
        ]
        if case .md5sess = challenge.algorithm { parts.append("algorithm=MD5-sess") }
        if challenge.usesQOPAuth {
            parts.append("qop=auth")
            parts.append("nc=\(counter)")
            parts.append("cnonce=\"\(cnonce)\"")
        }
        if let opaque = challenge.opaque { parts.append("opaque=\"\(escapeQuoted(opaque))\"") }
        return "Digest " + parts.joined(separator: ", ")
    }

    /// `Basic base64(username:password)`.
    ///
    /// Encoded as UTF-8. Hikvision truncates non-ASCII passwords, so a caller that sees one logs a
    /// warning; the encoding here is still the correct one to send.
    package static func basicAuthorization(credential: Credential) -> String {
        let joined = Array("\(credential.account):\(credential.secret)".utf8)
        return "Basic " + Base64.encode(joined)
    }

    /// Escapes a value going inside a quoted-string parameter.
    ///
    /// A `"` or `\` in a username or realm would otherwise end the parameter early and change the
    /// meaning of everything after it.
    static func escapeQuoted(_ raw: String) -> String {
        guard raw.contains("\"") || raw.contains("\\") else { return raw }
        var out = ""
        out.reserveCapacity(raw.count + 4)
        for character in raw {
            if character == "\"" || character == "\\" { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
