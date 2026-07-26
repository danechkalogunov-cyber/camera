//
//  HikvisionURLTests.swift
//  VigilISAPITests
//
//  The single path builder: the compact live path, the R1.2 probe ladder in the customer's order,
//  the playback forms, and the endpoint's URL construction rules.
//  Covers docs/spec-isapi.md §12.4, docs/REQUIREMENTS-CUSTOMER.md R1.2 and API_CONTRACT §2 R-23.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - Paths

@Suite struct HikvisionURLTests {

    /// §12.4's table, row by row. The arithmetic form is the only one Vigil generates, because
    /// `{ch}0{stream}` is the same number for `ch ≤ 9` and wrong for `ch ≥ 10`.
    @Test func hikvisionURLLivePathFollowsTheSpecTable() {
        #expect(HikvisionURL.livePath(StreamingChannelID(channel: 1, quality: .main))
                == "/Streaming/Channels/101")
        #expect(HikvisionURL.livePath(StreamingChannelID(channel: 1, quality: .sub))
                == "/Streaming/Channels/102")
        #expect(HikvisionURL.livePath(StreamingChannelID(channel: 1, quality: .third))
                == "/Streaming/Channels/103")
        #expect(HikvisionURL.livePath(StreamingChannelID(channel: 7, quality: .sub))
                == "/Streaming/Channels/702")
        #expect(HikvisionURL.livePath(StreamingChannelID(channel: 12, quality: .main))
                == "/Streaming/Channels/1201")
        #expect(HikvisionURL.livePath(StreamingChannelID(channel: 32, quality: .sub))
                == "/Streaming/Channels/3202")
    }

    /// `Streaming/Channels` is capitalised: the lowercase spelling works on 5.5+ and 404s on 5.2.x.
    @Test func hikvisionURLLivePathIsCapitalised() {
        let path = HikvisionURL.livePath(StreamingChannelID(channel: 1, quality: .main))
        #expect(path.contains("/Streaming/Channels/"))
        #expect(path.contains("/streaming/") == false)
    }

    /// The snapshot resource uses the **lower-case** ISAPI spelling, which is a different tree from
    /// the RTSP one and both spellings matter.
    @Test func hikvisionURLSnapshotPathUsesTheISAPISpelling() {
        #expect(HikvisionURL.snapshotPath(StreamingChannelID(channel: 1, quality: .sub))
                == "/Streaming/channels/102/picture")
        #expect(HikvisionURL.streamingChannelPath(StreamingChannelID(channel: 3, quality: .main))
                == "/Streaming/channels/301")
    }

    /// The playback path, with and without a window. Times go out in the compact UTC form because
    /// that is the only one every firmware's playback parser accepts.
    @Test func hikvisionURLPlaybackPathCarriesCompactTimes() {
        #expect(HikvisionURL.playbackPath(TrackID(101)) == "/Streaming/tracks/101")
        let start = Date(timeIntervalSince1970: 1_714_538_096)      // 2024-05-01T04:34:56Z
        let end = Date(timeIntervalSince1970: 1_714_541_696)        // one hour later
        #expect(HikvisionURL.playbackPath(TrackID(101), from: start, to: end)
                == "/Streaming/tracks/101?starttime=20240501T043456Z&endtime=20240501T053456Z")
        #expect(HikvisionURL.playbackPath(TrackID(101), from: start, to: nil)
                == "/Streaming/tracks/101?starttime=20240501T043456Z")
    }

    /// The ladder is R1.2's order, exactly, and ends with the ONVIF marker rather than a path.
    @Test func hikvisionURLLadderIsInRequirementOrder() {
        let ladder = HikvisionURL.candidates(channel: 1, quality: .main)
        #expect(ladder.map(\.family) == [.channelsCompact, .channelsBare, .tracks,
                                        .legacyH264, .legacyMPEG4, .onvifGetStreamURI])
        #expect(ladder.map(\.path) == ["/Streaming/Channels/101", "/Streaming/Channels/1",
                                      "/Streaming/tracks/101", "/h264/ch1/main/av_stream",
                                      "/mpeg4/ch1/sub/av_stream", ""])
        #expect(ladder.map(\.order) == [0, 1, 2, 3, 4, 5])
        #expect(ladder.last?.isProtocolFallback == true)
        #expect(ladder.dropLast().allSatisfy { $0.isProtocolFallback == false })
    }

    /// The sub-stream ladder renders the sub forms, and the MPEG-4 rung ignores quality because the
    /// firmware that shipped it only ever exposed the sub-stream on that path.
    @Test func hikvisionURLLadderRendersSubStreamForms() {
        let ladder = HikvisionURL.candidates(channel: 4, quality: .sub)
        #expect(ladder.map(\.path) == ["/Streaming/Channels/402", "/Streaming/Channels/4",
                                      "/Streaming/tracks/401", "/h264/ch4/sub/av_stream",
                                      "/mpeg4/ch4/sub/av_stream", ""])
    }

    /// A known-good family is hoisted to the front, so a re-probe confirms the learned answer in
    /// one round trip instead of six — the ladder runs at most once per device, ever.
    @Test func hikvisionURLLadderHoistsAKnownFamily() {
        let ladder = HikvisionURL.candidates(channel: 2, quality: .main, preferring: .legacyH264)
        #expect(ladder.first?.family == .legacyH264)
        #expect(ladder.first?.path == "/h264/ch2/main/av_stream")
        #expect(ladder.first?.order == 0)
        #expect(ladder.count == 6)
        #expect(Set(ladder.map(\.family)).count == 6)
    }

    /// Duplicate renderings never take a probe slot twice.
    @Test func hikvisionURLLadderPathsAreDistinct() {
        for channel in 1...16 {
            for quality in StreamQuality.allCases {
                let ladder = HikvisionURL.candidates(channel: ChannelID(channel), quality: quality)
                let paths = ladder.map(\.path).filter { !$0.isEmpty }
                #expect(Set(paths).count == paths.count,
                        "channel \(channel) \(quality) produced a duplicate path")
            }
        }
    }

    /// A candidate survives a `Codable` round trip, because the winner is persisted on the camera
    /// record.
    @Test func hikvisionURLCandidateRoundTripsThroughCodable() throws {
        let candidate = RTSPPathCandidate(family: .channelsCompact,
                                          path: "/Streaming/Channels/101", order: 0)
        let data = try JSONEncoder().encode(candidate)
        let decoded = try JSONDecoder().decode(RTSPPathCandidate.self, from: data)
        #expect(decoded == candidate)
    }

    /// The identifier types do not interchange. `livePath` takes a `StreamingChannelID` and
    /// `playbackPath` a `TrackID`; neither accepts a bare `Int`, and there is no conversion between
    /// them — `HikvisionURL.playbackPath(StreamingChannelID(channel: 1, quality: .main))` and
    /// `HikvisionURL.livePath(101)` are both compile errors, which is the point of the three types
    /// (docs/API_CONTRACT.md §2 R-13). This test asserts the runtime half: the same number in the
    /// two spaces produces two different paths.
    @Test func hikvisionURLKeepsTheThreeIdentifierSpacesApart() {
        let streaming = StreamingChannelID(channel: 1, quality: .main)
        let track = TrackID(101)
        #expect(streaming.value == track.value)
        #expect(HikvisionURL.livePath(streaming) == "/Streaming/Channels/101")
        #expect(HikvisionURL.playbackPath(track) == "/Streaming/tracks/101")
        #expect(HikvisionURL.livePath(streaming) != HikvisionURL.playbackPath(track))
        #expect(streaming.channel == ChannelID(1))
    }
}

