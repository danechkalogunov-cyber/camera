//
//  PTZTests.swift
//  VigilISAPITests
//
//  The PTZ bodies asserted byte-for-byte against docs/spec-isapi.md §13, the 0…255 lower-left
//  `position3D` mapping including the Y flip, the capability documents under both spellings of the
//  root element, and the controller's keep-alive and triple zero-stop.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - Fixtures

enum PTZFixtures {

    /// The declaration `XMLBuilder` always emits (docs/spec-isapi.md §8): some 5.2.x firmwares
    /// reject a body without it with `invalidXMLFormat`.
    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"

    /// docs/spec-isapi.md §13.9, with the `PTZChanelCap` root — Hikvision's own typo, and the
    /// spelling most firmware uses.
    static let capabilities = """
        <PTZChanelCap version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <AbsolutePanTiltPositionSpace>
            <XRange><min>0</min><max>3600</max></XRange>
            <YRange><min>-900</min><max>900</max></YRange>
          </AbsolutePanTiltPositionSpace>
          <AbsoluteZoomPositionSpace><ZRange><min>1</min><max>1000</max></ZRange></AbsoluteZoomPositionSpace>
          <RelativePanTiltSpace><XRange><min>-255</min><max>255</max></XRange>
            <YRange><min>-255</min><max>255</max></YRange></RelativePanTiltSpace>
          <ContinuousPanTiltSpace><XRange><min>-100</min><max>100</max></XRange>
            <YRange><min>-100</min><max>100</max></YRange></ContinuousPanTiltSpace>
          <ContinuousZoomSpace><ZRange><min>-100</min><max>100</max></ZRange></ContinuousZoomSpace>
          <isSupportPosition3D>true</isSupportPosition3D>
          <isSupportPreset>true</isSupportPreset>
          <maxPresetNum>300</maxPresetNum>
          <isSupportPatrol>true</isSupportPatrol>
          <maxPatrolNum>8</maxPatrolNum>
          <isSupportPatternn>true</isSupportPatternn>
          <isSupportFocus>true</isSupportFocus>
          <isSupportIris>true</isSupportIris>
          <isSupportAux>true</isSupportAux>
        </PTZChanelCap>
        """

    /// The same document under the correctly-spelled root, which a few firmwares use.
    static var capabilitiesCorrectSpelling: String {
        capabilities
            .replacingOccurrences(of: "<PTZChanelCap", with: "<PTZChannelCap")
            .replacingOccurrences(of: "</PTZChanelCap>", with: "</PTZChannelCap>")
    }

    /// docs/spec-isapi.md §13.6.
    static let presets = """
        <PTZPresetList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <PTZPreset version="2.0">
            <enabled>true</enabled>
            <id>1</id>
            <presetName>Gate</presetName>
          </PTZPreset>
          <PTZPreset version="2.0">
            <enabled>true</enabled>
            <id>2</id>
            <presetName>Driveway</presetName>
          </PTZPreset>
          <PTZPreset version="2.0">
            <enabled>true</enabled>
            <id>94</id>
            <presetName>Remote reboot</presetName>
          </PTZPreset>
        </PTZPresetList>
        """

    /// docs/spec-isapi.md §13.7, with the lower-case `<presetID>` variant on the second stop.
    static let patrols = """
        <PTZPatrolList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <PTZPatrol version="2.0">
            <id>1</id>
            <enabled>true</enabled>
            <patrolName>Perimeter</patrolName>
            <PatrolSequenceList>
              <PatrolSequence>
                <id>1</id><PresetID>1</PresetID><dwellTime>10</dwellTime><speed>30</speed>
              </PatrolSequence>
              <PatrolSequence>
                <id>2</id><presetID>2</presetID><DwellTime>15</DwellTime><speed>30</speed>
              </PatrolSequence>
            </PatrolSequenceList>
          </PTZPatrol>
        </PTZPatrolList>
        """

    /// docs/spec-isapi.md §13.8.
    static let status = """
        <PTZStatus version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <AbsoluteHigh>
            <elevation>-150</elevation>
            <azimuth>1350</azimuth>
            <absoluteZoom>40</absoluteZoom>
          </AbsoluteHigh>
        </PTZStatus>
        """

    static func document(_ xml: String) throws -> ISAPIDocument {
        try ISAPIDocument(parsing: Data(xml.utf8))
    }
}

