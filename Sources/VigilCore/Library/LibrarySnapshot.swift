//
//  LibrarySnapshot.swift
//  VigilCore
//
//  What the library is at an instant, what changed, and why a mutation was refused.
//  macOS-only. Split from CameraLibrary.swift, which docs/API_CONTRACT.md §7.2 caps at 600
//  lines.
//

#if os(macOS)

import Foundation
import VigilISAPI
import VigilProtocols

// MARK: - LibrarySnapshot

/// An immutable view of the library, taken at one revision.
///
/// Handed to the UI instead of a live reference: SwiftUI wants a value it can diff, and a value
/// cannot change under a view body halfway through drawing.
public struct LibrarySnapshot: Sendable, Hashable {

    /// Every camera, in the user's display order.
    public var cameras: [Camera]

    /// The channel inventory learned per camera, in camera order.
    public var channelInventories: [CameraChannelInventory]

    /// Increments on every committed mutation. Cheap way for a view to know it is looking at stale
    /// state, and the assertion handle for tests.
    public var revision: Int

    /// True when the document came from a newer Vigil. The UI must disable every editing
    /// affordance; every mutation on the library throws while it holds.
    public var isReadOnly: Bool

    /// When the document was last **persisted**, not when it was last changed in memory: a snapshot
    /// taken between a mutation and its debounced write still carries the previous write's stamp.
    public var updatedAt: Date

    /// Builds a snapshot.
    public init(cameras: [Camera],
                channelInventories: [CameraChannelInventory],
                revision: Int,
                isReadOnly: Bool,
                updatedAt: Date) {
        self.cameras = cameras
        self.channelInventories = channelInventories
        self.revision = revision
        self.isReadOnly = isReadOnly
        self.updatedAt = updatedAt
    }

    /// The camera with this identity, or `nil`.
    public func camera(_ id: CameraID) -> Camera? {
        cameras.first { $0.id == id }
    }

    /// The cameras the app may auto-connect, in display order.
    public var enabledCameras: [Camera] {
        cameras.filter(\.isEnabled)
    }

    /// The stored channel inventory for a camera, or `nil`.
    public func channelInventory(_ id: CameraID) -> CameraChannelInventory? {
        channelInventories.first { $0.cameraID == id }
    }
}

// MARK: - LibraryChange

/// What changed, and the library as it now stands.
public struct LibraryChange: Sendable, Hashable {

    /// Which mutation produced this event. Drives animation; never required for correctness, because
    /// ``snapshot`` is always complete.
    public var kind: LibraryChangeKind

    /// The library **after** the change.
    public var snapshot: LibrarySnapshot

    /// Builds a change event.
    public init(kind: LibraryChangeKind, snapshot: LibrarySnapshot) {
        self.kind = kind
        self.snapshot = snapshot
    }
}

/// The kinds of change a `CameraLibrary` reports.
public enum LibraryChangeKind: Sendable, Hashable {

    /// The first element every new subscriber receives: the state as it was when it subscribed.
    ///
    /// This is what makes `changes()` safe to call at any time. A subscriber can never miss a
    /// mutation that happened before it arrived, so no consumer needs a separate "read the current
    /// value first" step that could interleave with a write.
    case subscribed

    /// `load()` replaced the whole collection. Carries the recovery source when the corruption
    /// ladder ran, so the UI can raise the modal-once alert docs/spec-core.md §5.9 requires.
    case loaded(LibraryRecoverySource?)

    /// A camera was added.
    case added(CameraID)

    /// A camera was removed. Its credential and its recordings are **not** touched.
    case removed(CameraID)

    /// A camera's own fields changed: a rename, an enable, a learned capability, a `lastSeenAt`.
    case updated(CameraID)

    /// Display order changed. No camera was added or removed.
    case reordered

    /// A camera's channel inventory was replaced.
    case inventoryUpdated(CameraID)

    /// The prototype's `UserDefaults` connection was folded in as a library entry.
    case importedLegacyConnection(CameraID)
}

// MARK: - LibraryMutationError

/// Why a mutation was refused.
///
/// Deliberately not a `VigilFailure`: these are caller mistakes and UI-level conditions, not device
/// or disk failures with a diagnostic code. Storage failures keep their own vocabulary
/// (`StorageError`) and surface through ``CameraLibrary/lastSaveError``.
public enum LibraryMutationError: Error, Sendable, Hashable, CustomStringConvertible {

    /// The document was written by a newer Vigil, so nothing may be written back.
    case readOnly(schemaVersion: Int)

    /// No camera with that identity is in the library.
    case unknownCamera(CameraID)

    /// A camera with that identity is already in the library. Adding it again would produce two
    /// records the user cannot tell apart; use a mutation instead.
    case duplicateCameraID(CameraID)

    /// The record cannot address a device. Carries the field-level reason.
    case invalidCamera(CameraValidationError)

    public var description: String {
        switch self {
        case let .readOnly(version):
            "library is read-only (schema \(version) is newer than this build)"
        case let .unknownCamera(id):
            "no camera \(id.short) in the library"
        case let .duplicateCameraID(id):
            "camera \(id.short) is already in the library"
        case let .invalidCamera(reason):
            "invalid camera: \(reason)"
        }
    }
}

#endif  // os(macOS)
