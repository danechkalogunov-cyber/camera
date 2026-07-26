//
//  Keychain.swift
//  VigilCore
//
//  The injected Keychain seam and its one real implementation. **This file and
//  Security/CredentialStore.swift are the only places in Vigil that touch `Security.framework`.**
//  Implements docs/spec-core.md §2 (`KeychainProtocol`) and docs/API_CONTRACT.md §4.8.
//
//  Declared here rather than in `Platform/CoreDependencies.swift` because the slice needs the
//  protocol and the full `CoreDependencies` struct (file system, disk space, power, occlusion,
//  notifications, pasteboard) has no consumers yet. When that file lands it must **use** this
//  declaration, not repeat it.
//

#if os(macOS)

import Foundation
import Security

// MARK: - KeychainProtocol

/// The four `SecItem` calls, behind a protocol so `CredentialStore` is testable without a Keychain.
///
/// Deliberately shaped like the C API rather than like a nice Swift store: the whole value of the
/// seam is that a test double can return the exact `OSStatus` the real Keychain would, including
/// `errSecItemNotFound` (a normal outcome), `errSecInteractionNotAllowed` (locked) and
/// `errSecMissingEntitlement` (unsigned development build).
///
/// Dictionaries are `[String: Any]` because `kSecValueData` is `Data`, `kSecAttrPort` is an
/// `NSNumber` and `kSecClass` is a `CFString`; no Swift type unifies them. Conformers are
/// `Sendable` and stateless, and every call is made from inside `CredentialStore`'s actor, so the
/// non-`Sendable` dictionaries never cross an isolation boundary.
public protocol KeychainProtocol: Sendable {

    /// `SecItemAdd`. Returns `errSecDuplicateItem` when an item with the same primary key exists.
    func add(_ attributes: [String: Any]) -> OSStatus

    /// `SecItemCopyMatching`. `errSecItemNotFound` means "no such item", which is a **normal**
    /// outcome and never an error at the call site.
    func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus

    /// `SecItemUpdate`. `attributesToUpdate` MUST NOT contain `kSecClass`; the Keychain answers
    /// `errSecParam` if it does.
    func update(_ query: [String: Any], _ attributesToUpdate: [String: Any]) -> OSStatus

    /// `SecItemDelete`. `errSecItemNotFound` means the item was already gone, which is success for
    /// every caller in this app.
    func delete(_ query: [String: Any]) -> OSStatus
}

// MARK: - SystemKeychain

/// The production implementation: a direct, unembellished bridge to `SecItem*`.
///
/// It adds no policy of its own — no retries, no logging, no status translation — because every one
/// of those decisions belongs to `CredentialStore`, where it can be tested.
///
/// The Objective-C declarations these four calls are checked against
/// (`/System/Library/Frameworks/Security.framework/Headers/SecItem.h`, macOS 14 SDK):
///
///     OSStatus SecItemAdd(CFDictionaryRef attributes, CFTypeRef * _Nullable result);
///     OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef * _Nullable result);
///     OSStatus SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
///     OSStatus SecItemDelete(CFDictionaryRef query);
///
/// which import into Swift as:
///
///     func SecItemAdd(_ attributes: CFDictionary,
///                     _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
///     func SecItemCopyMatching(_ query: CFDictionary,
///                              _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
///     func SecItemUpdate(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus
///     func SecItemDelete(_ query: CFDictionary) -> OSStatus
public struct SystemKeychain: KeychainProtocol {

    /// Builds the production Keychain adapter. Stateless.
    public init() {}

    /// Adds an item. `nil` is passed for the `result` pointer: mixing `kSecValueData` into an add
    /// with a return key answers `errSecParam` (spec-core §6.5).
    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Copies one matching item. The caller owns the returned `CFTypeRef`; ARC manages it because
    /// Swift imports the out-parameter as a retained `CFTypeRef?`.
    public func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, &result)
    }

    public func update(_ query: [String: Any], _ attributesToUpdate: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

#endif
