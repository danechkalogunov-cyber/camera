//
//  FrameStreamHandle.swift
//  VigilRender
//
//  The attach point that lets a frame producer deliver into whichever view SwiftUI happens to
//  create, without `VigilRender` importing `VigilCore`.
//  Implements docs/API_CONTRACT.md §4.10, slice subset.
//

#if os(macOS)

import Foundation

/// A stable handle for one camera's video destination.
///
/// SwiftUI creates and destroys `VideoTileView`s as the layout changes; the object that produces
/// frames must not care. It holds a `FrameStreamHandle`, hands the same handle to every `VideoTile`
/// it places, and reads `sink` whenever it has a sample to deliver.
///
/// The handle holds the view **weakly**. A view that SwiftUI has discarded must be able to
/// deallocate even if the producer still has the handle, and delivering into a discarded view must
/// be a no-op rather than a leak.
///
/// ## Isolation
///
/// This type is `@MainActor`, not `@unchecked Sendable`.
///
/// docs/API_CONTRACT.md §4.10 declares it `public final class FrameStreamHandle: @unchecked
/// Sendable`, but §2 R-52 of the same document fixes the repo-wide census of `@unchecked Sendable`
/// types at exactly three and this is not one of them; R-52 is explicit that the list is complete.
/// Main-actor isolation resolves the contradiction without a fourth escape hatch, and it is also
/// simply true: attach and detach happen from `makeNSView`/`dismantleNSView`, which are main-actor
/// entry points, and the view being handed around is an `NSView`.
///
/// The cost is that a producer living on an actor must hop to the main actor once, at setup, to
/// read `sink`. It does **not** need to hop per frame: `VideoTileView`'s ingest entry point is
/// `nonisolated`, so the producer caches the sink once and calls it directly from its own thread.
///
/// This deviation is reported to the supervisor rather than resolved silently.
@MainActor
public final class FrameStreamHandle {

    // MARK: - Stored properties

    /// The view currently on screen for this stream, or `nil` when SwiftUI has not created one (or
    /// has already discarded it). Cache it once and call its `nonisolated` ingest entry point
    /// directly; do not re-read it per frame.
    public private(set) weak var sink: VideoTileView?

    /// Called when a view attaches or detaches, so a producer can start or stop delivering without
    /// polling. The argument is the new value of `sink`.
    public var onSinkChange: ((VideoTileView?) -> Void)?

    // MARK: - Lifecycle

    /// Creates an unattached handle.
    public init() {}

    // MARK: - Public API

    /// Registers the view that should receive this stream's frames.
    ///
    /// Attaching a second view replaces the first; the previous view simply stops receiving. It is
    /// not an error — SwiftUI legitimately rebuilds a view before tearing the old one down.
    public func attach(_ view: VideoTileView) {
        sink = view
        view.frameSource = self
        onSinkChange?(view)
    }

    /// Unregisters the current view.
    ///
    /// Safe to call when nothing is attached. Calling it does **not** flush or blank the layer: the
    /// last displayed picture is the correct thing to leave on screen (docs/API_CONTRACT.md §4.9).
    public func detach() {
        sink = nil
        onSinkChange?(nil)
    }
}

#endif
