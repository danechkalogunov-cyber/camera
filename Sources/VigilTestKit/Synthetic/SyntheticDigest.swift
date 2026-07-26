//
//  SyntheticDigest.swift
//  VigilTestKit
//
//  The camera side of RFC 2069 / RFC 2617 authentication: it issues the challenge and it *verifies*
//  the client's response rather than accepting anything. A client that computes HA2 over the wrong
//  URI, reuses a nonce count, or omits `qop` when the challenge offered it is rejected here, which
//  is the whole point — a fixture that rubber-stamped the Authorization header would prove nothing.
//  Implements docs/ARCHITECTURE.md §10.2 and RFC 2617 §3.2.2.
//

import VigilProtocols

// MARK: - Parameter parsing

/// Parsing and verification helpers for the `Authorization` header the client sends back.
public enum SyntheticDigest: Sendable {

    /// Splits a comma-separated `key=value` parameter list, honouring double quotes.
    ///
    /// A comma inside a quoted value — Hikvision realms contain them — does not split. Unquoted
    /// values are accepted. Keys are lower-cased; values are returned verbatim with the surrounding
    /// quotes removed. A malformed fragment with no `=` is skipped rather than throwing, because a
    /// real server tolerates it and the fixture must not be stricter than the thing it imitates.
    public static func parseParameters(_ value: String) -> [String: String] {
        var out: [String: String] = [:]
        var current = ""
        var inQuotes = false
        var fragments: [String] = []
        for character in value {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == "," && !inQuotes {
                fragments.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fragments.append(current)
        for fragment in fragments {
            let trimmed = fragment.trimmingASCIIWhitespace()
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<separator]).trimmingASCIIWhitespace()
            var raw = String(trimmed[trimmed.index(after: separator)...]).trimmingASCIIWhitespace()
            if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
                raw = String(raw.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            out[key.lowercased()] = raw
        }
        return out
    }

    // MARK: Response computation

    /// The RFC 2069 (no `qop`) digest response.
    public static func responseNoQop(username: String, realm: String, password: String,
                                     method: String, uri: String, nonce: String) -> String {
        let ha1 = MD5.hexDigest("\(username):\(realm):\(password)")
        let ha2 = MD5.hexDigest("\(method):\(uri)")
        return MD5.hexDigest("\(ha1):\(nonce):\(ha2)")
    }

    /// The RFC 2617 `qop=auth` digest response.
    public static func responseQopAuth(username: String, realm: String, password: String,
                                       method: String, uri: String, nonce: String,
                                       nonceCount: String, cnonce: String) -> String {
        let ha1 = MD5.hexDigest("\(username):\(realm):\(password)")
        let ha2 = MD5.hexDigest("\(method):\(uri)")
        return MD5.hexDigest("\(ha1):\(nonce):\(nonceCount):\(cnonce):auth:\(ha2)")
    }

    // MARK: Verification

    /// The outcome of checking one `Authorization` header.
    public enum Verdict: Sendable, Hashable {
        /// The header is absent, so the camera must challenge.
        case missing
        /// The header is present and correct.
        case accepted
        /// The header is present but wrong: bad scheme, bad credential, or a bad digest response.
        case rejected(reason: String)
    }

    /// Verifies a `Basic` credential.
    ///
    /// - Returns: `.rejected` when the base64 is undecodable, has no colon, or does not match.
    public static func verifyBasic(_ headerValue: String, username: String,
                                   password: String) -> Verdict {
        let token = headerValue.dropFirst("Basic".count).trimmingASCIIWhitespace()
        guard let decoded = Base64.decodeOrNil(String(token)) else {
            return .rejected(reason: "basic credential is not valid base64")
        }
        let text = String(decoding: decoded, as: UTF8.self)
        guard let colon = text.firstIndex(of: ":") else {
            return .rejected(reason: "basic credential has no colon separator")
        }
        let sentUser = String(text[text.startIndex..<colon])
        let sentSecret = String(text[text.index(after: colon)...])
        guard sentUser == username, sentSecret == password else {
            return .rejected(reason: "basic credential does not match")
        }
        return .accepted
    }

    /// Verifies a `Digest` credential against the challenge the camera issued.
    ///
    /// - Parameters:
    ///   - requireQop: `true` when the challenge offered `qop="auth"`, in which case a response
    ///     computed without `nc`/`cnonce` is rejected.
    ///   - expectedNonce: the nonce most recently issued. A response against an older nonce is
    ///     rejected so the stale-nonce path is genuinely exercised.
    /// - Returns: `.accepted` only when the recomputed response matches byte for byte.
    public static func verifyDigest(_ headerValue: String, method: String, username: String,
                                    password: String, realm: String, expectedNonce: String,
                                    requireQop: Bool) -> Verdict {
        let parameters = parseParameters(String(headerValue.dropFirst("Digest".count)))
        guard let sentUser = parameters["username"] else {
            return .rejected(reason: "digest response has no username")
        }
        guard let uri = parameters["uri"] else {
            return .rejected(reason: "digest response has no uri")
        }
        guard let response = parameters["response"]?.lowercased() else {
            return .rejected(reason: "digest response has no response value")
        }
        guard let nonce = parameters["nonce"] else {
            return .rejected(reason: "digest response has no nonce")
        }
        guard nonce == expectedNonce else {
            return .rejected(reason: "digest response uses a stale nonce")
        }
        guard sentUser == username else {
            return .rejected(reason: "digest username does not match")
        }
        let expected: String
        if requireQop {
            guard let nonceCount = parameters["nc"], let cnonce = parameters["cnonce"] else {
                return .rejected(reason: "challenge offered qop=auth but nc/cnonce are absent")
            }
            guard parameters["qop"]?.lowercased() == "auth" else {
                return .rejected(reason: "challenge offered qop=auth but qop is absent or wrong")
            }
            expected = responseQopAuth(username: username, realm: realm, password: password,
                                       method: method, uri: uri, nonce: nonce,
                                       nonceCount: nonceCount, cnonce: cnonce)
        } else {
            expected = responseNoQop(username: username, realm: realm, password: password,
                                     method: method, uri: uri, nonce: nonce)
        }
        guard expected == response else {
            return .rejected(reason: "digest response value does not match")
        }
        return .accepted
    }
}

// MARK: - Small string helper

extension String {

    /// Drops leading and trailing spaces, tabs, CR and LF.
    ///
    /// Written here rather than reached for from Foundation so the trimming set is exactly the
    /// linear-whitespace of RFC 2616 and does not vary with Unicode definitions.
    func trimmingASCIIWhitespace() -> String {
        var view = Substring(self)
        while let first = view.first, first == " " || first == "\t" || first == "\r" || first == "\n" {
            view = view.dropFirst()
        }
        while let last = view.last, last == " " || last == "\t" || last == "\r" || last == "\n" {
            view = view.dropLast()
        }
        return String(view)
    }
}