// MARK: - PTZBodySuite

@Suite struct PTZBodySuite {

    @Test func ptzContinuousBodyMatchesTheSpecByteForByte() {
        // docs/spec-isapi.md §13.1's body, with the declaration §8 requires.
        let velocity = PTZVelocity(pan: 60, tilt: -40, zoom: 0)
        #expect(velocity.body.stringValue == PTZFixtures.declaration
                + "<PTZData><pan>60</pan><tilt>-40</tilt><zoom>0</zoom></PTZData>")
    }

    @Test func ptzStopBodyCarriesAllThreeAxesAsZero() {
        // All three elements must be present even when zero, in pan/tilt/zoom order: 5.2.x
        // validators reject anything else.
        #expect(PTZVelocity.stopped.body.stringValue == PTZFixtures.declaration
                + "<PTZData><pan>0</pan><tilt>0</tilt><zoom>0</zoom></PTZData>")
        #expect(PTZVelocity.stopped.isStopped)
    }

    @Test func ptzMomentaryBodyMatchesTheSpec() {
        // docs/spec-isapi.md §13.2's body.
        let velocity = PTZVelocity(pan: 40, tilt: 0, zoom: 0)
        #expect(velocity.momentaryBody(durationMilliseconds: 300).stringValue
                == PTZFixtures.declaration
                + "<PTZData><pan>40</pan><tilt>0</tilt><zoom>0</zoom>"
                + "<Momentary><duration>300</duration></Momentary></PTZData>")
    }

    @Test func ptzMomentaryClampsItsDuration() {
        let velocity = PTZVelocity(pan: 10, tilt: 0, zoom: 0)
        #expect(velocity.momentaryBody(durationMilliseconds: 99_999).stringValue
                    .contains("<duration>60000</duration>"))
        #expect(velocity.momentaryBody(durationMilliseconds: -5).stringValue
                    .contains("<duration>0</duration>"))
    }

    @Test func ptzAbsoluteBodyMatchesTheSpec() throws {
        // docs/spec-isapi.md §13.3's body: elevation, azimuth, absoluteZoom, in that order.
        let capabilities = PTZCapabilitiesWire(
            document: try PTZFixtures.document(PTZFixtures.capabilities))
        let position = PTZAbsolutePosition(wireAzimuth: 1350, wireElevation: -150, wireZoom: 40)
        #expect(position.body(clampedTo: capabilities).stringValue == PTZFixtures.declaration
                + "<PTZData><AbsoluteHigh><elevation>-150</elevation>"
                + "<azimuth>1350</azimuth><absoluteZoom>40</absoluteZoom></AbsoluteHigh></PTZData>")
        #expect(position.azimuthDegrees == 135)
        #expect(position.elevationDegrees == -15)
    }

    @Test func ptzAbsoluteClampsToTheAdvertisedRanges() throws {
        // Out-of-range values are clamped client-side: firmware has been seen to answer
        // `deviceError` and then ignore the *next* valid command too.
        let capabilities = PTZCapabilitiesWire(
            document: try PTZFixtures.document(PTZFixtures.capabilities))
        let position = PTZAbsolutePosition(azimuthDegrees: 400, elevationDegrees: -200,
                                          zoomSteps: 5000)
        let text = position.body(clampedTo: capabilities).stringValue
        #expect(text.contains("<azimuth>3600</azimuth>"))
        #expect(text.contains("<elevation>-900</elevation>"))
        #expect(text.contains("<absoluteZoom>1000</absoluteZoom>"))
    }

    @Test func ptzRelativeBodyMatchesTheSpec() {
        // docs/spec-isapi.md §13.4's body.
        let move = PTZRelativeMove(positionX: 120, positionY: -60, relativeZoom: 0)
        #expect(move.body.stringValue == PTZFixtures.declaration
                + "<PTZData><Relative><positionX>120</positionX>"
                + "<positionY>-60</positionY><relativeZoom>0</relativeZoom></Relative></PTZData>")
    }

    @Test func ptzRelativeClampsToPlusMinus255() {
        let move = PTZRelativeMove(positionX: 999, positionY: -999, relativeZoom: 300)
        #expect(move.positionX == 255)
        #expect(move.positionY == -255)
        #expect(move.relativeZoom == 255)
    }

    @Test func ptzPosition3DBodyMatchesTheSpec() {
        // docs/spec-isapi.md §13.5's body.
        let box = PTZ3D(startX: 62, startY: 180, endX: 190, endY: 60)
        #expect(box.body.stringValue == PTZFixtures.declaration
                + "<PTZData><Position3D>"
                + "<StartPoint><positionX>62</positionX><positionY>180</positionY></StartPoint>"
                + "<EndPoint><positionX>190</positionX><positionY>60</positionY></EndPoint>"
                + "</Position3D></PTZData>")
    }

    @Test func ptzVelocityClampsEveryAxis() {
        let velocity = PTZVelocity(pan: 400, tilt: -400, zoom: 101)
        #expect(velocity.pan == 100)
        #expect(velocity.tilt == -100)
        #expect(velocity.zoom == 100)
    }

    @Test func ptzVelocityScalesBySpeedWithoutNormalisingDiagonals() {
        // Hikvision treats pan and tilt speed independently, and a diagonal drag is expected to
        // move at full speed on both axes — so no unit-vector normalisation.
        let full = PTZVelocity.from(directionX: 1, directionY: 1, zoom: 0, speed: 10)
        #expect(full.pan == 100)
        #expect(full.tilt == 100)
        let half = PTZVelocity.from(directionX: -1, directionY: 0, zoom: 0, speed: 5)
        #expect(half.pan == -50)
        #expect(half.tilt == 0)
        // The speed setting itself is clamped to 1…10.
        #expect(PTZVelocity.from(directionX: 1, directionY: 0, zoom: 0, speed: 99).pan == 100)
        #expect(PTZVelocity.from(directionX: 1, directionY: 0, zoom: 0, speed: 0).pan == 10)
    }

    @Test func ptzLensAndAuxBodiesMatchTheSpec() {
        // docs/spec-isapi.md §13.8's three bodies.
        #expect(PTZLensCommand.focus(50).stringValue == PTZFixtures.declaration
                + "<FocusData><focus>50</focus></FocusData>")
        #expect(PTZLensCommand.iris(50).stringValue == PTZFixtures.declaration
                + "<IrisData><iris>50</iris></IrisData>")
        #expect(PTZAuxiliary.light.body(id: 1, on: true).stringValue == PTZFixtures.declaration
                + "<PTZAux><id>1</id><type>LIGHT</type><status>on</status></PTZAux>")
        #expect(PTZAuxiliary.wiper.body(id: 2, on: false).stringValue
                    .contains("<type>WIPER</type><status>off</status>"))
        #expect(PTZLensCommand.focus(-500).stringValue.contains("<focus>-100</focus>"))
    }

    @Test func ptzPresetWriteBodyMatchesTheSpec() {
        // docs/spec-isapi.md §13.6's set body.
        #expect(PTZPreset.writeBody(id: 3, name: "Back gate").stringValue
                == PTZFixtures.declaration
                + "<PTZPreset><id>3</id><presetName>Back gate</presetName></PTZPreset>")
    }

    @Test func ptzPresetNameTruncatesOnACharacterBoundary() {
        // 30 bytes, never a split multi-byte character: a half character produces
        // `invalidXMLContent`, not a shorter name.
        let long = String(repeating: "é", count: 40)          // 2 bytes each
        let truncated = PTZPreset.truncate(long, toUTF8Bytes: 30)
        #expect(truncated.utf8.count == 30)
        #expect(truncated.count == 15)
        #expect(PTZPreset.truncate("Gate", toUTF8Bytes: 30) == "Gate")
        // A character that would straddle the limit is dropped whole.
        let emoji = String(repeating: "🎥", count: 10)         // 4 bytes each
        #expect(PTZPreset.truncate(emoji, toUTF8Bytes: 30).utf8.count == 28)
    }

    @Test func ptzPresetBodyEscapesAName() {
        #expect(PTZPreset.writeBody(id: 4, name: "Gate & <yard>").stringValue
                    .contains("<presetName>Gate &amp; &lt;yard&gt;</presetName>"))
    }
}

