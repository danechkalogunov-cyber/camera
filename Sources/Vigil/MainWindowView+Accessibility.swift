//
//  MainWindowView+Accessibility.swift
//  Vigil
//
//  Full Keyboard Access focus indication and the narrow-window camera rail.
//

#if os(macOS)

import SwiftUI

import VigilUI

extension MainWindowView {
    @ViewBuilder
    func keyboardRegionRing(_ region: MainWindowState.KeyboardRegion) -> some View {
        if window.isFullKeyboardAccessEnabled && window.keyboardRegion == region {
            RoundedRectangle(cornerRadius: 5)
                .stroke(SwiftUI.Color.accentColor, lineWidth: 2)
                .padding(2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    var sidebarRail: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(sidebarCameras) { camera in
                    Button {
                        selectCamera(camera.id)
                    } label: {
                        Text(String(camera.name.prefix(1)).uppercased())
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(VTheme.Color.Layer.surfaceRaised))
                    }
                    .buttonStyle(.plain)
                    .help(camera.name)
                    .accessibilityLabel(camera.name)
                }
            }
            .padding(.vertical, 10)
        }
        .frame(width: 52)
        .background(VTheme.Color.Layer.sidebarFallback)
    }
}

#endif  // os(macOS)
