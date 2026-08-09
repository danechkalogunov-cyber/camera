//
//  LiveStreamDoctor.swift
//  Vigil
//
//  Connects the pure eleven-stage doctor to live TCP, ISAPI, RTSP and RTP evidence.
//

#if os(macOS)

import AppKit
import Foundation

import VigilCore
import VigilDiscovery
import VigilProtocols
import VigilTransport

// MARK: - Shared probe caches

/// Runs the TCP/OPTIONS prefix once although four report rows consume it.
private actor DoctorPrefixCache {
    private let targetCamera: Camera
    private let logger: any LoggerProtocol
    private var cached: ManualConnectionTestResult?

    init(camera: Camera, logger: any LoggerProtocol) {
        self.targetCamera = camera
        self.logger = logger
    }

    func result() async -> ManualConnectionTestResult? {
        if let cached { return cached }
        guard let host = IPv4Address(targetCamera.host),
              let http = UInt16(exactly: targetCamera.httpPort),
              let rtsp = UInt16(exactly: targetCamera.rtspPort) else { return nil }
        let environment = LiveDiscoveryEnvironment.make(logger: logger)
        let result = await ManualConnectionTest(environment: environment)
            .run(host: host, httpPort: http, rtspPort: rtsp, useTLS: targetCamera.useTLS)
        cached = result
        return result
    }
}

fileprivate struct DoctorMediaEvidence: Sendable {
    var resolvedAddress = false
    var connectedRTSP = false
    var answeredOptions = false
    var described = false
    var codec: VideoCodec?
    var receivedRTP = false
    var receivedKeyframe = false
    var qualityFailure: StreamDoctorFailure?
    var qualityDetail: String?
    var streamFailure: StreamError.Code?
}

/// Runs a disposable, no-decoder controller once and shares its observations across rows 6...11.
private actor DoctorMediaCache {
    private let targetCamera: Camera
    private let credentials: CredentialStore
    private let dependencies: CoreDependencies
    private var cached: DoctorMediaEvidence?

    init(camera: Camera, credentials: CredentialStore, dependencies: CoreDependencies,
         initialEvidence: DoctorMediaEvidence? = nil) {
        self.targetCamera = camera
        self.credentials = credentials
        self.dependencies = dependencies
        self.cached = initialEvidence
    }

    private func loadEvidence() async -> DoctorMediaEvidence {
        if let cached { return cached }
        let store = credentials
        let target = targetCamera
        let provider: @Sendable () async throws -> Credential? = {
            try await store.credential(for: target)
        }
        let controller = StreamController(
            camera: targetCamera,
            credentialProvider: provider,
            initialPriority: .background,
            dependencies: dependencies,
            policy: ReconnectPolicy(delays: [.seconds(30)], jitterFraction: 0,
                                    maxAttemptsBeforeCold: 1))
        let events = controller.events()
        await controller.start()
        let result = await Self.observe(events: events)
        await controller.stop(reason: .userRequested)
        cached = result
        return result
    }

    fileprivate func evidence() async -> DoctorMediaEvidence { await loadEvidence() }

    private static func observe(events: AsyncStream<StreamEvent>) async -> DoctorMediaEvidence {
        await withTaskGroup(of: DoctorMediaEvidence.self) { group in
            group.addTask {
                var evidence = DoctorMediaEvidence()
                var qualitySamples = 0
                for await event in events {
                    if Task.isCancelled { return evidence }
                    switch event {
                    case .stateChanged(_, let state, _):
                        switch state {
                        case .connecting:
                            evidence.resolvedAddress = true
                        case .authenticating:
                            evidence.resolvedAddress = true
                            evidence.connectedRTSP = true
                        case .describing:
                            evidence.resolvedAddress = true
                            evidence.connectedRTSP = true
                            evidence.answeredOptions = true
                        case .settingUp, .playing, .degraded:
                            evidence.resolvedAddress = true
                            evidence.connectedRTSP = true
                            evidence.answeredOptions = true
                        default:
                            break
                        }
                    case .authenticated:
                        evidence.connectedRTSP = true
                        evidence.answeredOptions = true
                    case .formatResolved(let format):
                        evidence.described = true
                        evidence.codec = format.videoCodec
                    case .firstPacketReceived:
                        evidence.receivedRTP = true
                    case .firstFrameAssembled:
                        evidence.receivedRTP = true
                    case .keyframe:
                        evidence.receivedKeyframe = true
                    case .statistics(let statistics):
                        guard evidence.receivedRTP else { continue }
                        qualitySamples += 1
                        if statistics.lossFraction > 0.10 {
                            evidence.qualityFailure = .highLoss
                            evidence.qualityDetail = String(
                                format: "%.1f%% packet loss", statistics.lossFraction * 100)
                        } else if statistics.jitterMilliseconds > 120 {
                            evidence.qualityFailure = .highJitter
                            evidence.qualityDetail = String(
                                format: "%.0f ms jitter", statistics.jitterMilliseconds)
                        } else if statistics.bitsPerSecond > 0,
                                  statistics.bitsPerSecond < 64_000 {
                            evidence.qualityFailure = .lowBitrate
                            evidence.qualityDetail = String(
                                format: "%.0f kbit/s", statistics.bitsPerSecond / 1_000)
                        }
                        if qualitySamples >= 5 { return evidence }
                    case .error(let error, _):
                        evidence.streamFailure = error.code
                        return evidence
                    case .ended:
                        return evidence
                    default:
                        break
                    }
                }
                return evidence
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(17))
                return DoctorMediaEvidence()
            }
            let first = await group.next() ?? DoctorMediaEvidence()
            group.cancelAll()
            return first
        }
    }
}

