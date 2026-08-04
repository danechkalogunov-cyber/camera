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
    /// this prefix" in one route — each of the fourteen controls needs its own. Written out here
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
