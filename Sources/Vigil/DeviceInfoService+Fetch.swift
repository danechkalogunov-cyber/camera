//
//  DeviceInfoService+Fetch.swift
//  Vigil
//
//  The other half of `DeviceInfoService`: building the per-device ISAPI session, reading the four
//  endpoints the Info tab needs, and turning every `ISAPIError` into a named `DeviceInfoOutcome`.
//  macOS-only. See docs/spec-isapi.md §10.1 (`deviceInfo`), §10.3 (`status`), §11 (channels) and
//  §15.4 (storage).
//
//  ⛔ ONE ENDPOINT IS REQUIRED AND THE REST ARE NOT. `/System/deviceInfo` is the identity anchor: a
//  device that will not answer it has not been identified, and the panel says "Unavailable". Uptime,
//  the channel count, the MAC fallback and the volumes are each read best-effort, because a
//  nine-year-old camera legitimately 404s two of them — so each failure names its section in
//  ``DeviceInfoOutcome/partial(missing:)`` and writes one log line, instead of failing the load or
//  leaving a row silently blank.
//
//  ⛔ NOTHING HERE BLOCKS. Every `await` below is a hop onto `ISAPIClient` or `ISAPIDeviceSession`,
//  both actors; there is no lock, no semaphore and no polling loop anywhere in this file. A camera
//  that never answers is bounded by `ISAPIClient.Configuration.controlTimeout`, which surfaces as
//  `.timedOut` and therefore as `isDeviceUnavailable` — never as a panel that spins for ever.
//

#if os(macOS)

import Foundation

import VigilCore
import VigilISAPI
import VigilProtocols
import VigilUI

// MARK: - The load

extension DeviceInfoService {

    /// Reads one camera and returns everything the panel needs, or a named reason it could not.
    ///
    /// Never throws: the caller is a `Task` whose only job is to publish, and an error that escaped
    /// here would become the "no data, no error" state the panel must never be in. Every failure is
    /// a ``DeviceInfoOutcome`` case instead.
    ///
    /// - Parameters:
    ///   - camera: the device record. Supplies the address half of the identity outright.
    ///   - credentials: the Keychain actor, read once per load.
    ///   - force: drop the ISAPI session's TTL caches *and* its negative-capability cache first, so
    ///     a retry re-asks endpoints an earlier load recorded as absent.
    func produce(camera: Camera, credentials: CredentialStore,
                 force: Bool) async -> DeviceInfoReading {
        let address = Self.addressIdentity(for: camera, base: identity)

        let credential: Credential
        do {
            // `nil` is a normal answer, not a failure: this camera's password has not been typed
            // yet (spec-core §6.4). It is reported as its own outcome so the panel can say so.
            guard let stored = try await credentials.credential(for: camera) else {
                return DeviceInfoReading(identity: address, storage: nil, outcome: .noCredential)
            }
            credential = stored
        } catch {
            // `String(describing:)` on a `CredentialError` names the OSStatus and the operation and
            // carries no secret; `Credential` never reaches this path at all.
            return DeviceInfoReading(identity: address, storage: nil,
                                     outcome: .keychainUnavailable(detail: String(describing: error)))
        }

        let session = await deviceSession(for: camera, credential: credential)
        if force { await session.invalidateCaches() }
        if Task.isCancelled {
            return DeviceInfoReading(identity: address, storage: nil, outcome: .cancelled)
        }

        let info: DeviceInfo
        do {
            info = try await session.deviceInfo()
        } catch {
            logger.warning(.isapi, "device did not identify itself",
                           ["host": camera.host,
                            "reason": error.userMessageKey,
                            "code": error.diagnosticCode])
            return DeviceInfoReading(identity: address, storage: nil,
                                     outcome: Self.outcome(for: error))
        }

        var identity = address
        identity.model = info.model
        identity.deviceName = info.deviceName
        identity.firmwareVersion = info.firmwareVersion.raw
        identity.firmwareReleased = Self.displayReleaseDate(info.firmwareReleasedDate)
        // The full serial is published deliberately: the panel prints `maskedSerialNumber` and the
        // copy affordance needs the real one. It never reaches a log line unmasked.
        identity.serialNumber = info.serialNumber
        identity.macAddress = info.macAddress ?? ""

        logger.info(.isapi, "device identified",
                    ["host": camera.host,
                     "model": info.model,
                     "firmware": info.firmwareVersion.raw,
                     "serial": Redact.serial(info.serialNumber),
                     "mac": Redact.mac(identity.macAddress, level: .info)])

        var missing: [DeviceInfoSection] = []
        identity.uptimeSeconds = await uptimeSeconds(from: session, missing: &missing)
        identity.totalChannels = await channelCount(from: session, missing: &missing)
        if identity.macAddress.isEmpty {
            identity.macAddress = await macAddress(from: session, missing: &missing)
        }
        let volumes = await storageInfo(from: session, missing: &missing)

        if Task.isCancelled {
            return DeviceInfoReading(identity: identity, storage: volumes, outcome: .cancelled)
        }
        let outcome: DeviceInfoOutcome = missing.isEmpty ? .identified : .partial(missing: missing)
        return DeviceInfoReading(identity: identity, storage: volumes, outcome: outcome)
    }