// MARK: - PTZ3DMappingSuite

@Suite struct PTZ3DMappingSuite {

    @Test func ptz3DMapsAViewRectIntoLowerLeftOriginWireSpace() {
        // A 256×256 view makes the arithmetic checkable by eye: view Y 0 is the *top*, which is
        // 255 in the device's lower-left space.
        let box = PTZ3D.box(rectX: 0, rectY: 0, rectWidth: 128, rectHeight: 128,
                            viewWidth: 256, viewHeight: 256, originIsTopLeft: false)
        #expect(box.startX == 0)
        #expect(box.startY == 255)      // top edge of the view ⇒ top of the image
        #expect(box.endX == 128)
        #expect(box.endY == 128)        // halfway down ⇒ halfway up
    }

    @Test func ptz3DFlipsYOnlyForTheLowerLeftConvention() {
        // The same rectangle under both conventions differs in Y and only in Y.
        let lowerLeft = PTZ3D.box(rectX: 64, rectY: 32, rectWidth: 128, rectHeight: 64,
                                  viewWidth: 256, viewHeight: 256, originIsTopLeft: false)
        let topLeft = PTZ3D.box(rectX: 64, rectY: 32, rectWidth: 128, rectHeight: 64,
                                viewWidth: 256, viewHeight: 256, originIsTopLeft: true)
        #expect(lowerLeft.startX == topLeft.startX)
        #expect(lowerLeft.endX == topLeft.endX)
        #expect(lowerLeft.startY == 223)        // 255 - 32
        #expect(topLeft.startY == 32)
        #expect(lowerLeft.endY == 159)          // 255 - 96
        #expect(topLeft.endY == 96)
        // In the device's space the start point is above the end point, exactly as the §13.5
        // sample shows (start 180, end 60).
        #expect(lowerLeft.startY > lowerLeft.endY)
        #expect(topLeft.startY < topLeft.endY)
    }

