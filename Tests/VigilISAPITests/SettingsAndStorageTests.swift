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

// MARK: - Fixtures

enum SettingsFixtures {

    /// docs/spec-isapi.md §14.9, with a 108-character `gridMap` for the 22 × 18 grid.
    static let motionDetection = """
        <MotionDetection version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <enabled>true</enabled>
          <enableHighlight>true</enableHighlight>
          <samplingInterval>2</samplingInterval>
          <startTriggerTime>500</startTriggerTime>
          <endTriggerTime>500</endTriggerTime>
          <regionType>grid</regionType>
          <Grid>
            <rowGranularity>18</rowGranularity>
            <columnGranularity>22</columnGranularity>
          </Grid>
          <MotionDetectionLayout version="2.0">
            <sensitivityLevel>60</sensitivityLevel>
            <layout>
              <gridMap>\(sixRowGridMap)</gridMap>
            </layout>
          </MotionDetectionLayout>
        </MotionDetection>
        """

    /// Six rows of `fffffc` (columns 0…21 on, the two padding bits off) then twelve empty rows —
    /// the shape docs/spec-isapi.md §14.9 prints.
    static let sixRowGridMap = String(repeating: "fffffc", count: 6)
        + String(repeating: "000000", count: 12)

    /// docs/spec-isapi.md §17.2's `<Color>` sample.
    static let color = """
        <Color version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <brightnessLevel>50</brightnessLevel>
          <contrastLevel>50</contrastLevel>
          <saturationLevel>50</saturationLevel>
        </Color>
        """

    /// The lower-case sharpness variant that 5.4.x–5.5.x sends.
    static let sharpnessLowerCase = """
        <Sharpness version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <sharpnessLevel>72</sharpnessLevel>
        </Sharpness>
        """

    static let wdr = """
        <WDR version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <mode>open</mode><WDRLevel>40</WDRLevel>
        </WDR>
        """

    static let ircut = """
        <IrcutFilter version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <IrcutFilterType>auto</IrcutFilterType>
          <nightToDayFilterLevel>4</nightToDayFilterLevel>
          <nightToDayFilterTime>5</nightToDayFilterTime>
        </IrcutFilter>
        """

    /// docs/spec-isapi.md §15.4, verbatim.
    static let storage = """
        <storage version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <hddList size="2">
            <hdd>
              <id>1</id>
              <hddName>hdd1</hddName>
              <hddPath>/</hddPath>
              <hddType>SATA</hddType>
              <status>ok</status>
              <capacity>3815447</capacity>
              <freeSpace>1258291</freeSpace>
              <property>RW</property>
              <group>1</group>
            </hdd>
            <hdd>
              <id>2</id>
              <hddName>sd1</hddName>
              <hddType>SD</hddType>
              <status>unformatted</status>
              <capacity>61035</capacity>
              <freeSpace>0</freeSpace>
              <property>RW</property>
            </hdd>
          </hddList>
          <nasList size="0"/>
          <workMode>group</workMode>
        </storage>
        """

    /// docs/spec-isapi.md §16.1, verbatim.
    static let twoWayAudioChannels = """
        <TwoWayAudioChannelList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <TwoWayAudioChannel version="2.0">
            <id>1</id>
            <enabled>true</enabled>
            <audioCompressionType>G.711ulaw</audioCompressionType>
            <audioInputType>MicIn</audioInputType>
            <noisereduce>true</noisereduce>
            <audioBitRate>64</audioBitRate>
            <audioSamplingRate>8</audioSamplingRate>
            <associateVideoInputs>
              <enabled>true</enabled>
              <videoInputChannelList><videoInputChannelID>1</videoInputChannelID></videoInputChannelList>
            </associateVideoInputs>
          </TwoWayAudioChannel>
        </TwoWayAudioChannelList>
        """

    /// docs/spec-isapi.md §16.1's capability form: the codec menu lives in an `opt` attribute.
    static let twoWayAudioCapabilities = """
        <TwoWayAudioChannel version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <id>1</id>
          <audioCompressionType opt="G.711ulaw,G.711alaw,G.722.1,AAC">G.711ulaw</audioCompressionType>
        </TwoWayAudioChannel>
        """

