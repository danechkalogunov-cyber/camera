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
    /// ⚠️ `nonisolated`, because `deinit` on a `@MainActor` class is *not* main-actor isolated —
    /// an object can be released from any thread — and reading an isolated property there is an
    /// error: "main actor-isolated property 'observer' can not be referenced from a nonisolated
    /// context".
    ///
    /// Not `nonisolated(unsafe)`: 6.2.4 reports that the `(unsafe)` has no effect here and asks for
    /// the plain spelling. Either way the storage is written exactly once, in `init`, and read
    /// exactly once, in `deinit`, which by definition runs when no other reference to this object
    /// survives — there is no moment at which two contexts can touch it.
    private nonisolated var observer: (any NSObjectProtocol)?

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
