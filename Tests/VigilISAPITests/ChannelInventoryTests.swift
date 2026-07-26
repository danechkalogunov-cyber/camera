//
//  ChannelInventoryTests.swift
//  VigilISAPITests
//
//  Channel enumeration on a camera and on an NVR, the channel → `StreamingChannelID` mapping, and
//  the wire-unit conversions in both directions.
//  Covers docs/spec-isapi.md §11 and §12.1–§12.3.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - Fixtures

enum InventoryFixtures {

    /// docs/spec-isapi.md §12.1, verbatim — one 4K H.265 main stream.
    static let cameraStreamingChannels = """
        <StreamingChannelList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <StreamingChannel version="2.0">
            <id>101</id>
            <channelName>Driveway</channelName>
            <enabled>true</enabled>
            <Transport>
              <rtspPortNo>554</rtspPortNo>
              <maxPacketSize>1000</maxPacketSize>
              <ControlProtocolList>
                <ControlProtocol><streamingTransport>RTSP</streamingTransport></ControlProtocol>
                <ControlProtocol><streamingTransport>HTTP</streamingTransport></ControlProtocol>
              </ControlProtocolList>
              <Unicast><enabled>true</enabled><rtpTransportType>RTP/TCP</rtpTransportType></Unicast>
              <Multicast>
                <enabled>false</enabled>
                <destIPAddress>0.0.0.0</destIPAddress>
                <videoDestPortNo>8600</videoDestPortNo>
                <audioDestPortNo>8602</audioDestPortNo>
              </Multicast>
              <Security><enabled>true</enabled><certificateType>digest</certificateType></Security>
            </Transport>
            <Video>
              <enabled>true</enabled>
              <videoInputChannelID>1</videoInputChannelID>
              <videoCodecType>H.265</videoCodecType>
              <videoScanType>progressive</videoScanType>
              <videoResolutionWidth>3840</videoResolutionWidth>
              <videoResolutionHeight>2160</videoResolutionHeight>
              <videoQualityControlType>VBR</videoQualityControlType>
              <constantBitRate>8192</constantBitRate>
              <fixedQuality>60</fixedQuality>
              <vbrUpperCap>8192</vbrUpperCap>
              <vbrLowerCap>32</vbrLowerCap>
              <maxFrameRate>2000</maxFrameRate>
              <keyFrameInterval>2000</keyFrameInterval>
              <snapShotImageType>JPEG</snapShotImageType>
              <GovLength>40</GovLength>
              <SVC><enabled>false</enabled></SVC>
              <H265Profile>Main</H265Profile>
              <SmartCodec><enabled>true</enabled></SmartCodec>
            </Video>
            <Audio>
              <enabled>true</enabled>
              <audioInputChannelID>1</audioInputChannelID>
              <audioCompressionType>G.711ulaw</audioCompressionType>
            </Audio>
          </StreamingChannel>
          <StreamingChannel version="2.0">
            <id>102</id>
            <channelName>Driveway</channelName>
            <enabled>true</enabled>
            <Transport>
              <rtspPortNo>554</rtspPortNo>
              <maxPacketSize>1000</maxPacketSize>
              <Unicast><enabled>true</enabled><rtpTransportType>RTP/UDP</rtpTransportType></Unicast>
            </Transport>
            <Video>
              <enabled>true</enabled>
              <videoCodecType>H.264-MP</videoCodecType>
              <videoResolutionWidth>640</videoResolutionWidth>
              <videoResolutionHeight>360</videoResolutionHeight>
              <videoQualityControlType>VBR</videoQualityControlType>
              <vbrUpperCap>512</vbrUpperCap>
              <vbrLowerCap>32</vbrLowerCap>
              <fixedQuality>60</fixedQuality>
              <maxFrameRate>1250</maxFrameRate>
              <keyFrameInterval>2000</keyFrameInterval>
              <GovLength>24</GovLength>
              <SmartCodec><enabled>false</enabled></SmartCodec>
            </Video>
            <Audio><enabled>false</enabled></Audio>
          </StreamingChannel>
        </StreamingChannelList>
        """

