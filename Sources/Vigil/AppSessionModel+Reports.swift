//
//  AppSessionModel+Reports.swift
//  Vigil
//
//  What the app does with what the display path and the connect path report: decode failures,
//  dropped frames, and the named causes shown on the connect form.
//  macOS-only. Split out of `AppSessionModel+Session.swift` at the 600-line ceiling
//  (API_CONTRACT.md §7.2); the boundary is the one that was already marked in that file.
//
//  ⚠️ Every handler here comes in two forms: a no-argument one that means `live`, and one that
//  takes the `CameraStream` that reported. The tile that reports a decode failure knows which
//  camera it is drawing, and with more than one on screen the counters, the recovery rate limit and
//  the log line all have to belong to that camera rather than to "the session".
//

#if os(macOS)

import AppKit
import Foundation

import VigilCore
import VigilISAPI
import VigilProtocols
import VigilRender
import VigilUI
import VigilVideo

// MARK: - Display-path reports

extension AppSessionModel {

    /// A sample the video renderer refused to decode.
    ///
    /// `VigilRender` hands over a diagnostic string rather than an error, because `any Error` is not
    /// `Sendable` and the report crosses a thread boundary from whatever queue AVFoundation posts on.
    /// The decision about what to *do* is here rather than there, which is why the tile only reports.
    ///
    /// One failure is not a fault: a truncated access unit after packet loss produces exactly this
    /// and the next keyframe fixes it. A run of them means the decoder cannot make progress from the
    /// parameter sets it has, and the only escape is a fresh keyframe — which is what
    /// ``AppSessionModel/recoverStalledPicture()`` asks for, rate-limited so a decoder that keeps
    /// failing cannot put the session into a restart loop.
    func handleDecodeFailure(_ diagnostic: String) {
        handleDecodeFailure(diagnostic, on: live)
    }

    /// The same, for whichever tile refused the sample.
    func handleDecodeFailure(_ diagnostic: String, on stream: CameraStream) {
        stream.decodeFailures += 1
        dependencies.logger.error(.video, "renderer failed to decode: \(diagnostic)")
        guard stream.decodeFailures >= Self.decodeFailuresBeforeRecovery else { return }
        stream.decodeFailures = 0
        recoverStalledPicture(on: stream)
    }

    /// Frames that never reached the screen, from either end of the display path.
    ///
    /// Two origins arrive here through one callback: `VigilVideo`'s pipeline dropping an access unit
    /// before it became a sample buffer, and the tile's own renderer refusing one it was handed. The
    /// reason string keeps them apart, and the tile's ``VigilRender/TileRenderState`` already carries
    /// the running counts for the status line, so this method's job is the part no view can do —
    /// putting the fact in the log, and acting on the one reason that never resolves by itself.
    ///
    /// **`noFormat` is the case this exists for.** It means no parameter sets have arrived, so every
    /// frame is being discarded and the tile is black with nothing wrong anywhere else. Left alone it
    /// stays that way forever. Hikvision re-sends SPS/PPS immediately before every IDR, so asking
    /// for a keyframe is precisely the right remedy — the recovery that looks like it is about a
    /// stalled picture is really about getting the format.
    ///
    /// Logging is thresholded, not per frame: at 25 fps an unresolved `noFormat` would otherwise
    /// write 1,500 lines a minute and bury the line that matters.
    func handleFramesDropped(_ count: Int, reason: String) {
        handleFramesDropped(count, reason: reason, on: live)
    }

    /// The same, for whichever tile dropped them.
    func handleFramesDropped(_ count: Int, reason: String, on stream: CameraStream) {
        stream.droppedByReason[reason, default: 0] += count
        let total = stream.droppedByReason[reason] ?? count
        if total.isMultiple(of: Self.dropLogInterval) || total == count {
            dependencies.logger.notice(.video, "dropped \(total) frame(s), reason: \(reason)")
        }
        guard reason == FrameDropReason.noFormat.rawValue,
              total >= Self.noFormatDropsBeforeRecovery
        else { return }
        stream.droppedByReason[reason] = 0
        dependencies.logger.notice(.video, "no parameter sets after \(total) frames; asking for a "
            + "keyframe so the camera re-sends them")
        recoverStalledPicture(on: stream)
    }

    /// A failure before the controller existed: a bad address, or a Keychain that would not answer.
    func fail(with error: any Error, host: String) {
        present(Self.diagnosis(for: error, host: host))
        dependencies.logger.error(.app, "connect failed: \(error)")
    }

