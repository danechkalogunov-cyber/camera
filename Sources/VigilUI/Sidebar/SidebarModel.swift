//
//  SidebarModel.swift
//  VigilUI
//
//  The values the sidebar renders, and the one protocol it needs from the camera library. Pure data
//  with no SwiftUI in it, so the list's structure, search and ordering can all be tested directly.
//  macOS-only. Implements docs/UX.md §4.1 (sections), §4.2 (row anatomy) and §1.3 (selection model).
//

#if os(macOS)

import Foundation

import VigilProtocols

// MARK: - VSidebarStatus

/// A camera's connection state, with the payload the sidebar subtitle needs.
///
/// Deliberately **not** `VLiveDot.Status`: that type is the dot's five-way visual vocabulary and
/// carries no data, whereas the row's subtitle shows `connecting 62%`, `3.1% loss` and
/// `offline · retry 8 s` (the approved mockup shows all three at once). The mapping to the dot is
/// one switch in the view — see ``VSidebarStatus/dotStatus``.
package enum VSidebarStatus: Sendable, Hashable {

    /// Switched off by the user. Never connected; the row dims (UX.md §4.3, `Space` toggles it).
    case disabled

    /// Connecting, with a completion fraction when the transport can estimate one.
    case connecting(progress: Double?)

    /// A picture is arriving.
    case live

    /// A picture is arriving but impaired.
    case degraded(VSidebarImpairment)

    /// No picture, with whole seconds to the next attempt when a countdown is running.
    ///
    /// ⛔ The countdown is a **number**, never a spinner: "retry 8 s" answers the question a spinner
    /// refuses to (UX.md §12.6).
    case offline(retryInSeconds: Int?)

    /// Credentials were rejected. ⛔ Never retried automatically — that is how devices lock out
    /// (UX.md §12.7).
    case authFailed

    /// Whether the camera is showing a picture, impaired or not.
    package var isShowingVideo: Bool {
        switch self {
        case .live, .degraded: return true
        case .disabled, .connecting, .offline, .authFailed: return false
        }
    }

    /// Whether this camera counts towards the footer's "*n* live".
    package var countsAsLive: Bool {
        isShowingVideo
    }

    /// Whether this camera counts towards the footer's "*m* degraded".
    package var countsAsDegraded: Bool {
        if case .degraded = self { return true }
        return false
    }

    /// Sort rank for the "problems first" ordering the footer's popover uses: lower is worse.
    package var severity: Int {
        switch self {
        case .authFailed: return 0
        case .offline: return 1
        case .degraded: return 2
        case .connecting: return 3
        case .live: return 4
        case .disabled: return 5
        }
    }
}

// MARK: - VSidebarImpairment

/// Why a live camera is degraded, in the form the row's subtitle prints.
///
/// One case per trigger in UX.md §12.5, so the subtitle can name the actual problem — "3.1% loss"
/// rather than a generic "degraded", which is the difference between a row an operator can act on
/// and a row they have to click.
package enum VSidebarImpairment: Sendable, Hashable {

    /// Packet loss as a fraction, `0…1`. Trigger is > 1.5 % over a 3 s window.
    case packetLoss(fraction: Double)

    /// Jitter in milliseconds. Trigger is > 80 ms.
    case jitter(milliseconds: Double)

    /// Decode queue depth in frames. Trigger is > 8.
    case decodeQueue(frames: Int)

    /// Presented frame rate below 60 % of what was negotiated.
    case lowFrameRate(fps: Double)

    /// Preview rate reduced by the application-wide decoder budget.
    case decodeBudget

    /// The transport was moved to TCP to recover. Informational rather than a fault.
    case switchedToTCP
}

// MARK: - VSidebarCamera

