//
//  DeviceIdentityTests.swift
//  VigilISAPITests
//
//  `deviceInfo`, `userCheck`, `status`, `time`, `capabilities`, network interfaces and users, all
//  against the bodies printed in docs/spec-isapi.md §10 and §17.4.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - Fixtures

enum IdentityFixtures {

    /// docs/spec-isapi.md §10.1, verbatim.
    static let cameraDeviceInfo = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DeviceInfo version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <deviceName>Front Door</deviceName>
          <deviceID>48343131-3435-3234-3138-343131343535</deviceID>
          <deviceDescription>IPCamera</deviceDescription>
          <deviceLocation>hangzhou</deviceLocation>
          <systemContact>Hikvision.China</systemContact>
          <model>DS-2CD2385FWD-I</model>
          <serialNumber>DS-2CD2385FWD-I20200114AAWR123456789</serialNumber>
          <macAddress>44:47:cc:11:22:33</macAddress>
          <firmwareVersion>V5.6.3</firmwareVersion>
          <firmwareReleasedDate>build 190923</firmwareReleasedDate>
          <encoderVersion>V7.3</encoderVersion>
          <encoderReleasedDate>build 190103</encoderReleasedDate>
          <bootVersion>V1.3.4</bootVersion>
          <bootReleasedDate>100316</bootReleasedDate>
          <hardwareVersion>0x0</hardwareVersion>
          <deviceType>IPCamera</deviceType>
          <telecontrolID>88</telecontrolID>
          <supportBeep>false</supportBeep>
          <supportVideoLoss>false</supportVideoLoss>
          <firmwareVersionInfo>B-R-G3-0</firmwareVersionInfo>
        </DeviceInfo>
        """

    /// The DVR variant described in docs/spec-isapi.md §10.1.
    static let recorderDeviceInfo = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DeviceInfo version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <deviceName>Embedded Net DVR</deviceName>
          <model>DS-7608NI-K2</model>
          <serialNumber>DS-7608NI-K2/8P1620190101CCWR000000001WCVU</serialNumber>
          <macAddress>44:47:cc:aa:bb:cc</macAddress>
          <firmwareVersion>V4.30.005</firmwareVersion>
          <firmwareReleasedDate>build 200323</firmwareReleasedDate>
          <deviceType>NVR</deviceType>
          <supportBeep>true</supportBeep>
          <supportVideoLoss>true</supportVideoLoss>
        </DeviceInfo>
        """

    /// docs/spec-isapi.md §10.2, the success body.
    static let userCheckOK = """
        <?xml version="1.0" encoding="UTF-8"?>
        <userCheck version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <statusValue>200</statusValue>
          <statusString>OK</statusString>
        </userCheck>
        """

    /// docs/spec-isapi.md §10.2, the wrong-password body.
    static let userCheckWrong = """
        <?xml version="1.0" encoding="UTF-8"?>
        <userCheck version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <statusValue>401</statusValue>
          <statusString>Unauthorized</statusString>
          <isIllegalLogin>true</isIllegalLogin>
          <retryLoginTime>3</retryLoginTime>
          <lockStatus>unlock</lockStatus>
          <unlockTime>0</unlockTime>
        </userCheck>
        """

    /// docs/spec-isapi.md §10.2, the locked body.
    static let userCheckLocked = """
        <userCheck version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <statusValue>401</statusValue>
          <statusString>Unauthorized</statusString>
          <isIllegalLogin>true</isIllegalLogin>
          <retryLoginTime>0</retryLoginTime>
          <lockStatus>lock</lockStatus>
          <unlockTime>1737</unlockTime>
        </userCheck>
        """

    /// docs/spec-isapi.md §10.3.
    static let systemStatus = """
        <DeviceStatus version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <currentDeviceTime>2024-05-01T12:34:56</currentDeviceTime>
          <deviceUpTime>987654</deviceUpTime>
          <deviceStatus>ok</deviceStatus>
          <CPUList>
            <CPU><cpuDescription>cpu</cpuDescription><cpuUtilization>17</cpuUtilization></CPU>
          </CPUList>
          <MemoryList>
            <Memory>
              <memoryDescription>DDR</memoryDescription>
              <memoryUsage>117.34</memoryUsage>
              <memoryAvailable>72.65</memoryAvailable>
            </Memory>
          </MemoryList>
          <openFileHandles>63</openFileHandles>
        </DeviceStatus>
        """

