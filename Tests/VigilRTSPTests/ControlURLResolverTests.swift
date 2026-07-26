//
//  ControlURLResolverTests.swift
//  VigilRTSPTests
//
//  Every row of the control-URL resolution table in docs/spec-rtsp.md §8.3, plus the forms that
//  table implies: a base without a trailing slash, a base with a query, `*` at both levels, and
//  the protocol-relative and absolute-path control values.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilRTSP

@Suite struct ControlURLResolverSuite {

    private func url(_ text: String) throws -> RTSPURL {
        try #require(RTSPURL(string: text))
    }

    // MARK: - The §8.3 worked examples

    @Test func controlResolverKeepsAnAbsoluteControlUnchanged() throws {
        let resolved = ControlURLResolver.resolve(
            control: "rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1",
            contentBase: "rtsp://192.168.1.64:554/Streaming/Channels/101/",
            contentLocation: nil,
            requestURI: try url("rtsp://192.168.1.64:554/Streaming/Channels/101"))
        #expect(resolved == "rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1")
    }

    @Test func controlResolverAppendsRelativeControlToContentBase() throws {
        let resolved = ControlURLResolver.resolve(
            control: "trackID=1",
            contentBase: "rtsp://192.168.1.200:554/Streaming/Channels/301/",
            contentLocation: nil,
            requestURI: try url("rtsp://192.168.1.200:554/Streaming/Channels/301"))
        #expect(resolved == "rtsp://192.168.1.200:554/Streaming/Channels/301/trackID=1")
    }

    /// The append rule, not RFC 3986's merge. RFC 3986 would drop `av_stream` and produce
    /// `rtsp://…/h264/ch1/main/trackID=1`, which every Hikvision device answers with 404.
    @Test func controlResolverAppendsToRequestURIWhenNoContentBase() throws {
        let resolved = ControlURLResolver.resolve(
            control: "trackID=1",
            contentBase: nil,
            contentLocation: nil,
            requestURI: try url("rtsp://192.168.1.64:554/h264/ch1/main/av_stream"))
        #expect(resolved == "rtsp://192.168.1.64:554/h264/ch1/main/av_stream/trackID=1")
    }

