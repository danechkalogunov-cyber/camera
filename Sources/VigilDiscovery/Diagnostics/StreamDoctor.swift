//
//  StreamDoctor.swift
//  VigilDiscovery
//
//  Deterministic, credential-free diagnostic sequence and its per-step report.
//

import Foundation

public enum StreamDoctorStep: String, Sendable, CaseIterable, Codable {
    case tcpHTTP, tcpRTSP, options, describe, setup, firstRTP, firstKeyframe
}

public enum StreamDoctorOutcome: String, Sendable, Codable, Equatable {
    case passed, failed, skipped
}

public struct StreamDoctorResult: Sendable, Codable, Equatable {
    public let outcomes: [StreamDoctorStep: StreamDoctorOutcome]
    public var firstFailure: StreamDoctorStep? {
        StreamDoctorStep.allCases.first { outcomes[$0] == .failed }
    }
}

/// Stops at the first failed dependency and marks later stages skipped.
public struct StreamDoctor: Sendable {
    public typealias Probe = @Sendable () async -> Bool
    private let probes: [StreamDoctorStep: Probe]

    public init(probes: [StreamDoctorStep: Probe]) { self.probes = probes }

    public func run() async -> StreamDoctorResult {
        var outcomes: [StreamDoctorStep: StreamDoctorOutcome] = [:]
        var blocked = false
        for step in StreamDoctorStep.allCases {
            if blocked {
                outcomes[step] = .skipped
                continue
            }
            let passed = await probes[step]?() ?? false
            outcomes[step] = passed ? .passed : .failed
            blocked = !passed
        }
        return StreamDoctorResult(outcomes: outcomes)
    }
}
