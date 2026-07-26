//
//  FingerprintTests.swift
//  VigilDiscoveryTests
//
//  The lenient header scanner, the two credential-free fingerprints, and the vendor classification
//  that has to distinguish "found, and it is a Hikvision" from "found, but it is a Dahua".
//  Covers docs/spec-discovery.md §6.6–§6.9; tests 51–64 of §13.5.
//
//  The response bodies below are synthesised from the header and status tables of §6.6/§6.7 — they
//  are the documented shapes, not captures from hardware.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilDiscovery

@Suite struct StartLineHeaderScannerBehaviour {

    static func data(_ text: String) -> Data { Data(text.utf8) }

    /// The ordinary case, with CRLF line endings and a body.
    @Test func startLineHeaderScannerParsesStatusAndHeaders() throws {
        let response = "RTSP/1.0 401 Unauthorized\r\n"
            + "CSeq: 1\r\n"
            + "WWW-Authenticate: Digest realm=\"IP Camera(52799)\", nonce=\"abc\"\r\n"
            + "Server: App-webs/\r\n"
            + "\r\n"
        let scan = try #require(StartLineHeaderScanner.scan(Self.data(response)))
        #expect(scan.protocolToken == "RTSP/1.0")
        #expect(scan.statusCode == 401)
        #expect(scan.reasonPhrase == "Unauthorized")
        #expect(scan.header("SERVER") == "App-webs/")
        #expect(scan.isTruncated == false)
        #expect(scan.bodyPrefix.isEmpty)
    }

    /// Test 56: firmware that answers with bare `\n` still parses.
    @Test func startLineHeaderScannerToleratesBareLineFeeds() throws {
        let response = "HTTP/1.1 200 OK\nServer: nginx\nContent-Length: 2\n\nhi"
        let scan = try #require(StartLineHeaderScanner.scan(Self.data(response)))
        #expect(scan.statusCode == 200)
        #expect(scan.header("server") == "nginx")
        #expect(String(decoding: scan.bodyPrefix, as: UTF8.self) == "hi")
    }

    /// A missing reason phrase is legal in the wild and must not lose the status code.
    @Test func startLineHeaderScannerAcceptsMissingReasonPhrase() throws {
        let scan = try #require(StartLineHeaderScanner.scan(Self.data("RTSP/1.0 200\r\n\r\n")))
        #expect(scan.statusCode == 200)
        #expect(scan.reasonPhrase.isEmpty)
    }

    /// A non-numeric status leaves `statusCode` nil rather than guessing.
    @Test func startLineHeaderScannerLeavesUnparseableStatusNil() throws {
        let scan = try #require(StartLineHeaderScanner.scan(Self.data("GARBAGE\r\n\r\n")))
        #expect(scan.protocolToken == "GARBAGE")
        #expect(scan.statusCode == nil)
    }

    /// Header lines with no colon are dropped; the headers around them survive.
    @Test func startLineHeaderScannerSkipsColonlessLines() throws {
        let response = "HTTP/1.1 200 OK\r\nthis line has no colon\r\nServer: Boa/0.94.14rc21\r\n\r\n"
        let scan = try #require(StartLineHeaderScanner.scan(Self.data(response)))
        #expect(scan.headers.count == 1)
        #expect(scan.header("server") == "Boa/0.94.14rc21")
    }

    /// Repeated headers join with `", "`; folded continuation lines extend the previous value.
    @Test func startLineHeaderScannerJoinsRepeatsAndFoldsContinuations() throws {
        let response = "RTSP/1.0 200 OK\r\nPublic: OPTIONS\r\nPublic: DESCRIBE\r\n"
            + "X-Long: first\r\n\tsecond\r\n\r\n"
        let scan = try #require(StartLineHeaderScanner.scan(Self.data(response)))
        #expect(scan.header("public") == "OPTIONS, DESCRIBE")
        #expect(scan.header("x-long") == "first second")
    }

