//
//  DiscoveryScanModel.swift
//  Vigil
//
//  Runs one network scan and turns its event stream into something a sheet can render.
//  macOS-only. Drives `VigilDiscovery.DiscoveryCoordinator`; see docs/spec-discovery.md §8 and §10.
//
//  ⛔ THIS IS THE ONLY PLACE IN THE APP THAT STARTS A SCAN, and it exists so that neither of the two
//  layers either side of it has to know about the other. `VigilDiscovery` is pure and names no
//  socket; `VigilUI` renders values and holds no network. This translates between them: the
//  coordinator's `DiscoveredDevice` becomes `VDiscoveredCamera`, and its `DiscoveryPhase` becomes a
//  sentence.
//
//  ⚠️ ONE RUN PER COORDINATOR. `DiscoveryCoordinator.start()` may be called once per instance; a
//  rescan builds a new one. Breaking out of the `for await` — which happens when the sheet closes
//  and the task is cancelled — terminates the stream, which cancels the run and closes every
//  socket, so there is no way to leave a sweep running behind a dismissed sheet (§8.4).
//

#if os(macOS)

import Foundation
import Observation

import VigilDiscovery
import VigilProtocols
import VigilTransport
import VigilUI

// MARK: - DiscoveryScanModel

/// One scan, observable.
@MainActor
@Observable
final class DiscoveryScanModel: Identifiable {

    /// Identifies this run to `.sheet(item:)`. One model is one run, so a new scan is a new sheet.
    nonisolated let id = UUID()

    // MARK: - Observable State

    /// Everything found so far, in the engine's own order (§10.4).
    private(set) var cameras: [VDiscoveredCamera] = []

    /// `0…1`, or `nil` before the plan exists.
    private(set) var progress: Double?

    /// What the run is doing, for the sheet's subtitle. Already translated.
    private(set) var phase: String = vigilUIString("Preparing…")

    /// True while a run is in flight.
    private(set) var isScanning = false

    /// A sentence about a degraded run, or `nil` when there is nothing to say.
    private(set) var notice: String?

    // MARK: - Callbacks

    /// Called once, with the first camera confident enough to act on without asking.
    ///
    /// This is what makes R1 possible: "launch it, type the password, see a picture" has no room in
    /// it for choosing an address from a list, so the first good answer is used and the rest of the
    /// run is somebody else's business. `nil` for a scan the user opened deliberately — there the
    /// whole point is the list.
    ///
    /// ⚠️ Fires for a **confident, ISAPI-speaking** row only. A `possible` row or something that
    /// merely has a port open is worth showing a person who asked to see it, and is not worth
    /// putting into a field on its own.
    var onFirstConfidentCamera: ((VDiscoveredCamera) -> Void)?

    /// Set once `onFirstConfidentCamera` has fired, so it fires exactly once per run.
    private var hasReportedConfidentCamera = false

    // MARK: - Stored Properties

    private let logger: any LoggerProtocol

    /// Addresses already in the library, so a row can say "Added" instead of offering a duplicate.
    private let knownAddresses: Set<String>

    private var coordinator: DiscoveryCoordinator?
    private var task: Task<Void, Never>?

    // MARK: - Initialisation

    /// Creates a scan model.
    ///
    /// - Parameters:
    ///   - logger: the app's logger, passed down to `VigilDiscovery`, which has no other way out.
    ///   - knownAddresses: hosts the user has already added.
    init(logger: any LoggerProtocol, knownAddresses: Set<String> = []) {
        self.logger = logger
        self.knownAddresses = knownAddresses
    }

    // MARK: - Running

    /// Starts a run, replacing any that is still going.
    func start() {
        stop()
        let environment = LiveDiscoveryEnvironment.make(logger: logger)
        if !environment.entitlements.multicastEntitlementPresent {
            // Said before the run rather than after it. Without the entitlement the two multicast
            // mechanisms are skipped and the sweep still finds cameras — slower, and only on this
            // subnet — and a user who is told that up front reads a short list as expected rather
            // than as a failure (§9.5).
            notice = vigilUIString("This build cannot use multicast, so only a direct sweep of "
                                   + "this subnet runs. Cameras on other subnets will not answer.")
        }
        let coordinator = DiscoveryCoordinator(environment: environment)
        self.coordinator = coordinator
        cameras = []
        progress = nil
        phase = vigilUIString("Preparing…")
        isScanning = true

        task = Task { [weak self] in
            // `start()` is `await` because the coordinator is an actor: the run lives off the main
            // actor, which is the point — a sweep of 254 hosts must not share an executor with the
            // window that is drawing its progress.
            let stream = await coordinator.start()
            for await event in stream {
                guard let self else { return }
                await absorb(event)
            }
            self?.isScanning = false
        }
    }

    /// Stops the current run. Safe when nothing is running.
    ///
    /// Cancelling the task terminates the stream, which the coordinator's `onTermination` turns
    /// into a cancel of its own — so the sockets close whether or not the explicit `cancel()` below
    /// wins the race. It is sent anyway because "the sheet closed" and "the user pressed Stop"
    /// should not differ in how quickly the network goes quiet.
    func stop() {
        task?.cancel()
        task = nil
        if let coordinator {
            Task { await coordinator.cancel() }
        }
        coordinator = nil
        isScanning = false
    }

    /// Stop if running, start if not — the sheet's one button.
    func toggle() {
        if isScanning { stop() } else { start() }
    }

