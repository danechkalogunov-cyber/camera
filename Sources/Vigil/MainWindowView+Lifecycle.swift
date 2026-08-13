//
//  MainWindowView+Lifecycle.swift
//  Vigil
//
//  The main window's `.task` and `.onChange` chain: what it starts, what it polls, and what it
//  does when something it does not own changes.
//  macOS-only. Supports Sources/Vigil/MainWindowView.swift.
//
//  ⛔ SPLIT OUT OF `body`, NOT FOR TIDINESS. As one expression the window's forty-odd modifiers hit
//
//      error: the compiler is unable to type-check this expression in reasonable time
//
//  because SwiftUI folds every modifier into one nested generic type and each closure adds another
//  batch of inference. Functions that each take a view and return one give the solver a handful of
//  small problems instead of one intractable one. The working budget is four or five modifiers per
//  function: a first attempt at eleven still failed to type-check, so "it looks short enough" is not
//  the test. Chaining these back together in `body` brings the error back.
//
//  ⚠️ `internal` rather than `private`: Swift scopes `private` to a file, so a member this type's
//  own `body` calls from the file next door cannot be private however local it looks.
//

#if os(macOS)

import AppKit
import Foundation
import SwiftUI

import VigilCore
import VigilUI

extension MainWindowView {

    // MARK: - Tasks

    /// The window's own lifecycle: everything that starts work, polls, or follows a camera.
    ///
    /// Four groups, composed here rather than in `body` so the window's own body stays a list of
    /// five names. Each `let` pins an opaque type the next call starts from.
    func windowTasks(_ content: some View) -> some View {
        let started = windowStartupTasks(content)
        let media = windowMediaTasks(started)
        let recording = windowRecordingTasks(media)
        return windowPanelTasks(recording)
    }

    /// What the window does once, when it appears: read the remembered chrome, ask AppKit about
    /// Full Keyboard Access, manage the cinema-mode cursor, and start the reconnect monitor.
    private func windowStartupTasks(_ content: some View) -> some View {
        content
        .task { window.showsVideoOverlay = session.remembersVideoOverlay }
        .task { eventFeed.restoreWatching(window.watchedCameraIDs) }
        .task {
            window.isFullKeyboardAccessEnabled = NSApp.isFullKeyboardAccessEnabled
        }
        .task(id: window.isCinemaMode) {
            if window.isCinemaMode {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, window.isCinemaMode, !cinemaCursorHidden else { return }
                NSCursor.hide()
                cinemaCursorHidden = true
            } else if cinemaCursorHidden {
                NSCursor.unhide()
                cinemaCursorHidden = false
            }
        }
        .task {
            streamLifecycle.start(
                suspendForSleep: { session.suspendForSystemSleep() },
                reconnect: { session.resumeAfterSystemSleep() })
            await withTaskCancellationHandler(operation: {
                try? await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
            }, onCancel: {
                Task { @MainActor in streamLifecycle.stop() }
            })
        }
        .onKeyPress(keys: [KeyEquivalent(Character("t"))], phases: [.down, .up]) { press in
            if press.phase == .down { beginPushToTalk() }
            else { session.twoWayAudio.end() }
            return .handled
        }
        .onDisappear { session.twoWayAudio.end() }
    }

    /// What a picture arriving — or stopping — means.
    ///
    /// The two `isReceivingMedia` observers are `onChange` rather than `task` and sit here anyway:
    /// they belong to this story, and both kinds are plain behaviour attachments, so which function
    /// carries them changes nothing about what runs.
    private func windowMediaTasks(_ content: some View) -> some View {
        content
        // ⚠️ The library is *not* loaded here any more — `RootView` does it at launch, so the
        // connect form and the scan see it too. Loading it again on this view's appearance would
        // re-run the legacy import against a library that may have just been populated by it.
        // Filed once a picture exists, which is the only moment Vigil knows the record is good for
        // anything. Adding at connect time would fill the list with addresses that never answered.
        .onChange(of: session.isReceivingMedia) { _, isReceiving in
            guard isReceiving else { return }
            Task { await session.reconcileCurrentCamera(with: library) }
        }
        .onChange(of: session.isReceivingMedia) { wasReceiving, isReceiving in
            guard wasReceiving, !isReceiving else { return }
            Task { await eventFeed.cameraLost(session.camera) }
        }
        .task(id: cycleTick) { await runCycle() }
        // Keyed on the camera's id, so a reconnect to the same device does not re-ask and a switch
        // to a different one does. `load` is cheap when the ISAPI session's TTL cache is warm.
        .task(id: selectedCamera?.id) {
            loadDeviceInfo()
        }
        .task(id: channelExpansionTrigger) {
            await expandRecorderChannelsIfNeeded()
        }
    }