    /// docs/spec-isapi.md §14.7, verbatim.
    static let eventTriggers = """
        <EventTriggerList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <EventTrigger version="2.0">
            <id>VMD-1</id>
            <eventType>VMD</eventType>
            <eventDescription>Motion Detection</eventDescription>
            <videoInputChannelID>1</videoInputChannelID>
            <dynVideoInputChannelID>1</dynVideoInputChannelID>
            <EventTriggerNotificationList>
              <EventTriggerNotification>
                <id>beep</id>
                <notificationMethod>beep</notificationMethod>
                <notificationRecurrence>beginning</notificationRecurrence>
              </EventTriggerNotification>
              <EventTriggerNotification>
                <id>record</id>
                <notificationMethod>record</notificationMethod>
                <notificationRecurrence>beginning</notificationRecurrence>
              </EventTriggerNotification>
            </EventTriggerNotificationList>
          </EventTrigger>
          <EventTrigger version="2.0">
            <id>tamperdetection-1</id>
            <eventType>tamperdetection</eventType>
            <eventDescription>Tamper Detection</eventDescription>
            <videoInputChannelID>1</videoInputChannelID>
            <EventTriggerNotificationList/>
          </EventTrigger>
        </EventTriggerList>
        """

    /// docs/spec-isapi.md §14.8, verbatim.
    static let eventSchedule = """
        <EventSchedule version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <id>VMD-1</id>
          <TimeBlockList>
            <TimeBlock>
              <dayOfWeek>Monday</dayOfWeek>
              <TimeRange><beginTime>00:00:00</beginTime><endTime>24:00:00</endTime></TimeRange>
            </TimeBlock>
            <TimeBlock>
              <dayOfWeek>Tuesday</dayOfWeek>
              <TimeRange><beginTime>08:00:00</beginTime><endTime>18:00:00</endTime></TimeRange>
            </TimeBlock>
          </TimeBlockList>
        </EventSchedule>
        """

    static func document(_ xml: String) throws -> ISAPIDocument {
        try ISAPIDocument(parsing: Data(xml.utf8))
    }
}

// MARK: - MotionGridSuite

@Suite struct MotionGridSuite {

    @Test func motionGridRoundTripsThe22By18HexMap() throws {
        // 18 rows × ceil(22/4) = 6 hex digits = 108 characters.
        #expect(SettingsFixtures.sixRowGridMap.count == 108)
        let grid = try #require(MotionGrid(hex: SettingsFixtures.sixRowGridMap,
                                           rows: 18, columns: 22))
        #expect(grid.rows == 18)
        #expect(grid.columns == 22)
        // `fffffc` sets bits 0…21 of the row: every column on, both padding bits off.
        for column in 0..<22 { #expect(grid[0, column], "row 0 column \(column)") }
        for column in 0..<22 { #expect(!grid[6, column], "row 6 column \(column)") }
        #expect(grid.hexString == SettingsFixtures.sixRowGridMap)
    }

    @Test func motionGridWritesPaddingBitsAsZero() {
        // The last two bits of each 22-column row are padding and must be written as zero;
        // firmware has been observed to reject a map with dirty padding.
        var grid = MotionGrid(rows: 18, columns: 22)
        grid.fill(true)
        #expect(grid.isFullFrame)
        let hex = grid.hexString
        #expect(hex.count == 108)
        // Each row is `fffffc`: five full nibbles plus `1100`.
        #expect(hex == String(repeating: "fffffc", count: 18))
    }

    @Test func motionGridIsTopLeftOriginAndRowMajor() {
        // Unlike detection-region polygons, the grid does **not** flip Y: the first row is the
        // image's top row (docs/spec-isapi.md §14.9).
        var grid = MotionGrid(rows: 4, columns: 4)
        grid[0, 0] = true
        // Row 0, column 0 is the most significant bit of the first hex digit.
        #expect(grid.hexString == "8" + "0" + "0" + "0")
        grid[0, 0] = false
        grid[3, 3] = true
        #expect(grid.hexString == "0001")
    }

    @Test func motionGridHandlesAnOddColumnCount() {
        // 25 columns ⇒ ceil(25/4) = 7 hex digits per row.
        var grid = MotionGrid(rows: 2, columns: 25)
        grid.fill(true)
        let hex = grid.hexString
        #expect(hex.count == 14)
        // The last digit carries only column 24: bit 3 of the nibble.
        #expect(hex == "ffffff8ffffff8")
        let round = MotionGrid(hex: hex, rows: 2, columns: 25)
        #expect(round?.isFullFrame == true)
    }

    @Test func motionGridRejectsMalformedHex() {
        #expect(MotionGrid(hex: "zzzz", rows: 1, columns: 4) == nil)
        // Too short for the declared geometry.
        #expect(MotionGrid(hex: "ff", rows: 18, columns: 22) == nil)
        #expect(MotionGrid(hex: "", rows: 1, columns: 1) == nil)
        // Longer is accepted: some firmware pads to a fixed 64-row buffer.
        #expect(MotionGrid(hex: String(repeating: "f", count: 400), rows: 18, columns: 22) != nil)
    }

    @Test func motionGridSubscriptIgnoresOutOfRange() {
        var grid = MotionGrid(rows: 2, columns: 2)
        #expect(!grid[99, 99])
        grid[99, 99] = true         // must not trap
        #expect(!grid.isFullFrame)
        // Zero dimensions clamp up rather than producing an empty map, which the device reads as
        // "detect nothing".
        let clamped = MotionGrid(rows: 0, columns: 0)
        #expect(clamped.rows == 1)
        #expect(clamped.columns == 1)
    }

    @Test func motionGridRasterisesAPolygon() {
        var grid = MotionGrid(rows: 10, columns: 10)
        // The top-left quadrant, in normalised top-left-origin coordinates.
        grid.set(polygon: [NormalizedPoint(x: 0, y: 0), NormalizedPoint(x: 0.5, y: 0),
                           NormalizedPoint(x: 0.5, y: 0.5), NormalizedPoint(x: 0, y: 0.5)],
                 to: true)
        #expect(grid[0, 0])
        #expect(grid[4, 4])
        #expect(!grid[5, 5])
        #expect(!grid[9, 9])
        #expect(!grid[0, 9])
        // Fewer than three points sets nothing rather than guessing at a degenerate shape.
        var untouched = MotionGrid(rows: 4, columns: 4)
        untouched.set(polygon: [NormalizedPoint(x: 0, y: 0), NormalizedPoint(x: 1, y: 1)], to: true)
        #expect(!untouched.isFullFrame)
        #expect(untouched.cells.allSatisfy { !$0 })
    }
}

