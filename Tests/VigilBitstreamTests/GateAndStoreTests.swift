//
//  GateAndStoreTests.swift
//  VigilBitstreamTests
//
//  The parameter-set store's merge and format-change rules, and the IRAP gate's admission rules.
//  Covers docs/spec-bitstream.md §20.2–§20.5 and §21, including T-GATE-1…4 and T-STORE-1…4.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilBitstream

// MARK: - Fixtures

private enum StoreVector {
    /// H.264 Main 4.0, 1920×1088 coded / 1920×1080 display, 25 fps (§23.2 V1).
    static let v1 = "Z00AKPQDwBE/LgIgAAADACAAAAZQgA=="
    /// H.264 High 4.1, the same 1920×1088 coded size, 30 fps (§23.2 V2).
    static let v2 = "Z2QAKawsrAeAIn5cBagICAoAAAMAAgAAAwB5Ht8="
    /// H.264 High 5.0, 2560×1440 — a genuine resolution change from V1 (§23.2 V3).
    static let v3 = "Z2QAMqzoAoALWwEQAAADABAAAAMCiEA="
    static let p1 = "aO48gA=="
    static let hevcVPS = "QAEMAf//AWAAAAMAsAAAAwAAAwB7lwJA"
    static let w1 = "QgEBAWAAAAMAsAAAAwAAAwB7oAPAgBDlll5JG2S7wFqAgICCAAADAAIAAAMAMlcIBBA="
    static let q1 = "RAHh88DMkA=="

    static func data(_ base64: String) -> Data { Data(base64Encoded: base64) ?? Data() }
}

/// A stable label so a test can assert the *kind* of change without restating the whole
/// `VideoFormatInfo` it carries.
private extension ParameterSetChange {
    var label: String {
        switch self {
        case .unchanged: "unchanged"
        case .firstSet: "firstSet"
        case .compatible: "compatible"
        case .incompatible: "incompatible"
        }
    }
}

// MARK: - ParameterSetStore

@Suite struct ParameterSetStoreTests {

    @Test func parameterSetStoreMergesSPSAndPPSArrivingSeparately() {
        // The failure this prevents: a store that replaced on each arrival would hold only the PPS
        // here, never become complete, and the decoder would never get a format description.
        var store = ParameterSetStore()
        #expect(!store.isComplete)

        let first = store.ingest(ParameterSets(codec: .h264,
                                               sps: [StoreVector.data(StoreVector.v1)]))
        #expect(first.label == "firstSet")
        #expect(!store.isComplete)
        #expect(store.format != nil)

        let second = store.ingest(ParameterSets(codec: .h264,
                                                pps: [StoreVector.data(StoreVector.p1)]))
        #expect(second.label == "compatible")
        #expect(store.isComplete)
        #expect(store.sets?.sps.count == 1)
        #expect(store.sets?.pps.count == 1)
        #expect(store.sets?.sps.first == StoreVector.data(StoreVector.v1))
        #expect(store.generation == 2)
    }

    @Test func parameterSetStoreMergesTheHEVCTripleAcrossThreeIngests() {
        var store = ParameterSetStore()
        _ = store.ingest(ParameterSets(codec: .h265, vps: [StoreVector.data(StoreVector.hevcVPS)]))
        #expect(!store.isComplete)
        _ = store.ingest(ParameterSets(codec: .h265, sps: [StoreVector.data(StoreVector.w1)]))
        #expect(!store.isComplete)                  // H.265 needs all three
        _ = store.ingest(ParameterSets(codec: .h265, pps: [StoreVector.data(StoreVector.q1)]))
        #expect(store.isComplete)
        #expect(store.h265VPS?.vpsID == 0)
        #expect(store.h265SPS?.codedWidth == 1920)
        #expect(store.h265PPS[0]?.parallelismType == 1)
        #expect(store.format?.codec == .h265)
        #expect(store.format?.displayHeight == 1080)
    }

    @Test func parameterSetStoreReportsAnIdenticalResendAsUnchanged() {
        // T-STORE-1. Hikvision re-sends the parameter sets before every IDR; bumping `generation`
        // there would rebuild the format description twice a second forever.
        var store = ParameterSetStore()
        let sets = ParameterSets(codec: .h264, sps: [StoreVector.data(StoreVector.v1)],
                                 pps: [StoreVector.data(StoreVector.p1)])
        #expect(store.ingest(sets).label == "firstSet")
        let generation = store.generation
        #expect(store.ingest(sets).label == "unchanged")
        #expect(store.ingest(sets).label == "unchanged")
        #expect(store.generation == generation)
    }

