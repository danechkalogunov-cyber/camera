//
//  SADPFixtures.swift
//  VigilDiscoveryTests
//
//  The recorded SADP datagrams the codec tests are driven from: the three ProbeMatch samples of
//  docs/spec-discovery.md §4.4 verbatim, the §14.1 probe hex dump, and the derived binary variants.
//  Covers docs/spec-discovery.md §4.4, §14.1 and §14.2.
//

import Foundation

/// SADP wire fixtures.
///
/// The three XML documents are copied character for character from the specification's §4.4 samples,
/// which are themselves recorded from firmware. The binary variants (`xorObfuscated…`,
/// `randomOpaque…`, `latin1…`) are **derived** from those documents by the transformations §14.2
/// names, so they are deterministic and reproducible rather than invented: nothing here claims to be
/// a capture that it is not.
enum SADPFixtures {

    // MARK: - Probe

    /// The run UUID used throughout §4.4 and §14.1. A parse failure here would surface immediately
    /// as a mismatch against `probeGoldenHex`, so the fallback can never hide a broken fixture.
    static let probeUUID = UUID(uuidString: "1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11") ?? UUID()

    /// The §14.1 hex dump of `Fixtures/sadp-probe.bin`, transcribed byte for byte.
    ///
    /// The dump is 129 bytes long; the prose above it in §4.2 says "121 bytes". The dump is what
    /// firmware actually receives, so the dump is the fixture and the prose is noted as an error.
    static let probeGoldenHex = """
        3c 3f 78 6d 6c 20 76 65 72 73 69 6f 6e 3d 22 31
        2e 30 22 20 65 6e 63 6f 64 69 6e 67 3d 22 75 74
        66 2d 38 22 3f 3e 0a 3c 50 72 6f 62 65 3e 0a 3c
        55 75 69 64 3e 31 46 39 42 32 41 36 43 2d 34 45
        31 44 2d 34 46 35 41 2d 39 43 33 45 2d 37 41 32
        42 35 44 38 45 30 43 31 31 3c 2f 55 75 69 64 3e
        0a 3c 54 79 70 65 73 3e 69 6e 71 75 69 72 79 3c
        2f 54 79 70 65 73 3e 0a 3c 2f 50 72 6f 62 65 3e
        0a
        """

    /// A probe as another SADP client on the LAN would send it: same shape, different `Uuid`.
    static let foreignProbeXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <Probe>
        <Uuid>7C1E4B90-0000-4000-8000-ABCDEF012345</Uuid>
        <Types>inquiry</Types>
        </Probe>

        """

    // MARK: - ProbeMatch documents

    /// §4.4.1 — an activated 4 MP camera on firmware 5.5.82, verbatim.
    static let activatedCameraXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ProbeMatch>
        <Uuid>1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11</Uuid>
        <Types>inquiry</Types>
        <DeviceType>0</DeviceType>
        <DeviceDescription>IPCamera</DeviceDescription>
        <DeviceSN>DS-2CD2143G0-I20200114AAWRD12345678</DeviceSN>
        <CommandPort>8000</CommandPort>
        <HttpPort>80</HttpPort>
        <HttpsPort>443</HttpsPort>
        <RtspPort>554</RtspPort>
        <SDKOverTLSPort>8443</SDKOverTLSPort>
        <MAC>c4-2f-90-ab-cd-ef</MAC>
        <IPv4Address>192.168.1.64</IPv4Address>
        <IPv4SubnetMask>255.255.255.0</IPv4SubnetMask>
        <IPv4Gateway>192.168.1.1</IPv4Gateway>
        <IPv6Address>fe80::c62f:90ff:feab:cdef</IPv6Address>
        <IPv6Gateway>::</IPv6Gateway>
        <IPv6MaskLen>64</IPv6MaskLen>
        <DHCP>false</DHCP>
        <AnalogChannelNum>0</AnalogChannelNum>
        <DigitalChannelNum>0</DigitalChannelNum>
        <SoftwareVersion>V5.5.82build 190910</SoftwareVersion>
        <DSPVersion>V7.3 build 190430</DSPVersion>
        <BootTime>2026-07-19 06:14:02</BootTime>
        <ResetAbility>true</ResetAbility>
        <DiskNumber>0</DiskNumber>
        <Activated>true</Activated>
        <PasswordResetAbility>true</PasswordResetAbility>
        <PasswordResetModeSecond>true</PasswordResetModeSecond>
        <SupportHCPlatform>true</SupportHCPlatform>
        <HCPlatformEnable>false</HCPlatformEnable>
        <SupportSecurityQuestion>true</SupportSecurityQuestion>
        <DeviceLock>false</DeviceLock>
        <Salt>d41d8cd98f00b204e9800998ecf8427e</Salt>
        </ProbeMatch>

        """

