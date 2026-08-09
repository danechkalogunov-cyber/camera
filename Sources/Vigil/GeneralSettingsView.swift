//
//  GeneralSettingsView.swift
//  Vigil
//
//  The process-level visibility controls required by F-AUT-05.
//

#if os(macOS)

import AppKit
import SwiftUI

import VigilUI

enum GeneralPreferenceKey {
    static let showsMenuBarExtra = "general.showsMenuBarExtra"
    static let menuBarOnly = "general.menuBarOnly"
}

struct GeneralSettingsView: View {
    @AppStorage(GeneralPreferenceKey.showsMenuBarExtra) private var showsMenuBarExtra = true
    @AppStorage(GeneralPreferenceKey.menuBarOnly) private var menuBarOnly = false

    var body: some View {
        Form {
            Section(vigilUIString("App visibility")) {
                Toggle(vigilUIString("Show Vigil in the menu bar"), isOn: $showsMenuBarExtra)
                    .disabled(menuBarOnly)
                Toggle(vigilUIString("Run as a menu-bar-only app"), isOn: $menuBarOnly)
                Text(vigilUIString("Open Vigil from the menu-bar extra whenever you need the window."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520, height: 220)
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
