import Foundation
import Testing
import VigilProtocols
@testable import VigilRTSP

@Suite struct RTSPMulticastTests {
    @Test func setupRequestsAndParsesMulticastTransport() {
        var config = RTSPSessionConfig(url: Harness.cameraURL)
        config.transport = .udpMulticast
        var machine = RTSPSessionMachine(config: config, credential: nil,
                                         random: SplitMix64RandomSource(seed: 1), now: .zero)
        _ = machine.handle(.start, now: .zero)
        _ = machine.ingest(Server.options(cseq: 1), now: .zero)
        let setup = machine.ingest(Server.describe(cseq: 2), now: .zero)
        let wire = setup.compactMap { action -> Data? in
            if case let .send(data) = action { data } else { nil }
        }.reduce(into: Data()) { $0.append($1) }
        #expect(String(decoding: wire, as: UTF8.self)
            .contains("Transport: RTP/AVP;multicast"))

        let response = RTSPWireBytes.response(headers: [
            ("CSeq", "3"), ("Session", "multicast-session;timeout=60"),
            ("Transport", "RTP/AVP;multicast;destination=239.1.2.3;port=5004-5005;ttl=7"),
        ])
        let actions = machine.ingest(response, now: .zero)
        let ports = RTSPUDPPortPair(rtp: 5_004, rtcp: 5_005)!
        let endpoint = RTSPMulticastEndpoint(destination: "239.1.2.3", ports: ports,
                                             timeToLive: 7)!
        #expect(actions.contains(.joinMulticast(trackID: 0, endpoint: endpoint)))
        #expect(machine.tracks[0].multicastEndpoint == endpoint)
        #expect(machine.tracks[0].interleavedChannels == 0...1)
    }

    @Test func malformedMulticastResponseIsRejected() {
        var config = RTSPSessionConfig(url: Harness.cameraURL)
        config.transport = .udpMulticast
        var machine = RTSPSessionMachine(config: config, credential: nil,
                                         random: SplitMix64RandomSource(seed: 1), now: .zero)
        _ = machine.handle(.start, now: .zero)
        _ = machine.ingest(Server.options(cseq: 1), now: .zero)
        _ = machine.ingest(Server.describe(cseq: 2), now: .zero)
        let response = RTSPWireBytes.response(headers: [
            ("CSeq", "3"), ("Session", "multicast-session"),
            ("Transport", "RTP/AVP;multicast;port=5004-5005"),
        ])
        #expect(machine.ingest(response, now: .zero).contains(.fail(.transportRejected)))
    }

    @Test func noMulticastMediaMapsToNamedFailure() {
        var config = RTSPSessionConfig(url: Harness.cameraURL)
        config.transport = .udpMulticast
        var machine = RTSPSessionMachine(config: config, credential: nil,
                                         random: SplitMix64RandomSource(seed: 1), now: .zero)
        _ = machine.handle(.start, now: .zero)
        _ = machine.ingest(Server.options(cseq: 1), now: .zero)
        _ = machine.ingest(Server.describe(cseq: 2), now: .zero)
        let setup = RTSPWireBytes.response(headers: [
            ("CSeq", "3"), ("Session", "multicast-session"),
            ("Transport", "RTP/AVP;multicast;destination=239.1.2.3;port=5004-5005"),
        ])
        _ = machine.ingest(setup, now: .zero)
        _ = machine.ingest(Server.play(cseq: 4, session: "multicast-session"), now: .zero)
        #expect(machine.timerFired(.firstMediaTimeout, now: .zero + .seconds(5))
            .contains(.fail(.multicastBlocked)))
    }
}