    /// Turns an authenticated recorder inventory into one stable library row per enabled input.
    private var channelExpansionTrigger: String {
        "\(selectedCamera?.id.rawValue.uuidString ?? "-")/"
            + "\(deviceInfo.identity.totalChannels)/\(String(describing: deviceInfo.outcome))"
    }

    private func expandRecorderChannelsIfNeeded() async {
        guard let camera = selectedCamera,
              deviceInfo.identity.totalChannels > 1,
              let control = deviceInfo.session else { return }
        do {
            let channels = try await control.channels()
            guard channels.count > 1 || channels.contains(where: { $0.upstream != nil }) else {
                return
            }
            let before = library.cameras.filter {
                $0.host == camera.host && $0.httpPort == camera.httpPort
            }.count
            let records = await library.addNVRChannels(channels, from: camera)
            let created = max(0, records.count - before)
            if created > 0 {
                window.toast = MainWindowToast(
                    kind: .success,
                    message: Self.localized("Recorder channels were added to the camera list."))
            }
        } catch {
            session.dependencies.logger.notice(
                .isapi, "recorder channel enumeration failed",
                ["host": camera.host, "reason": String(describing: error)])
        }
    }

    /// Clips, telemetry, the poster frame and the event stream.
    private func windowRecordingTasks(_ content: some View) -> some View {
        content
        // Re-read whenever a clip finishes, so a recording appears in the list the moment it closes.
        .task(id: recording.completed.count) {
            vouchForFinishedClips()
            reloadClips()
        }
        .task(id: recording.isRecording) {
            // Also re-read on start, so the `.partial` file appears while it is being written
            // rather than only once the clip closes.
            reloadClips()
            await tickWhileRecording()
        }
        .task { await pollTelemetry() }
        .task(id: selectedCamera?.id) { await pollPoster() }
        .task(id: motionMonitorKey) {
            for camera in motionMonitoredCameras where isMotionRecordingArmed(camera.id) {
                await session.setMotionRecordingArmed(
                    true, for: camera,
                    preRollSeconds: motionRecordingConfiguration(camera.id).preRollSeconds)
            }
            await eventFeed.follow(cameras: motionMonitoredCameras,
                                   displaying: selectedCamera?.id)
        }
        .onChange(of: eventFeed.recordingTriggerRevision) { _, _ in
            for trigger in eventFeed.takeRecordingTriggers() {
                handleMotionRecordingTrigger(trigger)
            }
        }
        .onChange(of: eventFeed.unreadCount, initial: true) { _, count in
            window.unreadEventCount = count
        }
    }

    /// Work that only makes sense while a particular panel or screen is being looked at.
    private func windowPanelTasks(_ content: some View) -> some View {
        content
        // Looking at the feed is what marks it read. Anything else — a button, a per-row gesture —
        // leaves a badge that counts events the user has already seen, which is a badge nobody
        // believes after the first time.
        .task(id: isEventsScreenOpen) { await markEventsRead() }
        // Only when the Image tab is actually looked at: these are four HTTP reads per channel.
        .task(id: window.inspectorTab) { await loadImageIfShown() }
        // The capability read is cached for 24 h by the session, so re-running this on a tab change
        // costs nothing after the first time — and the coordinator ignores a repeat for the same
        // channel anyway.
        .task(id: deviceInfoReady) {
            followPTZ()
            if let camera = selectedCamera {
                await session.twoWayAudio.probe(camera: camera, deviceSession: deviceInfo.session)
            }
        }
        // The index is only worth reading when the Recordings screen is actually on the stage:
        // it is a paged search at the device and a camera with a full card answers slowly.
        .task(id: archiveTrigger) { await loadArchive() }
    }

    // MARK: - Reactions

    /// What the window does when something it does not own changes: a menu-bar counter, a
    /// coordinator's failure, a notice from the library.
    func windowReactions(_ content: some View) -> some View {
        let menu = windowMenuReactions(content)
        return windowFailureReactions(menu)
    }

