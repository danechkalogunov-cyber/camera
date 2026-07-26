//
//  DeviceSessionTests.swift
//  VigilISAPITests
//
//  The device session: the TTL table, the negative-capability cache, the read-modify-write-then-
//  re-GET discipline, the four quirk consultation points, and the ten-step connect sequence.
//  Covers docs/spec-isapi.md §17.1, §18.1, §18.2, §18.3 and §19.
//
//  Every test drives a `RequestDouble`, so what is asserted is the exact traffic the session would
//  have put on the wire and the exact bytes of every body — not a mock's expectation of them.
//  Nothing here waits: freshness is driven by `SessionTestClock.advance(by:)` and the wall clock is
//  frozen, so a TTL boundary is asserted at the boundary rather than near it.
//
//  Fixtures are hand-written from the samples in docs/spec-isapi.md §10, §11, §15 and §17.2. Where a
//  value is not in the spec it is synthesised and says so — none of it came from real hardware.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - Doubles

/// A monotonic clock a test moves explicitly, and which never suspends.
///
/// A reference type because the session stores it as `any MonotonicClock`: `VirtualClock` is a
/// struct, so advancing the test's copy would not advance the session's. Sleeps return immediately —
/// nothing in the session sleeps, and a connect-sequence test must not depend on one that did.
final class SessionTestClock: MonotonicClock, @unchecked Sendable {

    private let lock = NSLock()
    private nonisolated(unsafe) var nanoseconds: Int64 = 0

    func now() -> MediaInstant {
        lock.lock()
        defer { lock.unlock() }
        return MediaInstant(nanoseconds: nanoseconds)
    }

    /// Moves the clock forward by `seconds`. Negative values are ignored, as on a real clock.
    func advance(seconds: Double) {
        guard seconds > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        nanoseconds += Int64(seconds * 1e9)
    }

    func sleep(for duration: Duration) async throws {}

    func sleep(until deadline: MediaInstant) async throws {}
}

/// A clock that jumps forward on every reading, so the connect sequence's budget is spent by the
/// time it reaches its first optional step.
///
/// Not a plausible clock — it is the cheapest way to put the budget check under test without any
/// wall-clock time at all, which is the only way a budget assertion can be exact.
final class SessionBurningClock: MonotonicClock, @unchecked Sendable {

    private let lock = NSLock()
    private let step: Int64
    private nonisolated(unsafe) var nanoseconds: Int64 = 0

    init(perReadingSeconds: Double) {
        step = Int64(perReadingSeconds * 1e9)
    }

    func now() -> MediaInstant {
        lock.lock()
        defer { lock.unlock() }
        nanoseconds += step
        return MediaInstant(nanoseconds: nanoseconds)
    }

    func sleep(for duration: Duration) async throws {}

    func sleep(until deadline: MediaInstant) async throws {}
}

/// Records the quirk records the session pushed at the request gate — consultation point 4.
actor SessionGateDouble: QuirkApplying {

    private(set) var applied: [DeviceQuirks] = []

    func applyQuirks(_ quirks: DeviceQuirks) async {
        applied.append(quirks)
    }
}

// MARK: - Fixtures

/// Bodies the session's own tests need. Every one is either quoted from docs/spec-isapi.md or
/// synthesised for this suite; none was captured from a device.
enum SessionFixtures {