    @Test func parameterSetStoreTreatsANewFrameRateAsCompatible() {
        // T-STORE-2. V1 and V2 share a coded size, chroma format and bit depth, and differ in
        // profile, level and frame rate. The decode session survives; only the format description
        // is rebuilt.
        var store = ParameterSetStore()
        _ = store.ingest(ParameterSets(codec: .h264, sps: [StoreVector.data(StoreVector.v1)],
                                       pps: [StoreVector.data(StoreVector.p1)]))
        #expect(store.format?.frameRate == 25.0)
        let change = store.ingest(ParameterSets(codec: .h264,
                                                sps: [StoreVector.data(StoreVector.v2)]))
        #expect(change.label == "compatible")
        #expect(store.format?.frameRate == 30.0)
        #expect(store.format?.codedWidth == 1920)
        #expect(store.generation == 2)
        if case .compatible(let previous) = change {
            #expect(previous?.frameRate == 25.0)
        } else {
            Issue.record("expected .compatible, got \(change)")
        }
    }

    @Test func parameterSetStoreTreatsAResolutionChangeAsIncompatible() {
        // T-STORE-3: 1920×1088 → 2560×1440. The pixel-buffer pool is size-bound, so the session
        // must be drained and recreated.
        var store = ParameterSetStore()
        _ = store.ingest(ParameterSets(codec: .h264, sps: [StoreVector.data(StoreVector.v1)],
                                       pps: [StoreVector.data(StoreVector.p1)]))
        let change = store.ingest(ParameterSets(codec: .h264,
                                                sps: [StoreVector.data(StoreVector.v3)]))
        #expect(change.label == "incompatible")
        #expect(store.format?.codedWidth == 2560)
        #expect(store.format?.codedHeight == 1440)
        if case .incompatible(let previous) = change {
            #expect(previous?.codedWidth == 1920)
        } else {
            Issue.record("expected .incompatible, got \(change)")
        }
    }

    @Test func parameterSetStoreKeepsBytesThatFailToParse() {
        // T-STORE-4, and the policy that matters most: VideoToolbox has its own, more permissive
        // parser. A parameter set we reject must still reach the decoder.
        var store = ParameterSetStore()
        let broken = Data([0x67, 0xFF, 0xFF, 0xFF])
        let change = store.ingest(ParameterSets(codec: .h264, sps: [broken],
                                                pps: [StoreVector.data(StoreVector.p1)]))
        #expect(change.label == "firstSet")
        #expect(store.isComplete)                   // about bytes, never about parse success
        #expect(store.sets?.sps.first == broken)
        #expect(store.format == nil)
        #expect(store.h264SPS == nil)
    }

    @Test func parameterSetStoreKeepsTheLastGoodFormatWhenAResendFailsToParse() {
        var store = ParameterSetStore()
        _ = store.ingest(ParameterSets(codec: .h264, sps: [StoreVector.data(StoreVector.v1)],
                                       pps: [StoreVector.data(StoreVector.p1)]))
        _ = store.ingest(ParameterSets(codec: .h264, sps: [Data([0x67, 0xFF, 0xFF, 0xFF])]))
        #expect(store.format?.codedWidth == 1920)   // last good geometry beats no geometry
        #expect(store.h264SPS == nil)
    }

    @Test func parameterSetStoreReplacesASetWithTheSameIDInPlace() {
        // V1 and V2 are both seq_parameter_set_id 0, so the store must end up with one SPS, not two.
        var store = ParameterSetStore()
        _ = store.ingest(ParameterSets(codec: .h264, sps: [StoreVector.data(StoreVector.v1)]))
        _ = store.ingest(ParameterSets(codec: .h264, sps: [StoreVector.data(StoreVector.v2)]))
        #expect(store.sets?.sps.count == 1)
        #expect(store.sets?.sps.first == StoreVector.data(StoreVector.v2))
    }

    @Test func parameterSetStoreDiscardsEverythingWhenTheCodecChanges() {
        var store = ParameterSetStore()
        _ = store.ingest(ParameterSets(codec: .h264, sps: [StoreVector.data(StoreVector.v1)],
                                       pps: [StoreVector.data(StoreVector.p1)]))
        let change = store.ingest(ParameterSets(codec: .h265,
                                                vps: [StoreVector.data(StoreVector.hevcVPS)],
                                                sps: [StoreVector.data(StoreVector.w1)],
                                                pps: [StoreVector.data(StoreVector.q1)]))
        #expect(change.label == "incompatible")
        #expect(store.sets?.codec == .h265)
        #expect(store.h264SPS == nil)
        #expect(store.format?.codec == .h265)
    }

