//
//  DeviceActivation.swift
//  VigilISAPI
//
//  First-password activation for an uninitialised Hikvision device.
//  Implements docs/spec-discovery.md §4.6.
//

import Foundation

// MARK: - ActivationPasswordPolicy

/// The password rules enforced by the device activation API.
public enum ActivationPasswordPolicy {

    /// A reason a proposed first password cannot be sent to the device.
    public enum Failure: Sendable, Hashable {
        case length
        case complexity
        case containsUsername
    }

    /// Validates the UTF-8 password before it can cross the network.
    public static func validate(_ password: String, username: String = "admin") -> Failure? {
        guard (8...16).contains(password.count) else { return .length }
        guard password.range(of: username, options: .caseInsensitive) == nil else {
            return .containsUsername
        }

        let special = Set(" !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
        var categories = 0
        if password.contains(where: { $0.isLowercase }) { categories += 1 }
        if password.contains(where: { $0.isUppercase }) { categories += 1 }
        if password.contains(where: { $0.isNumber }) { categories += 1 }
        if password.contains(where: { special.contains($0) }) { categories += 1 }
        return categories >= 2 ? nil : .complexity
    }
}

// MARK: - DeviceActivation

/// Encodes and sends the unauthenticated first-password request.
public enum DeviceActivation {

    /// Activates a device. Callers must validate with ``ActivationPasswordPolicy`` first.
    public static func activate(password: String,
                                using requests: any ISAPIRequesting) async throws(ISAPIError) {
        guard ActivationPasswordPolicy.validate(password) == nil else {
            throw .malformedResponse("activation password does not satisfy device policy")
        }
        let escaped = password
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<ActivateInfo><password>\(escaped)</password></ActivateInfo>"
        _ = try await requests.putDocument(ISAPIResource.activate,
                                           body: Data(xml.utf8), query: [], lane: .control)
    }
}
