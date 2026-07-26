//
//  RTSPHeaderScanner.swift
//  VigilRTSP
//
//  Token, quoted-string and parameter-list primitives shared by the challenge parser, the Transport
//  header, RTP-Info and Session. Everything here is quote-aware, because the values these headers
//  carry contain the separators they are split on: realm="IP Camera(52491), Building 3" and
//  url="rtsp://h/a?b=1;c=2" are both real.
//  Implements docs/spec-rtsp.md §4.6.
//

import VigilProtocols

/// Quote-aware splitting primitives. Allocation-light: everything works on `Substring` slices and
/// materialises a `String` only at the end.
package enum RTSPHeaderScanner {

    // MARK: - Tokens

    /// RFC 2326 §15.1 `token`: any CHAR except CTLs and separators.
    ///
    /// The separator set is `()<>@,;:\"/[]?={} SP HT`. Bytes ≥ 0x80 are **not** tokens: a header
    /// name is ASCII, and treating a UTF-8 continuation byte as a name character is how a header
    /// smuggling bug starts.
    package static func isTokenByte(_ byte: UInt8) -> Bool { ASCII.isTokenByte(byte) }

    /// Whether every character of `text` is a token byte and `text` is non-empty.
    package static func isToken(_ text: Substring) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy(isTokenByte)
    }

    // MARK: - Splitting

    /// Splits at `separator` occurrences that are **outside** quoted strings.
    ///
    /// A `\"` escape inside a quoted string does not close it. An unterminated quote makes the rest
    /// of the input one field, which is the lenient reading: a device that forgot a closing quote
    /// still gets its value parsed rather than shredded into fragments.
    /// Empty fields are preserved, so `a,,b` yields three slices.
    package static func topLevelSplit(_ text: Substring, on separator: Character) -> [Substring] {
        var out: [Substring] = []
        var fieldStart = text.startIndex
        var index = text.startIndex
        var inQuotes = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if inQuotes, character == "\\" {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == separator, !inQuotes {
                out.append(text[fieldStart ..< index])
                fieldStart = text.index(after: index)
            }
            index = text.index(after: index)
        }
        out.append(text[fieldStart ..< text.endIndex])
        return out
    }

    /// The first index of `character` outside a quoted string, or `nil`.
    package static func firstUnquotedIndex(of character: Character,
                                           in text: Substring) -> Substring.Index? {
        var index = text.startIndex
        var inQuotes = false
        var escaped = false
        while index < text.endIndex {
            let current = text[index]
            if escaped {
                escaped = false
            } else if inQuotes, current == "\\" {
                escaped = true
            } else if current == "\"" {
                inQuotes.toggle()
            } else if current == character, !inQuotes {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Parameters

    /// Parses a `name=value` list separated by `separator`, honouring quoted values.
    ///
    /// Used for `Transport` (`;`), `WWW-Authenticate` (`,`), `RTP-Info` (`;`) and `Session` (`;`).
    /// Rules, each of which exists because a device does it:
    ///
    /// * a field with no `=` is a flag and yields an empty value (`unicast`, `RTP/AVP/TCP`);
    /// * whitespace around the name, the `=` and the value is trimmed;
    /// * one layer of quoting is removed from the value, with `\"` unescaped;
    /// * the name is **not** lowercased here — callers that need folding do it themselves, because
    ///   `RTP-Info`'s `url` value is case-sensitive while its name is not.
    package static func parameters(_ text: Substring,
                                   separator: Character = ";") -> [(name: String, value: String)] {
        var out: [(name: String, value: String)] = []
        for field in topLevelSplit(text, on: separator) {
            let trimmed = trimmingOWS(field)
            guard !trimmed.isEmpty else { continue }
            guard let equals = firstUnquotedIndex(of: "=", in: trimmed) else {
                out.append((String(trimmed), ""))
                continue
            }
            let name = trimmingOWS(trimmed[trimmed.startIndex ..< equals])
            let value = trimmingOWS(trimmed[trimmed.index(after: equals)...])
            out.append((String(name), unquote(value)))
        }
        return out
    }

    // MARK: - Quoting

    /// Strips one layer of `"` and unescapes `\<char>` inside it. Text that is not quoted is
    /// returned unchanged, including text with an opening quote and no closing one.
    package static func unquote(_ text: Substring) -> String {
        guard text.count >= 2, text.first == "\"", text.last == "\"" else { return String(text) }
        let inner = text.dropFirst().dropLast()
        guard inner.contains("\\") else { return String(inner) }
        var out = ""
        out.reserveCapacity(inner.count)
        var escaped = false
        for character in inner {
            if escaped {
                out.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// Wraps `text` in quotes, escaping `\` and `"`. Used to build `Authorization`, where every
    /// value but `qop`, `nc` and `algorithm` is a quoted string (docs/spec-rtsp.md §6.4).
    package static func quote(_ text: String) -> String {
        var out = "\""
        out.reserveCapacity(text.count + 2)
        for character in text {
            if character == "\\" || character == "\"" { out.append("\\") }
            out.append(character)
        }
        out.append("\"")
        return out
    }

    /// Drops leading and trailing SP and HTAB.
    package static func trimmingOWS(_ text: Substring) -> Substring {
        var slice = text
        while let first = slice.first, first == " " || first == "\t" { slice = slice.dropFirst() }
        while let last = slice.last, last == " " || last == "\t" { slice = slice.dropLast() }
        return slice
    }
}
