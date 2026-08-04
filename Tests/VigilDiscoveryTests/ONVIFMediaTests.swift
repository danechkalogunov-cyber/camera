import Foundation
import Testing
import VigilProtocols

@testable import VigilDiscovery

private actor SOAPTransport: HTTPTransporting {
    let responses: [HTTPResponse]
    var index = 0
    var requests: [HTTPRequest] = []
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func perform(_ request: HTTPRequest) async throws(ISAPIError) -> HTTPResponse {
        requests.append(request)
        defer { index += 1 }
        return responses[index]
    }
    func stream(_ request: HTTPRequest) async throws(ISAPIError) -> (
        status: Int, headers: HTTPHeaders, bytes: AsyncThrowingStream<Data, any Error>
    ) { throw .notSupported(resource: "test") }
    func upload(_ request: HTTPRequest) async throws(ISAPIError) -> any HTTPUploadHandle {
        throw .notSupported(resource: "test")
    }
}

@Test("ONVIF UsernameToken matches the specification digest vector")
func usernameTokenVector() {
    let token = WSUsernameToken(
        username: "user", password: "password",
        nonce: Array("nonce".utf8), created: "2024-01-02T03:04:05Z")
    #expect(
        token.passwordDigest == Base64.encode(SHA1.digest(Array("nonce2024-01-02T03:04:05Zpassword".utf8))))
    #expect(token.xml.contains("<wsse:Username>user</wsse:Username>"))
}

@Test("ONVIF Media parses GetProfiles and GetStreamUri fixtures")
func mediaRequests() async throws {
    let profiles = Data(("<s:Envelope><s:Body><trt:GetProfilesResponse>"
        + "<trt:Profiles token=\"main\"><tt:Name>Main Stream</tt:Name></trt:Profiles>"
        + "<trt:Profiles token=\"sub\"><tt:Name>Sub Stream</tt:Name></trt:Profiles>"
        + "</trt:GetProfilesResponse></s:Body></s:Envelope>").utf8)
    let uri = Data(("<s:Envelope><s:Body><trt:GetStreamUriResponse><trt:MediaUri>"
        + "<tt:Uri>rtsp://192.0.2.10/live</tt:Uri></trt:MediaUri>"
        + "</trt:GetStreamUriResponse></s:Body></s:Envelope>").utf8)
    let transport = SOAPTransport([
        HTTPResponse(statusCode: 200, body: profiles), HTTPResponse(statusCode: 200, body: uri),
    ])
    let client = ONVIFMediaClient(
        endpoint: URL(string: "http://192.0.2.10/onvif/media_service")!, transport: transport)
    let values = try await client.getProfiles(token: nil)
    #expect(values == [.init(token: "main", name: "Main Stream"), .init(token: "sub", name: "Sub Stream")])
    #expect(
        try await client.getStreamURI(profileToken: "main", token: nil).absoluteString
            == "rtsp://192.0.2.10/live")
}

@Test("SADP activation consumes a public-key challenge and emits ciphertext only")
func sadpActivation() throws {
    let challenge = try SADPActivationCodec.decodeChallenge(
        Data("<ProbeMatch><DeviceSN>DS-TEST</DeviceSN><PublicKey>AQIDBA==</PublicKey></ProbeMatch>".utf8))
    let packet = try SADPActivationCodec.encodeActivation(
        uuid: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!, challenge: challenge,
        encryptedPassword: [0xde, 0xad])
    let xml = String(decoding: packet, as: UTF8.self)
    #expect(xml.contains("<Types>activate</Types>"))
    #expect(xml.contains("<Password>3q0=</Password>"))
}
