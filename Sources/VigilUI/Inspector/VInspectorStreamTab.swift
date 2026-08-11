//
//  VInspectorStreamTab.swift
//  VigilUI
//
//  The Stream tab: the 60 s bitrate sparkline, the stream's own numbers, the transport-health block
//  and the device summary — the exact four blocks design/mockups/01-main-window.html renders.
//  macOS-only. Implements docs/UX.md §6.2, design/mockups/01-main-window.html (the right panel) and
//  docs/DESIGN.md §4.4, §9.20 (threshold tinting), §9.21 (sparkline).
//
//  ⛔ NO THRESHOLD IS DECIDED HERE. Every coloured value on this tab comes from an `InspectorStat`
//  factory, which asks `InspectorHealth` — the one place DESIGN.md §9.20's table is written down.
//  A view that re-derived "0.5 % is a warning" would be a second copy of a product rule, and the
//  second copy is always the one that goes stale.
//
//  The one value that is *not* an `InspectorStat` is the decode path, because it is a boolean
//  rather than a measurement. UX.md §6.2 gives it the `ok` colour for hardware and `warn` for
//  software. ⚠️ The mockup draws its `⚡ HARDWARE` chip in amber, which under DESIGN.md P3 would say
//  "something is wrong" about the healthy case. UX.md's mapping is followed. Reported.
//

#if os(macOS)

import SwiftUI

import VigilProtocols

// MARK: - VInspectorStreamTab

