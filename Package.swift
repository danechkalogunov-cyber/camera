// swift-tools-version:6.0
//
// Vigil — native macOS viewer for Hikvision IP cameras and NVRs.
//
// ZERO EXTERNAL DEPENDENCIES BY DESIGN. `dependencies:` is empty and must stay empty.
// Adding an SPM package breaks constraint C1 in docs/ARCHITECTURE.md §1.1 and CI will fail.
//
// Two build worlds:
//   macOS  — everything builds. `swift build` / Xcode / Scripts/build-app.sh.
//   Linux  — only the Foundation-only targets are meaningful. `swift build --product VigilPure`
//            builds them; a full `swift build` also succeeds because every file in a macOS-only
//            target is wrapped in `#if os(macOS)` (see docs/ARCHITECTURE.md §4).

import PackageDescription

// MARK: - Build settings

/// Applied to every target in the package.
///
/// * `ExistentialAny` forces the `any P` spelling so existential boxing stays visible at call sites,
///   which matters on the frame path.
/// * `swiftLanguageModes: [.v6]` is set package-wide below and turns on *complete* concurrency
///   checking; we never downgrade a target to `.v5` to silence a data-race diagnostic.
let common: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

/// Pure targets additionally get a compile-time marker so shared helpers can assert purity.
let pure: [SwiftSetting] = common + [
    .define("VIGIL_PURE"),
]

/// macOS-only targets. `VIGIL_APPLE` is defined only when actually compiling for an Apple platform,
/// so the `#if os(macOS)` guards and the define always agree.
let apple: [SwiftSetting] = common + [
    .define("VIGIL_APPLE", .when(platforms: [.macOS])),
]

// MARK: - Package

