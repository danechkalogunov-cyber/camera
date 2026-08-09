#if os(macOS)

import Foundation
import Testing

@testable import Vigil
import VigilProtocols

@Suite("App Intent snapshot rendezvous", .serialized)
struct IntentSnapshotBridgeTests {
    @Test func requestIsScopedToTheSelectedCameraAndConsumedOnce() {
        let camera = CameraID()
        let other = CameraID()
        let request = IntentSnapshotBridge.begin(for: camera)
        #expect(IntentSnapshotBridge.takePending(for: other) == nil)
        #expect(IntentSnapshotBridge.takePending(for: camera) == request)
        #expect(IntentSnapshotBridge.takePending(for: camera) == nil)
    }

    @Test func completedRequestReturnsTheCapturedFile() async throws {
        let request = IntentSnapshotBridge.begin(for: CameraID())
        let url = URL(fileURLWithPath: "/tmp/vigil-intent-test.jpg")
        IntentSnapshotBridge.complete(request, url: url)
        #expect(try await IntentSnapshotBridge.wait(for: request) == url)
    }

    @Test func failedRequestReturnsItsRedactedReason() async {
        let request = IntentSnapshotBridge.begin(for: CameraID())
        IntentSnapshotBridge.fail(request, reason: "password=hunter2")
        do {
            _ = try await IntentSnapshotBridge.wait(for: request)
            Issue.record("expected capture failure")
        } catch IntentSnapshotBridgeError.captureFailed(let reason) {
            #expect(!reason.contains("hunter2"))
        } catch {
            Issue.record("unexpected failure: \(error)")
        }
    }
}

#endif
