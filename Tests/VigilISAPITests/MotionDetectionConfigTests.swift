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