    /// Non-UTF-8 bytes in a realm decode as ISO-8859-1 instead of failing the whole scan.
    @Test func startLineHeaderScannerDecodesLatin1Realms() throws {
        var bytes = Array("RTSP/1.0 401 Unauthorized\r\nWWW-Authenticate: Digest realm=\"caf".utf8)
        bytes.append(0xE9)                                  // 'é' in ISO-8859-1, invalid UTF-8
        bytes += Array("\"\r\n\r\n".utf8)
        let scan = try #require(StartLineHeaderScanner.scan(Data(bytes)))
        let header = try #require(scan.header("www-authenticate"))
        let challenge = try #require(StartLineHeaderScanner.authChallenge(header))
        #expect(challenge.params["realm"] == "café")
    }

    /// Test 62: a megabyte of headers stops at the limit and says it was truncated.
    @Test func startLineHeaderScannerIsBoundedByHeaderByteLimit() throws {
        var response = "HTTP/1.1 200 OK\r\n"
        let padding = String(repeating: "a", count: 64)
        for index in 0..<16_000 { response += "X-Pad-\(index): \(padding)\r\n" }
        response += "\r\n"
        #expect(response.utf8.count > 1_000_000)
        let scan = try #require(StartLineHeaderScanner.scan(Self.data(response)))
        #expect(scan.statusCode == 200)
        #expect(scan.isTruncated)
        #expect(scan.headers.count < 16_000)
    }

    /// A buffer that ends mid-headers is reported as truncated, not as a complete response.
    @Test func startLineHeaderScannerFlagsUnterminatedHeaders() throws {
        let scan = try #require(StartLineHeaderScanner.scan(Self.data("HTTP/1.1 200 OK\r\nSer")))
        #expect(scan.isTruncated)
    }

    /// Empty input is the one case that yields nil.
    @Test func startLineHeaderScannerReturnsNilForEmptyInput() {
        #expect(StartLineHeaderScanner.scan(Data()) == nil)
    }

    /// The body prefix is capped at 512 bytes however long the body is.
    @Test func startLineHeaderScannerCapsBodyPrefix() throws {
        let response = "HTTP/1.1 200 OK\r\n\r\n" + String(repeating: "x", count: 4_096)
        let scan = try #require(StartLineHeaderScanner.scan(Self.data(response)))
        #expect(scan.bodyPrefix.count == 512)
    }

    /// Auth challenges: quoted, unquoted, comma-bearing realms and a bare scheme.
    @Test func startLineHeaderScannerParsesAuthChallenges() throws {
        let digest = try #require(StartLineHeaderScanner
            .authChallenge("Digest realm=\"IP Camera(52799)\", nonce=abc123, qop=\"auth\""))
        #expect(digest.scheme == "Digest")
        #expect(digest.params["realm"] == "IP Camera(52799)")
        #expect(digest.params["nonce"] == "abc123")
        #expect(digest.params["qop"] == "auth")

        let basic = try #require(StartLineHeaderScanner.authChallenge("Basic realm=\"index\""))
        #expect(basic.scheme == "Basic")
        #expect(basic.params["realm"] == "index")

        let bare = try #require(StartLineHeaderScanner.authChallenge("Negotiate"))
        #expect(bare.scheme == "Negotiate")
        #expect(bare.params.isEmpty)
        #expect(StartLineHeaderScanner.authChallenge("   ") == nil)
    }
}

// MARK: - Requests and classification

@Suite struct FingerprintCodecBehaviour {

    static let host = IPv4Address(192, 168, 1, 64)

    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// Test 51: the exact `OPTIONS` bytes, and the absence of any credential.
    @Test func fingerprintCodecBuildsExactRTSPOptionsRequest() {
        let expected = "OPTIONS rtsp://192.168.1.64:554/ RTSP/1.0\r\n"
            + "CSeq: 1\r\n"
            + "User-Agent: Vigil/1.0 (macOS; discovery)\r\n"
            + "\r\n"
        let request = FingerprintCodec.rtspOptionsRequest(host: Self.host)
        #expect(Self.text(request) == expected)
        #expect(!Self.text(request).lowercased().contains("authorization"))
    }

