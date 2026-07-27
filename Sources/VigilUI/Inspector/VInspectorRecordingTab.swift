//
//  VInspectorRecordingTab.swift
//  VigilUI
//
//  The Recording tab: local recording and its elapsed time, today's clip count, where the files go,
//  and a read-only mirror of the device's own storage.
//  macOS-only. Implements as much of docs/UX.md §6.6 as this package has types for, plus
//  docs/DESIGN.md §4.4 and §7.5 (the breathing live dot).
//
//  ⚠️ THIS IS THE THINNEST TAB, AND DELIBERATELY SO. UX.md §6.6 specifies six sections: local
//  recording, auto-record with its four buffers, a 7 × 24 schedule grid with three brushes, the
//  destination and filename template, a retention policy, and the device-storage mirror. Of those,
//  exactly two are backed by a type anywhere in this package — the device storage, which is
//  `VigilISAPI`'s `StorageInfo`, and whatever ``VInspectorRecordingState`` carries, which is the
//  four facts the app demonstrably already has.
//
//  The schedule grid, the buffers, the retention policy and the filename template have no value
//  type, no service protocol and no persistence anywhere in the package. Rendering controls for
//  them would mean inventing four models inside a view file, and a control that cannot write is
//  worse than an absent one — it teaches the user that the app lies. They are absent. Reported.
//

#if os(macOS)

import SwiftUI

import VigilISAPI

// MARK: - VInspectorRecordingTab

