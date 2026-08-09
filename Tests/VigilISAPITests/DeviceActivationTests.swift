//
//  DeviceActivationTests.swift
//  VigilISAPITests
//

import Testing
@testable import VigilISAPI

@Suite struct DeviceActivationSuite {

    @Test func passwordPolicyMatchesTheDocumentedDeviceRules() {
        #expect(ActivationPasswordPolicy.validate("Short1!") == .length)
        #expect(ActivationPasswordPolicy.validate("lowercaseonly") == .complexity)
        #expect(ActivationPasswordPolicy.validate("MyAdmin42!") == .containsUsername)
        #expect(ActivationPasswordPolicy.validate("Door-Camera42!") == nil)
    }

    @Test func activationSendsEscapedPasswordToTheExactResource() async throws {
        let requests = RequestDouble()

        try await DeviceActivation.activate(password: "Door&Cam42!", using: requests)

        let recorded = await requests.recorded
        #expect(recorded.count == 1)
        #expect(recorded.first?.method == "PUT")
        #expect(recorded.first?.resource == "/System/activate")
        #expect(recorded.first?.bodyText
                == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
                + "<ActivateInfo><password>Door&amp;Cam42!</password></ActivateInfo>")
    }
}
