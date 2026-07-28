//
//  DeviceInfoService.swift
//  Vigil
//
//  The Info tab's device facts: one `@Observable` object that asks a camera who it is over ISAPI and
//  publishes the answer as an `InspectorDeviceIdentity`, a `StorageInfo` and a named outcome.
//  macOS-only. See docs/UX.md §6.1 and docs/spec-isapi.md §10.1–§10.3 and §15.4.
//
//  ⛔ NOTHING HERE IS SILENT. `VInspectorState` carries `isDeviceLoading` and `isDeviceUnavailable`
//  because the Info tab renders both — skeleton rows while a fetch is in flight, an inline
//  "Unavailable" badge with a retry when it failed (UX.md §6.1: never an alert) — and this is the
//  object that sets them. Every path that leaves a row empty produces a ``DeviceInfoOutcome`` case
//  and logs one line naming it. "No data, no error" is the exact shape this project refuses.
//
//  ⚠️ Secrets. The password is read from the Keychain on each load, handed to `ISAPIClient`, and
//  never stored here; `Credential` masks its own secret in every string conversion. The serial
//  number reaches the log only through `Redact.serial`, because a serial identifies a customer's
//  unit and ends up in pasted bug reports. The *unmasked* serial is published to the inspector on
//  purpose — `InspectorDeviceIdentity.maskedSerialNumber` is what the panel prints by default, and
//  the full value exists so the copy affordance has something to copy.
//
//  The fetch half lives in `DeviceInfoService+Fetch.swift`; the members it touches are `internal`
//  rather than `private` because Swift's `private` is file-scoped and the two halves are two files.
//  The published state keeps `private(set)`, and every write to it is in this file.
//

#if os(macOS)

import CoreGraphics
import Foundation
import ImageIO
import Observation

import VigilCore
import VigilISAPI
import VigilProtocols
import VigilUI

// MARK: - DeviceInfoSection

/// One block of the Info tab, named so a partial answer can say exactly which part is missing.
///
/// A nine-year-old Hikvision camera answers `/System/deviceInfo` and 404s `/ContentMgmt/Storage`;
/// that is a device with no disk, not a device that failed, and the difference has to be
/// representable or the panel would blank rows that are simply not applicable.
enum DeviceInfoSection: String, Sendable, Hashable, CaseIterable {

    /// `/System/deviceInfo` — model, name, firmware, serial, MAC. The only required section.
    case identity

    /// `/System/status` — uptime.
    case status

    /// `/ContentMgmt/Storage` — the volumes and the free-space bar.
    case storage

    /// The channel inventory, which supplies "channel 1 of 8".
    case channels

    /// `/System/Network/interfaces` — read only when `deviceInfo` carried no MAC.
    case network
}

// MARK: - DeviceInfoOutcome

/// What one load did, named. There is no "nothing happened" case.
///
/// Every case is either a success shape or a diagnosed failure; ``isUnavailable`` is what the Info
/// tab's badge reads. The failures are separated by what the *user* would have to do about them,
/// not by which HTTP status produced them, which is why `403` and `404` are different cases and
/// `500` and `503` are the same one.
enum DeviceInfoOutcome: Sendable, Hashable {

    /// Everything the Info tab shows was answered.
    case identified

    /// The device identified itself but did not answer every section. The panel still shows what
    /// arrived; `missing` is for the log and for a diagnostics bundle.
    case partial(missing: [DeviceInfoSection])

    /// No password is stored for this camera yet. Not a failure — the user has not typed one.
    case noCredential

    /// The Keychain would not answer. Carries a description, never the secret.
    case keychainUnavailable(detail: String)

    /// 401 after credentials were supplied: the password is wrong. Terminal (API_CONTRACT R-25).
    case authenticationRejected

    /// Vigil's own lockout counter refused to send. Only a new password clears it — waiting does
    /// not, and every further attempt spends one of the device's five.
    case authenticationBlocked(failures: Int)

