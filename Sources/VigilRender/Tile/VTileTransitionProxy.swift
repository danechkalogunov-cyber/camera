//
//  VTileTransitionProxy.swift
//  VigilRender
//
//  Still compositor proxy used while a live video tile changes geometry.
//

#if os(macOS)

import CoreGraphics
import SwiftUI

public struct VTileTransitionProxy: View {
    public let still: CGImage?
    public init(still: CGImage? = nil) { self.still = still }

    public var body: some View {
        Group {
            if let still {
                Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.black
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#endif  // os(macOS)
