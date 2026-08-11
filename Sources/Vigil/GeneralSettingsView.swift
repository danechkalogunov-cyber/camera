//
//  GeneralSettingsView.swift
//  Vigil
//
//  The process-level visibility controls required by F-AUT-05.
//

#if os(macOS)

import AppKit
import SwiftUI

import VigilCore
import VigilProtocols
import VigilUI

enum GeneralPreferenceKey {
    static let showsMenuBarExtra = "general.showsMenuBarExtra"
    static let menuBarOnly = "general.menuBarOnly"
    static let defaultTransportKey = "vigil.streams.defaultTransport"

    static func defaultTransport(in defaults: UserDefaults = .standard) -> RTSPTransportKind {
        guard let raw = defaults.string(forKey: defaultTransportKey),
              let transport = RTSPTransportKind(rawValue: raw),
              [.auto, .tcpInterleaved, .udpUnicast].contains(transport)
        else { return .tcpInterleaved }
        return transport
    }
}

struct GeneralSettingsView: View {
    @AppStorage(GeneralPreferenceKey.showsMenuBarExtra) private var showsMenuBarExtra = true
    @AppStorage(GeneralPreferenceKey.menuBarOnly) private var menuBarOnly = false
    @AppStorage(GeneralPreferenceKey.defaultTransportKey)
    private var defaultTransport = RTSPTransportKind.tcpInterleaved.rawValue
    @AppStorage(MachineDecodeBudget.overrideKey) private var maximumDecodeUnits = 0.0

    var body: some View {
        Form {
            Section(vigilUIString("App visibility")) {
                Toggle(vigilUIString("Show Vigil in the menu bar"), isOn: $showsMenuBarExtra)
                    .disabled(menuBarOnly)
                Toggle(vigilUIString("Run as a menu-bar-only app"), isOn: $menuBarOnly)
                Text(vigilUIString("Open Vigil from the menu-bar extra whenever you need the window."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(vigilUIString("Streams")) {
                Picker(vigilUIString("Default transport"), selection: $defaultTransport) {
                    Text(vigilUIString("Auto (TCP / UDP)"))
                        .tag(RTSPTransportKind.auto.rawValue)
                    Text(vigilUIString("TCP (interleaved)"))
                        .tag(RTSPTransportKind.tcpInterleaved.rawValue)
                    Text(vigilUIString("UDP (unicast)"))
                        .tag(RTSPTransportKind.udpUnicast.rawValue)
                }
                Picker(vigilUIString("Maximum concurrent decodes"),
                       selection: $maximumDecodeUnits) {
                    Text(vigilUIString("Automatic (recommended)"))
                        .tag(0.0)
                    ForEach([10.0, 16.0, 24.0, 32.0, 48.0], id: \.self) { units in
                        Text("\(Int(units)) DU").tag(units)
                    }
                }
                Text(vigilUIString(
                    "New cameras inherit the default transport. Per-camera settings take precedence."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520, height: 390)
        .onChange(of: menuBarOnly, initial: true) { _, onlyInMenuBar in
            if onlyInMenuBar { showsMenuBarExtra = true }
            AppVisibility.apply(menuBarOnly: onlyInMenuBar, hideWindows: false)
        }
    }
}

enum AppVisibility {
    @MainActor
    static func apply(menuBarOnly: Bool, hideWindows: Bool) {
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
        if menuBarOnly, hideWindows {
            for window in NSApp.windows where window.canBecomeMain { window.orderOut(nil) }
        } else if !menuBarOnly {
            NSApp.activate()
        }
    }
}

#endif  // os(macOS)