// MARK: - MotionDetectionConfigSuite

@Suite struct MotionDetectionConfigSuite {

    @Test func motionConfigDecodesTheFixture() throws {
        let config = MotionDetectionConfig(
            document: try SettingsFixtures.document(SettingsFixtures.motionDetection))
        #expect(config.enabled)
        #expect(config.sensitivity == 60)
        #expect(config.samplingInterval == 2)
        #expect(config.startTriggerMS == 500)
        #expect(config.endTriggerMS == 500)
        #expect(config.grid.rows == 18)
        #expect(config.grid.columns == 22)
        #expect(config.grid[0, 0])
        #expect(!config.grid[17, 0])
        #expect(config.originalNode != nil)
    }

    @Test func motionConfigDefaultsToThe22By18Geometry() throws {
        let xml = "<MotionDetection><enabled>false</enabled></MotionDetection>"
        let config = MotionDetectionConfig(document: try SettingsFixtures.document(xml))
        #expect(!config.enabled)
        #expect(config.grid.rows == 18)
        #expect(config.grid.columns == 22)
        #expect(config.grid.cells.allSatisfy { !$0 })
    }

    @Test func motionConfigPatchesTheDevicesOwnElement() throws {
        let config = MotionDetectionConfig(
            document: try SettingsFixtures.document(SettingsFixtures.motionDetection))
        var grid = MotionGrid(rows: 18, columns: 22)
        grid.fill(true)
        let patched = try #require(config.patchedNode(enabled: false, sensitivity: 80, grid: grid))
        let text = String(decoding: patched.serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<enabled>false</enabled>"))
        #expect(text.contains("<sensitivityLevel>80</sensitivityLevel>"))
        #expect(text.contains("<gridMap>\(String(repeating: "fffffc", count: 18))</gridMap>"))
        // Everything Vigil does not model round-trips: a hand-built minimal body is what the
        // validator rejects.
        #expect(text.contains("<enableHighlight>true</enableHighlight>"))
        #expect(text.contains("<regionType>grid</regionType>"))
        #expect(text.contains("<startTriggerTime>500</startTriggerTime>"))
    }

    @Test func motionConfigClampsSensitivityAndRefusesToInventABody() throws {
        let config = MotionDetectionConfig(
            document: try SettingsFixtures.document(SettingsFixtures.motionDetection))
        let clamped = try #require(config.patchedNode(enabled: nil, sensitivity: 500, grid: nil))
        let text = String(decoding: clamped.serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<sensitivityLevel>100</sensitivityLevel>"))

        var detached = config
        detached.originalNode = nil
        #expect(detached.patchedNode(enabled: true, sensitivity: nil, grid: nil) == nil)
    }
}

// MARK: - ImageSettingsSuite

@Suite struct ImageSettingsSuite {

    @Test func imageControlResourceNamesMatchTheWire() {
        // The capitalisation is the device's, not Swift's.
        #expect(ISAPIResource.image(ChannelID(1), .color) == "/Image/channels/1/color")
        #expect(ISAPIResource.image(ChannelID(1), .wdr) == "/Image/channels/1/WDR")
        #expect(ISAPIResource.image(ChannelID(1), .blc) == "/Image/channels/1/BLC")
        #expect(ISAPIResource.image(ChannelID(1), .hlc) == "/Image/channels/1/HLC")
        #expect(ISAPIResource.image(ChannelID(1), .ircut) == "/Image/channels/1/ircutFilter")
        #expect(ISAPIResource.image(ChannelID(2), .flip) == "/Image/channels/2/imageFlip")
        #expect(ISAPIResource.image(ChannelID(2), .powerLine)
                == "/Image/channels/2/powerLineFrequency")
        #expect(ISAPIResource.imageDefaults(ChannelID(1))
                == "/Image/channels/1/defaultConfiguration")
    }

