//
//  RecordingDestination.swift
//  VigilCore
//
//  Where clips and snapshots go, and the sandbox handshake that makes a user-chosen folder writable
//  across a relaunch.
//  Implements docs/spec-core.md §9.6 (pre-flight checks 1–4) and docs/FEATURES.md F-REC-01
//  acceptance 9 / F-CAP-01 acceptance 5.
//
//  **The rule this file exists for.** A sandboxed app can write to `~/Library/Containers/…/Movies`
//  without asking anyone, and to `~/Movies` only through a grant the user made in an open panel and
//  Vigil kept as a security-scoped bookmark (`com.apple.security.files.user-selected.read-write`).
//  When that grant is missing, stale, or refused, the *only* acceptable outcome is a named error with
//  a remedy the UI can put on a button. A swallowed denial is indistinguishable from a camera with
//  no video, and this project exists to refuse that failure mode.
//

#if os(macOS)

import Foundation
import VigilProtocols

// MARK: - RecordingDestinationKind

/// Which of the two default locations a destination falls back to.
public enum RecordingDestinationKind: String, Sendable, Hashable, Codable {

    /// Clips. `Movies/Vigil`.
    case clips

    /// Snapshots. `Pictures/Vigil`.
    case snapshots

    /// The `FileManager.SearchPathDirectory` for this kind.
    ///
    /// Signature: `enum FileManager.SearchPathDirectory` with `case moviesDirectory` and
    /// `case picturesDirectory`. In a sandbox both resolve **inside the container** unless the app
    /// holds a grant for the real one — which is exactly why they are the *fallback* and a
    /// user-selected bookmark is the preferred root.
    var searchPath: FileManager.SearchPathDirectory {
        switch self {
        case .clips: .moviesDirectory
        case .snapshots: .picturesDirectory
        }
    }
}

// MARK: - RecordingDestinationRequest

/// A request to resolve a destination directory.
public struct RecordingDestinationRequest: Sendable, Hashable {

    /// Which default location applies when there is no user-chosen root.
    public var kind: RecordingDestinationKind

    /// A security-scoped bookmark for a folder the user chose in an open panel, or `nil` to use the
    /// default location.
    ///
    /// Stored as bookmark data rather than as a `URL` on purpose: a plain path does not survive a
    /// relaunch in a sandbox — the grant does not attach to the path, it attaches to the bookmark.
    public var userSelectedBookmark: Data?

    /// Directory created inside the root, so Vigil never writes loose files into `~/Movies`.
    public var folderName: String

    /// Refuse to start below this much free space (spec-core §9.6 check 4). 2 GiB by default: enough
    /// for roughly twenty minutes of 1080p at 8 Mbps, so a recording that starts has room to be
    /// worth keeping.
    public var minimumFreeBytes: Int64

    /// Builds a request.
    public init(kind: RecordingDestinationKind,
                userSelectedBookmark: Data? = nil,
                folderName: String = "Vigil",
                minimumFreeBytes: Int64 = 2 << 30) {
        self.kind = kind
        self.userSelectedBookmark = userSelectedBookmark
        self.folderName = folderName
        self.minimumFreeBytes = minimumFreeBytes
    }
}

// MARK: - RecordingDestination

/// A resolved, writable destination directory, holding its sandbox access open for as long as it
/// lives.
///
/// A reference type with a `deinit` because security-scoped access is a **balanced** pair: every
/// successful `startAccessingSecurityScopedResource()` needs exactly one
/// `stopAccessingSecurityScopedResource()`, and leaking the open scope leaks a kernel resource that
/// the OS stops granting after a few hundred. Tying the stop to the object's lifetime is the only way
/// to get that right across the error paths.
///
/// `Sendable` without `@unchecked`: every stored property is a `let` of a `Sendable` type.
public final class RecordingDestination: Sendable {

    // MARK: - Stored Properties

    /// The directory files go in. Already created and verified writable.
    public let directory: URL

    /// Free bytes measured at resolution time. The recorder re-checks periodically; this is the
    /// number the pre-flight passed on.
    public let freeBytesAtResolution: Int64

    /// True when `directory` came from a user-selected bookmark and security-scoped access is open.
    public let isSecurityScoped: Bool

    /// True when the bookmark resolved but macOS reported it stale. Access still works for this
    /// launch; the app should re-create the bookmark and store it. Surfaced rather than hidden,
    /// because a stale bookmark that is never refreshed becomes a failure at the worst moment.
    public let bookmarkWasStale: Bool

    /// The scoped URL whose access must be released. Identical to `directory`'s ancestor grant, kept
    /// separately because access is released on the URL that was resolved, not on a child of it.
    private let scopedURL: URL?

    // MARK: - Initialisation

    init(directory: URL, freeBytesAtResolution: Int64, scopedURL: URL?, bookmarkWasStale: Bool) {
        self.directory = directory
        self.freeBytesAtResolution = freeBytesAtResolution
        self.scopedURL = scopedURL
        self.isSecurityScoped = scopedURL != nil
        self.bookmarkWasStale = bookmarkWasStale
    }

    deinit {
        // `func stopAccessingSecurityScopedResource()` — returns nothing and must be called exactly
        // once per successful start. Calling it on a URL that was never started is documented as
        // harmless, but it is guarded anyway so the pairing is visible.
        scopedURL?.stopAccessingSecurityScopedResource()
    }
}

// MARK: - RecordingDestinationResolver

/// Resolves a `RecordingDestinationRequest` into a `RecordingDestination`.
///
/// **Never call this from the main actor.** It creates directories and reads volume capacity, both of
/// which are synchronous file-system calls that can block for the length of a spun-down disk or an
/// unresponsive network mount. Every caller in this module is an actor.
public enum RecordingDestinationResolver {