    /// The device says the account is locked. `retryAfterSeconds` is its own estimate when it gave
    /// one; the firmware default is 1800 s.
    case accountLocked(retryAfterSeconds: Double?)

    /// The camera has never been activated and has no admin password yet.
    case notActivated

    /// 403: the account exists but may not read this endpoint. A different account would work.
    case permissionDenied(resource: String)

    /// The endpoint does not exist on this firmware. Not an error for anything but `identity`.
    case notSupported(resource: String)

    /// The request did not finish inside its budget. The panel must show "Unavailable", not spin.
    case timedOut(resource: String)

    /// No usable connection: wrong address, device off, or the LAN in between.
    case unreachable(detail: String)

    /// The device answered, and what it sent was not the document it promised — malformed XML, an
    /// HTML login page on a 200, or a `<DeviceInfo>` with no `<model>` in it.
    case malformedResponse(detail: String)

    /// `https://` was asked for and this build cannot evaluate a certificate.
    case tlsUnavailable

    /// The device refused with its own status vocabulary, or with an HTTP status not named above.
    case deviceRefused(detail: String)

    /// A newer load replaced this one, or the panel went away. Never shown.
    case cancelled

    /// True when the Info tab must show its inline "Unavailable" badge.
    ///
    /// `partial` is deliberately **not** unavailable: the device answered, some rows are filled,
    /// and badging the whole panel would hide the answer the user actually got.
    var isUnavailable: Bool {
        switch self {
        case .identified, .partial, .cancelled: false
        default: true
        }
    }

    /// A short, secret-free line for the log and for "copy diagnostics".
    ///
    /// Diagnostic text, not user-facing copy: it is never localised and never shown as a sentence
    /// in the panel, which shows the badge from ``isUnavailable`` instead.
    var summary: String {
        switch self {
        case .identified:
            return "identified"
        case .partial(let missing):
            return "partial, missing: " + missing.map(\.rawValue).joined(separator: ",")
        case .noCredential:
            return "no password stored for this camera"
        case .keychainUnavailable(let detail):
            return "keychain unavailable: \(detail)"
        case .authenticationRejected:
            return "the device rejected the password"
        case .authenticationBlocked(let failures):
            return "blocked locally after \(failures) rejected sign-ins"
        case .accountLocked(let retryAfterSeconds):
            let seconds = retryAfterSeconds.map { String(Int($0)) } ?? "unknown"
            return "the device locked the account; unlocks in \(seconds) s"
        case .notActivated:
            return "the camera has not been activated"
        case .permissionDenied(let resource):
            return "this account may not read \(resource)"
        case .notSupported(let resource):
            return "this firmware has no \(resource)"
        case .timedOut(let resource):
            return "timed out reading \(resource)"
        case .unreachable(let detail):
            return "unreachable: \(detail)"
        case .malformedResponse(let detail):
            return "malformed response: \(detail)"
        case .tlsUnavailable:
            return "https is unavailable in this build"
        case .deviceRefused(let detail):
            return "the device refused: \(detail)"
        case .cancelled:
            return "cancelled"
        }
    }
}

// MARK: - DeviceInfoReading

/// One completed load, before it reaches the published properties.
///
/// A value rather than four `await`-separated writes, so the panel never renders a half-applied
/// state: the whole reading lands on the main actor in one hop.
struct DeviceInfoReading: Sendable {

    /// Everything the Info tab prints about the device, address included.
    var identity: InspectorDeviceIdentity

    /// The volumes, or `nil` when the device has none or would not say.
    var storage: StorageInfo?

    /// What happened, named.
    var outcome: DeviceInfoOutcome
}

// MARK: - DeviceInfoService