/// One camera as the sidebar needs it.
///
/// A view model rather than `VigilCore.Camera`: the row shows negotiated stream facts (codec,
/// resolution, frame rate) that live on the stream and not on the stored record, and it must not
/// reach into a controller to get them while it is laying out.
package struct VSidebarCamera: Sendable, Hashable, Identifiable {

    // MARK: - Stored Properties

    /// Stable identity, which also selects the identity colour.
    package let id: CameraID

    /// The display name, and the primary search field.
    package var name: String

    /// Address, shown in the inspector and searched by prefix.
    package var host: String

    /// The user-created group this camera belongs to, if any. A camera belongs to 0…1 group
    /// (UX.md §1.1); groups do not nest.
    package var groupID: GroupID?

    /// The device this camera is a channel of, when it is one of several channels on an NVR.
    ///
    /// A string rather than a dedicated identifier type because `VigilProtocols` has no `DeviceID`
    /// — devices are identified by serial there — and inventing one in a shared module from this
    /// slice would be the wrong place for it. The value is the device's serial when it is known and
    /// its host otherwise; all the sidebar needs is that two channels of one NVR agree on it.
    ///
    /// `nil` for a standalone camera. When two or more cameras share a key, the sidebar gathers them
    /// under a device header — see ``VSidebarTree``.
    package var deviceKey: String?

    /// The device's display name, used as the device header's title.
    package var deviceName: String?

    /// The channel's number on its device, for the `CH3` suffix a device header's children show.
    package var channelNumber: Int?

    /// An explicitly persisted identity-colour index, or `nil` to derive one from ``id``.
    package var identityIndex: Int?

    /// Whether the user has switched this camera off. A disabled camera is never connected.
    package var isEnabled: Bool

    /// Connection state.
    package var status: VSidebarStatus

    /// Negotiated codec, e.g. `H.265`. `nil` until the stream is described.
    package var codec: String?

    /// Bucketed resolution, e.g. `1080p` (UX.md §4.2 buckets: ≤ 480p, 720p, 1080p, 1440p, 4K, else
    /// `{w}×{h}`).
    package var resolutionLabel: String?

    /// Presented frame rate. `nil` until a second of samples exists — the row shows nothing rather
    /// than a wrong number (UX.md §15.2 step 5).
    package var framesPerSecond: Double?

    /// Whether Vigil is recording this camera locally, which turns the row's rail red.
    package var isRecording: Bool

    /// Whether the stream in use is the sub-stream, marked with a superscript in the subtitle.
    package var isSubStream: Bool

    /// Model name, searched after the host.
    package var model: String?

    /// Serial number, matched only on an exact suffix of four characters or more.
    package var serial: String?

    /// When motion was last confirmed, for the "motion in the last 24 h" filter.
    package var lastMotionAt: Date?

    // MARK: - Initialisation

    /// Creates a row's worth of camera.
    ///
    /// Every field past the identity has a default, because a row has to be renderable from the
    /// moment the camera record exists — before any stream has been described. That is what the
    /// "nothing in the UI ever blocks on the network" rule requires (UX.md §0 hard rule 2).
    package init(id: CameraID,
                 name: String,
                 host: String = "",
                 groupID: GroupID? = nil,
                 deviceKey: String? = nil,
                 deviceName: String? = nil,
                 channelNumber: Int? = nil,
                 identityIndex: Int? = nil,
                 isEnabled: Bool = true,
                 status: VSidebarStatus = .connecting(progress: nil),
                 codec: String? = nil,
                 resolutionLabel: String? = nil,
                 framesPerSecond: Double? = nil,
                 isRecording: Bool = false,
                 isSubStream: Bool = false,
                 model: String? = nil,
                 serial: String? = nil,
                 lastMotionAt: Date? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.groupID = groupID
        self.deviceKey = deviceKey
        self.deviceName = deviceName
        self.channelNumber = channelNumber
        self.identityIndex = identityIndex
        self.isEnabled = isEnabled
        self.status = status
        self.codec = codec
        self.resolutionLabel = resolutionLabel
        self.framesPerSecond = framesPerSecond
        self.isRecording = isRecording
        self.isSubStream = isSubStream
        self.model = model
        self.serial = serial
        self.lastMotionAt = lastMotionAt
    }
}

// MARK: - VSidebarGroup

/// A user-created group of cameras. Flat — groups do not nest (UX.md §1.1).
package struct VSidebarGroup: Sendable, Hashable, Identifiable {

    /// Stable identity.
    package let id: GroupID

    /// The group's name, which is also searched.
    package var name: String

    /// An explicit identity-colour index for the group's tag glyph.
    package var identityIndex: Int?

    /// Creates a group.
    package init(id: GroupID, name: String, identityIndex: Int? = nil) {
        self.id = id
        self.name = name
        self.identityIndex = identityIndex
    }
}

// MARK: - VSidebarSelection