    /// Resolves and verifies a destination.
    ///
    /// The order is the order of spec-core §9.6, and it matters: the security scope must be opened
    /// *before* writability is tested, or a folder the user did grant reads as unwritable.
    ///
    /// 1. Resolve the bookmark, if there is one, and open its security scope.
    /// 2. Append `folderName` and create the directory.
    /// 3. Verify it is a writable directory.
    /// 4. Verify free space against `minimumFreeBytes`.
    ///
    /// - Throws: `RecordingError.folderUnavailable` when a bookmark cannot be resolved or the default
    ///   location cannot be located — an unmounted volume, or a folder the user deleted;
    ///   `.destinationUnwritable(path:)` when the sandbox refuses, with the entitlement named in the
    ///   message so a support log says which grant is missing; `.spaceBelowReserve(freeBytes:)` when
    ///   the volume is too full to be worth starting on.
    public static func resolve(_ request: RecordingDestinationRequest,
                               fileSystem: any RecordingFileSystem)
        throws(RecordingError) -> RecordingDestination {

        var scopedURL: URL?
        var wasStale = false

        if let bookmark = request.userSelectedBookmark {
            let resolved = try resolveBookmark(bookmark)
            scopedURL = resolved.url
            wasStale = resolved.wasStale
        }

        // Taken over immediately, on the line after the scope was opened: everything below can throw,
        // and `OpenedScope.deinit` is what releases the grant on those paths.
        let opened = OpenedScope(url: scopedURL)

        let root: URL
        if let scopedURL {
            root = scopedURL
        } else {
            root = try defaultRoot(for: request.kind)
        }

        let directory = root.appendingPathComponent(request.folderName, isDirectory: true)

        try fileSystem.createDirectory(at: directory)

        guard fileSystem.directoryExists(at: directory) else {
            throw RecordingError.folderUnavailable
        }
        guard fileSystem.isWritableDirectory(at: directory) else {
            throw RecordingError.destinationUnwritable(
                path: "\(directory.path) — the sandbox refused write access. Vigil can only write "
                + "outside its container to a folder chosen in an open panel "
                + "(com.apple.security.files.user-selected.read-write).")
        }

        // `nil` means the volume would not answer — a rare but real answer from some network mounts.
        // Refusing to record because of it would make Vigil unusable on those volumes, so an
        // unknown capacity passes the reserve check and the recorder relies on the write itself
        // failing with `.diskFull` if it comes to that.
        let free = fileSystem.availableCapacity(at: directory) ?? Int64.max
        guard free >= request.minimumFreeBytes else {
            throw RecordingError.spaceBelowReserve(freeBytes: free)
        }

        return RecordingDestination(directory: directory,
                                    freeBytesAtResolution: free,
                                    scopedURL: opened.take(),
                                    bookmarkWasStale: wasStale)
    }

    // MARK: - Private Helpers

    /// Resolves a security-scoped bookmark and opens its scope.
    ///
    /// Signatures this is written against:
    /// ```
    /// init(resolvingBookmarkData bookmarkData: Data,
    ///      options: URL.BookmarkResolutionOptions = [],
    ///      relativeTo url: URL? = nil,
    ///      bookmarkDataIsStale: inout Bool) throws
    /// func startAccessingSecurityScopedResource() -> Bool
    /// ```
    /// `.withSecurityScope` is the option that makes the grant come back with the URL; without it the
    /// URL resolves and every write to it is refused, which is the single most common way to get this
    /// wrong and produces exactly the "no file, no error" outcome.
    private static func resolveBookmark(_ bookmark: Data)
        throws(RecordingError) -> (url: URL, wasStale: Bool) {
        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark,
                          options: [.withSecurityScope],
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        } catch {
            // The folder was deleted, renamed onto another volume, or the volume is not mounted.
            // `.folderUnavailable` carries no payload, so the numeric detail cannot be attached here;
            // its remedy — "Choose a different recordings folder" — is exactly the action the user
            // has to take, which is what makes the bare case adequate.
            throw RecordingError.folderUnavailable
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw RecordingError.destinationUnwritable(
                path: "\(url.path) — startAccessingSecurityScopedResource returned false. The "
                + "saved folder grant is no longer valid; choose the folder again.")
        }
        return (url, isStale)
    }

    /// The container-relative default root for a kind.
    ///
    /// Signature: `func url(for directory: FileManager.SearchPathDirectory,
    ///                      in domain: FileManager.SearchPathDomainMask,
    ///                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL`.
    ///
    /// `create: true` is deliberate: in a fresh container neither `Movies` nor `Pictures` exists, and
    /// the throwing form reports why rather than returning a path that cannot be written to.
    private static func defaultRoot(for kind: RecordingDestinationKind)
        throws(RecordingError) -> URL {
        do {
            return try FileManager.default.url(for: kind.searchPath,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        } catch {
            throw RecordingError.folderUnavailable
        }
    }
}

// MARK: - OpenedScope

/// Holds a started security scope until ownership passes to a `RecordingDestination`.
///
/// Without this, a `throw` between `startAccessingSecurityScopedResource()` and the destination's
/// construction leaks the grant — the pairing would depend on every error path remembering to close
/// it, which is precisely the kind of bookkeeping that is wrong six months later.
private final class OpenedScope {

    private var url: URL?

    init(url: URL?) {
        self.url = url
    }

    /// Passes ownership out. After this the scope is the caller's to release.
    func take() -> URL? {
        let taken = url
        url = nil
        return taken
    }

    deinit {
        url?.stopAccessingSecurityScopedResource()
    }
}

#endif
