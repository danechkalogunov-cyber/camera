//
//  Redact.swift
//  VigilProtocols
//
//  The single redaction point for the whole project: every log line, every metadata
//  value and every string in the diagnostics bundle passes through here.
//
//  Implements docs/API_CONTRACT.md §3.10 (ruling R-15), FEATURES.md §20.6 and
//  ARCHITECTURE.md §8.6.
//

/// The one redaction implementation. `Redaction`, `LogRedaction` and
/// `String.redactingSecrets()` do not exist (API_CONTRACT §2 R-15).
///
/// Every rule below is a hard requirement from `FEATURES.md` §20.6 and `ARCHITECTURE.md` §8.6, and
/// is covered by a fuzz test that seeds secrets in several encodings and asserts none survives any
/// log-formatting path. Redaction is **idempotent** and never lengthens a string past 2×.
///
/// The rules differ by kind of secret, and the difference is deliberate:
///
/// * a **password** is never useful in a log, so it never appears in any form;
/// * an **`Authorization` value** is a password equivalent, so it is elided whole;
/// * a **session id** is needed to correlate two log lines but not to read, so it is hashed;
/// * a **serial** and a **MAC** identify hardware the user owns, so enough is kept to recognise
///   the device (last four characters, last two octets) and no more.
public enum Redact {

    // MARK: Marks

    /// What an elided value becomes. Three characters, so redaction cannot double the length of
    /// any realistic `key=value` pair.
    private static let valueMask = "•••"
    /// What elided XML element content becomes, per API_CONTRACT §3.10.
    private static let elementMask = "<redacted/>"
    /// One masked character, used to preserve the shape of serials and MACs.
    private static let maskCharacter: Character = "\u{2022}"

    // MARK: Key tables

    /// Keys whose value is elided after either `=` or `:`. These are passwords by another name and
    /// are never useful in a log.
    private static let anySeparatorKeys: [[Character]] = [
        Array("password"), Array("passwd"), Array("pwd"), Array("pass"),
        Array("secret"), Array("token"), Array("apikey"), Array("api_key"),
    ]

    /// Keys whose value is elided only after `=`. They appear as parameters in Digest challenges
    /// and query strings; matching them after a colon as well would eat `response: 200 OK` out of
    /// every RTSP trace, which is the kind of over-redaction that makes people turn logging off.
    private static let equalsOnlyKeys: [[Character]] = [
        Array("nonce"), Array("cnonce"), Array("opaque"), Array("response"),
        Array("challenge"), Array("salt"), Array("iv"), Array("sessionid"),
        Array("auth"), Array("credential"),
    ]

    /// Header names whose entire value is elided.
    private static let secretHeaders: [[Character]] = [
        Array("authorization"), Array("proxy-authorization"),
        Array("www-authenticate"), Array("proxy-authenticate"),
    ]

    /// ISAPI XML elements whose content is elided. `securityVer` is a prefix match, covering
    /// `securityVersion`, `securityVer` and the several spellings across firmware.
    private static let secretElements: [[Character]] = [
        Array("password"), Array("macaddress"), Array("serialnumber"), Array("challenge"),
        Array("salt"), Array("iv"), Array("sessionid"),
    ]
    private static let secretElementPrefixes: [[Character]] = [Array("securityver")]

    // MARK: - Text

    /// Passwords, `Authorization` / `WWW-Authenticate` values, Digest `nonce`/`cnonce`/`opaque`/
    /// `response`, `Basic <b64>`, `password=`, `pwd=`, and the ISAPI XML elements
    /// `<password>`, `<macAddress>`, `<serialNumber>`, `<challenge>`, `<salt>`, `<iv>`,
    /// `<securityVer*>`, `<sessionID>`. Elements keep their tags; contents become `<redacted/>`.
    ///
    /// URL userinfo (`rtsp://admin:hunter2@host/…`) is stripped too, because a URL is the most
    /// common way a password reaches a log line by accident.
    ///
    /// Applying this twice changes nothing: every replacement it makes is itself a value it would
    /// leave alone.
    public static func secrets(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var chars = Array(text)
        chars = stripUserinfo(chars)
        chars = redactSecretHeaders(chars)
        chars = redactXMLElements(chars)
        chars = redactBasicTokens(chars)
        chars = redactKeyedValues(chars)
        return String(chars)
    }

    /// Convenience: `secrets` over the message and every metadata value.
    ///
    /// Metadata *keys* are left alone: they are compile-time constants chosen by us, and redacting
    /// them would make the log unsearchable.
    public static func event(_ event: LogEvent) -> LogEvent {
        var redacted = event
        redacted.message = secrets(in: event.message)
        redacted.metadata = event.metadata.mapValues { secrets(in: $0) }
        return redacted
    }

