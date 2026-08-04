//
//  StreamLifecycleMonitor.swift
//  Vigil
//
//  Converts network and workspace lifecycle changes into immediate stream recovery.
//

#if os(macOS)

import AppKit
import Network

/// Converts network and workspace lifecycle changes into immediate stream recovery requests.
@MainActor
final class StreamLifecycleMonitor {
    private let pathMonitor: NWPathMonitor
    private var observers: [NSObjectProtocol] = []
    private var wasSatisfied = true
    private var reconnect: (@MainActor () -> Void)?

    init(pathMonitor: NWPathMonitor = NWPathMonitor()) { self.pathMonitor = pathMonitor }

    func start(reconnect: @escaping @MainActor () -> Void) {
        self.reconnect = reconnect
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let satisfied = path.status == .satisfied
                if satisfied, !wasSatisfied { reconnect() }
                wasSatisfied = satisfied
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "camera.vigil.network-path"))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reconnect?() }
        })
    }

    func stop() {
        pathMonitor.cancel()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.forEach(workspace.removeObserver)
        observers.removeAll()
        reconnect = nil
    }

    deinit { pathMonitor.cancel() }
}

#endif
