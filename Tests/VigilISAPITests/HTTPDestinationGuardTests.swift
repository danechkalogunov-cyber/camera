import Foundation
import Testing
import VigilProtocols

@testable import VigilISAPI

@Suite struct HTTPDestinationGuardTests {

    @Test func localLiteralSkipsDNS() async throws {
        let url = try #require(URL(string: "http://192.168.1.64/ISAPI/System/status"))
        try await HTTPDestinationGuard.requirePermitted(url) { _ in
            .addresses([[8, 8, 8, 8]])
        }
    }

    @Test func publicLiteralIsBlockedBeforeDNS() async throws {
        let url = try #require(URL(string: "http://8.8.8.8/ISAPI/System/status"))
        await #expect(throws: ISAPIError.notConnected("egress policy blocked 8.8.8.8")) {
            try await HTTPDestinationGuard.requirePermitted(url) { _ in
                .addresses([[192, 168, 1, 64]])
            }
        }
    }

    @Test func internalDNSRequiresOnlyLocalAnswers() async throws {
        let url = try #require(URL(string: "http://nvr.example.internal/ISAPI/System/status"))
        try await HTTPDestinationGuard.requirePermitted(url) { host in
            #expect(host == "nvr.example.internal")
            return .addresses([
                [192, 168, 1, 64],
                [0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
            ])
        }
    }

    @Test func mixedDNSAnswersFailClosed() async throws {
        let url = try #require(URL(string: "http://nvr.example.internal/status"))
        await #expect(throws: ISAPIError.notConnected(
            "egress policy blocked nvr.example.internal")) {
            try await HTTPDestinationGuard.requirePermitted(url) { _ in
                .addresses([[192, 168, 1, 64], [8, 8, 8, 8]])
            }
        }
    }

    @Test func resolutionFailureCreatesNoFallbackPath() async throws {
        let url = try #require(URL(string: "http://missing.example.internal/status"))
        await #expect(throws: ISAPIError.notConnected(
            "could not resolve missing.example.internal")) {
            try await HTTPDestinationGuard.requirePermitted(url) { _ in .unavailable }
        }
    }

    @Test func automaticRedirectsCannotChangeTheDestinationHost() throws {
        let source = try #require(URL(string: "http://camera.local/login"))
        let secure = try #require(URL(string: "https://CAMERA.local/ISAPI/System/status"))
        let publicHost = try #require(URL(string: "https://example.com/collect"))
        #expect(HTTPRedirectPolicy.allows(from: source, to: secure))
        #expect(!HTTPRedirectPolicy.allows(from: source, to: publicHost))
        #expect(!HTTPRedirectPolicy.allows(from: nil, to: secure))
    }
}
