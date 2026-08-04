//
//  SettingsAndStorageTests.swift
//  VigilISAPITests
//
//  The motion grid's `gridMap` encoding, the image sub-resources and their read-modify-write
//  patches, JPEG snapshot policy and sniffing, storage volumes in decimal MB, two-way audio codec
//  negotiation, and the event-trigger and schedule readers.
//  Covers docs/spec-isapi.md §12.5, §14.7–§14.9, §15.4, §16 and §17.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - TwoWayAudioSuite

@Suite struct TwoWayAudioSuite {

    @Test func twoWayAudioChannelDecodesTheFixture() throws {
        let channels = TwoWayAudioChannel.list(
            document: try SettingsFixtures.document(SettingsFixtures.twoWayAudioChannels))
        let channel = try #require(channels.first)
        #expect(channel.id == 1)
        #expect(channel.enabled)
        #expect(channel.codec.codec == .g711U)
        #expect(channel.bitrateKbps == 64)
        // `audioSamplingRate` is kilohertz as an integer.
        #expect(channel.sampleRateHz == 8000)
        #expect(channel.inputType == "MicIn")
        #expect(channel.associatedVideoChannels == [ChannelID(1)])
        // With no `opt` attribute the device offers exactly what it is set to.
        #expect(channel.supportedCodecs.count == 1)
    }