let package = Package(
    name: "Vigil",
    // Required as soon as any target ships a `.lproj` directory — SwiftPM refuses the manifest
    // otherwise: "manifest property 'defaultLocalization' not set; it is required in the presence of
    // localized resources". English is the development language; `ru.lproj` is a translation of it.
    defaultLocalization: "en",
    platforms: [
        // Ignored on Linux; constrains the Apple deployment target only.
        .macOS(.v14),
    ],
    products: [
        // The shipping app binary. Assembled into Vigil.app by Scripts/build-app.sh.
        .executable(name: "Vigil", targets: ["Vigil"]),

        // The Linux/CI surface: exactly the Foundation-only targets. `swift build --product VigilPure`
        // is the single command Linux CI runs, and it is the mechanism that keeps the pure layer pure —
        // if someone adds `import CoreMedia` to VigilRTP, this product stops building.
        .library(
            name: "VigilPure",
            // `type:` is REQUIRED here, not cosmetic. A library product with no explicit type is an
            // "automatic" product, and SwiftPM refuses `swift build --product <automatic library>`:
            //   warning: '--product' cannot be used with the automatic product 'VigilPure';
            //            building the default target instead
            // That silently turns the Linux purity gate into a full-package build, which defeats it.
            // Verified on Swift 6.1.2 / Linux — see docs/BUILD-VERIFICATION.md.
            type: .static,
            targets: [
                "VigilProtocols",
                "VigilBitstream",
                "VigilRTSP",
                "VigilRTP",
                "VigilISAPI",
                "VigilDiscovery",
            ]
        ),

        // Test-only fixtures. Exposed as a product so `swift build --product VigilTestKit` can be
        // sanity-checked on Linux independently of the test runner.
        .library(name: "VigilTestKit", targets: ["VigilTestKit"]),

        // Convenience for embedding the app layer in an Xcode host project (see project.yml).
        .library(name: "VigilApp", targets: ["VigilUI", "VigilCore", "VigilRender"]),
    ],
    dependencies: [
        // INTENTIONALLY EMPTY. See the header comment.
    ],
    targets: [

        // MARK: Pure — Foundation only, Linux-testable

        .target(
            name: "VigilProtocols",
            path: "Sources/VigilProtocols",
            swiftSettings: pure
        ),
        .target(
            name: "VigilBitstream",
            dependencies: ["VigilProtocols"],
            path: "Sources/VigilBitstream",
            swiftSettings: pure
        ),
        .target(
            name: "VigilRTSP",
            dependencies: ["VigilProtocols"],
            path: "Sources/VigilRTSP",
            swiftSettings: pure
        ),
        .target(
            name: "VigilRTP",
            dependencies: ["VigilProtocols", "VigilBitstream"],
            path: "Sources/VigilRTP",
            swiftSettings: pure
        ),
        .target(
            name: "VigilISAPI",
            dependencies: ["VigilProtocols"],
            path: "Sources/VigilISAPI",
            swiftSettings: pure
        ),
        .target(
            name: "VigilDiscovery",
            dependencies: ["VigilProtocols"],
            path: "Sources/VigilDiscovery",
            swiftSettings: pure
        ),

        // MARK: Test fixtures — pure, shipped to no product the app links

        .target(
            name: "VigilTestKit",
            dependencies: ["VigilProtocols", "VigilRTSP", "VigilRTP", "VigilBitstream"],
            path: "Sources/VigilTestKit",
            swiftSettings: pure
        ),

        // MARK: macOS-only

        .target(
            name: "VigilTransport",
            // The edge to VigilDiscovery is back: `Sources/VigilTransport/Discovery/` now conforms
            // to that module's transport protocols, which is the wave the note here anticipated.
            // The dependency runs this way round on purpose — VigilDiscovery stays Foundation-only
            // and Linux-testable, and every socket lives on this side of the line.
            dependencies: ["VigilProtocols", "VigilRTSP", "VigilDiscovery"],
            path: "Sources/VigilTransport",
            swiftSettings: apple
        ),
        .target(
            name: "VigilVideo",
            dependencies: ["VigilProtocols", "VigilBitstream"],
            path: "Sources/VigilVideo",
            swiftSettings: apple
        ),
        .target(
            name: "VigilRender",
            dependencies: ["VigilProtocols", "VigilVideo"],
            path: "Sources/VigilRender",
            // NO `resources:`. There is nothing to put in a bundle yet — `Shaders/` holds only a
            // `.placeholder`, and SwiftPM skips dotfiles, so declaring it produced an EMPTY bundle
            // with no Info.plist. `codesign` then refused it outright and stopped the first Mac build:
            //   Vigil_VigilRender.bundle: bundle format unrecognized, invalid, or unsuitable
            // Nothing in this target calls `Bundle.module`, so the bundle bought nothing and cost the
            // build. Restore `.process("Shaders")` in the same commit that adds the first .metal file,
            // not before.
            swiftSettings: apple
        ),
        .target(
            name: "VigilCore",
            dependencies: [
                "VigilProtocols",
                "VigilRTSP",
                "VigilRTP",
                "VigilBitstream",
                "VigilISAPI",
                "VigilDiscovery",
                "VigilTransport",
                "VigilVideo",
            ],
            path: "Sources/VigilCore",
            swiftSettings: apple
        ),
        .target(
            name: "VigilUI",
            dependencies: ["VigilProtocols", "VigilCore", "VigilRender"],
            path: "Sources/VigilUI",
            // `Localizations` only. This target DOES call `Bundle.module` (every `Text(_, bundle:)`),
            // and SwiftPM's generated accessor `fatalError`s when the bundle is absent, so unlike
            // VigilRender above this one must keep a resource — and that resource has to be real. It
            // now is: `Localizations/en.lproj/Localizable.strings`, the base localisation.
            //
            // `Resources` is dropped until there is something in it. It held only a `.placeholder`,
            // which SwiftPM skips, and an empty directory is not a resource — Assets.xcassets and the
            // app icon do not exist yet, which the build script already warns about by name.
            resources: [
                .process("Localizations"),    // en.lproj / ru.lproj .strings + .stringsdict
            ],
            swiftSettings: apple
        ),
        .executableTarget(
            name: "Vigil",
            // SwiftPM puts only *direct* dependencies on a target's import search path, so every
            // module the app target `import`s must appear here even when a listed dependency
            // already depends on it. This list was [VigilUI, VigilCore] while the wiring imported
            // VigilProtocols, VigilRender and VigilVideo as well — and the Linux build stayed green
            // the whole time, because every file in this target is inside `#if os(macOS)` and the
            // imports were therefore never active. It would have failed on the first Mac build.
            dependencies: [
                "VigilUI",
                "VigilCore",
                "VigilProtocols",
                "VigilRender",
                "VigilVideo",
            ],
            path: "Sources/Vigil",
            swiftSettings: apple
        ),

        // MARK: Tests — pure (run on Linux AND macOS)

        .testTarget(
            name: "VigilProtocolsTests",
            dependencies: ["VigilProtocols", "VigilTestKit"],
            path: "Tests/VigilProtocolsTests"
        ),
        .testTarget(
            name: "VigilBitstreamTests",
            dependencies: ["VigilBitstream", "VigilTestKit"],
            path: "Tests/VigilBitstreamTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VigilRTSPTests",
            dependencies: ["VigilRTSP", "VigilTestKit"],
            path: "Tests/VigilRTSPTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VigilRTPTests",
            dependencies: ["VigilRTP", "VigilTestKit"],
            path: "Tests/VigilRTPTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VigilISAPITests",
            dependencies: ["VigilISAPI", "VigilTestKit"],
            path: "Tests/VigilISAPITests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VigilDiscoveryTests",
            dependencies: ["VigilDiscovery", "VigilTestKit"],
            path: "Tests/VigilDiscoveryTests",
            resources: [.copy("Fixtures")]
        ),
        // End-to-end pure pipeline: synthetic camera -> RTSP -> RTP -> EncodedFrame. No sockets,
        // no VideoToolbox, no Mac required. This is the highest-value test target in the repo.
        .testTarget(
            name: "VigilPipelineTests",
            dependencies: ["VigilTestKit", "VigilRTSP", "VigilRTP", "VigilBitstream", "VigilProtocols"],
            path: "Tests/VigilPipelineTests",
            resources: [.copy("Fixtures")]
        ),

        // MARK: Tests — macOS only (bodies wrapped in #if os(macOS); empty modules on Linux)

        .testTarget(
            name: "VigilTransportTests",
            dependencies: ["VigilTransport", "VigilTestKit"],
            path: "Tests/VigilTransportTests"
        ),
        .testTarget(
            name: "VigilVideoTests",
            dependencies: ["VigilVideo", "VigilTestKit"],
            path: "Tests/VigilVideoTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VigilRenderTests",
            dependencies: ["VigilRender", "VigilTestKit"],
            path: "Tests/VigilRenderTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VigilCoreTests",
            dependencies: ["VigilCore", "VigilTestKit"],
            path: "Tests/VigilCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VigilUITests",
            dependencies: ["VigilUI", "VigilTestKit"],
            path: "Tests/VigilUITests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
