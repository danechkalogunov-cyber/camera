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

// MARK: - ImageResetOutcome

/// What pressing *Reset to Defaults* achieved.
///
/// Four answers rather than a `Bool`, because the three failures are not the same failure and a
/// user who is told only "it didn't work" cannot tell a camera that refuses the endpoint from one
/// that was already at its defaults.
enum ImageResetOutcome: Sendable, Hashable {

    /// The camera accepted it and its picture settings changed.
    case reset

    /// The camera has no working reset command — it answered the device's own reset with the
    /// carried reason — so Vigil wrote the documented default values through the sub-resources
    /// instead, and those went through.
    ///
    /// Deliberately not folded into ``reset``. A device reset also restores the controls Vigil does
    /// not model — exposure, white balance, gamma — and claiming one happened when it did not would
    /// leave a user wondering why their exposure is still wrong.
    case documentedDefaults(String)

    /// The camera accepted it and reported the same settings afterwards — which is the honest
    /// answer for a camera that was already sitting at its factory values.
    case unchanged

    /// The device refused, with its own named reason.
    case refused(String)

    /// There was no ISAPI session to ask. Before a camera is connected, or after it dropped.
    case unavailable
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

    /// The camera's own JPEG snapshot, decoded small, for the sidebar's thumbnail.
    ///
    /// **Why the device and not the video path.** The decode pipeline is passthrough: an
    /// `EncodedFrame` becomes a `CMBlockBuffer` and then a `CMSampleBuffer` of *compressed* data,
    /// which `AVSampleBufferDisplayLayer` decodes internally and never hands back
    /// (`.vigil/SLICE.md`: "No `VTDecompressionSession`"). There is no decoded pixel buffer anywhere
    /// in this app, so a thumbnail cannot be taken from the stream at all.
    ///
    /// The camera will render one itself over ISAPI as a JPEG. One small HTTP GET every few seconds
    /// costs nothing on the media path and needs no decoding here.
    private(set) var poster: CGImage?

    /// The camera's picture controls, as the device reports them.
    ///
    /// `nil` until the Image tab has been opened once — these are four HTTP reads per channel and
    /// there is no reason to spend them on a panel nobody has looked at.
    private(set) var image: InspectorImageSettings?

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

    /// Reads the camera's picture controls into ``image``.
    ///
    /// Silent on failure, like the poster: a firmware that does not expose a control leaves that row
    /// at its default rather than failing the whole panel. `ImageSettings` is `Optional` field by
    /// field for the same reason.
    func loadImageSettings(channel: ChannelID, force: Bool = false) async {
        guard let session else { return }
        do {
            let settings = try await session.imageSettings(channel: channel, force: force)
            image = Self.inspectorImage(from: settings)
        } catch {
            logger.debug(.isapi, "image settings unavailable: \(String(describing: error))")
        }
    }