/// Fetches and publishes one camera's identity, firmware, uptime and storage.
///
/// **Isolation.** `@MainActor`, because every property here is read during SwiftUI body evaluation.
/// The device work is not: `ISAPIClient` and `ISAPIDeviceSession` are actors, so each `await` in
/// `DeviceInfoService+Fetch.swift` hops off the main actor and back. Nothing blocks, nothing polls,
/// and a camera that never answers costs one `URLSession` timeout — after which
/// ``isDeviceUnavailable`` is set and the panel says so.
///
/// **One camera at a time.** ``load(camera:credentials:force:)`` cancels the load in flight and
/// starts another. A stale task that finishes after a newer one started is discarded by generation
/// number rather than being allowed to overwrite fresher state.
@MainActor
@Observable
final class DeviceInfoService {

    // MARK: - Published state

    /// The device facts, address included. Empty fields render as `—`, which is correct before the
    /// first load and after a failure — the panel's job is not to invent a model number.
    private(set) var identity = InspectorDeviceIdentity()

    /// The device's volumes, or `nil` when `/ContentMgmt/Storage` has not answered or is absent.
    /// `VInspectorState.storage` takes this value directly.
    private(set) var storage: StorageInfo?

    /// True while a load is in flight. Drives `VInspectorState.isDeviceLoading`, which renders the
    /// skeleton bars at the real content's width (DESIGN.md §9.19).
    private(set) var isLoading = false

    /// True when the last load could not identify the device. Drives
    /// `VInspectorState.isDeviceUnavailable`, which renders the inline badge and its retry.
    private(set) var isUnavailable = false

    /// What the last load did. `nil` before the first one.
    private(set) var outcome: DeviceInfoOutcome?

    /// When the published values were last replaced, for a future "as of" line.
    private(set) var updatedAt: Date?

    // MARK: - Dependencies
    //
    // Internal rather than private: `DeviceInfoService+Fetch.swift` reads all four, and Swift's
    // `private` is file-scoped. Nothing outside this target can see the type at all.

    /// Structured logging. Never receives a password or an unmasked serial.
    let logger: any LoggerProtocol

    /// Monotonic time for the ISAPI cache TTLs and the retry backoff. Injected, never `Date()`.
    let clock: any MonotonicClock

    /// The client tunables in force, including the per-request budgets that make an unanswering
    /// camera a failed load rather than a stuck panel.
    let configuration: ISAPIClient.Configuration

    // MARK: - Session state
    //
    // Also internal, and for the same reason: the fetch half owns building and reusing these.

    /// The per-device control plane, built on first load and reused until the address, the account
    /// or the password changes.
    var session: ISAPIDeviceSession?

    /// The client underneath ``session``. Held separately because it is the only object that can be
    /// told a new password, which is the only thing that clears the two-401 hard block (R-25).
    var client: ISAPIClient?

    /// What ``session`` was built for. A change here rebuilds both.
    var sessionKey: SessionKey?

    /// The load in flight.
    private var task: Task<Void, Never>?

    /// Incremented by every ``load(camera:credentials:force:)`` and by ``reset()``, so a task that
    /// finishes after it was superseded cannot write stale values.
    private var generation = 0

    /// What ``retry()`` repeats.
    private var lastRequest: Request?

    // MARK: - Nested types

    /// Identifies the device and account a session was built for.
    ///
    /// The password is represented by ``SecretFingerprint``, never by the secret itself: a retyped
    /// password must rebuild the client (and clear its lockout counter), and retyping the *same*
    /// password must not — that distinction is the whole of docs/RULING-LOCKOUT.md §4.
    struct SessionKey: Sendable, Hashable {
        var host: String
        var port: Int
        var useTLS: Bool
        var account: String
        var credentialRef: CredentialRef
        var secretFingerprint: String
    }

    /// The arguments of the last load, so the panel's retry button needs none.
    private struct Request {
        var camera: Camera
        var credentials: CredentialStore
    }

    // MARK: - Initialisation

