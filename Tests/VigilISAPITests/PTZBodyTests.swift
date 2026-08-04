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