    @Test func parameterSetStoreResetEmptiesEverything() {
        var store = ParameterSetStore()
        _ = store.ingest(ParameterSets(codec: .h264, sps: [StoreVector.data(StoreVector.v1)],
                                       pps: [StoreVector.data(StoreVector.p1)]))
        store.reset()
        #expect(store.sets == nil)
        #expect(store.format == nil)
        #expect(store.generation == 0)
        #expect(!store.isComplete)
    }

    @Test func parameterSetStoreCapsTheNumberOfStoredSets() {
        // A stream that re-sends a slightly different, unparseable SPS must not grow the store
        // without bound: each set is unparseable, so none can be matched by id.
        var store = ParameterSetStore()
        for index in 0 ..< 40 {
            let junk = Data([0x67, 0xFF, 0xFF, UInt8(truncatingIfNeeded: index)])
            _ = store.ingest(ParameterSets(codec: .h264, sps: [junk]))
        }
        #expect((store.sets?.sps.count ?? 0) <= 8)
    }
}

// MARK: - IRAPGate

@Suite struct IRAPGateTests {

    private func nonIRAP(_ codec: VideoCodec = .h264) -> AccessUnitSummary {
        AccessUnitSummary(codec: codec, containsVCL: true, parameterSetsAvailable: true,
                          firstSliceSeen: true)
    }

    private func idr(_ codec: VideoCodec = .h264) -> AccessUnitSummary {
        AccessUnitSummary(codec: codec, containsIRAP: true, containsIDR: true, containsVCL: true,
                          parameterSetsAvailable: true, firstSliceSeen: true)
    }

    @Test func irapGateStartsClosed() {
        let gate = IRAPGate(codec: .h264)
        #expect(!gate.isOpen)
        #expect(!gate.shouldRequestKeyframe)
        #expect(gate.droppedAccessUnits == 0)
    }

    @Test func irapGateDropsUntilAnIDRArrives() {
        // T-GATE-1: forty non-IRAP access units are dropped; the forty-first, carrying an IDR,
        // opens the gate.
        var gate = IRAPGate(codec: .h264)
        for _ in 0 ..< 40 {
            #expect(gate.evaluate(nonIRAP(), at: nil) == .drop(.awaitingIRAP))
        }
        #expect(gate.droppedAccessUnits == 40)
        #expect(gate.shouldRequestKeyframe)         // raised well before the fortieth drop
        #expect(!gate.isOpen)

        #expect(gate.evaluate(idr(), at: nil) == .pass)
        #expect(gate.isOpen)
        #expect(!gate.shouldRequestKeyframe)
        #expect(gate.droppedAccessUnits == 40)
    }

    @Test func irapGateRaisesTheKeyframeRequestOnlyAfterThePolicyThreshold() {
        var gate = IRAPGate(codec: .h264)
        for _ in 0 ..< 24 { _ = gate.admit(nonIRAP()) }
        #expect(!gate.shouldRequestKeyframe)
        _ = gate.admit(nonIRAP())
        #expect(gate.shouldRequestKeyframe)
    }

    @Test func irapGateRefusesAnIRAPWithNoParameterSets() {
        var gate = IRAPGate(codec: .h264)
        let orphan = AccessUnitSummary(codec: .h264, containsIRAP: true, containsIDR: true,
                                       containsVCL: true, parameterSetsAvailable: false)
        #expect(gate.evaluate(orphan, at: nil) == .drop(.missingParameterSets))
        #expect(!gate.isOpen)
    }

    @Test func irapGateDropsAnAccessUnitWithNoVCLNAL() {
        var gate = IRAPGate(codec: .h264)
        let parameterSetsOnly = AccessUnitSummary(codec: .h264, parameterSetsAvailable: true)
        #expect(gate.evaluate(parameterSetsOnly, at: nil) == .drop(.nonVCLOnly))
    }

    @Test func irapGateOpensOnAnExactRecoveryPoint() {
        // T-GATE-2.
        var gate = IRAPGate(codec: .h264)
        var summary = nonIRAP()
        summary.recoveryPoint = RecoveryPoint(recoveryCount: 0, exactMatch: true, brokenLink: false)
        #expect(gate.evaluate(summary, at: nil) == .pass)
        #expect(gate.isOpen)
    }

