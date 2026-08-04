//
//  ConnectFormState.swift
//  VigilUI
//
//  The connect form's value state: three fields, their validation, the in-flight flag and the
//  diagnosis a failed attempt resolved to. Plus the host validator and the RTSP-paste parser.
//  macOS-only. Implements docs/UX.md §8.3 and docs/REQUIREMENTS-CUSTOMER.md §R1.4.
//

#if os(macOS)

import Foundation

import SwiftUI

import VigilProtocols

// MARK: - ConnectField problems

/// What is wrong with one field, as a value rather than as a sentence.
///
/// Keeping the *reason* separate from the *wording* is what lets the state stay `Sendable` and
/// testable while the copy stays in the view layer where `VTheme` and the bundle live.
package enum ConnectFieldProblem: Sendable, Hashable {

    /// The address is empty.
    case hostRequired

    /// The address is not an IPv4 address, an IPv6 address or a host name.
    case hostMalformed

    /// The account name is empty. Hikvision's factory account is `admin` (R1.4).
    case usernameRequired

    /// The password is empty. Strength is not judged — it is the camera's password, not ours
    /// (UX.md §8.3).
    case passwordRequired

    /// The sentence shown under the field: specific and actionable, never "Invalid input"
    /// (DESIGN.md §9.5).
    @MainActor
    package var message: LocalizedStringKey {
        switch self {
        case .hostRequired:
            return "Enter the camera's address."
        case .hostMalformed:
            return "Use an IP address like 192.168.1.64, or a host name."
        case .usernameRequired:
            return "Enter the account name. Hikvision cameras use admin unless it was changed."
        case .passwordRequired:
            return "Enter the camera's password."
        }
    }
}

// MARK: - ConnectRequest

/// What the form hands to the app when the user presses Connect.
///
/// ⛔ Deliberately **not** `Codable`, and its ``description`` redacts the password, so that a
/// credential cannot reach a log line, a JSON file or a crash report by accident — the same rule
/// `VigilCore.Credential` follows (API_CONTRACT.md §4.9).
package struct ConnectRequest: Sendable, Hashable, CustomStringConvertible {

    /// The camera's address: an IPv4 address, an IPv6 address, or a host name.
    package let host: String

    /// The account name.
    package let username: String

    /// The password, held only long enough to reach the Keychain.
    package let password: String

    package let httpPort: Int
    package let rtspPort: Int
    package let channel: Int
    package let usesTLS: Bool

    /// Creates a request.
    package init(host: String, username: String, password: String,
                 httpPort: Int = 80, rtspPort: Int = 554, channel: Int = 1,
                 usesTLS: Bool = false) {
        self.host = host
        self.username = username
        self.password = password
        self.httpPort = httpPort
        self.rtspPort = rtspPort
        self.channel = channel
        self.usesTLS = usesTLS
    }

    package var description: String {
        "ConnectRequest(host: \(host), username: \(username), password: <redacted>)"
    }
}

// MARK: - ConnectFormState

