//
//  DiscoveryCredentialGuardTests.swift
//  VigilDiscoveryTests
//
//  Proof that nothing the discovery encoders emit carries a credential — and, just as important, proof
//  that the guard which checks that actually trips when one is introduced.
//  Covers docs/spec-discovery.md §6.10, §13.1, §13.2 and §15.
//

import Foundation
import Testing
import VigilProtocols

@testable import VigilDiscovery

@Suite struct DiscoveryCredentialGuardTests {

    // MARK: - The guard can fail

    /// A guard that cannot fail is worse than no guard, because it reads as proof. Each of these is a
    /// credential a well-meaning change might add "just to check whether the password works".
    @Test func credentialGuardFlagsAnAuthorizationHeader() {
        let request = Data("""
            GET /ISAPI/System/deviceInfo HTTP/1.1\r
            Host: 192.168.1.64\r
            Authorization: Basic YWRtaW46MTIzNDU=\r
            \r

            """.utf8)
        let violations = DiscoveryCredentialGuard.violations(in: request)
        #expect(!violations.isEmpty)
        #expect(violations.contains { $0.token == "authorization" })
    }

    /// Lower case, upper case and the proxy variant all trip it.
    @Test func credentialGuardIsCaseInsensitiveAndCatchesProxyAuth() {
        #expect(!DiscoveryCredentialGuard.violations(in: Data("authorization: x".utf8)).isEmpty)
        #expect(!DiscoveryCredentialGuard.violations(in: Data("AUTHORIZATION: x".utf8)).isEmpty)
        #expect(!DiscoveryCredentialGuard.violations(in: Data("Proxy-Authorization: x".utf8)).isEmpty)
    }

    /// The ONVIF path's temptation: a WS-Security header on the Probe. §5.7 forbids every SOAP call
    /// beyond the Probe precisely because they need this.
    @Test func credentialGuardFlagsAWSSecurityUsernameToken() {
        let envelope = WSDiscoveryCodec.encodeProbe(messageID: UUID(),
                                                    types: .networkVideoTransmitter)
        guard var text = String(data: envelope, encoding: .utf8) else {
            Issue.record("the probe envelope must be UTF-8")
            return
        }
        text = text.replacingOccurrences(of: "  <e:Header>", with: """
              <e:Header>
                <wsse:Security>
                  <wsse:UsernameToken><wsse:Username>admin</wsse:Username>
                  <wsse:Password Type="PasswordDigest">Zm9v</wsse:Password></wsse:UsernameToken>
                </wsse:Security>
            """)
        let violations = DiscoveryCredentialGuard.violations(in: Data(text.utf8))
        #expect(violations.contains { $0.token == "usernametoken" })
        #expect(violations.contains { $0.token == "wsse" })
        #expect(violations.contains { $0.token == "password" })
    }

    /// A credential smuggled into a URL rather than a header.
    @Test func credentialGuardFlagsUserInfoInAURL() {
        let violations = DiscoveryCredentialGuard.violations(
            in: Data("DESCRIBE rtsp://admin:12345@192.168.1.64:554/Streaming/Channels/101".utf8))
        #expect(violations.contains { $0.token == "userinfo@host" })
    }

    /// A URL without credentials must **not** trip it: a guard that cries wolf gets disabled.
    @Test func credentialGuardIgnoresPlainURLs() {
        let clean = "XAddrs: http://192.168.1.64/onvif/device_service rtsp://10.0.20.11:554/x"
        #expect(DiscoveryCredentialGuard.violations(in: Data(clean.utf8)).isEmpty)
    }

    /// Binary payloads are searched too, so nothing evades the scan by not being valid UTF-8.
    @Test func credentialGuardScansNonUTF8Payloads() {
        var bytes: [UInt8] = [0xFF, 0xFE, 0xB0]
        bytes.append(contentsOf: Array("Authorization: Digest".utf8))
        bytes.append(0x80)
        #expect(!DiscoveryCredentialGuard.violations(in: Data(bytes)).isEmpty)
    }

