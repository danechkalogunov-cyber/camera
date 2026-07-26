//
//  SecretFingerprint.swift
//  VigilProtocols
//
//  The salted, truncated digest that lets `LockoutGovernor` tell "the user typed a new password"
//  from "the user typed the same password again", without ever storing or logging the password.
//  Implements docs/RULING-LOCKOUT.md §4 constraint 1 and §7 (closing gap 9).
//
//  Why the salt is the `CredentialRef` and not a per-process random value. §4 originally salted with
//  a process-random value, which cannot be reproduced after a relaunch: the failure count survived,
//  the comparison did not, and the first `clear` after every launch was therefore granted
//  unconditionally — handing back the exact bypass the fingerprint exists to close, once per launch,
//  and quitting an app is not a difficult thing to do while guessing a password.
//
//  The ref is already persisted (it is the Keychain handle) and is a per-device random UUID, so the
//  stored value is not a hash of the password alone: an attacker who reads the file gets a salted,
//  truncated digest they cannot match against a precomputed table, and they must already know which
//  device it belongs to. Anyone with read access to the app's container is past the boundary the
//  Keychain defends in any case.
//

import Foundation

// MARK: - SecretFingerprint

/// Derives the fingerprint the governor compares.
///
/// A free namespace rather than a method on `LockoutGovernor`, deliberately: the governor **stores
/// and compares, never derives** (§7 consequence 1). Keeping the derivation here means the three
/// call sites that know a `Credential` cannot each invent their own spelling of it, which is the
/// failure mode that made §4's original `account:` parameter clear nothing.
public enum SecretFingerprint {

    /// Bytes of the digest kept. Sixteen: enough that two distinct passwords for one device
    /// colliding is not a thing that happens, short enough that the stored value is not a complete
    /// SHA-256 preimage target.
    public static let byteCount = 16

    /// `SHA256(credentialRef.uuidString ‖ secret)`, truncated to `byteCount` bytes, lowercase hex.
    ///
    /// The two inputs are concatenated with a `:` separator so that no pair of (ref, secret) values
    /// can produce the same byte sequence as a different pair — a UUID string is fixed-width and
    /// contains no colon, but the separator makes that a property of this function rather than of
    /// `UUID`'s spelling.
    ///
    /// - Parameters:
    ///   - ref: the Keychain handle. Persisted, so the fingerprint is reproducible after a relaunch.
    ///   - secret: the password. Read, hashed and dropped; never returned, logged or stored.
    public static func of(ref: CredentialRef, secret: String) -> String {
        let digest = SHA256.digest("\(ref.rawValue.uuidString):\(secret)")
        return SHA256.hex(Array(digest.prefix(byteCount)))
    }

    /// The fingerprint of a credential's own secret, salted with its own ref.
    ///
    /// The spelling every call site should use: it cannot pair the wrong ref with the wrong secret.
    public static func of(_ credential: Credential) -> String {
        of(ref: credential.ref, secret: credential.secret)
    }
}
