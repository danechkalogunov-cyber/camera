//
//  VClipPlayerView.swift
//  VigilUI
//
//  Plays one recorded clip, with scrubbing. The archive half of LIBRARY ▸ Recordings.
//  macOS-only. See docs/UX.md (Recordings) and design/mockups/03-playback.html.
//

#if os(macOS)

import AVKit
import Foundation
import SwiftUI

// MARK: - VClipPlayerView

/// A recorded clip, playing.
///
/// **Why AVKit and not the live path.** `VideoTileView` exists to show a stream whose frames arrive
/// one at a time from the network; a file on disk is the opposite problem, and it needs seeking, a
/// scrubber and a play/pause the live path deliberately does not have. `AVPlayerView` is AVKit's own
/// control set, so scrubbing, skip, volume and full screen come from the system rather than being
/// re-implemented — and they behave the way every other Mac video surface behaves.
///
/// The player is rebuilt whenever the URL changes, because `AVPlayer.replaceCurrentItem` leaves the
/// old item's transport state behind: a clip opened after a paused one would arrive paused, which
/// reads as a broken row.
@MainActor
package struct VClipPlayerView: View {

    // MARK: - Stored Properties

    /// The clip being played.
    package let clip: VLibraryClip

    /// Closes the player and returns to the list.
    package let onClose: () -> Void

    @State private var player: AVPlayer?

    // MARK: - Initialisation

    /// Creates a player over one clip.
    ///
    /// - Parameters:
    ///   - clip: what to play. A clip with no `url` renders the unavailable state instead.
    ///   - onClose: dismisses the player.
    package init(clip: VLibraryClip, onClose: @escaping () -> Void = {}) {
        self.clip = clip
        self.onClose = onClose
    }

    // MARK: - View

    package var body: some View {
        VStack(spacing: 0) {
            header
            surface
        }
        .background(VTheme.Color.Layer.videoWell)
        .task(id: LoadKey(url: clip.url, isRecording: clip.isRecording)) { load() }
        .onDisappear { player?.pause() }
    }

    // MARK: - Private Helpers

    /// Name, time and a close button.
    private var header: some View {
        HStack(spacing: VTheme.Space.sm) {
            VStack(alignment: .leading, spacing: VTheme.Space.hair) {
                Text(verbatim: clip.camera.name)
                    .vType(VTheme.Typography.headline)
                    .foregroundStyle(VTheme.Color.Text.primary)
                Text(verbatim: clip.fileName)
                    .vType(VTheme.Typography.caption1)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: VTheme.Space.sm)
            VButton(symbol: VTheme.Symbol.close,
                    size: .sm,
                    accessibilityLabel: "Close player",
                    action: onClose)
        }
        .padding(.horizontal, VTheme.Space.lg)
        .padding(.vertical, VTheme.Space.sm)
        .background(VTheme.Color.Layer.surface)
    }

    /// The picture, or an explanation of why there is none.
    @ViewBuilder
    private var surface: some View {
        if let player {
            // `AVPlayerView`, not SwiftUI's `VideoPlayer`. The latter crashed on first use:
            //   getSuperclassMetadata + 828 → fatalError, inside _AVKit_SwiftUI
            // The Swift runtime could not build metadata for the representable `VideoPlayer` wraps.
            // `AVPlayerView` is the AppKit control underneath it, carries the same transport bar,
            // and instantiates as a plain NSView with no generic metadata to resolve.
            VClipPlayerSurface(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unavailable
        }
    }

    /// Shown when the clip has no file behind it, or is still being written.
    ///
    /// A clip still recording has no finished `moov` atom, so `AVPlayer` cannot open it — saying so
    /// is better than an empty black rectangle that looks like a decode failure.
    private var unavailable: some View {
        VStack(spacing: VTheme.Space.sm) {
            VTheme.Symbol.cinema.image()
                .vIcon(size: VTheme.Icon.lg)
                .foregroundStyle(VTheme.Color.Text.tertiary)
            Text(clip.isRecording ? "Still recording" : "This clip is not available",
                 bundle: .vigilUI)
                .vType(VTheme.Typography.body)
                .foregroundStyle(VTheme.Color.Text.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Builds a player for the current clip, or clears it.
    private func load() {
        guard let url = clip.url, !clip.isRecording else {
            player = nil
            return
        }
        let player = AVPlayer(url: url)
        // Muted by default: these clips are recorded from a camera whose audio Vigil does not
        // request, so any sound would be a surprise rather than content.
        player.isMuted = true
        self.player = player
        player.play()
    }

    private struct LoadKey: Hashable {
        let url: URL?
        let isRecording: Bool
    }
}

// MARK: - VClipPlayerSurface

/// `AVPlayerView` as a SwiftUI view.
///
/// Deliberately thin: the control brings its own scrubber, skip buttons, volume and full-screen
/// toggle, so there is nothing here to configure beyond handing it the player and letting it size
/// itself. `controlsStyle` is `.inline` because the surface sits inside a panel rather than filling a
/// window, and `.floating` would put a translucent bar over a picture only 360 pt tall.
@MainActor
private struct VClipPlayerSurface: NSViewRepresentable {

    /// The player to show.
    let player: AVPlayer

    /// Builds the view. `AVPlayerView()` takes no arguments; every property is set after.
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    /// Re-points the view when the clip changes.
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

#endif  // os(macOS)