    /// §4.4.2 — factory-fresh and **not activated**, verbatim. The case that must reach the UI.
    static let notActivatedCameraXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ProbeMatch>
        <Uuid>1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11</Uuid>
        <Types>inquiry</Types>
        <DeviceType>0</DeviceType>
        <DeviceDescription>IPCamera</DeviceDescription>
        <DeviceSN>DS-2CD2347G2-LU20260401AAWRJ98765432</DeviceSN>
        <CommandPort>8000</CommandPort>
        <HttpPort>80</HttpPort>
        <MAC>44-19-b6-11-22-33</MAC>
        <IPv4Address>192.168.1.64</IPv4Address>
        <IPv4SubnetMask>255.255.255.0</IPv4SubnetMask>
        <IPv4Gateway>192.168.1.1</IPv4Gateway>
        <IPv6Address>::</IPv6Address>
        <DHCP>false</DHCP>
        <AnalogChannelNum>0</AnalogChannelNum>
        <DigitalChannelNum>0</DigitalChannelNum>
        <SoftwareVersion>V5.7.3build 220315</SoftwareVersion>
        <DSPVersion>V5.0 build 220301</DSPVersion>
        <BootTime>2026-07-26 09:41:55</BootTime>
        <DiskNumber>0</DiskNumber>
        <Activated>false</Activated>
        <PasswordResetAbility>false</PasswordResetAbility>
        <SupportHCPlatform>true</SupportHCPlatform>
        <Salt>3f8a1c02b7e44d15a9c6ef2b7d5401aa</Salt>
        </ProbeMatch>

        """

    /// §4.4.3 — a 16-channel NVR, verbatim, including its empty `<OEMinfo>`.
    static let nvrXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ProbeMatch>
        <Uuid>1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11</Uuid>
        <Types>inquiry</Types>
        <DeviceType>2</DeviceType>
        <DeviceDescription>NVR</DeviceDescription>
        <DeviceSN>DS-7616NI-K2/16P1620201105AAWR123456789WCVU</DeviceSN>
        <CommandPort>8000</CommandPort>
        <HttpPort>80</HttpPort>
        <HttpsPort>443</HttpsPort>
        <RtspPort>554</RtspPort>
        <MAC>bc-ad-28-de-ad-be</MAC>
        <IPv4Address>10.0.20.11</IPv4Address>
        <IPv4SubnetMask>255.255.255.0</IPv4SubnetMask>
        <IPv4Gateway>10.0.20.1</IPv4Gateway>
        <DHCP>true</DHCP>
        <AnalogChannelNum>0</AnalogChannelNum>
        <DigitalChannelNum>16</DigitalChannelNum>
        <SoftwareVersion>V4.30.085build 200922</SoftwareVersion>
        <DSPVersion>V1.0 build 200901</DSPVersion>
        <BootTime>2026-06-02 18:22:41</BootTime>
        <DiskNumber>2</DiskNumber>
        <Activated>true</Activated>
        <PasswordResetAbility>true</PasswordResetAbility>
        <SupportHCPlatform>true</SupportHCPlatform>
        <OEMinfo></OEMinfo>
        </ProbeMatch>

        """

