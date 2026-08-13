//
//  MainWindowView+ClipExport.swift
//  Vigil
//
//  In/out commands and the sandbox save-panel handoff for F-PLB-04.
//

#if os(macOS)

import AppKit
import Foundation
import UniformTypeIdentifiers

import VigilProtocols

extension MainWindowView {
    var currentExportRange: Range<Date>? {
        guard session.clipExport.selectionCameraID == selectedCamera?.id else { return nil }
        return session.clipExport.selection.range
    }

    func setClipExportInPoint() {
        guard let camera = selectedCamera,
              let instant = archive.archive?.playhead else { return }
        session.clipExport.setIn(instant, camera: camera.id)
    }

    func setClipExportOutPoint() {
        guard let camera = selectedCamera,
              let instant = archive.archive?.playhead else { return }
        session.clipExport.setOut(instant, camera: camera.id)
    }

    func exportSelectedClip() {
        guard !session.clipExport.isExporting,
              let camera = selectedCamera,
              currentExportRange != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(exportFileStem(camera.displayName)).mp4"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            session.clipExport.start(
                camera: camera,
                destination: destination,
                maskedSerial: ClipExportCoordinator.mask(
                    serial: deviceInfo.identity.serialNumber),
                appSession: session)
        }
    }

    /// Uses macOS's native sharing picker so an exported clip can go straight to Telegram, Mail,
    /// AirDrop and any other installed sharing extension instead of only being saved in Finder.
    func shareExportedClip(_ url: URL) {
        let picker = NSSharingServicePicker(items: [url])
        guard let view = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else {
            return
        }
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }

    func exportFileStem(_ cameraName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safe = cameraName.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }
        let name = String(safe).split(separator: "-").joined(separator: "-")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: Date())
        return "\(name.isEmpty ? "camera" : name)_\(stamp)"
    }
}

#endif
