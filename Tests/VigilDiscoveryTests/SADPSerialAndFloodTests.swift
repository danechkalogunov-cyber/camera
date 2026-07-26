//
//  SADPSerialAndFloodTests.swift
//  VigilDiscoveryTests
//
//  The serial-to-model split table, the zoneless `BootTime` rule, and the per-run ingest limiter that
//  keeps a datagram storm from becoming unbounded allocation.
//  Covers docs/spec-discovery.md §4.5.3, §4.5.4, §4.5.5, §14.3 and §13.2 tests 16, 17, 18.
//

import Foundation
import Testing
import VigilProtocols

@testable import VigilDiscovery

@Suite struct SADPSerialSplitTests {

    /// Test 16, driven by the §14.3 table verbatim. The awkward rows are the point: a model that
    /// ends in digits (`…/16P16`), a serial with two date-shaped runs, and the invalid dates that
    /// must not be mistaken for one.
    @Test(arguments: [
        ("DS-2CD2143G0-I20200114AAWRD12345678", "DS-2CD2143G0-I"),
        ("DS-2CD2347G2-LU20260401AAWRJ98765432", "DS-2CD2347G2-LU"),
        ("DS-7616NI-K2/16P1620201105AAWR123456789WCVU", "DS-7616NI-K2/16P16"),
        ("DS-2DE4A425IW-DE20211230AAWR555000111", "DS-2DE4A425IW-DE"),
        ("iDS-2CD7A46G0/P-IZHSY20220630AAWR777", "iDS-2CD7A46G0/P-IZHSY"),
        ("HWI-B140H20230101CCWR123456", "HWI-B140H"),
        ("DS-2CD2043G2-I", nil),
        ("", nil),
        ("1234", nil),
        ("DS-XX20990101AAWR1", nil),
        ("DS-A20201232AAWR1", nil),
        ("DS-B2020010120200102AAWR1", "DS-B20200101"),
    ] as [(String, String?)])
    func sadpSerialSplitMatchesTheSpecTable(serial: String, expectedModel: String?) {
        let split = SADPCodec.splitSerial(serial)
        #expect(split.model == expectedModel, "serial \(serial)")
        if let expectedModel {
            #expect(split.remainder == String(serial.dropFirst(expectedModel.count)))
            #expect(expectedModel + split.remainder == serial)
        } else {
            #expect(split.remainder == serial)      // nothing to split: the serial is the whole thing
        }
    }

    /// A serial that *is* only a date has no model — an empty model would be worse than none.
    @Test func sadpSerialThatIsOnlyADateHasNoModel() {
        let split = SADPCodec.splitSerial("20200114AAWRD12345678")
        #expect(split.model == nil)
        #expect(split.remainder == "20200114AAWRD12345678")
    }

    /// The year window is a range, not a prefix test: 2005 and 2035 are in, 2004 and 2036 are out.
    @Test func sadpSerialYearBoundsAreExact() {
        #expect(SADPCodec.splitSerial("DS-X20050101AA").model == "DS-X")
        #expect(SADPCodec.splitSerial("DS-X20350101AA").model == "DS-X")
        #expect(SADPCodec.splitSerial("DS-X20040101AA").model == nil)
        #expect(SADPCodec.splitSerial("DS-X20360101AA").model == nil)
        #expect(SADPCodec.splitSerial("DS-X20200001AA").model == nil)      // month 00
        #expect(SADPCodec.splitSerial("DS-X20201300AA").model == nil)      // month 13, day 00
    }

    /// Non-ASCII in a serial must not split a scalar in half.
    @Test func sadpSerialSplitIsScalarSafe() {
        let split = SADPCodec.splitSerial("КАМЕРА20200114AAWR1")
        #expect(split.model == "КАМЕРА")
        #expect(split.remainder == "20200114AAWR1")
    }
}

@Suite struct SADPBootTimeTests {

    /// Test 17. `BootTime` is the device's own wall clock with no zone attached, so the raw string is
    /// preserved and any `Date` is derived only from a zone the caller supplies. Reading
    /// `TimeZone.current` in here would make the value depend on the machine running the code.
    @Test func sadpBootTimeIsNotTreatedAsUTC() throws {
        let match = try #require(SADPCodec.decode(SADPFixtures.activatedCameraDatagram,
                                                  from: IPv4Address(192, 168, 1, 64),
                                                  expectedUUID: nil,
                                                  receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        #expect(match.bootTimeLocalString == "2026-07-19 06:14:02")

        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let plusOne = try #require(TimeZone(secondsFromGMT: 3_600))
        let asUTC = try #require(match.bootTime(in: utc))
        let asPlusOne = try #require(match.bootTime(in: plusOne))

        #expect(asUTC.timeIntervalSince1970 == 1_784_441_642)
        #expect(asUTC.timeIntervalSince(asPlusOne) == 3_600)
    }

