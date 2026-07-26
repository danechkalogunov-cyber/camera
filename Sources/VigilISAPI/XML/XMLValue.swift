//
//  XMLValue.swift
//  VigilISAPI
//
//  The lenient typed accessors: what a device's text becomes, and what happens when it is absent,
//  empty, mis-cased, comma-decimalled or plain junk.
//  Implements docs/spec-isapi.md §7.4 and docs/API_CONTRACT.md §4.5.
//
//  Leniency here is not sloppiness: every rule below exists because a shipped firmware does it.
//  `<enabled>yes</enabled>`, `<Duration>1,5</Duration>` and `<brightness>50 </brightness>` are all
//  real, and a reader that returned `nil` for them would show a user an empty settings panel.
//

import Foundation
import VigilProtocols

// MARK: - XMLValue

/// A value read from a path: the element (or attribute) that matched, plus the context needed to
/// explain its absence.
///
/// Every non-throwing accessor answers `nil` rather than throwing, so optional and
/// firmware-variant fields read without `try`. The `required…` variants throw
/// `ISAPIError.malformedResponse` carrying the path, the parent element and its actual children,
/// which is the diagnostic a `DecodingError` cannot give.
public struct XMLValue: Sendable {

    /// The matched element, or `nil` when the path matched nothing or matched an attribute.
    public let node: XMLNode?

    /// The matched attribute's value, when the path ended in `@attr`.
    public let attribute: String?

    /// The path that produced this value, verbatim, for error messages.
    public let path: String

    /// The element the last path segment searched inside, for sibling enumeration in errors.
    public let parent: XMLNode?

    /// Builds a value. Constructed by `XMLNode.subscript`; there is no reason to build one by hand
    /// outside a test.
    public init(node: XMLNode?, attribute: String? = nil, path: String, parent: XMLNode?) {
        self.node = node
        self.attribute = attribute
        self.path = path
        self.parent = parent
    }

    // MARK: Presence

    /// True when an element or an attribute matched. An element present but empty still `exists`.
    public var exists: Bool { node != nil || attribute != nil }

