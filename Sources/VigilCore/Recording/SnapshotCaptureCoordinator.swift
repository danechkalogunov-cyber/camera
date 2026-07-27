//
//  SnapshotCaptureCoordinator.swift
//  VigilCore
//
//  The object between a snapshot button and `SnapshotService`: it picks one of the two routes,
//  falls back once when that route fails, turns every failure into a *named* outcome, and refuses a
//  second capture while one is in flight.
//  Implements docs/spec-core.md §10.1 and docs/FEATURES.md F-CAP-01 acceptance 1 / 7 / 8.
//
//  **Why this lives in `VigilCore` rather than beside the app's `SnapshotCoordinator`.**
//  `Tests/VigilCoreTests` may only see `VigilCore` and `VigilTestKit` (Package.swift), and
//  Package.swift is not this wave's to edit — so a capture policy declared in the `Vigil` executable
//  target could not be tested at all. Everything here is policy over seams; the live wiring
//  (Keychain, `ISAPIClient`, the destination directory) is the app's `LiveSnapshotSource`.
//
//  ⛔ Nothing here is silent. Every path out of ``SnapshotCaptureCoordinator/captureAndWait(options:)``
//  publishes a ``SnapshotOutcome`` and logs one line naming it. A snapshot button that saves nothing
//  and says nothing is the exact failure this project refuses.
//

#if os(macOS)

import Foundation
import Observation
import VigilProtocols
import VigilVideo

// MARK: - SnapshotRouteAvailability

/// Which of the two capture routes can be used *right now*.
///
/// Answered before every capture rather than cached, because both facts change while the window is
/// open: a tile that was paused starts decoding, and a camera whose HTTP session was never opened
/// gets one the moment a password is stored.
public struct SnapshotRouteAvailability: Sendable, Hashable {

    /// True when something is decoding and can hand over the frame on screen.
    public var hasDisplayedFrame: Bool

    /// True when the camera can be asked for its own JPEG over ISAPI.
    public var hasDeviceRoute: Bool

    /// Builds an availability answer.
    public init(hasDisplayedFrame: Bool, hasDeviceRoute: Bool) {
        self.hasDisplayedFrame = hasDisplayedFrame
        self.hasDeviceRoute = hasDeviceRoute
    }

    /// True when at least one route exists. False is the one case that must never reach
    /// `SnapshotService`: it has nothing to try and the user deserves a specific sentence.
    public var hasAnyRoute: Bool { hasDisplayedFrame || hasDeviceRoute }
}

// MARK: - SnapshotAttempting

/// One camera's capture capability, as the coordinator sees it.
///
/// The seam exists so the coordinator's *policy* — route choice, the single fallback, the named
/// outcomes and the in-flight rule — is testable without ImageIO, a socket, or a writable disk.
/// The app's conformance owns the `SnapshotService`, the destination directory and the ISAPI client.
public protocol SnapshotAttempting: Sendable {

    /// Short camera identity for log lines. Never a password, never a serial number.
    var cameraLabel: String { get }

    /// Which routes can be used right now.
    func availableRoutes() async -> SnapshotRouteAvailability

    /// Runs exactly one capture over exactly one route.
    ///
    /// - Parameters:
    ///   - source: the route to use. Never `.automatic`: the coordinator has already resolved the
    ///     choice, so that the fallback happens in one place and is reported once.
    ///   - options: format, quality, naming and metadata.
    /// - Returns: the captured still, with its bytes populated.
    /// - Throws: `VigilError` — `.render` when the frame could not be captured or encoded, `.isapi`
    ///   when the device refused, `.storage` / `.recording` when the file could not be written.
    func attempt(source: SnapshotSourcePreference,
                 options: SnapshotCaptureOptions) async throws(VigilError) -> SnapshotResult
}

// MARK: - SnapshotFailureKind

/// Why a capture produced no file, in the vocabulary the UI shows.
///
/// Grouped by *what the user would do about it* rather than by which layer threw: a sandbox refusal
/// and a full disk are different sentences with different buttons, while every flavour of "the
/// camera would not answer" is one.
public enum SnapshotFailureKind: String, Sendable, Hashable, Codable {

    /// Nothing is attached — no camera is connected yet.
    case noCamera

    /// Neither route was available, so nothing was even attempted.
    case noRoute

    /// A route was tried and could not produce an image: no frame, a decode failure, or an encoder
    /// that refused.
    case captureFailed

