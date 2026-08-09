//
//  EventTestSupport.swift
//  VigilCoreTests
//
//  Doubles and fixture builders for the `Sources/VigilCore/Events` suites: a movable clock, a
//  movable wall clock, an `EventNotificationAlert` builder, and a scripted `ISAPIRequesting` that
//  serves real multipart alert-stream bytes.
//
//  No @Test lives here. Every name is prefixed `Event` so it cannot collide with a sibling agent's
//  doubles in the same test module.
//

#if os(macOS)

import Foundation
import Testing
import VigilCore
import VigilISAPI
import VigilProtocols

// MARK: - Clocks

/// A monotonic clock a test moves by hand, shared **by reference** so an actor and the test that
/// drives it see the same time.
///
/// `@unchecked Sendable`, justified: every access to `nanos` and `sleeps` happens inside `lock`, an
/// invariant the compiler cannot check but which is local to these thirty lines.
/// `VigilTestKit.VirtualClock` is a `struct` by design — two copies advance independently — which is
/// the right choice there and the wrong one here.
final class EventTestClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var nanos: Int64 = 0
    private var sleeps: [Double] = []

    init(startSeconds: Double = 0) {
        nanos = Int64(startSeconds * 1e9)
    }

    func now() -> MediaInstant {
        lock.lock()
        defer { lock.unlock() }
        return MediaInstant(nanoseconds: nanos)
    }

    /// Moves time forward. Never backwards: a monotonic clock that steps back is not one.
    func advance(seconds: Double) {
        guard seconds > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        nanos += Int64(seconds * 1e9)
    }

    /// Records the requested delay, moves the clock by it, and yields once.
    ///
    /// It does not actually wait: a test that waited would be measuring this machine's load. The
    /// single `Task.yield()` lets the actor under test make progress, and the cancellation check is
    /// what makes a cancelled backoff return promptly, exactly as the real clock does.
    func sleep(for duration: Duration) async throws {
        // `NSLock.lock()` is `@available(*, noasync)`, so the mutation lives in a synchronous
        // helper. Calling a sync function from an async one is exactly what that attribute wants.
        recordSleep(duration)
        try Task.checkCancellation()
        await Task.yield()
    }

    private func recordSleep(_ duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        sleeps.append(Double(duration.wholeNanoseconds) / 1e9)
        nanos += duration.wholeNanoseconds
    }

    /// Every delay asked for, in order — the backoff ladder, assertable.
    var requestedSleeps: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return sleeps
    }
}

/// A wall clock a test sets directly.
///
/// `@unchecked Sendable`, justified as above: one lock, one field.
final class EventTestWallClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.date = date
    }

    func advance(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        date = date.addingTimeInterval(seconds)
    }
}

// MARK: - Identity

/// Hands out predictable `EventID`s so a failing assertion names a recognisable record.
final class EventIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0

    /// `EventID` wraps a `UUID`; a counter in the last field keeps them ordered and readable.
    func next() -> EventID {
        lock.lock()
        defer { lock.unlock() }
        index += 1
        let suffix = String(format: "%012d", index)
        let text = "00000000-0000-4000-8000-\(suffix)"
        guard let uuid = UUID(uuidString: text) else { return EventID() }
        return EventID(uuid)
    }
}

// MARK: - Alert builder

/// Builds an `EventNotificationAlert` the way the wire would, without going through XML.
///
/// The values are synthesised, not captured from hardware; the shapes follow docs/spec-isapi.md
/// §14.3's field table. Where a test needs the XML path instead, `eventMultipartBody` below builds
/// real multipart bytes and lets `MultipartStreamParser` do the decoding.
enum EventAlertFixture {