    // MARK: - Private Helpers

    /// Folds one event into the observable state.
    ///
    /// `deviceFound` and `deviceUpdated` both rebuild the whole list from the coordinator's
    /// snapshot rather than patching a row. That is deliberate: the snapshot is already in the
    /// stable order of §10.4, and patching would require this file to re-implement that comparator
    /// — a second source of truth for the one property that stops the list reshuffling under the
    /// pointer.
    private func absorb(_ event: DiscoveryEvent) async {
        switch event {
        case .started:
            phase = vigilUIString("Looking for cameras…")
        case let .progress(value):
            progress = value.fraction
            phase = Self.sentence(for: value.phase)
        case .deviceFound, .deviceUpdated, .deviceMerged:
            await refreshCameras()
        case let .diagnostic(diagnostic):
            logger.info(.discovery, "discovery: \(String(describing: diagnostic))")
        case let .finished(summary):
            // From the summary, not the coordinator: the run is over and this is its final word,
            // so there is no reason to hop back to the actor for a value it just handed us.
            cameras = summary.devices.map(row(for:))
            isScanning = false
            progress = 1
            phase = Self.sentence(for: summary)
            // Also here, not only on device events: a row can cross the confidence threshold on the
            // last piece of evidence the run gathers, and a caller waiting for one good answer
            // should get it rather than being told the scan ended empty-handed.
            reportFirstConfidentCamera()
        case .addressChanged, .addressReused, .phaseCompleted:
            break
        }
    }

    private func refreshCameras() async {
        guard let coordinator else { return }
        cameras = await coordinator.snapshot.map(row(for:))
        reportFirstConfidentCamera()
    }

    /// Hands the first good answer to whoever is waiting for one, at most once.
    ///
    /// Reads from the rebuilt list rather than from the event, so it inherits §10.4's order for
    /// free: the engine has already sorted by confidence, then ISAPI, then address, so "the first
    /// row that qualifies" *is* the best answer and this file does not get a second opinion about
    /// what best means.
    private func reportFirstConfidentCamera() {
        guard !hasReportedConfidentCamera, let report = onFirstConfidentCamera else { return }
        guard let best = cameras.first(where: {
            $0.isConfident && $0.supportsISAPI && !$0.isAlreadyAdded
        }) else { return }
        hasReportedConfidentCamera = true
        report(best)
    }

    /// One device, in the sheet's vocabulary.
    private func row(for device: DiscoveredDevice) -> VDiscoveredCamera {
        let address = device.address.description
        let title = device.displayName ?? device.model ?? address
        let detail = [device.model, device.firmwareVersion]
            .compactMap { $0 }
            .filter { $0 != title }
            .joined(separator: " ")
        return VDiscoveredCamera(
            // ⚠️ Derived from the identity, not freshly generated: a row that gains a serial
            // number mid-run must stay the same row, or SwiftUI animates it out and back in while
            // the user is reaching for it.
            id: Self.rowID(for: device),
            title: title,
            address: address,
            detail: detail,
            confidence: device.confidence,
            supportsISAPI: device.vendor.supportsISAPI,
            isAlreadyAdded: knownAddresses.contains(address),
            needsActivation: device.needsActivation)
    }

    /// A stable UUID for a device, hashed from its identity.
    ///
    /// `DeviceIdentity` is an enum over a MAC, a serial, an ONVIF UUID or an endpoint, and none of
    /// those is a `UUID`. Hashing its description gives a value that is stable for as long as the
    /// identity is — which is exactly the lifetime a row needs.
    private static func rowID(for device: DiscoveredDevice) -> UUID {
        var hasher = Hasher()
        hasher.combine(String(describing: device.id))
        let hash = UInt64(bitPattern: Int64(hasher.finalize()))
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: hash >> (8 * UInt64(index)))
            bytes[index + 8] = bytes[index] ^ 0x5A
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// What a phase is called in the sheet. Named, not numbered: "sweepB" means nothing to anyone.
    ///
    /// ⚠️ Not `DiscoveryPhase.label`. That property exists and is shorter, but it lives in
    /// `VigilDiscovery`, which is Foundation-only and has no bundle of its own — its strings can
    /// never be translated. The user-facing sentence therefore belongs on this side of the line,
    /// where `VigilUI`'s `.strings` tables can reach it, and the engine's `label` stays what it
    /// always was: a name for a log line.
    private static func sentence(for phase: DiscoveryPhase) -> String {
        switch phase {
        case .planning: vigilUIString("Preparing…")
        case .arpSnapshot: vigilUIString("Reading what this Mac has already spoken to…")
        case .sadp: vigilUIString("Asking Hikvision cameras to announce themselves…")
        case .onvif: vigilUIString("Asking ONVIF devices to announce themselves…")
        case .bonjour: vigilUIString("Listening for Bonjour…")
        case .sweepA, .sweepB: vigilUIString("Checking every address on this network…")
        case .fingerprint: vigilUIString("Asking what answered…")
        case .settling: vigilUIString("Finishing…")
        case .finished: vigilUIString("Done.")
        }
    }

    /// How a finished run is summarised.
    private static func sentence(for summary: DiscoverySummary) -> String {
        switch summary.terminationReason {
        case .cancelled: vigilUIString("Stopped.")
        default: summary.devices.isEmpty
            ? vigilUIString("Nothing answered.")
            : vigilUIString("Done.")
        }
    }
}

#endif  // os(macOS)
