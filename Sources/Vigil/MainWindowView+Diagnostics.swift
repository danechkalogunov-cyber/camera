//
//  MainWindowView+Diagnostics.swift
//  Vigil
//
//  User-driven F-DAT-03 export. Evidence is captured on the main actor, then redaction, hashing and
//  ZIP encoding move off it. The resulting bytes are written atomically to the selected location.
//

#if os(macOS)

import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

import VigilCore
import VigilDiscovery
import VigilProtocols

private extension UTType {
    static let vigilDiagnostics = UTType(exportedAs: "com.vigil.diagnostics", conformingTo: .zip)
}

extension MainWindowView {
    func exportDiagnostics() {
        guard window.diagnosticsExportTask == nil else { return }
        let now = Date()
        let files: [DiagnosticsArchiveFile]
        do { files = try diagnosticFiles(now: now) } catch {
            reportDiagnosticsFailure(error)
            return
        }
        guard confirmDiagnostics(files) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.vigilDiagnostics, .zip]
        panel.nameFieldStringValue = "Vigil-Diagnostics-\(Self.diagnosticStamp(now)).zip"
        panel.message = Self.localized(
            "The archive is redacted and stays on this Mac until you choose to share it.")
        panel.prompt = Self.localized("Export")
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        window.toast = MainWindowToast(kind: .info,
                                       message: Self.localized("Building diagnostics archive…"),
                                       actionTitle: Self.localized("Cancel export"),
                                       action: { window.diagnosticsExportTask?.cancel() })
        window.diagnosticsExportTask = Task {
            defer { window.diagnosticsExportTask = nil }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try DiagnosticsArchiveBuilder.build(createdAt: now,
                                                        includesHostnames: false,
                                                        includesFullLogs: true,
                                                        files: files)
                }
                let data = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                try data.write(to: destination, options: [.atomic, .completeFileProtection])
                window.toast = MainWindowToast(
                    kind: .success,
                    message: Self.localized("Diagnostics archive exported."),
                    actionTitle: "Reveal in Finder",
                    action: { NSWorkspace.shared.activateFileViewerSelecting([destination]) })
            } catch is CancellationError {
                window.toast = MainWindowToast(kind: .info,
                                               message: Self.localized("Diagnostics export cancelled."))
            } catch {
                reportDiagnosticsFailure(error)
            }
        }
    }

    /// Lists every source and its pre-ZIP size before collection can begin.
    private func confirmDiagnostics(_ files: [DiagnosticsArchiveFile]) -> Bool {
        let alert = NSAlert()
        alert.messageText = Self.localized("Review diagnostics archive")
        alert.informativeText = Self.localized(
            "These redacted files will be included. No data leaves this Mac automatically.")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.backgroundColor = .textBackgroundColor
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let rows = files.map { file in
            let size = ByteCountFormatter.string(fromByteCount: Int64(file.data.count),
                                                 countStyle: .file)
            return "\(file.path)  \(size)"
        } + ["manifest.json  " + Self.localized("generated")]
        text.string = rows.joined(separator: "\n")
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: Self.localized("Continue"))
        alert.addButton(withTitle: Self.localized("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func diagnosticFiles(now: Date) throws -> [DiagnosticsArchiveFile] {
        var files = [
            DiagnosticsArchiveFile(path: "summary.txt", text: diagnosticSummary(now: now)),
            DiagnosticsArchiveFile(path: "library-redacted.json",
                                   data: try redactedLibraryData(now: now)),
            DiagnosticsArchiveFile(path: "logs/vigil-\(Self.diagnosticDay(now)).log",
                                   text: DiagnosticLogCollector.last24Hours(now: now)),
            DiagnosticsArchiveFile(path: "events.csv", text: diagnosticEventsCSV()),
            DiagnosticsArchiveFile(path: "crash-context.json",
                                   text: diagnosticCrashContext(now: now)),
        ]

        for camera in library.cameras {
            let key = camera.id.short
            let stats = measuredTelemetry[camera.id]?.statistics ?? .init()
            files.append(DiagnosticsArchiveFile(
                path: "streams/\(key)/stats.csv", text: Self.statisticsCSV(stats)))
            let minutes = measuredTelemetry[camera.id]?.minuteStatistics ?? []
            files.append(DiagnosticsArchiveFile(
                path: "streams/\(key)/stats-24h.csv",
                text: Self.minuteStatisticsCSV(minutes, now: session.dependencies.clock.now())))
            let doctor: String
            if window.streamDoctorCameraID == camera.id, !window.streamDoctorOutcomes.isEmpty {
                doctor = StreamDoctorResult(outcomes: window.streamDoctorOutcomes,
                                            failures: window.streamDoctorFailures,
                                            details: window.streamDoctorDetails).redactedText
            } else {
                doctor = session.cameras.stream(for: camera.id)?.diagnosis
                    .map(String.init(describing:)) ?? "No Stream Doctor result recorded."
            }
            files.append(DiagnosticsArchiveFile(path: "streams/\(key)/doctor.txt", text: doctor))
        }
        return files
    }

    private func diagnosticSummary(now: Date) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "development"
        let build = info["CFBundleVersion"] as? String ?? "development"
        let process = ProcessInfo.processInfo
        let displays = NSScreen.screens.map {
            "\(Int($0.frame.width))x\(Int($0.frame.height))@\(String(format: "%.1f", $0.backingScaleFactor))x"
        }.joined(separator: ", ")
        return [
            "Vigil diagnostics",
            "created: \(ISO8601DateFormatter().string(from: now))",
            "app: \(version) (\(build))",
            "macOS: \(process.operatingSystemVersionString)",
            "processors: \(process.processorCount) active=\(process.activeProcessorCount)",
            "memory: \(process.physicalMemory) bytes",
            "displays: \(displays)",
            "locale: \(Locale.current.identifier)",
            "appearance: "
                + (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])?.rawValue
                   ?? "unknown"),
            "cameras: \(library.cameras.count)",
        ].joined(separator: "\n") + "\n"
    }

    private func redactedLibraryData(now: Date) throws -> Data {
        let cameras = library.cameras.map { camera -> Camera in
            Camera(id: camera.id, name: camera.name,
                   host: Self.cameraAlias(camera.host), httpPort: camera.httpPort,
                   rtspPort: camera.rtspPort, useTLS: camera.useTLS, channel: camera.channel,
                   preferredQuality: camera.preferredQuality, transport: camera.transport,
                   credentialRef: CredentialRef(), capabilities: camera.capabilities,
                   createdAt: camera.createdAt, lastSeenAt: camera.lastSeenAt,
                   isEnabled: camera.isEnabled, colorTag: camera.colorTag,
                   rtspPathOverride: camera.rtspPathOverride,
                   latencyPreset: camera.latencyPreset)
        }
        return try ConfigurationArchiveCodec.encode(
            VigilConfigurationArchive(exportedAt: now, cameras: cameras, groups: groups.groups))
    }

    private func diagnosticEventsCSV() -> String {
        var rows = ["id,camera,kind,label,occurred_at,duration_seconds,unread"]
        let formatter = ISO8601DateFormatter()
        rows += eventFeed.events.suffix(5_000).map { event in
            [event.id.uuidString, event.camera.id.short, String(describing: event.kind), event.label,
             formatter.string(from: event.occurredAt),
             event.durationSeconds.map { String($0) } ?? "", String(event.isUnread)]
                .map(Self.csvField).joined(separator: ",")
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    private func diagnosticCrashContext(now: Date) -> String {
        let value: [String: Any] = [
            "capturedAt": ISO8601DateFormatter().string(from: now),
            "phase": String(describing: session.phase),
            "selectedCamera": selectedCamera?.id.short ?? "none",
            "streamState": String(describing: session.streamState),
            "recording": recording.isRecording,
            "unreadEvents": eventFeed.unreadCount,
        ]
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return "{}\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func reportDiagnosticsFailure(_ error: any Error) {
        window.toast = MainWindowToast(
            kind: .error,
            message: String(format: Self.localized("Could not export diagnostics: %@"),
                            (error as NSError).localizedDescription))
    }

    private static func statisticsCSV(_ stats: StreamStatistics) -> String {
        let header = "fps,bits_per_second,packets_received,packets_lost,loss_fraction,jitter_ms,"
            + "decode_queue,uptime_seconds,reconnects,last_error"
        let row = [String(stats.framesPerSecond), String(stats.bitsPerSecond),
                   String(stats.packetsReceived), String(stats.packetsLost),
                   String(stats.lossFraction), String(stats.jitterMilliseconds),
                   String(stats.decodeQueueDepth), String(stats.uptimeSeconds),
                   String(stats.reconnectCount), stats.lastErrorCode ?? ""]
            .map(csvField).joined(separator: ",")
        return header + "\r\n" + row + "\r\n"
    }

    private static func minuteStatisticsCSV(_ rows: [StreamMinuteStatistics],
                                            now: MediaInstant) -> String {
        let header = "minutes_ago,fps,bits_per_second,packets_received,packets_lost,loss_fraction,"
            + "jitter_ms,decode_queue,uptime_seconds,reconnects,last_error"
        let values = rows.reversed().map { row in
            let stats = row.statistics
            let age = max(0, Int(now.seconds(since: row.endedAt) / 60))
            return [String(age), String(stats.framesPerSecond), String(stats.bitsPerSecond),
                    String(stats.packetsReceived), String(stats.packetsLost),
                    String(stats.lossFraction), String(stats.jitterMilliseconds),
                    String(stats.decodeQueueDepth), String(stats.uptimeSeconds),
                    String(stats.reconnectCount), stats.lastErrorCode ?? ""]
                .map(csvField).joined(separator: ",")
        }
        return ([header] + values).joined(separator: "\r\n") + "\r\n"
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n")
        else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func cameraAlias(_ host: String) -> String {
        let digest = SHA256.hash(data: Data(host.lowercased().utf8))
        return "cam-" + digest.prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    private static func diagnosticStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func diagnosticDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

#endif