    /// A three-channel NVR inventory: channel 1 main+sub, channel 7 sub only, channel 12 main.
    /// Synthesised from the §12.1 element shape and the §12.4 id table — no real capture available.
    static let nvrStreamingChannels = """
        <StreamingChannelList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <StreamingChannel><id>101</id><channelName>NVR CH1</channelName><enabled>true</enabled>
            <Transport><rtspPortNo>554</rtspPortNo></Transport>
            <Video><videoCodecType>H.264</videoCodecType><maxFrameRate>2500</maxFrameRate>
            <videoResolutionWidth>1920</videoResolutionWidth>
            <videoResolutionHeight>1080</videoResolutionHeight>
            <keyFrameInterval>2000</keyFrameInterval></Video></StreamingChannel>
          <StreamingChannel><id>102</id><enabled>true</enabled>
            <Video><videoCodecType>H.264</videoCodecType><maxFrameRate>1200</maxFrameRate>
            <videoResolutionWidth>352</videoResolutionWidth>
            <videoResolutionHeight>288</videoResolutionHeight></Video></StreamingChannel>
          <StreamingChannel><id>702</id><enabled>true</enabled>
            <Video><videoCodecType>H.265</videoCodecType><maxFrameRate>1500</maxFrameRate>
            </Video></StreamingChannel>
          <StreamingChannel><id>1201</id><enabled>false</enabled>
            <Video><videoCodecType>H.264</videoCodecType></Video></StreamingChannel>
          <StreamingChannel><id>1</id><enabled>true</enabled>
            <Video><videoCodecType>H.264</videoCodecType></Video></StreamingChannel>
        </StreamingChannelList>
        """

    /// docs/spec-isapi.md §11.1, verbatim.
    static let inputProxyChannels = """
        <InputProxyChannelList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <InputProxyChannel version="2.0">
            <id>1</id>
            <name>Driveway</name>
            <sourceInputPortDescriptor>
              <proxyProtocol>ISAPI</proxyProtocol>
              <addressingFormatType>ipaddress</addressingFormatType>
              <ipAddress>192.168.1.64</ipAddress>
              <managePortNo>8000</managePortNo>
              <srcInputPort>1</srcInputPort>
              <userName>admin</userName>
              <streamType>auto</streamType>
              <deviceID>48343131-3435-3234-3138-343131343535</deviceID>
            </sourceInputPortDescriptor>
          </InputProxyChannel>
          <InputProxyChannel version="2.0">
            <id>7</id>
            <name>Loading bay</name>
            <sourceInputPortDescriptor>
              <proxyProtocol>ONVIF</proxyProtocol>
              <ipAddress>192.168.1.71</ipAddress>
              <managePortNo>80</managePortNo>
              <srcInputPort>1</srcInputPort>
              <userName>viewer</userName>
            </sourceInputPortDescriptor>
          </InputProxyChannel>
        </InputProxyChannelList>
        """

    /// The list form of docs/spec-isapi.md §11.2, with channel 7 offline for a stated reason.
    static let inputProxyStatusList = """
        <InputProxyChannelStatusList version="2.0"
            xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <InputProxyChannelStatus version="2.0">
            <id>1</id>
            <online>true</online>
            <streamingProxyChannelIdList>
              <streamingProxyChannelId>1</streamingProxyChannelId>
              <streamingProxyChannelId>2</streamingProxyChannelId>
            </streamingProxyChannelIdList>
            <chanDetectResult>online</chanDetectResult>
          </InputProxyChannelStatus>
          <InputProxyChannelStatus version="2.0">
            <id>7</id>
            <online>false</online>
            <chanDetectResult>userOrPasswordError</chanDetectResult>
          </InputProxyChannelStatus>
        </InputProxyChannelStatusList>
        """

