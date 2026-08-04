//
//  ONVIFMediaClient.swift
//  VigilDiscovery
//
//  ONVIF Media SOAP client with injected HTTP transport.
//

import Foundation
import VigilProtocols

public struct ONVIFMediaProfile: Sendable, Hashable {
    public let token: String
    public let name: String
    public init(token: String, name: String) {
        self.token = token
        self.name = name
    }
}

/// Minimal ONVIF Media 1 client. Transport is injected, so protocol fixtures run on Linux.
public struct ONVIFMediaClient: Sendable {
    public let endpoint: URL
    public let transport: any HTTPTransporting
    public init(endpoint: URL, transport: any HTTPTransporting) {
        self.endpoint = endpoint
        self.transport = transport
    }

    public func getProfiles(token: WSUsernameToken?) async throws -> [ONVIFMediaProfile] {
        let body = envelope(header: token?.xml ?? "", body: "<trt:GetProfiles/>")
        let response = try await send(action: "http://www.onvif.org/ver10/media/wsdl/GetProfiles", body: body)
        let xml = try successfulXML(response, resource: "ONVIF GetProfiles")
        return Self.elements(named: "Profiles", in: xml).compactMap { element in
            guard let profileToken = Self.attribute("token", in: element) else { return nil }
            return ONVIFMediaProfile(
                token: profileToken,
                name: Self.text(named: "Name", in: element) ?? profileToken)
        }
    }

    public func getStreamURI(profileToken: String, token: WSUsernameToken?) async throws -> URL {
        let request = "<trt:GetStreamUri><trt:StreamSetup>"
            + "<tt:Stream>RTP-Unicast</tt:Stream><tt:Transport>"
            + "<tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup>"
            + "<trt:ProfileToken>\(WSUsernameToken.escape(profileToken))</trt:ProfileToken>"
            + "</trt:GetStreamUri>"
        let response = try await send(
            action: "http://www.onvif.org/ver10/media/wsdl/GetStreamUri",
            body: envelope(header: token?.xml ?? "", body: request))
        let xml = try successfulXML(response, resource: "ONVIF GetStreamUri")
        guard let value = Self.text(named: "Uri", in: xml), let url = URL(string: value) else {
            throw ISAPIError.malformedResponse("ONVIF GetStreamUri omitted a valid Uri")
        }
        return url
    }

    private func send(action: String, body: String) async throws -> HTTPResponse {
        var headers = HTTPHeaders()
        headers["Content-Type"] = "application/soap+xml; charset=utf-8; action=\"\(action)\""
        return try await transport.perform(
            HTTPRequest(
                url: endpoint, method: "POST", headers: headers,
                body: Data(body.utf8), lane: .control))
    }

    private func successfulXML(_ response: HTTPResponse, resource: String) throws -> String {
        guard response.statusCode == 200 else {
            throw ISAPIError.http(status: response.statusCode, resource: resource)
        }
        guard let xml = String(data: response.body, encoding: .utf8) else {
            throw ISAPIError.malformedResponse("\(resource) was not UTF-8")
        }
        return xml
    }

    private func envelope(header: String, body: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" "
            + "xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" "
            + "xmlns:tt=\"http://www.onvif.org/ver10/schema\" "
            + "xmlns:wsse=\"http://docs.oasis-open.org/wss/2004/01/"
            + "oasis-200401-wss-wssecurity-secext-1.0.xsd\" "
            + "xmlns:wsu=\"http://docs.oasis-open.org/wss/2004/01/"
            + "oasis-200401-wss-wssecurity-utility-1.0.xsd\">"
            + "<s:Header>\(header)</s:Header><s:Body>\(body)</s:Body></s:Envelope>"
    }

    static func elements(named name: String, in xml: String) -> [String] {
        let pattern =
            #"<(?:(?:[A-Za-z_][\w.-]*):)?"# + name + #"\b[^>]*>[\s\S]*?</(?:(?:[A-Za-z_][\w.-]*):)?"# + name
            + #"\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = xml as NSString
        return regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }
    static func text(named name: String, in xml: String) -> String? {
        guard let element = elements(named: name, in: xml).first,
            let open = element.firstIndex(of: ">"),
            let close = element.range(of: "</", options: .backwards)?.lowerBound
        else { return nil }
        return String(element[element.index(after: open)..<close]).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }
    static func attribute(_ name: String, in element: String) -> String? {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: element, range: NSRange(element.startIndex..., in: element)),
            let range = Range(match.range(at: 1), in: element)
        else { return nil }
        return String(element[range])
    }
}
