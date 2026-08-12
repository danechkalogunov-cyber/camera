//
//  AlertStreamTests.swift
//  VigilISAPITests
//
//  The alert-stream consumer: heartbeat suppression, XML+JPEG pairing, the pairing-window flush,
//  the `EventNotificationAlert` model, region magnitude sniffing and the Y flip, and the terminal
//  states a 403 and a second 401 produce.
//  Covers docs/spec-isapi.md §14.2–§14.4 and §14.6.
//

import Foundation
import Testing
import VigilProtocols

@testable import VigilISAPI

// MARK: - EventAlertModelSuite

@Suite struct EventAlertModelSuite {

    private func alert(
        _ xml: String,
        receivedAt: Date = Date(timeIntervalSince1970: 1_714_560_896)
    ) throws
        -> EventNotificationAlert
    {
        try EventNotificationAlert(
            document: try ISAPIDocument(parsing: Data(xml.utf8)),
            receivedAt: receivedAt)
    }

    @Test func eventAlertDecodesTheMotionFixture() throws {
        let event = try alert(MultipartFixtures.motionXML)
        #expect(event.deviceIP == "192.168.1.64")
        #expect(event.deviceMAC == "44:47:cc:11:22:33")
        #expect(event.channel == ChannelID(1))
        #expect(event.channelName == "Driveway")
        #expect(event.kind == .motion)
        #expect(event.rawType == "VMD")
        #expect(event.state == .active)
        #expect(event.activePostCount == 1)
        #expect(!event.timestampWasNaive)
        // 2024-05-01T12:34:56+08:00 is 2024-05-01T04:34:56Z.
        #expect(abs(event.timestamp.timeIntervalSince1970 - 1_714_538_096) < 0.001)
        #expect(event.regions.count == 1)
        #expect(!event.isHeartbeat)
        #expect(event.snapshot == nil)
    }

    @Test func eventAlertSuppressesTheHeartbeat() throws {
        let event = try alert(MultipartFixtures.heartbeatXML)
        // All four conditions of docs/spec-isapi.md §14.3: videoloss, inactive, count 0, no regions.
        #expect(event.kind == .videoLoss)
        #expect(event.state == .inactive)
        #expect(event.activePostCount == 0)
        #expect(event.regions.isEmpty)
        #expect(event.isHeartbeat)
    }

    @Test func eventAlertDoesNotMistakeARealVideoLossForAHeartbeat() throws {
        // A camera going dark also arrives as `videoloss`, but with a non-zero post count.
        let xml = """
            <EventNotificationAlert><channelID>3</channelID>
            <eventType>videoloss</eventType><eventState>active</eventState>
            <activePostCount>1</activePostCount></EventNotificationAlert>
            """
        let event = try alert(xml)
        #expect(event.kind == .videoLoss)
        #expect(!event.isHeartbeat)
        #expect(event.kind.defaultSeverity == .critical)
    }

    @Test func eventAlertPrefersDynChannelIDOnAnNVR() throws {
        // `dynChannelID` is the channel the user sees; `channelID` is the NVR's internal one, and
        // showing it would attribute every event to the wrong camera.
        let event = try alert(MultipartFixtures.lineCrossingXML)
        #expect(event.channel == ChannelID(7))
        #expect(event.kind == .lineCrossing)
    }

    @Test func eventAlertKeepsATwoPointTripwirePolygon() throws {
        // Two points is a legitimate line, and dropping it would erase the drawn tripwire.
        let event = try alert(MultipartFixtures.lineCrossingXML)
        let region = try #require(event.regions.first)
        #expect(region.polygon.count == 2)
        #expect(abs(region.polygon[0].x - 0.1) < 0.0001)
        // Y flips: the wire's 250 of 1000 is 0.25 up from the bottom, i.e. 0.75 down from the top.
        #expect(abs(region.polygon[0].y - 0.75) < 0.0001)
    }

    @Test func eventAlertDropsAnUnderSpecifiedPolygonForAnythingElse() throws {
        let xml = """
            <EventNotificationAlert><eventType>fielddetection</eventType>
            <eventState>active</eventState><activePostCount>1</activePostCount>
            <DetectionRegionList><DetectionRegion><regionID>1</regionID>
            <RegionCoordinatesList>
            <RegionCoordinates><positionX>0</positionX><positionY>0</positionY></RegionCoordinates>
            <RegionCoordinates><positionX>500</positionX><positionY>0</positionY></RegionCoordinates>
            </RegionCoordinatesList></DetectionRegion></DetectionRegionList>
            </EventNotificationAlert>
            """
        let event = try alert(xml)
        #expect(event.kind == .intrusion)
        #expect(event.regions.isEmpty)
    }

