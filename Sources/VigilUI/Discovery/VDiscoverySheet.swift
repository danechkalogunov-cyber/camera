//
//  VDiscoverySheet.swift
//  VigilUI
//
//  The sheet that shows what a network scan is finding, while it is still finding it.
//  macOS-only. Implements docs/UX.md §8.3 (find a camera) and docs/spec-discovery.md §10.4 (order).
//
//  ⛔ NO SOCKET REACHES THIS FILE. `VigilUI` does not depend on `VigilDiscovery`; the app target
//  runs the scan and hands down ``VDiscoveredCamera`` values, exactly as it hands down
//  `VSidebarCamera` and `VLibraryClip`. That is what keeps this sheet renderable in a preview with
//  no network, and what stops a view from being able to start one.
//
//  ⚠️ THE ROW ORDER IS THE CALLER'S. spec-discovery.md §10.4 fixes it — confidence descending, then
//  ISAPI-capable first, then address — precisely so a list does not reshuffle under the pointer as
//  evidence lands. Sorting here would fight the engine that already did it.
//

#if os(macOS)

import Foundation
import SwiftUI

// MARK: - VDiscoveredCamera

/// One device a scan has found, in the vocabulary a row prints.
package struct VDiscoveredCamera: Identifiable, Sendable, Hashable {

    /// A channel inventory summary supplied by an authenticated NVR probe. Discovery itself never
    /// guesses occupancy from SADP's capacity fields: "eight inputs" does not mean eight signals.
    package struct ChannelSummary: Sendable, Hashable {
        package let online: Int
        package let empty: Int

        package init(online: Int, empty: Int) {
            self.online = max(0, online)
            self.empty = max(0, empty)
        }
    }

    /// Stable for the whole run, so a row that gains a name does not become a new row.
    package let id: UUID

    /// What to call it: the device's own name, else its model, else its address.
    package let title: String

    /// The address a connection would be made to.
    package let address: String

    /// Model and firmware, when the device said. Empty renders as nothing rather than a dash: a
    /// scan answer is partial by nature and an em dash per missing field is noise.
    package let detail: String

    /// `0…100`. Below 30 the engine calls it a *possible* device, and so does this sheet.
    package let confidence: Int

    /// Whether Vigil could talk ISAPI to it — the difference between "a camera" and "something on
    /// the network with an open port".
    package let supportsISAPI: Bool

    /// True when this address is already in the library, so the row can say so instead of offering
    /// to add a duplicate.
    package let isAlreadyAdded: Bool

    /// Factory-fresh SADP devices cannot be added until the user sets their first password.
    package let needsActivation: Bool

    /// Present only after channel enumeration produced real online/empty states.
    package let channelSummary: ChannelSummary?

    /// Creates a row.
    package init(id: UUID, title: String, address: String, detail: String = "",
                 confidence: Int, supportsISAPI: Bool, isAlreadyAdded: Bool = false) {
        self.id = id
        self.title = title
        self.address = address
        self.detail = detail
        self.confidence = confidence
        self.supportsISAPI = supportsISAPI
        self.isAlreadyAdded = isAlreadyAdded
        self.needsActivation = false
        self.channelSummary = nil
    }

    package init(id: UUID, title: String, address: String, detail: String = "",
                 confidence: Int, supportsISAPI: Bool, isAlreadyAdded: Bool = false,
                 needsActivation: Bool, channelSummary: ChannelSummary? = nil) {
        self.id = id
        self.title = title
        self.address = address
        self.detail = detail
        self.confidence = confidence
        self.supportsISAPI = supportsISAPI
        self.isAlreadyAdded = isAlreadyAdded
        self.needsActivation = needsActivation
        self.channelSummary = channelSummary
    }

    /// Confident enough to present as a device rather than a possibility (spec-discovery.md §7.6).
    package var isConfident: Bool { confidence >= 30 }
}

// MARK: - VDiscoverySheet

