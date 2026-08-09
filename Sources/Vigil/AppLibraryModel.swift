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
import VigilISAPI
import VigilProtocols
import VigilUI

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

    /// Prevents the main window and wall, which can appear together, from opening the store twice.
    private var isLoading = false

    // MARK: - Stored Properties

    private let logger: any LoggerProtocol

    /// `nil` when the store could not be built at all — see the file header on why that is survivable.
    private let library: CameraLibrary?

    /// Where `library.json` and its backup live, or `nil` when the directory could not be resolved.
    ///
    /// Exposed so the window's notice can carry a *Reveal in Finder* action, which FEATURES.md
    /// §F-INV-01 acceptance 3 names by name. A sentence telling a user their camera list was damaged
    /// and not showing them where it is asks them to go and find it.
    private(set) var storeDirectory: URL?

    // MARK: - Initialisation

    /// Builds the model. Nothing is read from disk until ``load(importingLegacyFrom:)``.
    init(logger: any LoggerProtocol) {
        self.logger = logger
        do {
            let directory = try LibraryStore.applicationSupportDirectory()
            self.storeDirectory = directory
            let store = LibraryStore(directory: directory, logger: logger)
            self.library = CameraLibrary(store: store, logger: logger)
        } catch {
            logger.error(.storage, "no camera library: \(error)")
            self.storeDirectory = nil
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
        guard !hasLoaded, !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
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
        guard let library else { return nil }
        // ⛔ Said, not swallowed. A read-only library refuses every write, and this one is reached by
        // an ordinary act — the first frame from a camera the user just connected to files it here.
        // Returning `nil` in silence meant the camera streamed, worked, and then was not in the list
        // next launch with nothing having mentioned it.
        guard !isReadOnly else {
            notice = vigilUIString("This camera list is read-only, so the camera was not saved. "
                                   + "It will not be here next time Vigil starts.")
            logger.error(.storage, "add refused: the library is read-only")
            return nil
        }
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

    /// Adds one library camera per enabled NVR input and records the authoritative inventory.
    /// The first record retains the connect form's identity; subsequent records share its
    /// Keychain handle and device settings but receive fresh stable identifiers.
    @discardableResult
    func addNVRChannels(_ channels: [VigilISAPI.DeviceChannel], from camera: Camera) async -> [Camera] {
        let available = channels.filter(\.isEnabled).sorted { $0.channel < $1.channel }
        guard !available.isEmpty else { return [] }
        var added: [Camera] = []
        for (offset, channel) in available.enumerated() {
            var copy = camera
            if offset > 0 { copy.id = CameraID(); copy.createdAt = Date(); copy.lastSeenAt = nil }
            copy.channel = channel.channel
            copy.name = channel.displayName
            if let stored = await add(copy) { added.append(stored) }
        }
        if let owner = added.first, let library {
            do {
                try await library.recordChannelInventory(for: owner.id, deviceChannels: channels)
                await refresh()
            } catch {
                logger.error(.storage, "could not record NVR channel inventory: \(error)")
            }
        }
        return added
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

    /// Replaces the whole camera list in one library transaction after an import was confirmed.
    func replace(with cameras: [Camera]) async throws {
        guard let library, !isReadOnly else { throw ImportFailure.readOnly }
        try await library.replaceCameras(cameras)
        await refresh()
    }

    enum ImportFailure: Error { case readOnly }

    /// Duplicates a camera next to its source and returns the new record for selection/editing.
    @discardableResult
    func duplicate(_ id: CameraID) async -> Camera? {
        guard let library, !isReadOnly else { return nil }
        do {
            let copy = try await library.duplicate(id)
            await refresh()
            return copy
        } catch {
            notice = vigilUIString("That camera could not be duplicated.")
            logger.error(.storage, "duplicate failed: \(error)")
            return nil
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

    /// Moves a camera before a row in the library's pre-move ordering.
    func move(_ id: CameraID, before destination: Int) async {
        guard let library, !isReadOnly,
              let source = cameras.firstIndex(where: { $0.id == id }) else { return }
        do {
            _ = try await library.moveCameras(fromOffsets: IndexSet(integer: source),
                                              toOffset: destination)
            await refresh()
        } catch {
            logger.error(.storage, "camera reorder failed: \(error)")
        }
    }

    /// Persists whether a camera participates in automatic connections.
    func setEnabled(_ enabled: Bool, for id: CameraID) async {
        guard let library, !isReadOnly else { return }
        do {
            _ = try await library.setEnabled(enabled, for: id)
            await refresh()
        } catch {
            logger.error(.storage, "set enabled failed: \(error)")
        }
    }

    /// Persists the chosen identity colour (`nil` means automatic).
    func setColorTag(_ tag: ColorTag, for id: CameraID) async {
        guard let library, !isReadOnly else { return }
        do {
            _ = try await library.setColorTag(tag, for: id)
            await refresh()
        } catch {
            logger.error(.storage, "set colour tag failed: \(error)")
        }
    }

    /// Clears a notice the user has read.
    func dismissNotice() { notice = nil }

    // MARK: - Private Helpers

    private func refresh() async {
        guard let library else { return }
        cameras = await library.cameras()
        IntentCameraIndex.save(cameras)
    }
}

#endif  // os(macOS)