    /// The recorded offset is usable: it points at the token in the original bytes.
    @Test func credentialGuardReportsUsableOffsets() throws {
        let text = "GET / HTTP/1.1\r\nAuthorization: Basic x\r\n\r\n"
        let violation = try #require(DiscoveryCredentialGuard.violations(in: Data(text.utf8)).first)
        #expect(violation.offset == 16)
        #expect(violation.description.contains("byte 16"))
    }

    // MARK: - Nothing we send trips it

    /// The SADP probe, across many UUIDs, carries nothing that could authenticate.
    @Test func credentialGuardPassesEverySADPProbe() {
        for _ in 0..<32 {
            let probe = SADPCodec.encodeProbe(uuid: UUID())
            DiscoveryCredentialGuard.requireNoCredentials(in: probe, label: "SADP probe")
            #expect(DiscoveryCredentialGuard.violations(in: probe).isEmpty)
        }
    }

    /// All three ONVIF probe variants, across many MessageIDs.
    @Test func credentialGuardPassesEveryWSDiscoveryProbe() {
        for variant in WSDiscoveryCodec.probeSchedule {
            for _ in 0..<8 {
                let probe = WSDiscoveryCodec.encodeProbe(messageID: UUID(), types: variant)
                DiscoveryCredentialGuard.requireNoCredentials(in: probe,
                                                              label: "WS-Discovery probe \(variant)")
                #expect(DiscoveryCredentialGuard.violations(in: probe).isEmpty)
            }
        }
    }

    /// Every payload the module can put on the wire, in one place: the two multicast probes and the
    /// three fingerprint requests. Nothing in any of these codecs' public surfaces accepts a
    /// credential, a user name or a realm, so there is no parameter through which one could be
    /// threaded — the absence of the parameter and this byte check are the two halves of §6.10.
    @Test func credentialGuardCoversEveryOutboundPayloadThisModuleProduces() {
        let host = IPv4Address(192, 168, 1, 64)
        let outbound: [(String, Data)] = [
            ("SADP inquiry", SADPCodec.encodeProbe(uuid: UUID())),
            ("ONVIF probe 1", WSDiscoveryCodec.encodeProbe(messageID: UUID(),
                                                           types: .networkVideoTransmitter)),
            ("ONVIF probe 2", WSDiscoveryCodec.encodeProbe(messageID: UUID(),
                                                           types: .networkVideoTransmitterAndDevice)),
            ("ONVIF probe 3", WSDiscoveryCodec.encodeProbe(messageID: UUID(), types: .wildcard)),
            ("RTSP OPTIONS", FingerprintCodec.rtspOptionsRequest(host: host, port: 554)),
            ("ISAPI deviceInfo", FingerprintCodec.isapiDeviceInfoRequest(host: host)),
            ("HTTP root", FingerprintCodec.rootRequest(host: host)),
        ]
        for (label, payload) in outbound {
            DiscoveryCredentialGuard.requireNoCredentials(in: payload, label: label)
            #expect(DiscoveryCredentialGuard.violations(in: payload).isEmpty, "\(label)")
        }
        #expect(outbound.count == 7)
    }

    /// Decoding must not echo credentials either: a device that sends us an `Authorization` header in
    /// a ProbeMatch field must not have it end up in anything we then transmit. The decoders produce
    /// values, never requests, so the property holds by construction — asserted so that a future
    /// "re-probe with what the device told us" change has to confront it.
    @Test func credentialGuardHoldsWhenADeviceSendsUsCredentials() {
        let hostile = SADPFixtures.activatedCameraXML.replacingOccurrences(
            of: "<DeviceDescription>IPCamera</DeviceDescription>",
            with: "<DeviceDescription>Authorization: Basic YWRtaW46MTIzNDU=</DeviceDescription>")
        let result = SADPCodec.decode(Data(hostile.utf8), from: .hikvisionFactoryDefault,
                                      expectedUUID: SADPFixtures.probeUUID,
                                      receivedAt: SADPFixtures.receivedAt)
        #expect(result.sadpSolicitedMatch?.deviceDescription
                    == "Authorization: Basic YWRtaW46MTIzNDU=")
        // Whatever a device says, our next outbound datagram is still just the inquiry probe.
        DiscoveryCredentialGuard.requireNoCredentials(
            in: SADPCodec.encodeProbe(uuid: SADPFixtures.probeUUID), label: "SADP probe after hostile input")
    }
}