    /// The raw text: the attribute value, or the element's trimmed character data.
    ///
    /// `nil` when the path matched nothing **and** when the element is present but empty — the two
    /// are distinguished by `exists`, because `<name/>` means "no name" everywhere ISAPI uses it.
    public var string: String? {
        let raw = attribute ?? node?.text
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    // MARK: Numbers

    /// An integer, tolerating surrounding whitespace, a leading `+`, and trailing units.
    ///
    /// `"1250"`, `" +1250"` and `"1250 kbps"` all read 1250; `"kbps"` reads `nil`. Trailing units
    /// appear on `bitRate` fields on at least one 5.4.x DVR.
    public var int: Int? {
        guard let raw = string else { return nil }
        var digits = ""
        var index = raw.startIndex
        if raw[index] == "+" || raw[index] == "-" {
            digits.append(raw[index])
            index = raw.index(after: index)
        }
        while index < raw.endIndex, raw[index].isNumber {
            digits.append(raw[index])
            index = raw.index(after: index)
        }
        guard digits.count > (digits.hasPrefix("+") || digits.hasPrefix("-") ? 1 : 0) else {
            return nil
        }
        return Int(digits.hasPrefix("+") ? String(digits.dropFirst()) : digits)
    }

    /// A double, accepting a comma decimal separator (`"1,5"` reads 1.5).
    ///
    /// Some firmwares localise a floating-point field to the device's language; the value is a
    /// number in both spellings and reading it as `nil` would blank a working control.
    public var double: Double? {
        guard let raw = string else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    // MARK: Booleans

    /// Spellings accepted as `true`, compared lowercased after trimming.
    static let trueSpellings: Set<String> = ["true", "1", "yes", "on", "enable", "enabled", "open"]

    /// Spellings accepted as `false`.
    static let falseSpellings: Set<String> = ["false", "0", "no", "off", "disable", "disabled",
                                              "close"]

    /// A boolean over the full ISAPI vocabulary. Anything outside both tables reads `nil`.
    public var bool: Bool? {
        guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        if Self.trueSpellings.contains(raw) { return true }
        if Self.falseSpellings.contains(raw) { return false }
        return nil
    }

    // MARK: Time and bytes

    /// A date in any form §7.5 lists, or `nil`. A naive form is read as UTC; the caller applies the
    /// device's cached offset when it has one.
    public var date: Date? {
        guard let raw = string else { return nil }
        return ISAPITime.parse(raw)?.date
    }

    /// The parsed date together with whether the wire form carried a zone at all.
    public var dateReading: ISAPITime.Reading? {
        guard let raw = string else { return nil }
        return ISAPITime.parse(raw)
    }

    /// Even-length hexadecimal, whitespace stripped, as bytes. `nil` for odd length or non-hex.
    public var hexData: Data? {
        guard let raw = string else { return nil }
        let compact = raw.filter { !$0.isWhitespace }
        guard let bytes = Hex.decodeOrNil(compact) else { return nil }
        return Data(bytes)
    }

    /// Base64 as bytes, whitespace tolerated. `nil` when the text is not valid Base64.
    public var base64Data: Data? {
        guard let raw = string else { return nil }
        let compact = raw.filter { !$0.isWhitespace }
        guard let bytes = Base64.decodeOrNil(compact) else { return nil }
        return Data(bytes)
    }

    /// A UUID string with any surrounding braces removed. Not validated as a UUID: several
    /// firmwares put a non-UUID session token in the same element.
    public var uuidString: String? {
        guard let raw = string else { return nil }
        var trimmed = raw
        if trimmed.hasPrefix("{") { trimmed.removeFirst() }
        if trimmed.hasSuffix("}") { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Defaulting reads

    /// The integer at this path, or `fallback` when it is absent or unreadable.
    public func int(or fallback: Int) -> Int { int ?? fallback }

    /// The boolean at this path, or `fallback`.
    public func bool(or fallback: Bool) -> Bool { bool ?? fallback }

    /// The text at this path, or `fallback`.
    public func string(or fallback: String) -> String { string ?? fallback }

    /// The double at this path, or `fallback`.
    public func double(or fallback: Double) -> Double { double ?? fallback }

    /// An integer clamped into `range`, or `fallback` when absent or unreadable.
    ///
    /// For fields a device occasionally reports outside their own advertised range — a brightness
    /// of 255 on a 0…100 control — where clamping shows a usable UI and `nil` shows none.
    public func int(clampedTo range: ClosedRange<Int>, or fallback: Int) -> Int {
        guard let value = int else { return fallback }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    // MARK: Required reads

    /// The text at this path.
    /// - Throws: `ISAPIError.malformedResponse` naming the path, the parent and its actual
    ///   children, so one log line identifies which firmware variant was not handled.
    public func requiredString() throws(ISAPIError) -> String {
        guard let value = string else { throw missing() }
        return value
    }

    /// The integer at this path.
    /// - Throws: `ISAPIError.malformedResponse` for an absent path or unparseable text.
    public func requiredInt() throws(ISAPIError) -> Int {
        guard let value = int else { throw malformed(expected: "an integer") }
        return value
    }

    /// The boolean at this path.
    /// - Throws: `ISAPIError.malformedResponse` for an absent path or a spelling outside §7.4.
    public func requiredBool() throws(ISAPIError) -> Bool {
        guard let value = bool else { throw malformed(expected: "a boolean") }
        return value
    }

    /// The date at this path.
    /// - Throws: `ISAPIError.malformedResponse` for an absent path or an unrecognised time form.
    public func requiredDate() throws(ISAPIError) -> Date {
        guard let value = date else { throw malformed(expected: "an ISO 8601 or compact time") }
        return value
    }

    // MARK: Diagnostics

    /// The error for an absent path, listing what the parent element actually contained.
    func missing() -> ISAPIError {
        .malformedResponse("missing \(path) in <\(parent?.name ?? "?")>; present children: "
                           + "[\(parent?.childKeys.joined(separator: ", ") ?? "")]")
    }

    /// The error for a present but unreadable value. Absence is reported as absence, not as a
    /// malformed value, because the two lead to different fixes.
    func malformed(expected: String) -> ISAPIError {
        guard let raw = string else { return missing() }
        return .malformedResponse("\(path) is \"\(raw)\" in <\(parent?.name ?? "?")>, expected "
                                  + expected)
    }
}