    /// The ISAPI probe names the path, the host and nothing else. No `Authorization`, ever: two
    /// credentialed 401s per device is terminal on Hikvision firmware.
    @Test func fingerprintCodecBuildsISAPIAndRootRequests() {
        let isapi = Self.text(FingerprintCodec.isapiDeviceInfoRequest(host: Self.host))
        #expect(isapi.hasPrefix("GET /ISAPI/System/deviceInfo HTTP/1.1\r\n"))
        #expect(isapi.contains("Host: 192.168.1.64\r\n"))
        #expect(isapi.contains("Connection: close\r\n"))
        #expect(!isapi.lowercased().contains("authorization"))
        let root = Self.text(FingerprintCodec.rootRequest(host: Self.host))
        #expect(root.hasPrefix("GET / HTTP/1.1\r\n"))
        #expect(!root.lowercased().contains("authorization"))
    }

    /// Test 52: the Hikvision realm.
    @Test func fingerprintCodecClassifiesHikvisionRTSPRealm() {
        let response = "RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\n"
            + "WWW-Authenticate: Digest realm=\"IP Camera(52799)\", nonce=\"deadbeef\"\r\n\r\n"
        let print = FingerprintCodec.classifyRTSP(Data(response.utf8))
        #expect(print.isRTSP)
        #expect(print.statusCode == 401)
        #expect(print.realm == "IP Camera(52799)")
        #expect(print.vendor == .hikvision)
        #expect(print.macHint == nil)
    }

    /// A `DS-` realm is Hikvision too — some firmware puts the model there.
    @Test func fingerprintCodecClassifiesHikvisionModelRealm() {
        let response = "RTSP/1.0 401 Unauthorized\r\n"
            + "WWW-Authenticate: Digest realm=\"DS-2CD2143G0-I\"\r\n\r\n"
        #expect(FingerprintCodec.classifyRTSP(Data(response.utf8)).vendor == .hikvision)
    }

    /// Test 53: an Axis realm carries the MAC, extracted as a hint.
    @Test func fingerprintCodecExtractsAxisMACHint() throws {
        let response = "RTSP/1.0 401 Unauthorized\r\n"
            + "WWW-Authenticate: Digest realm=\"AXIS_ACCC8E123456\", nonce=\"x\"\r\n\r\n"
        let print = FingerprintCodec.classifyRTSP(Data(response.utf8))
        #expect(print.vendor == .axis)
        #expect(print.macHint == MACAddress("ac:cc:8e:12:34:56"))
        // A realm that only looks like one is rejected rather than guessed at.
        #expect(FingerprintCodec.macFromAxisRealm("AXIS_NOTHEX123456") == nil)
        #expect(FingerprintCodec.macFromAxisRealm("AXIS_ACCC8E") == nil)
    }

    /// Test 54: Dahua's `Login to <hex>` and bare `IPC` realms.
    @Test func fingerprintCodecClassifiesDahuaRealms() {
        #expect(FingerprintCodec.vendorForRealm("Login to 4a2b1c") == .dahua)
        #expect(FingerprintCodec.vendorForRealm("IPC") == .dahua)
        #expect(FingerprintCodec.vendorForServerHeader("Boa/0.94.14rc21") == .dahua)
        #expect(FingerprintCodec.vendorForServerHeader("DahuaRtsp") == .dahua)
    }

    /// Test 55: a 200 with a `Public:` list, parsed and uppercased.
    @Test func fingerprintCodecParsesPublicMethods() {
        let response = "RTSP/1.0 200 OK\r\nCSeq: 1\r\n"
            + "Public: OPTIONS, DESCRIBE, SETUP, teardown, PLAY\r\n\r\n"
        let print = FingerprintCodec.classifyRTSP(Data(response.utf8))
        #expect(print.publicMethods == ["OPTIONS", "DESCRIBE", "SETUP", "TEARDOWN", "PLAY"])
        #expect(print.vendor == .genericRTSP)
    }

    /// A port 554 that is not RTSP at all: worth knowing, and it must not become a camera.
    @Test func fingerprintCodecRejectsNonRTSPResponse() {
        #expect(FingerprintCodec.classifyRTSP(Data("HTTP/1.1 200 OK\r\n\r\n".utf8)).isRTSP == false)
        #expect(FingerprintCodec.classifyRTSP(Data([0x16, 0x03, 0x01, 0x00])).isRTSP == false)
        #expect(FingerprintCodec.classifyRTSP(Data()).isRTSP == false)
    }

