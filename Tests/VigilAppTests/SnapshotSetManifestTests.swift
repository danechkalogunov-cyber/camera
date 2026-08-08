//
//  SnapshotSetManifestTests.swift
//  VigilAppTests
//
//  The two parts of a snapshot set that are arithmetic rather than I/O: the folder's name, and what
//  the manifest says about the set.
//
//  ⛔ THE MANIFEST IS THE ONLY PART THAT SURVIVES. Six months later the images are a folder of JPEGs
//  with slugs for names; `manifest.json` is what says which camera each one is, when its frame was
//  actually taken, and — the part nobody would reconstruct — which cameras were asked and produced
//  nothing. F-CAP-02 acceptance 4 is explicit that a set of fourteen successes and two failures
//  writes fourteen files and a manifest naming the two, so a manifest that quietly omitted the
//  failures would satisfy the folder listing and lose the fact that mattered.
//

#if os(macOS)

import Foundation
import Testing

@testable import Vigil

@Suite("Snapshot set manifest")
struct SnapshotSetManifestTests {

    // MARK: - Fixtures

    private func entry(_ name: String, at seconds: Double?, failure: String? = nil) -> SnapshotSetEntry {
        SnapshotSetEntry(
            camera: name,
            cameraID: UUID(),
            file: failure == nil ? "\(name).jpg" : nil,
            capturedAt: seconds.map { Date(timeIntervalSince1970: $0) },
            pixelWidth: failure == nil ? 1920 : nil,
            pixelHeight: failure == nil ? 1080 : nil,
            failure: failure)
    }

    private let requested = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Counts

    /// ⛔ Acceptance 4: a partial set is a written set. Fourteen and two, not nothing.
    @Test func aPartialSetCountsBothHalves() {
        let entries = [
            entry("front", at: 100),
            entry("yard", at: 100.1),
            entry("gate", at: nil, failure: "the camera did not answer"),
        ]

        let manifest = SnapshotSetCoordinator.manifest(requestedAt: requested, entries: entries)

        #expect(manifest.succeeded == 2)
        #expect(manifest.failed == 1)
        #expect(manifest.entries.count == 3, "the failure is listed, not dropped")
    }

    /// A failed camera keeps its name and its reason and carries no file, so a reader can tell a
    /// camera that was never asked from one that was asked and refused.
    @Test func aFailedCameraCarriesItsReasonAndNoFile() {
        let entries = [entry("gate", at: nil, failure: "no password is stored for this camera")]

        let manifest = SnapshotSetCoordinator.manifest(requestedAt: requested, entries: entries)

        #expect(manifest.entries[0].file == nil)
        #expect(manifest.entries[0].failure == "no password is stored for this camera")
        #expect(manifest.entries[0].camera == "gate")
    }

    /// A set where nothing answered is still a manifest. The folder exists, and the record of what
    /// was tried is the only useful thing in it.
    @Test func aSetThatFailedEntirelyStillRecordsWhatWasTried() {
        let entries = [
            entry("front", at: nil, failure: "timed out"),
            entry("yard", at: nil, failure: "timed out"),
        ]

        let manifest = SnapshotSetCoordinator.manifest(requestedAt: requested, entries: entries)

        #expect(manifest.succeeded == 0)
        #expect(manifest.failed == 2)
        #expect(manifest.spreadMilliseconds == nil)
    }

    // MARK: - The spread

    /// ⛔ Acceptance 2's number: the widest gap between two captured frames, in milliseconds. It is
    /// measured between the **frames**, not from when the user pressed the key — the request is one
    /// instant by construction and would report zero spread every time.
    @Test func theSpreadIsMeasuredBetweenTheFrames() {
        let entries = [
            entry("a", at: 100.0),
            entry("b", at: 100.18),
            entry("c", at: 100.05),
        ]

        let manifest = SnapshotSetCoordinator.manifest(requestedAt: requested, entries: entries)

        let spread = manifest.spreadMilliseconds ?? 0
        #expect(spread > 179 && spread < 181, "180 ms between the earliest and the latest")
    }

    /// A failed camera contributes no instant, so it cannot widen the spread — a camera that timed
    /// out after thirty seconds is not a thirty-second spread across the set.
    @Test func aFailedCameraDoesNotWidenTheSpread() {
        let entries = [
            entry("a", at: 100.0),
            entry("b", at: 100.1),
            entry("late", at: nil, failure: "timed out after 30 s"),
        ]

        let manifest = SnapshotSetCoordinator.manifest(requestedAt: requested, entries: entries)

        let spread = manifest.spreadMilliseconds ?? 0
        #expect(spread > 99 && spread < 101)
    }

    /// ⚠️ One camera has no spread. A single reading is not a range, and reporting `0` would claim a
    /// measurement of simultaneity that was never taken.
    @Test func oneCameraHasNoSpread() {
        let manifest = SnapshotSetCoordinator.manifest(
            requestedAt: requested, entries: [entry("only", at: 100)])

        #expect(manifest.spreadMilliseconds == nil)
    }

    // MARK: - The folder

    /// Acceptance 3's name, exactly: `Snapshot Set 2026-07-26 14-31-07`.
    ///
    /// ⚠️ Hyphens in the time, not colons: a colon is not legal in a path component on every volume
    /// Vigil can be pointed at, and the one it fails on is the one somebody keeps their evidence on.
    @Test func theFolderIsNamedForTheInstantTheSetWasAskedFor() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 26
        components.hour = 14
        components.minute = 31
        components.second = 7
        let instant = Calendar.current.date(from: components) ?? Date()

        let name = SnapshotSetCoordinator.folderName(for: instant)

        #expect(name == "Snapshot Set 2026-07-26 14-31-07")
        #expect(name.contains(":") == false)
    }

    // MARK: - Round trip

    /// The manifest is written as JSON and read back by whoever opens the folder later, so it has to
    /// survive the trip — including the dates, which is the field an ISO-8601 strategy is chosen for.
    @Test func theManifestSurvivesItsOwnJSON() throws {
        let manifest = SnapshotSetCoordinator.manifest(
            requestedAt: requested,
            entries: [entry("front", at: 100), entry("gate", at: nil, failure: "refused")])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoded = try encoder.encode(manifest)
        let restored = try decoder.decode(SnapshotSetManifest.self, from: encoded)

        #expect(restored == manifest)
    }
}

#endif  // os(macOS)