    /// docs/spec-isapi.md §11.3, verbatim.
    static let videoInputChannels = """
        <VideoInputChannelList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <VideoInputChannel version="2.0">
            <id>1</id>
            <inputPort>1</inputPort>
            <name>Camera 01</name>
            <videoFormat>PAL</videoFormat>
            <powerLineFrequencyMode>50hz</powerLineFrequencyMode>
            <whiteBalanceMode>auto</whiteBalanceMode>
            <resDesc>1080p</resDesc>
          </VideoInputChannel>
        </VideoInputChannelList>
        """

    static func document(_ xml: String) throws -> ISAPIDocument {
        try ISAPIDocument(parsing: Data(xml.utf8))
    }
}

// MARK: - StreamingChannelDecodeSuite

@Suite struct StreamingChannelDecodeSuite {

    @Test func streamingChannelDecodesEveryFieldOfTheMainStream() throws {
        let result = StreamingChannelConfig.list(
            document: try InventoryFixtures.document(InventoryFixtures.cameraStreamingChannels))
        #expect(result.skipped.isEmpty)
        let main = try #require(result.channels.first { $0.id.value == 101 })
        #expect(main.channelName == "Driveway")
        #expect(main.enabled)
        #expect(main.codec.codec == .h265)
        #expect(main.codec.raw == "H.265")
        #expect(main.codec.profile == "Main")
        #expect(main.width == 3840)
        #expect(main.height == 2160)
        // maxFrameRate is fps × 100: 2000 is 20 fps, not 2000 fps and not 20.00 something else.
        #expect(main.frameRate == 20)
        #expect(main.bitrateControl == .vbr(upper: 8192, lower: 32, quality: 60))
        // keyFrameInterval is milliseconds; GovLength is frames. They are different numbers with
        // different units and both are kept.
        #expect(main.keyFrameIntervalMS == 2000)
        #expect(main.govLength == 40)
        #expect(main.smartCodecEnabled)
        #expect(!main.svcEnabled)
        #expect(main.scanType == .progressive)
        #expect(main.audioEnabled)
        #expect(main.audioCodec?.codec == .g711U)
        #expect(main.rtspPort == 554)
        #expect(main.maxPacketSize == 1000)
        #expect(main.preferredRTPTransport == .tcp)
        #expect(main.multicast?.enabled == false)
        #expect(main.multicast?.videoPort == 8600)
        #expect(!main.hasMTUHazard)
    }

    @Test func streamingChannelDecodesTheFractionalSubstreamRate() throws {
        let result = StreamingChannelConfig.list(
            document: try InventoryFixtures.document(InventoryFixtures.cameraStreamingChannels))
        let sub = try #require(result.channels.first { $0.id.value == 102 })
        // 1250 is 12.5 fps — the case that breaks an integer-only conversion.
        #expect(sub.frameRate == 12.5)
        #expect(sub.codec.codec == .h264)
        #expect(sub.codec.profile == "Main")     // from the `-MP` suffix, with no profile element
        #expect(sub.govLength == 24)
        #expect(!sub.smartCodecEnabled)
        #expect(!sub.audioEnabled)
        #expect(sub.audioCodec == nil)
        #expect(sub.id.channel == .first)
        #expect(sub.id.quality == .sub)
    }

    @Test func streamingChannelSkipsASingleDigitIdInsteadOfInventingChannelZero() throws {
        let result = StreamingChannelConfig.list(
            document: try InventoryFixtures.document(InventoryFixtures.nvrStreamingChannels))
        // `<id>1</id>` is the 5.1.x single-digit firmware quirk. Accepting it would address
        // channel 0, so it is skipped and reported.
        #expect(result.skipped == [1])
        #expect(result.channels.map(\.id.value).sorted() == [101, 102, 702, 1201])
    }

    @Test func streamingChannelFlagsAnMTUHazard() throws {
        let xml = """
            <StreamingChannel><id>101</id>
            <Transport><maxPacketSize>1460</maxPacketSize>
            <Unicast><rtpTransportType>RTP/UDP</rtpTransportType></Unicast></Transport>
            <Video><videoCodecType>H.264</videoCodecType></Video></StreamingChannel>
            """
        let config = try StreamingChannelConfig(
            node: try InventoryFixtures.document(xml).root)
        #expect(config.hasMTUHazard)
    }