    @Test func ptz3DNormalisesADragDrawnInAnyDirection() {
        // Drag direction is irrelevant to the device; only the rectangle matters. A drag up-left
        // and a drag down-right over the same area must produce the same body.
        let downRight = PTZ3D.box(rectX: 40, rectY: 40, rectWidth: 80, rectHeight: 60,
                                  viewWidth: 320, viewHeight: 240, originIsTopLeft: false)
        let upLeft = PTZ3D.box(rectX: 120, rectY: 100, rectWidth: -80, rectHeight: -60,
                               viewWidth: 320, viewHeight: 240, originIsTopLeft: false)
        #expect(downRight == upLeft)
    }

    @Test func ptz3DPointIsAClickToCentre() {
        let point = PTZ3D.point(x: 160, y: 120, viewWidth: 320, viewHeight: 240,
                               originIsTopLeft: false)
        #expect(point.isPoint)
        #expect(point.startX == 128)
        #expect(point.startY == 128)      // the exact centre maps to the middle of 0…255
    }

    @Test func ptz3DClampsAndSurvivesADegenerateView() {
        // A drag that ran outside the content rect must still produce a legal body.
        let outside = PTZ3D.box(rectX: -50, rectY: -50, rectWidth: 1000, rectHeight: 1000,
                                viewWidth: 320, viewHeight: 240, originIsTopLeft: false)
        #expect(outside.startX == 0)
        #expect(outside.startY == 255)
        #expect(outside.endX == 255)
        #expect(outside.endY == 0)
        // A zero-sized view centres rather than dividing by zero.
        let degenerate = PTZ3D.box(rectX: 0, rectY: 0, rectWidth: 10, rectHeight: 10,
                                   viewWidth: 0, viewHeight: 0, originIsTopLeft: false)
        #expect(degenerate.isPoint)
        #expect(degenerate.startX == 128)
    }

    @Test func ptz3DMinimumDragIsTwelvePoints() {
        #expect(PTZ3D.minimumDragPoints == 12)
    }
}

// MARK: - PTZModelSuite

@Suite struct PTZModelSuite {

    @Test func ptzCapabilitiesParseUnderBothSpellingsOfTheRoot() throws {
        for xml in [PTZFixtures.capabilities, PTZFixtures.capabilitiesCorrectSpelling] {
            let caps = PTZCapabilitiesWire(document: try PTZFixtures.document(xml))
            #expect(!caps.isAbsent)
            #expect(caps.supportsPosition3D)
            #expect(caps.supportsPresets)
            #expect(caps.maxPresets == 300)
            #expect(caps.supportsPatrols)
            #expect(caps.maxPatrols == 8)
            #expect(caps.supportsFocus)
            #expect(caps.supportsIris)
            #expect(caps.supportsAbsolute)
            #expect(caps.supportsRelative)
            #expect(caps.supportsContinuous)
            #expect(caps.azimuthRange == 0...3600)
            #expect(caps.elevationRange == -900...900)
            #expect(caps.zoomRange == 1...1000)
            #expect(caps.auxiliaries.contains(.light))
        }
    }

