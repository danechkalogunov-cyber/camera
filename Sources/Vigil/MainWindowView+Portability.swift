//
//  MainWindowView+Portability.swift
//  Vigil
//
//  The two File-menu commands that move a configuration in and out: ⇧⌘I (import cameras from CSV)
//  and ⌥⌘E (export the configuration).
//  macOS-only. Implements docs/UX.md §8.5 and the ⇧⌘I / ⌥⌘E rows of §11.1.
//
//  ⛔ THE CODECS SHIPPED WITHOUT A DOOR. `CameraCSVImporter` and `ConfigurationArchiveCodec` are
//  written, tested — round-trip, dangling group members, quoted names, malformed rows — and were
//  reachable from nothing at all: no menu item, no key, no button. A parser nobody can hand a file
//  to is a test fixture, and it was one for as long as it has existed.
//
//  ⚠️ WHAT IS HERE IS THE PANEL, NOT THE WHOLE OF §8.5. That section also specifies a dry-run
//  preview table with editable cells, delimiter sniffing (`;` and tab), CP1251 for exports from
//  Russian VMS tools, and an encrypted `.vigilconfig` for exports that include passwords. None of
//  that is here: the importer takes UTF-8 RFC 4180 with a `host` column, and the export writes the
//  archive JSON, which never contains a password to begin with. The report after an import says
//  exactly what happened — added, skipped as duplicates, and the reason a file was refused — so the
//  gap is visible to the user rather than silent, and ЧТО-НЕ-СДЕЛАНО carries the rest.
//

#if os(macOS)

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

import VigilCore
import VigilProtocols
import VigilUI

extension MainWindowView {

    // MARK: - ⇧⌘I, import

    /// Asks for a CSV file and adds the cameras it names.
    ///
    /// Duplicates are skipped rather than merged, and the rule is `host` + `channel` — the pair
    /// UX.md §8.5 names, and the right one: the same address on two channels is two cameras on an
    /// NVR, while the same address on the same channel twice is the same camera listed twice.
    func importCamerasFromCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = Self.localized("Choose a CSV file with a header row and a host column.")
        panel.prompt = Self.localized("Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let parsed: [Camera]
        do {
            parsed = try CameraCSVImporter.decode(try Data(contentsOf: url))
        } catch {
            window.toast = MainWindowToast(
                kind: .error,
                message: String(format: Self.localized("Could not read that CSV: %@"),
                                Self.describe(error)))
            return
        }
        guard !parsed.isEmpty else {
            window.toast = MainWindowToast(kind: .warning,
                                           message: Self.localized("That file listed no cameras."))
            return
        }
        Task { await addImportedCameras(parsed) }
    }

    /// Adds the rows that are not already in the library, and reports both numbers.
    ///
    /// ⚠️ The count is reported even when it is zero, because "18 cameras, all already here" and
    /// "18 cameras added" are different outcomes and a silent import cannot be told apart from a
    /// failed one.
    private func addImportedCameras(_ cameras: [Camera]) async {
        var added = 0
        var duplicates = 0
        for camera in cameras {
            let exists = library.cameras.contains {
                $0.host == camera.host && $0.channel == camera.channel
            }
            guard !exists else {
                duplicates += 1
                continue
            }
            await library.add(camera)
            added += 1
        }
        window.toast = MainWindowToast(
            kind: added > 0 ? .success : .warning,
            message: String(format: Self.localized("Import finished — added %lld, already here %lld"),
                            added, duplicates))
    }

    // MARK: - ⌥⌘E, export

    /// Writes the library and the groups to a file the user chooses.
    ///
    /// ⛔ No passwords, and not by omission: `Camera` carries a `CredentialRef`, which is a UUID
    /// naming a Keychain item, and the secret itself never enters the record. UX.md §8.5 offers an
    /// encrypted bundle that *does* include passwords; this writes the plain archive, so the file is
    /// safe to email and useless to an attacker who takes it. The sheet that offers the encrypted
    /// variant is the part that is not here.
    func exportConfiguration() {
        let archive = VigilConfigurationArchive(cameras: library.cameras, groups: groups.groups)
        let data: Data
        do {
            data = try ConfigurationArchiveCodec.encode(archive)
        } catch {
            window.toast = MainWindowToast(
                kind: .error,
                message: String(format: Self.localized("Could not build the export: %@"),
                                Self.describe(error)))
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "vigil-configuration.json"
        panel.message = Self.localized("The export lists cameras and groups. It holds no passwords.")
        panel.prompt = Self.localized("Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
            window.toast = MainWindowToast(
                kind: .success,
                message: String(format: Self.localized("Exported cameras: %lld"),
                                archive.cameras.count),
                actionTitle: "Reveal in Finder",
                action: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        } catch {
            window.toast = MainWindowToast(
                kind: .error,
                message: String(format: Self.localized("Could not write the export: %@"),
                                Self.describe(error)))
        }
    }

    // MARK: - ⌥⌘D, Stream Doctor

    /// Runs the credential-free connection test against the camera on screen (UX.md §11.1).
    ///
    /// The same prefix the connect form's `Test` button runs — TCP 80 and 554, then RTSP `OPTIONS`
    /// — which until now could only be reached *before* connecting, from a form the user leaves as
    /// soon as a picture appears. That is the wrong moment: a stream that has started misbehaving is
    /// when someone wants to know whether the camera still answers, and by then the form is gone.
    func runStreamDoctor() {
        guard let camera = session.camera else {
            window.toast = MainWindowToast(kind: .warning,
                                           message: Self.localized("Connect a camera first"))
            return
        }
        window.toast = MainWindowToast(kind: .info,
                                       message: Self.localized("Checking the camera's ports…"))
        session.testConnection(ConnectRequest(host: camera.host,
                                              username: session.form.request.username,
                                              password: "",
                                              httpPort: camera.httpPort,
                                              rtspPort: camera.rtspPort,
                                              channel: camera.channel.value,
                                              usesTLS: camera.useTLS))
    }

    // MARK: - Private Helpers

    /// The user-facing half of an error, without leaking a Swift type name into a toast.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case CameraCSVImporter.Failure.missingHostColumn:
            return localized("no host column in the header row")
        case CameraCSVImporter.Failure.emptyDocument:
            return localized("the file is empty or not UTF-8 text")
        case let CameraCSVImporter.Failure.malformedRow(row):
            return String(format: localized("row %lld has the wrong number of columns"), row)
        case let CameraCSVImporter.Failure.invalidInteger(row, column):
            return String(format: localized("row %lld, column %@ is not a number"), row, column)
        case let CameraCSVImporter.Failure.invalidBoolean(row, column):
            return String(format: localized("row %lld, column %@ is not yes or no"), row, column)
        default:
            return (error as NSError).localizedDescription
        }
    }
}

#endif  // os(macOS)
