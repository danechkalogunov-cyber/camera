//
//  Bundle+VigilUI.swift
//  VigilUI
//
//  Locating this module's resource bundle without a fatalError. Used by every `Text(_, bundle:)`
//  call site in this module, in place of SwiftPM's synthesised `Bundle.module`.
//  macOS-only. See docs/BUILD-VERIFICATION.md for the crash that made this necessary.
//

#if os(macOS)

import Foundation

// MARK: - Bundle.vigilUI

extension Bundle {

    /// This module's resource bundle, or `Bundle.main` when it cannot be found.
    ///
    /// **Why this exists instead of `Bundle.module`.** SwiftPM synthesises `Bundle.module`, and its
    /// synthesised accessor ends in a `fatalError`. That killed the app on the first real launch, at
    /// the moment SwiftUI evaluated the connect form:
    ///
    /// ```
    /// _assertionFailure(_:_:file:line:flags:)
    /// closure #1 in variable initialization expression of static NSBundle.module
    ///     (resource_bundle_accessor.swift:12)
    /// closure #1 in ConnectFormView.content.getter    (ConnectFormView.swift:113)
    /// ```
    ///
    /// The cause is a layout disagreement, not a missing file. The synthesised accessor looks beside
    /// `Bundle.main.bundleURL`, which for an `.app` is the bundle **root** — `Vigil.app/`. Apple's
    /// bundle layout puts resources in `Vigil.app/Contents/Resources/`, which is where
    /// `Scripts/build-app.sh` correctly places them and where `codesign` requires them to be. Both
    /// sides are behaving as designed; they simply do not meet. Moving the bundle to the root to
    /// satisfy the accessor would produce unsealed top-level content and break signing instead.
    ///
    /// **Why it must not crash.** A missing `.strings` file costs nothing: `LocalizedStringKey` falls
    /// back to the key, and in this module every key *is* its English text, so the interface renders
    /// correctly with no bundle at all. Trading that for a process death is indefensible — and it is
    /// the reason `Scripts/lint.py` bans `fatalError` in `Sources/`. The ban could not see this one,
    /// because the code was generated at build time rather than written here.
    ///
    /// Resolved once, lazily, on first use.
    public static let vigilUI: Bundle = {
        // A private class purely so `Bundle(for:)` has something to locate. In a statically linked
        // SwiftPM target this resolves to the main bundle; if VigilUI is ever built as a dynamic
        // framework it resolves to that framework, and the first candidate below starts working.
        final class BundleFinder {}

        let name = "Vigil_VigilUI.bundle"
        let finder = Bundle(for: BundleFinder.self)

        // Ordered most specific to most general. Every plausible layout is tried before giving up:
        //   1. the framework's own resources, if this module is dynamically linked
        //   2. Vigil.app/Contents/Resources — where build-app.sh puts it and codesign wants it
        //   3. Vigil.app/ — where SwiftPM's own synthesised accessor looks
        //   4. the same, spelled explicitly, in case resourceURL is nil
        //   5. beside the executable — a plain `swift run` with no .app around it
        let candidates: [URL?] = [
            finder.resourceURL,
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"),
            Bundle.main.executableURL?.deletingLastPathComponent(),
            finder.bundleURL,
        ]

        for case let directory? in candidates {
            let url = directory.appendingPathComponent(name)
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        // Not found. `Bundle.main` has no `.lproj` for this module, so every `LocalizedStringKey`
        // falls through to its own text — which is English, and correct. Silent on purpose: this
        // runs during the first view body evaluation, where there is no logger in scope and no
        // user-visible consequence to report.
        return .main
    }()
}

#endif  // os(macOS)