    /// The camera answered, and the answer was a refusal — busy, offline channel, 401, timeout.
    case deviceRefused

    /// The folder could not be written: a sandbox denial, a deleted folder, a read-only volume.
    case destinationUnwritable

    /// The volume is too full to write the file.
    case diskFull

    /// The capture was cancelled — the window closed, or the app is quitting.
    case cancelled

    /// Anything the mapping above does not name. Always carries the thrown error's code.
    case unexpected
}

// MARK: - SnapshotFailure

/// A named capture failure, with everything the UI and a support log need.
public struct SnapshotFailure: Sendable, Hashable {

    /// What went wrong, in the UI's vocabulary.
    public var kind: SnapshotFailureKind

    /// One sentence for the user. For a thrown error this is `VigilError.userMessage`; for a local
    /// refusal it is written here, because "The snapshot could not be taken" does not tell someone
    /// that nothing is decoding.
    public var message: String

    /// What to do about it, when there is something to do.
    public var remedy: String?

    /// The `VG-…` code, so a pasted screenshot can be traced through the diagnostics bundle.
    public var diagnosticCode: String

    /// Builds a failure.
    public init(kind: SnapshotFailureKind, message: String, remedy: String?,
                diagnosticCode: String) {
        self.kind = kind
        self.message = message
        self.remedy = remedy
        self.diagnosticCode = diagnosticCode
    }

    /// The code a refusal decided here carries.
    ///
    /// Computed from `RenderError.captureFailed` rather than written as a literal, so a local
    /// refusal and a thrown one land in the same code space and one grep finds both.
    public static var localDiagnosticCode: String {
        VigilError.render(.captureFailed("")).diagnosticCode
    }
}

// MARK: - SnapshotOutcome

/// What one capture did. There is no "nothing happened" case, by construction.
public enum SnapshotOutcome: Sendable, Hashable {

    /// A still was produced, and written unless `writesFile` was false.
    case saved(SnapshotResult)

    /// Nothing was written, for the named reason.
    case failed(SnapshotFailure)

    /// The result, when this is a success.
    public var result: SnapshotResult? {
        guard case .saved(let result) = self else { return nil }
        return result
    }

    /// The failure, when this is one.
    public var failure: SnapshotFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }
}

// MARK: - SnapshotCaptureCoordinator

/// Drives one capture at a time and publishes its outcome.
///
/// **The route policy, written once so it is arguable rather than accidental** (spec-core §10.1):
///
/// * `.automatic` prefers the **displayed frame** — it is instant and is exactly the picture the
///   user is looking at — and falls back to the camera's own JPEG when that route fails or when
///   nothing is decoding.
/// * `.deviceJPEG` ("Full resolution") uses the device, and falls back to the displayed frame when
///   the device refuses *and* a frame is on screen: a still that says "saved from the displayed
///   frame instead" beats no still at all.
/// * `.displayedFrame` ("As displayed") never falls back. The request is for that exact framing,
///   and a full-sensor image is not a substitute for it.
///
/// A fallback is only tried for a **route** failure. A destination that refused the write will
/// refuse the other route's write too, so a storage failure is reported immediately rather than
/// spending 400 ms fetching a JPEG that has nowhere to go.
@MainActor
@Observable
public final class SnapshotCaptureCoordinator {

    // MARK: - Observed State

    /// True from the moment a capture is accepted until its outcome is published. The toolbar
    /// disables its button on this, and a second capture is refused while it is true.
    public private(set) var isCapturing = false

    /// The last capture's outcome. `nil` only before the first one.
    public private(set) var lastOutcome: SnapshotOutcome?

    // MARK: - Derived State

    /// The file the last successful capture wrote, for a "Show in Finder" affordance.
    public var lastSavedURL: URL? {
        guard case .saved(let result) = lastOutcome else { return nil }
        return result.url
    }

    // MARK: - Stored Properties

    /// Where every outcome is named.
    private let logger: any LoggerProtocol

    /// The camera to capture from, or `nil` when nothing is connected.
    private var source: (any SnapshotAttempting)?

    /// The capture started by ``capture(options:)``, so a caller can await it.
    private var pending: Task<Void, Never>?

    // MARK: - Initialisation

    /// Builds a coordinator.
    ///
    /// - Parameter logger: structured logging. Pass `dependencies.logger` so a snapshot's failure
    ///   appears in the same stream as the stream failure that probably caused it.
    public init(logger: any LoggerProtocol) {
        self.logger = logger
    }

