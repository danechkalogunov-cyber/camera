//
//  ISAPITestDoubles.swift
//  VigilISAPITests
//
//  The doubles the client tests drive: a Digest-verifying stub device, a scripted transport with
//  overlap counting, a clock that never really sleeps, and the response bodies copied verbatim from
//  docs/spec-isapi.md.
//
//  The stub device **verifies** the `Authorization` header rather than accepting anything: it
//  recomputes the response from its own view of the credential and, crucially, checks that the
//  `uri` parameter equals the request-line URI it actually received. A fixture that rubber-stamped
//  the header would pass while the client hashed the path without its query — the exact defect
//  spec-isapi §5.2 calls the most common cause of a permanent 401.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - Clock

/// A monotonic clock that advances when asked to sleep but never blocks the test.
final class InstantTestClock: MonotonicClock, @unchecked Sendable {

    /// Sleeps observed, in order. Read after a test to assert a backoff schedule.
    private(set) nonisolated(unsafe) var sleeps: [Duration] = []

    private nonisolated(unsafe) var nanoseconds: Int64 = 0
    private let lock = NSLock()

    func now() -> MediaInstant {
        lock.lock()
        defer { lock.unlock() }
        return MediaInstant(nanoseconds: nanoseconds)
    }

    func sleep(for duration: Duration) async throws {
        record(duration)
        await Task.yield()
    }

    /// Records a sleep and advances the clock. Split out because `NSLock.lock()` is unavailable
    /// from an `async` context.
    private func record(_ duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        sleeps.append(duration)
        let parts = duration.components
        nanoseconds += parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
    }

    /// Every sleep this clock was asked for.
    var recordedSleeps: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return sleeps
    }
}

// MARK: - Digest stub device