    @Test func videoCodecWireKeepsUndecodableCodecsHonest() {
        #expect(VideoCodecWire(raw: "MPEG4").codec == nil)
        #expect(VideoCodecWire(raw: "MPEG4").isDecodable == false)
        #expect(VideoCodecWire(raw: "SVAC").codec == nil)
        #expect(VideoCodecWire(raw: "h.264").codec == .h264)
        #expect(VideoCodecWire(raw: "H264").codec == .h264)
        #expect(VideoCodecWire(raw: "H.264-BP").profile == "Baseline")
        #expect(VideoCodecWire(raw: "H.264-HP").profile == "High")
        #expect(VideoCodecWire(raw: "H.265").codec == .h265)
        #expect(VideoCodecWire(raw: "MJPEG").codec == .mjpeg)
        #expect(VideoCodecWire(raw: "H.265", profileElement: "Main10").profile == "Main10")
    }

    @Test func audioCodecWireMapsWhatItCanAndKeepsTheRest() {
        #expect(AudioCodecWire(raw: "G.711ulaw").codec == .g711U)
        #expect(AudioCodecWire(raw: "G.711alaw").codec == .g711A)
        #expect(AudioCodecWire(raw: "G.726").codec == .g726)
        #expect(AudioCodecWire(raw: "AAC").codec == .aac)
        #expect(AudioCodecWire(raw: "PCM").codec == .pcmS16LE)
        // `G.722.1` and `MP2L2` are legal wire values with no `AudioCodec` case; the raw string
        // still reaches the UI so it can say why there is no audio.
        #expect(AudioCodecWire(raw: "G.722.1").codec == nil)
        #expect(AudioCodecWire(raw: "G.722.1").raw == "G.722.1")
        #expect(AudioCodecWire(raw: "MP2L2").codec == nil)
        #expect(AudioCodecWire.wireName(for: .g711U) == "G.711ulaw")
        #expect(AudioCodecWire.wireName(for: .aac) == "AAC")
    }
}

// MARK: - WireUnitSuite

@Suite struct WireUnitSuite {

    @Test func wireUnitsConvertFrameRateBothWays() {
        #expect(ISAPIUnits.frameRate(fromWire: 2000) == 20)
        #expect(ISAPIUnits.frameRate(fromWire: 1250) == 12.5)
        // Below 100 is a legitimate sub-1-fps mode, not an error to be clamped away.
        #expect(ISAPIUnits.frameRate(fromWire: 50) == 0.5)
        #expect(ISAPIUnits.frameRate(fromWire: 0) == nil)
        #expect(ISAPIUnits.frameRate(fromWire: -100) == nil)
        #expect(ISAPIUnits.wireFrameRate(fromFPS: 20) == 2000)
        #expect(ISAPIUnits.wireFrameRate(fromFPS: 12.5) == 1250)
        #expect(ISAPIUnits.wireFrameRate(fromFPS: 0.5) == 50)
        #expect(ISAPIUnits.wireFrameRate(fromFPS: 30) == 3000)
    }

    @Test func wireUnitsRoundTripEveryDocumentedFrameRate() throws {
        for wire in [50, 100, 400, 1200, 1250, 2000, 2500, 3000, 6000] {
            let fps = try #require(ISAPIUnits.frameRate(fromWire: wire))
            #expect(ISAPIUnits.wireFrameRate(fromFPS: fps) == wire)
        }
    }

    @Test func wireUnitsConvertKeyFrameIntervalBothWays() {
        // Milliseconds, not frames.
        #expect(ISAPIUnits.keyFrameSeconds(fromWireMilliseconds: 2000) == 2)
        #expect(ISAPIUnits.keyFrameSeconds(fromWireMilliseconds: 500) == 0.5)
        #expect(ISAPIUnits.wireKeyFrameMilliseconds(fromSeconds: 2) == 2000)
        #expect(ISAPIUnits.wireKeyFrameMilliseconds(fromSeconds: 0.04) == 40)
    }