    @Test func controlResolverCarriesTheBaseQueryOntoTheTrackURI() throws {
        let requestURI = "rtsp://192.168.1.200:554/Streaming/tracks/301"
            + "?starttime=20240115T090000Z&endtime=20240115T093000Z"
        let resolved = ControlURLResolver.resolve(
            control: "trackID=1",
            contentBase: nil,
            contentLocation: nil,
            requestURI: try url(requestURI))
        #expect(resolved == "rtsp://192.168.1.200:554/Streaming/tracks/301/trackID=1"
            + "?starttime=20240115T090000Z&endtime=20240115T093000Z")
    }

    @Test func controlResolverHandlesAbsolutePathControlAgainstARootBase() throws {
        let resolved = ControlURLResolver.resolve(
            control: "/Streaming/Channels/101/trackID=1",
            contentBase: "rtsp://192.168.1.64:554/",
            contentLocation: nil,
            requestURI: try url("rtsp://192.168.1.64:554/Streaming/Channels/101"))
        #expect(resolved == "rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1")
    }

    @Test func controlResolverMapsStarToTheRequestURIVerbatim() throws {
        let requestURI = try url("rtsp://192.168.1.200:554/Streaming/Channels/301")
        let resolved = ControlURLResolver.resolve(
            control: "*",
            contentBase: "rtsp://192.168.1.200:554/Streaming/Channels/301/",
            contentLocation: nil,
            requestURI: requestURI)
        // Not the slash-normalised base: the verbatim request URI is what the device logged at
        // DESCRIBE time and what keeps the digest URI consistent between DESCRIBE and PLAY.
        #expect(resolved == "rtsp://192.168.1.200:554/Streaming/Channels/301")
    }

    @Test func controlResolverMapsMissingControlToTheRequestURI() throws {
        let resolved = ControlURLResolver.resolve(
            control: nil,
            contentBase: "rtsp://192.168.1.64:554/Streaming/Channels/101/",
            contentLocation: nil,
            requestURI: try url("rtsp://192.168.1.64:554/Streaming/Channels/101"))
        #expect(resolved == "rtsp://192.168.1.64:554/Streaming/Channels/101")
    }

    // MARK: - Base selection precedence

    @Test func controlResolverPrefersContentBaseOverContentLocation() throws {
        let resolved = ControlURLResolver.resolve(
            control: "trackID=1",
            contentBase: "rtsp://base.example:554/base/",
            contentLocation: "rtsp://location.example:554/location/",
            requestURI: try url("rtsp://request.example:554/request"))
        #expect(resolved == "rtsp://base.example:554/base/trackID=1")
    }

    @Test func controlResolverFallsBackToContentLocationWhenAbsolute() throws {
        let resolved = ControlURLResolver.resolve(
            control: "trackID=1",
            contentBase: nil,
            contentLocation: "rtsp://location.example:554/location/",
            requestURI: try url("rtsp://request.example:554/request"))
        #expect(resolved == "rtsp://location.example:554/location/trackID=1")
    }

    @Test func controlResolverResolvesRelativeContentLocationAgainstTheRequestURI() throws {
        let resolved = ControlURLResolver.resolve(
            control: "trackID=1",
            contentBase: nil,
            contentLocation: "media/",
            requestURI: try url("rtsp://192.168.1.64:554/Streaming/Channels/101"))
        #expect(resolved == "rtsp://192.168.1.64:554/Streaming/Channels/101/media/trackID=1")
    }

    @Test func controlResolverIgnoresARelativeContentBase() throws {
        // A relative Content-Base has no defined meaning; trusting it would build a URI the device
        // never issued, so the request URI wins instead.
        let resolved = ControlURLResolver.resolve(
            control: "trackID=1",
            contentBase: "not-absolute/",
            contentLocation: nil,
            requestURI: try url("rtsp://192.168.1.64:554/Streaming/Channels/101"))
        #expect(resolved == "rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1")
    }

    // MARK: - Slash and query handling

    @Test func controlResolverInsertsExactlyOneSlash() throws {
        let withSlash = ControlURLResolver.resolve(
            control: "trackID=1", contentBase: "rtsp://h:554/a/", contentLocation: nil,
            requestURI: try url("rtsp://h:554/a"))
        let withoutSlash = ControlURLResolver.resolve(
            control: "trackID=1", contentBase: "rtsp://h:554/a", contentLocation: nil,
            requestURI: try url("rtsp://h:554/a"))
        #expect(withSlash == "rtsp://h:554/a/trackID=1")
        #expect(withoutSlash == "rtsp://h:554/a/trackID=1")
    }

    @Test func controlResolverDoesNotDoubleTheQueryWhenTheControlHasOne() throws {
        let resolved = ControlURLResolver.resolve(
            control: "trackID=1?profile=Profile_1",
            contentBase: "rtsp://h:554/tracks/301?starttime=20240115T090000Z",
            contentLocation: nil,
            requestURI: try url("rtsp://h:554/tracks/301"))
        #expect(resolved == "rtsp://h:554/tracks/301/trackID=1?profile=Profile_1")
    }

    @Test func controlResolverHandlesProtocolRelativeControl() throws {
        let resolved = ControlURLResolver.resolve(
            control: "//other.example:554/Streaming/Channels/201/trackID=1",
            contentBase: "rtsp://192.168.1.64:554/Streaming/Channels/101/",
            contentLocation: nil,
            requestURI: try url("rtsp://192.168.1.64:554/Streaming/Channels/101"))
        #expect(resolved == "rtsp://other.example:554/Streaming/Channels/201/trackID=1")
    }

    @Test func controlResolverTreatsAnEmptyControlAsAbsent() throws {
        let resolved = ControlURLResolver.resolve(
            control: "", contentBase: nil, contentLocation: nil,
            requestURI: try url("rtsp://h:554/a"))
        #expect(resolved == "rtsp://h:554/a")
    }

    // MARK: - The two real session descriptions

    @Test func controlResolverResolvesTheNVRDescriptionsRelativeTracks() throws {
        let document = try SDPParser.parse(SDPWireFixture.wire(SDPWireFixture.nvrH265PCMA))
        let requestURI = try url("rtsp://192.168.1.200:554/Streaming/Channels/301")
        let base = "rtsp://192.168.1.200:554/Streaming/Channels/301/"

        let aggregate = ControlURLResolver.resolve(control: document.sessionControl,
                                                   contentBase: base, contentLocation: nil,
                                                   requestURI: requestURI)
        #expect(aggregate == "rtsp://192.168.1.200:554/Streaming/Channels/301")

        let video = ControlURLResolver.resolve(control: document.media[0].control,
                                               contentBase: base, contentLocation: nil,
                                               requestURI: requestURI)
        let audio = ControlURLResolver.resolve(control: document.media[1].control,
                                               contentBase: base, contentLocation: nil,
                                               requestURI: requestURI)
        #expect(video == "rtsp://192.168.1.200:554/Streaming/Channels/301/trackID=1")
        #expect(audio == "rtsp://192.168.1.200:554/Streaming/Channels/301/trackID=2")
    }
}
