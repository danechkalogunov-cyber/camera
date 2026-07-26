//
//  RTSPChallenge.swift
//  VigilRTSP
//
//  `WWW-Authenticate` / `Proxy-Authenticate` parsing. Quoted-string correct, because Hikvision
//  realms contain commas, parentheses and spaces — `IP Camera(52491), Building 3` is a realm, not
//  two challenge parameters — and because some firmware puts a Digest and a Basic challenge in one
//  header value.
//  Implements docs/spec-rtsp.md §6.1–6.2 and docs/API_CONTRACT.md §4.3.
//

import VigilProtocols

/// One authentication challenge.
///
/// Field shapes follow API_CONTRACT §4.3: `scheme` and `algorithm` are strings rather than enums so
/// an unknown scheme survives to the log line that will explain the failure. `qop` is empty for the
/// RFC 2069 no-`qop` form, which is the **primary** Hikvision path and not a legacy fallback.
public struct RTSPChallenge: Sendable, Hashable {

    /// `"Digest"`, `"Basic"`, or whatever the device actually wrote, in its original casing.
    public var scheme: String

    /// The realm, unquoted, verbatim. Empty when the device omitted it — legal for `Basic`, and a
    /// Digest challenge without a realm still hashes, with an empty realm in A1.
    public var realm: String

    /// The server nonce, unquoted. `nil` makes a Digest challenge unusable.
    public var nonce: String?

    /// `opaque`, unquoted. Echoed verbatim in `Authorization` when present.
    public var opaque: String?

    /// The `qop` options, lowercased, in the order sent. **Empty means RFC 2069 no-`qop`.**
    public var qop: [String]

    /// `"MD5"` or `"MD5-sess"`, normalised; any other spelling is kept verbatim so it can be
    /// reported. Defaults to `"MD5"` when the device sent no `algorithm`, as most Hikvision
    /// firmware does.
    public var algorithm: String

    /// Whether the device said the nonce is stale. Comparison is unquote, ASCII-lowercase, compare
    /// to `"true"` — Hikvision sends `stale="FALSE"`, quoted and upper-case, where RFC 2617 says an
    /// unquoted token.
    public var stale: Bool

    /// Creates a challenge. Used by the parser and by tests; nothing else builds one.
    public init(scheme: String, realm: String = "", nonce: String? = nil, opaque: String? = nil,
                qop: [String] = [], algorithm: String = "MD5", stale: Bool = false) {
        self.scheme = scheme
        self.realm = realm
        self.nonce = nonce
        self.opaque = opaque
        self.qop = qop
        self.algorithm = algorithm
        self.stale = stale
    }

    // MARK: - Classification

    /// Whether this is a Digest challenge (case-insensitive).
    public var isDigest: Bool { ASCII.lowercased(scheme) == "digest" }

    /// Whether this is a Basic challenge (case-insensitive).
    public var isBasic: Bool { ASCII.lowercased(scheme) == "basic" }

    /// Whether the algorithm is the session variant, which folds the nonce and cnonce into HA1.
    public var isSessionAlgorithm: Bool { ASCII.lowercased(algorithm) == "md5-sess" }

    /// Whether Vigil can compute a response for this challenge: Digest with a nonce and an MD5
    /// family algorithm, or Basic. `qop` containing only `auth-int` fails here — sending a hash
    /// computed the wrong way is worse than reporting that we cannot authenticate.
    public var isSupported: Bool {
        if isBasic { return true }
        guard isDigest, nonce != nil else { return false }
        let family = ASCII.lowercased(algorithm)
        guard family == "md5" || family == "md5-sess" else { return false }
        return qop.isEmpty || qop.contains("auth")
    }

    // MARK: - Parsing

