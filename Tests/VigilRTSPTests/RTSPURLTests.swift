//
//  RTSPURLTests.swift
//  VigilRTSPTests
//
//  The URL value type, with the credential invariant as the centrepiece: the string that goes on
//  the wire and the string that goes in a log both drop the userinfo, and they differ from the
//  operator's URL in exactly that place.
//  Covers docs/spec-rtsp.md §10.1 and the HikvisionURLTests credential rows of §18.2.
//

import Testing

@testable import VigilRTSP

@Suite struct RTSPURLTests {

    // MARK: - Credentials

    /// The round trip that matters: parse a URL that carries a password, and prove both rendered
    /// forms differ from the input *only* by the userinfo, while the credential is still available
    /// to the authenticator.
    @Test func rtspURLStripsCredentialsFromEveryRenderedForm() throws {
        let typed = "rtsp://admin:Hik12345@192.168.1.64:554/Streaming/Channels/101"
        let url = try #require(RTSPURL(string: typed))

        #expect(url.username == "admin")
        #expect(url.password == "Hik12345")

        let wire = url.requestLineForm
        let printed = url.description
        #expect(wire == "rtsp://192.168.1.64:554/Streaming/Channels/101")
        #expect(printed == wire)

        // Differ from the operator's URL exactly where the credentials were.
        let withoutScheme = String(wire.dropFirst("rtsp://".count))
        #expect(typed == "rtsp://admin:Hik12345@" + withoutScheme)
        for rendered in [wire, printed, "\(url)"] {
            #expect(!rendered.contains("Hik12345"))
            #expect(!rendered.contains("admin"))
            #expect(!rendered.contains("@"))
        }
    }

    @Test func rtspURLPercentDecodesUserinfoOnly() throws {
        let url = try #require(RTSPURL(string: "rtsp://ad%40min:p%40ss%2Fword@h/Streaming%2Fx"))
        #expect(url.username == "ad@min")
        #expect(url.password == "p@ss/word")
        // The path keeps its encoding verbatim: %2F is not a path separator on the wire.
        #expect(url.path == "/Streaming%2Fx")
    }

    @Test func rtspURLDescriptionRedactsSecretQueryValues() throws {
        let url = try #require(RTSPURL(string: "rtsp://h/Streaming/tracks/101?password=hunter2"))
        #expect(url.requestLineForm.contains("hunter2"))
        #expect(!url.description.contains("hunter2"))
    }

    // MARK: - Ports

    @Test func rtspURLKeepsAnExplicitPortAndOmitsAnAbsentOne() throws {
        let explicit = try #require(RTSPURL(string: "rtsp://192.168.1.64:554/x"))
        #expect(explicit.port == 554)
        #expect(explicit.requestLineForm == "rtsp://192.168.1.64:554/x")

        let implicit = try #require(RTSPURL(string: "rtsp://192.168.1.64/x"))
        #expect(implicit.port == 554)
        #expect(implicit.requestLineForm == "rtsp://192.168.1.64/x")
        #expect(implicit.absoluteFormWithPort == "rtsp://192.168.1.64:554/x")
    }

    @Test func rtspURLDefaultsRTSPSToPort322() throws {
        let url = try #require(RTSPURL(string: "rtsps://cam.local/Streaming/Channels/101"))
        #expect(url.scheme == "rtsps")
        #expect(url.port == 322)
        #expect(url.requestLineForm == "rtsps://cam.local/Streaming/Channels/101")
    }

    @Test func rtspURLFallbackFormsDropQueryAndDefaultPort() throws {
        let url = try #require(RTSPURL(string: "rtsp://h:554/Streaming/tracks/101?starttime=1"))
        #expect(url.formWithoutQuery == "rtsp://h:554/Streaming/tracks/101")
        #expect(url.formWithoutDefaultPort == "rtsp://h/Streaming/tracks/101?starttime=1")
    }

    // MARK: - Paths and queries

    @Test func rtspURLPreservesTrackIDPathSegmentsVerbatim() throws {
        let url = try #require(RTSPURL(string: "rtsp://h/Streaming/Channels/101/trackID=1"))
        #expect(url.path == "/Streaming/Channels/101/trackID=1")
        #expect(url.requestLineForm == "rtsp://h/Streaming/Channels/101/trackID=1")
    }

