#if os(macOS)

import Foundation
import Testing
@testable import Vigil
import VigilCore
import VigilProtocols

@Suite("Configuration import and export")
struct DataPortabilityTests {
    @Test func jsonRoundTripIncludesGroupsAndMembership() throws {
        let camera = Camera(name: "Front", host: "192.0.2.10")
        let group = CameraGroupRecord(id: GroupID(), name: "Outside", identityIndex: 2,
                                      members: [camera.id])
        let archive = VigilConfigurationArchive(exportedAt: Date(timeIntervalSince1970: 123),
                                                cameras: [camera], groups: [group])

        let decoded = try ConfigurationArchiveCodec.decode(
            ConfigurationArchiveCodec.encode(archive))

        #expect(decoded == archive)
        #expect(decoded.groups.first?.members == [camera.id])
    }

    @Test func jsonImportRejectsDanglingGroupMembers() throws {
        let camera = Camera(host: "camera.local")
        let group = CameraGroupRecord(id: GroupID(), name: "Bad", identityIndex: nil,
                                      members: [CameraID()])
        let encoded = try ConfigurationArchiveCodec.encode(
            VigilConfigurationArchive(cameras: [camera], groups: [group]))
        #expect(throws: ConfigurationArchiveCodec.Failure.self) {
            try ConfigurationArchiveCodec.decode(encoded)
        }
    }

    @Test func csvSupportsQuotedNamesAndConnectionFields() throws {
        let csv = """
        host,name,httpPort,rtspPort,channel,useTLS,enabled
        192.0.2.1,"Gate, north",443,8554,3,yes,false

        """
        let cameras = try CameraCSVImporter.decode(Data(csv.utf8))
        #expect(cameras.count == 1)
        #expect(cameras[0].name == "Gate, north")
        #expect(cameras[0].httpPort == 443)
        #expect(cameras[0].rtspPort == 8554)
        #expect(cameras[0].channel == ChannelID(3))
        #expect(cameras[0].useTLS)
        #expect(!cameras[0].isEnabled)
    }

    @Test func malformedCSVReportsItsSourceRow() {
        let csv = "host,httpPort\ncamera.local,nope\n"
        #expect(throws: CameraCSVImporter.Failure.invalidInteger(row: 2, column: "httpport")) {
            try CameraCSVImporter.decode(Data(csv.utf8))
        }
    }

    @Test func diagnosticFileScrubsStructuredAndEmbeddedSecrets() throws {
        let data = try DiagnosticBundleBuilder.build(
            createdAt: Date(timeIntervalSince1970: 0),
            application: ["version": "1"],
            statistics: ["token": "top-secret", "fps": "25"],
            logs: ["request password=hunter2 host=camera.local"],
            deviceResponses: ["isapi": "Authorization: Bearer-secret"])
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text.contains("<redacted>"))
        #expect(!text.contains("top-secret"))
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("Bearer-secret"))
        #expect(text.contains("\"fps\" : \"25\""))
    }
}

#endif