    /// docs/spec-isapi.md §10.4.
    static let systemTime = """
        <Time version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <timeMode>NTP</timeMode>
          <localTime>2024-05-01T12:34:56+08:00</localTime>
          <timeZone>CST-8:00:00</timeZone>
        </Time>
        """

    /// docs/spec-isapi.md §10.5, abbreviated exactly as printed there.
    static let capabilities = """
        <DeviceCap version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <SysCap>
            <isSupportHttps>true</isSupportHttps>
            <networkNo>1</networkNo>
            <serialNo>0</serialNo>
            <videoInNo>1</videoInNo>
            <audioInNo>1</audioInNo>
            <videoOutNo>0</videoOutNo>
            <audioOutNo>1</audioOutNo>
            <alarmInNo>1</alarmInNo>
            <alarmOutNo>1</alarmOutNo>
            <isSupportPTZ>false</isSupportPTZ>
            <isSupportTwoWayAudio>true</isSupportTwoWayAudio>
            <isSupportRedirectHttpToHttps>false</isSupportRedirectHttpToHttps>
            <SupportStreamingChannelNums>3</SupportStreamingChannelNums>
            <IOCap><IOInputPortNums>1</IOInputPortNums><IOOutputPortNums>1</IOOutputPortNums></IOCap>
          </SysCap>
          <VideoCap>
            <isSupportSmartCodec>true</isSupportSmartCodec>
            <videoInputChannelNums>1</videoInputChannelNums>
          </VideoCap>
          <AudioCap><audioInputChannelNums>1</audioInputChannelNums></AudioCap>
          <EventCap>
            <isSupportMotionDetection>true</isSupportMotionDetection>
            <isSupportLineDetection>true</isSupportLineDetection>
            <isSupportFieldDetection>true</isSupportFieldDetection>
            <isSupportRegionEntrance>true</isSupportRegionEntrance>
            <isSupportTamperDetection>true</isSupportTamperDetection>
            <isSupportFaceDetection>false</isSupportFaceDetection>
          </EventCap>
        </DeviceCap>
        """

    /// docs/spec-isapi.md §10.6.
    static let networkInterfaces = """
        <NetworkInterfaceList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <NetworkInterface version="2.0">
            <id>1</id>
            <IPAddress version="2.0">
              <ipVersion>dual</ipVersion>
              <addressingType>static</addressingType>
              <ipAddress>192.168.1.64</ipAddress>
              <subnetMask>255.255.255.0</subnetMask>
              <ipv6Address>::</ipv6Address>
              <bitMask>0</bitMask>
              <DefaultGateway><ipAddress>192.168.1.1</ipAddress></DefaultGateway>
              <PrimaryDNS><ipAddress>192.168.1.1</ipAddress></PrimaryDNS>
              <SecondaryDNS><ipAddress>8.8.8.8</ipAddress></SecondaryDNS>
            </IPAddress>
            <Link>
              <MACAddress>44:47:cc:11:22:33</MACAddress>
              <autoNegotiation>true</autoNegotiation>
              <speed>100</speed>
              <duplex>full</duplex>
              <MTU>1500</MTU>
            </Link>
          </NetworkInterface>
        </NetworkInterfaceList>
        """

    /// docs/spec-isapi.md §17.4.
    static let users = """
        <UserList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <User version="2.0">
            <id>1</id>
            <userName>admin</userName>
            <userLevel>Administrator</userLevel>
          </User>
          <User version="2.0">
            <id>2</id>
            <userName>viewer</userName>
            <userLevel>Operator</userLevel>
            <bondIpAddressList/>
            <bondMacAddressList/>
          </User>
        </UserList>
        """

    static func document(_ xml: String) throws -> ISAPIDocument {
        try ISAPIDocument(parsing: Data(xml.utf8))
    }
}

// MARK: - DeviceInfoSuite

@Suite struct DeviceInfoSuite {