    /// Builds a service.
    ///
    /// - Parameters:
    ///   - logger: where every outcome is named. `session.dependencies.logger` in the app.
    ///   - clock: monotonic source for the ISAPI cache TTLs and retry backoff. Pass
    ///     `dependencies.clock` so the whole app measures on one clock.
    ///   - configuration: request budgets. The default shortens the control budget from the
    ///     module's 8 s to 6 s, because this panel is a background nicety and a user staring at a
    ///     skeleton row for eight seconds has already decided the app is broken.
    init(logger: any LoggerProtocol,
         clock: any MonotonicClock = SystemMonotonicClock(),
         configuration: ISAPIClient.Configuration = DeviceInfoService.defaultConfiguration) {
        self.logger = logger
        self.clock = clock
        self.configuration = configuration
    }

    /// The budgets a device-info load runs under.
    ///
    /// A computed property rather than a stored `static let` so the value cannot be mutated in
    /// place by a caller that meant to configure its own copy.
    static var defaultConfiguration: ISAPIClient.Configuration {
        var configuration = ISAPIClient.Configuration()
        configuration.connectTimeout = .seconds(4)
        configuration.controlTimeout = .seconds(6)
        return configuration
    }

    // MARK: - API

    /// Loads everything the Info tab shows for one camera.
    ///
    /// Returns immediately. The load runs in a task that inherits this actor, hops onto the ISAPI
    /// actors for the network work, and lands its result back here in one write.
    ///
    /// Calling this again cancels the load in flight — the panel following a selection change must
    /// not leave two fetches racing to publish two different cameras.
    ///
    /// - Parameters:
    ///   - camera: which device, and where. Supplies the address half of the identity outright, so
    ///     the host and ports are correct even when the device never answers.
    ///   - credentials: the Keychain actor. Read per load, never captured with its secret.
    ///   - force: bypass the ISAPI session's TTL caches. The retry button passes `true`; a routine
    ///     tab activation passes `false` and is usually answered without a round trip.
    func load(camera: Camera, credentials: CredentialStore, force: Bool = false) {
        lastRequest = Request(camera: camera, credentials: credentials)
        task?.cancel()
        generation += 1
        let generation = self.generation
        isLoading = true
        isUnavailable = false
        // The address is known now, so it is published now: an Info tab that shows `:554` with no
        // host in front of it is the defect this half of the identity exists to prevent.
        identity = Self.addressIdentity(for: camera, base: identity)
        task = Task { [weak self] in
            guard let self else { return }
            let reading = await self.produce(camera: camera, credentials: credentials, force: force)
            self.finish(reading, generation: generation)
        }
    }

