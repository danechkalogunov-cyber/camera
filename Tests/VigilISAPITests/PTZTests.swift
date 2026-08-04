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