    /// docs/spec-isapi.md §10.1, trimmed to the fields the session reads.
    static func deviceInfo(firmware: String = "V5.5.82",
                           serial: String = "DS-2CD2385FWD-I20190611AAWR000000001") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <DeviceInfo version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <deviceName>Front Door</deviceName><deviceID>1</deviceID>
        <model>DS-2CD2385FWD-I</model><serialNumber>\(serial)</serialNumber>
        <firmwareVersion>\(firmware)</firmwareVersion><deviceType>IPCamera</deviceType>
        </DeviceInfo>
        """
    }

    /// docs/spec-isapi.md §10.3. `uptime` is what a reboot is detected from.
    static func status(uptime: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <DeviceStatus version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <currentDeviceTime>2024-05-01T10:00:00+00:00</currentDeviceTime>
        <deviceUpTime>\(uptime)</deviceUpTime><cpuUtilization>7</cpuUtilization>
        </DeviceStatus>
        """
    }

    /// docs/spec-isapi.md §10.2, the healthy answer.
    static let userCheckOK = """
        <?xml version="1.0" encoding="UTF-8"?>
        <userCheck version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <statusValue>200</statusValue><statusString>OK</statusString>
        </userCheck>
        """

    /// A locked account. Synthesised from the §10.2 field list.
    static let userCheckLocked = """
        <?xml version="1.0" encoding="UTF-8"?>
        <userCheck version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <statusValue>401</statusValue><statusString>lockedIpFailed</statusString>
        <lockStatus>lock</lockStatus><retryLoginTime>0</retryLoginTime>
        <unlockTime>300</unlockTime>
        </userCheck>
        """

    /// docs/spec-isapi.md §10.4. `CST-8:00:00` is the POSIX-inverted spelling of UTC+8.
    static let deviceTime = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Time version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <timeMode>NTP</timeMode><localTime>2024-05-01T18:00:00+08:00</localTime>
        <timeZone>CST-8:00:00</timeZone>
        </Time>
        """

    /// A two-stream single-channel camera — docs/spec-isapi.md §12.1, trimmed.
    static let streamingChannels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <StreamingChannelList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <StreamingChannel version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <id>101</id><channelName>Front Door</channelName><enabled>true</enabled>
        <Video><enabled>true</enabled><videoInputChannelID>1</videoInputChannelID>
        <videoCodecType>H.265</videoCodecType><videoResolutionWidth>2688</videoResolutionWidth>
        <videoResolutionHeight>1520</videoResolutionHeight>
        <videoQualityControlType>VBR</videoQualityControlType><maxFrameRate>2000</maxFrameRate>
        <vbrUpperCap>4096</vbrUpperCap></Video>
        </StreamingChannel>
        <StreamingChannel version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <id>102</id><channelName>Front Door</channelName><enabled>true</enabled>
        <Video><enabled>true</enabled><videoInputChannelID>1</videoInputChannelID>
        <videoCodecType>H.264</videoCodecType><videoResolutionWidth>640</videoResolutionWidth>
        <videoResolutionHeight>360</videoResolutionHeight>
        <videoQualityControlType>VBR</videoQualityControlType><maxFrameRate>1200</maxFrameRate>
        <vbrUpperCap>512</vbrUpperCap></Video>
        </StreamingChannel>
        </StreamingChannelList>
        """

    /// docs/spec-isapi.md §17.2's `<Color>` sample, verbatim — the namespace matters to this suite.
    static let color = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Color version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <brightnessLevel>50</brightnessLevel><contrastLevel>50</contrastLevel>
        <saturationLevel>55</saturationLevel>
        </Color>
        """

    /// A `<Sharpness>` with no level element at all — the one case the quirk casing decides.
    static let sharpnessWithoutLevel = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Sharpness version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <enabled>true</enabled>
        </Sharpness>
        """

    /// docs/spec-isapi.md §17.2's IR-cut element.
    static let ircut = """
        <?xml version="1.0" encoding="UTF-8"?>
        <IrcutFilter version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <IrcutFilterType>auto</IrcutFilterType><nightToDayFilterLevel>4</nightToDayFilterLevel>
        <nightToDayFilterTime>5</nightToDayFilterTime>
        </IrcutFilter>
        """

    /// docs/spec-isapi.md §15.2's result shape, one segment, no more pages.
    static func searchResult(strip: String = "OK", matches: Int = 1) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <CMSearchResult version="1.0" xmlns="http://www.hikvision.com/ver10/XMLSchema">
        <searchID>C0DE0000-0000-0000-0000-000000000000</searchID>
        <responseStatus>true</responseStatus><responseStatusStrip>\(strip)</responseStatusStrip>
        <numOfMatches>\(matches)</numOfMatches>
        <matchList><searchMatchItem>
        <trackID>101</trackID>
        <timeSpan><startTime>2024-05-01T09:00:00Z</startTime>
        <endTime>2024-05-01T09:10:00Z</endTime></timeSpan>
        <mediaSegmentDescriptor><contentType>video</contentType><codecType>H.265</codecType>
        <playbackURI>rtsp://10.0.0.64/Streaming/tracks/101?starttime=20240501T090000Z\
        &amp;endtime=20240501T091000Z</playbackURI></mediaSegmentDescriptor>
        <metadataMatches><metadataDescriptor>//recordType.meta.std-cgi.com/timing\
        </metadataDescriptor></metadataMatches>
        </searchMatchItem></matchList>
        </CMSearchResult>
        """
    }

    /// A refusal shaped like the one a firmware without a record-type filter sends.
    static let badParameters = ISAPIError.device(statusCode: 4,
                                                sub: ResponseStatus.SubStatus.badParameters)

    /// The monthly accelerator's answer — docs/spec-isapi.md §15.5, one recorded day.
    static let dailyDistribution = """
        <?xml version="1.0" encoding="UTF-8"?>
        <trackDailyDistribution version="1.0" xmlns="http://www.hikvision.com/ver10/XMLSchema">
        <dayList><day><id>1</id><dayOfMonth>1</dayOfMonth><record>true</record>
        <recordType>timing</recordType></day></dayList>
        </trackDailyDistribution>
        """

    /// docs/spec-isapi.md §13.9's PTZ capability document, trimmed.
    static let ptzCapabilities = """
        <?xml version="1.0" encoding="UTF-8"?>
        <PTZChanelCap version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <isSupportPreset>true</isSupportPreset><isSupportPosition3D>true</isSupportPosition3D>
        <isSupportPatrol>true</isSupportPatrol><maxPresetNum>255</maxPresetNum>
        </PTZChanelCap>
        """

    /// The `/Streaming/channels/102` answer, for the read half of a substream write.
    ///
    /// A single `<StreamingChannel>` rather than the list: that is what the per-stream resource
    /// returns, and `updateStream` reads it rather than the list so the patch is applied to the
    /// element the device would validate.
    static let substreamChannel = """
        <?xml version="1.0" encoding="UTF-8"?>
        <StreamingChannel version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <id>102</id><channelName>Front Door</channelName><enabled>true</enabled>
        <Video><enabled>true</enabled><videoInputChannelID>1</videoInputChannelID>
        <videoCodecType>H.264</videoCodecType><videoResolutionWidth>640</videoResolutionWidth>
        <videoResolutionHeight>360</videoResolutionHeight>
        <videoQualityControlType>VBR</videoQualityControlType><maxFrameRate>1200</maxFrameRate>
        <vbrUpperCap>512</vbrUpperCap></Video>
        </StreamingChannel>
        """

    /// Refuses every image sub-resource except `kept`.
    ///
    /// `RequestDouble` matches routes by **suffix**, so there is no way to express "everything under
    /// this prefix" in one route — each of the thirteen controls needs its own. Written out here
    /// rather than in each test so a new `ImageControl` case is covered automatically.
    static func refuseImageControls(_ double: RequestDouble,
                                    except kept: Set<ImageControl>) async {
        for control in ImageControl.allCases where !kept.contains(control) {
            let resource = ISAPIResource.image(.first, control)
            await double.route(resource, failing: .notFound(resource: resource))
        }
    }

    /// Builds a session over a double, on a clock the caller can advance.
    ///
    /// The `endpoint`/`credential` initialiser is deliberately not used: it would construct an
    /// `ISAPIClient`, which is a different unit with its own tests, and this suite is about the
    /// session's own decisions.
    static func session(_ requests: RequestDouble,
                        clock: SessionTestClock,
                        gate: (any QuirkApplying)? = nil,
                        quirks: DeviceQuirks = DeviceQuirks(),
                        ttl: CacheTTL = CacheTTL()) -> ISAPIDeviceSession {
        ISAPIDeviceSession(requests: requests, gate: gate, quirks: quirks, clock: clock,
                           wallClock: FixedWallClock(Date(timeIntervalSince1970: 1_714_557_600)),
                           random: SplitMix64RandomSource(seed: 0xC0DE), ttl: ttl)
    }

    /// The wall-clock instant `session(_:clock:…)` freezes at: 2024-05-01T10:00:00Z.
    static let frozenNow = Date(timeIntervalSince1970: 1_714_557_600)

    /// Midnight UTC of the frozen day, which is what makes a `dayIndex` call "today".
    static let today = Date(timeIntervalSince1970: 1_714_521_600)
}

// MARK: - Cache TTLs (§18.1)

@Suite struct DeviceSessionCacheSuite {

    @Test func deviceSessionServesDeviceInfoFromCacheUntilTheTTLExpires() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock)

        _ = try await session.deviceInfo()
        _ = try await session.deviceInfo()
        #expect(await double.requests(to: "/System/deviceInfo").count == 1)

        // One second short of 24 h is still fresh; one second past it is not.
        clock.advance(seconds: 86_399)
        _ = try await session.deviceInfo()
        #expect(await double.requests(to: "/System/deviceInfo").count == 1)
        clock.advance(seconds: 2)
        _ = try await session.deviceInfo()
        #expect(await double.requests(to: "/System/deviceInfo").count == 2)
    }

    @Test func deviceSessionForceBypassesAFreshCacheEntry() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.deviceInfo()
        _ = try await session.deviceInfo(force: true)
        #expect(await double.requests(to: "/System/deviceInfo").count == 2)
    }

    /// §18.1 keys the capability row by firmware version, so an upgrade discards it however fresh.
    @Test func deviceSessionDiscardsCapabilitiesWhenTheFirmwareVersionChanges() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo",
                           pages: [SessionFixtures.deviceInfo(firmware: "V5.5.82"),
                                   SessionFixtures.deviceInfo(firmware: "V5.6.0")])
        await double.route("/System/capabilities",
                           xml: "<DeviceCap><SysCap><isSupportPTZ>true</isSupportPTZ></SysCap>"
                              + "</DeviceCap>")
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock)

        _ = try await session.capabilities()
        #expect(await double.requests(to: "/System/capabilities").count == 1)

        // A new firmware string arrives from a forced identity re-read. The capability box is still
        // inside its 24 h, but it belongs to the old firmware and must not be served.
        _ = try await session.deviceInfo(force: true)
        _ = try await session.capabilities()
        #expect(await double.requests(to: "/System/capabilities").count == 2)
    }

    /// An uptime regression means the device rebooted, which flushes everything (§18.1).
    @Test func deviceSessionFlushesEveryCacheWhenUptimeRegresses() async throws {
        let double = RequestDouble()
        await double.route("/System/status", pages: [SessionFixtures.status(uptime: 90_000),
                                                     SessionFixtures.status(uptime: 12)])
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock)

        _ = try await session.deviceInfo()
        _ = try await session.status()
        clock.advance(seconds: 6)                    // past the 5 s status TTL
        _ = try await session.status()               // uptime dropped ⇒ flush

        _ = try await session.deviceInfo()
        #expect(await double.requests(to: "/System/deviceInfo").count == 2)
    }

    @Test func deviceSessionInvalidatesTheStreamAndChannelRowsOnAStreamWrite() async throws {
        let double = RequestDouble()
        await double.route("/Streaming/channels/102", xml: SessionFixtures.substreamChannel)
        await double.route("/Streaming/channels", xml: SessionFixtures.streamingChannels)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.channels()
        let before = await double.requests(to: "/Streaming/channels").count

        var patch = StreamingChannelPatch()
        patch.frameRate = 15
        _ = try await session.updateStream(StreamingChannelID(channel: .first, quality: .sub),
                                           patch)
        // The list must be re-read rather than served from the 30 s box the write just staled.
        _ = try await session.channels()
        #expect(await double.requests(to: "/Streaming/channels").count > before)
    }

    /// A TTL of zero is the documented way to pin a row off, and must not be read as "no TTL".
    @Test func deviceSessionTreatsAZeroTTLAsNeverFresh() async throws {
        var ttl = CacheTTL()
        ttl.deviceInfo = 0
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        let session = SessionFixtures.session(double, clock: SessionTestClock(), ttl: ttl)

        _ = try await session.deviceInfo()
        _ = try await session.deviceInfo()
        #expect(await double.requests(to: "/System/deviceInfo").count == 2)
    }
}

// MARK: - Negative capability cache (§18.3)

@Suite struct DeviceSessionNegativeCacheSuite {

    @Test func deviceSessionStopsAskingForARefusedCapability() async throws {
        let double = RequestDouble()
        await double.route("/PTZCtrl/channels/1/capabilities",
                           failing: .notSupported(resource: "/PTZCtrl/channels/1/capabilities"))
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock)

        #expect(try await session.ptzCapabilities(channel: .first).isAbsent)
        let firstCount = await double.requestCount
        #expect(firstCount == 1)

        // A different channel, whose template collapses to the same key: no round trip at all,
        // even though channel 3 has no capability box of its own. Deliberately without advancing the
        // clock — the negative entry and the capability box share a 24 h TTL, and this test is about
        // the template collapse. `deviceSessionReAsksOnceTheNegativeEntryExpires` covers expiry.
        #expect(try await session.ptzCapabilities(channel: ChannelID(3)).isAbsent)
        #expect(await double.requestCount == 1)
        #expect(await session.suppressedCapabilityTemplates
                    .contains("/PTZCtrl/channels/{n}/capabilities"))
    }

    /// The negative entry expires after 24 h so a device that was fixed is re-probed.
    @Test func deviceSessionReAsksOnceTheNegativeEntryExpires() async throws {
        let double = RequestDouble()
        await double.route("/Event/triggers", failing: .notFound(resource: "/Event/triggers"))
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock)

        _ = try? await session.eventTriggers()
        _ = try? await session.eventTriggers()
        #expect(await double.requestCount == 1)

        clock.advance(seconds: 86_401)
        _ = try? await session.eventTriggers()
        #expect(await double.requestCount == 2)
    }

    /// §18.3 scopes the cache to capability-bearing resources. These four are how Vigil finds out
    /// whether the device is reachable at all, so suppressing them would strand it.
    @Test func deviceSessionNeverSuppressesTheReachabilityTemplates() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo",
                           failing: .notFound(resource: "/System/deviceInfo"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try? await session.deviceInfo()
        _ = try? await session.deviceInfo()
        _ = try? await session.deviceInfo()
        #expect(await double.requestCount == 3)
        #expect(await session.suppressedCapabilityTemplates.isEmpty)
    }

    /// An `insufficientPermission` is about the account, not the endpoint: caching it would hide a
    /// feature from a user who then fixes their credentials and cannot work out why.
    @Test func deviceSessionDoesNotCacheAPermissionFailureAsAMissingCapability() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/record/tracks",
                           failing: .insufficientPermission(resource: "/ContentMgmt/record/tracks"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try? await session.recordTracks()
        _ = try? await session.recordTracks()
        #expect(await double.requestCount == 2)
        #expect(await session.suppressedCapabilityTemplates.isEmpty)
    }

    @Test func deviceSessionClearsNegativeEntriesOnInvalidate() async throws {
        let double = RequestDouble()
        await double.route("/Event/triggers", failing: .notFound(resource: "/Event/triggers"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try? await session.eventTriggers()
        await session.invalidateCaches()
        #expect(await session.suppressedCapabilityTemplates.isEmpty)
        _ = try? await session.eventTriggers()
        #expect(await double.requestCount == 2)
    }
}

// MARK: - Read-modify-write and the confirming re-GET (§17.1)

@Suite struct DeviceSessionReadModifyWriteSuite {

    /// The whole discipline in one assertion set: GET, PUT the *whole* element with the device's own
    /// `version` and `xmlns` echoed back, then re-GET to confirm.
    @Test func deviceSessionImageWriteIsGetThenWholeElementPutThenReGet() async throws {
        let double = RequestDouble()
        await double.route("/Image/channels/1/color", xml: SessionFixtures.color)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.setImageColor(channel: .first, brightness: 62, contrast: nil,
                                            saturation: nil)
        let traffic = await double.requests(to: "/Image/channels/1/color")
        // The setter re-reads the whole panel afterwards, so assert the first three requests:
        // the read, the whole-element write, and the confirming read.
        #expect(traffic.prefix(3).map(\.method) == ["GET", "PUT", "GET"])

        let body = try #require(traffic[1].bodyText)
        #expect(body.contains("<brightnessLevel>62</brightnessLevel>"))
        // Untouched siblings survive: a "minimal" body is what the validator rejects.
        #expect(body.contains("<contrastLevel>50</contrastLevel>"))
        #expect(body.contains("<saturationLevel>55</saturationLevel>"))
        // The echoed attributes some 5.4.x builds reject a `<Color>` without (§8, §17.2).
        #expect(body.contains("version=\"2.0\""))
        #expect(body.contains("xmlns=\"http://www.hikvision.com/ver20/XMLSchema\""))
        #expect(body.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
    }

    /// The re-GET is what makes the returned value the device's, not the caller's.
    @Test func deviceSessionImageWriteReturnsTheDevicesClampedValueNotTheRequestedOne() async throws {
        let double = RequestDouble()
        // The device answers 60 to a request for 62 — several firmwares quantise to steps of two.
        await double.route("/Image/channels/1/color",
                           pages: [SessionFixtures.color,
                                   SessionFixtures.color
                                       .replacingOccurrences(of: "<brightnessLevel>50",
                                                             with: "<brightnessLevel>60")])
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let confirmed = try await session.setImageColor(channel: .first, brightness: 62,
                                                        contrast: nil, saturation: nil)
        #expect(confirmed.brightness == 60)
    }

    /// A write must drop its cache *before* the confirming read, or the read is served from the
    /// entry the write just invalidated and the user is shown their own request back.
    @Test func deviceSessionImageWriteDoesNotServeTheConfirmationFromTheStaleCache() async throws {
        let double = RequestDouble()
        await double.route("/Image/channels/1/color", xml: SessionFixtures.color)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.imageSettings(channel: .first)
        let beforeWrite = await double.requests(to: "/Image/channels/1/color").count
        _ = try await session.setImageColor(channel: .first, brightness: 10, contrast: nil,
                                            saturation: nil)
        #expect(await double.requests(to: "/Image/channels/1/color").count > beforeWrite + 2)
    }

    /// `schedule` carries configuration Vigil does not model, so the mode is refused rather than
    /// written on its own — writing it alone would silently discard the user's schedule.
    @Test func deviceSessionRefusesAnIRCutModeItCannotExpressWithoutInventingABody() async throws {
        let double = RequestDouble()
        await double.route("/Image/channels/1/ircutFilter", xml: SessionFixtures.ircut)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        await #expect(throws: ISAPIError.self) {
            _ = try await session.setIRCut(channel: .first,
                                           IRCutSetting(mode: .schedule, nightToDayLevel: nil,
                                                        nightToDaySeconds: nil))
        }
        // Nothing was written: the refusal happens before the PUT.
        #expect(await double.requests(to: "/Image/channels/1/ircutFilter")
                    .allSatisfy { $0.method == "GET" })
    }

    /// A patch that renames the root would reach the device as a body it answers
    /// `invalidXMLContent` to, hours later, in the field. It is refused here instead.
    @Test func deviceSessionRefusesAPatchThatChangesTheRootElementName() async throws {
        let double = RequestDouble()
        await double.route("/Image/channels/1/color", xml: SessionFixtures.color)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        await #expect(throws: ISAPIError.self) {
            _ = try await session.readModifyWrite("/Image/channels/1/color") { _ in
                XMLNode(name: "Colour", text: "wrong")
            }
        }
        #expect(await double.requests(to: "/Image/channels/1/color")
                    .allSatisfy { $0.method == "GET" })
    }

    @Test func deviceSessionMotionWriteEchoesTheElementsVigilDoesNotModel() async throws {
        let double = RequestDouble()
        await double.route("/motionDetection", xml: """
            <?xml version="1.0" encoding="UTF-8"?>
            <MotionDetection version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
            <enabled>true</enabled><enableHighlight>true</enableHighlight>
            <samplingInterval>2</samplingInterval><startTriggerTime>500</startTriggerTime>
            <endTriggerTime>500</endTriggerTime>
            <regionType>grid</regionType>
            <Grid><rowGranularity>18</rowGranularity><columnGranularity>22</columnGranularity></Grid>
            <MotionDetectionLayout version="2.0"><sensitivityLevel>40</sensitivityLevel>
            <layout><gridMap>\(String(repeating: "000000", count: 18))</gridMap></layout>
            </MotionDetectionLayout>
            </MotionDetection>
            """)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.setMotionDetection(channel: .first, enabled: false,
                                                 sensitivity: 80, grid: nil)
        let traffic = await double.requests(to: "/motionDetection")
        #expect(traffic.map(\.method) == ["GET", "PUT", "GET"])
        let body = try #require(traffic[1].bodyText)
        #expect(body.contains("<enabled>false</enabled>"))
        #expect(body.contains("<sensitivityLevel>80</sensitivityLevel>"))
        #expect(body.contains("<enableHighlight>true</enableHighlight>"))
        #expect(body.contains("<startTriggerTime>500</startTriggerTime>"))
        #expect(body.contains("<rowGranularity>18</rowGranularity>"))
    }

    @Test func deviceSessionResetImageDefaultsSendsNoBodyAndDropsTheCache() async throws {
        let double = RequestDouble()
        await double.route("/Image/channels/1/color", xml: SessionFixtures.color)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.imageSettings(channel: .first)
        try await session.resetImageDefaults(channel: .first)
        let reset = await double.requests(to: "/defaultConfiguration")
        #expect(reset.count == 1)
        #expect(reset[0].method == "PUT")
        #expect(reset[0].body == nil)

        let beforeReRead = await double.requests(to: "/Image/channels/1/color").count
        _ = try await session.imageSettings(channel: .first)
        #expect(await double.requests(to: "/Image/channels/1/color").count > beforeReRead)
    }
}

// MARK: - The four quirk consultation points (§19)

@Suite struct DeviceSessionQuirkSuite {

    /// Point 1, path builder: the list form of proxied-channel status 404s on DS-76xx/77xx, and the
    /// first refusal switches the session to the per-channel form for good.
    @Test func deviceSessionFallsBackToPerChannelProxyStatusAfterTheListForm404s() async throws {
        let double = RequestDouble()
        await double.route("/InputProxy/channels/status",
                           failing: .notFound(resource: "/InputProxy/channels/status"))
        await double.route("/InputProxy/channels", xml: """
            <InputProxyChannelList><InputProxyChannel><id>1</id>
            <sourceInputPortDescriptor><ipAddress>10.0.0.65</ipAddress>
            </sourceInputPortDescriptor></InputProxyChannel></InputProxyChannelList>
            """)
        await double.route("/Streaming/channels", xml: SessionFixtures.streamingChannels)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.channels(force: true)
        #expect(await session.observedQuirks.inputProxyStatusListUnsupported)

        // The second inventory read must not try the list form again.
        let listCallsBefore = await double.requests(to: "/InputProxy/channels/status").count
        _ = try await session.channels(force: true)
        #expect(await double.requests(to: "/InputProxy/channels/status").count == listCallsBefore)
    }

    /// Point 1, path builder: the daily-distribution resource moved between firmwares, and the one
    /// that answered is remembered so the month view costs one request rather than two.
    @Test func deviceSessionRemembersWhichDailyDistributionResourceAnswered() async throws {
        let double = RequestDouble()
        await double.route("/record/tracks/dailyDistribution",
                           failing: .notFound(resource: "/record/tracks/dailyDistribution"))
        await double.route("/search/dailyDistribution", xml: SessionFixtures.dailyDistribution)
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock)

        let first = try await session.monthCalendar(track: TrackID(101), year: 2024, month: 5)
        #expect(first.days[0] != nil)
        #expect(await session.observedQuirks.dailyDistributionPath == "/ContentMgmt/search/dailyDistribution")

        clock.advance(seconds: 601)   // past the 10 min month-calendar TTL
        _ = try await session.monthCalendar(track: TrackID(101), year: 2024, month: 5)
        // The refused spelling was tried exactly once, ever.
        #expect(await double.requests(to: "/record/tracks/dailyDistribution").count == 1)
    }

    /// A device with no accelerator at all yields an all-`nil` calendar and no error: `nil` means
    /// "unknown", the date picker fills days in lazily, and an error would banner a working view.
    @Test func deviceSessionReturnsAnUnknownMonthRatherThanFailingWithoutTheAccelerator() async throws {
        let double = RequestDouble()
        await double.route("/dailyDistribution",
                           failing: .notSupported(resource: "/dailyDistribution"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let calendar = try await session.monthCalendar(track: TrackID(101), year: 2024, month: 5)
        #expect(calendar.days.allSatisfy { $0 == nil })
    }

    /// Point 1, path builder: the event-schedule resource has two spellings too.
    @Test func deviceSessionRemembersWhichEventScheduleResourceAnswered() async throws {
        let double = RequestDouble()
        await double.route("/Event/schedules/VMD-1", failing: .notFound(resource: "/Event/schedules/VMD-1"))
        await double.route("/Event/schedules", xml: """
            <EventSchedule><TimeBlockList><TimeBlock><dayOfWeek>1</dayOfWeek>
            <TimeRange><beginTime>00:00:00</beginTime><endTime>24:00:00</endTime></TimeRange>
            </TimeBlock></TimeBlockList></EventSchedule>
            """)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        #expect(try await session.eventSchedule(triggerID: "VMD-1") != nil)
        #expect(await session.observedQuirks.eventSchedulePath == "/Event/schedules")
    }

    /// Point 2, body builder: the record-type filter is dropped for good once refused, and the same
    /// search is retried unfiltered so the user still gets their timeline.
    @Test func deviceSessionRetriesARecordingSearchWithoutTheTypeFilterOnceRefused() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/search",
                           pages: [SessionFixtures.searchResult()])
        await double.route("/System/time", xml: SessionFixtures.deviceTime)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        // First: prove the filter *is* sent when nothing has refused it.
        var query = RecordSearchQuery(track: TrackID(101),
                                      start: Date(timeIntervalSince1970: 1_714_550_400),
                                      end: Date(timeIntervalSince1970: 1_714_636_800))
        query.recordTypes = [.motion]
        _ = try await session.searchRecordings(query)
        let filteredBody = try #require(await double.requests(to: "/ContentMgmt/search").first?.bodyText)
        #expect(filteredBody.contains("\(CMSearchDescription.allRecordTypes)/motion"))

        // Now teach it the refusal and prove the retry drops the filter.
        await session.learn(.recordTypeFilterRejected)
        #expect(await session.observedQuirks.recordTypeFilterUnsupported)
        let before = await double.requests(to: "/ContentMgmt/search").count
        _ = try await session.searchRecordings(query)
        let retried = await double.requests(to: "/ContentMgmt/search")
        #expect(retried.count == before + 1)
        let unfiltered = try #require(retried.last?.bodyText)
        #expect(!unfiltered.contains("\(CMSearchDescription.allRecordTypes)/motion"))
        #expect(unfiltered.contains(
            "<metadataDescriptor>\(CMSearchDescription.allRecordTypes)</metadataDescriptor>"))
    }

    /// Point 2, body builder: a `<Sharpness>` with no level element is the one case where the casing
    /// has to come from the quirk row rather than from the device's own document.
    @Test func deviceSessionWritesTheQuirkSharpnessCasingWhenTheElementIsAbsent() async throws {
        for capitalized in [true, false] {
            let double = RequestDouble()
            await double.route("/sharpness", xml: SessionFixtures.sharpnessWithoutLevel)
            var quirks = DeviceQuirks()
            quirks.sharpnessElementIsCapitalized = capitalized
            let session = SessionFixtures.session(double, clock: SessionTestClock(), quirks: quirks)

            _ = try await session.setSharpness(channel: .first, 80)
            let put = try #require(await double.requests(to: "/sharpness")
                                        .first { $0.method == "PUT" }?.bodyText)
            let expected = capitalized ? "<SharpnessLevel>80</SharpnessLevel>"
                                       : "<sharpnessLevel>80</sharpnessLevel>"
            #expect(put.contains(expected))
            // The element the device did send survives either way.
            #expect(put.contains("<enabled>true</enabled>"))
        }
    }

    /// Point 3, response interpretation: several DVRs read `starttime` as device-local despite the
    /// `Z`, so the window goes out shifted and the answers come back shifted the other way.
    @Test func deviceSessionShiftsThePlaybackWindowForDeviceLocalFirmware() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/search", xml: SessionFixtures.searchResult())
        await double.route("/System/time", xml: SessionFixtures.deviceTime)   // UTC+8
        var quirks = DeviceQuirks()
        quirks.playbackTimesAreDeviceLocal = true
        let session = SessionFixtures.session(double, clock: SessionTestClock(), quirks: quirks)

        let start = Date(timeIntervalSince1970: 1_714_550_400)   // 2024-05-01T08:00:00Z
        let segments = try await session.searchRecordings(
            RecordSearchQuery(track: TrackID(101), start: start,
                              end: start.addingTimeInterval(3_600)))
        // Out: the request carries the window shifted forward by the device's +8 h offset, so the
        // device's own local reading lands on the instant the user asked for.
        let body = try #require(await double.requests(to: "/ContentMgmt/search").first?.bodyText)
        #expect(body.contains("2024-05-01T16:00:00Z"))
        // Back: the echoed device-local times are shifted back before anything compares them.
        let segment = try #require(segments.first)
        #expect(segment.start == Date(timeIntervalSince1970: 1_714_525_200))   // 09:00Z −8 h = 01:00Z
    }

    /// Point 4, the request gate: three `deviceBusy` answers inside ten seconds drop the device to
    /// two concurrent control requests, and the gate is told immediately.
    @Test func deviceSessionPushesTheConcurrencyOverrideAtTheGateAfterThreeBusyAnswers() async throws {
        let double = RequestDouble()
        await double.route("/System/status", failing: .deviceBusy)
        let gate = SessionGateDouble()
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock, gate: gate)

        for _ in 0..<3 {
            _ = try? await session.status()
            clock.advance(seconds: 1)
        }
        #expect(await session.observedQuirks.maxConcurrentRequestsOverride == 2)
        let applied = await gate.applied
        #expect(applied.last?.maxConcurrentRequestsOverride == 2)
        // One push, not three: `observe` reports "changed" only for the observation that changed it.
        #expect(applied.count == 1)
    }

    /// The record describes the firmware, not the session, so a cache flush must not discard it —
    /// re-learning it costs the user real round trips.
    @Test func deviceSessionKeepsTheQuirkRecordAcrossACacheInvalidation() async throws {
        let double = RequestDouble()
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        await session.learn(.streamingChannelIDRejected)
        await session.invalidateCaches()
        #expect(await session.observedQuirks.streamingChannelIDIsSingleDigit)
    }

    /// The `position3D` Y origin cannot be read or seeded; the §13.5 calibration is its only source.
    @Test func deviceSessionLearnsThePosition3DOriginFromACalibration() async throws {
        let session = SessionFixtures.session(RequestDouble(), clock: SessionTestClock())

        #expect(await session.position3DOriginIsTopLeft == false)
        await session.calibratePosition3DOrigin(topLeft: true)
        #expect(await session.position3DOriginIsTopLeft)
        #expect(await session.observedQuirks.ptz3DOriginIsTopLeft == true)
    }
}

// MARK: - Playback

@Suite struct DeviceSessionPlaybackSuite {

    /// Today's index is still being written to, so it expires; a past day cannot change, so it does
    /// not (§18.1). That asymmetry is what lets the timeline be scrubbed backwards for free.
    @Test func deviceSessionCachesAPastDayIndexForeverAndTodaysForSixtySeconds() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/search", xml: SessionFixtures.searchResult())
        await double.route("/System/time", xml: SessionFixtures.deviceTime)
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock)
        let past = SessionFixtures.today.addingTimeInterval(-86_400)

        _ = try await session.dayIndex(track: TrackID(101), dayStartUTC: past)
        let afterFirst = await double.requests(to: "/ContentMgmt/search").count
        clock.advance(seconds: 100_000)
        _ = try await session.dayIndex(track: TrackID(101), dayStartUTC: past)
        #expect(await double.requests(to: "/ContentMgmt/search").count == afterFirst)

        _ = try await session.dayIndex(track: TrackID(101), dayStartUTC: SessionFixtures.today)
        let afterToday = await double.requests(to: "/ContentMgmt/search").count
        clock.advance(seconds: 61)
        _ = try await session.dayIndex(track: TrackID(101), dayStartUTC: SessionFixtures.today)
        #expect(await double.requests(to: "/ContentMgmt/search").count == afterToday + 1)
    }

    /// One `searchID` for the whole search, and `searchResultPostion` advanced by the device's own
    /// match count — Hikvision's spelling, kept verbatim because the corrected one is ignored.
    @Test func deviceSessionPagesARecordingSearchWhileTheDeviceSaysMore() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/search",
                           pages: [SessionFixtures.searchResult(strip: "MORE", matches: 1),
                                   SessionFixtures.searchResult(strip: "OK", matches: 1)])
        await double.route("/System/time", xml: SessionFixtures.deviceTime)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let segments = try await session.searchRecordings(
            RecordSearchQuery(track: TrackID(101),
                              start: Date(timeIntervalSince1970: 1_714_550_400),
                              end: Date(timeIntervalSince1970: 1_714_636_800)))
        let pages = await double.requests(to: "/ContentMgmt/search")
        #expect(pages.count == 2)
        #expect(segments.count == 2)

        // Both pages carried the same searchID; the second advanced the cursor.
        let first = try #require(pages[0].bodyText)
        let second = try #require(pages[1].bodyText)
        #expect(first.contains("<searchResultPostion>0</searchResultPostion>"))
        #expect(second.contains("<searchResultPostion>1</searchResultPostion>"))
        let id = try #require(first.split(separator: "<searchID>").last?
                                  .split(separator: "</searchID>").first)
        #expect(second.contains("<searchID>\(id)</searchID>"))
    }

    /// A device that answers `MORE` for ever must not hold the actor open until the app quits.
    @Test func deviceSessionAbandonsASearchThatNeverStopsSayingMore() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/search",
                           xml: SessionFixtures.searchResult(strip: "MORE", matches: 1))
        await double.route("/System/time", xml: SessionFixtures.deviceTime)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.searchRecordings(
            RecordSearchQuery(track: TrackID(101),
                              start: Date(timeIntervalSince1970: 1_714_550_400),
                              end: Date(timeIntervalSince1970: 1_714_636_800)))
        #expect(await double.requests(to: "/ContentMgmt/search").count
                    == ISAPIDeviceSession.maximumSearchPages)
    }

    /// The quota sub-resource is advisory: a device without it still has volumes, and failing the
    /// whole call would hide the free-space readout the user came for.
    @Test func deviceSessionMergesStorageQuotasButToleratesTheirAbsence() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/Storage/quota",
                           failing: .notFound(resource: "/ContentMgmt/Storage/quota"))
        await double.route("/ContentMgmt/Storage", xml: """
            <storage version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
            <hddList><hdd><id>1</id><hddName>hdde</hddName><capacity>3815447</capacity>
            <freeSpace>1048576</freeSpace><status>ok</status></hdd></hddList>
            <workMode>quota</workMode></storage>
            """)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let info = try await session.storage()
        #expect(info.volumes.count == 1)
        #expect(info.quotas.isEmpty)
    }
}

// MARK: - PTZ, events, audio, image

@Suite struct DeviceSessionFeatureSuite {

    /// One controller per channel and never one per gesture: the keep-alive and the triple
    /// zero-stop are per-channel state, and two controllers would race a held joystick.
    @Test func deviceSessionMemoisesOnePTZControllerPerChannel() async throws {
        let double = RequestDouble()
        await double.route("/PTZCtrl/channels/1/capabilities", xml: SessionFixtures.ptzCapabilities)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let first = try await session.ptzController(channel: .first)
        let second = try await session.ptzController(channel: .first)
        #expect(first === second)
        #expect(await double.requests(to: "/capabilities").count == 1)
    }

    @Test func deviceSessionRefusesAPTZControllerForAChannelWithoutPTZ() async throws {
        let double = RequestDouble()
        await double.route("/PTZCtrl/channels/1/capabilities",
                           failing: .notSupported(resource: "/PTZCtrl/channels/1/capabilities"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        await #expect(throws: ISAPIError.self) {
            _ = try await session.ptzController(channel: .first)
        }
    }

    /// Exactly one alert-stream monitor per device (API_CONTRACT §2 R-28): the device multiplexes
    /// every channel onto one response, and a second one exhausts its HTTP worker pool.
    @Test func deviceSessionMemoisesOneAlertStreamMonitorPerDevice() async throws {
        let session = SessionFixtures.session(RequestDouble(), clock: SessionTestClock())

        let first = await session.alertStream()
        let second = await session.alertStream()
        #expect(first === second)
    }

    /// A `403`/`404` on one image sub-resource means the control does not exist, which is what the
    /// panel needs in order to show only the sliders that will work.
    @Test func deviceSessionReportsOnlyTheImageControlsTheDeviceAnswered() async throws {
        let double = RequestDouble()
        await double.route("/Image/channels/1/color", xml: SessionFixtures.color)
        await double.route("/Image/channels/1/ircutFilter", xml: SessionFixtures.ircut)
        // Everything else is refused, which is the common case on a fixed camera.
        await SessionFixtures.refuseImageControls(double, except: [.color, .ircut])
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let settings = try await session.imageSettings(channel: .first)
        #expect(settings.available == [.color, .ircut])
        #expect(settings.brightness == 50)
        #expect(settings.irCut?.mode == .auto)
    }

    /// A device that refuses all thirteen is a normal camera without image controls, not an error.
    @Test func deviceSessionReturnsEmptyImageSettingsWhenEveryControlIsRefused() async throws {
        let double = RequestDouble()
        await SessionFixtures.refuseImageControls(double, except: [])
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        #expect(try await session.imageSettings(channel: .first).available.isEmpty)
    }

    /// A channel that advertises nothing Vigil can encode must not open a session that sends static.
    @Test func deviceSessionRefusesTwoWayAudioWithNoSharedCodec() async throws {
        let double = RequestDouble()
        await double.route("/System/TwoWayAudio/channels", xml: """
            <TwoWayAudioChannelList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
            <TwoWayAudioChannel><id>1</id><enabled>true</enabled>
            <audioCompressionType>G.722.1</audioCompressionType>
            <audioInputType>MicIn</audioInputType></TwoWayAudioChannel>
            </TwoWayAudioChannelList>
            """)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        await #expect(throws: ISAPIError.self) {
            _ = try await session.openTwoWayAudio(channel: 1)
        }
    }

    /// A camera left panning after the app quits is the one failure a user cannot undo from inside
    /// Vigil, so PTZ is stopped first and unconditionally.
    @Test func deviceSessionShutdownStopsPTZAndTheAlertStreamAndFlushesCaches() async throws {
        let double = RequestDouble()
        await double.route("/PTZCtrl/channels/1/capabilities", xml: SessionFixtures.ptzCapabilities)
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.ptzController(channel: .first)
        _ = await session.alertStream()
        _ = try await session.deviceInfo()
        await session.shutdown()

        // A `continuous` stop was written for the controller that existed.
        #expect(await !double.requests(to: "/continuous").isEmpty)
        // And the identity cache is gone, so the next read hits the device.
        _ = try await session.deviceInfo()
        #expect(await double.requests(to: "/System/deviceInfo").count == 2)
    }
}

// MARK: - Connect sequence (§18.2)

@Suite struct DeviceSessionConnectSuite {

    /// A route table for a healthy single-channel camera. Everything not listed is refused by the
    /// last route, which is how a real camera answers most of the optional steps.
    static func healthyCamera() async -> RequestDouble {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        await double.route("/Security/userCheck", xml: SessionFixtures.userCheckOK)
        await double.route("/System/time", xml: SessionFixtures.deviceTime)
        await double.route("/System/capabilities", xml: """
            <DeviceCap version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
            <SysCap><isSupportPTZ>true</isSupportPTZ><isSupportTwoWayAudio>true\
            </isSupportTwoWayAudio></SysCap>
            <RacmCap><isSupportSearch>true</isSupportSearch></RacmCap>
            </DeviceCap>
            """)
        await double.route("/Streaming/channels", xml: SessionFixtures.streamingChannels)
        await double.route("/PTZCtrl/channels/1/capabilities", xml: SessionFixtures.ptzCapabilities)
        return double
    }

    @Test func connectSequenceEstablishesIdentityChannelsAndPTZ() async throws {
        let double = await Self.healthyCamera()
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.identity.model == "DS-2CD2385FWD-I")
        #expect(outcome.credentials.ok)
        #expect(outcome.channels.count == 1)
        #expect(outcome.canStream)
        #expect(outcome.time?.utcOffsetSeconds == 28_800)
        #expect(outcome.ptzChannels == [.first])
        #expect(!outcome.degradations.contains(.ptzUnavailable))
        #expect(!outcome.exceededBudget)
    }

    /// Step 1 is the "is this even an ISAPI device" test, and its failure aborts the sequence
    /// before a single credential is sent anywhere else.
    @Test func connectSequenceAbortsWhenTheIdentityEndpointIsAbsent() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo",
                           failing: .notFound(resource: "/System/deviceInfo"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        await #expect(throws: ISAPIError.self) { _ = try await session.connect() }
        #expect(await double.requests(to: "/Security/userCheck").isEmpty)
    }

    /// Step 2 aborts on a lock, and the one thing the caller must not do is retry — each retry
    /// extends the lock-out. Throwing rather than returning is what makes that hard to get wrong.
    @Test func connectSequenceAbortsOnALockedAccountWithoutProbingAnything() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        await double.route("/Security/userCheck", xml: SessionFixtures.userCheckLocked)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        await #expect(throws: ISAPIError.accountLocked(retryAfter: 300)) {
            _ = try await session.connect()
        }
        #expect(await double.requests(to: "/System/capabilities").isEmpty)
        #expect(await double.requests(to: "/Streaming/channels").isEmpty)
    }

    /// Step 4's failure is fatal for streaming but not for the connection: channel 1 is synthesised,
    /// because an empty camera list is a worse answer than an optimistic one that fails visibly.
    @Test func connectSequenceSynthesisesChannelOneWhenTheStreamListFails() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        await double.route("/Security/userCheck", xml: SessionFixtures.userCheckOK)
        await double.route("/Streaming/channels",
                           failing: .notFound(resource: "/Streaming/channels"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.channels.count == 1)
        #expect(outcome.channels[0].channel == .first)
        #expect(outcome.degradations.contains(.channelListSynthesised))
        #expect(outcome.canStream)
    }

    /// Step 3's failure is not an error: the family defaults stand in and step 7 settles the rest.
    @Test func connectSequenceFallsBackToFamilyDefaultsWhenCapabilitiesAreAbsent() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        await double.route("/Security/userCheck", xml: SessionFixtures.userCheckOK)
        await double.route("/System/capabilities",
                           failing: .notFound(resource: "/System/capabilities"))
        await double.route("/Streaming/channels", xml: SessionFixtures.streamingChannels)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.capabilities.videoInputChannels >= 1)
        // `capabilities()` absorbs its own failure into the family defaults, so the sequence sees a
        // usable record and the degradation that matters is the one the probes could not settle.
        #expect(!outcome.degradations.contains(.budgetExceeded))
    }

    /// Step 7 probes only the rows `/System/capabilities` left unresolved — probing a row the device
    /// already answered is a wasted round trip on hardware whose ceiling is three of them.
    @Test func connectSequenceProbesOnlyTheUnresolvedCapabilityRows() async throws {
        let double = await Self.healthyCamera()
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        // `isSupportPTZ` was in the document, so no functional probe was needed for it beyond the
        // per-channel capability read step 8 does anyway.
        #expect(outcome.capabilities.supportsPTZ)
        #expect(!outcome.capabilities.unresolved.contains(.supportsPTZ))
        // A row the document did not mention and that has a probe is now resolved either way.
        #expect(!outcome.capabilities.unresolved.contains(.supportsImageColor))
        // A row that cannot be probed at all stays honest about not being known.
        #expect(outcome.capabilities.unresolved.contains(.supportsHTTPS))
    }

    /// A refusal during a probe resolves the row `false` *and* lands in the negative cache, so the
    /// feature behind it costs no round trip for the next 24 h.
    @Test func connectSequenceRecordsProbeRefusalsInTheNegativeCache() async throws {
        let double = await Self.healthyCamera()
        await double.route("/Image/channels/1/color",
                           failing: .notSupported(resource: "/Image/channels/1/color"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.capabilities.supportsImageColor == false)
        #expect(await session.suppressedCapabilityTemplates.contains("/Image/channels/{n}/color"))
    }

    @Test func connectSequenceReportsPTZUnavailableWhenNoChannelHasIt() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        await double.route("/Security/userCheck", xml: SessionFixtures.userCheckOK)
        await double.route("/Streaming/channels", xml: SessionFixtures.streamingChannels)
        await double.route("/PTZCtrl/channels/1/capabilities",
                           failing: .notSupported(resource: "/PTZCtrl/channels/1/capabilities"))
        await double.route("/PTZCtrl/channels",
                           failing: .notSupported(resource: "/PTZCtrl/channels"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.ptzChannels.isEmpty)
        #expect(outcome.degradations.contains(.ptzUnavailable))
        // The connection itself is fine — a fixed camera is still a camera.
        #expect(outcome.canStream)
    }

    @Test func connectSequenceReportsPlaybackUnavailableWithNoTracksOrStorage() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        await double.route("/Security/userCheck", xml: SessionFixtures.userCheckOK)
        await double.route("/Streaming/channels", xml: SessionFixtures.streamingChannels)
        await double.route("/ContentMgmt/record/tracks",
                           failing: .notFound(resource: "/ContentMgmt/record/tracks"))
        await double.route("/ContentMgmt/Storage",
                           failing: .notFound(resource: "/ContentMgmt/Storage"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.recordTracks.isEmpty)
        #expect(outcome.storage == nil)
        #expect(outcome.degradations.contains(.playbackUnavailable))
    }

    /// The budget is checked between steps, so a device that has already burned it gets steps 1–6
    /// and nothing optional. What did not run is re-probed lazily on first use.
    @Test func connectSequenceSkipsTheOptionalStepsOnceTheBudgetIsSpent() async throws {
        let double = await Self.healthyCamera()
        let session = ISAPIDeviceSession(
            requests: double, clock: SessionBurningClock(perReadingSeconds: 13),
            wallClock: FixedWallClock(SessionFixtures.frozenNow),
            random: SplitMix64RandomSource(seed: 1))

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.exceededBudget)
        // The elapsed reading is the injected clock's, so a clock that moves reports movement while
        // the frozen one reports zero — see `connectSequenceMeasuresElapsedTimeOnTheInjectedClock`.
        #expect(outcome.elapsedSeconds > 0)
        #expect(outcome.degradations.contains(.budgetExceeded))
        // Steps 1–4 still landed, which is what the first tile needs.
        #expect(outcome.canStream)
        #expect(outcome.ptzChannels.isEmpty)
    }

    /// The elapsed reading comes off the injected clock, so this measures the sequence rather than
    /// the machine it runs on.
    @Test func connectSequenceMeasuresElapsedTimeOnTheInjectedClock() async throws {
        let double = await Self.healthyCamera()
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.elapsedSeconds == 0)
    }

    /// Step 10 is skipped, and the degradation recorded, when the device says it has no alert
    /// stream — starting a monitor that will only ever 403 would put a red banner on a healthy
    /// camera.
    @Test func connectSequenceSkipsTheAlertStreamWhenTheDeviceHasNone() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        await double.route("/Security/userCheck", xml: SessionFixtures.userCheckOK)
        await double.route("/Streaming/channels", xml: SessionFixtures.streamingChannels)
        await double.route("/System/capabilities", xml: """
            <DeviceCap version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
            <EventCap><isSupportAlertStream>false</isSupportAlertStream></EventCap></DeviceCap>
            """)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        // `startingAlertStream: true` — the documented sequence. The device's own answer is what
        // suppresses step 10, not the caller.
        let outcome = try await session.connect()
        #expect(outcome.capabilities.supportsAlertStream == false)
        #expect(outcome.degradations.contains(.alertStreamUnavailable))
        #expect(await double.requests(to: "/alertStream").isEmpty)
    }

    /// The quirk record the sequence hands back is what `VigilCore` persists on the camera row.
    @Test func connectSequenceReturnsTheQuirkRecordItLearned() async throws {
        let double = await Self.healthyCamera()
        await double.route("/InputProxy/channels/status",
                           failing: .notFound(resource: "/InputProxy/channels/status"))
        await double.route("/InputProxy/channels", xml: """
            <InputProxyChannelList><InputProxyChannel><id>1</id></InputProxyChannel>
            </InputProxyChannelList>
            """)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.quirks.inputProxyStatusListUnsupported)
        // Seeded from the firmware, not observed: 5.5.x sends the declaration in every body.
        #expect(outcome.quirks.requiresXMLDeclarationInBody)
    }
}

// MARK: - Namespace preservation (§8, §17.2)

@Suite struct ISAPIDocumentNamespaceSuite {

    /// The defect this suite exists for: the parser used to drop every `xmlns*` attribute, so no
    /// read-modify-write body Vigil sent could carry the namespace that §8 and §17.2 require and
    /// that some 5.4.x builds reject a `<Color>` without.
    @Test func isapiDocumentNamespacePreservesTheDefaultDeclaration() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <Color version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">\
            <brightnessLevel>50</brightnessLevel></Color>
            """.utf8))
        #expect(document.root.attributes["xmlns"] == "http://www.hikvision.com/ver20/XMLSchema")
        #expect(document["@xmlns"].string == "http://www.hikvision.com/ver20/XMLSchema")
    }

    /// A prefixed declaration keeps its **whole** name. Reducing `xmlns:hik` to `hik` — which is
    /// what prefix-stripping would do — writes back an attribute the device never sent and loses
    /// the declaration entirely.
    @Test func isapiDocumentNamespacePreservesAPrefixedDeclarationVerbatim() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <Color xmlns:hik="http://www.hikvision.com/ver20/XMLSchema" version="2.0">\
            <brightnessLevel>50</brightnessLevel></Color>
            """.utf8))
        #expect(document.root.attributes["xmlns:hik"] == "http://www.hikvision.com/ver20/XMLSchema")
        #expect(document.root.attributes["hik"] == nil)
        let text = String(decoding: document.root.serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("xmlns:hik=\"http://www.hikvision.com/ver20/XMLSchema\""))
    }

    /// Prefix-stripping on *names* is deliberate and must survive the fix: it is what keeps every
    /// path expression in this module namespace-agnostic.
    @Test func isapiDocumentNamespaceStillStripsPrefixesFromNames() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <hik:Color xmlns:hik="http://www.hikvision.com/ver20/XMLSchema" hik:version="2.0">\
            <hik:brightnessLevel>50</hik:brightnessLevel></hik:Color>
            """.utf8))
        #expect(document.rootName == "Color")
        #expect(document["brightnessLevel"].int == 50)
        // The prefix came off the ordinary attribute's name, and its lowercased local name is what
        // an `@attr` path matches.
        #expect(document["@version"].string == "2.0")
        // The declaration did not lose its prefix.
        #expect(document.root.attributes["xmlns:hik"] != nil)
    }

    /// `xmlnsfoo` is an ordinary attribute, not a declaration. The old `hasPrefix("xmlns")` test
    /// swallowed it; the exact rule does not.
    @Test func isapiDocumentNamespaceKeepsAnAttributeThatMerelyStartsWithXmlns() throws {
        let document = try ISAPIDocument(parsing: Data(
            "<Color xmlnsExtra=\"7\"><brightnessLevel>50</brightnessLevel></Color>".utf8))
        #expect(document.root.attributes["xmlnsextra"] == "7")
    }

    /// End to end: a `<Color>` read from the device and patched comes back out with both attributes
    /// the spec sample shows, in the spec sample's order.
    @Test func isapiDocumentNamespaceRoundTripsThroughAReadModifyWriteBody() throws {
        let document = try ISAPIDocument(parsing: Data(SessionFixtures.color.utf8))
        let patched = ImageWrite.color(document.root, brightness: 62, contrast: nil,
                                       saturation: nil)
        let text = String(decoding: patched.serialized(), as: UTF8.self)
        #expect(text.contains("<Color version=\"2.0\" "
                              + "xmlns=\"http://www.hikvision.com/ver20/XMLSchema\">"))
        #expect(text.contains("<brightnessLevel>62</brightnessLevel>"))
        // And it still parses, which is the only thing the device actually cares about.
        let reparsed = try ISAPIDocument(parsing: patched.serialized())
        #expect(reparsed["brightnessLevel"].int == 62)
        #expect(reparsed["@xmlns"].string == "http://www.hikvision.com/ver20/XMLSchema")
    }
}