    /// Test 57: the highest-value signal in discovery — a 401 from `/ISAPI/` with a Hik `Server`.
    @Test func fingerprintCodecClassifiesISAPI401AsHikvision() {
        let response = "HTTP/1.1 401 Unauthorized\r\nServer: App-webs/\r\n"
            + "WWW-Authenticate: Digest realm=\"IP Camera(52799)\", nonce=\"n\"\r\n\r\n"
        let print = FingerprintCodec.classifyHTTP(Data(response.utf8))
        #expect(print.statusCode == 401)
        #expect(print.isapiPathPresent)
        #expect(print.vendor == .hikvision)
        #expect(print.realm == "IP Camera(52799)")
    }

    /// Test 61: the ISAPI path exists but the web stack is somebody else's — an OEM rebadge.
    @Test func fingerprintCodecClassifiesOEMServerHeaderAsHikvisionOEM() {
        let response = "HTTP/1.1 401 Unauthorized\r\nServer: nginx\r\n"
            + "WWW-Authenticate: Digest realm=\"Login\"\r\n\r\n"
        let print = FingerprintCodec.classifyHTTP(Data(response.utf8))
        #expect(print.isapiPathPresent)
        #expect(print.vendor == .hikvisionOEM)
        #expect(print.vendor.supportsISAPI)
    }

    /// Test 58: a 404 is the clearest "not Hikvision" there is, and must not claim a vendor.
    @Test func fingerprintCodecTreatsISAPI404AsNotHikvision() {
        let response = "HTTP/1.1 404 Not Found\r\nServer: HP HTTP Server; HP Officejet\r\n\r\n"
        let print = FingerprintCodec.classifyHTTP(Data(response.utf8))
        #expect(print.isapiPathPresent == false)
        #expect(print.vendor == .unknown)
        #expect(print.vendor.supportsISAPI == false)
    }

    /// Test 59: a 200 body with `<DeviceInfo>` hands us the metadata for free.
    @Test func fingerprintCodecExtractsInlineDeviceInfo() throws {
        let body = "<?xml version=\"1.0\"?><DeviceInfo><deviceName>Front</deviceName>"
            + "<model>DS-2CD2143G0-I</model>"
            + "<serialNumber>DS-2CD2143G0-I20200114AAWRD12345678</serialNumber>"
            + "<macAddress>c4:2f:90:ab:cd:ef</macAddress>"
            + "<firmwareVersion>V5.5.82</firmwareVersion></DeviceInfo>"
        let response = "HTTP/1.1 200 OK\r\nServer: App-webs/\r\n"
            + "Content-Type: application/xml\r\n\r\n" + body
        let print = FingerprintCodec.classifyHTTP(Data(response.utf8))
        let inline = try #require(print.inlineDeviceInfo)
        #expect(print.isapiPathPresent)
        #expect(inline.model == "DS-2CD2143G0-I")
        #expect(inline.serialNumber == "DS-2CD2143G0-I20200114AAWRD12345678")
        #expect(inline.macAddress == MACAddress("c4:2f:90:ab:cd:ef"))
        #expect(inline.firmwareVersion == "V5.5.82")
        #expect(print.vendor == .hikvision)
    }

    /// A truncated or empty element yields nil rather than a garbage value.
    @Test func fingerprintCodecInlineDeviceInfoToleratesMalformedXML() {
        let info = FingerprintCodec.parseInlineDeviceInfo("<DeviceInfo><model></model><serialNumber>")
        #expect(info.isEmpty)
        #expect(FingerprintCodec.element("model", in: "<model>DS-1</model>") == "DS-1")
        #expect(FingerprintCodec.element("model", in: "<model>DS-1") == nil)
    }

