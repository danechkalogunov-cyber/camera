//
//  ConnectDiagnosis.swift
//  VigilUI
//
//  The named causes a failed connection can resolve to, and the words and actions each one gets.
//  macOS-only. Implements docs/REQUIREMENTS-CUSTOMER.md §R1.5, docs/UX.md §8.4, §12.7 and §14.
//
//  ⛔ The rule this file exists to enforce: **a failure is never a code and never a dead end.**
//  Every case below names a cause in the user's words and offers at least one concrete next action,
//  because "Connection failed (-12909)" costs the customer a support call and tells them nothing.
//

#if os(macOS)

import SwiftUI

// MARK: - ConnectDiagnosis

/// A named reason a connection attempt did not produce a picture.
///
/// The nine cases required by R1.5 are all here, plus ``undiagnosed(host:detail:)`` for the case
/// the Stream Doctor cannot classify — which still names a cause in plain words, still offers an
/// action, and puts the raw status line behind a `Details` disclosure where support can find it
/// rather than in front of the user (UX.md §8.4).
///
/// The type is a `Sendable` value with `String`/`Int` payloads so that `VigilCore` can produce it
/// off the main actor and hand it to the UI; only its presentation (title, message, tint, glyph)
/// is main-actor isolated, because that half reads `VTheme`.
package enum ConnectDiagnosis: Sendable, Hashable {

    /// No TCP route to either port: the camera is off, on another subnet, or behind a firewall.
    case notOnThisNetwork(host: String)

    /// A factory-fresh camera with no password set. It must be activated before it will talk.
    case cameraNotActivated(host: String)

    /// A `401` that persisted after a Digest retry with a fresh nonce. The password is wrong.
    ///
    /// ⛔ This is terminal and is **never** retried automatically: retrying a wrong password is
    /// exactly how Hikvision devices lock themselves out (UX.md §12.7).
    case wrongPassword(host: String)

    /// The device reports the account locked. `minutesRemaining` is `nil` when it does not say.
    case accountLocked(host: String, minutesRemaining: Int?)

    /// HTTP answered and RTSP refused: RTSP is switched off in the camera, or a firewall eats 554.
    case rtspPortClosed(host: String, httpPort: Int, rtspPort: Int)

    /// Something answered, but its fingerprint is not Hikvision and it does not speak ISAPI.
    case notHikvisionDevice(host: String)

    /// The SDP advertises a codec Vigil cannot decode. `codec` is what the camera actually offered.
    case codecUnsupported(host: String, codec: String)

    /// RTSP `PLAY` succeeded but no RTP arrived: almost always UDP blocked between here and there.
    case noPictureUDPBlocked(host: String)

    /// RTP is flowing but no complete picture: the keyframe interval is too long, or the keyframe
    /// was lost and the camera has not sent another.
    case pictureStalls(host: String)

    /// The doctor ran and could not classify the result. `detail` is the raw, redacted status line
    /// and belongs behind a disclosure, never in the headline (UX.md §8.4, §14.1 rule 3).
    case undiagnosed(host: String, detail: String)
}

// MARK: - Behaviour

extension ConnectDiagnosis {

    /// Whether Vigil may retry this on its own.
    ///
    /// `false` for the two credential failures. Automatic retry after a rejected password is how a
    /// camera ends up locked out, and a locked camera cannot be helped by trying again either
    /// (UX.md §12.7; spec-core.md §7.5 transition 11).
    package var allowsAutomaticRetry: Bool {
        switch self {
        case .wrongPassword, .accountLocked, .cameraNotActivated:
            return false
        case .notOnThisNetwork, .rtspPortClosed, .notHikvisionDevice, .codecUnsupported,
             .noPictureUDPBlocked, .pictureStalls, .undiagnosed:
            return true
        }
    }

    /// Which field the form should move focus to, so the user's next keystroke lands where the fix
    /// is (UX.md §8.4, "Primary fix offered").
    package var fieldToFocus: ConnectField? {
        switch self {
        case .wrongPassword, .accountLocked:
            return .password
        case .notOnThisNetwork, .rtspPortClosed, .notHikvisionDevice:
            return .host
        case .cameraNotActivated, .codecUnsupported, .noPictureUDPBlocked, .pictureStalls,
             .undiagnosed:
            return nil
        }
    }

