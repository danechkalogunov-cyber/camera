//
//  WSDFixtures.swift
//  VigilDiscoveryTests
//
//  The recorded ONVIF WS-Discovery datagrams the codec tests are driven from: the two ProbeMatches of
//  docs/spec-discovery.md §5.4, prefix and namespace variants of the first, and Hello/Bye.
//  Covers docs/spec-discovery.md §5.4 and §14.2.
//

import Foundation

/// WS-Discovery wire fixtures.
///
/// The Hikvision and Dahua ProbeMatches are the §5.4 samples verbatim; the variants are mechanical
/// rewrites of the first (different prefixes, no namespace declarations at all) which is exactly what
/// §13.3 tests 27 and 28 ask for. Nothing here is presented as a capture it is not.
enum WSDFixtures {

    /// The `MessageID` of probe #1 in §5.2, which the §5.4 response relates to.
    static let probeMessageID = "urn:uuid:9a6f2c41-8b3d-4a7e-9f10-2c5b8e7d3a91"

    /// The `MessageID` the camera's own response carries.
    static let responseMessageID = "urn:uuid:c1f4b2e0-77aa-4a1c-8f2b-000000000042"

    /// The camera's `EndpointReference`. Its last twelve hex digits are the MAC — a hint only.
    static let hikvisionEndpoint = "urn:uuid:2419d68a-2dd2-21b2-a205-c42f90abcdef"

    /// The Dahua sample's endpoint.
    static let dahuaEndpoint = "urn:uuid:5b3f2a10-0000-0000-0000-3cef8c112233"

    /// The nine scopes of the §5.4 Hikvision sample, in order, still percent-encoded.
    static let hikvisionScopeList = [
        "onvif://www.onvif.org/type/Network_Video_Transmitter",
        "onvif://www.onvif.org/type/video_encoder",
        "onvif://www.onvif.org/Profile/Streaming",
        "onvif://www.onvif.org/Profile/G",
        "onvif://www.onvif.org/Profile/T",
        "onvif://www.onvif.org/hardware/DS-2CD2143G0-I",
        "onvif://www.onvif.org/name/HIKVISION%20DS-2CD2143G0-I",
        "onvif://www.onvif.org/location/china",
        "onvif://www.onvif.org/MAC/c4%3A2f%3A90%3Aab%3Acd%3Aef",
    ].joined(separator: " ")

    /// The two service URLs of the §5.4 sample: one IPv4, one bracketed IPv6.
    static let hikvisionXAddrList = "http://192.168.1.64/onvif/device_service "
        + "http://[fe80::c62f:90ff:feab:cdef]/onvif/device_service"

