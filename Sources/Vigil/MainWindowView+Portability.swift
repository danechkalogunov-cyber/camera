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
//  The same door also accepts a password-free library JSON document and the authenticated
//  `.vigilbackup` container. Encrypted input is decoded and authenticated before the confirmation
//  is shown; only after confirmation are Keychain items and the atomic library replacement touched.
//

#if os(macOS)

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

import VigilCore
import VigilProtocols
import VigilUI

private extension UTType {
    static let vigilBackup = UTType(exportedAs: "com.vigil.backup", conformingTo: .data)
    static let vigilLibraryJSON = UTType(exportedAs: "com.vigil.library-json", conformingTo: .json)
}

extension MainWindowView {

    // MARK: - ⇧⌘I, import

    /// Opens CSV, plain JSON, or an authenticated encrypted backup.
    ///
    /// Duplicates are skipped rather than merged, and the rule is `host` + `channel` — the pair
    /// UX.md §8.5 names, and the right one: the same address on two channels is two cameras on an
    /// NVR, while the same address on the same channel twice is the same camera listed twice.
    func importCamerasFromCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.vigilBackup, .vigilLibraryJSON, .json,
                                     .commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = Self.localized("Choose a camera list or Vigil backup to restore.")
        panel.prompt = Self.localized("Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if url.pathExtension.lowercased() == "vigilbackup" {
            restoreEncryptedConfiguration(from: url)
            return
        }
        if ["json", "vigiljson", "vigilconfig"].contains(url.pathExtension.lowercased()) {
            restorePlainConfiguration(from: url)
            return
        }

