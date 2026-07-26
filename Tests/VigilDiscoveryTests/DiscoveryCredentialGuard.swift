//
//  DiscoveryCredentialGuard.swift
//  VigilDiscoveryTests
//
//  The mechanical enforcement of the one absolute rule: discovery never sends a credential. Any bytes
//  a test hands it are scanned for authentication material, and finding some fails the suite.
//  Covers docs/spec-discovery.md §6.10, §13.1 and §15.
//

import Foundation
import Testing

/// Scans outbound bytes for anything that could authenticate, and fails the test when it finds it.
///
/// Why this exists as code rather than as a review habit: Hikvision devices lock an account after
/// roughly five failed authentications. A discovery pass that tried even one password would lock every
/// camera on the network at once, and the user would find out hours later, from a camera that no longer
/// works. `§6.10` therefore forbids credentials outright — not behind a flag, not "just to check" — and
/// the specification asks for that to be enforced by a double that fails the suite (§13.1).
///
/// Every encoder in this module is routed through `violations(in:)` by the tests, and
/// `DiscoveryCredentialGuardTests` proves the guard itself trips when a credential is introduced: a
/// guard that cannot fail is worse than none, because it reads as proof.
///
/// When the injected transport protocols land, the `MockExchanger` that implements `ByteExchanging`
/// must call `requireNoCredentials(in:label:)` on every request body it is handed. That is the same
/// check, applied to the fingerprint path this half of the module does not own.
enum DiscoveryCredentialGuard {

    /// One piece of authentication material found in outbound bytes.
    struct Violation: Sendable, Hashable, CustomStringConvertible {
        /// The lowercased token that matched, or a description of the shape that did.
        let token: String
        /// Byte offset where it was found, for a diff against a capture.
        let offset: Int

        var description: String { "'\(token)' at byte \(offset)" }
    }

    /// Tokens that may never appear in anything discovery sends.
    ///
    /// `authorization` covers `Authorization` and `Proxy-Authorization` in any case. `usernametoken`,
    /// `passworddigest`, `wsse` and `nonce` cover the WS-Security header an ONVIF SOAP call would
    /// carry. `password`, `passwd` and `credential` catch a body that carries one in the clear.
    static let forbiddenTokens = [
        "authorization", "usernametoken", "passworddigest", "wsse", "password", "passwd",
        "credential", "x-api-key", "cookie", "www-authenticate",
    ]

    /// Every credential-shaped thing in `payload`, in offset order. Empty means clean.
    ///
    /// The bytes are read as ISO-8859-1 so that binary payloads are searchable too and no input can
    /// evade the scan by not being valid UTF-8.
    static func violations(in payload: Data) -> [Violation] {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(payload.count)
        for byte in payload { scalars.append(Unicode.Scalar(byte)) }
        return violations(in: String(scalars))
    }

    /// Every credential-shaped thing in `text`, in offset order. Empty means clean.
    static func violations(in text: String) -> [Violation] {
        let lowered = Array(text.lowercased().utf8)
        var found: [Violation] = []
        for token in forbiddenTokens {
            let pattern = Array(token.utf8)
            var index = 0
            while index + pattern.count <= lowered.count {
                if Array(lowered[index..<(index + pattern.count)]) == pattern {
                    found.append(Violation(token: token, offset: index))
                    index += pattern.count
                } else {
                    index += 1
                }
            }
        }
        found.append(contentsOf: userInfoViolations(in: lowered))
        return found.sorted { $0.offset < $1.offset }
    }

    /// Finds `scheme://user:secret@host`, the form that smuggles a credential into a URL.
    private static func userInfoViolations(in lowered: [UInt8]) -> [Violation] {
        let marker = Array("://".utf8)
        var found: [Violation] = []
        var index = 0
        while index + marker.count <= lowered.count {
            guard Array(lowered[index..<(index + marker.count)]) == marker else {
                index += 1
                continue
            }
            var cursor = index + marker.count
            var sawColon = false
            while cursor < lowered.count {
                let byte = lowered[cursor]
                if byte == UInt8(ascii: "/") || byte == UInt8(ascii: "?")
                    || byte == UInt8(ascii: " ") || byte == UInt8(ascii: "<")
                    || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n") { break }
                if byte == UInt8(ascii: ":") { sawColon = true }
                if byte == UInt8(ascii: "@"), sawColon {
                    found.append(Violation(token: "userinfo@host", offset: index))
                    break
                }
                cursor += 1
            }
            index += marker.count
        }
        return found
    }

    /// Records a test failure when `payload` carries a credential. This is the call that makes the
    /// rule mechanical: a future change that starts sending an `Authorization` header fails here
    /// rather than in the field, on somebody's locked-out camera.
    static func requireNoCredentials(in payload: Data, label: String) {
        let found = violations(in: payload)
        if !found.isEmpty {
            Issue.record("""
                \(label) carries authentication material, which discovery must never send: \
                \(found.map(\.description).joined(separator: ", "))
                """)
        }
    }
}