    // MARK: - Wiring

    /// Points the coordinator at a camera, or at nothing.
    ///
    /// Called when the session goes live and again when it is torn down. Detaching does not cancel
    /// a capture already in flight: the bytes are already off the camera and the file is worth
    /// finishing.
    public func attach(_ source: (any SnapshotAttempting)?) {
        self.source = source
        logger.debug(.core, "snapshot source \(source != nil ? "attached" : "detached")")
    }

    // MARK: - Capture

    /// Starts a capture and returns immediately. The toolbar and the ⇧⌘S shortcut call this.
    ///
    /// Refused, with a logged notice, while one is already in flight — a held-down shortcut must
    /// not queue eleven captures.
    ///
    /// - Parameter options: format, quality, naming and metadata.
    public func capture(options: SnapshotCaptureOptions = SnapshotCaptureOptions()) {
        guard begin() else { return }
        pending = Task { [weak self] in
            await self?.run(options: options)
        }
    }

    /// Captures, and does not return until the outcome has been published.
    ///
    /// The form a test drives and the form an App Intent would await. Never throws: the outcome is
    /// the return channel, so there is no error that can be dropped on the floor.
    ///
    /// - Parameter options: format, quality, naming and metadata.
    public func captureAndWait(options: SnapshotCaptureOptions = SnapshotCaptureOptions()) async {
        guard begin() else { return }
        await run(options: options)
    }

    /// Awaits the capture started by ``capture(options:)``, if there is one.
    ///
    /// Used by a quit handler — an in-flight write is worth the tenth of a second — and by tests.
    public func finishPendingCapture() async {
        let task = pending
        pending = nil
        await task?.value
    }

    // MARK: - Private: the run

    /// Takes the in-flight slot, or refuses and says so.
    private func begin() -> Bool {
        guard !isCapturing else {
            logger.notice(.core, "snapshot ignored: one is already in flight")
            return false
        }
        isCapturing = true
        return true
    }

    /// One capture, from route choice to published outcome.
    private func run(options: SnapshotCaptureOptions) async {
        defer { isCapturing = false }

        guard let source else {
            publish(.failed(SnapshotFailure(
                kind: .noCamera,
                message: "There is no camera to take a snapshot of.",
                remedy: "Connect to a camera and try again.",
                diagnosticCode: SnapshotFailure.localDiagnosticCode)))
            return
        }

        let routes = await source.availableRoutes()
        guard let plan = Self.plan(for: options.source, routes: routes) else {
            publish(.failed(Self.noRouteFailure(for: options.source, routes: routes)))
            return
        }

        do {
            let result = try await Self.attempt(source, using: plan.preferred, options: options)
            publish(.saved(result))
        } catch let primary {
            guard let fallback = plan.fallback, Self.isRouteFailure(primary) else {
                publish(.failed(Self.failure(for: primary)))
                return
            }
            logger.notice(.core, "snapshot route failed; trying the other one",
                          ["camera": source.cameraLabel,
                           "failed": plan.preferred.rawValue,
                           "trying": fallback.rawValue,
                           "reason": primary.diagnosticCode])
            do {
                var result = try await Self.attempt(source, using: fallback, options: options)
                // The service only sets this when *it* fell back, and it never does here: the
                // coordinator always hands it one concrete route. The UI's "Saved from the
                // camera's own snapshot" note reads this, so it is set where the fallback happened.
                result.usedFallback = true
                publish(.saved(result))
            } catch let secondary {
                // Both routes are on the record, and the *requested* one is what the user is told
                // about — it is the one they chose and the one whose remedy applies.
                logger.error(.core, "snapshot fallback route failed too",
                             ["camera": source.cameraLabel,
                              "route": fallback.rawValue,
                              "reason": secondary.diagnosticCode,
                              "message": secondary.userMessage])
                publish(.failed(Self.failure(for: primary)))
            }
        }
    }

    /// Publishes an outcome and logs exactly one line naming it.
    private func publish(_ outcome: SnapshotOutcome) {
        lastOutcome = outcome
        switch outcome {
        case .saved(let result):
            logger.info(.core, "snapshot outcome: saved",
                        ["origin": result.origin.rawValue,
                         "fallback": String(result.usedFallback),
                         "pixels": "\(result.pixelWidth)x\(result.pixelHeight)",
                         "path": Redact.path(result.url?.path ?? "(not written)")])
        case .failed(let failure):
            logger.error(.core, "snapshot outcome: \(failure.kind.rawValue)",
                         ["code": failure.diagnosticCode, "message": failure.message])
        }
    }

