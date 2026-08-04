//
//  VInspectorInfoTab.swift
//  VigilUI
//
//  The Info tab: who this camera is, what firmware it runs, where it lives, how long it has been
//  up, what it can store and what it can do.
//  macOS-only. Implements docs/UX.md §6.1 and docs/DESIGN.md §4.4, §9.19 (skeletons).
//
//  Every row here is backed by ``InspectorDeviceIdentity`` or `VigilISAPI`'s `StorageInfo`. UX.md
//  §6.1's Capabilities row lists eight chips — PTZ, Audio, Two-Way, H.265, Third stream, Motion,
//  Line crossing, Intrusion — and only two of them have a value type in this package:
//  ``InspectorPTZCapability/isPresent`` and the codec on ``InspectorStreamDescription``. Those two
//  are rendered and the other six are left out rather than faked from a guess. Reported.
//

#if os(macOS)

import SwiftUI

import VigilISAPI

// MARK: - VInspectorInfoTab

/// UX.md §6.1.
///
/// The serial is masked (`DS-2CD…4821`) with a copy button beside it. A serial identifies a
/// specific unit and ends up in screenshots and pasted bug reports, so the full value is never on
/// screen by default — ``InspectorDeviceIdentity/maskedSerialNumber`` owns that rule and this view
/// only obeys it.
@MainActor
package struct VInspectorInfoTab: View {

    /// The panel's snapshot.
    package let state: VInspectorState

    /// The panel's handlers.
    package let actions: VInspectorActions

    /// Creates the tab.
    package init(state: VInspectorState, actions: VInspectorActions) {
        self.state = state
        self.actions = actions
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.isDeviceUnavailable {
                VInspectorNotice("Unavailable", onRetry: actions.onRetryDevice)
                    .padding(.bottom, VTheme.Space.xs)
            }
            identitySection
            storageSection
            capabilitiesSection
            actionsSection
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        let identity = state.identity
        return VStack(alignment: .leading, spacing: 0) {
            VInspectorSectionHeader("Identity")
            VInspectorRow("Model") { deviceValue(identity.model) }
            VInspectorRow("Device name") { deviceValue(identity.deviceName) }
            VInspectorRow("Firmware") { deviceValue(firmwareLabel) }
            serialRow
            VInspectorRow("MAC") { deviceValue(identity.macAddress) }
            VInspectorRow("Channel") { deviceValue(channelLabel) }
            hostRow
            VInspectorRow("Uptime") {
                VInspectorMonoValue(VInspectorFormat.uptime(seconds: identity.uptimeSeconds),
                                    isLive: true)
            }
            clockRow
        }
    }

    /// How far the camera's clock is from this Mac's — and, when it applies, that Vigil is already
    /// correcting for a firmware that labels local time as UTC.
    ///
    /// ⛔ This row earns its place by explaining *other* symptoms. A camera an hour out puts events
    /// at the wrong minute, sends an archive search for the wrong day, and leaves a bookmark
    /// pointing at footage that is not there — and every one of those looks like a bug in Vigil
    /// until you know the clock is wrong. `DeviceTime.skew(against:)` has computed this since it
    /// was written and its own documentation says "beyond ±60 s the UI warns"; nothing warned.
    @ViewBuilder
    private var clockRow: some View {
        switch state.identity.clockAgreement {
        case .unknown:
            // Nothing read yet is not the same as "in step", and must not be drawn as it.
            EmptyView()
        case .inStep(let seconds):
            VInspectorRow("Clock") { clockValue(seconds, isOut: false) }
        case .out(let seconds):
            VInspectorRow("Clock") { clockValue(seconds, isOut: true) }
        }
    }

    /// The signed figure, warned about when it is out, and annotated when Vigil is compensating.
    private func clockValue(_ seconds: Double, isOut: Bool) -> some View {
        HStack(spacing: VTheme.Space.xxs) {
            if isOut {
                VTheme.Symbol.warning.image()
                    .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
                    .foregroundStyle(VTheme.Color.Semantic.warn)
            }
            VInspectorMonoValue(Self.skewLabel(seconds))
            // Said in words, not folded into the number: the figure is what the clock reads, and
            // this is what Vigil is doing about it. On such a camera the skew is the zone offset
            // and the clock is in fact correct, so an unexplained "+3:00:00" would send the user
            // to reset a clock that is fine.
            if state.identity.stampsLocalTimeAsUTC {
                Text("zone corrected", bundle: .vigilUI)
                    .vType(VTheme.Typography.caption2)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
            }
        }
    }

    /// `"+0:04"` / `"−2:11"`, always signed.
    ///
    /// The sign is the whole point: an unsigned figure leaves the user unable to tell a camera
    /// running fast from one running slow, and those have different causes. A true minus sign
    /// rather than a hyphen, so it lines up with the digits in the monospaced face.
    private static func skewLabel(_ seconds: Double) -> String {
        (seconds < 0 ? "\u{2212}" : "+") + VInspectorFormat.duration(seconds: abs(seconds))
    }

    /// Firmware version and, when the device reported one, its release date.
    ///
    /// The date arrives pre-formatted on ``InspectorDeviceIdentity/firmwareReleased`` — UX.md §6.1
    /// asks for `.dateTime.year().month().day()`, and doing it at the adapter keeps this module out
    /// of the business of parsing whatever `firmwareReleasedDate` a given firmware emits.
    private var firmwareLabel: String {
        let version = state.identity.firmwareVersion
        guard let released = state.identity.firmwareReleased, !released.isEmpty else {
            return version
        }
        return version.isEmpty ? released : "\(version) \u{00B7} \(released)"
    }

    private var channelLabel: String {
        guard state.identity.totalChannels > 1 else { return state.identity.channel.description }
        return "\(state.identity.channel.description) / \(state.identity.totalChannels)"
    }

    /// The masked serial with its copy affordance.
    private var serialRow: some View {
        VInspectorRow("Serial") {
            HStack(spacing: VTheme.Space.xxs) {
                if state.isDeviceLoading {
                    VInspectorSkeletonValue()
                } else {
                    VInspectorMonoValue(state.identity.maskedSerialNumber)
                }
                VButton(symbol: .copy,
                        size: .xs,
                        accessibilityLabel: "Copy",
                        action: actions.onCopySerial)
                    .disabled(state.identity.serialNumber.isEmpty)
            }
        }
    }

    /// `host:554`, with a lock glyph when the ISAPI channel is TLS.
    private var hostRow: some View {
        VInspectorRow("Host") {
            HStack(spacing: VTheme.Space.xxs) {
                if state.identity.usesTLS {
                    VTheme.Symbol.locked.image()
                        .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
                        .foregroundStyle(VTheme.Color.Semantic.ok)
                        .accessibilityLabel(Text("Secure", bundle: .vigilUI))
                }
                deviceValue(state.identity.addressLabel)
            }
        }
    }

    // MARK: - Storage

    /// Device capacity, the 6 pt bar, and a warning when a volume is not `ok`.
    ///
    /// The bar turns `danger` past 95 % because a device that cannot write is a device that is not
    /// recording, and that is the fact the row exists to surface.
    @ViewBuilder
    private var storageSection: some View {
        VInspectorSectionHeader("Storage")
        if let capacity = state.storageCapacityMB, let used = state.storageUsedFraction {
            VInspectorRow("Device storage") { storageSummary(used: used, capacity: capacity) }
            VInspectorMeter(fraction: used, tint: storageTint(used))
                .padding(.top, VTheme.Space.xxs)
            if let storage = state.storage, storage.needsAttention {
                Text("A volume on this camera needs attention.", bundle: .vigilUI)
                    .vType(VTheme.Typography.caption1)
                    .foregroundStyle(VTheme.Color.Semantic.warn)
                    .padding(.top, VTheme.Space.xxs)
            }
        } else {
            VInspectorRow("Device storage") { VInspectorMonoValue(nil) }
        }
    }

    /// `74 % of 4.0 TB`.
    ///
    /// The joining word is prose, so the sentence goes through the localisation table while the two
    /// numbers do not — a decimal separator that changed with the locale would make two screenshots
    /// of the same disk disagree.
    private func storageSummary(used: Double, capacity: Int) -> some View {
        let value = VInspectorFormat.percent(fraction: used)
        let expected = VInspectorFormat.capacity(megabytes: capacity)
        return Text("\(value) of \(expected)", bundle: .vigilUI)
            .vType(VTheme.Typography.mono.numeric)
            .foregroundStyle(storageTint(used).colour)
            .lineLimit(1)
    }

    /// ⚠️ 0.95 is this view's own threshold, not one of `InspectorHealth`'s: DESIGN.md §9.20's
    /// table covers loss, jitter, latency, fps and decode queue, and says nothing about disks.
    /// It is declared here, once, rather than inlined twice. Reported.
    private func storageTint(_ used: Double) -> VInspectorHealthTint {
        used >= 0.95 ? .danger : .neutral
    }

    // MARK: - Capabilities

    /// The two capability chips this package can actually answer for.
    @ViewBuilder
    private var capabilitiesSection: some View {
        VInspectorSectionHeader("Capabilities")
        HStack(spacing: VTheme.Space.xxs) {
            capabilityChip("PTZ", isPresent: state.ptz.isPresent)
            if !state.stream.codec.isEmpty {
                VChip(.neutral) { Text(verbatim: state.stream.codec) }
            }
            Spacer(minLength: 0)
        }
    }

    /// A chip that is greyed rather than hidden when the feature is absent, so the row's shape does
    /// not change per model and the user learns what a camera *could* have (UX.md §6.1).
    @ViewBuilder
    private func capabilityChip(_ title: LocalizedStringKey, isPresent: Bool) -> some View {
        VChip(.neutral, restOpacity: isPresent ? 1 : 0.45) {
            Text(title, bundle: .vigilUI)
                .foregroundStyle(isPresent
                                    ? VTheme.Color.Text.secondary
                                    : VTheme.Color.Text.disabled)
        }
    }

    // MARK: - Actions

    /// ⚠️ UX.md §6.1 lists four actions. `Edit Camera…` and `Reboot Device…` are omitted: the first
    /// belongs to the camera library and the second is a destructive device write, and neither has
    /// a handler on ``InspectorDeviceService`` or anywhere else in this package. Reported.
    @ViewBuilder
    private var actionsSection: some View {
        VInspectorSectionHeader("Actions")
        VStack(alignment: .leading, spacing: VTheme.Space.xs) {
            VButton("Open Web UI", symbol: .network, style: .secondary, size: .sm,
                    action: actions.onOpenWebPage)
            VButton("Run Stream Doctor", symbol: .streamDoctor, style: .secondary, size: .sm,
                    action: actions.onRunStreamDoctor)
        }
        .padding(.top, VTheme.Space.xxs)
    }

    // MARK: - Private Helpers

    /// A device string, or its skeleton while ISAPI is answering.
    @ViewBuilder
    private func deviceValue(_ text: String) -> some View {
        if state.isDeviceLoading {
            VInspectorSkeletonValue()
        } else {
            VInspectorMonoValue(text)
        }
    }
}

// MARK: - Previews

#if DEBUG && !VIGIL_NO_PREVIEWS
#Preview("Info — populated") {
    ScrollView {
        VInspectorInfoTab(state: .previewHealthy, actions: VInspectorActions())
            .padding(VTheme.Space.lg)
    }
    .frame(width: VTheme.Metrics.inspectorWidth, height: 620)
    .background(VTheme.Color.Layer.surface)
}

#Preview("Info — near-full disk and a failed fetch") {
    ScrollView {
        VInspectorInfoTab(state: .previewDegraded, actions: VInspectorActions())
            .padding(VTheme.Space.lg)
    }
    .frame(width: VTheme.Metrics.inspectorWidth, height: 620)
    .background(VTheme.Color.Layer.surface)
}

#Preview("Info — loading") {
    ScrollView {
        VInspectorInfoTab(state: .previewLoading, actions: VInspectorActions())
            .padding(VTheme.Space.lg)
    }
    .frame(width: VTheme.Metrics.inspectorWidth, height: 620)
    .background(VTheme.Color.Layer.surface)
}
#endif

#endif  // os(macOS)