/// UX.md §6.2.
@MainActor
package struct VInspectorStreamTab: View {

    /// The panel's snapshot.
    package let state: VInspectorState

    /// The panel's handlers.
    package let actions: VInspectorActions

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    /// The sparkline's floor: one megabit per second. Below that a stream is either a sub-stream
    /// at a trickle or barely alive, and either way the shape of its noise is not information.
    package static let bitrateFloor: Double = 1_000_000

    /// Creates the tab.
    package init(state: VInspectorState, actions: VInspectorActions) {
        self.state = state
        self.actions = actions
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bitrateSection
            transportHealthSection
            deviceSection
            actionsSection
        }
    }

    // MARK: - Bitrate

    /// `BITRATE — LAST 60 S`, the sparkline, then the four stream facts.
    @ViewBuilder
    private var bitrateSection: some View {
        VInspectorSectionHeader("Bitrate — last 60 s")
        VInspectorSparkline(values: state.bitrateSeries,
                            tint: VTheme.Color.Semantic.accent,
                            floor: Self.bitrateFloor)
        VInspectorRow("Bitrate") {
            VInspectorStatValue(.bitrate(bitsPerSecond: state.statistics.bitsPerSecond))
        }
        VInspectorRow("Resolution") {
            VInspectorStatValue(.resolution(width: state.stream.pixelWidth,
                                            height: state.stream.pixelHeight))
        }
        VInspectorRow("Framerate") {
            VInspectorStatValue(.framesPerSecond(state.statistics.framesPerSecond,
                                                 target: state.stream.targetFramesPerSecond))
        }
        VInspectorRow("Keyframe int.") {
            VInspectorStatValue(.keyframeInterval(
                seconds: state.statistics.keyframeIntervalSeconds,
                framesPerSecond: state.statistics.framesPerSecond))
        }
    }

    // MARK: - Transport health

    /// The six rows of the mockup's `TRANSPORT HEALTH` block, in its order.
    ///
    /// Packet loss is the one reading that earns a green when it is fine: it is the number an
    /// operator opens this tab to see, and "0.02 %" in `text.primary` says nothing that "0.02 %"
    /// in `ok` does not say faster.
    @ViewBuilder
    private var transportHealthSection: some View {
        VInspectorSectionHeader("Transport health")
        VInspectorRow("Packet loss") {
            VInspectorStatValue(.loss(fraction: state.statistics.lossFraction),
                                emphasisesHealth: true)
        }
        VInspectorRow("Jitter") {
            VInspectorStatValue(.jitter(milliseconds: state.statistics.jitterMilliseconds))
        }
        VInspectorRow("Reordered") {
            VInspectorMonoValue(VInspectorFormat.count(state.statistics.packetsOutOfOrder),
                                isLive: true)
        }
        VInspectorRow("Decode queue") {
            VInspectorStatValue(.decodeQueue(frames: state.statistics.decodeQueueDepth))
        }
        VInspectorRow("Latency") {
            VInspectorStatValue(
                .latency(milliseconds: state.statistics.estimatedLatencyMilliseconds))
        }
        VInspectorRow("Decode") { decodeChip }
        VInspectorRow("Transport") { VInspectorMonoValue(state.stream.transport) }
        VInspectorRow("Stream in use") { streamInUseValue }
        if let mode = state.stream.decodeBudgetMode {
            VInspectorRow("Decode budget") {
                VInspectorMonoValue(mode, isLive: true)
            }
        }
        if state.statistics.reconnectCount > 0 {
            VInspectorRow("Reconnects") {
                VInspectorMonoValue(VInspectorFormat.count(UInt64(state.statistics.reconnectCount)),
                                    isLive: true)
            }
        }
        if let sessionID = state.stream.sessionID, !sessionID.isEmpty {
            VInspectorRow("Session") { VInspectorMonoValue(sessionID) }
        }
        if let code = state.statistics.lastErrorCode, !code.isEmpty {
            VInspectorRow("Last error") {
                Text(verbatim: code)
                    .vType(VTheme.Typography.mono)
                    .foregroundStyle(VTheme.Color.Semantic.danger)
                    .lineLimit(1)
            }
        }
    }

    /// `⚡ HARDWARE` or `CPU SOFTWARE`, as a tinted capsule.
    ///
    /// Built here rather than with ``VChip`` because §9.9's three chip families are `onVideo`,
    /// `neutral` and `selected` — none of them semantic — and re-styling a component from the
    /// outside is exactly what the component exists to prevent. The recipe is the mockup's:
    /// a 20 pt capsule, `Caption2`, the semantic colour at α 0.14 behind it.
    private var decodeChip: some View {
        let isHardware = state.statistics.isHardwareAccelerated
        let tint: SwiftUI.Color = isHardware
            ? VTheme.Color.Semantic.ok
            : VTheme.Color.Semantic.warn
        return HStack(spacing: VTheme.Space.xxs) {
            (isHardware ? VTheme.Symbol.hardwareDecode : VTheme.Symbol.softwareDecode).image()
                .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
            if isHardware {
                Text("Hardware", bundle: .vigilUI)
            } else {
                Text("Software", bundle: .vigilUI)
            }
        }
        .vType(VTheme.Typography.caption2)
        .foregroundStyle(tint)
        .padding(.horizontal, VTheme.Space.xs)
        .frame(height: VTheme.Metrics.xs)
        .background(tint.opacity(0.14), in: Capsule(style: .continuous))
        .overlay {
            // Under `differentiateWithoutColor` the software case also gains an edge, so the two
            // states differ in geometry and not only in hue (§10.5).
            if differentiate, !isHardware {
                Capsule(style: .continuous)
                    .strokeBorder(tint, lineWidth: VTheme.Border.thin)
            }
        }
    }

    /// `Auto → Main`, tappable to cycle Auto/Main/Sub/Third (UX.md §6.2).
    private var streamInUseValue: some View {
        Button(action: actions.onCycleStream) {
            HStack(spacing: VTheme.Space.xxs) {
                if state.stream.isAutomaticStream {
                    Text("Auto", bundle: .vigilUI)
                        .vType(VTheme.Typography.caption1)
                        .foregroundStyle(VTheme.Color.Text.tertiary)
                    Text(verbatim: "\u{2192}")
                        .vType(VTheme.Typography.caption1)
                        .foregroundStyle(VTheme.Color.Text.disabled)
                }
                VInspectorMonoValue(state.stream.streamInUse)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Device

    /// The mockup's `DEVICE` block: model, address, uptime, storage — plus the 6 pt bar.
    @ViewBuilder
    private var deviceSection: some View {
        VInspectorSectionHeader("Device")
        VInspectorRow("Model") { VInspectorMonoValue(state.identity.model) }
        VInspectorRow("Address") { VInspectorMonoValue(state.identity.host) }
        VInspectorRow("Uptime") {
            VInspectorMonoValue(VInspectorFormat.uptime(seconds: state.identity.uptimeSeconds),
                                isLive: true)
        }
        if let capacity = state.storageCapacityMB, let used = state.storageUsedFraction {
            VInspectorRow("Storage") { storageSummary(used: used, capacity: capacity) }
            VInspectorMeter(fraction: used, tint: used >= 0.95 ? .danger : .neutral)
                .padding(.top, VTheme.Space.xxs)
        } else {
            VInspectorRow("Storage") { VInspectorMonoValue(nil) }
        }
    }

    /// `74 % of 4.0 TB` — see the Info tab for why only the joining word is localised.
    private func storageSummary(used: Double, capacity: Int) -> some View {
        let value = VInspectorFormat.percent(fraction: used)
        let expected = VInspectorFormat.capacity(megabytes: capacity)
        return Text("\(value) of \(expected)", bundle: .vigilUI)
            .vType(VTheme.Typography.mono.numeric)
            .foregroundStyle(used >= 0.95
                                ? VTheme.Color.Semantic.danger
                                : VTheme.Color.Text.primary)
            .lineLimit(1)
    }

    // MARK: - Actions

    /// UX.md §6.2's four actions. `Export 10 min CSV` is omitted — nothing in this package can
    /// produce the file, and a button that cannot do its job is worse than its absence. Reported.
    @ViewBuilder
    private var actionsSection: some View {
        VInspectorSectionHeader("Actions")
        VStack(alignment: .leading, spacing: VTheme.Space.xs) {
            HStack(spacing: VTheme.Space.xs) {
                VButton("Request Keyframe", style: .secondary, size: .sm,
                        action: actions.onRequestKeyframe)
                VButton("Reconnect", style: .secondary, size: .sm, action: actions.onReconnect)
            }
            HStack(spacing: VTheme.Space.xs) {
                VButton("Copy Diagnostics", style: .ghost, size: .sm,
                        action: actions.onCopyDiagnostics)
                VButton("Switch Transport", style: .ghost, size: .sm,
                        action: actions.onSwapTransport)
            }
        }
        .padding(.top, VTheme.Space.xxs)
    }
}

// MARK: - Previews

#if DEBUG && !VIGIL_NO_PREVIEWS
#Preview("Stream — healthy") {
    ScrollView {
        VInspectorStreamTab(state: .previewHealthy, actions: VInspectorActions())
            .padding(VTheme.Space.lg)
    }
    .frame(width: VTheme.Metrics.inspectorWidth, height: 720)
    .background(VTheme.Color.Layer.surface)
}

#Preview("Stream — loss, software decode, full disk") {
    ScrollView {
        VInspectorStreamTab(state: .previewDegraded, actions: VInspectorActions())
            .padding(VTheme.Space.lg)
    }
    .frame(width: VTheme.Metrics.inspectorWidth, height: 720)
    .background(VTheme.Color.Layer.surface)
}

#Preview("Stream — no samples yet") {
    ScrollView {
        VInspectorStreamTab(
            state: VInspectorState(camera: LiveCameraIdentity(id: UUID(),
                                                              name: "New camera",
                                                              host: "192.168.1.90")),
            actions: VInspectorActions())
            .padding(VTheme.Space.lg)
    }
    .frame(width: VTheme.Metrics.inspectorWidth, height: 720)
    .background(VTheme.Color.Layer.surface)
}
#endif

#endif  // os(macOS)