    @Test func deviceInfoDecodesTheCameraFixture() throws {
        let info = try DeviceInfo(document: IdentityFixtures.document(
            IdentityFixtures.cameraDeviceInfo))
        #expect(info.deviceName == "Front Door")
        #expect(info.model == "DS-2CD2385FWD-I")
        #expect(info.serialNumber == "DS-2CD2385FWD-I20200114AAWR123456789")
        #expect(info.macAddress == "44:47:cc:11:22:33")
        #expect(info.deviceID == "48343131-3435-3234-3138-343131343535")
        #expect(info.hardwareVersion == "0x0")
        #expect(info.deviceType == "IPCamera")
        #expect(info.family == .ipCamera)
        #expect(info.supportsBeep == false)
        #expect(info.supportsVideoLoss == false)
        #expect(info.firmwareVersion.major == 5)
        #expect(info.firmwareVersion.minor == 6)
        #expect(info.firmwareVersion.patch == 3)
        #expect(info.firmwareVersion.raw == "V5.6.3")
    }

    @Test func deviceInfoDecodesTheRecorderFixture() throws {
        let info = try DeviceInfo(document: IdentityFixtures.document(
            IdentityFixtures.recorderDeviceInfo))
        #expect(info.family == .nvr)
        #expect(info.family.isRecorder)
        #expect(info.supportsVideoLoss)
        #expect(info.firmwareVersion.major == 4)
        #expect(info.firmwareVersion.minor == 30)
        #expect(info.firmwareVersion.patch == 5)
    }

    @Test func deviceInfoRequiresAModel() throws {
        let xml = "<DeviceInfo><deviceName>Nameless</deviceName></DeviceInfo>"
        #expect(throws: ISAPIError.self) {
            try DeviceInfo(document: IdentityFixtures.document(xml))
        }
    }

    @Test func deviceInfoFallsBackToTheModelForAMissingName() throws {
        let xml = "<DeviceInfo><model>DS-2CD1023G0E-I</model></DeviceInfo>"
        let info = try DeviceInfo(document: IdentityFixtures.document(xml))
        #expect(info.deviceName == "DS-2CD1023G0E-I")
        #expect(info.serialNumber.isEmpty)
        #expect(info.family == .unknown)
    }

    @Test func deviceFamilyFollowsTheDocumentedOrder() {
        // docs/spec-isapi.md §10.1's table, one row at a time, first match winning.
        #expect(DeviceFamily.infer(deviceType: "NVR", model: "DS-7608NI-K2") == .nvr)
        #expect(DeviceFamily.infer(deviceType: "Hybrid DVR", model: "DS-7204HQHI") == .hybridDVR)
        #expect(DeviceFamily.infer(deviceType: "DVR", model: "DS-7204HQHI") == .dvr)
        #expect(DeviceFamily.infer(deviceType: "", model: "DS-7716NI-I4") == .nvr)
        #expect(DeviceFamily.infer(deviceType: "", model: "DS-9664NI-I8") == .nvr)
        #expect(DeviceFamily.infer(deviceType: "", model: "DS-KV6113") == .doorbell)
        #expect(DeviceFamily.infer(deviceType: "IPDome", model: "DS-2DE4A425IW") == .ipCamera)
        #expect(DeviceFamily.infer(deviceType: "IPZoom", model: "X") == .ipCamera)
        #expect(DeviceFamily.infer(deviceType: "Encoder", model: "DS-6704HUHI") == .encoder)
        #expect(DeviceFamily.infer(deviceType: "mystery", model: "unknown") == .unknown)
        // `hybrid` must beat `dvr`, which is why the order in the table is not alphabetical.
        #expect(DeviceFamily.infer(deviceType: "Hybrid DVR", model: "") == .hybridDVR)
    }

    @Test func firmwareVersionParsesEveryDocumentedShape() {
        #expect(FirmwareVersion(parsing: "V5.6.3") == FirmwareVersion(major: 5, minor: 6, patch: 3,
                                                                     build: nil, raw: "V5.6.3"))
        let withBuild = FirmwareVersion(parsing: "V5.5.82 build 190220")
        #expect(withBuild.major == 5)
        #expect(withBuild.minor == 5)
        #expect(withBuild.patch == 82)
        #expect(withBuild.build == 190_220)
        let short = FirmwareVersion(parsing: "V5.6 build 190923")
        #expect(short.patch == 0)          // the build number must not become the patch
        #expect(short.build == 190_923)
        #expect(FirmwareVersion(parsing: "V4.30.005").patch == 5)
        let junk = FirmwareVersion(parsing: "unknown")
        #expect(junk.major == 0)
        #expect(junk.raw == "unknown")
    }

    @Test func firmwareVersionOrdersByComponentThenBuild() {
        #expect(FirmwareVersion(parsing: "V5.6") < FirmwareVersion(parsing: "V5.6.3"))
        #expect(FirmwareVersion(parsing: "V5.6.3") < FirmwareVersion(parsing: "V5.7.0"))
        #expect(FirmwareVersion(parsing: "V4.30.005") < FirmwareVersion(parsing: "V5.0.0"))
        #expect(FirmwareVersion(parsing: "V5.5.82 build 1")
                < FirmwareVersion(parsing: "V5.5.82 build 2"))
    }
}

