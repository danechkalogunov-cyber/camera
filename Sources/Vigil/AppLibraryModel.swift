//
//  AppLibraryModel.swift
//  Vigil
//
//  The camera library, as the window sees it: a list, and the four things that change it.
//  macOS-only. Wraps `VigilCore.CameraLibrary`; see docs/spec-core.md §5.
//
//  ⛔ THIS IS THE ONLY PLACE THE APP TOUCHES `library.json`. Everything below it — the atomic write,
//  the backup rotation, the schema migrations, the corruption quarantine — is `CameraLibrary`'s and
//  is already written and tested. What was missing was anybody calling it: the app has been running
//  on a single `LastConnection` in `UserDefaults` this whole time, which is why it can hold exactly
//  one camera.
//
//  ⚠️ A FAILURE TO OPEN THE LIBRARY IS NOT FATAL AND MUST NOT BE. A Mac with no writable Application
//  Support, a document written by a newer Vigil, a file someone chmod'ed — none of those is a reason
//  to refuse to show video. In every one of them this model degrades to an empty, read-only list and
//  the app keeps working exactly as it did before the library existed.
//

#if os(macOS)

import Foundation
import Observation

import VigilCore
import VigilProtocols

// MARK: - AppLibraryModel

/// Every camera the user has added, and the operations that change that set.
@MainActor
@Observable
final class AppLibraryModel {

    // MARK: - Observable State

    /// The library, in the order the user arranged it.
    private(set) var cameras: [Camera] = []

    /// True when the document belongs to a newer Vigil. Nothing is written back in that state —
    /// downgrading a schema by writing an older one over it is how libraries get destroyed.
    private(set) var isReadOnly = false

    /// A sentence about a degraded or recovered load, or `nil` when there is nothing to say.
    private(set) var notice: String?

    /// True once `load()` has run, whatever the outcome. The sidebar waits for it rather than
    /// flashing an empty list at a user who has cameras.
    private(set) var hasLoaded = false

    // MARK: - Stored Properties

    private let logger: any LoggerProtocol

    /// `nil` when the store could not be built at all — see the file header on why that is survivable.
    private let library: CameraLibrary?

    // MARK: - Initialisation

    /// Builds the model. Nothing is read from disk until ``load(importingLegacyFrom:)``.
    init(logger: any LoggerProtocol) {
        self.logger = logger
        do {
            let directory = try LibraryStore.applicationSupportDirectory()
            let store = LibraryStore(directory: directory, logger: logger)
            self.library = CameraLibrary(store: store, logger: logger)
        } catch {
            logger.error(.storage, "no camera library: \(error)")
            self.library = nil
        }
    }

    // MARK: - Loading

    /// Opens `library.json`, adopting the prototype's single remembered camera if there is one.
    ///
    /// The import runs only against an **empty** library, and that is the whole of its safety: a
    /// user who has added cameras must never have the old single record injected back on top of
    /// them. `CameraLibrary.importLegacyConnection` carries the `CredentialRef` through unchanged,
    /// which is the difference between "the camera still works" and "type your password again".
    ///
    /// - Parameter defaults: the values `LastConnection` writes. Read here, on the main actor, and
    ///   passed down as a plain dictionary so a non-`Sendable` `UserDefaults` never crosses an
    ///   isolation boundary — which is exactly what that overload exists for.
    func load(importingLegacyFrom defaults: UserDefaults) async {
        defer { hasLoaded = true }
        guard let library else { return }

        let outcome = await library.load()
        switch outcome {
        case .created:
            logger.info(.storage, "camera library: new")
        case let .loaded(_, migrations, _):
            if !migrations.isEmpty {
                logger.notice(.storage, "camera library migrated: \(migrations.joined(separator: ", "))")
            }
        case let .recovered(_, from, error):
            // Said out loud. A silent recovery is how a user discovers weeks later that half their
            // cameras are gone and nothing ever mentioned it.
            notice = vigilUIString("Your camera list was damaged and has been restored from a backup. "
                                   + "Some recent changes may be missing.")
            logger.error(.storage, "camera library recovered from \(from): \(error)")
        case let .readOnly(_, futureVersion):
            isReadOnly = true
            notice = vigilUIString("This camera list was written by a newer version of Vigil. "
                                   + "It is being shown read-only so nothing is lost.")
            logger.error(.storage, "camera library is from a newer Vigil (v\(futureVersion))")
        }

        if await library.cameras().isEmpty, !isReadOnly {
            adoptLegacyRecord(from: defaults)
        }
        await refresh()
    }

    /// Brings the prototype's remembered camera into the library, once.
    private func adoptLegacyRecord(from defaults: UserDefaults) {
        guard let library else { return }
        let values = [
            LegacyLastConnection.hostKey: defaults.string(forKey: LegacyLastConnection.hostKey),
            LegacyLastConnection.accountKey: defaults.string(forKey: LegacyLastConnection.accountKey),
            LegacyLastConnection.credentialRefKey:
                defaults.string(forKey: LegacyLastConnection.credentialRefKey),
            LegacyLastConnection.rtspPathKey:
                defaults.string(forKey: LegacyLastConnection.rtspPathKey),
        ].compactMapValues { $0 }
        guard !values.isEmpty else { return }
        Task {
            do {
                if let imported = try await library.importLegacyConnection(fromDefaults: values) {
                    logger.info(.storage, "adopted the remembered camera into the library",
                                ["host": imported.camera.host])
                    await refresh()
                }
            } catch {
                // Not fatal: the app still has the remembered connection and still connects. The
                // only loss is that this camera is not in the list yet.
                logger.error(.storage, "could not adopt the remembered camera: \(error)")
            }
        }
    }

    // MARK: - Mutations

    /// Adds a camera and returns it as stored, or `nil` when the library refused it.
    @discardableResult
    func add(_ camera: Camera) async -> Camera? {
        guard let library, !isReadOnly else { return nil }
        do {
            let stored = try await library.add(camera)
            await refresh()
            logger.info(.storage, "camera added", ["host": stored.host])
            return stored
        } catch {
            notice = vigilUIString("That camera could not be added.")
            logger.error(.storage, "add failed: \(error)")
            return nil
        }
    }

    /// Removes a camera. Its Keychain item is **not** touched here — that belongs to whoever owns
    /// the credential, and deleting a password because a row disappeared is the kind of surprise
    /// that costs a user access to a device they still own.
    func remove(_ id: CameraID) async {
        guard let library, !isReadOnly else { return }
        do {
            _ = try await library.remove(id)
            await refresh()
        } catch {
            logger.error(.storage, "remove failed: \(error)")
        }
    }

    /// Renames a camera.
    func rename(_ id: CameraID, to name: String) async {
        guard let library, !isReadOnly else { return }
        do {
            _ = try await library.rename(id, to: name)
            await refresh()
        } catch {
            logger.error(.storage, "rename failed: \(error)")
        }
    }

    /// Clears a notice the user has read.
    func dismissNotice() { notice = nil }

    // MARK: - Private Helpers

    private func refresh() async {
        guard let library else { return }
        cameras = await library.cameras()
    }
}

#endif  // os(macOS)
