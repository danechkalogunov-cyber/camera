//
//  DeviceIdentifierTests.swift
//  VigilProtocolsTests
//
//  ChannelID / StreamingChannelID / TrackID: the three Hikvision addressing spaces and
//  the conversions between them. Covers docs/API_CONTRACT.md §3.14 (ruling R-13).
//
//  The composite form `channel * 100 + stream` is documented in docs/spec-isapi.md §7;
//  the values here are taken from that mapping, not from a device.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct DeviceIdentifierTests {

    // MARK: - Composition

    @Test func streamingChannelIDComposesTheCameraCase() {
        // A camera has exactly one video input, so main is 101 and sub is 102.
        #expect(StreamingChannelID(channel: 1, quality: .main).value == 101)
        #expect(StreamingChannelID(channel: 1, quality: .sub).value == 102)
        #expect(StreamingChannelID(channel: 1, quality: .third).value == 103)
    }

    @Test func streamingChannelIDComposesTheNVRCase() {
        // The case this type exists for: channel 3, stream 2 → 302, never 32 and never 3.
        let id = StreamingChannelID(channel: ChannelID(3), quality: .sub)
        #expect(id.value == 302)
        #expect(id.description == "302")
    }

    @Test func streamingChannelIDComposesAHighChannelNumber() {
        #expect(StreamingChannelID(channel: 64, quality: .main).value == 6401)
        #expect(StreamingChannelID(channel: 16, quality: .third).value == 1603)
    }

    // MARK: - Decomposition

    @Test func streamingChannelIDDecomposesTheNVRCase() throws {
        let id = try #require(StreamingChannelID(rawValue: 302))
        #expect(id.channel == ChannelID(3))
        #expect(id.quality == .sub)
    }

    @Test func streamingChannelIDRoundTripsEveryPlausibleChannelAndQuality() {
        for channel in 1...64 {
            for quality in StreamQuality.allCases {
                let id = StreamingChannelID(channel: ChannelID(channel), quality: quality)
                let parsed = StreamingChannelID(rawValue: id.value)
                #expect(parsed == id)
                #expect(parsed?.channel.value == channel)
                #expect(parsed?.quality == quality)
            }
        }
    }

    // MARK: - Rejection

    @Test func streamingChannelIDRejectsValuesBelowTheFirstChannel() {
        #expect(StreamingChannelID(rawValue: 100) == nil)   // channel 1, stream 0
        #expect(StreamingChannelID(rawValue: 99) == nil)
        #expect(StreamingChannelID(rawValue: 1) == nil)     // single-digit firmware, not this type
        #expect(StreamingChannelID(rawValue: 0) == nil)
        #expect(StreamingChannelID(rawValue: -302) == nil)
    }

    @Test func streamingChannelIDRejectsQualityDigitsOutsideOneToThree() {
        #expect(StreamingChannelID(rawValue: 104) == nil)
        #expect(StreamingChannelID(rawValue: 304) == nil)
        #expect(StreamingChannelID(rawValue: 199) == nil)
        #expect(StreamingChannelID(rawValue: 300) == nil)
    }

    @Test func streamingChannelIDAcceptsTheBoundaryValues() {
        #expect(StreamingChannelID(rawValue: 101) != nil)
        #expect(StreamingChannelID(rawValue: 103) != nil)
        #expect(StreamingChannelID(rawValue: 6403) != nil)
    }

    @Test func channelIDReportsImplausibleValues() {
        // 101 is a streaming channel that has been assigned to the wrong type — the exact mix-up
        // this triple of types exists to make visible.
        #expect(ChannelID(101).isPlausible == false)
        #expect(ChannelID(0).isPlausible == false)
        #expect(ChannelID(-1).isPlausible == false)
        #expect(ChannelID(1).isPlausible)
        #expect(ChannelID(64).isPlausible)
        #expect(ChannelID(65).isPlausible == false)
    }

    // MARK: - Non-interchangeability

    @Test func trackIDAndStreamingChannelIDAreDistinctTypesOverTheSameNumbers() {
        let streaming = StreamingChannelID(channel: 1, quality: .main)
        let track = TrackID(streaming.value)
        // Same number, different concept: the conversion had to be spelled out, which is the point.
        #expect(track.value == streaming.value)
        #expect(track.description == streaming.description)
        // And there is no implicit path back: TrackID exposes no channel or quality.
        #expect(TrackID(101) == TrackID(101))
        #expect(TrackID(101) < TrackID(201))
    }

    @Test func channelIDIsTheOnlyIdentifierExpressibleByAnIntegerLiteral() {
        // A literal is allowed for the 1-based input channel, which is what a human types.
        let channel: ChannelID = 3
        #expect(channel.value == 3)
        #expect(channel == ChannelID(3))
        // `let id: StreamingChannelID = 302` and `let t: TrackID = 101` do not compile; the
        // corresponding named forms do.
        #expect(StreamingChannelID(channel: channel, quality: .sub).value == 302)
        #expect(TrackID(101).value == 101)
    }

    @Test func channelIDOrdersNumerically() {
        #expect(ChannelID(1) < ChannelID(2))
        #expect(ChannelID(9) < ChannelID(10))
        #expect(!(ChannelID(3) < ChannelID(3)))
    }

    // MARK: - Coding

    @Test func deviceIdentifiersCodeAsBareIntegers() throws {
        let encoder = JSONEncoder()
        #expect(String(decoding: try encoder.encode(ChannelID(3)), as: UTF8.self) == "3")
        let streaming = StreamingChannelID(channel: 3, quality: .sub)
        #expect(String(decoding: try encoder.encode(streaming), as: UTF8.self) == "302")
        #expect(String(decoding: try encoder.encode(TrackID(101)), as: UTF8.self) == "101")
    }

    @Test func streamingChannelIDDecodeRejectsAMalformedPersistedValue() throws {
        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(StreamingChannelID.self, from: Data("99".utf8))
        }
        let good = try decoder.decode(StreamingChannelID.self, from: Data("302".utf8))
        #expect(good.channel == ChannelID(3))
        #expect(good.quality == .sub)
    }

    @Test func deviceIdentifiersRoundTripThroughJSON() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let channel = ChannelID(7)
        #expect(try decoder.decode(ChannelID.self, from: encoder.encode(channel)) == channel)
        let track = TrackID(701)
        #expect(try decoder.decode(TrackID.self, from: encoder.encode(track)) == track)
    }
}