// MARK: - App projection

@MainActor
private final class DoctorProgressRelay {
    private let reportWindowState: MainWindowState

    init(window: MainWindowState) { self.reportWindowState = window }

    nonisolated func publish(_ step: StreamDoctorStep, _ outcome: StreamDoctorOutcome) {
        Task { @MainActor [weak self] in
            self?.reportWindowState.streamDoctorOutcomes[step] = outcome
        }
    }
}

extension MainWindowView {
    /// Executes the real probes while the sheet publishes each pass/fail/skip transition.
    func beginStreamDoctor(camera: Camera) {
        window.streamDoctorTask?.cancel()
        window.streamDoctorCameraName = camera.displayName
        window.streamDoctorCameraID = camera.id
        window.streamDoctorOutcomes = [:]
        window.streamDoctorFailures = [:]
        window.streamDoctorDetails = [:]
        window.isStreamDoctorRunning = true
        window.sheet = .streamDoctor

        let prefix = DoctorPrefixCache(camera: camera, logger: session.dependencies.logger)
        let activeStream = session.cameras.stream(for: camera.id)
        let initialEvidence = activeStream.flatMap(Self.activeDoctorEvidence)
        let media = DoctorMediaCache(camera: camera, credentials: session.credentials,
                                     dependencies: session.dependencies,
                                     initialEvidence: initialEvidence)
        let infoService = deviceInfo
        let credentialStore = session.credentials
        let relay = DoctorProgressRelay(window: window)
        let progress: StreamDoctor.Progress = { step, outcome in relay.publish(step, outcome) }
        var probes: [StreamDoctorStep: StreamDoctor.DetailedProbe] = [:]

        probes[.addressResolution] = {
            if let result = await prefix.result() {
                let alive = result.http.provesHostAlive || result.rtsp.provesHostAlive
                return alive ? .pass("address answered") : .fail(.hostNotFound)
            }
            let evidence = await media.evidence()
            return evidence.resolvedAddress ? .pass("name resolved") : .fail(.hostNotFound)
        }
        probes[.tcpRTSP] = {
            if let result = await prefix.result() {
                return result.rtsp == .open ? .pass("port open") : .fail(.rtspPortClosed)
            }
            let evidence = await media.evidence()
            return evidence.connectedRTSP ? .pass("connected") : .fail(.rtspPortClosed)
        }
        probes[.tcpHTTP] = {
            guard let result = await prefix.result() else {
                // Hostname cameras are verified by the ISAPI request in the next row.
                return .pass("checked with ISAPI")
            }
            return result.http == .open ? .pass("port open") : .fail(.httpPortClosed)
        }
        probes[.options] = {
            if let result = await prefix.result() {
                return result.speaksRTSP ? .pass("RTSP response") : .fail(.notAnRTSPServer)
            }
            let evidence = await media.evidence()
            return evidence.answeredOptions ? .pass("RTSP response") : .fail(.notAnRTSPServer)
        }
        probes[.isapiDeviceInfo] = {
            let reading = await Task { @MainActor in
                await infoService.produce(camera: camera, credentials: credentialStore, force: true)
            }.value
            switch reading.outcome {
            case .identified, .partial:
                return .pass("Hikvision device identified")
            case .notActivated:
                return .fail(.notActivated)
            case .authenticationRejected, .authenticationBlocked:
                return .fail(.authFailed)
            case .accountLocked:
                return .fail(.accountLocked)
            case .cancelled:
                return .fail(.cancelled)
            default:
                return .fail(.notHikvision, detail: reading.outcome.summary)
            }
        }
        probes[.describeAnonymous] = {
            let evidence = await media.evidence()
            return (evidence.described || evidence.streamFailure == .authenticationFailed)
                ? .pass("challenge or SDP received")
                : .fail(.describeChallengeMissing, detail: evidence.streamFailure?.rawValue)
        }
        probes[.describeAuthenticated] = {
            let evidence = await media.evidence()
            if evidence.described { return .pass("SDP received") }
            return .fail(Self.doctorFailure(for: evidence.streamFailure),
                         detail: evidence.streamFailure?.rawValue)
        }
        probes[.codec] = {
            let evidence = await media.evidence()
            guard let codec = evidence.codec else { return .fail(.unsupportedCodec) }
            return .pass(codec.rawValue.uppercased())
        }
        probes[.firstRTP] = {
            let evidence = await media.evidence()
            return evidence.receivedRTP ? .pass("media received") : .fail(.noMediaData)
        }
        probes[.firstKeyframe] = {
            let evidence = await media.evidence()
            return evidence.receivedKeyframe ? .pass("decodable access unit") : .fail(.noKeyframe)
        }
        probes[.qualitySample] = {
            let evidence = await media.evidence()
            if let failure = evidence.qualityFailure {
                return .fail(failure, detail: evidence.qualityDetail)
            }
            return .pass(evidence.qualityDetail ?? "quality within thresholds")
        }

        window.streamDoctorTask = Task { @MainActor in
            let result = await StreamDoctor(detailedProbes: probes, progress: progress).run()
            guard !Task.isCancelled else {
                window.isStreamDoctorRunning = false
                return
            }
            window.streamDoctorOutcomes = result.outcomes
            window.streamDoctorFailures = result.failures
            window.streamDoctorDetails = result.details
            window.isStreamDoctorRunning = false
        }
    }