    /// Test 60: a 403 whose body says `notActivated` — the camera has no password yet.
    @Test func fingerprintCodecDetectsNotActivated() {
        let body = "<ResponseStatus><statusCode>6</statusCode>"
            + "<subStatusCode>notActivated</subStatusCode></ResponseStatus>"
        let response = "HTTP/1.1 403 Forbidden\r\nServer: DVRDVS-Webs\r\n\r\n" + body
        let print = FingerprintCodec.classifyHTTP(Data(response.utf8))
        #expect(print.notActivated)
        #expect(print.vendor == .hikvision)
        #expect(print.isapiPathPresent)
    }

    /// The `/` follow-up must never claim the ISAPI path exists, even on a 401.
    @Test func fingerprintCodecRootRequestNeverClaimsISAPIPath() {
        let response = "HTTP/1.1 401 Unauthorized\r\nServer: Router\r\n"
            + "WWW-Authenticate: Basic realm=\"index\"\r\n\r\n"
        let print = FingerprintCodec.classifyHTTP(Data(response.utf8), isISAPIPath: false)
        #expect(print.isapiPathPresent == false)
        #expect(print.vendor == .unknown)
    }
}

// MARK: - Classification

@Suite struct VendorClassifierBehaviour {

    /// SADP is the strongest single piece of evidence: +45, and `OEMinfo` splits Hikvision from a
    /// rebadge.
    @Test func vendorClassifierScoresSADPHighest() {
        let genuine = VendorClassifier.classify(ClassificationEvidence(hasSADPProbeMatch: true))
        #expect(genuine.vendor == .hikvision)
        #expect(genuine.confidenceDelta == 45)
        let oem = VendorClassifier.classify(
            ClassificationEvidence(hasSADPProbeMatch: true, sadpOEMInfo: "HiLook"))
        #expect(oem.vendor == .hikvisionOEM)
        #expect(oem.confidenceDelta == 45)
    }

    /// Test 63: Dahua's private port (+30) beats a bare ONVIF ProbeMatch (+15).
    @Test func vendorClassifierResolvesConflictByHighestDelta() {
        let verdict = VendorClassifier.classify(
            ClassificationEvidence(hasONVIFProbeMatch: true, openPorts: [80, 554, 37_777]))
        #expect(verdict.vendor == .dahua)
        #expect(verdict.confidenceDelta == 30)
    }

    /// Test 64: a `.unknown` verdict never undoes a known vendor.
    @Test func vendorClassifierNeverRegressesToUnknown() {
        let verdict = VendorClassifier.classify(
            ClassificationEvidence(openPorts: [80], currentVendor: .hikvision))
        #expect(verdict.vendor == .hikvision)
        let combined = VendorClassifier.combine(
            existing: ClassificationVerdict(vendor: .hikvision, confidenceDelta: 45),
            incoming: ClassificationVerdict(vendor: .unknown, confidenceDelta: 5))
        #expect(combined.vendor == .hikvision)
        #expect(combined.confidenceDelta == 45)
    }

    /// "Found, but not Hikvision" for each family the brief names, from the evidence a sweep can
    /// actually gather.
    @Test func vendorClassifierDistinguishesTheCommonFamilies() {
        let hikvision = VendorClassifier.classify(ClassificationEvidence(
            http: HTTPFingerprint(statusCode: 401, serverHeader: "App-webs/",
                                  isapiPathPresent: true, vendor: .hikvision),
            openPorts: [80, 554]))
        #expect(hikvision.vendor == .hikvision)
        #expect(hikvision.confidenceDelta == 35)

        let dahua = VendorClassifier.classify(ClassificationEvidence(
            rtsp: RTSPFingerprint(isRTSP: true, statusCode: 401, realm: "Login to 4a2b1c",
                                  vendor: .dahua),
            http: HTTPFingerprint(statusCode: 404), openPorts: [80, 554, 37_777]))
        #expect(dahua.vendor == .dahua)

        let axis = VendorClassifier.classify(ClassificationEvidence(
            rtsp: RTSPFingerprint(isRTSP: true, statusCode: 401, realm: "AXIS_ACCC8E123456",
                                  vendor: .axis),
            openPorts: [80], bonjourTypes: ["_axis-video._tcp"]))
        #expect(axis.vendor == .axis)
        #expect(axis.confidenceDelta == 30)

        let unknown = VendorClassifier.classify(ClassificationEvidence(
            http: HTTPFingerprint(statusCode: 404, serverHeader: "HP HTTP Server"),
            openPorts: [80]))
        #expect(unknown.vendor == .unknown)
        #expect(unknown.confidenceDelta == 5)
        #expect(unknown.vendor.supportsISAPI == false)
    }