    @Test func imageSettingsAbsorbTheColorDocument() throws {
        var settings = ImageSettings()
        settings.absorb(.color, document: try SettingsFixtures.document(SettingsFixtures.color))
        #expect(settings.brightness == 50)
        #expect(settings.contrast == 50)
        #expect(settings.saturation == 50)
        #expect(settings.available == [.color])
    }

    @Test func imageSettingsReadSharpnessUnderBothCasings() throws {
        var lower = ImageSettings()
        lower.absorb(.sharpness,
                     document: try SettingsFixtures.document(SettingsFixtures.sharpnessLowerCase))
        #expect(lower.sharpness == 72)
        var upper = ImageSettings()
        upper.absorb(.sharpness, document: try SettingsFixtures.document(
            "<Sharpness><SharpnessLevel>33</SharpnessLevel></Sharpness>"))
        #expect(upper.sharpness == 33)
    }

    @Test func imageSettingsRecordAControlEvenWithNoModelledValue() throws {
        // The device has the control; hiding the slider because a field was named differently
        // would be worse than showing it with the device's own default.
        var settings = ImageSettings()
        settings.absorb(.gamma, document: try SettingsFixtures.document(
            "<Gamma><enabled>true</enabled><gammaLevel>50</gammaLevel></Gamma>"))
        #expect(settings.available.contains(.gamma))
        settings.absorb(.blc, document: try SettingsFixtures.document("<BLC/>"))
        #expect(settings.available.contains(.blc))
    }