// MARK: - UserCheckSuite

@Suite struct UserCheckSuite {

    @Test func userCheckReadsSuccess() throws {
        let result = UserCheckResult(document: try IdentityFixtures.document(
            IdentityFixtures.userCheckOK), httpStatus: 200)
        #expect(result.ok)
        #expect(!result.isLocked)
        #expect(!result.notActivated)
        #expect(result.remainingAttempts == nil)
        #expect(!result.shouldBlockFurtherAttempts)
    }

    @Test func userCheckReadsTheWrongPasswordBody() throws {
        let result = UserCheckResult(document: try IdentityFixtures.document(
            IdentityFixtures.userCheckWrong), httpStatus: 401)
        #expect(!result.ok)
        #expect(result.remainingAttempts == 3)
        #expect(!result.isLocked)
        #expect(result.unlockAfter == 0)
        // Three attempts left is not yet the blocking threshold.
        #expect(!result.shouldBlockFurtherAttempts)
    }

    @Test func userCheckReadsTheLockedBody() throws {
        let result = UserCheckResult(document: try IdentityFixtures.document(
            IdentityFixtures.userCheckLocked), httpStatus: 401)
        #expect(!result.ok)
        #expect(result.isLocked)
        #expect(result.unlockAfter == 1737)
        #expect(result.shouldBlockFurtherAttempts)
    }

    @Test func userCheckBlocksAtOneRemainingAttempt() throws {
        let xml = """
            <userCheck><statusValue>401</statusValue><isIllegalLogin>true</isIllegalLogin>
            <retryLoginTime>1</retryLoginTime><lockStatus>unlock</lockStatus></userCheck>
            """
        let result = UserCheckResult(document: try IdentityFixtures.document(xml),
                                     httpStatus: 401)
        // Vigil must never be the reason a camera locks out, so one attempt left is already
        // too few (docs/spec-isapi.md §10.2).
        #expect(result.shouldBlockFurtherAttempts)
    }

    @Test func userCheckAcceptsTheResponseStatusRoot() throws {
        // Some 5.4.x devices answer `<ResponseStatus>` with `notActivated` instead of `<userCheck>`.
        let xml = """
            <ResponseStatus><statusCode>4</statusCode>
            <subStatusCode>notActivated</subStatusCode></ResponseStatus>
            """
        let result = UserCheckResult(document: try IdentityFixtures.document(xml),
                                     httpStatus: 401)
        #expect(result.notActivated)
        #expect(!result.ok)
    }

    @Test func userCheckTreatsA200BodyWith401AsFailure() throws {
        // The firmwares that put the real status only in the body must not read as success.
        let result = UserCheckResult(document: try IdentityFixtures.document(
            IdentityFixtures.userCheckWrong), httpStatus: 200)
        #expect(!result.ok)
    }
}

// MARK: - DeviceStatusSuite

@Suite struct DeviceStatusSuite {