    func copyStreamDoctorReport() {
        let report = StreamDoctorResult(outcomes: window.streamDoctorOutcomes,
                                        failures: window.streamDoctorFailures,
                                        details: window.streamDoctorDetails).redactedText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    private static func doctorFailure(for code: StreamError.Code?) -> StreamDoctorFailure {
        switch code {
        case .accountLocked: .accountLocked
        case .rtspPathNotFound: .wrongRTSPPath
        case .unsupportedMedia, .decodeUnsupported: .unsupportedCodec
        default: .authFailed
        }
    }

    private static func activeDoctorEvidence(_ stream: CameraStream) -> DoctorMediaEvidence? {
        guard stream.isReceivingMedia, let format = stream.format else { return nil }
        let statistics = stream.statistics
        var evidence = DoctorMediaEvidence(resolvedAddress: true,
                                           connectedRTSP: true,
                                           answeredOptions: true,
                                           described: true,
                                           codec: format.videoCodec,
                                           receivedRTP: true,
                                           receivedKeyframe: true)
        if statistics.lossFraction > 0.10 {
            evidence.qualityFailure = .highLoss
            evidence.qualityDetail = String(format: "%.1f%% packet loss",
                                            statistics.lossFraction * 100)
        } else if statistics.jitterMilliseconds > 120 {
            evidence.qualityFailure = .highJitter
            evidence.qualityDetail = String(format: "%.0f ms jitter",
                                            statistics.jitterMilliseconds)
        } else if statistics.bitsPerSecond > 0, statistics.bitsPerSecond < 64_000 {
            evidence.qualityFailure = .lowBitrate
            evidence.qualityDetail = String(format: "%.0f kbit/s",
                                            statistics.bitsPerSecond / 1_000)
        }
        return evidence
    }
}

#endif
