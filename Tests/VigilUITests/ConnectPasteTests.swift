//
//  ConnectPasteTests.swift
//  VigilUITests
//
//  Pasting a whole camera URL into the address field.
//  Covers `ConnectFormState.absorbPastedURL()`; see docs/UX.md §12 ("auto-parses into every field").
//
//  The port and the path are the point of this file. They were dropped for as long as the method
//  existed, so pasting the URL a camera's own web page hands you threw away the two parts that are
//  hardest to retype — and the user then watched the probe ladder search for a path they had just
//  supplied.
//
//  ⚠️ EVERY CALL IS HOISTED INTO A `let`, DELIBERATELY. `#expect(form.absorbPastedURL())` does not
//  compile: swift-testing rewrites a bare call into `__checkFunctionCall(form.self, calling: {
//  $0.absorbPastedURL() })` so it can print the receiver on failure, and that `$0` is a `let`, which
//  a `mutating` method may not touch. The error names a line inside the expanded macro rather than
//  this file, so it is worth recognising once. `Scripts/lint.py` now catches it — see
//  `check_mutating_in_expect`.
//

#if os(macOS)

import Foundation
import Testing

@testable import VigilUI

// MARK: - Full URL

/// The shape UX.md names: everything in one paste.
@Test func connectPasteFillsEveryFieldFromAFullURL() {
    var form = ConnectFormState()
    form.host = "rtsp://admin:secret@192.168.1.64:554/Streaming/Channels/101"
    let applied = form.absorbPastedURL()
    #expect(applied)
    #expect(form.host == "192.168.1.64")
    #expect(form.username == "admin")
    #expect(form.password == "secret")
    #expect(form.rtspPort == 554)
    #expect(form.rtspPath == "/Streaming/Channels/101")
    #expect(form.usesTLS == false)
}

/// A non-default port is kept. This is the case that makes the feature worth having: a camera behind
/// a port map is exactly where retyping is error-prone.
@Test func connectPasteKeepsANonDefaultPort() {
    var form = ConnectFormState()
    form.host = "rtsp://192.168.1.64:8554/Streaming/Channels/102"
    let applied = form.absorbPastedURL()
    #expect(applied)
    #expect(form.rtspPort == 8554)
    #expect(form.rtspPath == "/Streaming/Channels/102")
}

/// The query rides with the path.
///
/// Hikvision addresses the archive with `?starttime=` (spec-isapi.md §15.6). A path stripped of its
/// query would open the live stream while claiming to open a recording.
@Test func connectPasteKeepsTheQueryWithThePath() {
    var form = ConnectFormState()
    form.host = "rtsp://192.168.1.64/Streaming/tracks/101?starttime=20260803T090000Z"
    let applied = form.absorbPastedURL()
    #expect(applied)
    #expect(form.rtspPath == "/Streaming/tracks/101?starttime=20260803T090000Z")
}

/// A bare `/` is not a path. It is what a browser adds, and storing it would override the probe
/// ladder with nothing.
@Test func connectPasteTreatsABareSlashAsNoPath() {
    var form = ConnectFormState()
    form.host = "rtsp://192.168.1.64/"
    let applied = form.absorbPastedURL()
    #expect(applied)
    #expect(form.host == "192.168.1.64")
    #expect(form.rtspPath == nil)
}

/// `rtsps://` is recorded even though no transport uses it yet, so the one bit of the address that
/// says "encrypted" is not silently lost.
@Test func connectPasteRecordsTLSFromTheScheme() {
    var form = ConnectFormState()
    form.host = "rtsps://192.168.1.64:322/Streaming/Channels/101"
    let applied = form.absorbPastedURL()
    #expect(applied)
    #expect(form.usesTLS)
    #expect(form.rtspPort == 322)
}

// MARK: - What must not be touched

/// A URL without credentials must not blank a password the user has already typed.
@Test func connectPasteDoesNotClearATypedPassword() {
    var form = ConnectFormState()
    form.password = "already typed"
    form.host = "rtsp://192.168.1.64/Streaming/Channels/101"
    let applied = form.absorbPastedURL()
    #expect(applied)
    #expect(form.password == "already typed")
    #expect(form.username == "admin")
}

/// A bare address is left exactly as typed. Rewriting a host under the cursor would be worse than
/// doing nothing.
@Test func connectPasteLeavesABareAddressAlone() {
    var form = ConnectFormState()
    form.host = "192.168.1.64"
    let applied = form.absorbPastedURL()
    #expect(applied == false)
    #expect(form.host == "192.168.1.64")
}

/// A scheme that is not a camera is ignored rather than expanded.
@Test func connectPasteIgnoresAnUnrelatedScheme() {
    var form = ConnectFormState()
    form.host = "ftp://192.168.1.64/pub"
    let applied = form.absorbPastedURL()
    #expect(applied == false)
    #expect(form.host == "ftp://192.168.1.64/pub")
    #expect(form.rtspPath == nil)
}

// MARK: - The clearing arm

/// ⛔ The regression this guards is invisible state surviving an edit.
///
/// `rtspPath` is not displayed by the form, and `absorbPastedURL()` is its only writer. If a path
/// from a pasted URL survived the user editing the address into a different camera, it would
/// override the probe ladder for a device it does not belong to — which looks exactly like the app
/// connecting to the wrong stream, with nothing on screen to explain it. `rtspPort` *is* displayed,
/// so the same edit has to put it back to 554 rather than leave the previous camera's `:8554`
/// sitting in a visible field under a new address.
@Test func connectPasteClearsThePathWhenTheAddressStopsBeingAURL() {
    var form = ConnectFormState()
    form.host = "rtsp://192.168.1.64:8554/Streaming/Channels/102"
    let pasted = form.absorbPastedURL()
    #expect(pasted)
    #expect(form.rtspPath != nil)
    #expect(form.rtspPort == 8554)

    // The user selects the field and types a different camera's address.
    form.host = "192.168.1.70"
    let afterEditingTheAddress = form.absorbPastedURL()
    #expect(afterEditingTheAddress == false)
    #expect(form.rtspPath == nil)
    #expect(form.rtspPort == 554)
    #expect(form.usesTLS == false)
}

/// Pasting a second URL replaces the first one's path rather than merging with it.
@Test func connectPasteReplacesAPreviousURLsPath() {
    var form = ConnectFormState()
    form.host = "rtsp://192.168.1.64:8554/Streaming/Channels/102"
    let firstPaste = form.absorbPastedURL()
    #expect(firstPaste)
    form.host = "rtsp://192.168.1.70/Streaming/Channels/201"
    let secondPaste = form.absorbPastedURL()
    #expect(secondPaste)
    #expect(form.host == "192.168.1.70")
    #expect(form.rtspPath == "/Streaming/Channels/201")
    #expect(form.rtspPort == 554)
}

@Test func connectRequestCarriesVisibleConnectionCoordinates() {
    var form = ConnectFormState()
    form.host = "192.168.1.64"
    form.password = "secret"
    form.httpPort = 8443
    form.rtspPort = 8554
    form.channel = 7
    form.usesTLS = true

    #expect(form.request.httpPort == 8443)
    #expect(form.request.rtspPort == 8554)
    #expect(form.request.channel == 7)
    #expect(form.request.usesTLS)
}

#endif  // os(macOS)