    @Test func deviceStatusDecodesTheFixture() throws {
        let status = DeviceStatus(document: try IdentityFixtures.document(
            IdentityFixtures.systemStatus))
        #expect(status.uptime == 987_654)
        #expect(status.status == "ok")
        #expect(status.cpuUtilization == [17])
        #expect(status.memoryUsedMB == 117.34)
        #expect(status.memoryAvailableMB == 72.65)
        #expect(status.openFileHandles == 63)
        #expect(status.temperaturesCelsius.isEmpty)
        #expect(status.currentDeviceTime != nil)
    }

    @Test func deviceStatusReadsRecorderTemperatures() throws {
        let xml = """
            <DeviceStatus><deviceUpTime>10</deviceUpTime><deviceStatus>ok</deviceStatus>
            <TemperatureList><Temperature><temperature>42</temperature></Temperature>
            <Temperature><temperature>44.5</temperature></Temperature></TemperatureList>
            </DeviceStatus>
            """
        let status = DeviceStatus(document: try IdentityFixtures.document(xml))
        #expect(status.temperaturesCelsius == [42, 44.5])
    }

    @Test func deviceStatusDetectsARebootFromAnUptimeRegression() throws {
        let before = DeviceStatus(currentDeviceTime: nil, uptime: 5000, status: "ok",
                                  cpuUtilization: [], memoryUsedMB: nil, memoryAvailableMB: nil,
                                  temperaturesCelsius: [], openFileHandles: nil)
        let after = DeviceStatus(currentDeviceTime: nil, uptime: 12, status: "ok",
                                 cpuUtilization: [], memoryUsedMB: nil, memoryAvailableMB: nil,
                                 temperaturesCelsius: [], openFileHandles: nil)
        #expect(after.indicatesRebootSince(before))
        #expect(!before.indicatesRebootSince(after))
    }
}

// MARK: - DeviceTimeSuite

@Suite struct DeviceTimeSuite {

    @Test func deviceTimeUndoesThePOSIXZoneInversion() throws {
        let time = try DeviceTime(document: IdentityFixtures.document(
            IdentityFixtures.systemTime))
        #expect(time.mode == "NTP")
        #expect(time.rawTimeZone == "CST-8:00:00")
        // `CST-8:00:00` means UTC+8: the sign on the wire is POSIX-inverted
        // (docs/spec-isapi.md §7.5).
        #expect(time.utcOffsetSeconds == 28_800)
    }

    @Test func deviceTimeComputesSignedSkew() throws {
        let time = try DeviceTime(document: IdentityFixtures.document(
            IdentityFixtures.systemTime))
        // 2024-05-01T12:34:56+08:00 is 2024-05-01T04:34:56Z.
        let reference = Date(timeIntervalSince1970: 1_714_538_096)
        #expect(abs(time.localTime.timeIntervalSince1970 - 1_714_538_096) < 0.001)
        #expect(abs(time.skew(against: reference)) < 0.001)
        #expect(abs(time.skew(against: reference.addingTimeInterval(-90)) - 90) < 0.001)
    }

    @Test func deviceTimeRequiresALocalTime() throws {
        let xml = "<Time><timeMode>NTP</timeMode><timeZone>CST-8:00:00</timeZone></Time>"
        #expect(throws: ISAPIError.self) {
            try DeviceTime(document: IdentityFixtures.document(xml))
        }
    }
}

// MARK: - DeviceCapabilitiesSuite

@Suite struct DeviceCapabilitiesSuite {

    @Test func capabilitiesResolveFromTheFixturePaths() throws {
        let caps = DeviceCapabilitiesWire(
            document: try IdentityFixtures.document(IdentityFixtures.capabilities),
            family: .ipCamera, probedAt: Date(timeIntervalSince1970: 0))
        #expect(caps.videoInputChannels == 1)
        #expect(caps.audioInputChannels == 1)
        #expect(caps.streamsPerChannel == 3)
        #expect(caps.supportsPTZ == false)
        #expect(caps.supportsTwoWayAudio)
        #expect(caps.supportsHTTPS)
        #expect(caps.alarmInputs == 1)
        #expect(caps.alarmOutputs == 1)
        // Any one of the three analytics flags resolves the row.
        #expect(caps.supportsSmartEvents)
        #expect(!caps.unresolved.contains(.supportsPTZ))
        #expect(!caps.unresolved.contains(.supportsSmartEvents))
        // Nothing in this document mentions WDR, so it stays unresolved for the probe.
        #expect(caps.unresolved.contains(.supportsWDR))
        #expect(caps.unresolved.contains(.supportsRecordSearch))
    }

