//
//  DeepLink.swift
//  VigilCore
//
//  The `vigil://` grammar, parsed. Pure and total: every input either produces a target or a named
//  error, and nothing here touches a camera, a window or the file system.
//  Implements docs/FEATURES.md §F-AUT-03 acceptance 1–3.
//
//  ⛔ A URL SCHEME IS AN UNAUTHENTICATED INPUT SURFACE. Anything on the Mac — a web page, a mail
//  message, a script someone was sent — can hand this string to Vigil. So the parser is written the
//  way the wire parsers in `VigilProtocols` are: it never traps, never force-unwraps, and answers a
//  typed error rather than an approximation. `F-AUT-03` acceptance 2 says it in one line — "never a
//  crash, never a silent no-op" — and the silent no-op is the half people forget, because a link
//  that does nothing is indistinguishable from an app that is broken.
//
//  ⚠️ Parsing is not permission. Deciding whether a link may start a recording belongs to the app,
//  which knows whether it is frontmost (acceptance 4). This file's job ends at saying what was asked
//  for.
//

#if os(macOS)

import Foundation

import VigilProtocols

// MARK: - DeepLinkReference

/// How a link names a camera or a group.
public enum DeepLinkReference: Sendable, Hashable {

    /// A stable identifier, when the link carried a UUID.
    case identifier(UUID)

    /// A name, case-folded and whitespace-collapsed (acceptance 3).
    ///
    /// Resolution is the app's problem, not this file's, and so is ambiguity: two cameras called
    /// "Front Door" must open the palette pre-filtered rather than have one of them guessed at.
    case slug(String)

    /// Reads whichever of the two a path component is.
    ///
    /// A UUID wins when the text parses as one, because a camera named after a UUID is a stretch and
    /// a link carrying one is not.
    public init(_ text: String) {
        if let identifier = UUID(uuidString: text) {
            self = .identifier(identifier)
            return
        }
        self = .slug(DeepLink.slug(text))
    }
}

// MARK: - DeepLinkAction

/// What a `vigil://camera/…` link asks for.
public enum DeepLinkAction: String, Sendable, Hashable, CaseIterable {
    case live
    case fullscreen
    case snapshot
    case record
    case stop
    case diagnose
    case mute
    case unmute

    /// Whether performing this without asking would be a privacy decision made on the user's behalf.
    ///
    /// `F-AUT-03` acceptance 4: a link from another app may not silently start a recording or take a
    /// picture. The app enforces it; this says which actions it applies to, so the rule lives beside
    /// the vocabulary rather than in a condition somebody has to remember to write.
    public var needsConfirmationFromAnotherApp: Bool {
        self == .record || self == .snapshot
    }
}

// MARK: - DeepLinkTarget

/// What a `vigil://` URL asked for.
public enum DeepLinkTarget: Sendable, Hashable {

    /// `vigil://camera/<uuid|slug>[?action=…][&stream=main|sub]`
    case camera(DeepLinkReference, action: DeepLinkAction?, stream: StreamQuality?)

    /// `vigil://group/<uuid|slug>`
    case group(DeepLinkReference)

    /// `vigil://layout/<mode|presetName>`
    case layout(String)

    /// `vigil://preset/<cameraRef>/<presetNumber>`
    case preset(DeepLinkReference, number: Int)

    /// `vigil://playback/<cameraRef>?t=<ISO8601>[&speed=<0.25…8>]`
    case playback(DeepLinkReference, at: Date, speed: Double?)

    /// `vigil://event/<eventID>`
    case event(UUID)

    /// `vigil://snapshot-all`
    case snapshotAll

    /// `vigil://palette[?q=<query>]`
    case palette(query: String?)

    /// `vigil://settings/<pane>`
    case settings(pane: String)

    /// `vigil://cycling/start|stop` — the App Intent and menu use the same cycle state machine.
    case cycling(Bool)
}

// MARK: - DeepLinkError

/// Why a link could not be understood.
///
/// Every case carries what it saw, because "That Vigil link isn't valid" is what the user is shown
/// and the detail is what goes in the log beside it.
public enum DeepLinkError: Error, Sendable, Hashable {

    /// Not a `vigil://` URL at all.
    case notAVigilLink

    /// The host names no known target.
    case unknownTarget(String)

    /// The target needs a path component and the link had none — `vigil://camera` with no camera.
    case missingComponent(target: String)

    /// A query value that does not parse: a speed of `fast`, a `t=` that is not ISO 8601.
    case malformedParameter(name: String, value: String)
}

// MARK: - DeepLink

/// The `vigil://` parser.
public enum DeepLink {

    /// The scheme, lowercased for comparison. macOS hands URLs back with the scheme it registered,
    /// but a hand-typed `VIGIL://` is still a valid URL and still ours.
    public static let scheme = "vigil"

