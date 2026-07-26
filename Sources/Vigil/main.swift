//
//  main.swift
//  Vigil
//
//  The executable's entry point. Top-level code, deliberately NOT `@main`, so the binary links on
//  Linux as well as macOS. See docs/API_CONTRACT.md §4.12 (R-41) and docs/ARCHITECTURE.md §4.2
//  Rule 3.
//

#if os(macOS)

// `VigilApp` carries no `@main` attribute, and this call is exactly what `@main` would synthesise.
// Two reasons, both load-bearing:
//
//   1. `@main` cannot be conditionally compiled away. With `@main` on `VigilApp` and the whole of
//      `VigilApp.swift` inside `#if os(macOS)`, a Linux build produces an executable target with
//      no entry point at all and the link fails — which would take the whole package's Linux
//      build down, not just this target.
//   2. A file named `main.swift` is top-level code, and top-level code plus `@main` in the same
//      module is a compile error ("'main' attribute cannot be used in a module that contains
//      top-level code"). Calling `.main()` explicitly is the documented way to have both.
//
// `App.main()` is declared on the `App` protocol as `public static func main()`.
VigilApp.main()

#else

import Foundation

// Linux compiles this target to an executable that refuses to run, rather than not compiling at
// all. That is what keeps a plain `swift build` green in the development container (see
// docs/ARCHITECTURE.md §4.2 Rule 3) while every SwiftUI, AppKit and VideoToolbox file above is
// preprocessed away to nothing.
FileHandle.standardError.write(Data("Vigil requires macOS 14.0 or later.\n".utf8))
exit(EXIT_FAILURE)

#endif  // os(macOS)
