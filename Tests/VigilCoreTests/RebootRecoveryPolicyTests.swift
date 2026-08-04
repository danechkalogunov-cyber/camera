#if os(macOS)

import Testing
@testable import VigilCore

@Suite("Camera reboot recovery policy")
struct RebootRecoveryPolicyTests {
    @Test("reboot-shaped failures are reprobed within the L18 detection budget")
    func rebootFailuresUseFastProbe() {
        let policy = ReconnectPolicy(coldRetryInterval: .seconds(300),
                                     rebootProbeInterval: .seconds(2))
        let rebootFailures: [StreamError.Code] = [
            .connectionClosed, .sessionLost, .connectTimeout, .hostResolutionFailed,
            .transportError, .portClosed,
        ]
        for failure in rebootFailures {
            #expect(policy.offlineDelay(for: failure) == .seconds(2))
        }
    }

    @Test("configuration failures retain cold retry and auth never reaches this policy")
    func nonRebootFailureStaysCold() {
        let policy = ReconnectPolicy(coldRetryInterval: .seconds(300),
                                     rebootProbeInterval: .seconds(2))
        #expect(policy.offlineDelay(for: .unsupportedMedia) == .seconds(300))
        #expect(StreamError.Code.authenticationFailed.forbidsColdRetry)
    }
}

#endif