    /// Shows a named cause on the connect form.
    ///
    /// `ConnectFormState.fail` also clears the in-flight flag and bumps the failure counter that
    /// drives the form's one-per-failure shake, so this is the only way a diagnosis reaches it.
    func present(_ named: ConnectDiagnosis) {
        diagnosis = named
        phase = .connect
        form.fail(named)
    }

    /// Turns an error raised on the app's own half of the connect path into a named cause.
    ///
    /// `StreamError` never reaches here — the controller reports those through its event stream —
    /// so this covers exactly two sources: the address the user typed, and the Keychain.
    static func diagnosis(for error: any Error, host: String) -> ConnectDiagnosis {
        switch error {
        case is CameraValidationError:
            // `CameraValidationError.description` is a redacted log line, not a sentence for a
            // person, so the user-facing copy is written here.
            return .undiagnosed(host: host,
                                detail: "That is not an address Vigil can use. Type just the "
                                    + "address — no rtsp://, no user name and no path.")
        case let failure as any VigilFailure:
            return .undiagnosed(host: host,
                                detail: [failure.userMessage, failure.userRemedy]
                                    .compactMap { $0 }.joined(separator: " "))
        default:
            return .undiagnosed(host: host, detail: "Vigil could not start the connection.")
        }
    }

    /// What we already know about this host and account: its Keychain handle, and the RTSP path
    /// that worked last time.
    ///
    /// Reusing the handle matters because `save` updates an item in place, whereas a fresh
    /// `CredentialRef` would leave the old item behind as an orphan on every retry. Reusing the
    /// path is R1.2's "the probe happens exactly once per device, ever".
    func knownHandle(for request: ConnectRequest) -> (ref: CredentialRef, rtspPath: String?) {
        guard let remembered = LastConnection.load(from: defaults),
              remembered.host.caseInsensitiveCompare(request.host) == .orderedSame,
              remembered.account == request.username
        else {
            return (CredentialRef(), nil)
        }
        return (remembered.credentialRef, remembered.rtspPath)
    }

    /// Removes a password the camera has rejected.
    ///
    /// Fire-and-forget on purpose: the user is already looking at the form, and a Keychain that
    /// refuses the delete changes nothing they can act on. The failure is logged, not shown.
    func deleteRejectedCredential(_ ref: CredentialRef) {
        let store = credentials
        let logger = dependencies.logger
        Task {
            do {
                try await store.delete(ref)
            } catch {
                logger.warning(.app, "could not remove the rejected credential: \(error)")
            }
        }
    }

    /// Opens the camera's own web page, where every device-side setting the diagnoses point at
    /// lives — including activation for a factory-fresh camera.
    func openCameraWebPage() {
        let host = camera?.host ?? form.request.host
        let port = camera?.httpPort ?? 80
        let authority = host.contains(":") ? "[\(host)]" : host   // bare IPv6 needs brackets
        guard !host.isEmpty, let url = URL(string: "http://\(authority):\(port)/") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reports a remedy the slice cannot perform, in place of doing nothing.
    func unavailable(_ sentence: String) {
        let host = camera?.host ?? form.request.host
        present(.undiagnosed(host: host, detail: sentence))
        dependencies.logger.notice(.ui, sentence)
    }

    /// Whole seconds from now until `date`, or `nil` when there is no countdown.
    static func seconds(until date: Date?) -> Int? {
        guard let date else { return nil }
        return max(0, Int(date.timeIntervalSinceNow.rounded()))
    }

    /// The port Hikvision devices use when 554 is taken or disabled (R1.5 "RTSP port closed").
    static let alternateRTSPPort = 8554

    /// The shortest gap between two forced keyframe recoveries.
    static let recoveryInterval: TimeInterval = 10

    /// How many renderer decode failures in a row before forcing a keyframe.
    ///
    /// Three, because one is packet loss and two can be the same GOP; three means the parameter sets
    /// the decoder is working from cannot decode what the camera is sending.
    static let decodeFailuresBeforeRecovery = 3

    /// How many frames may be dropped for want of parameter sets before asking for a keyframe.
    ///
    /// Fifty is about two seconds at 25 fps — long enough that a normal startup, where the first
    /// access units precede the first SPS by a few frames, resolves on its own without a restart.
    static let noFormatDropsBeforeRecovery = 50

    /// One log line per this many dropped frames of the same reason.
    static let dropLogInterval = 100
}

#endif  // os(macOS)