    @Test func ptzCapabilitiesDoNotGuessPosition3D() throws {
        // A device that answers the document but omits `isSupportPosition3D` gets `false`: a
        // rejected `position3D` reads as a broken drag gesture, not as a missing feature.
        let xml = "<PTZChanelCap><isSupportPreset>true</isSupportPreset></PTZChanelCap>"
        let caps = PTZCapabilitiesWire(document: try PTZFixtures.document(xml))
        #expect(!caps.supportsPosition3D)
        #expect(caps.supportsPresets)
        #expect(caps.maxPresets == 255)     // presets supported but no maximum given
        #expect(!caps.isAbsent)
    }

    @Test func ptzCapabilitiesAbsentHidesEverything() {
        let caps = PTZCapabilitiesWire.absent
        #expect(caps.isAbsent)
        #expect(!caps.supportsContinuous)
        #expect(!caps.supportsPosition3D)
        #expect(!caps.supportsPresets)
        #expect(caps.maxPresets == 0)
        #expect(caps.auxiliaries.isEmpty)
    }

    @Test func ptzCapabilitiesIgnoreAnInvertedRange() throws {
        let xml = """
            <PTZChanelCap><AbsolutePanTiltPositionSpace>
            <XRange><min>3600</min><max>0</max></XRange>
            </AbsolutePanTiltPositionSpace></PTZChanelCap>
            """
        let caps = PTZCapabilitiesWire(document: try PTZFixtures.document(xml))
        #expect(caps.azimuthRange == 0...3600)
    }

    @Test func ptzPresetsListIncludingTheReservedCommands() throws {
        let presets = PTZPreset.list(document: try PTZFixtures.document(PTZFixtures.presets))
        #expect(presets.count == 3)
        #expect(presets[0] == PTZPreset(id: 1, name: "Gate", enabled: true))
        #expect(presets[1].name == "Driveway")
        // Reserved presets are returned, not filtered: the UI lists them separately, read-only.
        #expect(presets[2].id == 94)
        #expect(presets[2].isReservedCommand)
        #expect(!presets[0].isReservedCommand)
    }

    @Test func ptzPresetReservedRangeIsExactly33To105() {
        #expect(PTZPreset.reservedCommands == 33...105)
        #expect(!PTZPreset(id: 32, name: "", enabled: true).isReservedCommand)
        #expect(PTZPreset(id: 33, name: "", enabled: true).isReservedCommand)
        #expect(PTZPreset(id: 94, name: "", enabled: true).isReservedCommand)
        #expect(PTZPreset(id: 105, name: "", enabled: true).isReservedCommand)
        #expect(!PTZPreset(id: 106, name: "", enabled: true).isReservedCommand)
        #expect(PTZPreset.userSlots == 1...32)
    }

    @Test func ptzPresetDisplayNameFallsBackForAnEmptyName() {
        #expect(PTZPreset(id: 3, name: "", enabled: true).displayName == "Preset 3")
        #expect(PTZPreset(id: 3, name: "Gate", enabled: true).displayName == "Gate")
    }

    @Test func ptzPatrolsAbsorbTheCasingVariants() throws {
        let patrols = PTZPatrol.list(document: try PTZFixtures.document(PTZFixtures.patrols))
        let patrol = try #require(patrols.first)
        #expect(patrol.id == 1)
        #expect(patrol.name == "Perimeter")
        #expect(patrol.stops.count == 2)
        #expect(patrol.stops[0] == PTZPatrol.Stop(presetID: 1, dwellSeconds: 10, speed: 30))
        // `<presetID>` and `<DwellTime>` are the same fields under different spellings.
        #expect(patrol.stops[1] == PTZPatrol.Stop(presetID: 2, dwellSeconds: 15, speed: 30))
    }

