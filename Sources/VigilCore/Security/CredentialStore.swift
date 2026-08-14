//
//  CredentialStore.swift
//  VigilCore
//
//  The Keychain actor: the only owner of a camera password in this process, and — with
//  Platform/Keychain.swift — the only user of `Security.framework`.
//  Implements docs/spec-core.md §6 and docs/API_CONTRACT.md §4.8 / §5.12
//  (`Security/CredentialStore.swift`).
//
//  Two invariants this file exists to enforce:
//  1. `errSecItemNotFound` from a read is a **normal outcome** and returns `nil`. Treating it as an
//     error is how "the password is never saved" ships with nothing in the log.
//  2. `Credential` is not `Codable` and never leaves here except in memory, so no encoder can put a
//     password in `library.json` (spec-core §6.1).
//

#if os(macOS)

import Foundation
import Security
import VigilProtocols

// MARK: - CredentialDescriptor

/// Everything needed to write a well-labelled Keychain item.
///
/// The label and comment are not decoration: this item is visible and deletable in Keychain
/// Access.app, and a user who finds an unexplained secret deletes it.
public struct CredentialDescriptor: Sendable, Hashable {

    /// The handle this item is filed under. Must equal the credential's own `ref`.
    public var ref: CredentialRef

    /// `kSecAttrServer`. Updated when the camera's address changes so the item stays truthful.
    public var host: String

    /// `kSecAttrPort`. The ISAPI port, because that is the service a human recognises.
    public var port: Int

    /// Selects `kSecAttrProtocolHTTPS` over `kSecAttrProtocolHTTP`.
    public var useTLS: Bool

    /// `kSecAttrAccount` — the device username, normally `admin`.
    public var account: String

    /// `kSecAttrLabel`, e.g. `"Vigil — Front Door (192.168.1.64)"`.
    public var label: String

    /// `kSecAttrComment`. Tells the user what breaks if they delete the item.
    public var comment: String

    /// The comment written on every item Vigil creates.
    public static let defaultComment =
        "Managed by Vigil. Deleting this item breaks the camera's saved password."

    /// Builds a descriptor.
    public init(ref: CredentialRef,
                host: String,
                port: Int,
                useTLS: Bool,
                account: String,
                label: String,
                comment: String = CredentialDescriptor.defaultComment) {
        self.ref = ref
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.account = account
        self.label = label
        self.comment = comment
    }

    /// The descriptor for a camera's credential, with the label the Keychain shows.
    ///
    /// `account` is passed separately because the record deliberately does not store a username:
    /// the username lives in the Keychain item, next to the password it belongs with.
    public init(camera: Camera, account: String) {
        self.init(ref: camera.credentialRef,
                  host: camera.host,
                  port: camera.httpPort,
                  useTLS: camera.useTLS,
                  account: account,
                  label: "Vigil — \(camera.displayName) (\(camera.host))")
    }
}

// MARK: - CredentialStore