/// A device that challenges with Digest and verifies what comes back.
actor DigestStubDevice {

    /// How the device behaves.
    struct Behaviour: Sendable {
        /// The realm it announces. Hikvision's contains a space and parentheses.
        var realm = "IP Camera(51253)"
        /// The nonce it announces first.
        var nonce = "4e5a4f5a5a4d5a4f5a4d3d3d"
        /// The nonce it switches to when `staleOnFirstCredentialedRequest` fires.
        var replacementNonce = "5f6b5a6b6b5e6b5a6b5e4e4e"
        /// `true` for RFC 2617 `qop="auth"`; `false` for the RFC 2069 form 5.1.x–5.5.x uses.
        var offersQOP = false
        /// Also advertise Basic in a second `WWW-Authenticate` header.
        var alsoOffersBasic = false
        /// An `algorithm` value the client cannot compute, to exercise the refusal path.
        var unsupportedAlgorithm: String?
        /// The password the device will accept. Differs from the client's to force failures.
        var password = "Vigil-Test-1"
        /// The account the device will accept.
        var account = "admin"
        /// Answer the first credentialed request with `stale=TRUE` and a new nonce.
        var staleOnFirstCredentialedRequest = false
        /// The success body.
        var body = Data(SpecBodies.userCheckOK.utf8)
    }

    private var behaviour: Behaviour
    private var currentNonce: String
    private var staleFired = false

    /// Every request the device saw, in order.
    private(set) var recorded: [HTTPRequest] = []

    /// The `Authorization` header values it saw, in order.
    private(set) var authorizations: [String] = []

    /// Every `nc` value it saw, to prove none is reused.
    private(set) var nonceCounts: [String] = []

    /// Challenges issued.
    private(set) var challengeCount = 0

    init(behaviour: Behaviour = .init()) {
        self.behaviour = behaviour
        currentNonce = behaviour.nonce
    }

    /// Answers one request.
    func perform(_ request: HTTPRequest) -> HTTPResponse {
        recorded.append(request)
        let uri = Self.requestURI(request.url)
        guard let header = request.headers["Authorization"] else {
            return challenge(nonce: currentNonce, stale: false)
        }
        authorizations.append(header)
        let parameters = DigestChallenge.parameters(in: String(header.dropFirst("Digest ".count)))
        if let nc = parameters["nc"] { nonceCounts.append(nc) }

        if behaviour.staleOnFirstCredentialedRequest, !staleFired {
            staleFired = true
            currentNonce = behaviour.replacementNonce
            return challenge(nonce: currentNonce, stale: true)
        }
        // The uri parameter must be the request-line URI, query included.
        guard parameters["uri"] == uri else {
            return challenge(nonce: currentNonce, stale: false)
        }
        guard parameters["username"] == behaviour.account,
              parameters["realm"] == behaviour.realm,
              parameters["nonce"] == currentNonce else {
            return challenge(nonce: currentNonce, stale: false)
        }
        let ha1 = HTTPDigest.ha1(username: behaviour.account, realm: behaviour.realm,
                                 password: behaviour.password)
        let ha2 = HTTPDigest.ha2(method: request.method, uri: uri)
        let expected: String
        if let qop = parameters["qop"], qop == "auth" {
            guard let nc = parameters["nc"], let cnonce = parameters["cnonce"] else {
                return challenge(nonce: currentNonce, stale: false)
            }
            expected = HTTPDigest.response(ha1: ha1, nonce: currentNonce, nonceCount: nc,
                                           cnonce: cnonce, qop: "auth", ha2: ha2)
        } else {
            expected = HTTPDigest.response(ha1: ha1, nonce: currentNonce, ha2: ha2)
        }
        guard parameters["response"] == expected else {
            return challenge(nonce: currentNonce, stale: false)
        }
        var headers = HTTPHeaders()
        headers["Content-Type"] = "application/xml"
        return HTTPResponse(statusCode: 200, headers: headers, body: behaviour.body)
    }

    /// The 401 the device answers with.
    private func challenge(nonce: String, stale: Bool) -> HTTPResponse {
        challengeCount += 1
        var value = "Digest realm=\"\(behaviour.realm)\", nonce=\"\(nonce)\""
        if behaviour.offersQOP { value += ", qop=\"auth\"" }
        if let algorithm = behaviour.unsupportedAlgorithm { value += ", algorithm=\(algorithm)" }
        value += ", stale=\"\(stale ? "TRUE" : "FALSE")\""
        var headers = HTTPHeaders()
        headers.append("WWW-Authenticate", value)
        if behaviour.alsoOffersBasic {
            headers.append("WWW-Authenticate", "Basic realm=\"\(behaviour.realm)\"")
        }
        headers["Content-Type"] = "application/xml"
        return HTTPResponse(statusCode: 401, headers: headers,
                            body: Data(SpecBodies.userCheckUnauthorized.utf8))
    }

    /// Path plus query, exactly as it appears on the request line.
    static func requestURI(_ url: URL) -> String {
        guard let query = url.query, !query.isEmpty else { return url.path }
        return url.path + "?" + query
    }
}

/// The transport in front of `DigestStubDevice`.
struct DigestStubTransport: HTTPTransporting, Sendable {

    let device: DigestStubDevice

    func perform(_ request: HTTPRequest) async throws(ISAPIError) -> HTTPResponse {
        await device.perform(request)
    }

    func stream(_ request: HTTPRequest) async throws(ISAPIError)
        -> (status: Int, headers: HTTPHeaders, bytes: AsyncThrowingStream<Data, any Error>) {
        let response = await device.perform(request)
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(response.body)
        continuation.finish()
        return (response.statusCode, response.headers, stream)
    }

    func upload(_ request: HTTPRequest) async throws(ISAPIError) -> any HTTPUploadHandle {
        throw ISAPIError.notSupported(resource: request.url.path)
    }
}

// MARK: - Scripted transport