/// The connect form's state.
///
/// A value type rather than an `@Observable` class: every rule below is a pure function of the
/// three strings, which makes the whole form testable without a view and without a main actor.
/// The screen holds it in `@State`.
package struct ConnectFormState: Sendable, Hashable {

    // MARK: - Stored Properties

    /// The camera's address, as typed.
    package var host: String = ""

    /// The account name. Prefilled with `admin`, because that is the Hikvision factory account and
    /// R1.4's acceptance test is that the user types **only** the password.
    package var username: String = "admin"

    /// The password, as typed.
    package var password: String = ""

    /// Explicit connection coordinates. Unlike a parsed URL, these stay visible and editable.
    ///
    /// ⚠️ These are the *only* declarations of the four. ``absorbPastedURL()`` writes them too —
    /// a pasted `:8554` lands in ``rtspPort``, a pasted `rtsps://` in ``usesTLS`` — and it used to
    /// do so through a second, shadow set of optional properties further down this struct. Two
    /// declarations of `rtspPort` do not compile, and the half of that pair the form displayed was
    /// never the half the paste wrote. One declaration, two writers: the field and the parser.
    ///
    /// ``usesTLS`` is recorded and not yet acted on — this build has no TLS transport — but it is
    /// kept so pasting an `rtsps://` URL does not silently lose the one bit of the address that
    /// says it is encrypted.
    package var httpPort: Int = 80
    package var rtspPort: Int = 554
    package var channel: Int = 1
    package var usesTLS: Bool = false

    /// Result of the credential-free connection test shown without leaving or saving the form.
    package var testResult: String?
    package var isTesting: Bool = false

    /// What is wrong with ``host``, once it has been checked.
    package var hostProblem: ConnectFieldProblem?

    /// What is wrong with ``username``, once it has been checked.
    package var usernameProblem: ConnectFieldProblem?

    /// What is wrong with ``password``, once it has been checked.
    package var passwordProblem: ConnectFieldProblem?

    /// True from the moment Connect is pressed until the attempt resolves.
    package var isConnecting: Bool = false

    /// The named cause of the last failure, or `nil` if there has not been one.
    package var diagnosis: ConnectDiagnosis?

    /// Increments on every failure, driving the error shake (§7.4 #45).
    package var failureCount: Int = 0

    /// The RTSP path a pasted URL carried, or `nil` when the address is a bare host.
    ///
    /// ⚠️ Carried, not shown. The form has no path field yet — that is a separate piece of work —
    /// so this is state the user cannot see, which is a trap unless it is cleared the moment the
    /// address stops being the URL it came from. ``absorbPastedURL()`` is what guarantees that:
    /// it rewrites *and* clears from the same rule, on every change to ``host``.
    package var rtspPath: String?

    // MARK: - Initialisation

    /// Creates an empty form with `admin` prefilled.
    package init() {}

    // MARK: - Derived state

    /// Whether Connect is enabled.
    ///
    /// Non-empty host and credentials, and no attempt already running. We deliberately do **not**
    /// require a successful test first: some cameras only answer once they are recording, and
    /// blocking the user is worse than one bad row (UX.md §8.3).
    package var canSubmit: Bool {
        !isConnecting
            && !Self.trimmed(host).isEmpty
            && !Self.trimmed(username).isEmpty
            && !password.isEmpty
    }

    /// The request the form would submit right now.
    package var request: ConnectRequest {
        ConnectRequest(host: Self.trimmed(host),
                       username: Self.trimmed(username),
                       password: password, httpPort: httpPort, rtspPort: rtspPort,
                       channel: channel, usesTLS: usesTLS)
    }

    // MARK: - Validation

    /// Checks one field and records the result.
    ///
    /// Called on submit, on focus loss, and 400 ms after typing stops — never per keystroke, so a
    /// half-typed address never flashes an error (DESIGN.md §9.5).
    package mutating func validate(_ field: ConnectField) {
        switch field {
        case .host:
            hostProblem = Self.problem(forHost: host)
        case .username:
            usernameProblem = Self.trimmed(username).isEmpty ? .usernameRequired : nil
        case .password:
            passwordProblem = password.isEmpty ? .passwordRequired : nil
        }
    }

    /// Checks every field and reports whether the form may be submitted.
    package mutating func validateAll() -> Bool {
        validate(.host)
        validate(.username)
        validate(.password)
        return hostProblem == nil && usernameProblem == nil && passwordProblem == nil
    }

    /// Clears the previous failure. Called when the user edits anything, so a stale diagnosis
    /// never sits under a form that has since changed.
    package mutating func clearDiagnosis() {
        diagnosis = nil
    }

    /// Records a failure and bumps ``failureCount`` so the form can shake once per failure.
    package mutating func fail(_ diagnosis: ConnectDiagnosis) {
        self.diagnosis = diagnosis
        self.isConnecting = false
        self.failureCount += 1
        if diagnosis.fieldToFocus == .password {
            passwordProblem = nil
        }
    }

    // MARK: - Paste handling

    /// Absorbs a pasted RTSP (or HTTP) URL into the separate fields.
    ///
    /// Pasting `rtsp://admin:secret@192.168.1.64:554/Streaming/Channels/101` fills the address,
    /// the user name and the password in one action — the fastest path an advanced user has, and
    /// the one UX.md §8.3 calls out by name. Anything that is not a URL with a host is left alone.
    ///
    /// ⛔ THE PORT AND THE PATH USED TO BE DROPPED. Only host, user and password were taken, so
    /// pasting the full URL a camera's own web page hands you threw away the two parts that are
    /// hardest to retype — `:8554` on a device behind a port map, and `/Streaming/Channels/102` for
    /// the sub-stream. The user then watched the probe ladder search for a path they had just
    /// supplied. UX.md §12 says "auto-parses into **every** field"; this is the rest of it.
    ///
    /// The clearing arm matters as much as the parsing one. `rtspPath` and `rtspPort` are state the
    /// form does not yet display, and this method is the only writer of both — so a value left over
    /// from a URL the user has since edited away would silently override the probe ladder for a
    /// different camera. Every non-URL address resets them.
    ///
    /// - Returns: `true` when the text was a URL and the fields were rewritten.
    @discardableResult
    package mutating func absorbPastedURL() -> Bool {
        let text = Self.trimmed(host)
        guard text.contains("://"),
              let components = URLComponents(string: text),
              let parsedHost = components.host,
              !parsedHost.isEmpty,
              let scheme = components.scheme?.lowercased(),
              Self.pasteableSchemes.contains(scheme) else {
            rtspPath = nil
            rtspPort = Self.defaultRTSPPort
            usesTLS = false
            return false
        }
        // `URLComponents` percent-decodes `user` and `password` for us, which matters because a
        // Hikvision password may legally contain `@` or `/` in its encoded form.
        host = parsedHost
        if let user = components.user, !user.isEmpty {
            username = user
        }
        if let secret = components.password, !secret.isEmpty {
            password = secret
        }
        // ⛔ ASSIGNED, NOT CONDITIONALLY ASSIGNED. `if let port = components.port` left the previous
        // URL's port in a visible field: paste a camera on `:8554`, then paste a second camera with
        // no port, and the form shows the new address on the old camera's port — which is a
        // connection attempt to a device that never answers, with the wrong number sitting in plain
        // sight and nothing to say where it came from. Every other field this method touches is
        // rewritten unconditionally; this one has to be too, and 554 is the default it falls back
        // to for the same reason the clearing arm above uses it.
        rtspPort = components.port ?? Self.defaultRTSPPort
        rtspPath = Self.streamPath(from: components)
        usesTLS = scheme == "rtsps" || scheme == "https"
        hostProblem = Self.problem(forHost: host)
        return true
    }

    /// What ``rtspPort`` falls back to whenever a pasted address does not name one. Spelled once,
    /// because the parse arm and the clearing arm must agree and used to be two loose literals.
    static let defaultRTSPPort = 554

    /// The schemes worth expanding. A pasted `ftp://` is not a camera, and rewriting the field for
    /// one would be worse than ignoring it.
    private static let pasteableSchemes: Set<String> = ["rtsp", "rtsps", "http", "https"]

    /// The path with its query, or `nil` when the URL carried nothing beyond `/`.
    ///
    /// The query is kept because Hikvision puts real arguments there — `?starttime=` is how the
    /// archive is addressed (spec-isapi.md §15.6), and a path stripped of it would open the live
    /// stream while claiming to open a recording. A bare `/` is dropped: that is what a browser
    /// adds, not where the stream lives, and storing it would override the probe ladder with
    /// nothing.
    private static func streamPath(from components: URLComponents) -> String? {
        let path = components.path
        guard !path.isEmpty, path != "/" else { return nil }
        guard let query = components.query, !query.isEmpty else { return path }
        return path + "?" + query
    }

    // MARK: - Private Helpers

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func problem(forHost value: String) -> ConnectFieldProblem? {
        let candidate = trimmed(value)
        if candidate.isEmpty { return .hostRequired }
        return ConnectHost.isValid(candidate) ? nil : .hostMalformed
    }
}

