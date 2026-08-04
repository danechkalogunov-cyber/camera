//
//  WSUsernameToken.swift
//  VigilDiscovery
//
//  WS-Security UsernameToken digest and XML encoding.
//

import Foundation
import VigilProtocols

/// Dependency-free WS-Security UsernameToken used by ONVIF devices.
public struct WSUsernameToken: Sendable, Hashable {
    public let username: String
    public let passwordDigest: String
    public let nonce: String
    public let created: String

    public init(username: String, password: String, nonce: [UInt8], created: String) {
        var input = nonce
        input.append(contentsOf: created.utf8)
        input.append(contentsOf: password.utf8)
        self.username = username
        self.passwordDigest = Base64.encode(SHA1.digest(input))
        self.nonce = Base64.encode(nonce)
        self.created = created
    }

    public var xml: String {
        """
        <wsse:Security s:mustUnderstand="1"><wsse:UsernameToken>
        <wsse:Username>\(Self.escape(username))</wsse:Username>
        <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/\
        oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(passwordDigest)</wsse:Password>
        <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/\
        oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonce)</wsse:Nonce>
        <wsu:Created>\(created)</wsu:Created></wsse:UsernameToken></wsse:Security>
        """
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