    /// Applies the panel's whole picture set to the camera.
    ///
    /// **Published first, written second.** The panel's sliders are computed `Binding`s whose getter
    /// reads this property, so until it changes the control snaps back to where it was — which is
    /// what made a drag look like it did nothing. Showing the requested value immediately is what
    /// lets a slider move at all; the device's own answer replaces it a moment later, so a camera
    /// that clamps or refuses still wins.
    ///
    /// Only the nodes that actually differ are sent. The panel hands over the entire set on every
    /// change, and writing all six ISAPI nodes for one slider would be five needless round trips and
    /// five more chances to leave the camera half-adjusted.
    ///
    /// **Everything here is the camera's own setting.** There is no local image processing anywhere
    /// in Vigil — the decode path is passthrough, straight from the network into
    /// `AVSampleBufferDisplayLayer` — so every control on this tab is an ISAPI write to
    /// `/Image/channels/{ch}/…` and the picture changes at the sensor, for everyone watching.
    /// ⚠️ That is also why "Adjust my view only" only *withholds* the write: honouring it properly
    /// needs a render-path adjustment stage that does not exist. Reported in ЧТО-НЕ-СДЕЛАНО.md.
    ///
    /// - Returns: `false` when the device refused at least one of the nodes that changed. The panel
    ///   ignores it — a refused write has already put the control back — but the reset fallback
    ///   needs to know whether writing the standard values actually reached the camera.
    @discardableResult
    func writeImage(channel: ChannelID, _ wanted: InspectorImageSettings) async -> Bool {
        guard let session else { return false }
        let previous = image ?? InspectorImageSettings()
        image = wanted

        guard !wanted.isLocalPreviewOnly else {
            logger.info(.isapi, "image write withheld: adjust-my-view-only is on")
            return true
        }
        var accepted = true

        if wanted.brightness != previous.brightness || wanted.contrast != previous.contrast
            || wanted.saturation != previous.saturation {
            let ok = await apply(channel: channel) {
                try await session.setImageColor(channel: channel,
                                                brightness: wanted.brightness,
                                                contrast: wanted.contrast,
                                                saturation: wanted.saturation)
            }
            accepted = accepted && ok
        }
        if wanted.sharpness != previous.sharpness {
            let ok = await apply(channel: channel) {
                try await session.setSharpness(channel: channel, wanted.sharpness)
            }
            accepted = accepted && ok
        }
        if wanted.wdrMode != previous.wdrMode || wanted.wdrLevel != previous.wdrLevel {
            let mode: WDRSetting.Mode = switch wanted.wdrMode {
            case .on:   .open
            case .off:  .close
            case .auto: .auto
            }
            let ok = await apply(channel: channel) {
                try await session.setWDR(channel: channel,
                                         WDRSetting(mode: mode, level: wanted.wdrLevel))
            }
            accepted = accepted && ok
        }
        // `schedule` is deliberately not sent. `ISAPIDeviceSession.setIRCut` refuses it, because the
        // mode carries a switching schedule Vigil does not model and writing the mode alone would
        // discard the user's own times. The segment stays selectable so a camera already in that
        // mode reports it honestly; choosing it here simply changes nothing on the device.
        if wanted.dayNightMode != previous.dayNightMode, wanted.dayNightMode != .schedule {
            let mode: IRCutSetting.Mode = switch wanted.dayNightMode {
            case .day:      .day
            case .night:    .night
            case .auto:     .auto
            case .schedule: .auto       // unreachable: excluded by the guard above
            }
            let ok = await apply(channel: channel) {
                // The two thresholds are `nil` on purpose. Every image write is a read-modify-write,
                // so an omitted element keeps whatever the device already had — passing a guess here
                // would overwrite the user's own night-to-day tuning with one.
                try await session.setIRCut(channel: channel,
                                           IRCutSetting(mode: mode,
                                                        nightToDayLevel: nil,
                                                        nightToDaySeconds: nil))
            }
            accepted = accepted && ok
        }
        if wanted.irMode != previous.irMode || wanted.irLevel != previous.irLevel {
            // The panel's tri-state is two device fields. `off` closes the lamp; `auto` and `on`
            // both leave it emitting and differ only in who picks the brightness — which is exactly
            // what `mixedLightBrightnessRegulatMode` says.
            let lamp = SupplementLightSetting(
                mode: wanted.irMode == .off ? .close : .irLight,
                regulation: wanted.irMode == .on ? .manual : .auto,
                brightness: wanted.irLevel)
            let ok = await apply(channel: channel) {
                try await session.setSupplementLight(channel: channel, lamp)
            }
            accepted = accepted && ok
        }
        if wanted.flip != previous.flip {
            let style: FlipSetting.Style? = switch wanted.flip {
            case .off:        nil
            case .centre:     .centre
            case .horizontal: .horizontal
            case .vertical:   .vertical
            }
            let ok = await apply(channel: channel) {
                // Switching off keeps the previous axis rather than clearing it, so turning the
                // flip back on restores what the user chose instead of reverting to `CENTER`.
                try await session.setFlip(channel: channel,
                                          FlipSetting(isEnabled: style != nil, style: style))
            }
            accepted = accepted && ok
        }
        return accepted
    }