    @Test func rtspURLPreservesQueriesContainingSemicolonsAndEquals() throws {
        let url = try #require(RTSPURL(string: "rtsp://h/a?b=1;c=2"))
        #expect(url.query == "b=1;c=2")
        #expect(url.requestLineForm == "rtsp://h/a?b=1;c=2")
    }

    @Test func rtspURLPreservesPlaybackQuery() throws {
        let text = "rtsp://192.168.1.200:554/Streaming/tracks/301"
            + "?starttime=20240115T090000Z&endtime=20240115T093000Z"
        let url = try #require(RTSPURL(string: text))
        #expect(url.requestLineForm == text)
    }

    @Test func rtspURLSuppliesRootPathWhenNoneIsWritten() throws {
        let url = try #require(RTSPURL(string: "rtsp://h"))
        #expect(url.path == "/")
        #expect(url.requestLineForm == "rtsp://h/")
    }

    @Test func rtspURLAssumesRTSPWhenTheSchemeIsMissing() throws {
        let url = try #require(RTSPURL(string: "192.168.1.64/Streaming/Channels/101"))
        #expect(url.scheme == "rtsp")
        #expect(url.host == "192.168.1.64")
        #expect(url.path == "/Streaming/Channels/101")
    }

    // MARK: - IPv6

    @Test func rtspURLStripsAndRestoresIPv6Brackets() throws {
        let url = try #require(RTSPURL(string: "rtsp://[fe80::1%25en0]:554/Streaming/Channels/101"))
        #expect(url.isIPv6Literal)
        #expect(url.host == "fe80::1%25en0")
        #expect(url.port == 554)
        #expect(url.requestLineForm == "rtsp://[fe80::1%25en0]:554/Streaming/Channels/101")
    }

    // MARK: - Rejection

    @Test func rtspURLRejectsInputItCannotRepresent() {
        #expect(RTSPURL(string: "") == nil)
        #expect(RTSPURL(string: "   ") == nil)
        #expect(RTSPURL(string: "http://h/x") == nil)
        #expect(RTSPURL(string: "rtsp://") == nil)
        #expect(RTSPURL(string: "rtsp://h:99999/x") == nil)
        #expect(RTSPURL(string: "rtsp://h:abc/x") == nil)
        #expect(RTSPURL(string: "rtsp://[fe80::1/x") == nil)
    }

    // MARK: - Derivation

    @Test func rtspURLAppendingControlInsertsExactlyOneSlash() throws {
        let base = try #require(RTSPURL(string: "rtsp://h/Streaming/Channels/101"))
        #expect(base.appendingControl("trackID=1").requestLineForm
            == "rtsp://h/Streaming/Channels/101/trackID=1")

        let trailing = try #require(RTSPURL(string: "rtsp://h/Streaming/Channels/101/"))
        #expect(trailing.appendingControl("/trackID=1").requestLineForm
            == "rtsp://h/Streaming/Channels/101/trackID=1")
    }

    @Test func rtspURLAppendingControlCarriesTheBaseQuery() throws {
        let base = try #require(RTSPURL(string: "rtsp://h/Streaming/tracks/101?starttime=1"))
        #expect(base.appendingControl("trackID=1").requestLineForm
            == "rtsp://h/Streaming/tracks/101/trackID=1?starttime=1")
    }

    @Test func rtspURLAppendingControlIgnoresEmptyAndWildcardControls() throws {
        let base = try #require(RTSPURL(string: "rtsp://h/a"))
        #expect(base.appendingControl("") == base)
        #expect(base.appendingControl("*") == base)
    }

    @Test func rtspURLEquivalenceIgnoresCaseTrailingSlashAndQuery() {
        #expect(RTSPURL.equivalent("rtsp://H/a/trackID=1", "rtsp://h/a/trackID=1/"))
        #expect(RTSPURL.equivalent("rtsp://h:554/a", "rtsp://h/a?starttime=1"))
        #expect(!RTSPURL.equivalent("rtsp://h/a/trackID=1", "rtsp://h/a/trackID=2"))
        #expect(RTSPURL.equivalent("trackID=1", "trackID=1"))
        #expect(!RTSPURL.equivalent("trackID=1", "trackID=2"))
    }
}
