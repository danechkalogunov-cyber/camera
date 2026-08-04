//
//  VMotionGovernor.swift
//  Vigil
//
//  Thermal-pressure governor for decorative UI motion.
//

#if os(macOS)

import Foundation
import Observation

@MainActor
@Observable
final class VMotionGovernor {
    private(set) var allowsMotion = true

    /// The notification token, kept only so `deinit` can hand it back.
    ///
    /// ⚠️ `nonisolated(unsafe)`, because `deinit` on a `@MainActor` class is *not* main-actor
    /// isolated — an object can be released from any thread — and reading an isolated property
    /// there is an error: "main actor-isolated property 'observer' can not be referenced from a
    /// nonisolated context". The unsafety is nominal: the storage is written exactly once, in
    /// `init`, and read exactly once, in `deinit`, which by definition runs when no other reference
    /// to this object survives, so no two contexts can reach it.
    ///
    /// ⛔ AND NOT PLAIN `nonisolated`, however loudly 6.2.4 asks for it. It emits
    ///
    ///     warning: 'nonisolated(unsafe)' has no effect on property 'observer',
    ///              consider using 'nonisolated'
    ///
    /// and taking that advice does not build: `@Observable` rewrites this into a stored
    /// `_observer`, where the same attribute is "error: 'nonisolated' cannot be applied to mutable
    /// stored properties" — and the note attached to *that* error asks for `nonisolated(unsafe)`.
    /// The two diagnostics point at each other. The warning is the one that is wrong, and it costs
    /// one warning per build to ignore it.
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    init(center: NotificationCenter = .default) {
        refresh()
        observer = center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                      object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh(processInfo: ProcessInfo = .processInfo) {
        allowsMotion = processInfo.thermalState != .serious && processInfo.thermalState != .critical
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

#endif  // os(macOS)