    // MARK: - Identifiers

    /// An RTSP `Session:` id → a stable 4-hex FNV-1a tag: `sess#7f3a`.
    ///
    /// Stable within and across runs, so two log lines about the same session can be correlated;
    /// one-way, so the id cannot be replayed out of a diagnostics bundle. An empty input yields
    /// `sess#0000`.
    public static func sessionID(_ raw: String) -> String {
        "sess#" + hex4(UInt16(truncatingIfNeeded: fnv1a64(raw, seed: 0)))
    }

    /// A serial number → last 4 characters: `••••••••4C21`.
    ///
    /// The last four are what the user can read off the label to confirm which device this is. A
    /// serial of 4 characters or fewer is masked completely — there would be nothing left to hide.
    public static func serial(_ raw: String) -> String {
        let chars = Array(raw)
        guard chars.count > 4 else {
            return String(repeating: maskCharacter, count: chars.count)
        }
        let kept = chars.suffix(4)
        return String(repeating: maskCharacter, count: chars.count - 4) + String(kept)
    }

    /// A MAC → last 2 octets at `info` and above; full only at `debug`.
    ///
    /// A MAC is a permanent hardware identifier and a strong cross-log correlator, so the general
    /// case keeps only enough to tell two cameras apart: `••:••:••:••:1A:2B`. Input with any of
    /// the four separator forms (`:`, `-`, `.`, none) is accepted; anything that is not twelve hex
    /// digits is masked completely rather than guessed at.
    public static func mac(_ raw: String, level: LogLevel) -> String {
        if level == .debug { return raw }
        let digits = Array(raw).filter { $0.isHexDigit }
        guard digits.count == 12 else {
            return String(repeating: maskCharacter, count: Array(raw).count)
        }
        let tail = String(digits.suffix(4)).uppercased()
        let fifth = tail.prefix(2)
        let sixth = tail.suffix(2)
        return "••:••:••:••:\(fifth):\(sixth)"
    }

    /// Stable pseudonym for the diagnostics bundle: `192.168.1.64` → `cam-3f9c`.
    /// Local logs keep real addresses — they are LAN addresses and are needed to diagnose.
    ///
    /// `salt` is generated per bundle, so the same camera gets different pseudonyms in two bundles
    /// and the mapping cannot be precomputed.
    public static func host(_ raw: String, salt: UInt64) -> String {
        "cam-" + hex4(UInt16(truncatingIfNeeded: fnv1a64(raw, seed: salt)))
    }

    // MARK: - Locations

    /// Strips userinfo; keeps scheme, host, port and path. Query values for keys matching the
    /// secret patterns are elided.
    ///
    /// Anything that does not look like a URL is still passed through `secrets`, so a mangled or
    /// truncated URL cannot leak by failing to parse.
    public static func url(_ raw: String) -> String {
        var chars = stripUserinfo(Array(raw))
        chars = redactQueryValues(chars)
        return secrets(in: String(chars))
    }

    /// Replaces the user's home directory with `~`. Used in the diagnostics bundle.
    ///
    /// Matches `/Users/<name>/` and `/home/<name>/` wherever they appear, so a path embedded in a
    /// longer message is covered too. The user's short name is a real identifier and often their
    /// full name.
    public static func path(_ raw: String) -> String {
        var chars = Array(raw)
        for prefix in [Array("/Users/"), Array("/home/")] {
            var index = 0
            var out: [Character] = []
            out.reserveCapacity(chars.count)
            while index < chars.count {
                if matches(chars, at: index, prefix) {
                    // Consume "/Users/" and the account name that follows it.
                    var cursor = index + prefix.count
                    while cursor < chars.count, chars[cursor] != "/" { cursor += 1 }
                    out.append("~")
                    index = cursor
                } else {
                    out.append(chars[index])
                    index += 1
                }
            }
            chars = out
        }
        return String(chars)
    }

    // MARK: - Scanning primitives

    /// ASCII-only lowercase mirror of `chars`, guaranteed to have the same length so indices into
    /// one are valid in the other. `String.lowercased()` cannot be used for this: it changes the
    /// character count for some scripts.
    private static func asciiLowercased(_ chars: [Character]) -> [Character] {
        chars.map { c in
            guard let ascii = c.asciiValue, ascii >= 65, ascii <= 90 else { return c }
            return Character(UnicodeScalar(ascii + 32))
        }
    }