// MARK: - Stream quality and key

@Suite struct StreamQualityTests {

    @Test func streamQualityRawValuesAreTheHikvisionStreamDigits() {
        #expect(StreamQuality.main.rawValue == 1)
        #expect(StreamQuality.sub.rawValue == 2)
        #expect(StreamQuality.third.rawValue == 3)
        #expect(StreamQuality.allCases.count == 3)
    }

    @Test func streamQualityCodesAsALowercaseString() throws {
        let encoded = try JSONEncoder().encode(StreamQuality.sub)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"sub\"")
        let decoded = try JSONDecoder().decode(StreamQuality.self, from: Data("\"third\"".utf8))
        #expect(decoded == .third)
    }

    @Test func streamQualityDecodeIsCaseInsensitiveButRejectsNonsense() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(StreamQuality.self, from: Data("\"Main\"".utf8)) == .main)
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(StreamQuality.self, from: Data("\"highest\"".utf8))
        }
        // The integer form is not accepted: the wire form is the string.
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(StreamQuality.self, from: Data("1".utf8))
        }
    }

    @Test func streamQualityOrdersByStreamNumber() {
        #expect(StreamQuality.main < StreamQuality.sub)
        #expect(StreamQuality.sub < StreamQuality.third)
    }

    @Test func streamKeyDescribesItselfWithTheShortCameraID() {
        let camera = CameraID()
        let key = StreamKey(camera: camera, quality: .sub)
        #expect(key.description == "\(camera.short)/sub")
        #expect(camera.short.count == 8)
        #expect(!key.description.contains(camera.description))
    }

    @Test func streamKeyDistinguishesQualitiesOfTheSameCamera() {
        // Both are live during the 150 ms crossfade of a quality switch, so they must not collide.
        let camera = CameraID()
        let main = StreamKey(camera: camera, quality: .main)
        let sub = StreamKey(camera: camera, quality: .sub)
        #expect(main != sub)
        #expect(Set([main, sub, main]).count == 2)
    }

    @Test func rtspTransportKindDefaultsAndPorts() {
        #expect(RTSPTransportKind.tcpInterleaved.defaultPort == 554)
        #expect(RTSPTransportKind.tcpTLS.defaultPort == 322)
        #expect(RTSPTransportKind.auto.defaultPort == 554)
        #expect(RTSPTransportKind.udpUnicast.isUDP)
        #expect(RTSPTransportKind.udpMulticast.isUDP)
        #expect(!RTSPTransportKind.tcpInterleaved.isUDP)
        #expect(!RTSPTransportKind.tcpTLS.isUDP)
        #expect(!RTSPTransportKind.auto.isUDP)
    }

    @Test func latencyPresetDepthsMatchTheContract() {
        #expect(LatencyPreset.low.jitterBufferDepth == .milliseconds(40))
        #expect(LatencyPreset.balanced.jitterBufferDepth == .milliseconds(120))
        #expect(LatencyPreset.quality.jitterBufferDepth == .milliseconds(350))
        #expect(LatencyPreset.low.jitterBufferPackets == 8)
        #expect(LatencyPreset.balanced.jitterBufferPackets == 24)
        #expect(LatencyPreset.quality.jitterBufferPackets == 64)
        #expect(LatencyPreset.low.decodeQueueDepth == 2)
        #expect(LatencyPreset.balanced.decodeQueueDepth == 3)
        #expect(LatencyPreset.quality.decodeQueueDepth == 5)
    }
}