    /// Everything that is not `yyyy-MM-dd HH:mm:ss` with in-range components is `nil`, not a guess.
    @Test func sadpBootTimeRejectsMalformedStrings() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let bad = ["", "2026-07-19", "2026/07/19 06:14:02", "not-a-date-at-all",
                   "2026-13-19 06:14:02", "2026-07-19 25:14:02", "2026-07-19 06:99:02",
                   "2026-07-1x 06:14:02"]
        for text in bad {
            let xml = SADPFixtures.activatedCameraXML.replacingOccurrences(
                of: "<BootTime>2026-07-19 06:14:02</BootTime>", with: "<BootTime>\(text)</BootTime>")
            let match = try #require(SADPCodec.decode(Data(xml.utf8),
                                                      from: IPv4Address(192, 168, 1, 64),
                                                      expectedUUID: nil,
                                                      receivedAt: SADPFixtures.receivedAt)
                .sadpSolicitedMatch)
            #expect(match.bootTime(in: utc) == nil, "boot time '\(text)'")
        }
    }

    /// A trailing suffix after the seconds is tolerated — some firmware appends a weekday.
    @Test func sadpBootTimeToleratesATrailingSuffix() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let xml = SADPFixtures.activatedCameraXML.replacingOccurrences(
            of: "<BootTime>2026-07-19 06:14:02</BootTime>",
            with: "<BootTime>2026-07-19 06:14:02 Sun</BootTime>")
        let match = try #require(SADPCodec.decode(Data(xml.utf8), from: IPv4Address(192, 168, 1, 64),
                                                  expectedUUID: nil,
                                                  receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        #expect(match.bootTime(in: utc)?.timeIntervalSince1970 == 1_784_441_642)
    }

    /// The observation carries `bootTime` only when a zone was supplied: the pure layer will not
    /// invent one on the caller's behalf.
    @Test func sadpBootTimeReachesTheObservationOnlyWithAZone() throws {
        let match = try #require(SADPCodec.decode(SADPFixtures.activatedCameraDatagram,
                                                  from: IPv4Address(192, 168, 1, 64),
                                                  expectedUUID: nil,
                                                  receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        #expect(SADPCodec.observation(from: match, source: .sadpMulticast).fields[.bootTime] == nil)
        let withZone = SADPCodec.observation(from: match, source: .sadpMulticast, bootTimeZone: utc)
        #expect(withZone.fields[.bootTime] == .date(Date(timeIntervalSince1970: 1_784_441_642)))
    }
}

@Suite struct SADPIngestLimiterTests {

    /// Test 18. One source flooding the group is capped at the per-source share, and the drops are
    /// counted so the caller emits one diagnostic per offender rather than one per datagram.
    @Test func sadpFloodFromOneSourceIsCappedPerSource() {
        var limiter = SADPIngestLimiter()
        let source = IPv4Address(10, 0, 20, 99)
        var admitted = 0
        for _ in 0..<600 where limiter.admit(from: source) { admitted += 1 }
        #expect(admitted == SADPCodec.maxDatagramsPerSource)
        #expect(admitted == 32)
        #expect(limiter.droppedCount(from: source) == 568)
        #expect(limiter.floodedSources.count == 1)
        #expect(limiter.floodedSources.first?.dropped == 568)
    }

    /// The run-wide cap holds even when the traffic is spread thinly across many sources, which is
    /// what a discovery-tool storm on a large LAN actually looks like.
    @Test func sadpFloodAcrossManySourcesIsCappedPerRun() {
        var limiter = SADPIngestLimiter()
        var admitted = 0
        for host in 1...100 {
            let source = IPv4Address(10, 0, 20, UInt8(host))
            for _ in 0..<20 where limiter.admit(from: source) { admitted += 1 }
        }
        #expect(admitted == SADPCodec.maxDatagramsPerRun)
        #expect(admitted == 512)
        #expect(limiter.admittedCount == 512)
        #expect(!limiter.floodedSources.isEmpty)
    }

    /// Well-behaved traffic is never touched, and the flood list stays empty.
    @Test func sadpLimiterAdmitsNormalTraffic() {
        var limiter = SADPIngestLimiter()
        for host in 1...20 {
            let source = IPv4Address(192, 168, 1, UInt8(host))
            for _ in 0..<3 {
                let admitted = limiter.admit(from: source)
                #expect(admitted)
            }
        }
        #expect(limiter.admittedCount == 60)
        #expect(limiter.floodedSources.isEmpty)
    }

    /// The flood list is sorted by address so a diagnostic sequence is deterministic run to run.
    @Test func sadpFloodedSourcesAreSortedByAddress() {
        var limiter = SADPIngestLimiter(runLimit: 4, perSourceLimit: 1)
        for host: UInt8 in [9, 3, 7] {
            let source = IPv4Address(10, 0, 0, host)
            _ = limiter.admit(from: source)
            _ = limiter.admit(from: source)
        }
        #expect(limiter.floodedSources.map { $0.source.description }
                    == ["10.0.0.3", "10.0.0.7", "10.0.0.9"])
    }
}