    // MARK: - Private: route policy

    /// The route to try first, and the one to try after it fails.
    private struct Plan {

        /// The route the request resolves to.
        var preferred: SnapshotSourcePreference

        /// The route to try once if `preferred` fails for a route-shaped reason.
        var fallback: SnapshotSourcePreference?
    }

    /// Resolves a preference against what is actually available, or `nil` when there is no route.
    private static func plan(for preference: SnapshotSourcePreference,
                             routes: SnapshotRouteAvailability) -> Plan? {
        switch preference {
        case .automatic:
            if routes.hasDisplayedFrame {
                return Plan(preferred: .displayedFrame,
                            fallback: routes.hasDeviceRoute ? .deviceJPEG : nil)
            }
            guard routes.hasDeviceRoute else { return nil }
            return Plan(preferred: .deviceJPEG, fallback: nil)

        case .displayedFrame:
            guard routes.hasDisplayedFrame else { return nil }
            return Plan(preferred: .displayedFrame, fallback: nil)

        case .deviceJPEG:
            guard routes.hasDeviceRoute else { return nil }
            return Plan(preferred: .deviceJPEG,
                        fallback: routes.hasDisplayedFrame ? .displayedFrame : nil)
        }
    }

    /// One capture over one route.
    private static func attempt(_ source: any SnapshotAttempting,
                                using preference: SnapshotSourcePreference,
                                options: SnapshotCaptureOptions)
        async throws(VigilError) -> SnapshotResult {
        var options = options
        options.source = preference
        return try await source.attempt(source: preference, options: options)
    }

    /// Whether trying the other route could plausibly help.
    ///
    /// The two route domains, and the credential the device route needs. A storage or recording
    /// failure is deliberately absent: the file has nowhere to go either way.
    private static func isRouteFailure(_ error: VigilError) -> Bool {
        switch error {
        case .render, .isapi, .decode, .credential, .transport, .rtsp: true
        default: false
        }
    }

    /// The specific sentence for "there was no route at all".
    ///
    /// Three different sentences, because the remedy differs: waiting helps one of them, choosing a
    /// different capture source helps another, and fixing the password helps the third.
    private static func noRouteFailure(for preference: SnapshotSourcePreference,
                                       routes: SnapshotRouteAvailability) -> SnapshotFailure {
        let message: String
        let remedy: String
        switch preference {
        case .displayedFrame:
            message = "There is no video to capture: this camera is not decoding, and "
                + "“As displayed” was required."
            remedy = "Choose “Full resolution” to ask the camera for a JPEG instead."
        case .deviceJPEG:
            message = "This camera has no HTTP session, so its own snapshot endpoint cannot be "
                + "reached."
            remedy = "Check the camera's address and password, then try again."
        case .automatic:
            message = "There is nothing to capture: no video is decoding and the camera has no "
                + "HTTP session."
            remedy = routes.hasAnyRoute
                ? "Try again in a moment."
                : "Wait for the picture to appear, or reconnect to the camera."
        }
        return SnapshotFailure(kind: .noRoute, message: message, remedy: remedy,
                               diagnosticCode: SnapshotFailure.localDiagnosticCode)
    }

    /// Maps a thrown error onto the named outcome the UI shows.
    ///
    /// Written as a mapping rather than an exhaustive switch on `VigilError` on purpose: the cases
    /// that matter to a snapshot are named, and everything else becomes `.unexpected` **carrying
    /// its own code**, so an unmapped failure is still traceable rather than invisible.
    private static func failure(for error: VigilError) -> SnapshotFailure {
        let kind: SnapshotFailureKind
        switch error {
        case .render, .decode, .bitstream:
            kind = .captureFailed
        case .isapi, .credential:
            kind = .deviceRefused
        case .storage(.diskFull), .recording(.spaceBelowReserve):
            kind = .diskFull
        case .storage, .recording:
            kind = .destinationUnwritable
        case .cancelled:
            kind = .cancelled
        default:
            kind = .unexpected
        }
        return SnapshotFailure(kind: kind, message: error.userMessage, remedy: error.userRemedy,
                               diagnosticCode: error.diagnosticCode)
    }
}

#endif