    /// Fetches one JPEG snapshot from the device and publishes it as ``poster``.
    ///
    /// Silent when there is no session yet, and silent on failure: a camera that refuses the picture
    /// endpoint — some firmwares gate it behind a separate permission — should cost a missing
    /// thumbnail and a debug line, not an error the user has to dismiss. The main picture is
    /// unaffected either way.
    func refreshPoster(channel: ChannelID) async {
        guard let client else { return }
        let route = SnapshotDeviceRoute(requester: client, clock: clock)
        do {
            let jpeg = try await route.fetchJPEG(channel: channel)
            guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 192
                  ] as CFDictionary) else {
                logger.debug(.isapi, "device snapshot: not a decodable JPEG")
                return
            }
            poster = image
        } catch {
            logger.debug(.isapi, "device snapshot unavailable: \(String(describing: error))")
        }
    }

    /// Repeats the last load, bypassing every cache. Wired to `VInspectorActions.onRetryDevice`.
    ///
    /// Does nothing when no camera has been loaded yet, rather than guessing one.
    func retry() {
        guard let lastRequest else {
            logger.debug(.isapi, "device info retry ignored: no camera has been loaded")
            return
        }
        load(camera: lastRequest.camera, credentials: lastRequest.credentials, force: true)
    }

    /// Drops every published value, cancels the load in flight and tears the ISAPI session down.
    ///
    /// Called when the window closes or the camera is disconnected. Idempotent, and safe to call
    /// from a view's `onDisappear`: the session's own shutdown is awaited in a detached hop so the
    /// caller never waits for a socket to close politely.
    func reset() {
        task?.cancel()
        task = nil
        generation += 1
        lastRequest = nil
        identity = InspectorDeviceIdentity()
        storage = nil
        poster = nil
        isLoading = false
        isUnavailable = false
        outcome = nil
        updatedAt = nil
        let outgoing = session
        session = nil
        client = nil
        sessionKey = nil
        guard let outgoing else { return }
        Task { await outgoing.shutdown() }
    }

    // MARK: - Publishing

    /// Lands one reading, unless a newer load has already started.
    ///
    /// The generation check is what makes a slow camera harmless: its answer arrives, finds that
    /// the panel has moved on, and is dropped instead of overwriting the camera now on screen.
    private func finish(_ reading: DeviceInfoReading, generation: Int) {
        guard generation == self.generation else {
            logger.debug(.isapi, "device info discarded: superseded by a newer load")
            return
        }
        isLoading = false
        outcome = reading.outcome
        isUnavailable = reading.outcome.isUnavailable
        identity = reading.identity
        // A failed refresh must not blank a storage bar that was correct a minute ago; only a load
        // that actually read the volumes replaces them.
        if let volumes = reading.storage { storage = volumes }
        updatedAt = Date()
        switch reading.outcome {
        case .identified, .partial, .cancelled:
            logger.info(.isapi, "device info: \(reading.outcome.summary)")
        default:
            logger.warning(.isapi, "device info unavailable: \(reading.outcome.summary)")
        }
    }

    // MARK: - Adapting

    /// Adopts everything this service knows into an inspector state.
    ///
    /// The one call the window needs, and the reason this type publishes an
    /// `InspectorDeviceIdentity` rather than a wire type: `VInspectorState` is assembled from
    /// values, and this is one of them.
    func apply(to state: inout VInspectorState) {
        state.identity = merged(into: state.identity)
        if let storage { state.storage = storage }
        state.isDeviceLoading = isLoading
        state.isDeviceUnavailable = isUnavailable
    }

    /// Overlays what this service knows onto an identity the caller has already built.
    ///
    /// Field by field, and only where this service has something: a caller that filled in the
    /// address from its own `Camera` record keeps that address until a load supplies one, and every
    /// device fact it could not fill stays empty rather than being replaced with a default. The
    /// Info tab renders an empty field as `—`, which is the truthful answer.
    func merged(into base: InspectorDeviceIdentity) -> InspectorDeviceIdentity {
        var out = base
        if !identity.host.isEmpty {
            out.host = identity.host
            out.rtspPort = identity.rtspPort
            out.httpPort = identity.httpPort
            out.usesTLS = identity.usesTLS
            out.channel = identity.channel
        }
        if !identity.model.isEmpty { out.model = identity.model }
        if !identity.deviceName.isEmpty { out.deviceName = identity.deviceName }
        if !identity.firmwareVersion.isEmpty { out.firmwareVersion = identity.firmwareVersion }
        if let released = identity.firmwareReleased, !released.isEmpty {
            out.firmwareReleased = released
        }
        if !identity.serialNumber.isEmpty { out.serialNumber = identity.serialNumber }
        if !identity.macAddress.isEmpty { out.macAddress = identity.macAddress }
        if identity.totalChannels > 1 { out.totalChannels = identity.totalChannels }
        if identity.uptimeSeconds > 0 { out.uptimeSeconds = identity.uptimeSeconds }
        return out
    }

    /// The half of the identity that comes from the camera record rather than from the device.
    ///
    /// Separate because it is known before any request goes out and stays true when every request
    /// fails: the address, the ports, the TLS flag and the channel are Vigil's own facts.
    static func addressIdentity(for camera: Camera,
                                base: InspectorDeviceIdentity) -> InspectorDeviceIdentity {
        var out = base
        out.host = camera.host
        out.httpPort = camera.httpPort
        out.rtspPort = camera.rtspPort
        out.usesTLS = camera.useTLS
        out.channel = camera.channel
        return out
    }
}

#endif  // os(macOS)