    @Test func irapGateStaysClosedOnABrokenLink() {
        // T-GATE-2, second half. Pictures after a broken link reference frames that do not exist.
        var gate = IRAPGate(codec: .h264)
        var summary = nonIRAP()
        summary.recoveryPoint = RecoveryPoint(recoveryCount: 0, exactMatch: true, brokenLink: true)
        #expect(gate.evaluate(summary, at: nil) == .drop(.awaitingIRAP))
        #expect(!gate.isOpen)

        var withIRAP = idr()
        withIRAP.recoveryPoint = RecoveryPoint(recoveryCount: 0, exactMatch: true, brokenLink: true)
        #expect(gate.evaluate(withIRAP, at: nil) == .drop(.brokenLink))
        #expect(!gate.isOpen)
    }

    @Test func irapGateIgnoresAnInexactRecoveryPointUnderTheStrictPolicy() {
        var strict = IRAPGate(codec: .h264, policy: .strict)
        var summary = nonIRAP()
        summary.recoveryPoint = RecoveryPoint(recoveryCount: 0, exactMatch: false, brokenLink: false)
        #expect(strict.evaluate(summary, at: nil) == .drop(.awaitingIRAP))

        var lenient = IRAPGate(codec: .h264,
                               policy: IRAPGate.Policy(acceptRecoveryPointSEI: true,
                                                       acceptInexactRecoveryPoint: true))
        #expect(lenient.evaluate(summary, at: nil) == .pass)
    }

    @Test func irapGateIgnoresRecoveryPointsUnderTheRecordedPlaybackPolicy() {
        var gate = IRAPGate(codec: .h265, policy: .recordedPlayback)
        var summary = nonIRAP(.h265)
        summary.recoveryPoint = RecoveryPoint(recoveryCount: 0, exactMatch: true, brokenLink: false)
        #expect(gate.evaluate(summary, at: nil) == .drop(.awaitingIRAP))
    }

    @Test func irapGateDropsRASLPicturesAfterACRAStart() {
        // T-GATE-3, and the reason the rule exists: RASL pictures associated with the CRA we
        // started at reference frames before it, which the decoder never saw. Forwarding them
        // produces the green flash users report when seeking NVR playback.
        var gate = IRAPGate(codec: .h265)
        let cra = AccessUnitSummary(codec: .h265, containsIRAP: true, containsCRAOrBLA: true,
                                    containsVCL: true, parameterSetsAvailable: true,
                                    firstSliceSeen: true)
        #expect(gate.evaluate(cra, at: nil) == .pass)
        #expect(gate.isOpen)

        let rasl = AccessUnitSummary(codec: .h265, containsRASL: true, containsVCL: true,
                                     parameterSetsAvailable: true, firstSliceSeen: true)
        #expect(gate.evaluate(rasl, at: nil) == .drop(.raslAfterCRAStart))
        #expect(gate.evaluate(rasl, at: nil) == .drop(.raslAfterCRAStart))

        // The first access unit with no RASL NAL clears NoRaslOutputFlag …
        #expect(gate.evaluate(nonIRAP(.h265), at: nil) == .pass)
        // … after which RASL pictures are decodable again.
        #expect(gate.evaluate(rasl, at: nil) == .pass)
    }

    @Test func irapGateDoesNotSetNoRaslOutputForAnIDRStart() {
        // IDR_W_RADL has no associated RASL pictures, so starting there must not arm the rule.
        var gate = IRAPGate(codec: .h265)
        let idrAU = AccessUnitSummary(codec: .h265, containsIRAP: true, containsIDR: true,
                                      containsVCL: true, parameterSetsAvailable: true)
        #expect(gate.evaluate(idrAU, at: nil) == .pass)
        let rasl = AccessUnitSummary(codec: .h265, containsRASL: true, containsVCL: true,
                                     parameterSetsAvailable: true)
        #expect(gate.evaluate(rasl, at: nil) == .pass)
    }

    @Test func irapGateOpensOnTheDesperationTimeout() {
        // T-GATE-4. A visibly imperfect picture beats a permanently blank tile on firmware that
        // never emits an IRAP.
        var gate = IRAPGate(codec: .h264)
        let start = MediaInstant(nanoseconds: 0)
        #expect(gate.evaluate(nonIRAP(), at: start) == .drop(.awaitingIRAP))
        #expect(gate.evaluate(nonIRAP(), at: start + .seconds(11)) == .drop(.awaitingIRAP))
        #expect(gate.evaluate(nonIRAP(), at: start + .seconds(13)) == .pass)
        #expect(gate.isOpen)
    }

