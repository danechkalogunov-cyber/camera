//
//  DiscoverySceneView.swift
//  Vigil
//
//  The standalone discovery window. It drives the same scan model and discovery UI as the main
//  window sheet, then hands a chosen device to the existing credential flow.
//

#if os(macOS)

import AppKit
import SwiftUI

import VigilISAPI
import VigilProtocols
import VigilTransport
import VigilUI

@MainActor
struct DiscoverySceneView: View {

    @Bindable var session: AppSessionModel
    @Bindable var library: AppLibraryModel

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    @State private var scan: DiscoveryScanModel?

    var body: some View {
        Group {
            if let scan {
                VDiscoverySheet(
                    cameras: scan.cameras,
                    progress: scan.progress,
                    phase: scan.phase,
                    isScanning: scan.isScanning,
                    notice: scan.notice,
                    onChoose: { choose($0, from: scan) },
                    onActivate: { activate($0, in: scan) },
                    onToggleScan: { scan.toggle() },
                    onClose: close)
            } else {
                ProgressView()
                    .frame(width: 520, height: 460)
            }
        }
        .task { beginScanIfNeeded() }
        .onDisappear { scan?.stop() }
    }

    private func beginScanIfNeeded() {
        guard scan == nil else { return }
        var known = Set(library.cameras.map(\.host))
        if let host = session.camera?.host { known.insert(host) }
        known = known.filter { !$0.isEmpty }
        let model = DiscoveryScanModel(
            logger: session.dependencies.logger,
            knownAddresses: known,
            channelSummaries: library.channelSummaries)
        scan = model
        model.start()
    }

    private func choose(_ camera: VDiscoveredCamera, from model: DiscoveryScanModel) {
        session.form.host = camera.address
        session.form.validate(.host)
        session.pendingONVIFServiceURL = camera.onvifServiceURL
        if session.phase == .live {
            session.disconnect()
            session.form.password = ""
            session.form.clearDiagnosis()
        }
        model.stop()
        openWindow(id: SceneID.main)
        dismissWindow(id: SceneID.discovery)
    }

    private func close() {
        scan?.stop()
        dismissWindow(id: SceneID.discovery)
    }

    private func activate(_ camera: VDiscoveredCamera, in model: DiscoveryScanModel) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = vigilUIString("Activate camera")
        alert.informativeText = String(
            format: vigilUIString("Set the first admin password for %@."), camera.address)
        alert.addButton(withTitle: vigilUIString("Activate"))
        alert.addButton(withTitle: vigilUIString("Cancel"))

        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        password.placeholderString = vigilUIString("New camera password")
        let confirmation = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        confirmation.placeholderString = vigilUIString("Confirm password")
        let fields = NSStackView(views: [password, confirmation])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 360, height: 56)
        alert.accessoryView = fields

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard password.stringValue == confirmation.stringValue else {
            model.reportNotice(vigilUIString("The passwords do not match."))
            return
        }
        let proposed = password.stringValue
        if let failure = ActivationPasswordPolicy.validate(proposed) {
            model.reportNotice(activationPasswordMessage(for: failure))
            return
        }

        model.reportNotice(vigilUIString("Activating camera…"))
        Task { @MainActor in
            let configuration = ISAPIClient.Configuration()
            let client = ISAPIClient(
                endpoint: ISAPIEndpoint(host: camera.address),
                credential: Credential(account: "admin", secret: proposed),
                configuration: configuration,
                transport: URLSessionHTTPTransport(
                    configuration: configuration, logger: session.dependencies.logger),
                clock: session.dependencies.clock,
                logger: session.dependencies.logger)
            do {
                try await DeviceActivation.activate(password: proposed, using: client)
                model.start(address: camera.address)
                model.reportNotice(vigilUIString("Camera activated. You can add it now."))
            } catch let error as ISAPIError {
                session.dependencies.logger.notice(
                    .discovery, "device activation failed",
                    ["reason": error.userMessage, "code": error.diagnosticCode])
                model.reportNotice(
                    String(
                        format: vigilUIString("Could not activate camera: %@"),
                        vigilUIString(error.userMessage)))
            } catch {
                session.dependencies.logger.notice(.discovery, "device activation failed")
                model.reportNotice(vigilUIString("Could not activate camera."))
            }
        }
    }

    private func activationPasswordMessage(for failure: ActivationPasswordPolicy.Failure) -> String {
        switch failure {
        case .length:
            vigilUIString("Password must be 8–16 characters long.")
        case .complexity:
            vigilUIString("Password must use at least two of: lowercase, uppercase, digits, symbols.")
        case .containsUsername:
            vigilUIString("Password must not contain “admin”.")
        }
    }
}

#endif  // os(macOS)