    /// Parses one header value, which may carry **several** challenges.
    ///
    /// The split is the subtle part. A new challenge begins at a bare token that is *not* followed
    /// by `=`: in `Digest realm="x", nonce="y", Basic realm="z"` the fragment `Basic realm="z"`
    /// starts one because `Basic` has no `=` before the first unquoted space. Fragments are cut at
    /// top-level commas only, so a comma inside a quoted realm never splits anything.
    ///
    /// Malformed input never throws: a parameter without a name, an unterminated quote, or a
    /// parameter before any scheme is dropped, and whatever parsed is returned. A caller that gets
    /// an empty array knows only that no challenge was legible.
    public static func parseAll(_ headerValue: String) -> [RTSPChallenge] {
        var challenges: [RTSPChallenge] = []
        for fragment in RTSPHeaderScanner.topLevelSplit(Substring(headerValue), on: ",") {
            let token = RTSPHeaderScanner.trimmingOWS(fragment)
            guard !token.isEmpty else { continue }
            if let space = firstUnquotedWhitespace(in: token) {
                let head = RTSPHeaderScanner.trimmingOWS(token[token.startIndex ..< space])
                let rest = RTSPHeaderScanner.trimmingOWS(token[token.index(after: space)...])
                // A scheme is a bare token followed by whitespace and then a parameter *name*.
                // The `rest.first != "="` guard is what keeps `realm = "x"` — a parameter written
                // with spaces around its equals sign — from being mistaken for a scheme.
                if RTSPHeaderScanner.isToken(head), rest.first != "=" {
                    challenges.append(RTSPChallenge(scheme: String(head)))
                    apply(rest, to: &challenges)
                    continue
                }
            }
            guard RTSPHeaderScanner.firstUnquotedIndex(of: "=", in: token) != nil else {
                challenges.append(RTSPChallenge(scheme: String(token)))   // e.g. a bare `Negotiate`
                continue
            }
            apply(token, to: &challenges)
        }
        return challenges
    }

    /// The first space or tab outside a quoted string, or `nil`.
    private static func firstUnquotedWhitespace(in text: Substring) -> Substring.Index? {
        let space = RTSPHeaderScanner.firstUnquotedIndex(of: " ", in: text)
        let tab = RTSPHeaderScanner.firstUnquotedIndex(of: "\t", in: text)
        switch (space, tab) {
        case (let space?, let tab?): return Swift.min(space, tab)
        case (let space?, nil): return space
        case (nil, let tab?): return tab
        case (nil, nil): return nil
        }
    }

    /// Applies one `name=value` parameter to the challenge being built.
    private static func apply(_ parameter: Substring, to challenges: inout [RTSPChallenge]) {
        guard let index = challenges.indices.last else { return }
        guard let equals = RTSPHeaderScanner.firstUnquotedIndex(of: "=", in: parameter) else {
            return
        }
        let rawName = RTSPHeaderScanner.trimmingOWS(parameter[parameter.startIndex ..< equals])
        let rawValue = RTSPHeaderScanner.trimmingOWS(parameter[parameter.index(after: equals)...])
        let name = ASCII.lowercased(String(rawName))
        let value = RTSPHeaderScanner.unquote(rawValue)
        switch name {
        case "realm":
            challenges[index].realm = value
        case "nonce":
            challenges[index].nonce = value
        case "opaque":
            challenges[index].opaque = value
        case "stale":
            challenges[index].stale = ASCII.lowercased(value) == "true"
        case "algorithm":
            challenges[index].algorithm = normalizedAlgorithm(value)
        case "qop":
            challenges[index].qop = RTSPHeaderScanner
                .topLevelSplit(Substring(value), on: ",")
                .map { ASCII.lowercased(String(RTSPHeaderScanner.trimmingOWS($0))) }
                .filter { !$0.isEmpty }
        default:
            break                       // `domain`, `charset`, `userhash` and vendor extensions
        }
    }

    /// Normalises the two spellings Vigil implements and passes anything else through untouched.
    private static func normalizedAlgorithm(_ raw: String) -> String {
        switch ASCII.lowercased(raw) {
        case "md5": "MD5"
        case "md5-sess": "MD5-sess"
        default: raw
        }
    }

    // MARK: - Selection

    /// Picks the challenge to answer out of everything a `401` carried.
    ///
    /// Digest always wins over Basic when both are offered, because Basic puts the password on the
    /// wire in clear. Basic is chosen only when it is the only supported option **and** the caller
    /// opted in or the connection is TLS. Returns `nil` when nothing is answerable.
    public static func select(from challenges: [RTSPChallenge],
                              allowBasicOverPlaintext: Bool,
                              isTLS: Bool) -> RTSPChallenge? {
        if let digest = challenges.first(where: { $0.isDigest && $0.isSupported }) { return digest }
        guard allowBasicOverPlaintext || isTLS else { return nil }
        return challenges.first { $0.isBasic }
    }
}