    @Test func ptzStatusReadsTheAbsolutePosition() throws {
        let status = try PTZStatus(document: try PTZFixtures.document(PTZFixtures.status))
        #expect(status.position.wireAzimuth == 1350)
        #expect(status.position.wireElevation == -150)
        #expect(status.position.zoomSteps == 40)
        #expect(status.position.azimuthDegrees == 135)
    }

    @Test func ptzStatusWithoutAPositionThrows() {
        // A zeroed position would make the position3D Y-axis calibration silently conclude
        // "not inverted".
        #expect(throws: ISAPIError.self) {
            try PTZStatus(document: try PTZFixtures.document("<PTZStatus/>"))
        }
    }

    @Test func ptzChannelListReadsTheNVRForm() throws {
        let xml = """
            <PTZChannelList><PTZChannel><id>1</id></PTZChannel>
            <PTZChannel><id>7</id></PTZChannel></PTZChannelList>
            """
        let channels = PTZChannelList.channels(document: try PTZFixtures.document(xml))
        #expect(channels == [ChannelID(1), ChannelID(7)])
    }
}

// MARK: - PTZControllerSuite

@Suite struct PTZControllerSuite {

    private func makeController(_ double: RequestDouble, gate: SleepGate,
                               capabilities: PTZCapabilitiesWire) -> PTZController {
        PTZController(requests: double, channel: ChannelID(1), capabilities: capabilities,
                      clock: GateClock(gate: gate))
    }

    private func fullCapabilities() throws -> PTZCapabilitiesWire {
        PTZCapabilitiesWire(document: try PTZFixtures.document(PTZFixtures.capabilities))
    }

    @Test func ptzControllerSendsTheContinuousBodyToTheRightResource() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        try await controller.continuous(pan: 60, tilt: -40, zoom: 0)