    @Test func irapGateNeverDesperationOpensWithoutAClock() {
        var gate = IRAPGate(codec: .h264)
        for _ in 0 ..< 1000 {
            let admitted = gate.admit(nonIRAP())
            #expect(!admitted)
        }
        #expect(!gate.isOpen)
    }

    @Test func irapGateResetClosesTheGateAndClearsTheRASLFlag() {
        var gate = IRAPGate(codec: .h265)
        let cra = AccessUnitSummary(codec: .h265, containsIRAP: true, containsCRAOrBLA: true,
                                    containsVCL: true, parameterSetsAvailable: true)
        _ = gate.admit(cra)
        gate.reset()
        #expect(!gate.isOpen)
        #expect(gate.droppedAccessUnits == 0)
        #expect(!gate.shouldRequestKeyframe)
        // Closed again: a RASL access unit is now refused for want of an IRAP, not for the flag.
        let rasl = AccessUnitSummary(codec: .h265, containsRASL: true, containsVCL: true,
                                     parameterSetsAvailable: true)
        #expect(gate.evaluate(rasl, at: nil) == .drop(.awaitingIRAP))
    }
}

// MARK: - AccessUnitSummary

@Suite struct AccessUnitSummaryTests {

    @Test func accessUnitSummaryClassifiesH264TypeCodes() {
        var summary = AccessUnitSummary(codec: .h264)
        summary.observe(typeCode: 7)                // SPS
        #expect(!summary.containsVCL)
        summary.observe(typeCode: 5, isFirstSlice: true)
        #expect(summary.containsVCL)
        #expect(summary.containsIRAP)
        #expect(summary.containsIDR)
        #expect(summary.firstSliceSeen)
        #expect(summary.isKeyframe)
    }

    @Test func accessUnitSummaryDoesNotCallAnIntraSliceAKeyframe() {
        // §20.5: only an IDR resets the decoded picture buffer, so a type-1 slice — even an
        // all-intra one — is not a sync sample and must not be written as one.
        var summary = AccessUnitSummary(codec: .h264)
        summary.observe(typeCode: 1, isFirstSlice: true)
        #expect(summary.containsVCL)
        #expect(!summary.isKeyframe)
    }

    @Test func accessUnitSummaryClassifiesH265IRAPRanges() {
        for type in UInt8(16) ... 23 {
            var summary = AccessUnitSummary(codec: .h265)
            summary.observe(typeCode: type)
            #expect(summary.containsIRAP)
            #expect(summary.isKeyframe)
            #expect(summary.containsCRAOrBLA == ((16 ... 18).contains(type) || type == 21))
            #expect(summary.containsIDR == (type == 19 || type == 20))
        }
        for type in UInt8(8) ... 9 {
            var summary = AccessUnitSummary(codec: .h265)
            summary.observe(typeCode: type)
            #expect(summary.containsRASL)
            #expect(!summary.containsIRAP)
        }
        var parameterSet = AccessUnitSummary(codec: .h265)
        parameterSet.observe(typeCode: 33)
        #expect(!parameterSet.containsVCL)
    }

    @Test func accessUnitSummaryReadsTypeAndFirstSliceFromANALUnit() {
        // H.265 IDR_W_RADL (19), layer 0, TID 0, first_slice_segment_in_pic_flag = 1.
        let nal: [UInt8] = [0x26, 0x01, 0x80, 0x00]
        var summary = AccessUnitSummary(codec: .h265)
        nal.withUnsafeBytes { summary.observe(nalUnit: $0) }
        #expect(summary.containsIRAP)
        #expect(summary.containsIDR)
        #expect(summary.firstSliceSeen)

        // The same picture's second slice segment: the flag is 0.
        let continuation: [UInt8] = [0x26, 0x01, 0x40, 0x00]
        var second = AccessUnitSummary(codec: .h265)
        continuation.withUnsafeBytes { second.observe(nalUnit: $0) }
        #expect(second.containsIRAP)
        #expect(!second.firstSliceSeen)
    }

    @Test func accessUnitSummaryIgnoresANALShorterThanItsHeader() {
        var summary = AccessUnitSummary(codec: .h265)
        let stub: [UInt8] = [0x26]
        stub.withUnsafeBytes { summary.observe(nalUnit: $0) }
        #expect(!summary.containsVCL)
        #expect(!summary.containsIRAP)
    }
}