    @Test func wireUnitsUseDecimalMegabytesForStorage() {
        // Hikvision counts 1 MB as 1 000 000 bytes; anything else disagrees with the camera's own
        // web UI by five percent.
        #expect(ISAPIUnits.bytes(fromDecimalMB: 3_815_447) == 3_815_447_000_000)
        #expect(ISAPIUnits.bytes(fromDecimalMB: 0) == 0)
    }

    @Test func wireUnitsReadSampleRateAsKilohertz() {
        #expect(ISAPIUnits.sampleRateHz(fromWire: 8) == 8000)
        #expect(ISAPIUnits.sampleRateHz(fromWire: 16) == 16_000)
        // A device that already reported hertz is passed through rather than multiplied again.
        #expect(ISAPIUnits.sampleRateHz(fromWire: 8000) == 8000)
    }

    @Test func wireUnitsSniffTheRegionCoordinateScale() {
        #expect(ISAPIUnits.regionScale(forMaximumCoordinate: 1000) == 1000)
        #expect(ISAPIUnits.regionScale(forMaximumCoordinate: 560) == 1000)
        #expect(ISAPIUnits.regionScale(forMaximumCoordinate: 9500) == 10_000)
    }
}

// MARK: - ChannelMergeSuite

@Suite struct ChannelMergeSuite {

    @Test func channelMergeEnumeratesACameraFromStreamingAlone() throws {
        let streaming = StreamingChannelConfig.list(
            document: try InventoryFixtures.document(InventoryFixtures.cameraStreamingChannels))
        let channels = ChannelInventory.merge(streaming: streaming.channels)
        #expect(channels.count == 1)
        let channel = try #require(channels.first)
        #expect(channel.channel == .first)
        #expect(channel.displayName == "Driveway")
        #expect(channel.isOnline)
        #expect(channel.streams.count == 2)
        #expect(channel.streams[.main]?.width == 3840)
        #expect(channel.streams[.sub]?.width == 640)
        #expect(channel.upstream == nil)
    }

    @Test func channelMergeEnumeratesAnNVRWithNamesAndOfflineReasons() throws {
        let streaming = StreamingChannelConfig.list(
            document: try InventoryFixtures.document(InventoryFixtures.nvrStreamingChannels))
        let proxy = InputProxyChannel.list(
            document: try InventoryFixtures.document(InventoryFixtures.inputProxyChannels))
        let status = InputProxyChannelStatus.list(
            document: try InventoryFixtures.document(InventoryFixtures.inputProxyStatusList))
        let inputs = VideoInputChannel.list(
            document: try InventoryFixtures.document(InventoryFixtures.videoInputChannels))
        let channels = ChannelInventory.merge(streaming: streaming.channels,
                                              inputProxy: proxy,
                                              proxyStatus: status,
                                              videoInputs: inputs)
        #expect(channels.map(\.channel.value) == [1, 7, 12])

        // The InputProxy name wins over the video-input name and over the streaming name: on an
        // NVR it is what the operator typed in.
        #expect(channels[0].displayName == "Driveway")
        #expect(channels[0].isOnline)
        #expect(channels[0].offlineReason == nil)
        #expect(channels[0].streams.count == 2)
        #expect(channels[0].upstream?.protocolName == "ISAPI")
        #expect(channels[0].upstream?.ipAddress == "192.168.1.64")
        #expect(channels[0].upstream?.managePort == 8000)

        // Channel 7 is offline and the device's own reason is passed through verbatim.
        #expect(channels[1].displayName == "Loading bay")
        #expect(!channels[1].isOnline)
        #expect(channels[1].offlineReason == "userOrPasswordError")
        #expect(channels[1].upstream?.protocolName == "ONVIF")

        // Channel 12 exists only in the streaming inventory and only as a disabled main stream.
        #expect(channels[2].displayName == "Channel 12")
        #expect(!channels[2].isEnabled)
        #expect(channels[2].isOnline)          // no status document ⇒ assumed reachable
    }