    @Test func eventAlertNormalisesTheMotionPolygonWithTheYFlip() throws {
        let event = try alert(MultipartFixtures.motionXML)
        let region = try #require(event.regions.first)
        #expect(region.regionID == 1)
        #expect(region.sensitivityLevel == 60)
        #expect(region.polygon.count == 4)
        // Wire (0, 0) is the image's bottom-left ⇒ normalised (0, 1) in a top-left space.
        #expect(region.polygon[0] == NormalizedPoint(x: 0, y: 1))
        #expect(region.polygon[1] == NormalizedPoint(x: 1, y: 1))
        #expect(abs(region.polygon[2].x - 1) < 0.0001)
        #expect(abs(region.polygon[2].y - 0.44) < 0.0001)  // 1 - 560/1000
        #expect(abs(region.polygon[3].y - 0.44) < 0.0001)
    }

    @Test func eventAlertSniffsTheTenThousandCoordinateScale() throws {
        // 5.5+ smart cameras use 0…10000. The magnitude is the only discriminator the wire gives.
        let xml = """
            <EventNotificationAlert><eventType>regionEntrance</eventType>
            <eventState>active</eventState><activePostCount>1</activePostCount>
            <DetectionRegionList><DetectionRegion><regionID>2</regionID>
            <RegionCoordinatesList>
            <RegionCoordinates><positionX>0</positionX><positionY>0</positionY></RegionCoordinates>
            <RegionCoordinates><positionX>9000</positionX><positionY>0</positionY></RegionCoordinates>
            <RegionCoordinates><positionX>9000</positionX><positionY>5000</positionY></RegionCoordinates>
            </RegionCoordinatesList>
            <TargetRect><X>1000</X><Y>2000</Y><width>3000</width><height>1000</height></TargetRect>
            </DetectionRegion></DetectionRegionList>
            </EventNotificationAlert>
            """
        let event = try alert(xml)
        let region = try #require(event.regions.first)
        #expect(abs(region.polygon[1].x - 0.9) < 0.0001)
        #expect(abs(region.polygon[2].y - 0.5) < 0.0001)
        let rect = try #require(region.targetRect)
        #expect(abs(rect.x - 0.1) < 0.0001)
        #expect(abs(rect.width - 0.3) < 0.0001)
        // The wire's Y is the rectangle's *lower* edge, so the flipped top edge is
        // 1 - (2000 + 1000)/10000.
        #expect(abs(rect.y - 0.7) < 0.0001)
    }