    @Test func wdrSettingReadsModeAndLevel() throws {
        let setting = WDRSetting(document: try SettingsFixtures.document(SettingsFixtures.wdr))
        #expect(setting.mode == .open)
        #expect(setting.level == 40)
        #expect(WDRSetting(document: try SettingsFixtures.document(
            "<WDR><mode>close</mode></WDR>")).mode == .close)
        #expect(WDRSetting(document: try SettingsFixtures.document(
            "<WDR><mode>auto</mode></WDR>")).mode == .auto)
        // Some firmware writes `<enabled>` instead of `<mode>`.
        #expect(WDRSetting(document: try SettingsFixtures.document(
            "<WDR><enabled>true</enabled></WDR>")).mode == .open)
    }

    @Test func irCutSettingReadsTypeAndThresholds() throws {
        let setting = IRCutSetting(document: try SettingsFixtures.document(SettingsFixtures.ircut))
        #expect(setting.mode == .auto)
        #expect(setting.nightToDayLevel == 4)
        #expect(setting.nightToDaySeconds == 5)
        #expect(IRCutSetting(document: try SettingsFixtures.document(
            "<IrcutFilter><IrcutFilterType>night</IrcutFilterType></IrcutFilter>")).mode == .night)
        #expect(IRCutSetting(document: try SettingsFixtures.document(
            "<IrcutFilter><IrcutFilterType>schedule</IrcutFilterType></IrcutFilter>")).mode
                == .schedule)
    }

    @Test func imageColorPatchEchoesTheWholeElement() throws {
        let node = try SettingsFixtures.document(SettingsFixtures.color).root
        let patched = ImageWrite.color(node, brightness: 62, contrast: nil, saturation: 55)
        let text = String(decoding: patched.serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<brightnessLevel>62</brightnessLevel>"))
        #expect(text.contains("<saturationLevel>55</saturationLevel>"))
        // Untouched, and still present — some 5.4.x builds reject a `<Color>` without every
        // sibling.
        #expect(text.contains("<contrastLevel>50</contrastLevel>"))
        #expect(text.contains("version=\"2.0\""))
        // KNOWN GAP, reported: `ISAPIDocument`'s parser discards every `xmlns*` attribute
        // (`Sources/VigilISAPI/XML/ISAPIDocument.swift`, `where !name.hasPrefix("xmlns")`), so a
        // read-modify-write body cannot echo the namespace that docs/spec-isapi.md §8 and §17.2
        // say some 5.4.x builds require. This assertion pins the current behaviour so the fix is
        // visible as a failing test rather than as silence.
        #expect(!text.contains("xmlns"),
                "xmlns is dropped on parse today; when that is fixed, assert it round-trips")
    }

    @Test func imageColorPatchClampsToZeroToHundred() throws {
        let node = try SettingsFixtures.document(SettingsFixtures.color).root
        let text = String(decoding: ImageWrite.color(node, brightness: 500, contrast: -20,
                                                     saturation: nil)
                            .serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<brightnessLevel>100</brightnessLevel>"))
        #expect(text.contains("<contrastLevel>0</contrastLevel>"))
    }

    @Test func imageSharpnessPatchWritesWhicheverCasingTheDeviceUsed() throws {
        let lower = try SettingsFixtures.document(SettingsFixtures.sharpnessLowerCase).root
        let lowerText = String(decoding: ImageWrite.sharpness(lower, level: 80)
                                .serialized(declaration: false), as: UTF8.self)
        #expect(lowerText.contains("<sharpnessLevel>80</sharpnessLevel>"))
        #expect(!lowerText.contains("<SharpnessLevel>"))

        let upper = try SettingsFixtures.document(
            "<Sharpness><SharpnessLevel>10</SharpnessLevel></Sharpness>").root
        let upperText = String(decoding: ImageWrite.sharpness(upper, level: 80)
                                .serialized(declaration: false), as: UTF8.self)
        #expect(upperText.contains("<SharpnessLevel>80</SharpnessLevel>"))
    }

    @Test func imageWDRPatchWritesModeAndLevel() throws {
        let node = try SettingsFixtures.document(SettingsFixtures.wdr).root
        let text = String(decoding: ImageWrite.wdr(node, WDRSetting(mode: .close, level: 0))
                            .serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<mode>close</mode>"))
        #expect(text.contains("<WDRLevel>0</WDRLevel>"))
    }

    @Test func imageIRCutPatchRefusesTheModesVigilDoesNotModel() throws {
        let node = try SettingsFixtures.document(SettingsFixtures.ircut).root
        let written = try #require(ImageWrite.irCut(node, IRCutSetting(mode: .night,
                                                                      nightToDayLevel: 9,
                                                                      nightToDaySeconds: 1)))
        let text = String(decoding: written.serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<IrcutFilterType>night</IrcutFilterType>"))
        #expect(text.contains("<nightToDayFilterLevel>7</nightToDayFilterLevel>"))
        #expect(text.contains("<nightToDayFilterTime>3</nightToDayFilterTime>"))
        // `schedule` and `triggeredByAlarmIn` carry configuration Vigil does not model, so writing
        // the mode alone would silently discard it.
        #expect(ImageWrite.irCut(node, IRCutSetting(mode: .schedule, nightToDayLevel: nil,
                                                    nightToDaySeconds: nil)) == nil)
        #expect(ImageWrite.irCut(node, IRCutSetting(mode: .triggeredByAlarmIn,
                                                    nightToDayLevel: nil,
                                                    nightToDaySeconds: nil)) == nil)
    }
}

