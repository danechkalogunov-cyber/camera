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
