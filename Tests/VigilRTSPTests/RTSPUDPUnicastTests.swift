import Foundation
import Testing
import VigilProtocols
@testable import VigilRTSP

@Suite struct RTSPUDPUnicastTests {
    @Test func setupReservesPairAndAdvertisesClientPorts() {
        var config = RTSPSessionConfig(url: Harness.cameraURL)
        config.transport = .udpUnicast
        config.udpClientPortBase = 50_000
        var machine = RTSPSessionMachine(config: config, credential: nil,
                                         random: SplitMix64RandomSource(seed: 1), now: .zero)
        _ = machine.handle(.start, now: .zero)
        _ = machine.ingest(Server.options(cseq: 1), now: .zero)
        let actions = machine.ingest(Server.describe(cseq: 2), now: .zero)

        #expect(actions.contains(.prepareUDP(trackID: 0,
                                             ports: RTSPUDPPortPair(rtp: 50_000, rtcp: 50_001)!)))
        let wire = actions.compactMap { action -> Data? in
            if case let .send(data) = action { data } else { nil }
        }.reduce(into: Data()) { $0.append($1) }
        #expect(String(decoding: wire, as: UTF8.self)
            .contains("Transport: RTP/AVP;unicast;client_port=50000-50001"))
    }

    @Test func datagramsAndReceiverReportsUseTheReservedPair() {
        var config = RTSPSessionConfig(url: Harness.cameraURL)
        config.transport = .udpUnicast
        var machine = RTSPSessionMachine(config: config, credential: nil,
                                         random: SplitMix64RandomSource(seed: 1), now: .zero)
        _ = machine.handle(.start, now: .zero)
        _ = machine.ingest(Server.options(cseq: 1), now: .zero)
        _ = machine.ingest(Server.describe(cseq: 2), now: .zero)
        let udpSetup = RTSPWireBytes.response(headers: [
            ("CSeq", "3"), ("Session", "udp-session;timeout=60"),
            ("Transport", "RTP/AVP;unicast;client_port=50000-50001;server_port=6970-6971"),
        ])
        _ = machine.ingest(udpSetup, now: .zero)
        _ = machine.ingest(Server.play(cseq: 4, session: "udp-session"), now: .zero)

        #expect(machine.tracks[0].serverPorts == RTSPUDPPortPair(rtp: 6_970, rtcp: 6_971))
        #expect(machine.ingestUDP(Data([1, 2, 3]), localPort: 50_000, now: .zero)
            .contains(.emitMedia(channel: 0, payload: Data([1, 2, 3]))))
        #expect(machine.handle(.sendRTCP(channel: 1, payload: Data([0x81])), now: .zero)
            == [.sendUDP(localPort: 50_001, payload: Data([0x81]))])
    }
}