// MARK: - SnapshotSuite

@Suite struct SnapshotSuite {

    @Test func snapshotRequestAsksTheSubstreamForAThumbnail() {
        let request = SnapshotWireRequest.thumbnail(channel: ChannelID(7))
        // The substream is 5–10× faster because the device does not have to scale.
        #expect(request.channel.value == 702)
        #expect(request.resource == "/Streaming/channels/702/picture")
        #expect(request.query.map(\.name) == ["videoResolutionWidth", "videoResolutionHeight"])
        #expect(request.query.map(\.value) == ["160", "90"])
    }

    @Test func snapshotRequestClampsAndPairsItsDimensions() {
        var request = SnapshotWireRequest(channel: StreamingChannelID(channel: .first,
                                                                     quality: .sub),
                                          width: 10, height: 99_999)
        #expect(request.query.map(\.value) == ["64", "4320"])
        // Both dimensions or neither: a device given only a width answers `badParameters` on some
        // firmware and ignores it on others.
        request.height = nil
        #expect(request.query.isEmpty)
    }

    @Test func snapshotRequestDropsTheQueryAfterA403() {
        // `snapshotIgnoresResolutionQuery`: retry once with no query, then remember.
        let request = SnapshotWireRequest.thumbnail(channel: .first)
        #expect(!request.query.isEmpty)
        #expect(request.withoutResolutionQuery.query.isEmpty)
        #expect(request.withoutResolutionQuery.resource == request.resource)
    }

    @Test func snapshotSniffsTheSOIMarkerRatherThanTrustingTheHeader() throws {
        // Some 5.2.x devices answer `Content-Type: text/html` with a JPEG body, so the bytes are
        // the only trustworthy evidence.
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        jpeg.append(Data(repeating: 0x41, count: 32))
        #expect(SnapshotPayload.hasJPEGMarker(jpeg))
        #expect(try SnapshotPayload.validate(jpeg, contentType: "text/html") == jpeg)

        let html = Data("<html><body>login</body></html>".utf8)
        #expect(!SnapshotPayload.hasJPEGMarker(html))
        #expect(throws: ISAPIError.unexpectedContentType(expected: "image/jpeg",
                                                        got: "image/jpeg")) {
            _ = try SnapshotPayload.validate(html, contentType: "image/jpeg")
        }
    }

    @Test func snapshotTreatsAnEmptyBodyAsAnOfflineChannel() {
        // An empty 200 is an NVR reporting the channel offline, not a zero-byte image.
        #expect(throws: ISAPIError.device(statusCode: 4, sub: "ipcOffline")) {
            _ = try SnapshotPayload.validate(Data(), contentType: "image/jpeg")
        }
    }

    @Test func snapshotMarkerCheckHandlesShortAndSlicedBodies() {
        #expect(!SnapshotPayload.hasJPEGMarker(Data([0xFF, 0xD8])))
        #expect(!SnapshotPayload.hasJPEGMarker(Data()))
        // A `Data` slice does not start at index zero; the check must still work.
        let padded = Data([0x00, 0x00, 0xFF, 0xD8, 0xFF, 0xE0])
        #expect(SnapshotPayload.hasJPEGMarker(padded.dropFirst(2)))
        #expect(!SnapshotPayload.hasJPEGMarker(padded.dropFirst(1)))
    }
}

// MARK: - StorageSuite

@Suite struct StorageSuite {

    @Test func storageDecodesVolumesInDecimalMegabytes() throws {
        let info = StorageInfo(document: try SettingsFixtures.document(SettingsFixtures.storage))
        #expect(info.volumes.count == 2)
        #expect(info.workMode == "group")

        let hdd = info.volumes[0]
        #expect(hdd.id == 1)
        #expect(hdd.name == "hdd1")
        #expect(hdd.kind == .sata)
        #expect(hdd.status == .ok)
        #expect(hdd.capacityMB == 3_815_447)
        #expect(hdd.freeSpaceMB == 1_258_291)
        #expect(!hdd.isReadOnly)
        // Decimal MB, so the figures match the camera's own web UI.
        #expect(hdd.capacityBytes == 3_815_447_000_000)
        #expect(abs(hdd.usedFraction - 0.67) < 0.01)

        let sd = info.volumes[1]
        #expect(sd.kind == .sd)
        #expect(sd.status == .unformatted)
        #expect(sd.usedFraction == 1)
    }