    // MARK: - The optional sections
    //
    // Each of the four returns a usable value and appends to `missing` rather than throwing. That
    // is the whole difference between "the device has no disk" and "the panel is broken".

    /// `GET /System/status` for the uptime row, or `0` and a named missing section.
    private func uptimeSeconds(from session: ISAPIDeviceSession,
                               missing: inout [DeviceInfoSection]) async -> Double {
        do {
            return try await session.status().uptime
        } catch {
            missing.append(.status)
            logger.notice(.isapi, "device uptime unavailable",
                          ["reason": error.userMessageKey, "code": error.diagnosticCode])
            return 0
        }
    }

    /// The channel inventory, for the `channel 1 of 8` row. Falls back to `1`, which is the truth
    /// for a camera and the safe understatement for a recorder that would not answer.
    private func channelCount(from session: ISAPIDeviceSession,
                              missing: inout [DeviceInfoSection]) async -> Int {
        do {
            let channels = try await session.channels()
            guard !channels.isEmpty else {
                missing.append(.channels)
                logger.notice(.isapi, "device reported no channels; assuming one")
                return 1
            }
            return channels.count
        } catch {
            missing.append(.channels)
            logger.notice(.isapi, "channel inventory unavailable",
                          ["reason": error.userMessageKey, "code": error.diagnosticCode])
            return 1
        }
    }

    /// `GET /System/Network/interfaces`, read **only** when `<deviceInfo>` carried no `macAddress`.
    ///
    /// Several firmwares omit the element from `deviceInfo` and report it here instead, and a MAC
    /// is the one field in the Info tab a user can check against a label on the device itself.
    /// Returns the empty string when nothing answered, which the panel renders as `—`.
    private func macAddress(from session: ISAPIDeviceSession,
                            missing: inout [DeviceInfoSection]) async -> String {
        do {
            let interfaces = try await session.networkInterfaces()
            let found = interfaces.compactMap(\.macAddress).first { !$0.isEmpty }
            guard let found else {
                missing.append(.network)
                logger.notice(.isapi, "no interface reported a MAC address")
                return ""
            }
            return found
        } catch {
            missing.append(.network)
            logger.notice(.isapi, "network interfaces unavailable",
                          ["reason": error.userMessageKey, "code": error.diagnosticCode])
            return ""
        }
    }

    /// `GET /ContentMgmt/Storage` for the capacity bar, or `nil` and a named missing section.
    ///
    /// A device that answers with an empty volume list is reported as missing too: `VInspectorState`
    /// hides the storage block when `storage` is `nil`, and an all-zero bar would be a fabrication.
    private func storageInfo(from session: ISAPIDeviceSession,
                             missing: inout [DeviceInfoSection]) async -> StorageInfo? {
        do {
            let volumes = try await session.storage()
            guard !volumes.volumes.isEmpty else {
                missing.append(.storage)
                logger.info(.isapi, "device reports no storage volumes")
                return nil
            }
            if volumes.needsAttention {
                logger.warning(.isapi, "a device volume needs attention",
                               ["workMode": volumes.workMode])
            }
            return volumes
        } catch {
            missing.append(.storage)
            logger.notice(.isapi, "device storage unavailable",
                          ["reason": error.userMessageKey, "code": error.diagnosticCode])
            return nil
        }
    }

    // MARK: - The session