    /// Restores the camera's factory picture settings and re-reads them.
    ///
    /// **Reports what happened, and never nothing.** This used to swallow every outcome into a log
    /// line, so a device that refused the endpoint outright and a device that reset perfectly looked
    /// identical from the panel: the button appeared to do nothing either way. The three answers are
    /// now distinguishable by the caller, which is what lets the window say which one it was.
    ///
    /// The second read is not belt-and-braces. `PUT …/defaultConfiguration` returns as soon as the
    /// camera has accepted it, and several firmwares apply the values a moment later — so a single
    /// confirming read can legitimately still hold the old panel and make a successful reset look
    /// like a no-op.
    ///
    /// **The fallback, and why it is not cheating.** Plenty of firmwares answer this endpoint with
    /// `statusCode 4 / invalidOperation` — the resource is documented (spec-isapi.md §17.2 row
    /// "Defaults") but not implemented on that model. When that happens Vigil writes the documented
    /// default values through the sub-resources that *do* work, which is what the button was asked
    /// to achieve. It is announced as such rather than reported as a device reset, because the two
    /// are not the same thing: a device reset also restores the controls Vigil does not model.
    @discardableResult
    func resetImage(channel: ChannelID) async -> ImageResetOutcome {
        guard let session else {
            logger.error(.isapi, "image reset ignored: no ISAPI session for this camera")
            return .unavailable
        }
        let before = image
        do {
            try await session.resetImageDefaults(channel: channel)
        } catch {
            let reason = String(describing: error)
            logger.error(.isapi, "image reset refused by the device: \(reason)")
            return await applyDocumentedDefaults(channel: channel, after: reason)
        }
        await loadImageSettings(channel: channel, force: true)
        if image != before {
            logger.info(.isapi, "image reset applied")
            return .reset
        }
        try? await Task.sleep(for: .milliseconds(900))
        await loadImageSettings(channel: channel, force: true)
        if image != before {
            logger.info(.isapi, "image reset applied after a settling delay")
            return .reset
        }
        logger.info(.isapi, "image reset accepted but nothing changed")
        return .unchanged
    }

    /// Writes the picture values the ISAPI specification gives as defaults.
    ///
    /// The set is `InspectorImageSettings()`'s own defaults, which are the documented ones:
    /// brightness, contrast, saturation and sharpness at 50 (spec-isapi.md §17.2), WDR closed,
    /// day/night automatic, the supplement lamp on automatic and no flip. `writeImage` already
    /// sends only the nodes that differ and reconciles each with the device's answer, so a camera
    /// that clamps a value still ends up showing what it actually kept.
    private func applyDocumentedDefaults(channel: ChannelID,
                                         after reason: String) async -> ImageResetOutcome {
        let before = image
        logger.info(.isapi, "writing the documented image defaults instead")
        guard await writeImage(channel: channel, InspectorImageSettings()) else {
            return .refused(reason)
        }
        return image == before ? .unchanged : .documentedDefaults(reason)
    }

    /// Runs one image write and republishes whatever the device answers.
    ///
    /// On refusal the panel is put back to what the camera last reported, so a control cannot be
    /// left showing a value the device never accepted.
    private func apply(channel: ChannelID,
                       _ write: () async throws -> ImageSettings) async -> Bool {
        do {
            image = Self.inspectorImage(from: try await write())
            return true
        } catch {
            logger.error(.isapi, "image write refused: \(String(describing: error))")
            await loadImageSettings(channel: channel, force: true)
            return false
        }
    }

    /// Restates the device's picture controls in the panel's vocabulary.
    ///
    /// Every field the device omits keeps the panel's default, which is what `InspectorImageSettings`
    /// renders as unavailable — never a fabricated midpoint.
    private static func inspectorImage(from settings: ImageSettings) -> InspectorImageSettings {
        var out = InspectorImageSettings()
        if let value = settings.brightness { out.brightness = value }
        if let value = settings.contrast { out.contrast = value }
        if let value = settings.saturation { out.saturation = value }
        if let value = settings.sharpness { out.sharpness = value }
        if let wdr = settings.wdr {
            switch wdr.mode {
            case .open:  out.wdrMode = .on
            case .close: out.wdrMode = .off
            case .auto:  out.wdrMode = .auto
            }
            if let level = wdr.level { out.wdrLevel = level }
        }
        if let ir = settings.irCut {
            switch ir.mode {
            case .day:      out.dayNightMode = .day
            case .night:    out.dayNightMode = .night
            case .auto:     out.dayNightMode = .auto
            case .schedule: out.dayNightMode = .schedule
            default:        break
            }
        }
        if let lamp = settings.supplementLight {
            // `on` means the user is choosing the brightness, `auto` means the camera is. A device
            // that reports no regulation element at all is choosing it itself, so it reads as auto.
            out.irMode = lamp.mode == .close ? .off : (lamp.regulation == .manual ? .on : .auto)
            if let brightness = lamp.brightness { out.irLevel = brightness }
        }
        if let flip = settings.flip {
            switch flip.style {
            case .centre?:     out.flip = flip.isEnabled ? .centre : .off
            case .horizontal?: out.flip = flip.isEnabled ? .horizontal : .off
            case .vertical?:   out.flip = flip.isEnabled ? .vertical : .off
            case nil:          out.flip = .off
            }
        }
        return out
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