    @Test func storageSurfacesAVolumeThatNeedsAttention() throws {
        let info = StorageInfo(document: try SettingsFixtures.document(SettingsFixtures.storage))
        #expect(info.needsAttention)
        #expect(info.totalCapacityMB == 3_876_482)
        #expect(info.totalFreeMB == 1_258_291)

        let healthy = StorageInfo(document: try SettingsFixtures.document("""
            <storage><hddList size="1"><hdd><id>1</id><hddType>SATA</hddType>
            <status>sleeping</status><capacity>1000</capacity><freeSpace>500</freeSpace>
            </hdd></hddList><workMode>quota</workMode></storage>
            """))
        // A sleeping or idle disk is healthy.
        #expect(!healthy.needsAttention)
        #expect(healthy.workMode == "quota")
    }

    @Test func storageAcceptsTheMisspelledStatus() throws {
        // `unformated` really is what several firmwares send.
        let info = StorageInfo(document: try SettingsFixtures.document("""
            <storage><hddList><hdd><id>1</id><status>unformated</status></hdd></hddList></storage>
            """))
        #expect(info.volumes.first?.status == .unformatted)
    }

    @Test func storageReadsNASEntries() throws {
        let info = StorageInfo(document: try SettingsFixtures.document("""
            <storage><hddList size="0"/><nasList size="1"><nas><id>5</id>
            <addressingFormatType>ipaddress</addressingFormatType><ipAddress>10.0.0.9</ipAddress>
            <mountType>NFS</mountType><path>/export/vigil</path><status>ok</status>
            <capacity>8000000</capacity><freeSpace>4000000</freeSpace><property>RO</property>
            </nas></nasList><workMode>group</workMode></storage>
            """))
        let nas = try #require(info.volumes.first)
        #expect(nas.kind == .nas(mount: "NFS"))
        #expect(nas.name == "/export/vigil")
        #expect(nas.isReadOnly)
    }

    @Test func storageQuotaListDecodes() throws {
        let quotas = StorageQuota.list(document: try SettingsFixtures.document("""
            <QuotaList><Quota><id>1</id><type>record</type><totalSpace>100000</totalSpace>
            <usedSpace>25000</usedSpace></Quota>
            <Quota><id>2</id><type>picture</type><totalSpace>1000</totalSpace>
            <usedSpace>10</usedSpace></Quota></QuotaList>
            """))
        #expect(quotas.count == 2)
        #expect(quotas[0].kind == "record")
        #expect(quotas[1].totalSpaceMB == 1000)
    }
}

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

// MARK: - EventTriggerSuite

@Suite struct EventTriggerSuite {

    @Test func eventTriggersDecodeTheFixture() throws {
        let triggers = EventTrigger.list(
            document: try SettingsFixtures.document(SettingsFixtures.eventTriggers))
        #expect(triggers.count == 2)
        #expect(triggers[0].id == "VMD-1")
        #expect(triggers[0].kind == .motion)
        #expect(triggers[0].channel == ChannelID(1))
        #expect(triggers[0].notificationMethods == ["beep", "record"])
        #expect(triggers[0].isConfigured)
        // An empty method list is "motion detection is enabled but wired to nothing" — the hint
        // that saves a support call.
        #expect(triggers[1].kind == .tamper)
        #expect(!triggers[1].isConfigured)
    }

    @Test func eventTriggerPrefersTheDynamicChannel() throws {
        let xml = """
            <EventTriggerList><EventTrigger><id>VMD-7</id><eventType>VMD</eventType>
            <videoInputChannelID>1</videoInputChannelID>
            <dynVideoInputChannelID>7</dynVideoInputChannelID></EventTrigger></EventTriggerList>
            """
        let triggers = EventTrigger.list(document: try SettingsFixtures.document(xml))
        #expect(triggers.first?.channel == ChannelID(7))
    }