    /// The control plane for one camera, built once and reused.
    ///
    /// Rebuilt when the address, the account or the **password** changes. The password is compared
    /// by `SecretFingerprint`, never by value, and a genuine change additionally calls
    /// `setCredential`, which is the only thing that clears `ISAPIClient`'s two-401 hard block
    /// (API_CONTRACT §2 R-25, docs/RULING-LOCKOUT.md §4). Retyping the same password clears nothing,
    /// which matters because that is the most likely route to a real thirty-minute lockout.
    ///
    /// `ISAPIClient` is built here rather than left to `ISAPIDeviceSession`'s convenience
    /// initialiser precisely so that the client is reachable for that call.
    func deviceSession(for camera: Camera, credential: Credential) async -> ISAPIDeviceSession {
        let key = SessionKey(host: camera.host,
                             port: camera.httpPort,
                             useTLS: camera.useTLS,
                             account: credential.account,
                             credentialRef: credential.ref,
                             secretFingerprint: SecretFingerprint.of(credential))
        if let session, sessionKey == key { return session }

        let previous = sessionKey
        if let outgoing = session {
            // Off the caller's path: shutting a session down stops PTZ keep-alives and the alert
            // stream, and a new device-info load must not wait for either.
            Task { await outgoing.shutdown() }
        }

        let endpoint = ISAPIEndpoint(host: camera.host, port: camera.httpPort,
                                     useTLS: camera.useTLS)
        let created = ISAPIClient(endpoint: endpoint,
                                  credential: credential,
                                  configuration: configuration,
                                  transport: URLSessionHTTPTransport(configuration: configuration,
                                                                     logger: logger),
                                  clock: clock,
                                  logger: logger)
        // Only a *different* password resets the counter. `setCredential` is idempotent otherwise,
        // but calling it unconditionally would hand every retry of a wrong password a fresh budget.
        if let previous, previous.secretFingerprint != key.secretFingerprint {
            await created.setCredential(credential)
            logger.info(.isapi, "device info: new password; ISAPI auth counter cleared")
        }
        let built = ISAPIDeviceSession(requests: created,
                                       gate: created,
                                       configuration: configuration,
                                       clock: clock,
                                       wallClock: SystemWallClock(),
                                       logger: logger)
        session = built
        client = created
        sessionKey = key
        return built
    }

    // MARK: - Naming failures

    /// Maps the ISAPI error vocabulary onto the outcomes the Info tab distinguishes.
    ///
    /// Exhaustive with no `default`, deliberately: a case added to `ISAPIError` must fail this
    /// switch to compile rather than fall into a bucket that means nothing to the user.
    ///
    /// The grouping is by *what the user would do about it*, not by HTTP status — which is why 403
    /// and 404 are different outcomes while 500 and 503 are the same one.
    static func outcome(for error: ISAPIError) -> DeviceInfoOutcome {
        switch error {
        case .cancelled:
            .cancelled
        case .authenticationFailed:
            .authenticationRejected
        case .authBlockedLocally(let failures):
            .authenticationBlocked(failures: failures)
        case .accountLocked(let retryAfter):
            .accountLocked(retryAfterSeconds: retryAfter)
        case .deviceNotActivated:
            .notActivated
        case .insufficientPermission(let resource):
            .permissionDenied(resource: resource)
        case .notSupported(let resource), .notFound(let resource):
            .notSupported(resource: resource)
        case .timedOut(let resource, _):
            .timedOut(resource: resource)
        case .notConnected(let detail):
            .unreachable(detail: detail)
        case .streamEnded:
            .unreachable(detail: "the device closed the connection")
        case .malformedResponse(let detail):
            .malformedResponse(detail: detail)
        case .unexpectedContentType(let expected, let got):
            .malformedResponse(detail: "expected \(expected), received \(got ?? "no content type")")
        case .multipartProtocolError(let detail):
            .malformedResponse(detail: detail)
        case .partTooLarge, .responseTooLarge:
            .malformedResponse(detail: "the response exceeded its size cap")
        case .tlsUnavailableOnThisPlatform:
            .tlsUnavailable
        case .unsupportedAuthentication(let scheme):
            .deviceRefused(detail: "unsupported authentication scheme \(scheme)")
        case .device(let statusCode, let sub):
            .deviceRefused(detail: "device status \(statusCode) \(sub ?? "")")
        case .http(let status, let resource):
            .deviceRefused(detail: "HTTP \(status) at \(resource)")
        case .deviceBusy:
            .deviceRefused(detail: "the device is busy")
        case .rebootRequired:
            .deviceRefused(detail: "the change needs a device reboot")
        }
    }

    /// The firmware release string as the Info tab should print it.
    ///
    /// Passed through verbatim after trimming, and **not** parsed as a date: Hikvision's
    /// `<firmwareReleasedDate>` is `build 190923` on most firmware and `2022-03-15` on some, so
    /// anything that assumed a date would print nothing for the majority of real cameras.
    /// `nil` for an absent or blank value, which the panel renders as `—`.
    static func displayReleaseDate(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

#endif  // os(macOS)