// MARK: - Endpoint

@Suite struct ISAPIEndpointTests {

    /// The prefix is joined once, the resource is written without it, and the default port is
    /// omitted from the URL.
    @Test func isapiEndpointBuildsThePrefixedPath() throws {
        let endpoint = ISAPIEndpoint(host: "192.168.1.64")
        #expect(endpoint.path("/System/deviceInfo") == "/ISAPI/System/deviceInfo")
        #expect(endpoint.path("System/deviceInfo") == "/ISAPI/System/deviceInfo")
        let url = try endpoint.url("/System/deviceInfo")
        #expect(url.absoluteString == "http://192.168.1.64/ISAPI/System/deviceInfo")
    }

    /// A non-default port and TLS both appear; a reverse-proxy prefix is honoured verbatim.
    @Test func isapiEndpointHonoursPortSchemeAndPrefix() throws {
        let proxied = ISAPIEndpoint(host: "cam.local", port: 8443, useTLS: true,
                                   pathPrefix: "/cam1/ISAPI/")
        #expect(proxied.authority == "cam.local:8443")
        let url = try proxied.url("/System/deviceInfo")
        #expect(url.absoluteString == "https://cam.local:8443/cam1/ISAPI/System/deviceInfo")
        let plain443 = ISAPIEndpoint(host: "cam.local", port: 443, useTLS: true)
        #expect(plain443.authority == "cam.local")
    }

