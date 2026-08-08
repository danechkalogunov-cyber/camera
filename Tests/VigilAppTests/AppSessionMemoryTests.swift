//
//  AppSessionMemoryTests.swift
//  VigilAppTests
//
//  What survives quitting, and what the next launch does with it.
//
//  ⛔ EVERY DEFECT THESE TESTS PIN DOWN WAS SHIPPED. The remembered connection is four lines of
//  `UserDefaults` access, and in the space of one week it lost a rename on the first reconnect, reset
//  the chrome preference on every archive seek, and minted a fresh `CameraID` per launch — which put
//  the same camera in the sidebar twice and detached its group, its bookmarks and its clips. None of
//  those needed a camera to find. They needed a test, and there was no way to build an
//  `AppSessionModel` in one until `AppSessionHarness` existed.
//
//  ⚠️ Nothing here opens a socket. Every path tested is one the app decides on its own: what it
//  writes down, what it reads back, and which Keychain handle it reuses.
//

#if os(macOS)

import Foundation
import Testing

@testable import Vigil
import VigilCore
import VigilProtocols
import VigilUI

@Suite("The remembered connection")
@MainActor
struct AppSessionMemoryTests {

    // MARK: - Round trip

    /// Every field goes in and comes back out, ``LastConnection/cameraID`` among them.
    @Test func savingAndLoadingReturnsEveryField() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let identity = CameraID()
        let ref = CredentialRef()

        let record = LastConnection(host: "192.168.1.64",
                                    account: "operator",
                                    credentialRef: ref,
                                    rtspPath: "/Streaming/Channels/101",
                                    name: "Front door",
                                    cameraID: identity,
                                    showsVideoOverlay: false)
        record.save(to: harness.defaults)

