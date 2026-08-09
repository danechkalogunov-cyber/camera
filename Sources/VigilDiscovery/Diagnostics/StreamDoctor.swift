//
//  StreamDoctor.swift
//  VigilDiscovery
//
//  Deterministic eleven-stage diagnostic sequence and its redacted report model.
//

import Foundation

/// The ordered probes from FEATURES.md F-HLT-06. Raw values are stable report identifiers.
public enum StreamDoctorStep: String, Sendable, CaseIterable, Codable {
    case addressResolution
    case tcpRTSP
    case tcpHTTP
    case options
    case isapiDeviceInfo
    case describeAnonymous
    case describeAuthenticated
    case codec
    case firstRTP
    case firstKeyframe
    case qualitySample

    public var title: String {
        switch self {
        case .addressResolution: "DNS / address resolution"
        case .tcpRTSP: "RTSP TCP port"
        case .tcpHTTP: "HTTP TCP port"
        case .options: "RTSP OPTIONS"
        case .isapiDeviceInfo: "ISAPI device identity"
        case .describeAnonymous: "Anonymous DESCRIBE challenge"
        case .describeAuthenticated: "Authenticated DESCRIBE"
        case .codec: "SDP codec"
        case .firstRTP: "First RTP packet"
        case .firstKeyframe: "First keyframe"
        case .qualitySample: "Five-second quality sample"
        }
    }
}

/// Stable, secret-free causes suitable for diagnostics archives and support copy/paste.
public enum StreamDoctorFailure: String, Sendable, Codable, Equatable {
    case hostNotFound
    case rtspPortClosed
    case httpPortClosed
    case notAnRTSPServer
    case notHikvision
    case notActivated
    case describeChallengeMissing
    case authFailed
    case accountLocked
    case wrongRTSPPath
    case unsupportedCodec
    case noMediaData
    case udpBlocked
    case multicastBlocked
    case noKeyframe
    case highLoss
    case highJitter
    case lowBitrate
    case cancelled

    public var message: String {
        switch self {
        case .hostNotFound: "Vigil cannot find this address on the local network."
        case .rtspPortClosed: "The RTSP port is closed or unreachable."
        case .httpPortClosed: "The HTTP port is closed, so Vigil cannot read camera settings."
        case .notAnRTSPServer: "The RTSP port answered, but the response is not RTSP."
        case .notHikvision: "The HTTP service did not identify itself as a Hikvision device."
        case .notActivated: "The camera has not been activated yet."
        case .describeChallengeMissing: "The camera did not answer DESCRIBE as expected."
        case .authFailed: "The camera rejected the saved credentials."
        case .accountLocked: "The camera has locked this account after failed sign-ins."
        case .wrongRTSPPath: "The camera rejected every known stream path."
        case .unsupportedCodec: "The stream uses a codec this Mac cannot decode."
        case .noMediaData: "PLAY succeeded, but no video packets arrived."
        case .udpBlocked: "UDP video is being blocked on the network."
        case .multicastBlocked: "Multicast video is not reaching this Mac."
        case .noKeyframe: "Video arrived without a complete keyframe."
        case .highLoss: "Too many video packets are being lost."
        case .highJitter: "Video packet timing is unstable."
        case .lowBitrate: "The camera is sending much less video data than expected."
        case .cancelled: "The diagnostic was cancelled."
        }
    }

    public var fix: String? {
        switch self {
        case .hostNotFound: "Check the address or scan the local subnet."
        case .rtspPortClosed: "Check port 554, then try 8554 or 10554 in camera settings."
        case .httpPortClosed: "Check port 80 or 443; video may still work without ISAPI."
        case .notAnRTSPServer: nil
        case .notHikvision: "Add the device through ONVIF when available."
        case .notActivated: "Open the camera web page and set its administrator password."
        case .describeChallengeMissing: "Check the RTSP service and firmware settings."
        case .authFailed: "Update the saved username and password."
        case .accountLocked: "Wait about 30 minutes; do not keep retrying the same password."
        case .wrongRTSPPath: "Set a custom RTSP path or try the alternate channel profile."
        case .unsupportedCodec: "Set the camera stream to H.264 or H.265."
        case .noMediaData: "Request a keyframe or switch to interleaved TCP."
        case .udpBlocked: "Switch the camera stream to interleaved TCP."
        case .multicastBlocked: "Switch to unicast TCP or check switch multicast filtering."
        case .noKeyframe: "Lower the camera I-frame interval and request a keyframe."
        case .highLoss: "Use TCP or the lower-bandwidth sub stream."
        case .highJitter: "Select the Quality latency preset."
        case .lowBitrate: "Check the configured camera bitrate and encoder profile."
        case .cancelled: nil
        }
    }