    /// An RTSP server that says nothing else is `.genericRTSP` — a camera we can probably stream but
    /// cannot control.
    @Test func vendorClassifierFallsBackToGenericRTSPAndONVIF() {
        let rtsp = VendorClassifier.classify(ClassificationEvidence(
            rtsp: RTSPFingerprint(isRTSP: true, statusCode: 200), openPorts: [554]))
        #expect(rtsp.vendor == .genericRTSP)
        #expect(rtsp.confidenceDelta == 10)
        let onvif = VendorClassifier.classify(ClassificationEvidence(hasONVIFProbeMatch: true))
        #expect(onvif.vendor == .genericONVIF)
        #expect(onvif.confidenceDelta == 15)
    }

    /// ONVIF scope text alone identifies the family (§5.7).
    @Test func vendorClassifierReadsONVIFScopeText() {
        #expect(VendorClassifier.vendorFromONVIFText("HIKVISION DS-2CD2143G0-I") == .hikvision)
        #expect(VendorClassifier.vendorFromONVIFText("HWI-B140H") == .hikvisionOEM)
        #expect(VendorClassifier.vendorFromONVIFText("IPC-HDW4433C-A") == .dahua)
        #expect(VendorClassifier.vendorFromONVIFText("AXIS P3245-LV") == .axis)
        #expect(VendorClassifier.vendorFromONVIFText("Reolink RLC-810A") == .reolink)
        #expect(VendorClassifier.vendorFromONVIFText("Some Printer") == nil)
    }

    /// Test 65 of §6.9: the OUI table is a hint, consulted only while the vendor is unknown.
    @Test func vendorClassifierUsesOUIOnlyAsALastResort() throws {
        let hikvisionMAC = try #require(MACAddress("c4:2f:90:ab:cd:ef"))
        let hinted = VendorClassifier.classify(ClassificationEvidence(openPorts: [80],
                                                                     mac: hikvisionMAC))
        #expect(hinted.vendor == .hikvision)
        #expect(hinted.confidenceDelta == 10)

        // With better evidence present, the OUI adds nothing and cannot override it.
        let axisMAC = try #require(MACAddress("ac:cc:8e:12:34:56"))
        let overridden = VendorClassifier.classify(ClassificationEvidence(
            hasSADPProbeMatch: true, openPorts: [80], mac: axisMAC))
        #expect(overridden.vendor == .hikvision)
        #expect(overridden.confidenceDelta == 45)

        // A locally administered address has a meaningless OUI.
        let local = try #require(MACAddress("c6:2f:90:ab:cd:ef"))
        #expect(VendorClassifier.vendorForOUI(local) == nil)
    }

    /// Device class comes from the SADP description and the ONVIF scopes, and never regresses.
    @Test func vendorClassifierInfersDeviceClass() {
        let nvr = VendorClassifier.classify(ClassificationEvidence(
            hasSADPProbeMatch: true, deviceDescription: "DS-7616NI-K2 NVR"))
        #expect(nvr.deviceClass == .nvr)
        let ptz = VendorClassifier.classify(ClassificationEvidence(
            hasSADPProbeMatch: true, deviceDescription: "IPCamera",
            onvifScopes: ONVIFScopes(types: ["ptz"])))
        #expect(ptz.deviceClass == .ptzCamera)
        let combined = VendorClassifier.combine(
            existing: ClassificationVerdict(vendor: .hikvision, deviceClass: .ptzCamera,
                                            confidenceDelta: 45),
            incoming: ClassificationVerdict(vendor: .hikvision, deviceClass: .camera,
                                            confidenceDelta: 35))
        #expect(combined.deviceClass == .ptzCamera)
    }

    /// No evidence at all is inconclusive, not a device.
    @Test func vendorClassifierReturnsInconclusiveWithoutEvidence() {
        let verdict = VendorClassifier.classify(ClassificationEvidence())
        #expect(verdict.vendor == .unknown)
        #expect(verdict.confidenceDelta == 0)
    }