    static let deviceEpoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// One alert.
    ///
    /// - Parameters:
    ///   - kind: the wire event type is derived from this so `EventKind(raw:)` round-trips.
    ///   - offset: seconds added to `deviceEpoch` for the device's own `dateTime`.
    ///   - naive: models a `dateTime` with no zone designator.
    static func alert(kind: EventKind = .motion,
                      rawType: String? = nil,
                      channel: ChannelID = 1,
                      state: EventState = .active,
                      activePostCount: Int = 1,
                      offset: Double = 0,
                      naive: Bool = false,
                      regions: [DetectionRegion] = [],
                      snapshot: Data? = nil,
                      ioPort: Int? = nil) -> EventNotificationAlert {
        EventNotificationAlert(deviceIP: "192.168.1.64",
                               deviceMAC: "44:47:cc:11:22:33",
                               channel: channel,
                               channelName: nil,
                               timestamp: deviceEpoch.addingTimeInterval(offset),
                               timestampWasNaive: naive,
                               kind: kind,
                               rawType: rawType ?? wireType(for: kind),
                               state: state,
                               activePostCount: activePostCount,
                               ioPort: ioPort,
                               regions: regions,
                               snapshot: snapshot)
    }

    /// The device's periodic liveness part: `videoloss` / `inactive` / count 0 / no regions.
    static func heartbeat() -> EventNotificationAlert {
        alert(kind: .videoLoss, state: .inactive, activePostCount: 0)
    }

    /// The wire spelling for a kind, as docs/spec-isapi.md §14.3 lists it.
    static func wireType(for kind: EventKind) -> String {
        switch kind {
        case .motion: "VMD"
        case .lineCrossing: "linedetection"
        case .intrusion: "fielddetection"
        case .regionEntrance: "regionEntrance"
        case .regionExit: "regionExiting"
        case .faceDetected: "facedetection"
        case .tamper: "tamperdetection"
        case .alarmInput: "io"
        case .videoLoss: "videoloss"
        case .diskFull: "diskfull"
        case .diskError: "diskerror"
        case .illegalAccess: "illegalaccess"
        case .networkBroken: "nicbroken"
        case .ipConflict: "ipconflict"
        case .badVideo: "badvideo"
        case .pir: "pirAlarm"
        case .unattendedBaggage: "unattendedBaggage"
        case .objectRemoved: "attendedBaggage"
        case .audioException: "audioexception"
        case .sceneChange: "scenechangedetection"
        case .other(let raw): raw
        }
    }

    /// A square intrusion zone with `points` vertices, already normalised.
    static func region(id: Int = 1, points: Int = 4) -> DetectionRegion {
        let polygon = (0..<max(0, points)).map { index in
            NormalizedPoint(x: Double(index % 7) / 7, y: Double(index % 5) / 5)
        }
        return DetectionRegion(regionID: id, sensitivityLevel: 50, polygon: polygon,
                               targetRect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
    }
}

// MARK: - Multipart bytes

/// Builds the real `multipart/mixed` body a Hikvision device sends on
/// `/ISAPI/Event/notification/alertStream`, so a test can drive the whole chain — parser, assembler,
/// monitor, service, store — from bytes.
///
/// Synthesised from the sample in docs/spec-isapi.md §14.2; not a capture from hardware.
enum EventMultipartFixture {

    static let boundary = "boundary"

    static func contentType() -> String { "multipart/mixed; boundary=\(boundary)" }