    /// Takes a URL apart, or names why it could not.
    ///
    /// - Parameter url: whatever the system delivered.
    /// - Returns: the target the link asked for.
    /// - Throws: ``DeepLinkError``. Total: every input produces one or the other.
    public static func parse(_ url: URL) throws(DeepLinkError) -> DeepLinkTarget {
        guard url.scheme?.lowercased() == scheme else { throw .notAVigilLink }
        // `host` is where the target lives in `vigil://camera/…`; a hostless `vigil:///x` is
        // malformed rather than a target of "".
        guard let target = url.host()?.lowercased(), !target.isEmpty else {
            throw .unknownTarget(url.absoluteString)
        }
        let path = url.pathComponents.filter { $0 != "/" }
        let query = queryItems(url)

        switch target {
        case "camera":
            guard let first = path.first else { throw .missingComponent(target: target) }
            return .camera(DeepLinkReference(first),
                           action: try action(query),
                           stream: try stream(query))
        case "group":
            guard let first = path.first else { throw .missingComponent(target: target) }
            return .group(DeepLinkReference(first))
        case "layout":
            guard let first = path.first else { throw .missingComponent(target: target) }
            return .layout(first)
        case "preset":
            guard path.count >= 2 else { throw .missingComponent(target: target) }
            guard let number = Int(path[1]) else {
                throw .malformedParameter(name: "preset", value: path[1])
            }
            return .preset(DeepLinkReference(path[0]), number: number)
        case "playback":
            guard let first = path.first else { throw .missingComponent(target: target) }
            guard let raw = query["t"] else {
                throw .malformedParameter(name: "t", value: "")
            }
            guard let instant = instant(from: raw) else {
                throw .malformedParameter(name: "t", value: raw)
            }
            return .playback(DeepLinkReference(first), at: instant, speed: try speed(query))
        case "event":
            guard let first = path.first else { throw .missingComponent(target: target) }
            guard let identifier = UUID(uuidString: first) else {
                throw .malformedParameter(name: "event", value: first)
            }
            return .event(identifier)
        case "snapshot-all":
            return .snapshotAll
        case "palette":
            // An empty `?q=` is not a query. It is what a link builder emits for "no filter", and
            // treating it as a search for the empty string would open the palette showing nothing.
            let text = query["q"].flatMap { $0.isEmpty ? nil : $0 }
            return .palette(query: text)
        case "settings":
            guard let first = path.first else { throw .missingComponent(target: target) }
            return .settings(pane: first.lowercased())
        case "cycling":
            guard let first = path.first else { throw .missingComponent(target: target) }
            switch first.lowercased() {
            case "start": return .cycling(true)
            case "stop": return .cycling(false)
            default: throw .malformedParameter(name: "cycling", value: first)
            }
        default:
            throw .unknownTarget(target)
        }
    }

    /// A name reduced to its comparable form: case-folded, whitespace collapsed to single spaces,
    /// trimmed. `  Front   DOOR ` and `front door` are the same camera (acceptance 3).
    public static func slug(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    // MARK: - Private Helpers

    /// The query as a dictionary, percent-decoded by `URLComponents`.
    ///
    /// Last value wins for a repeated name — an arbitrary choice, but a defined one, and a link with
    /// two `?action=` values is malformed input rather than a case to model.
    private static func queryItems(_ url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return [:]
        }
        var out: [String: String] = [:]
        for item in items {
            out[item.name.lowercased()] = item.value ?? ""
        }
        return out
    }

    private static func action(_ query: [String: String]) throws(DeepLinkError) -> DeepLinkAction? {
        guard let raw = query["action"] else { return nil }
        guard let action = DeepLinkAction(rawValue: raw.lowercased()) else {
            throw .malformedParameter(name: "action", value: raw)
        }
        return action
    }

    /// `main` or `sub`. `third` is deliberately not spelled in the grammar, so it is rejected rather
    /// than quietly accepted — the grammar in §F-AUT-03 is normative.
    private static func stream(_ query: [String: String]) throws(DeepLinkError) -> StreamQuality? {
        guard let raw = query["stream"] else { return nil }
        switch raw.lowercased() {
        case "main": return .main
        case "sub": return .sub
        default: throw .malformedParameter(name: "stream", value: raw)
        }
    }

    /// The playback speed, held to the grammar's `0.25…8`.
    ///
    /// Out of range is an error rather than a clamp: a link asking for 100× has misunderstood
    /// something, and silently giving it 8× would hide that from whoever wrote the link.
    private static func speed(_ query: [String: String]) throws(DeepLinkError) -> Double? {
        guard let raw = query["speed"] else { return nil }
        guard let value = Double(raw), value >= 0.25, value <= 8 else {
            throw .malformedParameter(name: "speed", value: raw)
        }
        return value
    }

    /// An ISO 8601 instant, with or without fractional seconds.
    ///
    /// Both are tried because both are written by hand and by machine, and a link that fails only
    /// because someone included milliseconds would be a maddening thing to debug.
    private static func instant(from text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

#endif  // os(macOS)