/// Lists what the scan has found so far.
///
/// **Results appear during the run, not after it.** A scan takes seconds and a camera that answered
/// in the first 200 ms should be selectable then — waiting for the sweep to end would make the fast
/// path feel as slow as the slow one.
@MainActor
package struct VDiscoverySheet: View {

    // MARK: - Stored Properties

    /// Everything found so far, already in the engine's order.
    package let cameras: [VDiscoveredCamera]

    /// `0…1`, or `nil` before the plan exists.
    package let progress: Double?

    /// What the run is doing, in a few words.
    package let phase: String

    /// True while the run is still going.
    package let isScanning: Bool

    /// A sentence about a degraded run — no multicast entitlement, a refused permission — or `nil`
    /// when there is nothing to say. Never a code.
    package let notice: String?

    /// The user picked a device.
    package let onChoose: (VDiscoveredCamera) -> Void

    /// Opens the existing credential/setup flow for a factory-fresh device.
    package let onActivate: (VDiscoveredCamera) -> Void

    /// Stop a running scan, or start another when it has finished.
    package let onToggleScan: () -> Void

    /// Dismiss.
    package let onClose: () -> Void

    // MARK: - Initialisation

    /// Creates the sheet.
    package init(cameras: [VDiscoveredCamera],
                 progress: Double?,
                 phase: String,
                 isScanning: Bool,
                 notice: String? = nil,
                 onChoose: @escaping (VDiscoveredCamera) -> Void,
                 onActivate: @escaping (VDiscoveredCamera) -> Void,
                 onToggleScan: @escaping () -> Void,
                 onClose: @escaping () -> Void) {
        self.cameras = cameras
        self.progress = progress
        self.phase = phase
        self.isScanning = isScanning
        self.notice = notice
        self.onChoose = onChoose
        self.onActivate = onActivate
        self.onToggleScan = onToggleScan
        self.onClose = onClose
    }

    // MARK: - View

    package var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(VTheme.Color.Stroke.subtle)
            body(for: cameras)
            Divider().overlay(VTheme.Color.Stroke.subtle)
            footer
        }
        .frame(width: 520, height: 460)
        .background(VTheme.Color.Layer.canvas)
    }

    // MARK: - Private Helpers

    private var header: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.xs) {
            Text("Cameras on This Network", bundle: .vigilUI)
                .vType(VTheme.Typography.title3)
                .foregroundStyle(VTheme.Color.Text.primary)
            Text(verbatim: phase)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(VTheme.Color.Text.secondary)
            if let progress, isScanning {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .padding(.top, VTheme.Space.xxs)
            }
            if let notice {
                Text(verbatim: notice)
                    .vType(VTheme.Typography.caption1)
                    .foregroundStyle(VTheme.Color.Semantic.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, VTheme.Space.xxs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VTheme.Space.lg)
    }

    /// What the empty state says, which differs during a scan and after one.
    ///
    /// ⚠️ Two whole literals, never one assembled with `+`. A `LocalizedStringKey` is looked up
    /// entire, so a key built from two halves matches nothing in any `.strings` file and renders as
    /// raw English at runtime — in the one place the user is already confused.
    ///
    /// It names the next action *during* the scan too: "nothing yet" and "nothing at all" look
    /// identical for the first second, and nobody should have to guess which they are in
    /// (UX.md §14.1 rule 1).
    private var emptyMessage: LocalizedStringKey {
        isScanning
            ? "Cameras appear here as they answer."
            : "Some cameras do not announce themselves — type the address instead."
    }

    /// The list, or the one thing worth saying when it is empty.
    @ViewBuilder
    private func body(for cameras: [VDiscoveredCamera]) -> some View {
        if cameras.isEmpty {
            VLibraryEmptyState(symbol: VTheme.Symbol.discover,
                               title: isScanning ? "Looking…" : "No cameras answered.",
                               message: emptyMessage,
                               actionTitle: nil) {}
                .frame(maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(cameras) { camera in
                        row(camera)
                        Divider().overlay(VTheme.Color.Stroke.subtle)
                            .padding(.leading, VTheme.Space.lg)
                    }
                }
            }
        }
    }

    private func row(_ camera: VDiscoveredCamera) -> some View {
        HStack(spacing: VTheme.Space.sm) {
            Button { onChoose(camera) } label: {
            HStack(spacing: VTheme.Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: VTheme.Space.xs) {
                        Text(verbatim: camera.title)
                            .vType(VTheme.Typography.body)
                            .foregroundStyle(VTheme.Color.Text.primary)
                            .lineLimit(1)
                        if !camera.isConfident {
                            // Said in words, not by dimming the row: a low-confidence answer is
                            // still worth trying, and greying it would read as unavailable.
                            Text("possible", bundle: .vigilUI)
                                .vType(VTheme.Typography.caption2)
                                .foregroundStyle(VTheme.Color.Text.tertiary)
                        }
                    }
                    Text(verbatim: [camera.address, camera.detail]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .vType(VTheme.Typography.caption1)
                        .foregroundStyle(VTheme.Color.Text.secondary)
                        .lineLimit(1)
                    if let summary = camera.channelSummary {
                        Text(verbatim: channelSummary(summary))
                            .vType(VTheme.Typography.caption1)
                            .foregroundStyle(VTheme.Color.Text.secondary)
                    }
                    if camera.needsActivation {
                        Text("Not activated — set a password before use", bundle: .vigilUI)
                            .vType(VTheme.Typography.caption1)
                            .foregroundStyle(VTheme.Color.Semantic.warn)
                    }
                }
                Spacer(minLength: VTheme.Space.sm)
                if camera.isAlreadyAdded && !camera.needsActivation {
                    Text("Added", bundle: .vigilUI)
                        .vType(VTheme.Typography.caption1)
                        .foregroundStyle(VTheme.Color.Text.tertiary)
                } else if !camera.supportsISAPI {
                    // Not a refusal — Vigil will still try RTSP — but the user deserves to know
                    // before typing a password that this one did not answer as a Hikvision camera.
                    Text("not ISAPI", bundle: .vigilUI)
                        .vType(VTheme.Typography.caption2)
                        .foregroundStyle(VTheme.Color.Text.tertiary)
                }
            }
            .padding(.horizontal, VTheme.Space.lg)
            .padding(.vertical, VTheme.Space.sm)
            .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(camera.isAlreadyAdded || camera.needsActivation)
            .accessibilityLabel(Text(verbatim: "\(camera.title), \(camera.address)"))

            if camera.needsActivation {
                VButton("Activate", style: .secondary) { onActivate(camera) }
                    .padding(.trailing, VTheme.Space.lg)
            }
        }
    }

    private func channelSummary(_ summary: VDiscoveredCamera.ChannelSummary) -> String {
        let format = vigilUIString("NVR · %lld channels online, %lld empty")
        return String.localizedStringWithFormat(format, Int64(summary.online), Int64(summary.empty))
    }

    private var footer: some View {
        HStack(spacing: VTheme.Space.sm) {
            VButton(isScanning ? "Stop" : "Scan Again", style: .secondary, action: onToggleScan)
            Spacer(minLength: 0)
            VButton("Close", style: .secondary, action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(VTheme.Space.lg)
    }
}

#endif  // os(macOS)