    public static func defaultCause(for step: StreamDoctorStep) -> StreamDoctorFailure {
        switch step {
        case .addressResolution: .hostNotFound
        case .tcpRTSP: .rtspPortClosed
        case .tcpHTTP: .httpPortClosed
        case .options: .notAnRTSPServer
        case .isapiDeviceInfo: .notHikvision
        case .describeAnonymous: .describeChallengeMissing
        case .describeAuthenticated: .authFailed
        case .codec: .unsupportedCodec
        case .firstRTP: .noMediaData
        case .firstKeyframe: .noKeyframe
        case .qualitySample: .lowBitrate
        }
    }
}

public enum StreamDoctorOutcome: String, Sendable, Codable, Equatable {
    case passed, failed, skipped, cancelled
}

/// One probe's richer answer. `detail` must already be redacted by its producer.
public struct StreamDoctorProbeResult: Sendable, Codable, Equatable {
    public let passed: Bool
    public let failure: StreamDoctorFailure?
    public let detail: String?

    public init(passed: Bool, failure: StreamDoctorFailure? = nil, detail: String? = nil) {
        self.passed = passed
        self.failure = failure
        self.detail = detail
    }

    public static func pass(_ detail: String? = nil) -> StreamDoctorProbeResult {
        StreamDoctorProbeResult(passed: true, detail: detail)
    }

    public static func fail(_ cause: StreamDoctorFailure,
                            detail: String? = nil) -> StreamDoctorProbeResult {
        StreamDoctorProbeResult(passed: false, failure: cause, detail: detail)
    }
}

public struct StreamDoctorResult: Sendable, Codable, Equatable {
    public let outcomes: [StreamDoctorStep: StreamDoctorOutcome]
    public let failures: [StreamDoctorStep: StreamDoctorFailure]
    public let details: [StreamDoctorStep: String]

    public init(outcomes: [StreamDoctorStep: StreamDoctorOutcome],
                failures: [StreamDoctorStep: StreamDoctorFailure] = [:],
                details: [StreamDoctorStep: String] = [:]) {
        self.outcomes = outcomes
        self.failures = failures
        self.details = details
    }

    public var firstFailure: StreamDoctorStep? {
        StreamDoctorStep.allCases.first { outcomes[$0] == .failed }
    }

    /// Plain-text, stable-order report. Hosts, paths and credentials are intentionally absent.
    public var redactedText: String {
        StreamDoctorStep.allCases.map { step in
            let outcome = outcomes[step] ?? .skipped
            var line = "[\(outcome.rawValue.uppercased())] \(step.title)"
            if let failure = failures[step] {
                line += " — \(failure.rawValue): \(failure.message)"
                if let fix = failure.fix { line += " Fix: \(fix)" }
            }
            if let detail = details[step], !detail.isEmpty { line += " (\(detail))" }
            return line
        }.joined(separator: "\n")
    }
}

/// Stops at the first failed dependency, marks later stages skipped, and publishes every transition.
public struct StreamDoctor: Sendable {
    public typealias Probe = @Sendable () async -> Bool
    public typealias DetailedProbe = @Sendable () async -> StreamDoctorProbeResult
    public typealias Progress = @Sendable (StreamDoctorStep, StreamDoctorOutcome) -> Void

    private let probes: [StreamDoctorStep: DetailedProbe]
    private let progress: Progress?

    /// Compatibility surface for simple and parameterized fixture tests.
    public init(probes: [StreamDoctorStep: Probe], progress: Progress? = nil) {
        self.probes = probes.mapValues { probe in
            { @Sendable in StreamDoctorProbeResult(passed: await probe()) }
        }
        self.progress = progress
    }

    public init(detailedProbes: [StreamDoctorStep: DetailedProbe], progress: Progress? = nil) {
        self.probes = detailedProbes
        self.progress = progress
    }

    public func run() async -> StreamDoctorResult {
        var outcomes: [StreamDoctorStep: StreamDoctorOutcome] = [:]
        var failures: [StreamDoctorStep: StreamDoctorFailure] = [:]
        var details: [StreamDoctorStep: String] = [:]
        var blocked = false
        for step in StreamDoctorStep.allCases {
            if blocked {
                outcomes[step] = .skipped
                progress?(step, .skipped)
                continue
            }
            guard !Task.isCancelled else {
                outcomes[step] = .cancelled
                failures[step] = .cancelled
                progress?(step, .cancelled)
                blocked = true
                continue
            }
            let result = await probes[step]?() ?? .fail(.defaultCause(for: step))
            if let detail = result.detail { details[step] = detail }
            if result.passed {
                outcomes[step] = .passed
                progress?(step, .passed)
            } else {
                outcomes[step] = .failed
                failures[step] = result.failure ?? .defaultCause(for: step)
                progress?(step, .failed)
                blocked = true
            }
        }
        return StreamDoctorResult(outcomes: outcomes, failures: failures, details: details)
    }
}
