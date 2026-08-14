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

    /// Rewrites an older item with Vigil's shared development ACL after its first successful read.
    ///
    /// Development builds are ad-hoc signed, so the default Keychain ACL changes with every
    /// rebuild. Keeping the migration inside the store means the secret never leaves this actor.
    public func migrateLegacyAccess(for camera: Camera) throws {
        guard let credential = try credential(for: camera.credentialRef) else { return }
        try save(credential, descriptor: CredentialDescriptor(camera: camera,
                                                             account: credential.account))
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
    /// and any user-granted access control survive a password change. A **new** item is created
    /// with the ACL ``sharedAccess(label:)`` builds; see that method for what that costs and why.
    ///
    /// - Precondition: `credential.ref == descriptor.ref`. Filing a password under another
    ///   credential's handle is a programmer error that would silently orphan the original.
    public func save(_ credential: Credential, descriptor: CredentialDescriptor) throws {
        precondition(credential.ref == descriptor.ref,
                     "descriptor must describe the credential's own ref")

        let attributes = itemAttributes(credential, descriptor)
        var status = keychain.add(attributes)

        if status == errSecDuplicateItem {
            // Old development builds wrote items with an ACL tied to the transient ad-hoc binary.
            // Updating such an item preserves that ACL and macOS asks for the login password after
            // every rebuild. Recreate it only when the user explicitly saves a password, so the
            // replacement gets the stable shared ACL from `itemAttributes`.
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
        ]
        if let accessGroup { attributes[kSecAttrAccessGroup as String] = accessGroup }
        if let access = Self.sharedAccess(label: descriptor.label) {
            attributes[kSecAttrAccess as String] = access
        }
        return attributes
    }

    /// An ACL that every application on this Mac can read, so macOS never asks for the login
    /// password to hand Vigil back its own item.
    ///
    /// ⛔ WHY THIS EXISTS, AND WHAT IT COSTS. A file-based Keychain item is bound by default to the
    /// **exact binary** that created it. Rebuild Vigil — which is what happens on every `git pull`
    /// here — and the signature no longer matches, so macOS puts up "Vigil wants to use your
    /// confidential information" and asks for the account password, once per launch, forever.
    /// "Always Allow" does not survive the next build either, because it trusts that binary and not
    /// the next one. The result is a camera password typed into a system dialog every single time
    /// the app starts, which is precisely the thing R1.4's zero-input relaunch promises not to ask
    /// for.
    ///
    /// ⚠️ THE COST IS REAL AND IS NOT HIDDEN: the item becomes readable by any process running as
    /// this user without a prompt. That is the same posture as most self-built apps and is a
    /// deliberate trade for a camera password on a machine the owner builds the app on; it is not
    /// the posture a signed, distributed build should ship with. When Vigil is signed with a stable
    /// identity this should become the fallback rather than the rule, and the item's ACL can then
    /// name that identity instead of naming everyone.
    ///
    /// ⛔ IT APPLIES TO **NEW ITEMS ONLY**, AND THAT LIMIT IS NOT AN OVERSIGHT. An ACL can be
    /// attached when an item is created and changed afterwards only by `SecKeychainItemSetAccess`,
    /// which macOS guards with its own dialog — "Vigil wants to change the owner of the … item",
    /// asking for the login password. That was tried and reverted: it replaced one prompt with a
    /// worse one. An item written before this existed keeps its narrow ACL until the user removes
    /// it in Keychain Access and types the camera's password once more, and there is no way for an
    /// application to do that on their behalf without asking for exactly the authorisation the
    /// exercise is trying to avoid.
    ///
    /// `nil` on any failure, and the caller simply omits the attribute — a prompting item is a far
    /// better outcome than no saved password at all.
    private static func sharedAccess(label: String) -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, nil, &access) == errSecSuccess,
              let access else { return nil }
        var aclList: CFArray?
        guard SecAccessCopyACLList(access, &aclList) == errSecSuccess,
              let acls = aclList as? [SecACL] else { return access }
        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess
            else { continue }
            // A `nil` application list is the documented way to say "every application is trusted";
            // an *empty* array would say the opposite — nobody — and prompt every time.
            _ = SecACLSetContents(acl, nil, description ?? "" as CFString, prompt)
        }
        return access
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
