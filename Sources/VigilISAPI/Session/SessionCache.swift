//
//  SessionCache.swift
//  VigilISAPI
//
//  The two caches `ISAPIDeviceSession` owns: the per-datum TTL table from docs/spec-isapi.md §18.1,
//  and the negative-capability cache from §18.3.
//  Implements docs/spec-isapi.md §18.1 and §18.3, and docs/API_CONTRACT.md §4.5.
//
//  Both are plain value types on an injected monotonic clock, so every expiry test is a matter of
//  handing them two instants rather than of waiting. Neither ever calls a clock itself: the session
//  reads the clock once per operation and passes the instant in, which is also what keeps two
//  freshness decisions inside one call from disagreeing.
//

import Foundation
import VigilProtocols

// MARK: - Timestamped

/// A cached value and the instant it was stored, on the session's monotonic clock.
///
/// Deliberately not `Equatable`: two cache entries with the same value but different ages are not
/// interchangeable, and a synthesised `==` would invite comparing them.
struct Timestamped<Value>: Sendable where Value: Sendable {

    /// What was cached.
    var value: Value

    /// When it was cached, on the session's clock.
    var storedAt: MediaInstant

    /// True when `now` is still inside `ttl` of `storedAt`.
    ///
    /// A negative or zero `ttl` means "never fresh", which is how a caller disables one row of the
    /// table without a second code path. An entry stored *after* `now` — impossible on a monotonic
    /// clock, possible in a test that hands the instants back to front — counts as fresh.
    func isFresh(at now: MediaInstant, ttl: Double) -> Bool {
        guard ttl > 0 else { return false }
        return now.seconds(since: storedAt) < ttl
    }
}

// MARK: - CacheTTL

/// The authoritative TTL table (docs/spec-isapi.md §18.1), in seconds.
///
/// Every value is a device-behaviour decision rather than a preference, so they are documented
/// individually and changed only against the spec. They are `var`s so a diagnostics build can pin
/// everything to zero and watch the real traffic.
public struct CacheTTL: Sendable, Hashable {

    /// Identity never changes without a firmware upgrade or a swap of hardware.
    public var deviceInfo: Double = 86_400

    /// Keyed by firmware version by the session; a firmware change discards it regardless of age.
    public var capabilities: Double = 86_400

    /// Long enough to spare the device a request per timeline redraw, short enough that an NTP step
    /// shows up while the user is still looking at the panel.
    public var deviceTime: Double = 300

    /// The health poll. Five seconds, because this is what the diagnostics panel refreshes from.
    public var deviceStatus: Double = 5

    /// Channel inventory. Invalidated by any stream `PUT` as well.
    public var channels: Double = 60

    /// Stream configuration. Invalidated by any stream `PUT` as well.
    public var streamingChannels: Double = 30

    /// Recording tracks: stable unless recording is reconfigured.
    public var recordTracks: Double = 300

    /// Volume list and free space.
    public var storage: Double = 300

    /// Today's recording index, which is still being written to.
    public var dayIndexToday: Double = 60

    /// The month calendar for the current month.
    public var monthCalendar: Double = 600

    /// Which event types the device has configured.
    public var eventTriggers: Double = 300

    /// PTZ capability is a property of the hardware.
    public var ptzCapabilities: Double = 86_400

    /// Image settings. Invalidated by any image `PUT` as well.
    public var imageSettings: Double = 30

    /// How long a `403 notSupport` / `404` / `405` suppresses a resource template.
    public var negativeCapability: Double = 86_400

    /// The documented table.
    public init() {}
}

// MARK: - NegativeCapabilityCache

/// Resource templates this device has refused, so Vigil stops asking (docs/spec-isapi.md §18.3).
///
/// Keyed by `ISAPIResource.template(of:)`, which collapses every all-digit path component to `{n}`:
/// one `403 notSupport` on channel 3's PTZ capabilities suppresses the pointless request on
/// channels 1…64. This is what stops Vigil from re-asking a fixed camera for PTZ capabilities forty
/// times a session.
public struct NegativeCapabilityCache: Sendable, Hashable {

    /// Template → the instant it was refused.
    private var refusals: [String: MediaInstant] = [:]

    /// An empty cache.
    public init() {}

    /// Records a refusal of `resource`.
    ///
    /// A repeat refusal refreshes the entry rather than extending the original 24 h from first
    /// sight: the device is still saying no, and the clock should run from the most recent evidence.
    public mutating func remember(_ resource: String, at instant: MediaInstant) {
        refusals[ISAPIResource.template(of: resource)] = instant
    }

    /// True when `resource` is still suppressed, and the entry is dropped when it is not.
    ///
    /// `mutating` on purpose: expiry is evaluated on read, so nothing has to sweep the table and an
    /// entry cannot outlive its TTL just because nobody looked.
    public mutating func isSuppressed(_ resource: String, at instant: MediaInstant,
                                      ttl: Double) -> Bool {
        let key = ISAPIResource.template(of: resource)
        guard let recordedAt = refusals[key] else { return false }
        guard ttl > 0, instant.seconds(since: recordedAt) < ttl else {
            refusals[key] = nil
            return false
        }
        return true
    }

    /// Drops the entry for `resource`, if any.
    ///
    /// The retry paths need this: a `403 notSupport` for `/picture` **with** resolution query items
    /// is a refusal of the query, not of the resource, and leaving the entry in place would suppress
    /// every later snapshot of every channel — the template collapses the channel number.
    public mutating func forget(_ resource: String) {
        refusals[ISAPIResource.template(of: resource)] = nil
    }

    /// Every suppressed template, sorted, for the diagnostics bundle.
    public var suppressedTemplates: [String] { refusals.keys.sorted() }

    /// Forgets everything. The "re-probe device" action in camera settings, and every reboot.
    public mutating func clear() {
        refusals.removeAll()
    }
}