/// A transport that replays a script and counts how many requests overlap.
actor ScriptedDevice {

    /// One scripted answer.
    struct Reply: Sendable {
        var status: Int = 200
        var headers: HTTPHeaders = .init()
        var body: Data = Data()
        /// When set, the transport throws this instead of answering.
        var failure: ISAPIError?

        /// An XML answer.
        static func xml(_ text: String, status: Int = 200) -> Reply {
            var headers = HTTPHeaders()
            headers["Content-Type"] = "application/xml"
            return Reply(status: status, headers: headers, body: Data(text.utf8))
        }
    }

    private var replies: [Reply]
    private var index = 0
    private var concurrent = 0

    /// Highest number of requests in flight at once. The assertion for the lane gate.
    private(set) var peakConcurrency = 0

    /// Every request, in order.
    private(set) var recorded: [HTTPRequest] = []

    init(replies: [Reply]) {
        self.replies = replies.isEmpty ? [Reply()] : replies
    }

    /// Marks a request as started.
    func enter(_ request: HTTPRequest) {
        recorded.append(request)
        concurrent += 1
        peakConcurrency = max(peakConcurrency, concurrent)
    }

    /// Marks a request as finished and returns its scripted answer.
    func leave() -> Reply {
        concurrent -= 1
        let reply = replies[min(index, replies.count - 1)]
        index += 1
        return reply
    }
}

/// The transport in front of `ScriptedDevice`.
///
/// It yields repeatedly between entering and leaving so that concurrent callers really do overlap;
/// no wall-clock sleep is involved, so the test is deterministic and instant.
struct ScriptedTransport: HTTPTransporting, Sendable {

    let device: ScriptedDevice

    func perform(_ request: HTTPRequest) async throws(ISAPIError) -> HTTPResponse {
        await device.enter(request)
        for _ in 0..<40 { await Task.yield() }
        let reply = await device.leave()
        if let failure = reply.failure { throw failure }
        return HTTPResponse(statusCode: reply.status, headers: reply.headers, body: reply.body)
    }

    func stream(_ request: HTTPRequest) async throws(ISAPIError)
        -> (status: Int, headers: HTTPHeaders, bytes: AsyncThrowingStream<Data, any Error>) {
        await device.enter(request)
        let reply = await device.leave()
        if let failure = reply.failure { throw failure }
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(reply.body)
        continuation.finish()
        return (reply.status, reply.headers, stream)
    }

    func upload(_ request: HTTPRequest) async throws(ISAPIError) -> any HTTPUploadHandle {
        throw ISAPIError.notSupported(resource: request.url.path)
    }
}

// MARK: - Bodies

/// Response bodies copied **verbatim** from docs/spec-isapi.md, which records them as captures from
/// real devices. Nothing here is invented; where a variant is synthesised to exercise a firmware
/// difference the comment says so.
enum SpecBodies {

    /// spec-isapi §10.2, `userCheck` success.
    static let userCheckOK = """
        <?xml version="1.0" encoding="UTF-8"?>
        <userCheck version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <statusValue>200</statusValue>
          <statusString>OK</statusString>
        </userCheck>
        """

    /// spec-isapi §10.2, `userCheck` after a rejected credential.
    static let userCheckUnauthorized = """
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

    /// spec-isapi §10.2, `userCheck` for a locked account.
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

    /// spec-isapi §10.1, `deviceInfo` from a 5.6.3 IP camera.
    static let deviceInfo = """
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