    /// True when `needle` occurs at `index`. `needle` must already be lowercase for a
    /// case-insensitive match against an `asciiLowercased` haystack.
    private static func matches(_ chars: [Character], at index: Int, _ needle: [Character]) -> Bool {
        guard index >= 0, index + needle.count <= chars.count else { return false }
        for offset in 0..<needle.count where chars[index + offset] != needle[offset] {
            return false
        }
        return true
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// True when the character before `index` cannot be part of a preceding word, so a key match
    /// at `index` is a whole key and not the tail of a longer identifier.
    private static func isAtWordStart(_ chars: [Character], _ index: Int) -> Bool {
        index == 0 || !isWordCharacter(chars[index - 1])
    }

    // MARK: - Rules

    /// `scheme://user:pass@host/…` → `scheme://host/…`.
    private static func stripUserinfo(_ chars: [Character]) -> [Character] {
        let marker = Array("://")
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            guard matches(chars, at: index, marker) else {
                out.append(chars[index])
                index += 1
                continue
            }
            out.append(contentsOf: marker)
            let authorityStart = index + marker.count
            var cursor = authorityStart
            var lastAt: Int?
            while cursor < chars.count {
                let c = chars[cursor]
                if c == "/" || c == "?" || c == "#" || c == " " || c == "\t"
                    || c == "\"" || c == "'" || c == "<" || c == ">" || c == "\n" || c == "\r" {
                    break
                }
                if c == "@" { lastAt = cursor }
                cursor += 1
            }
            // Skip everything up to and including the last '@' inside the authority.
            index = lastAt.map { $0 + 1 } ?? authorityStart
        }
        return out
    }

