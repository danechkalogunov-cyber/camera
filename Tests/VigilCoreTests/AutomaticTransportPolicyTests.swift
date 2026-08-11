#if os(macOS)

import Testing
@testable import VigilCore
import VigilProtocols

@Suite struct AutomaticTransportPolicyTests {
    @Test func refusalTriesTheOtherUnicastTransportExactlyOnce() {
        #expect(StreamController.nextAutomaticTransport(
            after: .transportUnsupported, active: .tcpInterleaved,
            tried: [.tcpInterleaved], didRetryTCPAfterSilentUDP: false) == .udpUnicast)
        #expect(StreamController.nextAutomaticTransport(
            after: .transportUnsupported, active: .udpUnicast,
            tried: [.udpUnicast], didRetryTCPAfterSilentUDP: false) == .tcpInterleaved)
        #expect(StreamController.nextAutomaticTransport(
            after: .transportUnsupported, active: .udpUnicast,
            tried: [.tcpInterleaved, .udpUnicast], didRetryTCPAfterSilentUDP: false) == nil)
    }

    @Test func silentUDPReturnsToTCPWithoutLooping() {
        #expect(StreamController.nextAutomaticTransport(
            after: .noMediaReceived, active: .udpUnicast,
            tried: [.udpUnicast], didRetryTCPAfterSilentUDP: false) == .tcpInterleaved)
        #expect(StreamController.nextAutomaticTransport(
            after: .noMediaReceived, active: .udpUnicast,
            tried: [.udpUnicast], didRetryTCPAfterSilentUDP: true) == nil)
    }

    @Test func unrelatedFailuresDoNotChangeTransport() {
        #expect(StreamController.nextAutomaticTransport(
            after: .authenticationFailed, active: .tcpInterleaved,
            tried: [.tcpInterleaved], didRetryTCPAfterSilentUDP: false) == nil)
    }
}

#endif