    /// One `<EventNotificationAlert>` part, `CRLF` framing, with an explicit `Content-Length`.
    static func part(eventType: String, channel: Int, state: String, count: Int,
                     dateTime: String = "2024-05-01T12:35:01+08:00") -> Data {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <EventNotificationAlert version="2.0" \
            xmlns="http://www.hikvision.com/ver20/XMLSchema">
            <ipAddress>192.168.1.64</ipAddress>
            <portNo>80</portNo>
            <protocol>HTTP</protocol>
            <macAddress>44:47:cc:11:22:33</macAddress>
            <channelID>\(channel)</channelID>
            <dateTime>\(dateTime)</dateTime>
            <activePostCount>\(count)</activePostCount>
            <eventType>\(eventType)</eventType>
            <eventState>\(state)</eventState>
            <eventDescription>\(eventType) alarm</eventDescription>
            </EventNotificationAlert>
            """
        let body = Data(xml.utf8)
        var out = Data("--\(boundary)\r\n".utf8)
        out.append(Data("Content-Type: application/xml; charset=\"UTF-8\"\r\n".utf8))
        out.append(Data("Content-Length: \(body.count)\r\n\r\n".utf8))
        out.append(body)
        out.append(Data("\r\n".utf8))
        return out
    }

    /// One camera-supplied JPEG part paired with the preceding XML alert.
    static func image(_ bytes: Data) -> Data {
        var out = Data("--\(boundary)\r\n".utf8)
        out.append(Data("Content-Type: image/jpeg\r\n".utf8))
        out.append(Data("Content-Length: \(bytes.count)\r\n\r\n".utf8))
        out.append(bytes)
        out.append(Data("\r\n".utf8))
        return out
    }

    /// The closing delimiter.
    static func closing() -> Data { Data("--\(boundary)--\r\n".utf8) }
}

// MARK: - Scripted ISAPI surface

/// An `ISAPIRequesting` that serves scripted alert-stream connections and nothing else.
///
/// `openStream` walks `connections`: each element is either bytes to deliver (after which the stream
/// ends cleanly, so the monitor reconnects) or an error to throw. Once the script is exhausted every
/// further call throws `outcomeWhenExhausted`, which is how a test gives the monitor a terminating
/// condition instead of letting it reconnect for ever.
///
/// `@unchecked Sendable`, justified: the mutable script index is guarded by `lock`.
final class EventScriptedRequests: ISAPIRequesting, @unchecked Sendable {

    enum Connection: Sendable {
        /// Deliver these chunks, then end the byte stream cleanly.
        case bytes([Data])
        /// Fail the open with this error.
        case failure(ISAPIError)
    }

    private let lock = NSLock()
    private var script: [Connection]
    private var index = 0
    private var opens = 0
    private let outcomeWhenExhausted: ISAPIError

    static let alertStreamResource = "/Event/notification/alertStream"

    init(script: [Connection],
         whenExhausted: ISAPIError = .notSupported(resource: alertStreamResource)) {
        self.script = script
        self.outcomeWhenExhausted = whenExhausted
    }

    /// How many times the alert stream was opened. The reconnect count, assertable.
    var openCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return opens
    }

    func openStream(_ resource: String, query: [URLQueryItem],
                    headers: [String: String]) async throws(ISAPIError) -> ISAPIByteStream {
        switch nextStep() {
        case .failure(let error):
            throw error
        case .bytes(let chunks):
            let stream = AsyncThrowingStream<Data, any Error> { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
            return ISAPIByteStream(contentType: EventMultipartFixture.contentType(), bytes: stream)
        }
    }

    /// Advances the script. Synchronous, because `NSLock` may not be taken from an async context.
    private func nextStep() -> Connection {
        lock.lock()
        defer { lock.unlock() }
        opens += 1
        let step: Connection = index < script.count ? script[index] : .failure(outcomeWhenExhausted)
        index += 1
        return step
    }

    // The rest of the protocol is not exercised by the event path; each answers `.notSupported`
    // rather than trapping, so an accidental call fails a test instead of taking the process down.
    func getDocument(_ resource: String, query: [URLQueryItem],
                     lane: HTTPLane) async throws(ISAPIError) -> ISAPIDocument {
        throw ISAPIError.notSupported(resource: resource)
    }

    func getBytes(_ resource: String, query: [URLQueryItem],
                  lane: HTTPLane) async throws(ISAPIError) -> Data {
        throw ISAPIError.notSupported(resource: resource)
    }

    func putDocument(_ resource: String, body: Data?, query: [URLQueryItem],
                     lane: HTTPLane) async throws(ISAPIError) -> ISAPIDocument? {
        throw ISAPIError.notSupported(resource: resource)
    }

    func postDocument(_ resource: String, body: Data?, query: [URLQueryItem],
                      lane: HTTPLane) async throws(ISAPIError) -> ISAPIDocument {
        throw ISAPIError.notSupported(resource: resource)
    }

    func deleteDocument(_ resource: String, query: [URLQueryItem],
                        lane: HTTPLane) async throws(ISAPIError) -> ISAPIDocument? {
        throw ISAPIError.notSupported(resource: resource)
    }
}

// MARK: - Async waiting

/// Waits until `condition` holds, giving the runtime real opportunities to make it true.
///
/// The intent is still "bound the scheduling opportunities, not the wall clock", so that a slow
/// machine cannot fail a test a fast one passes. What changed is how the opportunities are given.
///
/// ⛔ IT MUST NOT BE A BARE `Task.yield()` LOOP, AND THIS PROJECT HAS NOW LEARNED THAT TWICE.
/// `VirtualDiscoveryClock.startPump` carries the same warning from the first time: a tight yield
/// loop occupies a cooperative-pool thread and starves the very task it is waiting for, so "the
/// work has not happened" becomes indistinguishable from "the work was never given a thread". Under
/// `swift test --parallel` on a loaded runner, where every other suite is competing for the same
/// pool, 20 000 yields could pass without the event pump running once — and
/// `eventMonitorServiceIngestsAnAlertFromRealMultipartBytes` then failed with a store that was
/// simply empty, five assertions deep, looking exactly like a broken ingest path.
///
/// So: yield for the first stretch, which is all a healthy machine ever needs and keeps the fast
/// path fast, then sleep. A sleep suspends this task and hands the thread back, which is the only
/// thing that actually helps when the pool is saturated.
/// ⚠️ THE BOUND EXISTS TO STOP A HANG, NOT TO ASSERT A SPEED. Nothing here measures how fast the
/// pipeline is; the assertions after it are about what the pipeline *did*. So the ceiling is set
/// generously and the loop exits the instant the condition holds — on a healthy machine that is
/// within a few hops and this costs nothing.
///
/// Getting that wrong is the second half of this function's history. The first version spun 20 000
/// bare yields, which starved what it waited for. Replacing them with sleeps fixed the mechanism
/// and, in the same edit, cut the ceiling to about 1.8 s — and a loaded runner then ingested 19 of
/// 30 alerts inside it and failed. The mechanism was right and the budget was wrong, which reads
/// exactly like the mechanism still being wrong.
///
/// And the third: about 9.8 s was not enough either. On the first full CI run of this suite — 2798
/// tests under `--parallel` on a three-core runner — `…CollapsesARepeatedWireAlarmIntoOneRow`
/// reached 13 of 30 inside the budget. Raised to about 30 s, for the reason above and no other: the
/// loop returns the instant the condition holds, so a healthy machine never spends it, and a
/// ceiling only ever bounds a hang.
///
/// ⚠️ What this budget cannot do is hide a real defect, and the number it reports is how to tell
/// the difference. A count that climbs with the budget and reaches its target is a starved pool. A
/// count that stops well short of the target with thirty seconds available is events being lost,
/// and no ceiling will fix that — go and read the ingest path instead of raising this again.
@discardableResult
func eventWaitUntil(attempts: Int = 30_000,
                    _ condition: @Sendable () async -> Bool) async -> Bool {
    /// Yields before falling back to sleeping. Small: on an idle machine the work lands within a
    /// handful of hops, and past that the pool is busy and yielding is the wrong tool.
    let yieldBudget = 200
    for attempt in 0..<attempts {
        if await condition() { return true }
        if attempt < yieldBudget {
            await Task.yield()
        } else {
            // Sleeping hands the thread back, which is the only thing that helps a saturated pool.
            // ~9.8 s of them, reached only when something is genuinely wrong.
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    return await condition()
}

/// A camera on `host`, enabled, on `channel`.
func eventTestCamera(host: String = "192.168.1.64", port: Int = 80,
                     channel: ChannelID = 1, enabled: Bool = true) -> Camera {
    var camera = Camera(host: host)
    camera.httpPort = port
    camera.channel = channel
    camera.isEnabled = enabled
    return camera
}

#endif
