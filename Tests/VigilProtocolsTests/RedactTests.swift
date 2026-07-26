//
//  RedactTests.swift
//  VigilProtocolsTests
//
//  The one redaction point. Covers docs/API_CONTRACT.md §3.10, FEATURES.md §20.6 and
//  ARCHITECTURE.md §8.6.
//
//  Every secret below is synthetic — "hunter2", "s3cr3t!", the MACs and the serials are
//  invented for these tests and none of them came from real hardware.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct RedactTests {

    /// The one string that must never survive any path, in any encoding.
    private static let password = "hunter2"

    /// Every shape a password is known to reach a log line in.
    private static let passwordCarriers = [
        "password=hunter2",
        "password=hunter2&channel=101",
        "pwd=hunter2",
        "passwd=hunter2",
        "pass=hunter2",
        "password: hunter2",
        "\"password\": \"hunter2\"",
        "{\"pwd\":\"hunter2\"}",
        "<password>hunter2</password>",
        "<password>hunter2</password><userName>admin</userName>",
        "rtsp://admin:hunter2@192.168.1.64:554/Streaming/Channels/101",
        "http://admin:hunter2@192.168.1.64/ISAPI/System/deviceInfo",
        "GET /ISAPI/x?password=hunter2 HTTP/1.1",
        "secret=hunter2",
        "token=hunter2",
    ]

    // MARK: - Passwords

    @Test func redactRemovesThePasswordFromEveryCarrier() {
        for carrier in Self.passwordCarriers {
            let redacted = Redact.secrets(in: carrier)
            #expect(!redacted.contains(Self.password),
                    "password survived redaction of \"\(carrier)\" as \"\(redacted)\"")
        }
    }

    @Test func redactRemovesThePasswordFromEveryCarrierWhenEmbeddedInALogLine() {
        for carrier in Self.passwordCarriers {
            let line = "12:00:01 rtsp connect \(carrier) attempt=2 host=192.168.1.64"
            let redacted = Redact.secrets(in: line)
            #expect(!redacted.contains(Self.password),
                    "password survived redaction of \"\(line)\" as \"\(redacted)\"")
        }
    }

    @Test func redactLeavesTheSurroundingLogLineReadable() {
        let line = "rtsp connect password=hunter2 host=192.168.1.64 channel=101"
        let redacted = Redact.secrets(in: line)
        #expect(redacted.contains("host=192.168.1.64"))
        #expect(redacted.contains("channel=101"))
        #expect(redacted.contains("password="))
    }

    @Test func redactIsIdempotentOverEveryPasswordCarrier() {
        for carrier in Self.passwordCarriers {
            let once = Redact.secrets(in: carrier)
            #expect(Redact.secrets(in: once) == once, "not idempotent for \"\(carrier)\"")
        }
    }

    @Test func redactNeverMoreThanDoublesTheLength() {
        // The 2× bound in §3.10. The tightest cases are the shortest secret-bearing tokens.
        let inputs = Self.passwordCarriers + ["<iv>a</iv>", "<salt>a</salt>", "pwd=a", "iv=a",
                                              "nonce=\"a\"", "Authorization: x"]
        for input in inputs {
            let redacted = Redact.secrets(in: input)
            #expect(redacted.count <= 2 * input.count,
                    "\"\(input)\" (\(input.count)) grew to \(redacted.count)")
        }
    }

    @Test func redactHandlesEmptyAndSecretFreeInputUnchanged() {
        #expect(Redact.secrets(in: "") == "")
        #expect(Redact.secrets(in: "rtsp DESCRIBE ok in 41 ms") == "rtsp DESCRIBE ok in 41 ms")
    }

    // MARK: - Authorization headers

    @Test func redactElidesBasicAuthorizationHeaders() {
        // "YWRtaW46aHVudGVyMg==" is base64 of "admin:hunter2" — the encoded form must go too.
        let line = "Authorization: Basic YWRtaW46aHVudGVyMg=="
        let redacted = Redact.secrets(in: line)
        #expect(!redacted.contains("YWRtaW46aHVudGVyMg=="))
        #expect(redacted.hasPrefix("Authorization:"))
    }

    @Test func redactElidesDigestAuthorizationHeaders() {
        let line = "Authorization: Digest username=\"admin\", realm=\"IP Camera\", "
            + "nonce=\"4f2a9c\", response=\"9b7d3f1a\""
        let redacted = Redact.secrets(in: line)
        #expect(!redacted.contains("9b7d3f1a"))
        #expect(!redacted.contains("4f2a9c"))
    }

    @Test func redactElidesWWWAuthenticateChallenges() {
        let line = "WWW-Authenticate: Digest realm=\"IP Camera\", nonce=\"abc123\", qop=\"auth\""
        let redacted = Redact.secrets(in: line)
        #expect(!redacted.contains("abc123"))
    }

    @Test func redactElidesBareDigestParametersOutsideAHeader() {
        let line = "computed cnonce=beefcafe opaque=deadbeef response=0011aabb"
        let redacted = Redact.secrets(in: line)
        #expect(!redacted.contains("beefcafe"))
        #expect(!redacted.contains("deadbeef"))
        #expect(!redacted.contains("0011aabb"))
    }

    @Test func redactKeepsAnRTSPStatusLineWithTheWordResponseIntact() {
        // `response` is a Digest parameter, but "response: 200 OK" is not a secret and losing it
        // would make every RTSP trace useless.
        let line = "response: 200 OK"
        #expect(Redact.secrets(in: line) == line)
    }

    // MARK: - XML elements

    @Test func redactBlanksSecretXMLElementContentsAndKeepsTheTags() {
        let xml = "<DeviceInfo><serialNumber>DS12345678</serialNumber>"
            + "<macAddress>44:19:b6:aa:bb:cc</macAddress><model>DS-2CD2143G0-I</model></DeviceInfo>"
        let redacted = Redact.secrets(in: xml)
        #expect(!redacted.contains("DS12345678"))
        #expect(!redacted.contains("44:19:b6:aa:bb:cc"))
        #expect(redacted.contains("<serialNumber><redacted/></serialNumber>"))
        #expect(redacted.contains("<macAddress><redacted/></macAddress>"))
        // A non-secret element is untouched, or the diagnostics bundle is worthless.
        #expect(redacted.contains("<model>DS-2CD2143G0-I</model>"))
    }

    @Test func redactBlanksTheActivationAndSessionElements() {
        let xml = "<challenge>abc</challenge><salt>def</salt><iv>012</iv>"
            + "<securityVersion>xyz</securityVersion><sessionID>7788</sessionID>"
        let redacted = Redact.secrets(in: xml)
        for secret in ["abc", "def", "012", "xyz", "7788"] {
            #expect(!redacted.contains(">\(secret)<"), "\(secret) survived")
        }
    }

    @Test func redactLeavesASelfClosingSecretElementAlone() {
        let xml = "<password/>"
        #expect(Redact.secrets(in: xml) == xml)
    }

    @Test func redactIsIdempotentOverXML() {
        let xml = "<password>hunter2</password><iv>0011</iv>"
        let once = Redact.secrets(in: xml)
        #expect(Redact.secrets(in: once) == once)
    }

    // MARK: - URLs

    @Test func redactStripsUserinfoFromAnRTSPURL() {
        let raw = "rtsp://admin:hunter2@192.168.1.64:554/Streaming/Channels/101"
        let redacted = Redact.url(raw)
        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains("admin"))
        #expect(!redacted.contains("@"))
        #expect(redacted == "rtsp://192.168.1.64:554/Streaming/Channels/101")
    }

    @Test func redactStripsUserinfoWhenTheURLAppearsInsideAMessage() {
        let line = "DESCRIBE rtsp://admin:hunter2@cam.local/Streaming/Channels/101 failed"
        let redacted = Redact.secrets(in: line)
        #expect(!redacted.contains("hunter2"))
        #expect(redacted.contains("rtsp://cam.local/Streaming/Channels/101"))
    }

    @Test func redactElidesSecretQueryValuesAndKeepsTheRest() {
        let raw = "http://192.168.1.64/ISAPI/Streaming/picture?password=hunter2&videoResolution=1080p"
        let redacted = Redact.url(raw)
        #expect(!redacted.contains("hunter2"))
        #expect(redacted.contains("videoResolution=1080p"))
    }

    @Test func redactLeavesACredentialFreeURLIntact() {
        let raw = "rtsp://192.168.1.64:554/Streaming/Channels/101"
        #expect(Redact.url(raw) == raw)
    }

    @Test func redactURLIsIdempotent() {
        let raw = "rtsp://admin:hunter2@192.168.1.64:554/Streaming/Channels/101?auth=abc"
        let once = Redact.url(raw)
        #expect(Redact.url(once) == once)
    }

    // MARK: - Session ids

    @Test func redactHashesASessionIDToFourHexCharacters() {
        let tag = Redact.sessionID("12345678")
        #expect(tag.hasPrefix("sess#"))
        #expect(tag.count == "sess#".count + 4)
        #expect(!tag.contains("12345678"))
        let hex = tag.dropFirst("sess#".count)
        #expect(hex.allSatisfy { $0.isHexDigit })
    }

    @Test func redactSessionIDIsStableAndDistinguishing() {
        #expect(Redact.sessionID("12345678") == Redact.sessionID("12345678"))
        #expect(Redact.sessionID("12345678") != Redact.sessionID("12345679"))
    }

    @Test func redactSessionIDHandlesAnEmptyID() {
        let tag = Redact.sessionID("")
        #expect(tag.hasPrefix("sess#"))
        #expect(tag.count == "sess#".count + 4)
    }

    // MARK: - Serials

    @Test func redactSerialKeepsOnlyTheLastFourCharacters() {
        let redacted = Redact.serial("DS2CD21434C21")
        #expect(redacted.hasSuffix("4C21"))
        #expect(!redacted.contains("DS2CD"))
        #expect(redacted.count == "DS2CD21434C21".count)
    }

    @Test func redactSerialMasksShortSerialsCompletely() {
        #expect(!Redact.serial("4C21").contains("4"))
        #expect(Redact.serial("4C21").count == 4)
        #expect(Redact.serial("").isEmpty)
    }

    @Test func redactSerialIsStableForTheSameInput() {
        #expect(Redact.serial("DS2CD21434C21") == Redact.serial("DS2CD21434C21"))
    }

    // MARK: - MAC addresses

    @Test func redactMACKeepsTheLastTwoOctetsAboveDebug() {
        for level in [LogLevel.info, .notice, .warning, .error, .fault] {
            let redacted = Redact.mac("44:19:B6:AA:1A:2B", level: level)
            #expect(redacted == "••:••:••:••:1A:2B", "wrong at \(level)")
            #expect(!redacted.contains("44"))
            #expect(!redacted.contains("B6"))
        }
    }

    @Test func redactMACKeepsEverythingAtDebug() {
        #expect(Redact.mac("44:19:B6:AA:1A:2B", level: .debug) == "44:19:B6:AA:1A:2B")
    }

    @Test func redactMACAcceptsEverySeparatorForm() {
        let expected = "••:••:••:••:1A:2B"
        #expect(Redact.mac("44-19-b6-aa-1a-2b", level: .info) == expected)
        #expect(Redact.mac("4419.b6aa.1a2b", level: .info) == expected)
        #expect(Redact.mac("4419b6aa1a2b", level: .info) == expected)
    }

    @Test func redactMACMasksAnythingThatIsNotTwelveHexDigits() {
        let redacted = Redact.mac("not-a-mac", level: .info)
        #expect(!redacted.contains("a"))
        #expect(redacted.count == "not-a-mac".count)
    }

    // MARK: - Paths and hosts

    @Test func redactPathReplacesTheHomeDirectoryWithATilde() {
        #expect(Redact.path("/Users/jane/Library/Application Support/Vigil/library.json")
            == "~/Library/Application Support/Vigil/library.json")
        #expect(Redact.path("/home/jane/vigil/library.json") == "~/vigil/library.json")
    }

    @Test func redactPathLeavesASystemPathAlone() {
        #expect(Redact.path("/Library/Preferences/x.plist") == "/Library/Preferences/x.plist")
    }

    @Test func redactPathHandlesAPathEmbeddedInAMessage() {
        let redacted = Redact.path("could not write /Users/jane/Movies/clip.mov")
        #expect(redacted == "could not write ~/Movies/clip.mov")
        #expect(!redacted.contains("jane"))
    }

    @Test func redactHostProducesAStableSaltedPseudonym() {
        let a = Redact.host("192.168.1.64", salt: 0xDEAD_BEEF)
        #expect(a.hasPrefix("cam-"))
        #expect(a.count == "cam-".count + 4)
        #expect(!a.contains("192"))
        #expect(a == Redact.host("192.168.1.64", salt: 0xDEAD_BEEF))
        #expect(a != Redact.host("192.168.1.65", salt: 0xDEAD_BEEF))
        // A different bundle salt gives a different pseudonym, so the mapping is not precomputable.
        #expect(a != Redact.host("192.168.1.64", salt: 0x0BAD_F00D))
    }

    // MARK: - Events

    @Test func redactEventCleansTheMessageAndEveryMetadataValue() {
        let event = LogEvent(level: .error, category: .rtsp,
                             message: "auth failed for rtsp://admin:hunter2@192.168.1.64/",
                             metadata: ["header": "Authorization: Basic YWRtaW46aHVudGVyMg==",
                                        "body": "<password>hunter2</password>",
                                        "attempt": "2"])
        let redacted = Redact.event(event)
        #expect(!redacted.message.contains("hunter2"))
        for (key, value) in redacted.metadata {
            #expect(!value.contains("hunter2"), "secret survived in metadata key \(key)")
            #expect(!value.contains("YWRtaW46aHVudGVyMg=="))
        }
        // Keys are ours, not the device's, and stay searchable.
        #expect(redacted.metadata["attempt"] == "2")
        #expect(redacted.level == .error)
        #expect(redacted.category == .rtsp)
    }
}
