//
//  EventCoalescerTests.swift
//  VigilCoreTests
//
//  The de-duplication rule and the bounded ring, tested directly: no actor, no clock, no device.
//  Covers docs/spec-core.md §11.3 and the seven event kinds of docs/spec-isapi.md §14.3.
//
//  `@testable` because `EventCoalescer` and `EventRing` are internal on purpose — they are the
//  mechanism, and `EventStore` is the API. Testing the mechanism directly is what makes a 3-second
//  window assertable at all: every instant here is a literal.
//

#if os(macOS)

import Foundation
import Testing
@testable import VigilCore
import VigilISAPI
import VigilProtocols

// MARK: - Harness

/// Drives a coalescer along a virtual timeline. `seconds` is both the monotonic reading and the
/// wall-clock offset, so device time and receipt time agree unless a test deliberately skews them.
struct EventCoalescerHarness {
    var coalescer: EventCoalescer
    let ids = EventIDSequence()
    let camera = CameraID()

    init(bounds: EventBounds = EventBounds(recordsPerCamera: 512, cameras: 64,
                                           newRecordsPerCameraPerMinute: 1_000,
                                           newRecordsPerApplicationPerMinute: 10_000)) {
        coalescer = EventCoalescer(bounds: bounds)
    }

    /// Ingests one alert at `seconds` on the virtual timeline.
    @discardableResult
    mutating func ingest(at seconds: Double,
                         kind: EventKind = .motion,
                         channel: ChannelID = 1,
                         state: EventState = .active,
                         activePostCount: Int = 1,
                         deviceOffset: Double? = nil,
                         naive: Bool = false,
                         regions: [DetectionRegion] = [],
                         snapshot: Data? = nil,
                         rawType: String? = nil,
                         target: DetectionTarget? = nil,
                         cameraID: CameraID? = nil) -> EventIngestOutcome {
        let alert = EventAlertFixture.alert(kind: kind,
                                           rawType: rawType,
                                           channel: channel,
                                           state: state,
                                           activePostCount: activePostCount,
                                           offset: deviceOffset ?? seconds,
                                           naive: naive,
                                           regions: regions,
                                           snapshot: snapshot)
        return coalescer.ingest(alert,
                                cameraID: cameraID ?? camera,
                                target: target,
                                receiptTime: EventAlertFixture.deviceEpoch
                                    .addingTimeInterval(seconds),
                                now: MediaInstant(nanoseconds: Int64(seconds * 1e9)),
                                newID: ids.next())
    }

    var records: [EventRecord] { coalescer.records(for: camera, limit: 500) }
}

#endif
