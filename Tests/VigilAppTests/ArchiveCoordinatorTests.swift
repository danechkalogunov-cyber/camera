//
//  ArchiveCoordinatorTests.swift
//  VigilAppTests
//
//  The identity rule behind "the timeline opens once and then never again".
//
//  ⛔ THIS IS THE BUG, AND IT WAS REPORTED THREE TIMES BEFORE IT WAS FOUND. `follow` guarded on
//  `session !== self.session`, so **any** freshly built `ISAPIDeviceSession` threw away the day's
//  index, the loaded day, the month cache and the track answer. `DeviceInfoService` builds a new
//  session whenever its key changes — a reconnect, a port change, a re-read credential — and none of
//  those is a different camera. The window then reloaded only if `archiveTrigger` happened to change
//  as well; when it did not, the scrubber sat empty with nothing on its way. A rebuilt transport is
//  not a new camera, and this is the test that says so.
//
//  ⚠️ The session double is never asked anything. `follow` decides what to keep and what to drop
//  from the arguments alone — it starts no load — so a requester that throws on every call is both
//  sufficient and a tripwire: a change that made `follow` fetch would fail here rather than quietly
//  reach for the network.
//

#if os(macOS)

import Foundation
import Testing

@testable import Vigil
import VigilISAPI
import VigilProtocols

// MARK: - Doubles

/// An `ISAPIRequesting` that refuses everything. See the file header for why refusing is the point.
private struct RefusingRequests: ISAPIRequesting {

    func getDocument(
        _ resource: String, query: [URLQueryItem], lane: HTTPLane
    ) async throws(ISAPIError) -> ISAPIDocument {
        throw ISAPIError.notConnected(resource)
    }

    func getBytes(
        _ resource: String, query: [URLQueryItem], lane: HTTPLane
    ) async throws(ISAPIError) -> Data {
        throw ISAPIError.notConnected(resource)
    }

    func putDocument(
        _ resource: String, body: Data?, query: [URLQueryItem], lane: HTTPLane
    ) async throws(ISAPIError) -> ISAPIDocument? {
        throw ISAPIError.notConnected(resource)
    }

    func postDocument(
        _ resource: String, body: Data?, query: [URLQueryItem], lane: HTTPLane
    ) async throws(ISAPIError) -> ISAPIDocument {
        throw ISAPIError.notConnected(resource)
    }

    func deleteDocument(
        _ resource: String, query: [URLQueryItem], lane: HTTPLane
    ) async throws(ISAPIError) -> ISAPIDocument? {
        throw ISAPIError.notConnected(resource)
    }

    func openStream(
        _ resource: String, query: [URLQueryItem], headers: [String: String]
    ) async throws(ISAPIError) -> ISAPIByteStream {
        throw ISAPIError.notConnected(resource)
    }
}

// MARK: - Tests

@Suite("The timeline's camera identity")
@MainActor
struct ArchiveCoordinatorTests {

    // MARK: - Fixtures

    private func coordinator() -> ArchiveCoordinator {
        ArchiveCoordinator(logger: NullLogger())
    }

    private func session() -> ISAPIDeviceSession {
        ISAPIDeviceSession(requests: RefusingRequests(), clock: VirtualTestClock())
    }

    /// Puts the coordinator into the state a loaded day leaves behind, so a wipe is visible.
    private func seed(_ coordinator: ArchiveCoordinator) {
        coordinator.myTracks = [TrackID(101), TrackID(103)]
        coordinator.visibleMonth = ArchiveCoordinator.MonthSlot(year: 2026, month: 8)
    }

    // MARK: - A rebuilt transport

    /// ⛔ The reported bug. The same camera on a new session keeps everything that was read through
    /// the old one, and adopts the new transport for whatever is asked next.
    @Test func aRebuiltSessionForTheSameCameraKeepsTheIndex() {
        let archive = coordinator()
        let camera = CameraID()
        archive.follow(
            camera: camera, session: session(), channel: ChannelID(1), name: "Front door")
        seed(archive)

        let rebuilt = session()
        archive.follow(
            camera: camera, session: rebuilt, channel: ChannelID(1), name: "Front door")

        #expect(archive.myTracks == [TrackID(101), TrackID(103)])
        #expect(archive.visibleMonth == ArchiveCoordinator.MonthSlot(year: 2026, month: 8))
        #expect(archive.session === rebuilt, "the new transport is adopted for the next question")
    }

    /// A rename is not a new camera either — the lane's label changes and nothing else does.
    @Test func aRenameKeepsTheIndex() {
        let archive = coordinator()
        let camera = CameraID()
        let transport = session()
        archive.follow(
            camera: camera, session: transport, channel: ChannelID(1), name: "Front door")
        seed(archive)

        archive.follow(
            camera: camera, session: transport, channel: ChannelID(1), name: "Back gate")

        #expect(archive.myTracks.count == 2)
    }

    // MARK: - A different camera

    /// A different camera is a different index, and everything read from the previous one goes —
    /// including the month cache, which is keyed by year and month alone and would otherwise show
    /// one camera's recording days under another's name.
    @Test func aDifferentCameraClearsEverything() {
        let archive = coordinator()
        archive.follow(camera: CameraID(), session: session(), channel: ChannelID(1), name: "Front")
        seed(archive)

        archive.follow(camera: CameraID(), session: session(), channel: ChannelID(1), name: "Yard")

        #expect(archive.myTracks.isEmpty)
        #expect(archive.visibleMonth == nil)
        #expect(archive.month == nil)
        #expect(archive.tracks == .unknown)
    }

    /// A different channel on the same device is a different index too: an NVR answers for many
    /// cameras on one session, and channel 2's recordings are not channel 1's.
    @Test func aDifferentChannelClearsEverything() {
        let archive = coordinator()
        let camera = CameraID()
        let transport = session()
        archive.follow(camera: camera, session: transport, channel: ChannelID(1), name: "Front")
        seed(archive)

        archive.follow(camera: camera, session: transport, channel: ChannelID(2), name: "Front")

        #expect(archive.myTracks.isEmpty)
        #expect(archive.visibleMonth == nil)
    }

    /// Being pointed at nothing clears the timeline: no camera is not "keep showing the last one".
    @Test func followingNothingClearsTheTimeline() {
        let archive = coordinator()
        archive.follow(camera: CameraID(), session: session(), channel: ChannelID(1), name: "Front")
        seed(archive)

        archive.follow(camera: nil, session: nil, channel: nil, name: "")

        #expect(archive.myTracks.isEmpty)
        #expect(archive.session == nil)
        #expect(archive.tracks == .unknown)
    }

    /// ⚠️ Twice with no camera is still a clear, not a "same camera" hit. `nil == nil` is true, and
    /// a guard written on the identifiers alone would have treated two unknown cameras as one —
    /// keeping a previous camera's index alive under a timeline pointed at nothing.
    @Test func twoFollowsWithNoCameraDoNotCountAsTheSameCamera() {
        let archive = coordinator()
        archive.follow(camera: nil, session: nil, channel: nil, name: "")
        archive.myTracks = [TrackID(101)]

        archive.follow(camera: nil, session: nil, channel: nil, name: "")

        #expect(archive.myTracks.isEmpty)
    }
}

#endif  // os(macOS)