/// Reads and writes camera passwords, and caches them in memory for as long as connections need
/// them.
///
/// Items are `kSecClassInternetPassword` keyed by `kSecAttrPath` = `/vigil/credential/<uuid>`
/// (spec-core §6.3), so two cameras on one host with one username never collide and a lookup
/// constrained by class plus path is exact.
public actor CredentialStore {

    // MARK: Stored properties

    private let keychain: any KeychainProtocol
    private let logger: any LoggerProtocol
    private let accessGroup: String?

    /// Read-through cache. A 16-camera reconnect after wake performs one Keychain read per camera,
    /// not one per RTSP round trip. Never written to disk, never in a diagnostics bundle.
    private var cache: [CredentialRef: Credential] = [:]

    // MARK: Initialisation

    /// Builds a store.
    ///
    /// - Parameters:
    ///   - keychain: the `SecItem` seam. `SystemKeychain()` in production.
    ///   - logger: structured log sink. Nothing logged here contains a secret.
    ///   - accessGroup: `kSecAttrAccessGroup`. `nil` for a normally signed app, which is what Vigil
    ///     ships; a value is only needed when items are shared with a helper.
    public init(keychain: any KeychainProtocol,
                logger: any LoggerProtocol = NullLogger(),
                accessGroup: String? = nil) {
        self.keychain = keychain
        self.logger = logger
        self.accessGroup = accessGroup
    }

    // MARK: Reads

    /// The credential for a handle, or `nil` when none is stored.
    ///
    /// `nil` is a normal answer — a camera whose password has not been entered yet — and callers
    /// must present it as "enter the password", never as a failure. Only a Keychain fault throws.
    ///
    /// - Throws: `CredentialError.keychainLocked` when the login keychain is locked,
    ///   `.userCancelledUnlock` when the user dismissed the prompt, `.missingEntitlement` on an
    ///   unsigned build, `.decodeFailed` when the stored item is not the shape Vigil wrote, and
    ///   `.keychainStatus` for anything else.
    public func credential(for ref: CredentialRef) throws -> Credential? {
        if let hit = cache[ref] { return hit }

        var query = baseQuery(ref)
        query[kSecReturnData as String] = NSNumber(value: true)
        query[kSecReturnAttributes as String] = NSNumber(value: true)
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = keychain.copyMatching(query, &item)
        switch status {
        case errSecSuccess:
            guard let attributes = item as? [String: Any],
                  let data = attributes[kSecValueData as String] as? Data,
                  let secret = String(data: data, encoding: .utf8),
                  let account = attributes[kSecAttrAccount as String] as? String else {
                logger.error(.core, "keychain item is not the shape Vigil wrote",
                             ["ref": "\(ref)"])
                throw CredentialError.decodeFailed
            }
            let credential = Credential(ref: ref, account: account, secret: secret)
            cache[ref] = credential
            return credential

        case errSecItemNotFound:
            // Normal: this camera has no saved password yet. Not an error, not a log line above
            // debug, and emphatically not a thrown failure (spec-core §6.4).
            logger.debug(.core, "no keychain item for credential", ["ref": "\(ref)"])
            return nil

        default:
            let error = CredentialError.from(status: status, operation: "read")
            logger.failure(.core, error)
            throw error
        }
    }

    /// The credential for a camera. The convenience every connect path uses.
    public func credential(for camera: Camera) throws -> Credential? {
        try credential(for: camera.credentialRef)
    }

    /// True when a password is stored for `ref`, without decrypting it.
    ///
    /// Uses `kSecReturnAttributes` alone, so it does not unlock the keychain to read the secret —
    /// which is what makes it safe to call while drawing a list of cameras.
    public func hasCredential(for ref: CredentialRef) throws -> Bool {
        if cache[ref] != nil { return true }
        var query = baseQuery(ref)
        query[kSecReturnAttributes as String] = NSNumber(value: true)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = keychain.copyMatching(query, &item)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw CredentialError.from(status: status, operation: "read")
        }
    }

    // MARK: Writes

    /// Creates or replaces the item for `descriptor.ref`.
    ///
    /// An existing item is updated in place rather than deleted and re-added, so its creation date
    /// and its creation date survives a password change.
    ///
    /// - Precondition: `credential.ref == descriptor.ref`. Filing a password under another
    ///   credential's handle is a programmer error that would silently orphan the original.
    public func save(_ credential: Credential, descriptor: CredentialDescriptor) throws {
        precondition(credential.ref == descriptor.ref,
                     "descriptor must describe the credential's own ref")

        let attributes = itemAttributes(credential, descriptor)
        var status = keychain.add(attributes)

        if status == errSecDuplicateItem {
            let deleteStatus = keychain.delete(baseQuery(descriptor.ref))
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                let error = CredentialError.from(status: deleteStatus, operation: "replace")
                logger.failure(.core, error)
                throw error
            }
            status = keychain.add(attributes)
        }
        guard status == errSecSuccess else {
            let error = CredentialError.from(status: status, operation: "save")
            logger.failure(.core, error)
            throw error
        }
        cache[descriptor.ref] = credential
        logger.info(.core, "credential saved", ["ref": "\(descriptor.ref)",
                                                "host": Redact.host(descriptor.host, salt: 0)])
    }

    /// Changes only the password, keeping the handle and the username.
    ///
    /// - Throws: `.notFound` when there is no item to update. Unlike a read, this is a real error:
    ///   the caller believed a credential existed.
    public func updateSecret(_ secret: String, for ref: CredentialRef) throws {
        let status = keychain.update(baseQuery(ref),
                                     [kSecValueData as String: Data(secret.utf8)])
        switch status {
        case errSecSuccess:
            if let previous = cache[ref] {
                cache[ref] = Credential(ref: ref, account: previous.account, secret: secret)
            } else {
                cache.removeValue(forKey: ref)
            }
            logger.info(.core, "credential secret updated", ["ref": "\(ref)"])
        case errSecItemNotFound:
            throw CredentialError.notFound
        default:
            let error = CredentialError.from(status: status, operation: "update")
            logger.failure(.core, error)
            throw error
        }
    }

    /// Follows a camera's host, port, TLS and username changes so Keychain Access stays truthful.
    ///
    /// A missing item is **not** an error: there is simply nothing to relabel, which is the normal
    /// state for a camera whose password has never been entered.
    public func updateAttributes(_ descriptor: CredentialDescriptor) throws {
        let update: [String: Any] = [
            kSecAttrServer as String: descriptor.host,
            kSecAttrPort as String: NSNumber(value: descriptor.port),
            kSecAttrProtocol as String: descriptor.useTLS
                ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP,
            kSecAttrAccount as String: descriptor.account,
            kSecAttrLabel as String: descriptor.label,
        ]
        let status = keychain.update(baseQuery(descriptor.ref), update)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else {
            let error = CredentialError.from(status: status, operation: "update")
            logger.failure(.core, error)
            throw error
        }
        if let previous = cache[descriptor.ref], previous.account != descriptor.account {
            cache.removeValue(forKey: descriptor.ref)
        }
    }

    /// Deletes the item. Deleting one that is already gone succeeds.
    public func delete(_ ref: CredentialRef) throws {
        let status = keychain.delete(baseQuery(ref))
        cache.removeValue(forKey: ref)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            let error = CredentialError.from(status: status, operation: "delete")
            logger.failure(.core, error)
            throw error
        }
    }

    // MARK: Maintenance

    /// Every Vigil-owned handle on this machine, for orphan cleanup. Never returns secrets.
    ///
    /// Items whose `kSecAttrPath` is not a Vigil path, or whose UUID does not parse, are skipped
    /// silently: another application's internet passwords are none of our business.
    public func enumerateRefs() throws -> [CredentialRef] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecReturnAttributes as String: NSNumber(value: true),
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseDataProtectionKeychain as String: NSNumber(value: true),
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }

        var item: CFTypeRef?
        let status = keychain.copyMatching(query, &item)
        switch status {
        case errSecSuccess:
            guard let rows = item as? [[String: Any]] else { return [] }
            let prefix = "/vigil/credential/"
            return rows.compactMap { row in
                guard let path = row[kSecAttrPath as String] as? String,
                      path.hasPrefix(prefix),
                      let uuid = UUID(uuidString: String(path.dropFirst(prefix.count))) else {
                    return nil
                }
                return CredentialRef(uuid)
            }
        case errSecItemNotFound:
            return []
        default:
            throw CredentialError.from(status: status, operation: "enumerate")
        }
    }

    /// Drops the in-memory cache. Called on screen lock, keychain lock and logout.
    public func purgeCache() {
        let count = cache.count
        cache.removeAll()
        logger.debug(.core, "credential cache purged", ["entries": String(count)])
    }

    /// Number of cached credentials. Diagnostics and tests only; never logged with the refs.
    public var cachedCount: Int { cache.count }

    // MARK: Query construction

    /// The query that locates exactly one item: class plus the UUID path, and nothing else.
    ///
    /// Host, port and account are deliberately **absent**. They change over a camera's life, and a
    /// lookup that included them would lose the password the moment the camera moved.
    private func baseQuery(_ ref: CredentialRef) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrPath as String: ref.keychainPath,
            kSecUseDataProtectionKeychain as String: NSNumber(value: true),
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    /// The full attribute set written on add, and (minus `kSecClass`) on update.
    ///
    /// `kSecAttrSynchronizable` is false because a LAN camera password must never reach iCloud
    /// Keychain, and `kSecAttrAccessible` is `WhenUnlocked` because Vigil has no work to do while
    /// the user is logged out (spec-core §6.3).
    private func itemAttributes(_ credential: Credential,
                                _ descriptor: CredentialDescriptor) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: descriptor.host,
            kSecAttrPort as String: NSNumber(value: descriptor.port),
            kSecAttrProtocol as String: descriptor.useTLS
                ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP,
            kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeHTTPDigest,
            kSecAttrAccount as String: descriptor.account,
            kSecAttrPath as String: descriptor.ref.keychainPath,
            kSecAttrLabel as String: descriptor.label,
            kSecAttrComment as String: descriptor.comment,
            kSecAttrDescription as String: "Vigil camera credential",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrSynchronizable as String: NSNumber(value: false),
            kSecValueData as String: Data(credential.secret.utf8),
            kSecUseDataProtectionKeychain as String: NSNumber(value: true),
        ]
        if let accessGroup { attributes[kSecAttrAccessGroup as String] = accessGroup }
        return attributes
    }
}

// MARK: - OSStatus mapping

public extension CredentialError {

    /// Maps a raw `OSStatus` onto the shared error vocabulary (docs/spec-core.md §6.6).
    ///
    /// `errSecItemNotFound` maps to `.notFound`, but a **read** must not call this: absence is a
    /// normal outcome there and is answered with `nil`.
    ///
    /// - Parameters:
    ///   - status: the status the Keychain returned, kept verbatim in `.keychainStatus` so the
    ///     numeric code reaches the log even when the case is unknown.
    ///   - operation: `save`, `read`, `update`, `delete` or `enumerate`, for the log line.
    static func from(status: OSStatus, operation: String) -> CredentialError {
        switch status {
        case errSecItemNotFound: .notFound
        case errSecDuplicateItem: .duplicate
        case errSecUserCanceled: .userCancelledUnlock
        case errSecInteractionNotAllowed: .keychainLocked
        case errSecMissingEntitlement: .missingEntitlement
        case errSecDecode: .decodeFailed
        default: .keychainStatus(Int32(status), operation: operation)
        }
    }
}

#endif