    @Test func eventScheduleDecodesTheFixture() throws {
        let schedule = EventSchedule(
            document: try SettingsFixtures.document(SettingsFixtures.eventSchedule))
        #expect(schedule.triggerID == "VMD-1")
        #expect(schedule.blocks.count == 2)
        #expect(schedule.blocks[0].weekday == 1)
        #expect(schedule.blocks[0].startSeconds == 0)
        // `24:00:00` is legal and means end-of-day.
        #expect(schedule.blocks[0].endSeconds == 86_400)
        #expect(schedule.blocks[1].weekday == 2)
        #expect(schedule.blocks[1].startSeconds == 28_800)
        #expect(schedule.blocks[1].endSeconds == 64_800)
        #expect(!schedule.isAlwaysArmed)
    }

    @Test func eventScheduleDetectsAlwaysArmed() throws {
        var blocks: [EventSchedule.Block] = []
        for weekday in 1...7 {
            blocks.append(EventSchedule.Block(weekday: weekday, startSeconds: 0,
                                              endSeconds: 86_400))
        }
        #expect(EventSchedule(triggerID: "VMD-1", blocks: blocks).isAlwaysArmed)
    }

    @Test func eventScheduleParsesTimesAndWeekdays() {
        #expect(EventSchedule.seconds("00:00:00") == 0)
        #expect(EventSchedule.seconds("24:00:00") == 86_400)
        #expect(EventSchedule.seconds("08:30") == 30_600)
        #expect(EventSchedule.seconds("25:00:00") == nil)
        #expect(EventSchedule.seconds("08:70:00") == nil)
        #expect(EventSchedule.seconds(nil) == nil)
        #expect(EventSchedule.weekday("Monday") == 1)
        #expect(EventSchedule.weekday("sunday") == 7)
        #expect(EventSchedule.weekday("3") == 3)
        #expect(EventSchedule.weekday("Someday") == nil)
    }
}

// MARK: - ResourceTemplateSuite

@Suite struct ResourceTemplateSuite {

    @Test func resourceTemplateCollapsesOnlyNumericComponents() {
        // One 403 on channel 3 must suppress the pointless request on channels 1…64, and a literal
        // such as `position3D` must survive.
        #expect(ISAPIResource.template(of: "/PTZCtrl/channels/3/capabilities")
                == "/PTZCtrl/channels/{n}/capabilities")
        #expect(ISAPIResource.template(of: "/PTZCtrl/channels/1/position3D")
                == "/PTZCtrl/channels/{n}/position3D")
        #expect(ISAPIResource.template(of: "/Streaming/channels/3202/picture")
                == "/Streaming/channels/{n}/picture")
        #expect(ISAPIResource.template(of: "/PTZCtrl/channels/1/presets/94/goto")
                == "/PTZCtrl/channels/{n}/presets/{n}/goto")
        #expect(ISAPIResource.template(of: "/System/deviceInfo") == "/System/deviceInfo")
        #expect(ISAPIResource.template(of: "/ContentMgmt/search") == "/ContentMgmt/search")
    }

    @Test func resourcePathsMatchTheEndpointIndex() {
        // Spot-checks against docs/spec-isapi.md Appendix A.
        #expect(ISAPIResource.deviceInfo == "/System/deviceInfo")
        #expect(ISAPIResource.userCheck == "/Security/userCheck")
        #expect(ISAPIResource.alertStream == "/Event/notification/alertStream")
        #expect(ISAPIResource.contentSearch == "/ContentMgmt/search")
        #expect(ISAPIResource.inputProxyStatusList
                == "/ContentMgmt/InputProxy/channels/status")
        #expect(ISAPIResource.inputProxyStatus(ChannelID(7))
                == "/ContentMgmt/InputProxy/channels/7/status")
        #expect(ISAPIResource.streamingChannel(StreamingChannelID(channel: ChannelID(12),
                                                                 quality: .main))
                == "/Streaming/channels/1201")
        #expect(ISAPIResource.streamingChannelSingleDigit(ChannelID(1)) == "/Streaming/channels/1")
        #expect(ISAPIResource.motionDetection(ChannelID(1))
                == "/System/Video/inputs/channels/1/motionDetection")
        #expect(ISAPIResource.twoWayAudioData(1) == "/System/TwoWayAudio/channels/1/audioData")
        #expect(ISAPIResource.dailyDistributionTracks
                == "/ContentMgmt/record/tracks/dailyDistribution")
        #expect(ISAPIResource.dailyDistributionSearch == "/ContentMgmt/search/dailyDistribution")
    }
}
