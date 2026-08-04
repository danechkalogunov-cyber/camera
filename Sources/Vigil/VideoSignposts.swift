//
//  VideoSignposts.swift
//  Vigil
//
//  Permanent points-of-interest consumed by Scripts/bench.sh and Instruments templates.
//

#if os(macOS)

    import Foundation
    import OSLog

    /// The twelve stable performance event names from API_CONTRACT §3.19.
    enum VideoSignpost: String, CaseIterable, Sendable {
        case launch
        case launchToFirstFrame
        case describe
        case setup
        case firstRTP
        case firstKeyframe
        case decode
        case render
        case snapshot
        case recordStart
        case paletteOpen
        case timelineDraw
    }

    /// Emits the app's permanent points of interest. The exhaustive switch deliberately keeps every
    /// name a compile-time constant so Instruments can index it without parsing message text.
    enum VideoSignposts {
        private static let signposter = OSSignposter(
            subsystem: Bundle.main.bundleIdentifier ?? "com.vigil.app",
            category: .pointsOfInterest
        )

        static func emit(_ event: VideoSignpost) {
            switch event {
            case .launch: signposter.emitEvent("launch")
            case .launchToFirstFrame: signposter.emitEvent("launchToFirstFrame")
            case .describe: signposter.emitEvent("describe")
            case .setup: signposter.emitEvent("setup")
            case .firstRTP: signposter.emitEvent("firstRTP")
            case .firstKeyframe: signposter.emitEvent("firstKeyframe")
            case .decode: signposter.emitEvent("decode")
            case .render: signposter.emitEvent("render")
            case .snapshot: signposter.emitEvent("snapshot")
            case .recordStart: signposter.emitEvent("recordStart")
            case .paletteOpen: signposter.emitEvent("paletteOpen")
            case .timelineDraw: signposter.emitEvent("timelineDraw")
            }
        }
    }

#endif
