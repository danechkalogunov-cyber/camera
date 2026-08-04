//
//  RecordSearchTests.swift
//  VigilISAPITests
//
//  `POST /ISAPI/ContentMgmt/search`: the request body's mandatory element order and its real
//  misspelling, paging across two pages under one `searchID`, the `playbackURI` rewrite, the track
//  list, and the day index's merge and minute bins.
//  Covers docs/spec-isapi.md §15.1–§15.5.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - PlaybackLocatorSuite

@Suite struct PlaybackLocatorSuite {

    private let uri = "rtsp://192.168.1.64/Streaming/tracks/101"
        + "?starttime=20240501T080000Z&endtime=20240501T081459Z"
        + "&name=ch01_00000000019000000&size=536870912"

    @Test func playbackLocatorParsesTheDocumentedURI() throws {
        let locator = try #require(PlaybackLocator(playbackURI: uri))
        #expect(locator.path == "/Streaming/tracks/101")
        #expect(locator.fileName == "ch01_00000000019000000")
        #expect(locator.sizeBytes == 536_870_912)
        #expect(abs(locator.start.timeIntervalSince1970 - 1_714_550_400) < 0.001)
        #expect(abs(locator.end.timeIntervalSince1970 - 1_714_551_299) < 0.001)
    }

    @Test func playbackLocatorKeepsTheQueryVerbatim() throws {
        let locator = try #require(PlaybackLocator(playbackURI: uri))
        // Byte-identical: `name` is a device-internal file name and re-encoding it, or reordering
        // the items, breaks playback on the firmwares that matter.
        #expect(locator.rawQuery == "starttime=20240501T080000Z&endtime=20240501T081459Z"
                + "&name=ch01_00000000019000000&size=536870912")
    }

    @Test func playbackLocatorRewritesOnlyTheAddress() throws {
        let locator = try #require(PlaybackLocator(playbackURI: uri))
        // The device filled in the address it thinks it has; on a multi-homed NVR or behind NAT
        // that is not the address Vigil reached it on.
        #expect(locator.requestURI(host: "10.0.0.5", port: 8554)
                == "rtsp://10.0.0.5:8554/Streaming/tracks/101"
                + "?starttime=20240501T080000Z&endtime=20240501T081459Z"
                + "&name=ch01_00000000019000000&size=536870912")
        #expect(locator.requestURI(host: "10.0.0.5", port: 322, useTLS: true).hasPrefix("rtsps://"))
        // No credentials, ever.
        #expect(!locator.requestURI(host: "h", port: 554).contains("@"))
    }

    @Test func playbackLocatorBracketsAnIPv6HostExactlyOnce() throws {
        let locator = try #require(PlaybackLocator(playbackURI: uri))
        #expect(locator.requestURI(host: "fe80::1", port: 554)
                    .hasPrefix("rtsp://[fe80::1]:554/"))
        #expect(locator.requestURI(host: "[fe80::1]", port: 554)
                    .hasPrefix("rtsp://[fe80::1]:554/"))
    }

    @Test func playbackLocatorTrimsATrailingSlash() throws {
        let locator = try #require(PlaybackLocator(
            playbackURI: "rtsp://h/Streaming/tracks/101/?starttime=20240501T080000Z"))
        #expect(locator.path == "/Streaming/tracks/101")
    }

    @Test func playbackLocatorToleratesAMissingNameAndSize() throws {
        let locator = try #require(PlaybackLocator(
            playbackURI: "rtsp://h/Streaming/tracks/101"
                + "?starttime=20240501T080000Z&endtime=20240501T081459Z"))
        #expect(locator.fileName == nil)
        #expect(locator.sizeBytes == nil)
    }

    @Test func playbackLocatorFallsBackToTheSearchResultTimes() throws {
        let start = Date(timeIntervalSince1970: 1_714_550_400)
        let end = Date(timeIntervalSince1970: 1_714_551_299)
        let locator = try #require(PlaybackLocator(playbackURI: "rtsp://h/Streaming/tracks/101",
                                                   fallbackStart: start, fallbackEnd: end))
        #expect(locator.start == start)
        #expect(locator.end == end)
        #expect(locator.rawQuery.isEmpty)
    }

    @Test func playbackLocatorRejectsAURIWithNoUsableAddress() {
        #expect(PlaybackLocator(playbackURI: "") == nil)
        #expect(PlaybackLocator(playbackURI: "rtsp://192.168.1.64") == nil)
        // No time at all, from any source.
        #expect(PlaybackLocator(playbackURI: "rtsp://h/Streaming/tracks/101") == nil)
    }

    @Test func playbackLocatorSynthesisesADirectSeek() {
        let start = Date(timeIntervalSince1970: 1_714_551_000)
        let open = PlaybackLocator(track: TrackID(101), start: start, end: nil)
        // No `endtime` means "play to the end of available footage".
        #expect(open.rawQuery == "starttime=20240501T081000Z")
        #expect(open.path == "/Streaming/tracks/101")
        let bounded = PlaybackLocator(track: TrackID(101), start: start,
                                      end: start.addingTimeInterval(60))
        #expect(bounded.rawQuery == "starttime=20240501T081000Z&endtime=20240501T081100Z")
    }

    @Test func playbackLocatorFormatsTheClockRange() throws {
        let locator = try #require(PlaybackLocator(playbackURI: uri))
        #expect(locator.clockRange == "clock=20240501T080000Z-20240501T081459Z")
    }

    @Test func playbackLocatorShiftsForDeviceLocalFirmware() throws {
        // `playbackTimesAreDeviceLocal`: the times move, `name` and `size` keep their positions.
        let locator = try #require(PlaybackLocator(playbackURI: uri))
        let shifted = locator.shiftedForDeviceLocalTimes(utcOffsetSeconds: 28_800)
        #expect(shifted.rawQuery == "starttime=20240501T160000Z&endtime=20240501T161459Z"
                + "&name=ch01_00000000019000000&size=536870912")
        #expect(shifted.start == locator.start)     // the absolute instant is unchanged
        #expect(locator.shiftedForDeviceLocalTimes(utcOffsetSeconds: 0) == locator)
    }
}
