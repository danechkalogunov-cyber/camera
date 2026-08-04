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