    /// Each vendor's suggested RTSP path, and the deliberate `nil` for the ones we must ask about.
    @Test func vendorClassifierVendorPathsMatchTheTable() {
        #expect(DeviceVendor.hikvision.defaultRTSPPaths?.main == "/Streaming/Channels/101")
        #expect(DeviceVendor.hikvisionOEM.defaultRTSPPaths?.sub == "/Streaming/Channels/102")
        #expect(DeviceVendor.dahua.defaultRTSPPaths?.main
            == "/cam/realmonitor?channel=1&subtype=0")
        #expect(DeviceVendor.reolink.defaultRTSPPaths?.main == "/h264Preview_01_main")
        #expect(DeviceVendor.genericONVIF.defaultRTSPPaths == nil)
        #expect(DeviceVendor.unknown.defaultRTSPPaths == nil)
    }
}

// MARK: - Observations from probe results

@Suite struct ObservationBuilderBehaviour {

    static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    /// A host that answered nothing yields nothing: a timeout is not a device.
    @Test func observationBuilderIgnoresSilentHosts() {
        let result = HostProbeResult(address: IPv4Address(10, 0, 20, 7),
                                    portOutcomes: [80: .timedOut, 554: .timedOut])
        #expect(ObservationBuilder.observations(from: result, observedAt: Self.stamp).isEmpty)
    }

    /// A refused port proves the host exists, so it produces a sweep observation with no open ports.
    @Test func observationBuilderTreatsRefusedAsAlive() {
        let result = HostProbeResult(address: IPv4Address(10, 0, 20, 8),
                                    portOutcomes: [80: .refused, 554: .timedOut])
        let observations = ObservationBuilder.observations(from: result, observedAt: Self.stamp)
        #expect(observations.count == 1)
        #expect(observations[0].source == .tcpSweep)
        if case let .ports(ports) = observations[0].fields[.openPorts] {
            #expect(ports.isEmpty)
        } else {
            Issue.record("expected an openPorts field")
        }
    }

    /// One observation per source, each stamped separately so field precedence can order them.
    @Test func observationBuilderSplitsBySource() throws {
        let result = HostProbeResult(
            address: IPv4Address(10, 0, 20, 42),
            portOutcomes: [80: .open, 554: .open, 8_000: .open, 443: .open],
            rtsp: RTSPFingerprint(isRTSP: true, statusCode: 401, realm: "IP Camera(11111)",
                                  vendor: .hikvision),
            http: HTTPFingerprint(statusCode: 401, serverHeader: "App-webs/",
                                  isapiPathPresent: true, vendor: .hikvision))
        let observations = ObservationBuilder.observations(from: result, observedAt: Self.stamp)
        #expect(observations.map(\.source) == [.tcpSweep, .rtspFingerprint, .isapiFingerprint])
        #expect(observations[0].fields[.httpPort] == .port(80))
        #expect(observations[0].fields[.commandPort] == .port(8_000))
        #expect(observations[0].fields[.httpsPort] == .port(443))
        #expect(observations[1].fields[.rtspRealm] == .string("IP Camera(11111)"))
        #expect(observations[2].fields[.httpServerHeader] == .string("App-webs/"))
    }

    /// An Axis realm's MAC arrives as a hint and never as an identity.
    @Test func observationBuilderMarksAxisMACAsHintOnly() throws {
        let mac = try #require(MACAddress("ac:cc:8e:12:34:56"))
        let result = HostProbeResult(
            address: IPv4Address(10, 0, 20, 55), portOutcomes: [80: .open],
            rtsp: RTSPFingerprint(isRTSP: true, statusCode: 401, realm: "AXIS_ACCC8E123456",
                                  macHint: mac, vendor: .axis))
        let observations = ObservationBuilder.observations(from: result, observedAt: Self.stamp)
        let rtsp = try #require(observations.first { $0.source == .rtspFingerprint })
        #expect(rtsp.mac == mac)
        #expect(rtsp.macIsHintOnly)
        #expect(!rtsp.identities.contains(.mac(mac)))
    }
}
