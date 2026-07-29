//
//  EntitlementInspector.swift
//  VigilTransport
//
//  What this build is actually allowed to do on the local network, read from its own code
//  signature rather than assumed.
//  macOS-only. Feeds `VigilDiscovery.EntitlementStatus`; see docs/spec-discovery.md §9.3 and §9.5.
//
//  ⛔ NEVER BRANCH ON THE OS VERSION. `com.apple.developer.networking.multicast` is enforced on
//  macOS 15 and later and usually ignored on 14, an ad-hoc-signed local build behaves differently
//  from a notarised one, and a provisioning profile can grant the key without the sandbox honouring
//  it. Every one of those combinations is a *configuration*, not a version, so the only honest
//  answers come from the signature and from what a socket actually did (§9.3).
//
//  This is deliberately only half the answer. The signature says what was *asked for*; whether
//  multicast works is settled empirically by the coordinator, which sets
//  `multicastVerifiedWorking` from a real send and degrades to a unicast sweep when it fails.
//

#if os(macOS)

import Foundation
import Security

import VigilDiscovery

// MARK: - EntitlementInspector

/// Reads this process's own entitlements.
public enum EntitlementInspector {

    /// Whether `com.apple.developer.networking.multicast` is in our signature.
    ///
    /// - Returns: `false` for anything it cannot establish. A build whose signature cannot be read
    ///   is exactly the ad-hoc case where the entitlement would not be honoured anyway, and a
    ///   discovery run that skips multicast still finds cameras — one that assumes multicast works
    ///   and silently sends nothing does not.
    public static func multicastEntitlementPresent() -> Bool {
        entitlements()["com.apple.developer.networking.multicast"] as? Bool == true
    }

    /// What the local-network permission appears to be.
    ///
    /// ⚠️ macOS has no API that answers this. There is no `CBManager.authorization` for the local
    /// network, and asking would be the wrong shape anyway: the permission is granted per *use*,
    /// the first time a bind or a multicast send happens, and the user's answer arrives as a socket
    /// error rather than as a callback. So the honest starting value is `.unknown`, and
    /// `DiscoveryCoordinator` narrows it from `EPERM`/`EACCES` on a real probe (§9.4).
    ///
    /// This exists so the seam is named rather than silently absent — an inspector that returned a
    /// confident `.granted` here would make the run stop asking, which is the failure this whole
    /// file is written to avoid.
    public static func localNetworkPermission() -> LocalNetworkPermission { .unknown }

    /// The status a run starts from.
    public static func status() -> EntitlementStatus {
        EntitlementStatus(multicastEntitlementPresent: multicastEntitlementPresent(),
                          multicastVerifiedWorking: nil,
                          localNetworkPermission: localNetworkPermission())
    }

    // MARK: - Private

    /// Our own entitlements dictionary, empty when the signature cannot be read.
    ///
    /// Signatures this is written against:
    /// ```
    /// func SecCodeCopySelf(_ flags: SecCSFlags, _ self: UnsafeMutablePointer<SecCode?>) -> OSStatus
    /// func SecCodeCopyStaticCode(_ code: SecCode, _ flags: SecCSFlags,
    ///                            _ staticCode: UnsafeMutablePointer<SecStaticCode?>) -> OSStatus
    /// func SecCodeCopySigningInformation(_ code: SecStaticCode, _ flags: SecCSFlags,
    ///                                    _ information: UnsafeMutablePointer<CFDictionary?>) -> OSStatus
    /// ```
    private static func entitlements() -> [String: Any] {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return [:] }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return [:] }
        var information: CFDictionary?
        // `kSecCSSigningInformation` is the flag that includes the entitlements dictionary; without
        // it the call succeeds and the key is simply absent, which reads as "no entitlement" and is
        // the exact wrong answer for a build that has one.
        //
        // ⚠️ Spelled the long way on purpose. `SecCSFlags` is a `CF_OPTIONS` type and carries no
        // member for this constant — `.signingInformation` does not compile — because the
        // information flags live in a *separate*, unnamed `CF_ENUM(uint32_t)` in CSCommon.h. The
        // `UInt32(...)` conversion is there because an unnamed enum's import type is not something
        // to bet the build on; it is a no-op when the constant is already `UInt32`.
        let signingInformation = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, signingInformation,
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return [:] }
        let key = kSecCodeInfoEntitlementsDict as String
        return dictionary[key] as? [String: Any] ?? [:]
    }
}

#endif  // os(macOS)
