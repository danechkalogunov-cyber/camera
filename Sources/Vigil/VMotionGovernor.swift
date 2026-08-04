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
    private var observer: NSObjectProtocol?

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