    /// `Authorization: Digest username="admin", response="…"` → `Authorization: •••`.
    private static func redactSecretHeaders(_ chars: [Character]) -> [Character] {
        let lower = asciiLowercased(chars)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            var matched: [Character]?
            for name in secretHeaders where matches(lower, at: index, name) {
                if isAtWordStart(chars, index) { matched = name }
                break
            }
            guard let name = matched else {
                out.append(chars[index])
                index += 1
                continue
            }
            var cursor = index + name.count
            while cursor < chars.count, chars[cursor] == " " { cursor += 1 }
            guard cursor < chars.count, chars[cursor] == ":" else {
                out.append(chars[index])
                index += 1
                continue
            }
            cursor += 1
            out.append(contentsOf: chars[index..<cursor])
            while cursor < chars.count, chars[cursor] == " " { cursor += 1 }
            out.append(" ")
            // Everything to the end of the line is the header value.
            var end = cursor
            while end < chars.count, chars[end] != "\r", chars[end] != "\n" { end += 1 }
            if end > cursor { out.append(contentsOf: Array(valueMask)) }
            index = end
        }
        return out
    }

    /// `<password>hunter2</password>` → `<password><redacted/></password>`.
    private static func redactXMLElements(_ chars: [Character]) -> [Character] {
        let lower = asciiLowercased(chars)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            guard chars[index] == "<", index + 1 < chars.count, chars[index + 1] != "/" else {
                out.append(chars[index])
                index += 1
                continue
            }
            // Read the tag name.
            var nameEnd = index + 1
            while nameEnd < chars.count, isWordCharacter(chars[nameEnd]) { nameEnd += 1 }
            let name = Array(lower[(index + 1)..<nameEnd])
            guard isSecretElement(name), nameEnd > index + 1 else {
                out.append(chars[index])
                index += 1
                continue
            }
            // Find the end of the opening tag, and refuse a self-closing one.
            var openEnd = nameEnd
            while openEnd < chars.count, chars[openEnd] != ">" { openEnd += 1 }
            guard openEnd < chars.count, chars[openEnd - 1] != "/" else {
                out.append(chars[index])
                index += 1
                continue
            }
            let contentStart = openEnd + 1
            let closing = Array("</") + name
            var closeStart = contentStart
            var found = false
            while closeStart < chars.count {
                if matches(lower, at: closeStart, closing) {
                    found = true
                    break
                }
                closeStart += 1
            }
            guard found, closeStart > contentStart else {
                out.append(contentsOf: chars[index...openEnd])
                index = openEnd + 1
                continue
            }
            out.append(contentsOf: chars[index...openEnd])
            out.append(contentsOf: Array(elementMask))
            index = closeStart
        }
        return out
    }

    /// True for an element whose content must be elided, including the `securityVer*` family.
    private static func isSecretElement(_ name: [Character]) -> Bool {
        if secretElements.contains(name) { return true }
        return secretElementPrefixes.contains { prefix in
            name.count >= prefix.count && Array(name.prefix(prefix.count)) == prefix
        }
    }

    /// `Basic YWRtaW46aHVudGVyMg==` → `Basic •••`, wherever it appears.
    private static func redactBasicTokens(_ chars: [Character]) -> [Character] {
        let lower = asciiLowercased(chars)
        let basic = Array("basic")
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            guard matches(lower, at: index, basic), isAtWordStart(chars, index) else {
                out.append(chars[index])
                index += 1
                continue
            }
            var cursor = index + basic.count
            var spaces = 0
            while cursor < chars.count, chars[cursor] == " " {
                cursor += 1
                spaces += 1
            }
            var end = cursor
            while end < chars.count, isBase64Character(chars[end]) { end += 1 }
            guard spaces > 0, end - cursor >= 4 else {
                out.append(chars[index])
                index += 1
                continue
            }
            out.append(contentsOf: basic)
            out.append(" ")
            out.append(contentsOf: Array(valueMask))
            index = end
        }
        return out
    }

    private static func isBase64Character(_ c: Character) -> Bool {
        guard let ascii = c.asciiValue else { return false }
        switch ascii {
        case 65...90, 97...122, 48...57: return true          // A-Z a-z 0-9
        case 43, 47, 61, 45, 95: return true                  // + / = - _
        default: return false
        }
    }

    /// `password=hunter2`, `"pwd": "hunter2"`, `nonce="abc"` → the key, then `•••`.
    private static func redactKeyedValues(_ chars: [Character]) -> [Character] {
        let lower = asciiLowercased(chars)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            var key: [Character]?
            var equalsOnly = false
            for candidate in anySeparatorKeys where matches(lower, at: index, candidate) {
                if isAtWordStart(chars, index), !isWordCharacter(charAfter(chars, index, candidate)) {
                    key = candidate
                }
                break
            }
            if key == nil {
                for candidate in equalsOnlyKeys where matches(lower, at: index, candidate) {
                    if isAtWordStart(chars, index),
                       !isWordCharacter(charAfter(chars, index, candidate)) {
                        key = candidate
                        equalsOnly = true
                    }
                    break
                }
            }
            guard let matchedKey = key else {
                out.append(chars[index])
                index += 1
                continue
            }
            var cursor = index + matchedKey.count
            // An optional closing quote, for the JSON form `"password": "…"`.
            if cursor < chars.count, chars[cursor] == "\"" || chars[cursor] == "'" { cursor += 1 }
            while cursor < chars.count, chars[cursor] == " " { cursor += 1 }
            guard cursor < chars.count,
                  chars[cursor] == "=" || (chars[cursor] == ":" && !equalsOnly) else {
                out.append(chars[index])
                index += 1
                continue
            }
            cursor += 1
            while cursor < chars.count, chars[cursor] == " " { cursor += 1 }
            guard cursor < chars.count else {
                out.append(chars[index])
                index += 1
                continue
            }
            let quoted = chars[cursor] == "\"" || chars[cursor] == "'"
            let quote = chars[cursor]
            var valueStart = cursor
            if quoted { valueStart += 1 }
            var valueEnd = valueStart
            if quoted {
                while valueEnd < chars.count, chars[valueEnd] != quote { valueEnd += 1 }
            } else {
                while valueEnd < chars.count, !isValueTerminator(chars[valueEnd]) { valueEnd += 1 }
            }
            guard valueEnd > valueStart else {
                out.append(chars[index])
                index += 1
                continue
            }
            out.append(contentsOf: chars[index..<valueStart])
            out.append(contentsOf: Array(valueMask))
            index = valueEnd
        }
        return out
    }

    private static func charAfter(_ chars: [Character], _ index: Int, _ key: [Character]) -> Character {
        let next = index + key.count
        return next < chars.count ? chars[next] : " "
    }

    private static func isValueTerminator(_ c: Character) -> Bool {
        c == "&" || c == "," || c == ";" || c == "\"" || c == "'" || c == "<" || c == ">"
            || c == " " || c == "\t" || c == "\n" || c == "\r"
    }

    /// Elides the values of secret-looking query keys, leaving the rest of the URL readable.
    private static func redactQueryValues(_ chars: [Character]) -> [Character] {
        guard let queryStart = chars.firstIndex(of: "?") else { return chars }
        let head = Array(chars[..<(queryStart + 1)])
        let tail = Array(chars[(queryStart + 1)...])
        return head + redactKeyedValues(tail)
    }

    // MARK: - Hashing

    /// FNV-1a, 64-bit. Not a cryptographic hash: it exists to make two log lines correlatable, and
    /// the values it protects (session ids, LAN addresses) are not secrets on their own.
    private static func fnv1a64(_ text: String, seed: UInt64) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        for shift in stride(from: 0, through: 56, by: 8) {
            hash ^= (seed >> UInt64(shift)) & 0xFF
            hash = hash &* prime
        }
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    private static func hex4(_ value: UInt16) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(4)
        for shift in stride(from: 12, through: 0, by: -4) {
            out.append(digits[Int((value >> UInt16(shift)) & 0xF)])
        }
        return out
    }
}