    /// The remedies to offer, most useful first. The first is drawn as the primary button.
    ///
    /// Never empty: R1.5's "never a dead end" is a structural property of this list, not a
    /// convention someone has to remember.
    package var remedies: [ConnectRemedy] {
        switch self {
        case .notOnThisNetwork:
            return [.checkAddress, .retry]
        case .cameraNotActivated:
            return [.activateCamera, .openCameraWebPage]
        case .wrongPassword:
            return [.updatePassword, .runStreamDoctor]
        case .accountLocked:
            return [.openCameraWebPage, .runStreamDoctor]
        case .rtspPortClosed:
            return [.tryAlternateRTSPPort, .openCameraWebPage]
        case .notHikvisionDevice:
            return [.useONVIF, .runStreamDoctor]
        case .codecUnsupported:
            return [.openCameraWebPage, .runStreamDoctor]
        case .noPictureUDPBlocked:
            return [.switchToTCP, .retry]
        case .pictureStalls:
            return [.retry, .runStreamDoctor]
        case .undiagnosed:
            return [.runStreamDoctor, .retry]
        }
    }

    /// The raw status line for the `Details` disclosure, when there is one. Redacted upstream.
    package var details: String? {
        if case .undiagnosed(_, let detail) = self { return detail }
        return nil
    }

    /// The canonical localisation key stem, per UX.md §14.2's `surface.subject.variant` scheme.
    ///
    /// The visible copy below is written as the English source string so that the slice reads
    /// correctly before `Localizable.xcstrings` exists; this property is the mapping the
    /// localisation pass consumes, so the two never have to be reverse-engineered from each other.
    package var localizationKey: String {
        switch self {
        case .notOnThisNetwork: return "error.unreachable"
        case .cameraNotActivated: return "error.notActivated"
        case .wrongPassword: return "error.auth.wrongPassword"
        case .accountLocked: return "error.auth.locked"
        case .rtspPortClosed: return "error.rtspBlocked"
        case .notHikvisionDevice: return "error.notHikvision"
        case .codecUnsupported: return "error.codecUnsupported"
        case .noPictureUDPBlocked: return "error.noMedia"
        case .pictureStalls: return "error.noKeyframe"
        case .undiagnosed: return "error.undiagnosed"
        }
    }
}

// MARK: - Presentation

extension ConnectDiagnosis {

    /// The headline: the fact, in at most six words, ending in a full stop (UX.md §14.1 rule 1).
    @MainActor
    package var title: Text {
        switch self {
        case .notOnThisNetwork:
            return Text("Can't reach this camera.", bundle: .module)
        case .cameraNotActivated:
            return Text("Camera isn't activated.", bundle: .module)
        case .wrongPassword:
            return Text("Wrong password.", bundle: .module)
        case .accountLocked:
            return Text("Device is locked.", bundle: .module)
        case .rtspPortClosed:
            return Text("Video port is closed.", bundle: .module)
        case .notHikvisionDevice:
            return Text("Not a Hikvision device.", bundle: .module)
        case .codecUnsupported:
            return Text("Unsupported video format.", bundle: .module)
        case .noPictureUDPBlocked:
            return Text("No video is arriving.", bundle: .module)
        case .pictureStalls:
            return Text("The picture has stalled.", bundle: .module)
        case .undiagnosed:
            return Text("Vigil couldn't finish signing in.", bundle: .module)
        }
    }

    /// The cause and the next step, in at most two sentences (UX.md §14.1 rule 1).
    ///
    /// Every argument is interpolated into a **single** key so a translator can reorder it; nothing
    /// here is assembled from fragments (§14.2, "Never concatenate").
    @MainActor
    package var message: Text {
        // Each message is one multi-line *literal* with `\` continuations, not two literals joined
        // with `+`: `LocalizedStringKey` is expressible by string interpolation, so a concatenated
        // `String` would silently take `Text`'s non-localising initialiser instead.
        switch self {
        case .notOnThisNetwork(let host):
            return Text("""
                No response from \(host). Check that it's powered on and on the same network \
                as this Mac.
                """, bundle: .module)
        case .cameraNotActivated(let host):
            return Text("""
                \(host) is brand new and has no password yet. Set one now to start using it.
                """, bundle: .module)
        case .wrongPassword(let host):
            return Text("""
                \(host) rejected this password. Check it and try again — too many attempts \
                will lock the device.
                """, bundle: .module)
        case .accountLocked(let host, let minutes):
            if let minutes {
                return Text("""
                    \(host) locked this account after too many failed sign-ins. It usually \
                    unlocks in about \(minutes) minutes.
                    """, bundle: .module)
            }
            return Text("""
                \(host) locked this account after too many failed sign-ins. It unlocks on its \
                own, or immediately if you reboot the camera.
                """, bundle: .module)
        case .rtspPortClosed(let host, let httpPort, let rtspPort):
            return Text("""
                Vigil reached \(host) on port \(httpPort), but RTSP port \(rtspPort) refused \
                the connection.
                """, bundle: .module)
        case .notHikvisionDevice(let host):
            return Text("""
                \(host) answered, but it doesn't speak ISAPI. Vigil can still try ONVIF, \
                with fewer features.
                """, bundle: .module)
        case .codecUnsupported(_, let codec):
            return Text("""
                This camera streams \(codec). Vigil plays H.265, H.264 and MJPEG.
                """, bundle: .module)
        case .noPictureUDPBlocked(let host):
            return Text("""
                \(host) started the stream but sent no video. Something on the network is \
                blocking UDP.
                """, bundle: .module)
        case .pictureStalls(let host):
            return Text("""
                \(host) is sending data but no complete picture yet. Vigil has asked it for a \
                new keyframe.
                """, bundle: .module)
        case .undiagnosed(let host, _):
            return Text("""
                \(host) answered, but not in a way Vigil recognises. The device's own reply is \
                in the details below.
                """, bundle: .module)
        }
    }