    /// An IPv6 literal is bracketed exactly once, and `host` stays unbracketed.
    @Test func isapiEndpointBracketsIPv6Once() throws {
        let endpoint = ISAPIEndpoint(host: "fe80::1", port: 8080)
        #expect(endpoint.host == "fe80::1")
        #expect(endpoint.authority == "[fe80::1]:8080")
        let url = try endpoint.url("/System/status")
        #expect(url.absoluteString == "http://[fe80::1]:8080/ISAPI/System/status")
    }

    /// The request-line URI is path plus query — the value Digest signs.
    @Test func isapiEndpointRequestURIIncludesTheQuery() {
        let endpoint = ISAPIEndpoint(host: "192.168.1.64")
        let uri = endpoint.requestURI("/Streaming/channels/101/picture",
                                      query: [URLQueryItem(name: "videoResolutionWidth",
                                                           value: "640")])
        #expect(uri == "/ISAPI/Streaming/channels/101/picture?videoResolutionWidth=640")
        #expect(endpoint.requestURI("/System/status") == "/ISAPI/System/status")
    }

    /// `+` goes out as `%2B`: Hikvision does not decode `+` as a space, and a `+` in a search
    /// timestamp that arrives as a space is a silently wrong day.
    @Test func isapiEndpointEncodesPlusAsPercentTwoB() throws {
        let endpoint = ISAPIEndpoint(host: "192.168.1.64")
        let uri = endpoint.requestURI("/ContentMgmt/search",
                                      query: [URLQueryItem(name: "time",
                                                           value: "2024-05-01T12:00:00+08:00")])
        #expect(uri.contains("%2B08%3A00"))
        #expect(uri.contains("+") == false)
        let url = try endpoint.url("/ContentMgmt/search",
                                   query: [URLQueryItem(name: "a", value: "x&y=z")])
        #expect(url.absoluteString.hasSuffix("?a=x%26y%3Dz"))
    }

    /// A valueless flag emits the bare name, and an empty host is refused rather than producing a
    /// URL that would go somewhere unintended.
    @Test func isapiEndpointHandlesValuelessItemsAndRejectsAnEmptyHost() {
        let endpoint = ISAPIEndpoint(host: "192.168.1.64")
        #expect(endpoint.requestURI("/x", query: [URLQueryItem(name: "flag", value: nil)])
                == "/ISAPI/x?flag")
        #expect(throws: ISAPIError.self) { try ISAPIEndpoint(host: "").url("/x") }
    }

    /// The endpoint is `Codable`, because it is part of the persisted camera record.
    @Test func isapiEndpointRoundTripsThroughCodable() throws {
        let endpoint = ISAPIEndpoint(host: "fe80::1", port: 8443, useTLS: true,
                                     pathPrefix: "/cam1/ISAPI")
        let decoded = try JSONDecoder().decode(
            ISAPIEndpoint.self, from: try JSONEncoder().encode(endpoint))
        #expect(decoded == endpoint)
    }
}
