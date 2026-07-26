//
//  SnapshotDeviceRoute.swift
//  VigilCore
//
//  The second snapshot route: the camera's own JPEG encoder, at full sensor resolution, over ISAPI.
//  Implements docs/spec-core.md §10.3 and docs/spec-isapi.md §12.5.
//
//  This file constructs **no** `ISAPIClient`. It goes through the `ISAPIRequesting` seam, which is
//  the whole reason that protocol exists: a snapshot route that owned a client would drag Digest,
//  the lane matrix and a `URLSession` into every test of it. The request shape, the content sniffing
//  and the retry rule all already exist and are tested in `VigilISAPI`
//  (`Endpoints/Snapshots.swift`); what is here is the *policy* that turns them into a full-resolution
//  still.
//

#if os(macOS)

import Foundation
import VigilISAPI
import VigilProtocols

// MARK: - SnapshotDeviceRoute

/// Fetches a JPEG from the device.
///
/// **Why the main stream and no resolution query.** `SnapshotWireRequest.thumbnail` asks the
/// *substream* for 160×90, because a thumbnail wants speed. This route wants the opposite: the point
/// of going to the camera at all — when a decoded frame is already on screen and free — is to get the
/// picture the sensor actually produced, which means the main stream and no `videoResolutionWidth`
/// query at all. Asking for a size makes the device scale, which costs it 300–700 ms and throws away
/// exactly the resolution that was being asked for.
public struct SnapshotDeviceRoute: Sendable {

    // MARK: - Nested Types

    /// Retry policy for the two device answers that are worth a second attempt.
    public struct RetryPolicy: Sendable, Hashable {

        /// How many times to retry a `deviceBusy` / 503. Two, per spec-core §10.3.
        public var busyRetries: Int

        /// Delay between those retries. 300 ms: long enough for another client's snapshot to finish,
        /// short enough to stay inside the 5 s the UI allows.
        public var busyDelay: Duration

        public init(busyRetries: Int = 2, busyDelay: Duration = .milliseconds(300)) {
            self.busyRetries = busyRetries
            self.busyDelay = busyDelay
        }
    }

    // MARK: - Stored Properties

    private let requester: any ISAPIRequesting
    private let clock: any MonotonicClock
    private let policy: RetryPolicy

    // MARK: - Initialisation

    /// Builds a route.
    ///
    /// - Parameters:
    ///   - requester: The seam. In production this is the adapter over `ISAPIClient`; in a test it is
    ///     a fixture double.
    ///   - clock: For the retry delay. Injected, so a test does not spend 600 ms per busy case.
    ///   - policy: Retry budget.
    public init(requester: any ISAPIRequesting, clock: any MonotonicClock,
                policy: RetryPolicy = RetryPolicy()) {
        self.requester = requester
        self.clock = clock
        self.policy = policy
    }

    // MARK: - Public API

    /// The request this route sends, exposed so a test can assert the shape without a transport.
    ///
    /// - Parameter channel: The video input to snapshot.
    /// - Returns: A main-stream request with `omitResolutionQuery` set, so `query` is empty.
    public static func request(channel: ChannelID) -> SnapshotWireRequest {
        SnapshotWireRequest(channel: StreamingChannelID(channel: channel, quality: .main),
                            width: nil,
                            height: nil,
                            omitResolutionQuery: true)
    }

    /// Fetches a full-resolution JPEG.
    ///
    /// - Parameter channel: The video input to snapshot.
    /// - Returns: The JPEG bytes, verbatim as the camera produced them. Not re-encoded: when the
    ///   caller wants JPEG out, these exact bytes are what gets written, so the file is bit-identical
    ///   to the device's own encode (spec-core §10.3).
    /// - Throws: `ISAPIError`. `.device(statusCode: 4, sub: "ipcOffline")` for an empty 200, which is
    ///   an NVR reporting the channel offline rather than a zero-byte image — the distinction
    ///   F-CAP-01 acceptance 8 turns into "No video to capture" instead of a broken-image
    ///   placeholder. `.deviceBusy` only after the retries are spent.
    public func fetchJPEG(channel: ChannelID) async throws(ISAPIError) -> Data {
        let wire = Self.request(channel: channel)
        var attempt = 0

        while true {
            do {
                let body = try await requester.getBytes(wire.resource, query: wire.query,
                                                        lane: .snapshot)
                // The bytes are the only trustworthy evidence of what arrived: some 5.2.x firmware
                // labels a JPEG `text/html`, and some answers an HTML error page with a 200.
                return try SnapshotPayload.validate(body, contentType: nil)
            } catch ISAPIError.deviceBusy where attempt < policy.busyRetries {
                attempt += 1
                try? await clock.sleep(for: policy.busyDelay)
            } catch ISAPIError.http(let status, _) where status == 503
                && attempt < policy.busyRetries {
                attempt += 1
                try? await clock.sleep(for: policy.busyDelay)
            }
        }
    }
}

#endif
