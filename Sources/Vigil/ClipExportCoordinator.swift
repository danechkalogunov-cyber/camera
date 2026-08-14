//
//  ClipExportCoordinator.swift
//  Vigil
//
//  Observable ownership, progress, cancellation and sidecar finalization for F-PLB-04.
//

#if os(macOS)

import Foundation
import Observation

import VigilCore
import VigilISAPI
import VigilProtocols

@MainActor
@Observable
final class ClipExportCoordinator {
    private(set) var selection = ClipExportSelection()
    private(set) var isExporting = false
    private(set) var progress: Double = 0
    private(set) var lastFailure: String?
    private(set) var completedURL: URL?
    private(set) var shareRequests: UInt64 = 0
    private(set) var selectionCameraID: CameraID?

    private var worker: ArchiveClipExportWorker?
    private var exportTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var destination: URL?

    func setIn(_ instant: Date, camera: CameraID) {
        adopt(camera)
        selection.setIn(instant)
    }

    func setOut(_ instant: Date, camera: CameraID) {
        adopt(camera)
        selection.setOut(instant)
    }

    /// Moves one visible handle without allowing it to cross the other. Keeping I to the left of O
    /// makes a drag stable: otherwise `selection.range` reorders the values mid-gesture and the
    /// handle jumps under the cursor.
    func moveBoundary(isStart: Bool, to instant: Date, camera: CameraID) {
        adopt(camera)
        let minimumGap: TimeInterval = 0.1
        if isStart, let out = selection.outPoint {
            selection.setIn(min(instant, out.addingTimeInterval(-minimumGap)))
        } else if !isStart, let `in` = selection.inPoint {
            selection.setOut(max(instant, `in`.addingTimeInterval(minimumGap)))
        } else if isStart {
            selection.setIn(instant)
        } else {
            selection.setOut(instant)
        }
    }

    func clearSelection() {
        selection.clear()
        selectionCameraID = nil
    }

    func start(camera: Camera, playback: PlaybackLocator, destination: URL, maskedSerial: String?,
               appSession: AppSessionModel) {
        guard !isExporting, selectionCameraID == camera.id,
              let range = selection.range else { return }
        let worker = ArchiveClipExportWorker(camera: camera, range: range, playback: playback,
                                             dependencies: appSession.dependencies,
                                             credentials: appSession.credentials)
        self.worker = worker
        self.destination = destination
        isExporting = true
        progress = 0
        lastFailure = nil
        completedURL = nil

        progressTask = Task { [weak self, weak worker] in
            while let self, let worker, self.isExporting, !Task.isCancelled {
                let seconds = await worker.mediaSeconds
                self.progress = self.selection.progress(mediaSeconds: seconds)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        exportTask = Task { [weak self, weak worker] in
            guard let self, let worker else { return }
            var resumeState: AppSessionModel.ClipExportResumeState?
            do {
                resumeState = await appSession.suspendForClipExport(cameraID: camera.id)
                guard !Task.isCancelled else {
                    await worker.cancel()
                    throw ArchiveClipExportWorker.Failure.cancelled
                }
                let output = try await worker.run()
                try self.finalize(output: output, camera: camera, range: range,
                                  destination: destination, maskedSerial: maskedSerial)
                self.progress = 1
                self.completedURL = destination
                self.shareRequests &+= 1
                self.lastFailure = nil
            } catch ArchiveClipExportWorker.Failure.cancelled {
                self.lastFailure = nil
            } catch {
                self.lastFailure = error.localizedDescription
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(at: Self.sidecarURL(for: destination))
            }
            if let resumeState {
                await appSession.resumeAfterClipExport(resumeState)
            }
            self.progressTask?.cancel()
            self.progressTask = nil
            self.worker = nil
            self.exportTask = nil
            self.isExporting = false
        }
    }

    func cancel() {
        guard isExporting else { return }
        let worker = worker
        let destination = destination
        progressTask?.cancel()
        exportTask?.cancel()
        Task {
            await worker?.cancel()
            if let destination {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(at: Self.sidecarURL(for: destination))
            }
        }
        self.worker = nil
        progressTask = nil
        exportTask = nil
        isExporting = false
        progress = 0
        lastFailure = nil
    }

    private func finalize(output: ArchiveClipExportWorker.Output, camera: Camera,
                          range: Range<Date>, destination: URL,
                          maskedSerial: String?) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: output.record.url, to: destination)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "unknown"
        let sidecar = ClipExportSidecar(
            cameraID: camera.id,
            cameraName: camera.displayName,
            maskedDeviceSerial: maskedSerial,
            requested: .init(start: range.lowerBound, end: range.upperBound),
            // Hikvision's RTP stream does not expose the UTC of the preceding keyframe. `nil` is
            // evidence of that limitation; copying requestedStart here would invent precision.
            actualStart: nil,
            actualDurationSeconds: output.record.mediaSeconds,
            codec: output.codec,
            resolution: output.resolution,
            vigilVersion: version)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(sidecar).write(to: Self.sidecarURL(for: destination),
                                              options: [.atomic])
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    static func sidecarURL(for clip: URL) -> URL {
        clip.deletingPathExtension().appendingPathExtension("json")
    }

    static func mask(serial: String?) -> String? {
        guard let serial, !serial.isEmpty else { return nil }
        let suffix = serial.suffix(4)
        return "••••\(suffix)"
    }

    private func adopt(_ camera: CameraID) {
        guard selectionCameraID != camera else { return }
        selection.clear()
        selectionCameraID = camera
    }
}

#endif