    /// §14.2 `sadp-probematch-oem.xml`: the camera document rebranded HiLook.
    static var oemCameraXML: String {
        activatedCameraXML
            .replacingOccurrences(of: "<DeviceSN>DS-2CD2143G0-I20200114AAWRD12345678</DeviceSN>",
                                  with: "<DeviceSN>HWI-B140H20230101CCWR123456</DeviceSN>")
            .replacingOccurrences(of: "<MAC>c4-2f-90-ab-cd-ef</MAC>",
                                  with: "<MAC>4c-bd-8f-01-02-03</MAC>")
            .replacingOccurrences(of: "<DeviceLock>false</DeviceLock>",
                                  with: "<DeviceLock>false</DeviceLock>\n<OEMinfo>HiLook</OEMinfo>")
    }

    /// §14.2 `sadp-probematch-amp.xml`: a description containing a bare, unescaped `&`, which real
    /// Hikvision firmware emits and which strict XML parsing would throw a real camera away over.
    static var unescapedAmpersandXML: String {
        activatedCameraXML.replacingOccurrences(
            of: "<DeviceDescription>IPCamera</DeviceDescription>",
            with: "<DeviceDescription>Lobby & Dock</DeviceDescription>")
    }

    // MARK: - Derived binary variants

    /// The activated-camera document as a datagram.
    static var activatedCameraDatagram: Data { Data(activatedCameraXML.utf8) }

    /// §14.2 `sadp-obfuscated-xor5a.bin`: the camera document XOR 0x5A, byte-wise.
    static var xorObfuscatedCameraDatagram: Data {
        Data(activatedCameraDatagram.map { $0 ^ 0x5A })
    }

    /// §14.2 `sadp-probematch-latin1.bin`: the camera document with the byte 0xB0 (`°` in
    /// ISO-8859-1, invalid as a standalone UTF-8 byte) inside `DeviceDescription`.
    static var latin1CameraDatagram: Data {
        var data = activatedCameraDatagram
        guard let range = data.range(of: Data("IPCamera".utf8)) else { return data }
        data.replaceSubrange(range.upperBound..<range.upperBound, with: [0xB0])
        return data
    }

    /// §14.2 `sadp-random-700.bin`: 700 deterministic pseudo-random bytes from SplitMix64 seeded
    /// with 0xC0FFEE. High entropy, no XML anywhere, no XOR key that reveals one.
    static var randomOpaqueDatagram: Data {
        var generator = SplitMix64(seed: 0x00C0_FFEE)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(704)
        while bytes.count < 700 {
            let word = generator.next()
            for shift in stride(from: 0, through: 56, by: 8) {
                bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        return Data(bytes.prefix(700))
    }

    /// A payload that begins with gzip magic. §4.8 requires that we record the fact and refuse to
    /// inflate, because no dependency-free inflate exists in the pure layer.
    static var gzipMagicDatagram: Data {
        var bytes: [UInt8] = [0x1F, 0x8B, 0x08, 0x00]
        bytes.append(contentsOf: Array(repeating: 0x41, count: 96))
        return Data(bytes)
    }

    // MARK: - Helpers

    /// Parses a whitespace-separated hex dump into bytes. Anything that is not a hex digit or
    /// whitespace is ignored, so a dump can be pasted with its ASCII column intact.
    static func hexData(_ dump: String) -> Data {
        var nibbles: [UInt8] = []
        for byte in dump.utf8 {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibbles.append(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibbles.append(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibbles.append(byte - UInt8(ascii: "A") + 10)
            default: continue
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(nibbles.count / 2)
        var index = 0
        while index + 1 < nibbles.count {
            bytes.append(nibbles[index] << 4 | nibbles[index + 1])
            index += 2
        }
        return Data(bytes)
    }

    /// A fixed arrival instant, so no test depends on the wall clock.
    static let receivedAt = Date(timeIntervalSince1970: 1_785_000_000)
}

/// SplitMix64, the generator §14.2 names for the committed random fixture. Deterministic across
/// platforms and trivially reproducible from the seed.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