        let loaded = LastConnection.load(from: harness.defaults)
        #expect(loaded == record)
    }

    /// A record written before the identity field existed loads without one, and is not discarded.
    @Test func aRecordWithoutAnIdentityStillLoads() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let record = LastConnection(host: "192.168.1.64",
                                    account: "admin",
                                    credentialRef: CredentialRef(),
                                    rtspPath: nil)
        record.save(to: harness.defaults)

        let loaded = LastConnection.load(from: harness.defaults)
        #expect(loaded?.cameraID == nil)
        #expect(loaded?.host == "192.168.1.64")
    }

    /// A half-written record is "nothing remembered", not an error: the cost is one screen of
    /// typing and there is no state worth recovering.
    @Test func anIncompleteRecordIsNothingRemembered() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        harness.defaults.set("192.168.1.64", forKey: "vigil.lastConnection.host")
        harness.defaults.set("not-a-uuid", forKey: "vigil.lastConnection.credentialRef")

        #expect(LastConnection.load(from: harness.defaults) == nil)
    }

    /// ⛔ The chrome is shown until the user hides it. `UserDefaults.bool(forKey:)` answers `false`
    /// for a missing key, so reading the flag rather than its *presence* would have hidden the
    /// overlay for every existing user on the launch this field shipped.
    @Test func theOverlayIsShownWhenNothingHasBeenStored() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        #expect(harness.model.remembersVideoOverlay)

        LastConnection(host: "192.168.1.64",
                       account: "admin",
                       credentialRef: CredentialRef(),
                       rtspPath: nil).save(to: harness.defaults)

        #expect(LastConnection.load(from: harness.defaults)?.showsVideoOverlay == true)
    }

    /// Forgetting leaves nothing behind, so the next launch shows the form.
    @Test func clearingRemovesEveryField() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        LastConnection(host: "192.168.1.64",
                       account: "admin",
                       credentialRef: CredentialRef(),
                       rtspPath: "/Streaming/Channels/101",
                       name: "Front door",
                       cameraID: CameraID(),
                       showsVideoOverlay: false).save(to: harness.defaults)

        LastConnection.clear(in: harness.defaults)

        #expect(LastConnection.load(from: harness.defaults) == nil)
        #expect(harness.model.remembersVideoOverlay, "a cleared record is a first launch again")
    }

    // MARK: - The Keychain handle

    /// The remembered handle is reused, because minting a fresh one on every connect would leave
    /// the old Keychain item behind as an orphan and lose the learned RTSP path with it.
    @Test func theRememberedHandleIsReusedForTheSameHostAndAccount() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let ref = CredentialRef()
        LastConnection(host: "192.168.1.64",
                       account: "admin",
                       credentialRef: ref,
                       rtspPath: "/Streaming/Channels/101").save(to: harness.defaults)

        harness.model.form.host = "192.168.1.64"
        harness.model.form.username = "admin"
        let known = harness.model.knownHandle(for: harness.model.form.request)

        #expect(known.ref == ref)
        #expect(known.rtspPath == "/Streaming/Channels/101")
    }

    /// A host typed in another case is the same host. `192.168.1.64` cannot vary, but a name can,
    /// and a case-sensitive compare would silently mint a second credential for one camera.
    @Test func theHostIsMatchedWithoutRegardToLetterCase() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let ref = CredentialRef()
        LastConnection(host: "Front-Door.local",
                       account: "admin",
                       credentialRef: ref,
                       rtspPath: nil).save(to: harness.defaults)

        harness.model.form.host = "front-door.local"
        #expect(harness.model.knownHandle(for: harness.model.form.request).ref == ref)
    }

    /// A different account on the same address is a different credential, so nothing is reused —
    /// including the learned path, which belongs to the account that was allowed to stream.
    @Test func aDifferentAccountGetsAFreshHandle() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let ref = CredentialRef()
        LastConnection(host: "192.168.1.64",
                       account: "admin",
                       credentialRef: ref,
                       rtspPath: "/Streaming/Channels/101").save(to: harness.defaults)

        harness.model.form.host = "192.168.1.64"
        harness.model.form.username = "operator"
        let known = harness.model.knownHandle(for: harness.model.form.request)

        #expect(known.ref != ref)
        #expect(known.rtspPath == nil)
    }

    /// The trimmed request is what matches, which is why the record stores the trimmed account: a
    /// name typed with a trailing space must not fail to match itself.
    @Test func aTrailingSpaceInTheAccountStillMatches() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let ref = CredentialRef()
        LastConnection(host: "192.168.1.64",
                       account: "admin",
                       credentialRef: ref,
                       rtspPath: nil).save(to: harness.defaults)

        harness.model.form.host = " 192.168.1.64 "
        harness.model.form.username = "admin "
        #expect(harness.model.knownHandle(for: harness.model.form.request).ref == ref)
    }

    // MARK: - Writing the record on the first frame

    /// ⛔ THE MERGE RULE. `rememberThisCamera()` runs on **every** first frame — so after every
    /// reconnect and every archive seek — and it used to build a fresh record each time, silently
    /// resetting every field it did not mention. The chrome preference was the visible casualty:
    /// the user turned it off, the next seek turned it back on, and the setting looked like it had
    /// never saved.
    @Test func rememberingAgainKeepsTheChromePreference() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let model = harness.model
        model.form.host = "192.168.1.64"
        model.camera = harness.camera()
        model.activeRef = CredentialRef()
        model.resolvedPath = "/Streaming/Channels/101"
        model.rememberThisCamera()

        model.rememberVideoOverlay(false)
        model.rememberThisCamera()

        #expect(model.remembersVideoOverlay == false)
        #expect(LastConnection.load(from: harness.defaults)?.rtspPath == "/Streaming/Channels/101")
    }

    /// A different address is a different camera, so its settings do not come along.
    @Test func aDifferentHostRebuildsTheRecord() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let model = harness.model
        model.form.host = "192.168.1.64"
        model.camera = harness.camera()
        model.activeRef = CredentialRef()
        model.rememberThisCamera()
        model.rememberVideoOverlay(false)

        model.camera = harness.camera(host: "192.168.1.65", name: "Yard")
        model.rememberThisCamera()

        let loaded = LastConnection.load(from: harness.defaults)
        #expect(loaded?.host == "192.168.1.65")
        #expect(loaded?.showsVideoOverlay == true, "the new camera has never been configured")
    }

    /// ⛔ The identity is written down, which is what makes the next launch resume *this* camera
    /// rather than mint a new one at the same address — the bug that drew one camera twice.
    @Test func theCameraIdentityIsRemembered() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let model = harness.model
        let camera = harness.camera()
        model.form.host = camera.host
        model.camera = camera
        model.activeRef = CredentialRef()

        model.rememberThisCamera()

        #expect(LastConnection.load(from: harness.defaults)?.cameraID == camera.id)
    }

    /// Nothing is written before there is a picture: without a Keychain handle there is no
    /// connection worth resuming.
    @Test func nothingIsRememberedWithoutAHandle() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        harness.model.camera = harness.camera()

        harness.model.rememberThisCamera()

        #expect(LastConnection.load(from: harness.defaults) == nil)
    }

    /// A rename reaches the record without disturbing the account or the learned path, and works
    /// before any frame has arrived — which is when the sidebar row can first be renamed.
    @Test func renamingKeepsTheRestOfTheRecord() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let ref = CredentialRef()
        LastConnection(host: "192.168.1.64",
                       account: "operator",
                       credentialRef: ref,
                       rtspPath: "/Streaming/Channels/101").save(to: harness.defaults)

        harness.model.rememberCameraName("Back gate")

        let loaded = LastConnection.load(from: harness.defaults)
        #expect(loaded?.name == "Back gate")
        #expect(loaded?.account == "operator")
        #expect(loaded?.credentialRef == ref)
        #expect(loaded?.rtspPath == "/Streaming/Channels/101")
    }

    // MARK: - The launch path

    /// With nothing remembered the form is shown and no session is started.
    @Test func aFirstLaunchShowsTheForm() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }

        harness.model.resumeOrPrompt()

        #expect(harness.model.phase == .connect)
        #expect(harness.model.sessionTask == nil)
    }

    /// The window's `.task` fires again when it is closed and reopened. Resuming twice would build
    /// a second controller for one camera and leak the first.
    @Test func resumingHappensOnceOnly() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        harness.model.resumeOrPrompt()

        LastConnection(host: "192.168.1.64",
                       account: "admin",
                       credentialRef: CredentialRef(),
                       rtspPath: nil).save(to: harness.defaults)
        harness.model.resumeOrPrompt()

        #expect(harness.model.sessionTask == nil)
        #expect(harness.model.form.host.isEmpty, "the second call must not read the record either")
    }

    /// ⛔ The remembered camera whose password the user deleted in Keychain Access. Vigil must ask
    /// again rather than fail silently at every launch — and must forget the record, so the *next*
    /// launch goes straight to the form.
    @Test func aRememberedCameraWithNoStoredPasswordFallsBackToTheForm() async {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        LastConnection(host: "192.168.1.64",
                       account: "operator",
                       credentialRef: CredentialRef(),
                       rtspPath: "/Streaming/Channels/101").save(to: harness.defaults)

        harness.model.resumeOrPrompt()
        await harness.model.sessionTask?.value

        #expect(harness.model.phase == .connect)
        #expect(harness.model.form.isConnecting == false)
        #expect(harness.model.form.host == "192.168.1.64", "the address is still prefilled")
        #expect(harness.model.form.username == "operator")
        #expect(LastConnection.load(from: harness.defaults) == nil)
    }
}

#endif  // os(macOS)
