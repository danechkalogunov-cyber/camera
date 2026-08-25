//
//  MainWindowView+Sheets.swift
//  Vigil
//
//  The form behind whichever sheet the main window has up. Split out of `WindowSheets.swift` when
//  that file crossed the 600-line ceiling API_CONTRACT.md §7.2 sets; the sheet types themselves stay
//  in `WindowSheets.swift`, this is only the `switch` that chooses between them. macOS-only.
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilCore
import VigilProtocols
import VigilUI

// MARK: - The window's sheets

/// ⚠️ `internal` rather than `private`, for the reason given in `MainWindowView+Library.swift`:
/// `private` reaches a type's extensions only within one file.
///
/// Moved out of `MainWindowView.swift` when that file crossed the 600-line ceiling
/// API_CONTRACT.md §7.2 sets — and which `Scripts/lint.py` now enforces, which is how the crossing
/// was noticed at all. The sheets it presents are the four types below, so this is where it belongs.
extension MainWindowView {

    /// The form behind whichever sheet is up.
    ///
    /// One `switch` rather than five `.sheet(isPresented:)` modifiers stacked on the same view:
    /// SwiftUI presents only one of those and drops the rest silently, so two that could both be
    /// true is a bug waiting for a fast double-click. `MainWindowSheet` makes that unrepresentable.
    @ViewBuilder
    func sheetBody(_ sheet: MainWindowSheet) -> some View {
        switch sheet {
        case .cameraSettings:
            CameraSettingsSheet(
                name: identity.name,
                groupID: groups.group(for: cameraID),
                showsOverlay: window.showsVideoOverlay,
                isEnabled: selectedCamera?.isEnabled ?? true,
                colorTag: selectedCamera?.colorTag ?? .none,
                transport: selectedCamera?.transport ?? .tcpInterleaved,
                host: identity.host,
                httpPort: selectedCamera?.httpPort ?? 80,
                model: deviceInfo.identity.model,
                groups: groups.groups,
                onSave: { name, group, overlay, enabled, colorTag, transport in
                    renameCamera(to: name)
                    updateCameraMetadata(isEnabled: enabled, colorTag: colorTag)
                    updateCameraTransport(transport)
                    groups.setGroup(group, for: cameraID)
                    window.showsVideoOverlay = overlay
                    session.rememberVideoOverlay(overlay)
                    window.sheet = nil
                },
                onCancel: { window.sheet = nil })
        case .newGroup:
            GroupNameSheet(
                isNew: true,
                onSave: { name in
                    // The camera goes in as the group is created. A user who makes a
                    // group while looking at a camera means that camera to be in it.
                    groups.create(named: name, cameras: [cameraID])
                    window.sheet = nil
                },
                onCancel: { window.sheet = nil })
        case .renameGroup(let id):
            GroupNameSheet(
                name: groups.groups.first { $0.id == id }?.name ?? "",
                isNew: false,
                onSave: { name in
                    groups.rename(id, to: name)
                    window.sheet = nil
                },
                onCancel: { window.sheet = nil })
        case .newBookmark(let instant):
            BookmarkSheet(
                instant: instant,
                isNew: true,
                onSave: { title, note in
                    bookmarks.add(
                        cameraID: cameraID,
                        instant: instant,
                        title: title,
                        note: note)
                    window.sheet = nil
                },
                onCancel: { window.sheet = nil })
        case .editBookmark(let id):
            let record = bookmarks.bookmarks.first { $0.id == id }
            BookmarkSheet(
                title: record?.title ?? "",
                note: record?.note ?? "",
                instant: record?.instant ?? Date(),
                isNew: false,
                onSave: { title, note in
                    bookmarks.update(id, title: title, note: note)
                    window.sheet = nil
                },
                onCancel: { window.sheet = nil })
        case .shortcuts:
            VShortcutsSheet(sections: VShortcutReference.sections) { window.sheet = nil }
        case .csvImport:
            if let preview = window.csvImportPreview {
                CSVImportPreviewSheet(
                    preview: preview,
                    onImport: { rows in
                        window.sheet = nil
                        window.csvImportPreview = nil
                        importPreviewRows(rows)
                    },
                    onCancel: {
                        window.sheet = nil
                        window.csvImportPreview = nil
                    })
            }
        case .streamDoctor:
            StreamDoctorSheet(
                cameraName: window.streamDoctorCameraName,
                outcomes: window.streamDoctorOutcomes,
                failures: window.streamDoctorFailures,
                details: window.streamDoctorDetails,
                isRunning: window.isStreamDoctorRunning,
                onCopy: copyStreamDoctorReport,
                onRunAgain: runStreamDoctor,
                onClose: {
                    window.streamDoctorTask?.cancel()
                    window.sheet = nil
                })
        case .saveLayoutPreset:
            LayoutPresetNameSheet(
                onSave: { name in
                    window.layoutPresets.save(
                        VLayoutPreset(
                            name: name, layout: window.layout,
                            cameraIDs: stageAssignment.visibleCameras.map { $0.rawValue.uuidString }))
                    window.sheet = nil
                },
                onCancel: { window.sheet = nil })
        case .manageLayoutPresets:
            LayoutPresetManagerSheet(
                collection: window.layoutPresets,
                onSave: { collection in
                    window.layoutPresets = collection
                    window.sheet = nil
                },
                onCancel: { window.sheet = nil })
        }
    }
}

#endif  // os(macOS)