    @Test func twoWayAudioReadsTheCodecMenuFromTheOptAttribute() throws {
        let channels = TwoWayAudioChannel.list(
            document: try SettingsFixtures.document(SettingsFixtures.twoWayAudioChannels))
        let base = try #require(channels.first)
        let merged = base.mergingCapabilities(
            try SettingsFixtures.document(SettingsFixtures.twoWayAudioCapabilities))
        #expect(merged.supportedCodecs.count == 4)
        #expect(merged.supportedCodecs.map(\.raw)
                == ["G.711ulaw", "G.711alaw", "G.722.1", "AAC"])
        // `G.722.1` has no `AudioCodec` case and is preserved as raw only.
        #expect(merged.supportedCodecs[2].codec == nil)
    }

    @Test func twoWayAudioNegotiatesInThePreferenceOrder() throws {
        let channels = TwoWayAudioChannel.list(
            document: try SettingsFixtures.document(SettingsFixtures.twoWayAudioChannels))
        var channel = try #require(channels.first)
        channel.supportedCodecs = ["G.722.1", "AAC", "G.711alaw", "G.711ulaw"]
            .map { AudioCodecWire(raw: $0) }
        // µ-law first: universally supported, encodes from an 8 kHz mono buffer with a table, no
        // container framing.
        #expect(channel.negotiatedSendCodec() == .g711U)

        channel.supportedCodecs = [AudioCodecWire(raw: "G.711alaw"), AudioCodecWire(raw: "AAC")]
        #expect(channel.negotiatedSendCodec() == .g711A)

        // Nothing Vigil can encode ⇒ the talk button is disabled rather than sending static.
        channel.supportedCodecs = [AudioCodecWire(raw: "G.722.1"), AudioCodecWire(raw: "MP2L2")]
        #expect(channel.negotiatedSendCodec() == nil)
    }

    @Test func twoWayAudioCodecPatchIsReadModifyWrite() throws {
        let channels = TwoWayAudioChannel.list(
            document: try SettingsFixtures.document(SettingsFixtures.twoWayAudioChannels))
        var channel = try #require(channels.first)
        let patched = try #require(channel.codecPatch(to: .g711A))
        let text = String(decoding: patched.serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<audioCompressionType>G.711alaw</audioCompressionType>"))
        // Everything else survives, including elements Vigil does not model.
        #expect(text.contains("<noisereduce>true</noisereduce>"))
        #expect(text.contains("<audioBitRate>64</audioBitRate>"))
        channel.originalNode = nil
        #expect(channel.codecPatch(to: .g711A) == nil)
    }

    @Test func twoWayAudioOpenResultToleratesBothResponseShapes() throws {
        let withSession = TwoWayAudioOpenResult(document: try SettingsFixtures.document(
            "<TwoWayAudioSession><sessionId>112</sessionId></TwoWayAudioSession>"))
        #expect(withSession.sessionID == "112")
        // A `<ResponseStatus>` with statusCode 1 and no id is also success.
        let plain = TwoWayAudioOpenResult(
            document: try SettingsFixtures.document(RequestDouble.okStatus))
        #expect(plain.sessionID == nil)
        #expect(TwoWayAudioOpenResult(document: nil).sessionID == nil)
    }

    @Test func twoWayAudioSessionFramesAndSilence() async throws {
        let double = RequestDouble()
        let session = TwoWayAudioSession(requests: double, channel: 1, codec: .g711U,
                                         sampleRateHz: 8000)
        // 160 bytes per 20 ms frame at 8 kHz µ-law.
        #expect(await session.frameBytes == 160)
        let silence = await session.silenceFrame
        #expect(silence.count == 160)
        #expect(silence.allSatisfy { $0 == 0xFF })

        let alaw = TwoWayAudioSession(requests: double, channel: 1, codec: .g711A,
                                      sampleRateHz: 8000)
        #expect(await alaw.silenceFrame.allSatisfy { $0 == 0xD5 })
        let linear = TwoWayAudioSession(requests: double, channel: 1, codec: .pcmS16LE,
                                        sampleRateHz: 8000)
        #expect(await linear.frameBytes == 320)
        #expect(await linear.silenceFrame.allSatisfy { $0 == 0x00 })
    }

    @Test func twoWayAudioSessionConfiguresTheCodecBeforeOpening() async throws {
        // The device decodes according to the channel's configured codec, so this ordering is
        // mandatory, not an optimisation.
        let double = RequestDouble()
        let channels = TwoWayAudioChannel.list(
            document: try SettingsFixtures.document(SettingsFixtures.twoWayAudioChannels))
        let current = try #require(channels.first)   // configured for µ-law
        let session = TwoWayAudioSession(requests: double, channel: 1, codec: .g711A,
                                         sampleRateHz: 8000)
        try await session.open(configuring: current)
        let recorded = await double.recorded
        #expect(recorded.count == 2)
        #expect(recorded[0].resource == "/System/TwoWayAudio/channels/1")
        #expect(recorded[0].bodyText?.contains("G.711alaw") == true)
        #expect(recorded[1].resource == "/System/TwoWayAudio/channels/1/open")
        #expect(recorded[1].body == nil)
        #expect(await session.state == .talking)
    }

    @Test func twoWayAudioSessionSkipsTheCodecPUTWhenItAlreadyMatches() async throws {
        let double = RequestDouble()
        let channels = TwoWayAudioChannel.list(
            document: try SettingsFixtures.document(SettingsFixtures.twoWayAudioChannels))
        let session = TwoWayAudioSession(requests: double, channel: 1, codec: .g711U,
                                         sampleRateHz: 8000)
        try await session.open(configuring: channels.first)
        #expect(await double.recorded.count == 1)
    }

    @Test func twoWayAudioSessionQueueDropsTheOldestBeyondTwentyFive() async throws {
        let double = RequestDouble()
        let session = TwoWayAudioSession(requests: double, channel: 1, codec: .g711U,
                                         sampleRateHz: 8000)
        try await session.open(configuring: nil)
        for index in 0..<40 {
            await session.enqueue(Data([UInt8(index)]))
        }
        #expect(await session.droppedFrames == 15)
        // The queue holds the newest 25; the first frame out is the oldest survivor, frame 15.
        let batch = await session.nextFrame()
        #expect(batch == Data([15, 16, 17, 18]))
    }

    @Test func twoWayAudioSessionWritesSilenceWhenTheQueueIsEmpty() async throws {
        // Several firmwares close the session after about a second with no data, so the pump writes
        // silence rather than letting the stream starve.
        let double = RequestDouble()
        let upload = UploadDouble()
        let session = TwoWayAudioSession(requests: double, channel: 1, codec: .g711U,
                                         sampleRateHz: 8000)
        try await session.open(configuring: nil)
        await session.attach(upload)
        await session.pump()
        let written = await upload.chunks
        #expect(written.count == 1)
        #expect(written[0] == Data(repeating: 0xFF, count: 160))

        await session.enqueue(Data(repeating: 0x10, count: 160))
        await session.pump()
        #expect(await upload.chunks.count == 2)
        #expect(await upload.chunks[1] == Data(repeating: 0x10, count: 160))
    }

    @Test func twoWayAudioSessionFailsAndReleasesOnALostUpload() async throws {
        // A half-sent audio stream is not resumable, so the session fails and the UI re-arms the
        // button rather than trying to continue.
        let double = RequestDouble()
        let session = TwoWayAudioSession(requests: double, channel: 1, codec: .g711U,
                                         sampleRateHz: 8000)
        try await session.open(configuring: nil)
        await session.attach(UploadDouble(failing: .notConnected("peer closed")))
        await session.pump()
        if case .failed = await session.state {} else {
            Issue.record("expected a failed state after a lost upload")
        }
        // Even from the failed state the channel is released.
        await session.close()
        #expect(await double.requests(to: "/close").count == 1)
    }

    @Test func twoWayAudioSessionAlwaysSendsClose() async throws {
        let double = RequestDouble()
        let session = TwoWayAudioSession(requests: double, channel: 1, codec: .g711U,
                                         sampleRateHz: 8000)
        // Even without a successful open: a session the device believes is open blocks every other
        // client for 60–120 s.
        await session.close()
        let recorded = await double.recorded
        #expect(recorded.count == 1)
        #expect(recorded[0].resource == "/System/TwoWayAudio/channels/1/close")
        #expect(await session.state == .closed)
        // Idempotent.
        await session.close()
        #expect(await double.recorded.count == 1)
    }

    @Test func twoWayAudioSessionFailsWhenOpenIsRefused() async throws {
        let double = RequestDouble()
        await double.route("/open", failing: .device(statusCode: 4, sub: "notsupport"))
        let session = TwoWayAudioSession(requests: double, channel: 1, codec: .g711U,
                                         sampleRateHz: 8000)
        await #expect(throws: ISAPIError.self) {
            try await session.open(configuring: nil)
        }
        if case .failed = await session.state {} else {
            Issue.record("expected a failed state")
        }
    }
}