// MARK: - ConnectHost

/// The host-field validator.
///
/// This is a **form-level** sanity check, not a parser that ever sees network bytes: its job is to
/// tell the user "that is not an address" before a four-second connect timeout does. It is
/// deliberately permissive about IPv6, because rejecting a valid address the user can see working
/// elsewhere is a far worse failure than accepting one the socket will reject in a moment.
package enum ConnectHost {

    /// The longest legal host name, in bytes (RFC 1035 §2.3.4).
    package static let maximumLength = 253

    /// The longest legal label within a host name.
    package static let maximumLabelLength = 63

    /// Whether `candidate` is an IPv4 address, a plausible IPv6 address, or a host name.
    package static func isValid(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.utf8.count <= maximumLength else { return false }
        // From Sources/VigilProtocols/Net/IPv4Address.swift:
        //     public init?(_ description: String)
        // Strict dotted-quad; returns nil for anything else, including a bare host name.
        if IPv4Address(candidate) != nil { return true }
        let unbracketed = stripBrackets(candidate)
        if unbracketed.contains(":") { return isPlausibleIPv6(unbracketed) }
        return isValidHostname(candidate)
    }

    /// Removes the `[…]` an IPv6 literal wears inside a URL.
    package static func stripBrackets(_ candidate: String) -> String {
        guard candidate.hasPrefix("["), candidate.hasSuffix("]"), candidate.count > 2 else {
            return candidate
        }
        return String(candidate.dropFirst().dropLast())
    }

    /// A permissive IPv6 check: hex groups separated by colons, at most one `::` run, at most
    /// eight groups, and an optional trailing IPv4 form for the mapped notation.
    package static func isPlausibleIPv6(_ candidate: String) -> Bool {
        // A zone index (`fe80::1%en0`) is legal and is not ours to validate.
        let address = candidate.split(separator: "%", maxSplits: 1).first.map { String($0) }
            ?? candidate
        guard !address.isEmpty, address.contains(":") else { return false }
        guard address.components(separatedBy: "::").count <= 2 else { return false }

        var groups = address.components(separatedBy: ":")
        // A trailing dotted quad (`::ffff:192.168.1.64`) counts as two groups.
        var budget = 8
        if let last = groups.last, last.contains(".") {
            guard IPv4Address(last) != nil else { return false }
            groups.removeLast()
            budget -= 2
        }
        var nonEmpty = 0
        for group in groups where !group.isEmpty {
            guard group.count <= 4, group.allSatisfy(\.isHexDigit) else { return false }
            nonEmpty += 1
        }
        return nonEmpty <= budget
    }

    /// RFC 1123 host name: dot-separated labels of alphanumerics and hyphens, no leading or
    /// trailing hyphen, each label 1…63 characters.
    package static func isValidHostname(_ candidate: String) -> Bool {
        let name = candidate.hasSuffix(".") ? String(candidate.dropLast()) : candidate
        guard !name.isEmpty else { return false }
        let labels = name.components(separatedBy: ".")
        for label in labels {
            guard !label.isEmpty, label.count <= maximumLabelLength else { return false }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
            let legal = label.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-")
            }
            guard legal else { return false }
        }
        return true
    }
}

#endif  // os(macOS)