    /// The glyph, from the typed symbol map — never a string literal (§8.3).
    @MainActor
    package var symbol: VTheme.Symbol {
        switch self {
        case .notOnThisNetwork: return .network
        case .cameraNotActivated: return .warning
        case .wrongPassword: return .authFailure
        case .accountLocked: return .locked
        case .rtspPortClosed: return .network
        case .notHikvisionDevice: return .info
        case .codecUnsupported: return .warning
        case .noPictureUDPBlocked: return .videoLoss
        case .pictureStalls: return .latency
        case .undiagnosed: return .streamDoctor
        }
    }

    /// The semantic colour, matching UX.md §8.4's row glyphs: red for the two credential failures,
    /// amber for the things the user can change on the device, grey for "nothing answered", and
    /// the accent for informational outcomes.
    ///
    /// ⛔ These are the *reserved* status hues (§3.2, P3). They are never used decoratively, which
    /// is exactly what makes them readable here.
    @MainActor
    package var tint: SwiftUI.Color {
        switch self {
        case .wrongPassword, .accountLocked:
            return VTheme.Color.Semantic.danger
        case .cameraNotActivated, .rtspPortClosed, .codecUnsupported, .noPictureUDPBlocked,
             .pictureStalls:
            return VTheme.Color.Semantic.warn
        case .notOnThisNetwork:
            return VTheme.Color.Text.tertiary
        case .notHikvisionDevice, .undiagnosed:
            return VTheme.Color.Semantic.accent
        }
    }
}

// MARK: - ConnectRemedy

/// A concrete next action offered beside a diagnosis.
///
/// The screen renders these; the app target performs them. Keeping them as a closed set rather
/// than as closures is what lets the diagnosis table above state, in one place, that every failure
/// has a way forward.
package enum ConnectRemedy: Sendable, Hashable, CaseIterable {

    /// Try the same connection again.
    case retry

    /// Put the cursor back in the host field.
    case checkAddress

    /// Put the cursor back in the password field.
    case updatePassword

    /// Run the activation flow, which sets the device's first password.
    case activateCamera

    /// Retry on the common alternative RTSP port.
    case tryAlternateRTSPPort

    /// Force TCP-interleaved transport, which traverses every LAN and needs no inbound ports.
    case switchToTCP

    /// Fall back to ONVIF for a device that does not speak ISAPI.
    case useONVIF

    /// Open the camera's own web page, where the device-side setting lives.
    case openCameraWebPage

    /// Run the full Stream Doctor sequence and show its step-by-step result.
    case runStreamDoctor

    /// The button label — a verb naming the outcome (UX.md §14.1 rule 6).
    ///
    /// A `LocalizedStringKey` rather than a `Text` so that ``VButton`` can take it directly and
    /// this copy exists exactly once.
    package var title: LocalizedStringKey {
        switch self {
        case .retry: return "Try Again"
        case .checkAddress: return "Check the Address"
        case .updatePassword: return "Update Password"
        case .activateCamera: return "Set Password"
        case .tryAlternateRTSPPort: return "Try Port 8554"
        case .switchToTCP: return "Switch to TCP"
        case .useONVIF: return "Use ONVIF"
        case .openCameraWebPage: return "Open Camera Web Page"
        case .runStreamDoctor: return "Diagnose"
        }
    }
}

// MARK: - ConnectField

/// The three fields of the slice's connect form, used to move focus to the one that needs fixing.
package enum ConnectField: Sendable, Hashable {

    /// The camera's address.
    case host

    /// The account name. Prefilled with `admin` (R1.4).
    case username

    /// The password.
    case password
}

#endif  // os(macOS)