    @Test func capabilitiesDefaultsAreConservativeButUsable() {
        let camera = DeviceCapabilitiesWire(family: .ipCamera,
                                           probedAt: Date(timeIntervalSince1970: 0))
        #expect(camera.streamsPerChannel == 2)
        // The alert stream and JPEG snapshots default to yes: both are near-universal, and
        // assuming otherwise hides working features (docs/spec-isapi.md §10.5).
        #expect(camera.supportsAlertStream)
        #expect(camera.supportsJPEGSnapshot)
        #expect(!camera.supportsRecordSearch)
        #expect(!camera.supportsInputProxy)
        let recorder = DeviceCapabilitiesWire(family: .nvr, probedAt: Date(timeIntervalSince1970: 0))
        #expect(recorder.supportsRecordSearch)
        #expect(recorder.supportsInputProxy)
    }

    @Test func capabilitiesClampNonsenseCounts() throws {
        let xml = "<DeviceCap><SysCap><videoInNo>-1</videoInNo></SysCap></DeviceCap>"
        let caps = DeviceCapabilitiesWire(document: try IdentityFixtures.document(xml),
                                         family: .ipCamera,
                                         probedAt: Date(timeIntervalSince1970: 0))
        #expect(caps.videoInputChannels == 1)
    }

    @Test func capabilitiesProbeResultsClearTheUnresolvedRow() {
        var caps = DeviceCapabilitiesWire(family: .ipCamera, probedAt: Date(timeIntervalSince1970: 0))
        caps.applyProbe(.supportsPTZ, supported: true)
        #expect(caps.supportsPTZ)
        #expect(!caps.unresolved.contains(.supportsPTZ))
        caps.applyProbe(.supportsWDR, supported: false)
        #expect(!caps.supportsWDR)
        #expect(!caps.unresolved.contains(.supportsWDR))
        caps.applyCount(.videoInputChannels, 16)
        #expect(caps.videoInputChannels == 16)
        caps.applyCount(.streamsPerChannel, 9)
        #expect(caps.streamsPerChannel == 3)
    }
}

// MARK: - NetworkAndUsersSuite

@Suite struct NetworkAndUsersSuite {

    @Test func networkInterfaceDecodesTheFixture() throws {
        let interfaces = NetworkInterfaceWire.list(
            document: try IdentityFixtures.document(IdentityFixtures.networkInterfaces))
        let interface = try #require(interfaces.first)
        #expect(interfaces.count == 1)
        #expect(interface.id == 1)
        #expect(interface.addressingType == "static")
        #expect(interface.ipv4 == "192.168.1.64")
        #expect(interface.subnetMask == "255.255.255.0")
        #expect(interface.gateway == "192.168.1.1")
        #expect(interface.dns == ["192.168.1.1", "8.8.8.8"])
        #expect(interface.macAddress == "44:47:cc:11:22:33")
        #expect(interface.linkSpeedMbps == 100)
        #expect(interface.duplex == "full")
        #expect(interface.mtu == 1500)
        // `::` is the unspecified address and is not a configured IPv6 address.
        #expect(interface.ipv6.isEmpty)
    }

    @Test func deviceUsersDecodeWithTheirLevels() throws {
        let users = DeviceUser.list(document: try IdentityFixtures.document(
            IdentityFixtures.users))
        #expect(users.count == 2)
        #expect(users[0].userName == "admin")
        #expect(users[0].level == .administrator)
        #expect(users[1].userName == "viewer")
        #expect(users[1].level == .operatorLevel)
        #expect(users[1].level.displayName == "Operator")
    }

    @Test func deviceUserPreservesAnUnknownLevel() throws {
        let xml = """
            <UserList><User><id>3</id><userName>svc</userName>
            <userLevel>Installer</userLevel></User></UserList>
            """
        let users = DeviceUser.list(document: try IdentityFixtures.document(xml))
        #expect(users.first?.level == .other("Installer"))
        #expect(users.first?.level.displayName == "Installer")
    }
}