        let preview: CameraCSVImporter.Preview
        do {
            preview = try CameraCSVImporter.preview(try Data(contentsOf: url))
        } catch {
            window.toast = MainWindowToast(
                kind: .error,
                message: String(format: Self.localized("Could not read that CSV: %@"),
                                Self.describe(error)))
            return
        }
        guard !preview.rows.isEmpty else {
            window.toast = MainWindowToast(kind: .warning,
                                           message: Self.localized("That file listed no cameras."))
            return
        }
        window.csvImportPreview = preview
        window.sheet = .csvImport
    }

    private func restorePlainConfiguration(from url: URL) {
        let archive: VigilConfigurationArchive
        do { archive = try ConfigurationArchiveCodec.decode(Data(contentsOf: url)) } catch {
            reportImportFailure(error)
            return
        }
        guard confirmRestore(cameraCount: archive.cameras.count, includesCredentials: false) else {
            return
        }
        Task { await applyRestoredArchive(archive, credentials: []) }
    }

    private func restoreEncryptedConfiguration(from url: URL) {
        let container: Data
        do { container = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            reportImportFailure(error)
            return
        }
        let alert = NSAlert()
        alert.messageText = Self.localized("Unlock the Vigil backup")
        alert.informativeText = Self.localized(
            "Enter the passphrase used when this encrypted backup was created.")
        let passphraseField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        passphraseField.placeholderString = Self.localized("Backup passphrase")
        alert.accessoryView = passphraseField
        alert.addButton(withTitle: Self.localized("Unlock"))
        alert.addButton(withTitle: Self.localized("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let passphrase = passphraseField.stringValue
        Task {
            do {
                let payload = try await Task.detached(priority: .userInitiated) {
                    try EncryptedConfigurationCodec.decode(container, passphrase: passphrase)
                }.value
                guard confirmRestore(cameraCount: payload.archive.cameras.count,
                                     includesCredentials: true) else { return }
                await applyRestoredArchive(payload.archive, credentials: payload.credentials)
            } catch {
                reportImportFailure(error)
            }
        }
    }

    private func confirmRestore(cameraCount: Int, includesCredentials: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = Self.localized("Replace the current configuration?")
        let detail = includesCredentials
            ? Self.localized("Camera settings, groups, and saved passwords will be restored.")
            : Self.localized("Camera settings and groups will be restored. Passwords are not in this file.")
        alert.informativeText = "\(cameraCount) "
            + Self.localized("cameras will replace the current configuration. ") + detail
        alert.addButton(withTitle: Self.localized("Replace Configuration"))
        alert.addButton(withTitle: Self.localized("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func applyRestoredArchive(
        _ archive: VigilConfigurationArchive,
        credentials: [EncryptedConfigurationPayload.StoredCredential]
    ) async {
        do {
            // Write credentials first: camera records are not made active until every Keychain
            // item succeeds. A failure therefore leaves the current configuration untouched.
            let byID = Dictionary(uniqueKeysWithValues: archive.cameras.map { ($0.id, $0) })
            for stored in credentials {
                guard let camera = byID[stored.cameraID] else {
                    throw EncryptedConfigurationCodec.Failure.damaged
                }
                let credential = Credential(ref: stored.ref, account: stored.account,
                                            secret: stored.secret)
                try await session.credentials.save(
                    credential, descriptor: CredentialDescriptor(camera: camera,
                                                                  account: stored.account))
            }
            try await library.replace(with: archive.cameras)
            groups.replace(with: archive.groups)
            window.toast = MainWindowToast(kind: .success,
                                           message: Self.localized("Configuration restored."))
        } catch {
            reportImportFailure(error)
        }
    }

    private func reportImportFailure(_ error: any Error) {
        let message: String
        switch error {
        case EncryptedConfigurationCodec.Failure.wrongPassphrase:
            message = Self.localized("That passphrase didn't work.")
        case EncryptedConfigurationCodec.Failure.damaged:
            message = Self.localized("This backup file is damaged.")
        case EncryptedConfigurationCodec.Failure.weakPassphrase:
            message = Self.localized("The passphrase must contain at least 12 characters.")
        default:
            message = String(format: Self.localized("Could not import that configuration: %@"),
                             Self.describe(error))
        }
        window.toast = MainWindowToast(kind: .error, message: message)
    }

    /// Adds the rows that are not already in the library, and reports both numbers.
    ///
    /// ⚠️ The count is reported even when it is zero, because "18 cameras, all already here" and
    /// "18 cameras added" are different outcomes and a silent import cannot be told apart from a
    /// failed one.
    func addImportedCameras(_ cameras: [Camera]) async {
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

    /// Asks exactly once per distinct host/account pair, then applies credentials, cameras and CSV
    /// group names. Passwords live only in the secure fields, this dictionary and Keychain; they are
    /// never added to the preview model or written back beside the source CSV.
    func importPreviewRows(_ rows: [CameraCSVImporter.PreviewRow]) {
        struct AccountPair: Hashable, Sendable {
            let host: String
            let username: String
        }
        let newRows = rows.filter { row in
            guard let camera = row.camera else { return false }
            return !library.cameras.contains {
                $0.host == camera.host && $0.channel == camera.channel
            }
        }
        let pairs = Set(newRows.compactMap { row -> AccountPair? in
            guard let camera = row.camera,
                  let username = row.username?.trimmingCharacters(in: .whitespaces),
                  !username.isEmpty else { return nil }
            return AccountPair(host: camera.host.lowercased(), username: username)
        }).sorted { ($0.host, $0.username) < ($1.host, $1.username) }

        var passwords: [AccountPair: String] = [:]
        for pair in pairs {
            let alert = NSAlert()
            alert.messageText = Self.localized("Password for imported camera")
            alert.informativeText = String(
                format: Self.localized("Enter the password for %1$@ on %2$@, or skip it for now."),
                pair.username, pair.host)
            let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0,
                                                                 width: 360, height: 24))
            passwordField.placeholderString = Self.localized("Camera password")
            alert.accessoryView = passwordField
            alert.addButton(withTitle: Self.localized("Save Password"))
            alert.addButton(withTitle: Self.localized("Skip"))
            if alert.runModal() == .alertFirstButtonReturn, !passwordField.stringValue.isEmpty {
                passwords[pair] = passwordField.stringValue
            }
        }

        Task {
            for row in newRows {
                guard let camera = row.camera,
                      let username = row.username?.trimmingCharacters(in: .whitespaces),
                      !username.isEmpty else { continue }
                let pair = AccountPair(host: camera.host.lowercased(), username: username)
                guard let password = passwords[pair] else { continue }
                do {
                    try await session.credentials.save(
                        Credential(ref: camera.credentialRef, account: username, secret: password),
                        descriptor: CredentialDescriptor(camera: camera, account: username))
                } catch {
                    window.toast = MainWindowToast(
                        kind: .error,
                        message: String(format: Self.localized("Could not save an imported password: %@"),
                                        Self.describe(error)))
                    return
                }
            }
            await addImportedCameras(rows.compactMap(\.camera))
            for row in newRows {
                guard let camera = row.camera,
                      let name = row.groupName?.trimmingCharacters(in: .whitespaces),
                      !name.isEmpty else { continue }
                let groupID = groups.groups.first {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                }?.id ?? groups.create(named: name)
                if let importedID = library.cameras.first(where: {
                    $0.host == camera.host && $0.channel == camera.channel
                })?.id {
                    groups.setGroup(groupID, for: importedID)
                }
            }
        }
    }

    // MARK: - ⌥⌘E, export

    /// Offers a shareable password-free JSON file or an authenticated encrypted backup containing
    /// Keychain credentials.
    func exportConfiguration() {
        let choice = NSAlert()
        choice.messageText = Self.localized("Export Configuration")
        choice.informativeText = Self.localized(
            "Choose encrypted backup to move cameras and passwords to another Mac, "
            + "plain JSON for a complete editable configuration, or CSV for a camera list.")
        choice.addButton(withTitle: Self.localized("Encrypted Backup…"))
        choice.addButton(withTitle: Self.localized("Plain JSON"))
        choice.addButton(withTitle: Self.localized("Camera List CSV"))
        choice.addButton(withTitle: Self.localized("Cancel"))
        switch choice.runModal() {
        case .alertFirstButtonReturn:
            exportEncryptedConfiguration()
            return
        case .alertSecondButtonReturn:
            break
        case .alertThirdButtonReturn:
            exportCSVConfiguration()
            return
        default:
            return
        }
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
        panel.allowedContentTypes = [.vigilLibraryJSON]
        panel.nameFieldStringValue = "vigil-configuration.vigiljson"
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

    private func exportCSVConfiguration() {
        let cameras = library.cameras
        var groupNames: [CameraID: String] = [:]
        for group in groups.groups {
            for cameraID in group.members where groupNames[cameraID] == nil {
                groupNames[cameraID] = group.name
            }
        }
        Task {
            var usernames: [CameraID: String] = [:]
            for camera in cameras {
                if let credential = try? await session.credentials.credential(for: camera) {
                    usernames[camera.id] = credential.account
                }
            }
            saveCSVConfiguration(CameraCSVExporter.encode(cameras, groupNames: groupNames,
                                                          usernames: usernames),
                                 cameraCount: cameras.count)
        }
    }

    private func saveCSVConfiguration(_ data: Data, cameraCount: Int) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "vigil-cameras.csv"
        panel.message = Self.localized("The CSV contains camera settings and usernames, but no passwords.")
        panel.prompt = Self.localized("Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            window.toast = MainWindowToast(
                kind: .success,
                message: String(format: Self.localized("Exported cameras: %lld"), cameraCount),
                actionTitle: "Reveal in Finder",
                action: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        } catch {
            window.toast = MainWindowToast(
                kind: .error,
                message: String(format: Self.localized("Could not write the export: %@"),
                                Self.describe(error)))
        }
    }

    private func exportEncryptedConfiguration() {
        let alert = NSAlert()
        alert.messageText = Self.localized("Protect the backup with a passphrase")
        alert.informativeText = Self.localized(
            "Use at least 12 characters. You will need this passphrase to restore the passwords.")
        let secureField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        secureField.placeholderString = Self.localized("Passphrase (12 or more characters)")
        alert.accessoryView = secureField
        alert.addButton(withTitle: Self.localized("Continue"))
        alert.addButton(withTitle: Self.localized("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let passphrase = secureField.stringValue
        guard passphrase.count >= 12 else {
            window.toast = MainWindowToast(
                kind: .warning,
                message: Self.localized("The passphrase must contain at least 12 characters."))
            return
        }

        let cameras = library.cameras
        let groups = groups.groups
        Task {
            var stored: [EncryptedConfigurationPayload.StoredCredential] = []
            for camera in cameras {
                guard let credential = try? await session.credentials.credential(for: camera) else {
                    continue
                }
                stored.append(.init(cameraID: camera.id, ref: credential.ref,
                                    account: credential.account, secret: credential.secret))
            }
            let payload = EncryptedConfigurationPayload(
                archive: VigilConfigurationArchive(cameras: cameras, groups: groups),
                credentials: stored)
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try EncryptedConfigurationCodec.encode(payload, passphrase: passphrase)
                }.value
                saveEncryptedConfiguration(data, cameraCount: cameras.count)
            } catch {
                window.toast = MainWindowToast(
                    kind: .error,
                    message: String(format: Self.localized("Could not build the export: %@"),
                                    Self.describe(error)))
            }
        }
    }

    private func saveEncryptedConfiguration(_ data: Data, cameraCount: Int) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.vigilBackup]
        panel.nameFieldStringValue = "vigil-configuration.vigilbackup"
        panel.message = Self.localized(
            "This encrypted backup contains camera passwords. Keep its passphrase separately.")
        panel.prompt = Self.localized("Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            window.toast = MainWindowToast(
                kind: .success,
                message: String(format: Self.localized("Exported cameras: %lld"), cameraCount),
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
        case CameraCSVImporter.Failure.unsupportedTextEncoding:
            return localized("the file is not UTF-8 or Windows-1251 text")
        case let CameraCSVImporter.Failure.malformedRow(row):
            return String(format: localized("row %lld has the wrong number of columns"), row)
        case let CameraCSVImporter.Failure.invalidInteger(row, column):
            return String(format: localized("row %lld, column %@ is not a number"), row, column)
        case let CameraCSVImporter.Failure.invalidBoolean(row, column):
            return String(format: localized("row %lld, column %@ is not yes or no"), row, column)
        case let CameraCSVImporter.Failure.invalidCamera(row, reason):
            return String(format: localized("row %@ is not a valid camera: %@"),
                          String(row), reason)
        default:
            return (error as NSError).localizedDescription
        }
    }
}

#endif  // os(macOS)