/// UX.md §6.6, as far as the types reach.
@MainActor
package struct VInspectorRecordingTab: View {

    /// The panel's snapshot.
    package let state: VInspectorState

    /// The panel's handlers.
    package let actions: VInspectorActions

    @Environment(\.vPulsePhase) private var pulsePhase

    /// Creates the tab.
    package init(state: VInspectorState, actions: VInspectorActions) {
        self.state = state
        self.actions = actions
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            localSection
            deviceStorageSection
        }
    }

    // MARK: - Local recording

    @ViewBuilder
    private var localSection: some View {
        VInspectorSectionHeader("Local recording")
        recordButton
        VInspectorRow("Elapsed") { elapsedValue }
        VInspectorRow("Clips today") {
            VInspectorMonoValue(VInspectorFormat.count(state.recording.clipsToday), isLive: true)
        }
        VInspectorRow("Destination") { VInspectorMonoValue(state.recording.destination) }
        // `.group` is the theme's `folder` glyph; DESIGN.md §8.3 has no dedicated
        // "reveal in Finder" case and a folder is what the Finder's own menu item shows.
        VButton("Reveal in Finder", symbol: .group, style: .ghost, size: .sm,
                action: actions.onRevealRecordings)
            .disabled(state.recording.destination == nil)
            .padding(.top, VTheme.Space.xxs)
    }

    /// Start or stop, with the `live` dot breathing off the window-wide clock while it runs.
    ///
    /// ⛔ The dot reads `\.vPulsePhase` and owns no animator of its own: unison across every pulsing
    /// indicator in the window is what separates a cockpit from a Christmas tree, and the budget
    /// allows four animation drivers window-wide (§7.5, §7.9).
    private var recordButton: some View {
        HStack(spacing: VTheme.Space.sm) {
            if state.recording.isRecording {
                VButton("Stop Recording", symbol: .stop, style: .destructive, size: .sm,
                        action: actions.onToggleRecording)
                VLiveDot(.live)
            } else {
                VButton("Start Recording", symbol: .record, style: .primary, size: .sm,
                        action: actions.onToggleRecording)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, VTheme.Space.xs)
    }

    /// The running clip's length, or an em dash when nothing is recording.
    ///
    /// `monoLarge.numeric` at the timecode's reserved width, so a clip crossing from `9:59` to
    /// `10:00` does not shove the row (§4.4).
    private var elapsedValue: some View {
        let text = state.recording.isRecording
            ? VInspectorFormat.duration(seconds: state.recording.elapsedSeconds)
            : VInspectorFormat.placeholder
        return Text(verbatim: text)
            .vType(VTheme.Typography.monoLarge.numeric)
            .foregroundStyle(state.recording.isRecording
                                ? VTheme.Color.Text.primary
                                : VTheme.Color.Text.tertiary)
            .vReserved(VTheme.Typography.Reserved.timecode)
            .opacity(dotOpacity)
    }

    /// The elapsed readout dims very slightly in time with the dot, so the two read as one signal
    /// rather than as an animation next to a number.
    private var dotOpacity: Double {
        guard state.recording.isRecording else { return 1 }
        return pulsePhase ? 0.85 : 1
    }

    // MARK: - Device storage

    /// A read-only mirror of Info ▸ Storage, which is what UX.md §6.6's last row asks for.
    @ViewBuilder
    private var deviceStorageSection: some View {
        VInspectorSectionHeader("Device storage")
        if let capacity = state.storageCapacityMB, let used = state.storageUsedFraction {
            VInspectorRow("In use") {
                let value = VInspectorFormat.percent(fraction: used)
                let expected = VInspectorFormat.capacity(megabytes: capacity)
                Text("\(value) of \(expected)", bundle: .vigilUI)
                    .vType(VTheme.Typography.mono.numeric)
                    .foregroundStyle(used >= 0.95
                                        ? VTheme.Color.Semantic.danger
                                        : VTheme.Color.Text.primary)
                    .lineLimit(1)
            }
            VInspectorMeter(fraction: used, tint: used >= 0.95 ? .danger : .neutral)
                .padding(.top, VTheme.Space.xxs)
            if let storage = state.storage {
                ForEach(storage.volumes) { volume in
                    volumeRow(volume)
                }
            }
        } else {
            VInspectorRow("In use") { VInspectorMonoValue(nil) }
        }
    }

    /// One volume's name and health. A sleeping or idle disk is healthy; unformatted, erroring,
    /// mismatched or absent is not — `StorageInfo.needsAttention` is where that list is written.
    private func volumeRow(_ volume: StorageVolume) -> some View {
        HStack(spacing: VTheme.Space.sm) {
            VTheme.Symbol.storage.image()
                .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
                .foregroundStyle(VTheme.Color.Text.tertiary)
            Text(verbatim: volume.name ?? String(volume.id))
                .vType(VTheme.Typography.callout)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .lineLimit(1)
            Spacer(minLength: VTheme.Space.xs)
            Text(verbatim: VInspectorFormat.capacity(megabytes: volume.capacityMB))
                .vType(VTheme.Typography.mono.numeric)
                .foregroundStyle(VTheme.Color.Text.primary)
            if Self.needsAttention(volume) {
                VTheme.Symbol.warning.image()
                    .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
                    .foregroundStyle(VTheme.Color.Semantic.warn)
                    .accessibilityLabel(Text("Needs attention", bundle: .vigilUI))
            }
        }
        .frame(minHeight: VInspectorMetrics.rowHeight)
        .accessibilityElement(children: .combine)
    }

    /// The same predicate `StorageInfo.needsAttention` applies to the whole device, per volume.
    nonisolated static func needsAttention(_ volume: StorageVolume) -> Bool {
        switch volume.status {
        case .unformatted, .error, .mismatch, .absent: return true
        case .ok, .sleeping, .idle, .formatting, .unknown: return false
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Rec — recording") {
    VPulseClock {
        ScrollView {
            VInspectorRecordingTab(state: .previewHealthy, actions: VInspectorActions())
                .padding(VTheme.Space.lg)
        }
    }
    .frame(width: VTheme.Metrics.inspectorWidth, height: 460)
    .background(VTheme.Color.Layer.surface)
}

#Preview("Rec — idle, near-full device disk") {
    VPulseClock {
        ScrollView {
            VInspectorRecordingTab(state: .previewDegraded, actions: VInspectorActions())
                .padding(VTheme.Space.lg)
        }
    }
    .frame(width: VTheme.Metrics.inspectorWidth, height: 460)
    .background(VTheme.Color.Layer.surface)
}
#endif

#endif  // os(macOS)
