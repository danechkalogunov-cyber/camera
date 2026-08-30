//
//  ConnectDiagnosisTests.swift
//  VigilUITests
//
//  The behaviour half of the connect diagnoses: which failures Vigil may retry on its own, where the
//  form should move focus, the remedy list (never empty — R1.5's "never a dead end" as a property),
//  and the localisation-key stems. The presentation half (title/message/tint) is @MainActor SwiftUI
//  and is left to the view tests.
//

#if os(macOS)

import Foundation
import Testing

@testable import VigilUI

@Suite("Connect diagnosis behaviour")
struct ConnectDiagnosisTests {

    /// One representative of every case, so a property can be checked across the whole enum.
    private static let allCases: [ConnectDiagnosis] = [
        .notOnThisNetwork(host: "192.168.1.64"),
        .cameraNotActivated(host: "192.168.1.64"),
        .wrongPassword(host: "192.168.1.64"),
        .accountLocked(host: "192.168.1.64", minutesRemaining: 30),
        .signInPausedByVigil(host: "192.168.1.64", minutesRemaining: 5),
        .rtspPortClosed(host: "192.168.1.64", httpPort: 80, rtspPort: 554),
        .notHikvisionDevice(host: "192.168.1.64"),
        .codecUnsupported(host: "192.168.1.64", codec: "H.263"),
        .noPictureUDPBlocked(host: "192.168.1.64"),
        .pictureStalls(host: "192.168.1.64"),
        .undiagnosed(host: "192.168.1.64", detail: "status 500"),
    ]

    // MARK: - Retry policy

    /// ⛔ A rejected password and a locked or unactivated device are never retried automatically —
    /// that is how a camera locks itself out. Everything else may be.
    @Test func onlyCredentialFailuresForbidAutomaticRetry() {
        #expect(!ConnectDiagnosis.wrongPassword(host: "h").allowsAutomaticRetry)
        #expect(!ConnectDiagnosis.accountLocked(host: "h", minutesRemaining: nil).allowsAutomaticRetry)
        #expect(!ConnectDiagnosis.cameraNotActivated(host: "h").allowsAutomaticRetry)

        #expect(ConnectDiagnosis.notOnThisNetwork(host: "h").allowsAutomaticRetry)
        #expect(ConnectDiagnosis.noPictureUDPBlocked(host: "h").allowsAutomaticRetry)
        // Vigil is retrying on its own schedule, so this one must NOT be treated as terminal.
        let paused = ConnectDiagnosis.signInPausedByVigil(host: "h", minutesRemaining: 5)
        #expect(paused.allowsAutomaticRetry)
    }

    // MARK: - Focus

    @Test func focusMovesToThePasswordFieldForEveryCredentialWait() {
        #expect(ConnectDiagnosis.wrongPassword(host: "h").fieldToFocus == .password)
        let locked = ConnectDiagnosis.accountLocked(host: "h", minutesRemaining: nil)
        #expect(locked.fieldToFocus == .password)
        let paused = ConnectDiagnosis.signInPausedByVigil(host: "h", minutesRemaining: 5)
        #expect(paused.fieldToFocus == .password)
    }

    @Test func focusMovesToTheHostFieldForTheReachabilityFailures() {
        #expect(ConnectDiagnosis.notOnThisNetwork(host: "h").fieldToFocus == .host)
        let rtsp = ConnectDiagnosis.rtspPortClosed(host: "h", httpPort: 80, rtspPort: 554)
        #expect(rtsp.fieldToFocus == .host)
        #expect(ConnectDiagnosis.notHikvisionDevice(host: "h").fieldToFocus == .host)
    }

    @Test func someDiagnosesFocusNothing() {
        #expect(ConnectDiagnosis.codecUnsupported(host: "h", codec: "x").fieldToFocus == nil)
        #expect(ConnectDiagnosis.pictureStalls(host: "h").fieldToFocus == nil)
    }

    // MARK: - Remedies

    /// R1.5 as a structural property: no diagnosis is ever a dead end.
    @Test func everyDiagnosisOffersAtLeastOneRemedy() {
        for diagnosis in Self.allCases {
            #expect(!diagnosis.remedies.isEmpty, "\(diagnosis) offered no remedy")
        }
    }

    @Test func theFirstRemedyIsTheOneTheFailureCallsFor() {
        #expect(ConnectDiagnosis.cameraNotActivated(host: "h").remedies.first == .activateCamera)
        #expect(ConnectDiagnosis.wrongPassword(host: "h").remedies.first == .updatePassword)
        let rtsp = ConnectDiagnosis.rtspPortClosed(host: "h", httpPort: 80, rtspPort: 554)
        #expect(rtsp.remedies.first == .tryAlternateRTSPPort)
        #expect(ConnectDiagnosis.noPictureUDPBlocked(host: "h").remedies.first == .switchToTCP)
        #expect(ConnectDiagnosis.notHikvisionDevice(host: "h").remedies.first == .useONVIF)
    }

    // MARK: - Details and keys

    /// The raw status line lives only behind the `undiagnosed` disclosure.
    @Test func onlyTheUndiagnosedCaseCarriesADetailsString() {
        for diagnosis in Self.allCases {
            let isUndiagnosed: Bool
            if case .undiagnosed = diagnosis { isUndiagnosed = true } else { isUndiagnosed = false }
            #expect((diagnosis.details != nil) == isUndiagnosed, "details mismatch for \(diagnosis)")
        }
        #expect(ConnectDiagnosis.undiagnosed(host: "h", detail: "status 500").details == "status 500")
    }

    @Test func localizationKeysAreDistinctPerCase() {
        let keys = Self.allCases.map(\.localizationKey)
        #expect(Set(keys).count == keys.count, "localisation keys collided: \(keys)")
        #expect(ConnectDiagnosis.wrongPassword(host: "h").localizationKey == "error.auth.wrongPassword")
    }
}

#endif  // os(macOS)
