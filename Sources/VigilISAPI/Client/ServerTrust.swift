//
//  ServerTrust.swift
//  VigilISAPI
//
//  The injected TLS trust seam and the trust-on-first-use rule it implements.
//  Implements docs/spec-isapi.md §6 and docs/API_CONTRACT.md §4.5.
//
//  `URLAuthenticationChallenge.protectionSpace.serverTrust` is a `SecTrust?` and `Security` does
//  not exist on Linux corelibs, so evaluation happens **outside** this module: `VigilISAPI`
//  declares the protocol, extracts the DER chain where a platform allows it, and `VigilCore`
//  supplies the policy. On Linux the only shipped conformance refuses TLS outright, which is why
//  `https://` endpoints there fail fast with `tlsUnavailableOnThisPlatform` instead of silently
//  trusting everything.
//

import Foundation
import VigilProtocols

// MARK: - Decision

/// The answer to one TLS handshake.
public enum ServerTrustDecision: Sendable, Equatable {
    /// Proceed with the connection.
    case trust
    /// Fail the task. The string is shown to the user as the reason, so it is written for a person.
    case reject(String)
}

// MARK: - Evaluator

/// Injected server-trust policy.
///
/// Hikvision devices ship a self-signed leaf whose common name is the device serial, with no SAN
/// and a ten-year validity, so standard evaluation always fails and standard evaluation is
/// therefore not what Vigil does. The policy is trust-on-first-use pinned by SPKI SHA-256:
/// the first successful handshake records the pin on the camera record, and a later mismatch is a
/// security warning the user must accept explicitly — never an automatic acceptance.
public protocol ServerTrustEvaluating: Sendable {

    /// Called once per TLS handshake.
    ///
    /// - Parameters:
    ///   - host: the host as Vigil addressed it, unbracketed.
    ///   - port: the TCP port.
    ///   - chainDER: the certificate chain in DER form, **leaf first**. Empty when the platform
    ///     could not produce it, which a policy must treat as untrusted rather than as "no
    ///     objection".
    /// - Returns: `.trust` to proceed, `.reject(reason)` to fail the task.
    func evaluate(host: String, port: Int, chainDER: [Data]) -> ServerTrustDecision
}

// MARK: - Shipped conformances

/// Refuses every TLS handshake. The only conformance that ships in the pure layer.
///
/// Plain HTTP on the LAN is the supported default (`NSAllowsLocalNetworking`), and a pure-layer
/// build has no way to evaluate a certificate at all — pretending otherwise would mean trusting
/// any certificate on the network, which is worse than not connecting.
public struct RefusingTrustEvaluator: ServerTrustEvaluating {

    /// Creates the evaluator.
    public init() {}

    /// Always rejects, naming the platform limitation so the message is actionable.
    public func evaluate(host: String, port: Int, chainDER: [Data]) -> ServerTrustDecision {
        .reject("TLS certificate evaluation is unavailable in this build; use http:// on the LAN")
    }
}

/// Accepts every TLS handshake. **Tests only** — it is `package`, so no app target can reach it.
package struct AlwaysTrustEvaluator: ServerTrustEvaluating {

    /// Creates the evaluator.
    package init() {}

    /// Always trusts. Never used outside a test that has no certificate to evaluate.
    package func evaluate(host: String, port: Int, chainDER: [Data]) -> ServerTrustDecision {
        .trust
    }
}

// MARK: - Pinning helper

/// The trust-on-first-use rule, expressed once so `VigilCore`'s macOS policy and any test policy
/// agree on it.
public enum TOFUPinning {

    /// Compares a freshly computed SPKI SHA-256 against the pin stored on the camera record.
    ///
    /// - Parameters:
    ///   - observed: SHA-256 over the leaf certificate's `subjectPublicKeyInfo` DER.
    ///   - stored: the pin from the camera record, or `nil` on the first ever handshake.
    /// - Returns: `.trust` when there is no pin yet (the caller stores `observed`) or when the pin
    ///   matches; `.reject` when it changed. Hostname mismatch, expiry and a missing SAN are
    ///   deliberately **not** consulted: on a LAN device with a serial-number CN they are the
    ///   normal case, and treating them as failures would train the user to click through.
    public static func decide(observed: Data, stored: Data?) -> ServerTrustDecision {
        guard let stored else { return .trust }
        guard stored == observed else {
            return .reject("certificate changed since this camera was first trusted")
        }
        return .trust
    }
}