        // Exactly one write so far: the keep-alive is parked on the closed gate.
        let requests = await double.requests(to: "/PTZCtrl/channels/1/continuous")
        #expect(requests.count == 1)
        #expect(requests[0].method == "PUT")
        #expect(requests[0].bodyText == PTZFixtures.declaration
                + "<PTZData><pan>60</pan><tilt>-40</tilt><zoom>0</zoom></PTZData>")
    }

    @Test func ptzControllerStopSendsThreeZeroBodies() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        // Two credits for the two inter-stop spacings.
        await gate.release(2)
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        await controller.stop()

        let requests = await double.requests(to: "/continuous")
        #expect(requests.count == PTZController.stopRepeatCount)
        let zero = PTZFixtures.declaration
            + "<PTZData><pan>0</pan><tilt>0</tilt><zoom>0</zoom></PTZData>"
        for request in requests { #expect(request.bodyText == zero) }
    }

    @Test func ptzControllerStopIgnoresIndividualFailures() async throws {
        // Two of three writes may fail and the camera still stops; propagating the first would
        // skip the other two, which is the runaway this design prevents.
        let double = RequestDouble()
        await double.route("/continuous", failing: .deviceBusy)
        let gate = SleepGate()
        await gate.release(2)
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        await controller.stop()
        #expect(await double.requests(to: "/continuous").count == 3)
    }

    @Test func ptzControllerZeroTripleRoutesToStop() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        await gate.release(2)
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        try await controller.continuous(pan: 0, tilt: 0, zoom: 0)
        // A joystick returning to centre must produce the full stop discipline, not one write.
        #expect(await double.requests(to: "/continuous").count == 3)
    }

    @Test func ptzControllerKeepAliveResendsTheIdenticalBody() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        try await controller.continuous(pan: 30, tilt: 0, zoom: 0)
        await double.waitForRequests(atLeast: 1)

        // Two keep-alive intervals, released one at a time so the cadence is exact.
        await gate.release(1)
        await double.waitForRequests(atLeast: 2)
        await gate.release(1)
        await double.waitForRequests(atLeast: 3)

        let requests = await double.requests(to: "/continuous")
        #expect(requests.count == 3)
        let expected = PTZFixtures.declaration
            + "<PTZData><pan>30</pan><tilt>0</tilt><zoom>0</zoom></PTZData>"
        for request in requests { #expect(request.bodyText == expected) }
        #expect(await controller.keepAliveSendCount == 2)
    }

    @Test func ptzControllerKeepAliveIntervalsAreTheDocumentedNumbers() {
        #expect(PTZController.keepAliveInterval == .milliseconds(400))
        #expect(PTZController.stopRepeatCount == 3)
        #expect(PTZController.stopRepeatSpacing == .milliseconds(80))
    }

    @Test func ptzControllerStopEndsTheKeepAlive() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        try await controller.continuous(pan: 30, tilt: 0, zoom: 0)
        await gate.release(1)
        await double.waitForRequests(atLeast: 2)

        // `stop()` cancels the keep-alive before its own first write, so the credits released here
        // reach the stop path and not another re-send.
        async let stopped: Void = controller.stop()
        await gate.release(8)
        await stopped

        let settled = await double.requestCount
        // More sleeps must not produce another keep-alive write: `activeVelocity` is now nil.
        await gate.release(8)
        await Task.yield()
        #expect(await double.requestCount == settled)
        let zero = PTZFixtures.declaration
            + "<PTZData><pan>0</pan><tilt>0</tilt><zoom>0</zoom></PTZData>"
        #expect(await double.recorded.suffix(3).allSatisfy { $0.bodyText == zero })
    }

    @Test func ptzControllerRefusesWritingAReservedPreset() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        // Preset 94 is remote reboot. Writing it would reboot the camera the user was bookmarking.
        await #expect(throws: ISAPIError.device(statusCode: 4, sub: "reservedPreset")) {
            try await controller.setPreset(94, name: "Nope")
        }
        await #expect(throws: ISAPIError.device(statusCode: 4, sub: "reservedPreset")) {
            try await controller.deletePreset(33)
        }
        // Not one byte went to the device.
        #expect(await double.requestCount == 0)
        // The user range is writable.
        try await controller.setPreset(3, name: "Back gate")
        let requests = await double.requests(to: "/PTZCtrl/channels/1/presets/3")
        #expect(requests.count == 1)
        #expect(requests[0].bodyText == PTZFixtures.declaration
                + "<PTZPreset><id>3</id><presetName>Back gate</presetName></PTZPreset>")
    }

    @Test func ptzControllerRecallsAReservedPresetWithAnEmptyBody() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        // Recall is allowed — the UI confirms first — and must send `Content-Length: 0`.
        try await controller.gotoPreset(94)
        let requests = await double.requests(to: "/presets/94/goto")
        #expect(requests.count == 1)
        #expect(requests[0].body == nil)
    }

    @Test func ptzControllerRefusesPosition3DWhenUnsupported() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: .absent)
        await #expect(throws: ISAPIError.self) {
            try await controller.position3D(PTZ3D(startX: 0, startY: 0, endX: 10, endY: 10))
        }
        await #expect(throws: ISAPIError.self) {
            try await controller.continuous(pan: 10, tilt: 0, zoom: 0)
        }
        #expect(await double.requestCount == 0)
    }

    @Test func ptzControllerStartingAPatrolStopsFirst() async throws {
        // Starting a patrol while a continuous move is active returns `invalidOperation`, so the
        // controller always stops first.
        let double = RequestDouble()
        let gate = SleepGate()
        await gate.release(2)
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        try await controller.startPatrol(1)
        let all = await double.recorded
        #expect(all.count == 4)
        #expect(all.prefix(3).allSatisfy { $0.resource.hasSuffix("/continuous") })
        #expect(all[3].resource.hasSuffix("/patrols/1/start"))
        #expect(all[3].body == nil)
    }

    @Test func ptzControllerReadsPresetsAndPatrols() async throws {
        let double = RequestDouble()
        await double.route("/presets", xml: PTZFixtures.presets)
        await double.route("/patrols", xml: PTZFixtures.patrols)
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        let presets = try await controller.presets()
        let patrols = try await controller.patrols()
        #expect(presets.count == 3)
        #expect(patrols.first?.stops.count == 2)
    }

    @Test func ptzControllerSendsFocusAndIrisToTheVideoInputPath() async throws {
        // Focus and iris live under `/System/Video/inputs/channels/{ch}`, not under `/PTZCtrl` —
        // the wrong path is a silent 404.
        let double = RequestDouble()
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        try await controller.setFocus(50)
        try await controller.setIris(-50)
        let recorded = await double.recorded
        #expect(recorded[0].resource == "/System/Video/inputs/channels/1/focus")
        #expect(recorded[1].resource == "/System/Video/inputs/channels/1/iris")
        #expect(recorded[1].bodyText?.contains("<iris>-50</iris>") == true)
    }
}