    @Test func channelMergeKeepsAProxiedChannelWithNoStreamingElement() throws {
        // An offline NVR channel has no `<StreamingChannel>` on some firmware. Dropping it would
        // make the channel vanish exactly when the user needs to see why.
        let proxy = InputProxyChannel.list(
            document: try InventoryFixtures.document(InventoryFixtures.inputProxyChannels))
        let status = InputProxyChannelStatus.list(
            document: try InventoryFixtures.document(InventoryFixtures.inputProxyStatusList))
        let channels = ChannelInventory.merge(streaming: [], inputProxy: proxy,
                                              proxyStatus: status)
        #expect(channels.count == 2)
        #expect(channels[1].channel.value == 7)
        #expect(channels[1].streams.isEmpty)
        #expect(!channels[1].isOnline)
    }

    @Test func channelInventoryFallsBackToOneChannel() {
        let channels = ChannelInventory.fallbackSingleChannel()
        #expect(channels.count == 1)
        #expect(channels[0].channel == .first)
        #expect(channels[0].streamingChannelID(.main).value == 101)
        #expect(channels[0].streamingChannelID(.sub).value == 102)
    }

    @Test func channelStreamPreferenceFallsBackRatherThanReturningNothing() throws {
        let streaming = StreamingChannelConfig.list(
            document: try InventoryFixtures.document(InventoryFixtures.nvrStreamingChannels))
        let channels = ChannelInventory.merge(streaming: streaming.channels)
        let channel7 = try #require(channels.first { $0.channel.value == 7 })
        // Channel 7 has only a substream; asking for main must still open something.
        #expect(channel7.stream(preferring: .sub)?.id.value == 702)
        #expect(channel7.stream(preferring: .main)?.id.value == 702)
    }

    @Test func channelStreamingIDIsPureArithmetic() {
        // docs/spec-isapi.md §12.4's table. The `{ch}0{stream}` form from old Hikvision documents
        // is wrong for ch >= 10, which is why only the arithmetic form exists.
        #expect(StreamingChannelID(channel: ChannelID(1), quality: .main).value == 101)
        #expect(StreamingChannelID(channel: ChannelID(1), quality: .sub).value == 102)
        #expect(StreamingChannelID(channel: ChannelID(1), quality: .third).value == 103)
        #expect(StreamingChannelID(channel: ChannelID(7), quality: .sub).value == 702)
        #expect(StreamingChannelID(channel: ChannelID(12), quality: .main).value == 1201)
        #expect(StreamingChannelID(channel: ChannelID(32), quality: .sub).value == 3202)
        let round = StreamingChannelID(channel: ChannelID(12), quality: .sub)
        #expect(round.channel == ChannelID(12))
        #expect(round.quality == .sub)
    }

    @Test func inputProxyStatusReadsTheSingleChannelForm() throws {
        // The fallback shape, for the NVRs whose list form 404s.
        let xml = """
            <InputProxyChannelStatus version="2.0">
              <id>3</id><online>false</online><chanDetectResult>networkAbnormal</chanDetectResult>
            </InputProxyChannelStatus>
            """
        let statuses = InputProxyChannelStatus.list(
            document: try InventoryFixtures.document(xml))
        #expect(statuses.count == 1)
        #expect(statuses[0].channel.value == 3)
        #expect(!statuses[0].online)
        #expect(statuses[0].detectResult == "networkAbnormal")
    }
}

// MARK: - StreamPatchSuite

@Suite struct StreamPatchSuite {

