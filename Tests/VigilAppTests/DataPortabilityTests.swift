#if os(macOS)

import Foundation
import Testing
@testable import Vigil
import VigilCore
import VigilProtocols

@Suite("Configuration import and export")
struct DataPortabilityTests {
    /// ⚠️ WHOLE-SECOND DATES IN THE FIXTURE, AND NOT FOR CONVENIENCE.
    ///
    /// This was the one test of 2797 that failed on the first real run of the suite, and it failed
    /// on `Camera.createdAt`, whose default is `Date()`. The archive writes ISO-8601 to the second,
    /// exactly as `library.json` does (`VigilCore.LibraryCoding`), so a fractional part cannot
    /// survive the trip — with a `Date()` in the fixture the assertion was measuring
    /// `ISO8601DateFormatter`'s resolution rather than this codec's fidelity, and it would fail
    /// roughly 999 times in 1000 regardless of the code under test.
    ///
    /// Whole seconds are also what the domain actually holds: every camera that has been through a
    /// single `library.json` save has a second-resolution `createdAt`, because that file truncates
    /// too — deliberately, so that re-encoding unchanged state produces identical bytes and the
    /// store's "skip the write" check can fire. The resolution the format carries is asserted
    /// directly by ``jsonRoundTripCarriesDatesToTheSecond()`` below, so it is a stated property
    /// rather than a silent one.
    @Test func jsonRoundTripIncludesGroupsAndMembership() throws {
        let camera = Camera(name: "Front", host: "192.0.2.10",
                            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let group = CameraGroupRecord(id: GroupID(), name: "Outside", identityIndex: 2,
                                      members: [camera.id])
        let archive = VigilConfigurationArchive(exportedAt: Date(timeIntervalSince1970: 123),
                                                cameras: [camera], groups: [group])

        let decoded = try ConfigurationArchiveCodec.decode(
            ConfigurationArchiveCodec.encode(archive))

        #expect(decoded == archive)
        #expect(decoded.groups.first?.members == [camera.id])
    }

    /// What the format promises about time, said out loud: seconds, not fractions of one.
    ///
    /// An export is a text file a user may read, diff or paste into an email, and second resolution
    /// is what the rest of Vigil writes. A camera exported before its first save therefore comes
    /// back with `createdAt` moved by under a second, which is the same rounding its next save
    /// would have applied anyway.
    @Test func jsonRoundTripCarriesDatesToTheSecond() throws {
        let instant = Date(timeIntervalSince1970: 1_700_000_000.75)
        let camera = Camera(host: "192.0.2.11", createdAt: instant)
        let archive = VigilConfigurationArchive(exportedAt: instant, cameras: [camera], groups: [])

        let decoded = try ConfigurationArchiveCodec.decode(
            ConfigurationArchiveCodec.encode(archive))

        let restored = try #require(decoded.cameras.first)
        #expect(restored.id == camera.id)
        #expect(abs(restored.createdAt.timeIntervalSince(instant)) < 1)
        #expect(restored.createdAt.timeIntervalSince1970
            == restored.createdAt.timeIntervalSince1970.rounded(.down))
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
