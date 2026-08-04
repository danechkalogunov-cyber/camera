//
//  SADPActivationCodec.swift
//  VigilDiscovery
//
//  SADP activation challenge and encrypted request codec.
//

import Foundation
import VigilProtocols

/// Public material advertised by an inactive device and required before an activation write.
public struct SADPActivationChallenge: Sendable, Hashable {
    public let deviceSerial: String
    public let publicKey: String
    public init(deviceSerial: String, publicKey: String) {
        self.deviceSerial = deviceSerial
        self.publicKey = publicKey
    }
}

/// Byte-exact SADP activation messages. RSA encryption stays at the platform security boundary;
/// this pure codec never accepts or retains the plaintext password.
public enum SADPActivationCodec {
    public static func decodeChallenge(_ payload: Data) throws -> SADPActivationChallenge {
        guard let xml = String(data: payload, encoding: .utf8),
            let serial = text("DeviceSN", xml), !serial.isEmpty,
            let key = text("PublicKey", xml), !key.isEmpty,
            (try? Base64.decodeStrict(key)) != nil
        else {
            throw ISAPIError.malformedResponse("SADP activation challenge omitted DeviceSN/PublicKey")
        }
        return SADPActivationChallenge(deviceSerial: serial, publicKey: key)
    }

    /// Encodes an update datagram after the password was RSA-encrypted with `challenge.publicKey`.
    public static func encodeActivation(
        uuid: UUID, challenge: SADPActivationChallenge,
        encryptedPassword: [UInt8]
    ) throws -> Data {
        guard !encryptedPassword.isEmpty else {
            throw ISAPIError.malformedResponse("SADP activation password ciphertext is empty")
        }
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <Probe>
            <Uuid>\(uuid.uuidString)</Uuid>
            <Types>activate</Types>
            <DeviceSN>\(escape(challenge.deviceSerial))</DeviceSN>
            <Password>\(Base64.encode(encryptedPassword))</Password>
            </Probe>

            """
        return Data(xml.utf8)
    }

    private static func text(_ name: String, _ xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>")?.upperBound,
            let end = xml.range(of: "</\(name)>", range: start..<xml.endIndex)?.lowerBound
        else { return nil }
        return String(xml[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
}
