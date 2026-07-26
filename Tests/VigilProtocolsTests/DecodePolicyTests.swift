//
//  DecodePolicyTests.swift
//  VigilProtocolsTests
//
//  Decode units, modes, priorities and budget pressure.
//  Covers docs/API_CONTRACT.md §3.7 and rulings R-22, R-49, R-58.
//
//  1 DU is defined as one 1080p30 H.264 stream, so every expectation below is derived
//  from that definition rather than measured.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct DecodePolicyTests {

    private func geometry(width: Int, height: Int, bitDepth: Int = 8) -> FrameGeometry {
        FrameGeometry(codedWidth: width, codedHeight: height,
                      cropWidth: width, cropHeight: height, bitDepth: bitDepth)
    }

    // MARK: - The unit itself

    @Test func oneDecodeUnitIsOne1080p30H264Stream() {
        let cost = DecodeCost.estimate(geometry: geometry(width: 1920, height: 1080),
                                       codec: .h264, fps: 30, mode: .full)
        #expect(cost.units == 1.0)
        #expect(cost.description == "1.00 DU")
    }

    @Test func costUsesCodedPixelsNotDisplayPixels() {
        // 1080p H.264 is coded 1088 lines and the decoder allocates all of them.
        let coded = DecodeCost.estimate(geometry: FrameGeometry(codedWidth: 1920, codedHeight: 1088,
                                                                cropWidth: 1920, cropHeight: 1080),
                                        codec: .h264, fps: 30, mode: .full)
        #expect(coded.units == 1.25)
    }

    @Test func costAppliesTheCodecWeight() {
        // H.265 is 1.35 × H.264, rounded up to the next quarter unit.
        let h265 = DecodeCost.estimate(geometry: geometry(width: 1920, height: 1080),
                                       codec: .h265, fps: 30, mode: .full)
        #expect(h265.units == 1.50)
        let mjpeg = DecodeCost.estimate(geometry: geometry(width: 1920, height: 1080),
                                        codec: .mjpeg, fps: 30, mode: .full)
        #expect(mjpeg.units == 0.50)          // 0.45 → 0.50
    }

    @Test func costAppliesTheBitDepthSurcharge() {
        // R-58: 1.26 above 8 bits, so H.265 Main 10 lands on the 1.70 the specs quote.
        let main10 = DecodeCost.estimate(geometry: geometry(width: 1920, height: 1080,
                                                            bitDepth: 10),
                                         codec: .h265, fps: 30, mode: .full)
        #expect(abs(1.35 * 1.26 - 1.701) < 1e-9)
        #expect(main10.units == 1.75)
    }

    @Test func costAppliesTheModeWeight() {
        let full = geometry(width: 1920, height: 1080)
        #expect(DecodeCost.estimate(geometry: full, codec: .h264, fps: 30,
                                    mode: .keyframesOnly).units == 0.25)     // 0.12
        #expect(DecodeCost.estimate(geometry: full, codec: .h264, fps: 30,
                                    mode: .fpsCapped).units == 0.75)         // 0.55
        #expect(DecodeCost.estimate(geometry: full, codec: .h264, fps: 30,
                                    mode: .trim).units == 1.00)              // 0.80
    }

    @Test func pausedAndJPEGPollCostNothingEvenWhenDownscaling() {
        let full = geometry(width: 3840, height: 2160)
        #expect(DecodeCost.estimate(geometry: full, codec: .h265, fps: 30, mode: .paused,
                                    isDownscaling: true) == .zero)
        #expect(DecodeCost.estimate(geometry: full, codec: .h265, fps: 30, mode: .jpegPoll,
                                    isDownscaling: true) == .zero)
    }

    @Test func downscalingAddsItsSurchargeInsideTheRounding() {
        // 1.00 + 0.05 = 1.05, which rounds up to 1.25 — the cost stays a multiple of 0.25.
        let cost = DecodeCost.estimate(geometry: geometry(width: 1920, height: 1080),
                                       codec: .h264, fps: 30, mode: .full, isDownscaling: true)
        #expect(cost.units == 1.25)
    }

    @Test func costOfAFourByFourWallOfSubStreams() {
        // 16 × 640×360 H.265 sub streams at 15 fps: each is well under a quarter unit, so each
        // rounds up to 0.25 and the wall costs 4 DU of a 24 DU budget.
        let sub = DecodeCost.estimate(geometry: geometry(width: 640, height: 360),
                                      codec: .h265, fps: 15, mode: .full)
        #expect(sub.units == 0.25)
        let total = (0..<16).reduce(DecodeCost.zero) { acc, _ in acc + sub }
        #expect(total.units == 4.0)
    }

    @Test func costIsAlwaysANonNegativeMultipleOfAQuarter() {
        for units in [-5.0, -0.01, 0.0, 0.01, 0.26, 1.9, 23.99] {
            let cost = DecodeCost(units: units)
            #expect(cost.units >= 0)
            #expect((cost.units * 4).truncatingRemainder(dividingBy: 1) == 0,
                    "\(units) became \(cost.units)")
        }
        #expect(DecodeCost(units: -5).units == 0)
        #expect(DecodeCost(units: 0.26).units == 0.5)
    }

    @Test func costRefusesGarbageFromADevice() {
        // A device that reports a nonsense frame rate must not poison the budget.
        let full = geometry(width: 1920, height: 1080)
        #expect(DecodeCost.estimate(geometry: full, codec: .h264, fps: .nan, mode: .full) == .zero)
        #expect(DecodeCost.estimate(geometry: full, codec: .h264, fps: .infinity,
                                    mode: .full) == .zero)
        #expect(DecodeCost.estimate(geometry: full, codec: .h264, fps: -30, mode: .full) == .zero)
        #expect(DecodeCost.estimate(geometry: geometry(width: 0, height: 0), codec: .h264,
                                    fps: 30, mode: .full) == .zero)
        #expect(DecodeCost(units: .nan).units == 0)
        #expect(DecodeCost(units: .infinity).units == 0)
    }

    @Test func costsAddAndCompare() {
        #expect(DecodeCost(units: 1) + DecodeCost(units: 0.5) == DecodeCost(units: 1.5))
        #expect(DecodeCost(units: 0.25) < DecodeCost(units: 0.5))
        #expect(DecodeCost.zero.units == 0)
        #expect(DecodeCost(units: 0.75).description == "0.75 DU")
        #expect(DecodeCost(units: 24).description == "24.00 DU")
    }

    // MARK: - Modes and priorities

    @Test func modeWeightsMatchTheContract() {
        #expect(DecodeMode.paused.costWeight == 0)
        #expect(DecodeMode.jpegPoll.costWeight == 0)
        #expect(DecodeMode.keyframesOnly.costWeight == 0.12)
        #expect(DecodeMode.fpsCapped.costWeight == 0.55)
        #expect(DecodeMode.trim.costWeight == 0.80)
        #expect(DecodeMode.full.costWeight == 1.00)
    }

    @Test func modesOrderFromPausedToFull() {
        #expect(DecodeMode.allCases.sorted() == [.paused, .jpegPoll, .keyframesOnly,
                                                 .fpsCapped, .trim, .full])
    }

    @Test func priorityOrderMatchesFeatureDEC06() {
        // focused > recording > visible large > visible small > wall > PiP > offscreen >
        // sidebar > background. Recording sits above every preview because it is never demoted.
        #expect(StreamPriority.focused > .recording)
        #expect(StreamPriority.recording > .visibleLarge)
        #expect(StreamPriority.visibleLarge > .visibleSmall)
        #expect(StreamPriority.visibleSmall > .wall)
        #expect(StreamPriority.wall > .pictureInPicture)
        #expect(StreamPriority.pictureInPicture > .offscreen)
        #expect(StreamPriority.offscreen > .sidebarThumbnail)
        #expect(StreamPriority.sidebarThumbnail > .background)
        #expect(Set(StreamPriority.allCases.map(\.rawValue)).count
            == StreamPriority.allCases.count)
    }

    @Test func budgetPressureOrdersByHowBadItIs() {
        #expect(BudgetPressure.none < .moderate)
        #expect(BudgetPressure.moderate < .severe)
        #expect(BudgetPressure.allCases.sorted() == [.none, .moderate, .severe])
    }

    // MARK: - Leases and results

    @Test func aLeaseKeepsItsIdentityWhenRepriced() {
        let key = StreamKey(camera: CameraID(), quality: .main)
        let lease = DecodeLease(key: key, cost: DecodeCost(units: 1), mode: .full)
        let repriced = lease.repriced(cost: DecodeCost(units: 0.25), mode: .keyframesOnly)
        #expect(repriced.id == lease.id)
        #expect(repriced.key == key)
        #expect(repriced.cost == DecodeCost(units: 0.25))
        #expect(repriced.mode == .keyframesOnly)
        #expect(lease.cost == DecodeCost(units: 1), "repricing must not mutate the original")
    }

    @Test func admissionResultExposesTheLeaseForBothGrantingCases() {
        let lease = DecodeLease(key: StreamKey(camera: CameraID(), quality: .sub),
                                cost: .zero, mode: .full)
        #expect(AdmissionResult.granted(lease).lease == lease)
        #expect(AdmissionResult.grantedDegraded(lease, .fpsCapped).lease == lease)
        #expect(AdmissionResult.denied(.thermalCritical).lease == nil)
    }

    @Test func budgetSnapshotRoundTripsThroughJSON() throws {
        let key = StreamKey(camera: CameraID(), quality: .main)
        let snapshot = BudgetSnapshot(budget: DecodeCost(units: 24),
                                      committed: DecodeCost(units: 6.5),
                                      sessionCount: 7, maxSessions: 24,
                                      pressure: .moderate, modes: [key: .fpsCapped])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(BudgetSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.modes[key] == .fpsCapped)
    }
}
