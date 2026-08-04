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
