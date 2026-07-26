//
//  ZZDebugClock.swift
//  VigilDiscoveryTests
//
//  Temporary diagnostic for the virtual clock's scheduler.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilDiscovery

@Suite(.serialized) struct ZZDebugClockSuite {
    @Test func zzDebugClockAdvanceTrace() async {
        var script = DiscoveryTestBed.Script()
        script.sadpAnswers = [ScriptedDatagram(delay: .milliseconds(40),
                                               text: SADPFixtures.activatedCameraXML,
                                               source: IPv4Address(192, 168, 1, 64),
                                               sourcePort: SADPCodec.port)]
        script.ports = [IPv4Address(192, 168, 1, 12).rawValue: CoordinatorFixtures.hikvisionPorts]
        let bed = DiscoveryTestBed(script)
        var configuration = DiscoveryConfiguration()
        configuration.mode = .subnets([IPv4Subnet(network: IPv4Address(192, 168, 1, 8),
                                                  prefixLength: 29)])
        let result = await bed.run(configuration)
        let advances = bed.clock.advanceLog.joined(separator: " ")
        let sadp = bed.sadpChannels.first?.sent.map(\.at.nanoseconds) ?? []
        Issue.record("reason=\(String(describing: result.terminationReason)) sadp=\(sadp) adv=\(advances)")
    }
}