    @Test func eventAlertRequiresAnEventType() {
        #expect(throws: ISAPIError.self) {
            _ = try EventNotificationAlert(
                document: try ISAPIDocument(parsing: Data("<EventNotificationAlert/>".utf8)),
                receivedAt: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func eventAlertFallsBackToTheReceiveTimeAndFlagsIt() throws {
        let received = Date(timeIntervalSince1970: 1_714_560_896)
        let xml = """
            <EventNotificationAlert><eventType>VMD</eventType>
            <eventState>active</eventState><activePostCount>1</activePostCount>
            </EventNotificationAlert>
            """
        let event = try alert(xml, receivedAt: received)
        #expect(event.timestamp == received)
        #expect(event.timestampWasNaive)
    }

    @Test func eventAlertFlagsANaiveDeviceTimestamp() throws {
        // A time with no zone was read as UTC; the session has to re-interpret it against the
        // device's own offset, so the flag has to be honest.
        let xml = """
            <EventNotificationAlert><eventType>VMD</eventType><eventState>active</eventState>
            <activePostCount>1</activePostCount><dateTime>2024-05-01T12:34:56</dateTime>
            </EventNotificationAlert>
            """
        #expect(try alert(xml).timestampWasNaive)
    }

    @Test func eventAlertZoneDetectionAcceptsEveryDesignator() {
        #expect(EventNotificationAlert.carriesZone("2024-05-01T04:34:56Z"))
        #expect(EventNotificationAlert.carriesZone("2024-05-01T12:34:56+08:00"))
        #expect(EventNotificationAlert.carriesZone("2024-05-01T07:34:56-05:00"))
        #expect(EventNotificationAlert.carriesZone("2024-05-01T12:34:56+0800"))
        #expect(!EventNotificationAlert.carriesZone("2024-05-01T12:34:56"))
        // The date's own hyphens must not read as a negative offset.
        #expect(!EventNotificationAlert.carriesZone("2024-05-01"))
    }

    @Test func eventKindMapsEveryDocumentedWireValue() {
        // docs/spec-isapi.md §14.3's table, compared lowercased.
        #expect(EventKind(raw: "VMD") == .motion)
        #expect(EventKind(raw: "linedetection") == .lineCrossing)
        #expect(EventKind(raw: "fielddetection") == .intrusion)
        #expect(EventKind(raw: "regionEntrance") == .regionEntrance)
        #expect(EventKind(raw: "regionExiting") == .regionExit)
        #expect(EventKind(raw: "facedetection") == .faceDetected)
        #expect(EventKind(raw: "tamperdetection") == .tamper)
        #expect(EventKind(raw: "shelteralarm") == .tamper)
        #expect(EventKind(raw: "io") == .alarmInput)
        #expect(EventKind(raw: "videoloss") == .videoLoss)
        #expect(EventKind(raw: "diskfull") == .diskFull)
        #expect(EventKind(raw: "diskerror") == .diskError)
        #expect(EventKind(raw: "illegalaccess") == .illegalAccess)
        #expect(EventKind(raw: "nicbroken") == .networkBroken)
        #expect(EventKind(raw: "ipconflict") == .ipConflict)
        #expect(EventKind(raw: "badvideo") == .badVideo)
        #expect(EventKind(raw: "pirAlarm") == .pir)
        #expect(EventKind(raw: "unattendedBaggage") == .unattendedBaggage)
        #expect(EventKind(raw: "attendedBaggage") == .objectRemoved)
        #expect(EventKind(raw: "audioexception") == .audioException)
        #expect(EventKind(raw: "scenechangedetection") == .sceneChange)
        // Never dropped: an unknown type surfaces with its raw name.
        #expect(EventKind(raw: "thermometry") == .other("thermometry"))
    }

    @Test func eventKindSeverityMatchesTheTable() {
        #expect(EventKind.motion.defaultSeverity == .info)
        #expect(EventKind.lineCrossing.defaultSeverity == .warning)
        #expect(EventKind.tamper.defaultSeverity == .critical)
        #expect(EventKind.videoLoss.defaultSeverity == .critical)
        #expect(EventKind.other("x").defaultSeverity == .info)
        #expect(EventSeverity.info < EventSeverity.warning)
        #expect(EventSeverity.warning < EventSeverity.critical)
    }

    @Test func eventAlertReadsTheIOPort() throws {
        let xml = """
            <EventNotificationAlert><eventType>io</eventType><eventState>active</eventState>
            <activePostCount>1</activePostCount><inputIOPortID>2</inputIOPortID>
            </EventNotificationAlert>
            """
        #expect(try alert(xml).ioPort == 2)
    }
}

// MARK: - AlertPartAssemblerSuite

@Suite struct AlertPartAssemblerSuite {

    private let now = Date(timeIntervalSince1970: 1_714_560_896)

    private func drive(
        _ outputs: [MultipartStreamParser.Output],
        policy: AlertStreamMonitor.Policy = .init(),
        now: Date
    ) -> [EventNotificationAlert] {
        var assembler = AlertPartAssembler(policy: policy)
        var events: [EventNotificationAlert] = []
        for output in outputs { events += assembler.accept(output, now: now) }
        events += assembler.flushAll()
        return events
    }

    @Test func assemblerPairsAJPEGWithThePrecedingEvent() throws {
        let token = "<boundary>"
        let stream = MultipartFixtures.realisticStream(boundary: token)
        let outputs = try MultipartFixtures.run(stream, boundary: token, chunkSize: 37)
        let events = drive(outputs, now: now)
        // Motion (with its image) and the heartbeat — the assembler does not filter heartbeats;
        // the monitor does.
        #expect(events.count == 2)
        #expect(events[0].kind == .motion)
        #expect(events[0].snapshot == MultipartFixtures.jpeg(containing: token))
        #expect(events[1].isHeartbeat)
        #expect(events[1].snapshot == nil)
    }

    @Test func assemblerEmitsAnEventWithNoImageWhenTheNextPartIsXML() throws {
        let token = "b"
        let motion = Data(MultipartFixtures.motionXML.utf8)
        let heartbeat = Data(MultipartFixtures.heartbeatXML.utf8)
        let stream = MultipartFixtures.stream(
            boundary: token,
            parts: [
                (["Content-Type": "application/xml", "Content-Length": String(motion.count)], motion),
                (
                    [
                        "Content-Type": "application/xml",
                        "Content-Length": String(heartbeat.count),
                    ], heartbeat
                ),
            ])
        let events = drive(
            try MultipartFixtures.run(stream, boundary: token, chunkSize: 64),
            now: now)
        #expect(events.count == 2)
        #expect(events[0].snapshot == nil)
    }

    @Test func assemblerFlushesAPendingEventOncePairingWindowExpires() throws {
        let token = "b"
        let motion = Data(MultipartFixtures.motionXML.utf8)
        let stream = MultipartFixtures.stream(
            boundary: token,
            parts: [
                (
                    [
                        "Content-Type": "application/xml",
                        "Content-Length": String(motion.count),
                    ], motion
                )
            ],
            closing: false)
        var assembler = AlertPartAssembler(policy: AlertStreamMonitor.Policy())
        var events: [EventNotificationAlert] = []
        for output in try MultipartFixtures.run(stream, boundary: token, chunkSize: 4096) {
            events += assembler.accept(output, now: now)
        }
        // Held, waiting for a JPEG.
        #expect(events.isEmpty)
        #expect(assembler.flushExpired(now: now.addingTimeInterval(1.0)).isEmpty)
        // 1.5 s later it goes out anyway: an event must never be delayed waiting for an image the
        // device is not going to send.
        let flushed = assembler.flushExpired(now: now.addingTimeInterval(1.5))
        #expect(flushed.count == 1)
        #expect(flushed[0].kind == .motion)
        #expect(assembler.flushAll().isEmpty)
    }

    @Test func assemblerEmitsImmediatelyWhenSnapshotsAreOff() throws {
        var policy = AlertStreamMonitor.Policy()
        policy.attachSnapshots = false
        let token = "b"
        let motion = Data(MultipartFixtures.motionXML.utf8)
        let stream = MultipartFixtures.stream(
            boundary: token,
            parts: [
                (
                    [
                        "Content-Type": "application/xml",
                        "Content-Length": String(motion.count),
                    ], motion
                )
            ])
        var assembler = AlertPartAssembler(policy: policy)
        var events: [EventNotificationAlert] = []
        for output in try MultipartFixtures.run(stream, boundary: token, chunkSize: 4096) {
            events += assembler.accept(output, now: now)
        }
        #expect(events.count == 1)
        #expect(events[0].snapshot == nil)
    }

    @Test func assemblerDropsAnOversizedImageButKeepsTheEvent() throws {
        var policy = AlertStreamMonitor.Policy()
        policy.snapshotMaxBytes = 64
        let token = "b"
        let motion = Data(MultipartFixtures.motionXML.utf8)
        var image = Data([0xFF, 0xD8, 0xFF])
        image.append(Data(repeating: 0x41, count: 4096))
        let stream = MultipartFixtures.stream(
            boundary: token,
            parts: [
                (["Content-Type": "application/xml", "Content-Length": String(motion.count)], motion),
                (["Content-Type": "image/jpeg", "Content-Length": String(image.count)], image),
            ])
        var parser = MultipartStreamParser(
            boundary: token,
            limits: MultipartStreamParser.Limits(
                maxBinaryPartBytes: policy.snapshotMaxBytes))
        var assembler = AlertPartAssembler(policy: policy)
        var events: [EventNotificationAlert] = []
        for output in try parser.ingest(stream) { events += assembler.accept(output, now: now) }
        events += assembler.flushAll()
        #expect(events.count == 1)
        #expect(events[0].kind == .motion)
        #expect(events[0].snapshot == nil)
    }

    @Test func assemblerIgnoresAnUndecodableXMLPart() throws {
        let token = "b"
        let junk = Data("<EventNotificationAlert><eventTyp".utf8)
        let motion = Data(MultipartFixtures.motionXML.utf8)
        let stream = MultipartFixtures.stream(
            boundary: token,
            parts: [
                (["Content-Type": "application/xml", "Content-Length": String(junk.count)], junk),
                (["Content-Type": "application/xml", "Content-Length": String(motion.count)], motion),
            ])
        let events = drive(
            try MultipartFixtures.run(stream, boundary: token, chunkSize: 4096),
            now: now)
        #expect(events.count == 1)
        #expect(events[0].kind == .motion)
    }
}