    /// spec-isapi §12.1, one streaming channel with the `ver20` namespace.
    static let streamingChannel = """
        <StreamingChannelList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <StreamingChannel version="2.0">
            <id>101</id>
            <channelName>Driveway</channelName>
            <enabled>true</enabled>
            <Transport>
              <rtspPortNo>554</rtspPortNo>
              <maxPacketSize>1000</maxPacketSize>
              <ControlProtocolList>
                <ControlProtocol><streamingTransport>RTSP</streamingTransport></ControlProtocol>
                <ControlProtocol><streamingTransport>HTTP</streamingTransport></ControlProtocol>
              </ControlProtocolList>
              <Unicast><enabled>true</enabled><rtpTransportType>RTP/TCP</rtpTransportType></Unicast>
            </Transport>
            <Video>
              <enabled>true</enabled>
              <videoInputChannelID>1</videoInputChannelID>
              <videoCodecType>H.265</videoCodecType>
              <videoResolutionWidth>3840</videoResolutionWidth>
              <videoResolutionHeight>2160</videoResolutionHeight>
              <maxFrameRate>2000</maxFrameRate>
              <keyFrameInterval>2000</keyFrameInterval>
              <GovLength>40</GovLength>
              <SVC><enabled>false</enabled></SVC>
            </Video>
            <Audio>
              <enabled>true</enabled>
              <audioCompressionType>G.711ulaw</audioCompressionType>
            </Audio>
          </StreamingChannel>
          <StreamingChannel version="2.0">
            <id>102</id>
            <channelName>Driveway sub</channelName>
            <enabled>true</enabled>
            <Video>
              <videoCodecType>H.264</videoCodecType>
              <maxFrameRate>1250</maxFrameRate>
            </Video>
          </StreamingChannel>
        </StreamingChannelList>
        """

    /// spec-isapi §9.1, a `ResponseStatus` refusal.
    static let responseStatusNotSupport = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ResponseStatus version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <requestURL>/ISAPI/PTZCtrl/channels/1/continuous</requestURL>
          <statusCode>4</statusCode>
          <statusString>Invalid Operation</statusString>
          <subStatusCode>notSupport</subStatusCode>
          <errorCode>1073741830</errorCode>
          <errorMsg>notSupport</errorMsg>
        </ResponseStatus>
        """

    /// A `ResponseStatus` body with an arbitrary sub-status and HTTP status. Synthesised from the
    /// §9.1 shape by substituting the two fields the §9.3 table keys off.
    static func responseStatus(code: Int, sub: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ResponseStatus version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
          <requestURL>/ISAPI/System/deviceInfo</requestURL>
          <statusCode>\(code)</statusCode>
          <statusString>Test</statusString>
          <subStatusCode>\(sub)</subStatusCode>
        </ResponseStatus>
        """
    }
}

// MARK: - Client factory

/// Builds a client wired to a stub, with everything time-like and random-like injected.
enum TestClientFactory {

    /// The credential the stub device accepts by default.
    static let goodCredential = Credential(account: "admin", secret: "Vigil-Test-1")

    /// A credential the stub device rejects.
    static let wrongCredential = Credential(account: "admin", secret: "not-the-password")

    /// A client in front of a Digest-verifying device.
    static func digestClient(device: DigestStubDevice,
                             credential: Credential = goodCredential,
                             host: String = "192.168.1.64",
                             registry: AuthLockoutRegistry = AuthLockoutRegistry(),
                             clock: InstantTestClock = InstantTestClock()) -> ISAPIClient {
        ISAPIClient(endpoint: ISAPIEndpoint(host: host),
                    credential: credential,
                    transport: DigestStubTransport(device: device),
                    trustEvaluator: AlwaysTrustEvaluator(),
                    clock: clock,
                    random: SplitMix64RandomSource(seed: 0x5EED),
                    lockoutRegistry: registry)
    }

    /// A client in front of a scripted device.
    static func scriptedClient(device: ScriptedDevice,
                               configuration: ISAPIClient.Configuration = .init(),
                               host: String = "192.168.1.65",
                               clock: InstantTestClock = InstantTestClock()) -> ISAPIClient {
        ISAPIClient(endpoint: ISAPIEndpoint(host: host),
                    credential: goodCredential,
                    configuration: configuration,
                    transport: ScriptedTransport(device: device),
                    trustEvaluator: AlwaysTrustEvaluator(),
                    clock: clock,
                    random: SplitMix64RandomSource(seed: 0x5EED),
                    lockoutRegistry: AuthLockoutRegistry())
    }
}