    @Test func streamPatchWritesTheWholeElementBack() throws {
        let document = try InventoryFixtures.document(InventoryFixtures.cameraStreamingChannels)
        let result = StreamingChannelConfig.list(document: document)
        let sub = try #require(result.channels.first { $0.id.value == 102 })
        let original = try #require(sub.originalNode)
        let patch = StreamingChannelPatch.gridOptimizedSubstream
        let patched = patch.applied(to: original)
        let text = String(decoding: patched.serialized(declaration: false), as: UTF8.self)

        // The patched values.
        #expect(text.contains("<videoCodecType>H.264</videoCodecType>"))
        #expect(text.contains("<videoResolutionWidth>640</videoResolutionWidth>"))
        #expect(text.contains("<videoResolutionHeight>360</videoResolutionHeight>"))
        #expect(text.contains("<maxFrameRate>1200</maxFrameRate>"))
        #expect(text.contains("<keyFrameInterval>2000</keyFrameInterval>"))
        #expect(text.contains("<vbrUpperCap>512</vbrUpperCap>"))
        // SmartCodec must be off on a substream: its long GOP delays the first keyframe 4–8 s.
        #expect(text.contains("<SmartCodec><enabled>false</enabled></SmartCodec>"))
        // Everything the patch did not name survives, which is the whole point of
        // read-modify-write (docs/spec-isapi.md §12.3).
        #expect(text.contains("<rtspPortNo>554</rtspPortNo>"))
        #expect(text.contains("<GovLength>24</GovLength>"))
        #expect(text.contains("<vbrLowerCap>32</vbrLowerCap>"))
        #expect(text.contains("<videoInputChannelID>") == false)   // absent in this fixture
        #expect(text.hasPrefix("<StreamingChannel"))
    }

    @Test func streamPatchEchoesTheDevicesVersionAndNamespace() throws {
        let document = try InventoryFixtures.document(InventoryFixtures.cameraStreamingChannels)
        let result = StreamingChannelConfig.list(document: document)
        let main = try #require(result.channels.first)
        let original = try #require(main.originalNode)
        var patch = StreamingChannelPatch()
        patch.frameRate = 15
        let text = String(decoding: patch.applied(to: original).serialized(declaration: false),
                          as: UTF8.self)
        #expect(text.contains("version=\"2.0\""))
        #expect(text.contains("<maxFrameRate>1500</maxFrameRate>"))
    }

    @Test func streamPatchSwitchesToCBRWithBothElements() throws {
        let document = try InventoryFixtures.document(InventoryFixtures.cameraStreamingChannels)
        let main = try #require(StreamingChannelConfig.list(document: document).channels.first)
        var patch = StreamingChannelPatch()
        patch.bitrateControl = .cbr(kbps: 4096)
        let text = String(decoding: patch.applied(to: try #require(main.originalNode))
                            .serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<videoQualityControlType>CBR</videoQualityControlType>"))
        #expect(text.contains("<constantBitRate>4096</constantBitRate>"))
    }

    @Test func streamPatchValidatesBeforeSpendingARoundTrip() {
        #expect(StreamingChannelPatch().isEmpty)
        #expect(StreamingChannelPatch.gridOptimizedSubstream.validationFailures().isEmpty)

        var bad = StreamingChannelPatch()
        bad.frameRate = 0.1
        #expect(bad.validationFailures().count == 1)

        var interval = StreamingChannelPatch()
        interval.keyFrameIntervalMS = 15
        #expect(interval.validationFailures().count == 1)
        interval.keyFrameIntervalMS = 20
        #expect(interval.validationFailures().isEmpty)

        var gop = StreamingChannelPatch()
        gop.govLength = 401
        #expect(gop.validationFailures().count == 1)

        var vbr = StreamingChannelPatch()
        vbr.bitrateControl = .vbr(upper: 16, lower: 32, quality: 60)
        #expect(vbr.validationFailures().count == 2)   // ceiling out of range, floor above ceiling

        var halfSize = StreamingChannelPatch()
        halfSize.width = 640
        #expect(halfSize.validationFailures().count == 1)
    }

    @Test func bitrateControlReportsThePeakWhicheverModeIsUsed() {
        #expect(BitrateControl.cbr(kbps: 4096).peakKbps == 4096)
        #expect(BitrateControl.vbr(upper: 512, lower: 32, quality: 60).peakKbps == 512)
    }
}