/// What the sidebar has selected, which is what the stage and the inspector follow.
///
/// Mirrors UX.md §1.3's `SidebarSelection` exactly, including the case names, so the later adapter
/// onto the app model is a rename and nothing more.
package enum VSidebarSelection: Sendable, Hashable {

    /// The "Current Layout" row: clears the camera selection and focuses the stage.
    case live

    /// A group row, which can be opened into the stage as a set.
    case group(GroupID)

    /// One camera.
    case camera(CameraID)

    /// The recordings feed, which replaces the stage's content.
    case recordings

    /// The events feed.
    case events

    /// The bookmarks list.
    case bookmarks

    /// The selected camera, if a camera is selected.
    package var selectedCamera: CameraID? {
        if case .camera(let id) = self { return id }
        return nil
    }
}

// MARK: - VCameraLibraryChange

/// What changed in the library.
///
/// Deliberately coarse. A fine-grained diff would let the sidebar animate an individual insertion,
/// but it would also let the sidebar and the library disagree about the order, which is the bug that
/// makes a drag-reorder snap back. The sidebar re-reads the whole ordered list on every change and
/// lets SwiftUI diff it by `id`.
package enum VCameraLibraryChange: Sendable, Hashable {

    /// The set or the order of cameras changed.
    case cameras

    /// The set of groups, or a group's membership, changed.
    case groups

    /// One camera's live status changed. Carried separately because it arrives at up to 1 Hz per
    /// camera and must not be mistaken for a structural change.
    case status(CameraID)
}

// MARK: - VCameraLibrarySource

/// The sidebar's whole requirement of the camera library.
///
/// ## Why this protocol is declared here
///
/// `VigilCore.CameraLibrary` — an actor with `add`/`remove`/`rename`/`reorder`/`enable` and an
/// `AsyncStream` of change events — is being written in parallel with this slice and did not exist
/// when these files were written. Rather than guess at its exact signatures and be wrong in a way
/// that has to be unpicked, the sidebar depends on the smallest surface it actually needs, declared
/// in its own directory. Wiring it up later is one adapter type in the app target that forwards each
/// method to the actor; nothing in `Sidebar/` has to change.
///
/// It is `@MainActor` because the sidebar reads it while laying out, and every method that mutates
/// the library is `nonisolated` and `async` because the real implementation is an actor. The
/// deliberate asymmetry — synchronous reads of a snapshot, asynchronous writes — is what keeps a
/// keystroke from awaiting an actor hop before the row can redraw.
@MainActor
package protocol VCameraLibrarySource: AnyObject {

    /// Every camera, in the order the sidebar shows them. Order is the library's, not the view's.
    var cameras: [VSidebarCamera] { get }

    /// Every group, in display order.
    var groups: [VSidebarGroup] { get }

    /// Renames a camera. An empty or whitespace-only name must be rejected by the implementation
    /// rather than stored (UX.md §4.3: an empty name reverts).
    nonisolated func renameCamera(_ id: CameraID, to name: String) async

    /// Removes a camera from the library, after the caller has confirmed.
    nonisolated func removeCamera(_ id: CameraID) async

    /// Moves cameras to a new position in the order.
    ///
    /// - Parameters:
    ///   - ids: the cameras being moved, in the order they should end up in.
    ///   - destination: the index in the **pre-move** array that the block should land before, which
    ///     is what SwiftUI's `onMove` and `DropDelegate` both report. ``VSidebarReorder`` converts
    ///     it to a post-removal index; see the note there about the off-by-one.
    nonisolated func moveCameras(_ ids: [CameraID], before destination: Int) async

    /// Puts a camera in a group, or removes it from every group when `group` is `nil`.
    nonisolated func setGroup(_ group: GroupID?, for id: CameraID) async

    /// Switches a camera on or off. A disabled camera is never connected.
    nonisolated func setEnabled(_ isEnabled: Bool, for id: CameraID) async

    /// Sets a camera's identity colour by index into ``VTheme/Color/Ident/all``.
    nonisolated func setIdentityIndex(_ index: Int?, for id: CameraID) async

    /// Creates a group containing `cameras`, and returns its identifier.
    nonisolated func createGroup(named name: String, cameras: [CameraID]) async -> GroupID

    /// A stream of change events. The sidebar re-reads ``cameras`` and ``groups`` on each one.
    nonisolated var changes: AsyncStream<VCameraLibraryChange> { get }
}

#endif  // os(macOS)