    /// §5.4 — the Hikvision `ProbeMatches`, verbatim.
    static var hikvisionProbeMatchXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope"
                      xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
                      xmlns:wsdd="http://schemas.xmlsoap.org/ws/2005/04/discovery"
                      xmlns:dn="http://www.onvif.org/ver10/network/wsdl"
                      xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
          <env:Header>
            <wsa:MessageID>\(responseMessageID)</wsa:MessageID>
            <wsa:RelatesTo>\(probeMessageID)</wsa:RelatesTo>
            <wsa:To>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:To>
            <wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</wsa:Action>
            <wsdd:AppSequence MessageNumber="7" InstanceId="1751030401"/>
          </env:Header>
          <env:Body>
            <wsdd:ProbeMatches>
              <wsdd:ProbeMatch>
                <wsa:EndpointReference>
                  <wsa:Address>\(hikvisionEndpoint)</wsa:Address>
                </wsa:EndpointReference>
                <wsdd:Types>dn:NetworkVideoTransmitter tds:Device</wsdd:Types>
                <wsdd:Scopes>\(hikvisionScopeList)</wsdd:Scopes>
                <wsdd:XAddrs>\(hikvisionXAddrList)</wsdd:XAddrs>
                <wsdd:MetadataVersion>10</wsdd:MetadataVersion>
              </wsdd:ProbeMatch>
            </wsdd:ProbeMatches>
          </env:Body>
        </env:Envelope>
        """
    }

    /// §5.4 — the Dahua ProbeMatch, in the envelope §14.2 says to wrap it in.
    static var dahuaProbeMatchXML: String {
        let scopes = [
            "onvif://www.onvif.org/type/Network_Video_Transmitter",
            "onvif://www.onvif.org/Profile/Streaming",
            "onvif://www.onvif.org/name/IPC-HDW4433C-A",
            "onvif://www.onvif.org/hardware/IPC-HDW4433C-A",
            "onvif://www.onvif.org/location/country/china",
        ].joined(separator: " ")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope"
                          xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
                          xmlns:wsdd="http://schemas.xmlsoap.org/ws/2005/04/discovery"
                          xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
              <env:Header>
                <wsa:RelatesTo>\(probeMessageID)</wsa:RelatesTo>
                <wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</wsa:Action>
              </env:Header>
              <env:Body>
                <wsdd:ProbeMatches>
                  <wsdd:ProbeMatch>
                    <wsa:EndpointReference>
                      <wsa:Address>\(dahuaEndpoint)</wsa:Address>
                    </wsa:EndpointReference>
                    <wsdd:Types>dn:NetworkVideoTransmitter</wsdd:Types>
                    <wsdd:Scopes>\(scopes)</wsdd:Scopes>
                    <wsdd:XAddrs>http://10.0.20.31/onvif/device_service</wsdd:XAddrs>
                    <wsdd:MetadataVersion>1</wsdd:MetadataVersion>
                  </wsdd:ProbeMatch>
                </wsdd:ProbeMatches>
              </env:Body>
            </env:Envelope>
            """
    }

    /// The Hikvision sample with every namespace prefix renamed. A decoder that compares prefixes
    /// instead of local names fails here and nowhere else.
    static var alternatePrefixProbeMatchXML: String {
        hikvisionProbeMatchXML
            .replacingOccurrences(of: "xmlns:env=", with: "xmlns:s=")
            .replacingOccurrences(of: "xmlns:wsa=", with: "xmlns:a=")
            .replacingOccurrences(of: "xmlns:wsdd=", with: "xmlns:t=")
            .replacingOccurrences(of: "env:", with: "s:")
            .replacingOccurrences(of: "wsa:", with: "a:")
            .replacingOccurrences(of: "wsdd:", with: "t:")
    }

    /// §14.2 `wsd-probematch-noprefix.xml`: the same content with no prefixes and no namespace
    /// declarations at all. Cheap firmware really does send this, and refusing it would mean
    /// refusing the devices most in need of being found.
    static var noNamespaceProbeMatchXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Envelope>
          <Header>
            <MessageID>\(responseMessageID)</MessageID>
            <RelatesTo>\(probeMessageID)</RelatesTo>
            <Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</Action>
            <AppSequence MessageNumber="7" InstanceId="1751030401"/>
          </Header>
          <Body>
            <ProbeMatches>
              <ProbeMatch>
                <EndpointReference>
                  <Address>\(hikvisionEndpoint)</Address>
                </EndpointReference>
                <Types>NetworkVideoTransmitter Device</Types>
                <Scopes>\(hikvisionScopeList)</Scopes>
                <XAddrs>\(hikvisionXAddrList)</XAddrs>
                <MetadataVersion>10</MetadataVersion>
              </ProbeMatch>
            </ProbeMatches>
          </Body>
        </Envelope>
        """
    }

    /// §14.2 `wsd-hello.xml`: an unsolicited announcement, which never carries `RelatesTo`.
    static var helloXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope"
                      xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
                      xmlns:wsdd="http://schemas.xmlsoap.org/ws/2005/04/discovery"
                      xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
          <env:Header>
            <wsa:MessageID>urn:uuid:aaaa1111-2222-4333-8444-555566667777</wsa:MessageID>
            <wsa:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>
            <wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Hello</wsa:Action>
            <wsdd:AppSequence MessageNumber="1" InstanceId="1751030401"/>
          </env:Header>
          <env:Body>
            <wsdd:Hello>
              <wsa:EndpointReference>
                <wsa:Address>\(hikvisionEndpoint)</wsa:Address>
              </wsa:EndpointReference>
              <wsdd:Types>dn:NetworkVideoTransmitter</wsdd:Types>
              <wsdd:Scopes>\(hikvisionScopeList)</wsdd:Scopes>
              <wsdd:XAddrs>http://192.168.1.64/onvif/device_service</wsdd:XAddrs>
              <wsdd:MetadataVersion>10</wsdd:MetadataVersion>
            </wsdd:Hello>
          </env:Body>
        </env:Envelope>
        """
    }

    /// §14.2 `wsd-bye.xml`: the device is leaving.
    static var byeXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope"
                      xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
                      xmlns:wsdd="http://schemas.xmlsoap.org/ws/2005/04/discovery">
          <env:Header>
            <wsa:MessageID>urn:uuid:bbbb1111-2222-4333-8444-555566667777</wsa:MessageID>
            <wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Bye</wsa:Action>
          </env:Header>
          <env:Body>
            <wsdd:Bye>
              <wsa:EndpointReference>
                <wsa:Address>\(hikvisionEndpoint)</wsa:Address>
              </wsa:EndpointReference>
            </wsdd:Bye>
          </env:Body>
        </env:Envelope>
        """
    }

    /// A SOAP envelope carrying an action we do not act on.
    static var resolveActionXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope"
                      xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">
          <env:Header>
            <wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Resolve</wsa:Action>
          </env:Header>
          <env:Body/>
        </env:Envelope>
        """
    }

    /// A datagram engineered to make a decoder allocate: `count` empty ProbeMatch elements inside a
    /// single envelope, small enough to stay under the 8 192-byte cap.
    static func manyProbeMatchesXML(count: Int) -> String {
        let matches = String(repeating: "<wsdd:ProbeMatch/>", count: count)
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope"
                          xmlns:wsdd="http://schemas.xmlsoap.org/ws/2005/04/discovery">
              <env:Body><wsdd:ProbeMatches>\(matches)</wsdd:ProbeMatches></env:Body>
            </env:Envelope>
            """
    }

    /// A fixed arrival instant, so no test depends on the wall clock.
    static let receivedAt = Date(timeIntervalSince1970: 1_785_000_500)
}
