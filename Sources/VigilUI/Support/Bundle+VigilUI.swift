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

// MARK: - Plain-String Lookup

/// One `VigilUI` string, in the user's language, as a `String` rather than a `LocalizedStringKey`.
///
/// **Why a plain `String` is sometimes the right answer.** `LocalizedStringKey` is what a `Text`
/// should almost always take, because SwiftUI then looks it up in the view's own environment. But
/// two kinds of caller cannot use one: the command palette, whose ranker folds and scores
/// individual characters and would otherwise rank against English inside an opaque key, and the
/// app-layer models that *compute* a sentence — a scan's phase line, a toast — and hand the result
/// down as a value.
///
/// ⚠️ THE KEY MAY BE ASSEMBLED WITH `+`, AND THAT IS THE POINT. A `LocalizedStringKey` built from
/// two halves matches nothing in any `.strings` file, so a long key has to be one unbroken literal
/// and long keys therefore break the 110-column limit. A `String` has no such problem: adjacent
/// literals are folded at compile time and what arrives here is the whole key.
///
/// - Parameter key: the English text, which in this module *is* the key.
/// - Returns: the translation, or `key` itself when there is none — never an empty string and never
///   a crash, for the reasons `Bundle.vigilUI` spells out above.
public func vigilUIString(_ key: String) -> String {
    Bundle.vigilUI.localizedString(forKey: key, value: key, table: nil)
}

#endif  // os(macOS)
