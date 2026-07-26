//
//  Credential.swift
//  VigilProtocols
//
//  The one credential value type — a username and a password held in memory only — and the opaque
//  Keychain handle that is safe to persist in its place.
//  Implements docs/API_CONTRACT.md §3.13 (ruling R-14).
//
//  Written by impl:rtsp-a because `RTSPAuthenticator.init(credential:random:)` (API_CONTRACT §4.3)
//  cannot compile without it and the W1 file was still missing; the declarations are the contract's
//  verbatim shape, so the owner of §3.13 can adopt this file unchanged.
//

import Foundation

// MARK: - Credential

/// A username and a password, in memory only.
///
/// **Not `Codable`. Deliberately.** `Camera` has no password property to accidentally encode, and
/// this type has no encoder to accidentally reach for: the password lives in the Keychain and is
/// referenced everywhere else by `ref`. `ISAPICredential` does not exist (API_CONTRACT §2 R-14).
///
/// `description` and `debugDescription` both mask the secret, so a credential cannot reach a log
/// line through string interpolation, `dump`, or a `#expect` failure message.
public struct Credential: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {

    /// The handle that locates this password in the Keychain. Stable across host and account edits.
    public let ref: CredentialRef

    /// The device account name, e.g. `admin`. Not a secret, but never logged next to a realm.
    public let account: String

    /// The password. Never logged, never serialised, never placed in a URL that goes on the wire.
    public let secret: String

    /// Creates a credential. `ref` defaults to a fresh handle, which is what a newly typed
    /// password wants; pass an existing `ref` when re-reading one out of the Keychain.
    public init(ref: CredentialRef = .init(), account: String, secret: String) {
        self.ref = ref
        self.account = account
        self.secret = secret
    }

    /// Masked. The secret is replaced by a fixed marker whose length reveals nothing about it.
    public var description: String { "Credential(account: \(account), secret: ****)" }

    /// Identical to `description`: the debug spelling is the one that reaches crash logs.
    public var debugDescription: String { description }
}

// MARK: - CredentialRef

/// Opaque, stable handle to a Keychain item. This is what appears in `library.json`; it reveals
/// nothing, not even the username.
public struct CredentialRef: Hashable, Sendable, Codable, CustomStringConvertible {

    /// The identity of the Keychain item. Random at creation and never derived from device data.
    public let rawValue: UUID

    /// Wraps an existing identifier, or mints a new one.
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public var description: String { rawValue.uuidString }

    /// The `kSecAttrPath` value that locates the item independently of host, port and account, so a
    /// camera can move to a new address without orphaning its password.
    public var keychainPath: String { "/vigil/credential/\(rawValue.uuidString)" }
}