    /// The menu bar's half of the bargain. `VigilCommands` is built above this window and cannot
    /// reach the coordinators these need, so it bumps a counter and the work happens here. See
    /// `MainWindowState.snapshotRequests` for why it is a counter and not a closure.
    private func windowMenuReactions(_ content: some View) -> some View {
        content
        // `initial: true` so a link that arrived during launch — before this window existed — is
        // performed the moment it does. That is §F-AUT-03 acceptance 5.
        .onChange(of: window.pendingDeepLink, initial: true) { _, _ in performPendingDeepLink() }
        .onChange(of: window.deferredRequest, initial: true) { _, request in
            guard let request else { return }
            window.deferredRequest = nil
            switch request {
            case .snapshotAll: snapshotAllEnabledCameras()
            case .recordToggle: toggleRecording()
            case .discover: onFindCameras()
            }
        }
        .onChange(of: window.isOverflowMenuOpen) { _, open in
            window.cycle = window.cycle.paused(open)
        }
        .onChange(of: window.snapshotRequests) { _, _ in takeSnapshot() }
        .onChange(of: window.recordToggleRequests) { _, _ in toggleRecording() }
        .onChange(of: window.findCamerasRequests) { _, _ in onFindCameras() }
        .onChange(of: window.openRecordingsFolderRequests) { _, _ in openRecordingsFolder() }
        .onChange(of: window.importCamerasRequests) { _, _ in importCamerasFromCSV() }
        .onChange(of: window.exportConfigurationRequests) { _, _ in exportConfiguration() }
        .onChange(of: window.streamDoctorRequests) { _, _ in runStreamDoctor() }
        .onChange(of: window.pictureInPictureRequests) { _, _ in togglePictureInPicture() }
        .onChange(of: window.exportDiagnosticsRequests) { _, _ in exportDiagnostics() }
        .onChange(of: session.clipExport.shareRequests) { _, _ in
            guard let url = session.clipExport.completedURL else { return }
            shareExportedClip(url)
        }
        .onChange(of: window.toggleWatchRequests) { _, _ in
            guard let camera = selectedCamera else { return }
            let starts = !window.watchedCameraIDs.contains(camera.id)
            if starts { window.watchedCameraIDs.insert(camera.id) }
            else { window.watchedCameraIDs.remove(camera.id) }
            Task { await eventFeed.setWatching(starts, camera: camera) }
        }
    }

    /// Everything a coordinator learns the hard way, said out loud.
    ///
    /// ⛔ Each of these was already being recorded and none of it was being shown. `RecordingCoordinator`'s
    /// own header puts it plainly: "A Record button that does nothing and says nothing is the exact
    /// shape this project refuses" — and that was the shape, because nothing read `lastFailure`.
    private func windowFailureReactions(_ content: some View) -> some View {
        content
        // Fires on every day the user steps to, not just the first load. Stepping a day goes
        // through `loadArchiveDay` rather than `loadArchive`, and an incomplete Tuesday must be
        // announced even though Monday was already announced.
        .onChange(of: archive.incompleteAfter) { _, _ in reportIncompleteDay() }
        // The mirror the menu reads to say Start or Stop. One writer, here.
        .onChange(of: recording.isRecording, initial: true) { _, isRecording in
            window.isRecording = isRecording
        }
        .onChange(of: session.twoWayAudio.state) { _, state in
            guard case .failed(let reason) = state else { return }
            if reason == "microphonePermission" {
                window.toast = MainWindowToast(
                    kind: .error,
                    message: Self.localized("Vigil needs microphone access to talk to your cameras"),
                    actionTitle: "Open Settings",
                    action: {
                        let settings = "x-apple.systempreferences:com.apple.preference.security"
                            + "?Privacy_Microphone"
                        if let url = URL(string: settings) {
                            NSWorkspace.shared.open(url)
                        }
                    })
            } else {
                window.toast = MainWindowToast(
                    kind: .error,
                    message: String(format: Self.localized("Two-way audio failed: %@"), reason))
            }
        }
        // ⚠️ A toast is the right shape for a recovery — a list rebuilt from a backup, an add the
        // store refused — and the wrong one for read-only, which is a condition rather than an
        // event and outlasts any banner. Saying it once is still better than never; a persistent
        // read-only indicator belongs with the sidebar's own chrome rather than being faked with a
        // toast that refuses to dismiss.
        .onChange(of: library.notice) { _, notice in
            guard let notice else { return }
            // The *Reveal in Finder* action FEATURES.md §F-INV-01 acceptance 3 names. Every notice
            // this model raises is about `library.json`, so the folder is always the right
            // destination; it is omitted only when the directory could not be resolved at all,
            // which is the one case where there is nothing to reveal.
            let folder = library.storeDirectory
            window.toast = MainWindowToast(
                kind: .warning,
                message: notice,
                actionTitle: folder == nil ? nil : "Reveal in Finder",
                action: folder.map { url in
                    { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                })
        }
        // A destination the sandbox will not write to, a disk with no room, a clip that closes
        // without producing a file — all of them logged, none of them said.
        .onChange(of: recording.lastFailure) { _, failure in
            guard let failure else { return }
            window.toast = MainWindowToast(
                kind: .error,
                message: String(format: Self.localized("Recording failed: %@"), failure))
        }
        // The same omission, one coordinator over. A PTZ command that the camera refuses left the
        // pad looking like it had worked.
        .onChange(of: ptz.lastFailure) { _, failure in
            guard let failure else { return }
            window.toast = MainWindowToast(
                kind: .warning,
                message: String(format: Self.localized("The camera refused that move: %@"), failure))
        }
    }
}

#endif  // os(macOS)
