//
//  SyntheticFixtureTests.swift
//  VigilPipelineTests
//
//  Tests of the fixture itself. If the synthetic camera does not emit spec-valid bytes then every
//  pipeline assertion built on it is worthless, so these run first: the real bitstream parser reads
//  the generated parameter sets, the real RTP parser reads the generated packets, and the real SDP
//  parser reads the generated session description.
//

import Foundation
import Testing
import VigilBitstream
import VigilProtocols
import VigilRTP
import VigilRTSP
import VigilTestKit

// MARK: - Bit writer

@Suite struct SyntheticBitWriterSuite {

    /// ue(0) is a single `1` bit; ue(1) and ue(2) are `010` and `011`. ITU-T H.264 §9.1 Table 9-1.
    @Test func bitWriterExpGolombMatchesTable91() {
        var writer = SyntheticBitWriter()
        writer.writeUE(0)
        writer.writeUE(1)
        writer.writeUE(2)
        // 1 010 011 → 1010 0110, zero-padded to one byte.
        #expect(writer.rbsp == [0b1010_0110])
    }

    /// se(v) mapping from ITU-T H.264 §9.1.1 Table 9-3: 0→0, 1→1, -1→2, 2→3, -2→4.
    @Test func bitWriterSignedExpGolombMatchesTable93() {
        for (value, mapped) in [(Int32(0), UInt32(0)), (1, 1), (-1, 2), (2, 3), (-2, 4)] {
            var signed = SyntheticBitWriter()
            signed.writeSE(value)
            var unsigned = SyntheticBitWriter()
            unsigned.writeUE(mapped)
            #expect(signed.rbsp == unsigned.rbsp, "se(\(value)) should equal ue(\(mapped))")
        }
    }

    @Test func bitWriterPacksBitsMostSignificantFirst() {
        var writer = SyntheticBitWriter()
        writer.write(0b101, bits: 3)
        writer.write(0b01, bits: 2)
        #expect(writer.bitCount == 5)
        #expect(writer.rbsp == [0b1010_1000])
    }

    @Test func bitWriterAlignToByteWritesStopBitThenZeros() {
        var writer = SyntheticBitWriter()
        writer.write(1, bits: 1)
        writer.alignToByte()
        #expect(writer.isByteAligned)
        #expect(writer.rbsp == [0b1100_0000])
    }

    /// Emulation prevention inserts 0x03 before any byte that would complete 00 00 0x, x ≤ 3.
    @Test func bitWriterRBSPEscapeInsertsEmulationPreventionBytes() {
        #expect(SyntheticRBSP.escape([0x00, 0x00, 0x01]) == [0x00, 0x00, 0x03, 0x01])
        #expect(SyntheticRBSP.escape([0x00, 0x00, 0x00]) == [0x00, 0x00, 0x03, 0x00])
        #expect(SyntheticRBSP.escape([0x00, 0x00, 0x04]) == [0x00, 0x00, 0x04])
        #expect(SyntheticRBSP.escape([0x00, 0x01, 0x00]) == [0x00, 0x01, 0x00])
    }

    /// A run of zeros must be escaped repeatedly, not just once.
    @Test func bitWriterRBSPEscapeHandlesLongZeroRuns() {
        let escaped = SyntheticRBSP.escape([0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(escaped == [0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00])
    }
}

// MARK: - Parameter sets

@Suite struct SyntheticParameterSetSuite {

    /// A 1920×1080 H.264 SPS codes 1088 lines and crops 4 chroma units off the bottom. The real
    /// parser must recover 1920×1080 from it.
    @Test func parameterSetsH264SPSParsesToRequestedGeometry() throws {
        let builder = SyntheticParameterSetBuilder(width: 1920, height: 1080, frameRate: 25,
                                                   codec: .h264)
        let nal = builder.h264SPS()
        let sps = try nal.withUnsafeBytes { try H264Parser.parseSPS($0) }
        #expect(sps.codedWidth == 1920)
        #expect(sps.codedHeight == 1088)
        #expect(sps.displayWidth == 1920)
        #expect(sps.displayHeight == 1080)
        #expect(sps.profileIDC == 77)
        #expect(sps.frameRate == 25)
    }

    @Test func parameterSetsH264SPSNeedsNoCropWhenHeightIsAMultipleOf16() throws {
        let builder = SyntheticParameterSetBuilder(width: 1280, height: 720, frameRate: 20,
                                                   codec: .h264)
        let sps = try builder.h264SPS().withUnsafeBytes { try H264Parser.parseSPS($0) }
        #expect(sps.codedHeight == 720)
        #expect(sps.displayHeight == 720)
        #expect(sps.frameCropping.isZero)
        #expect(sps.frameRate == 20)
    }

    /// H.265 codes in 8-sample units, so 1080 needs no conformance window at all.
    @Test func parameterSetsH265SPSParsesToRequestedGeometry() throws {
        let builder = SyntheticParameterSetBuilder(width: 1920, height: 1080, frameRate: 25,
                                                   codec: .h265)
        let sps = try builder.h265SPS().withUnsafeBytes { try H265Parser.parseSPS($0) }
        #expect(sps.codedWidth == 1920)
        #expect(sps.codedHeight == 1080)
        #expect(sps.displayWidth == 1920)
        #expect(sps.displayHeight == 1080)
        #expect(sps.frameRate == 25)
    }

    /// A height that is not a multiple of 8 exercises the conformance window path.
    @Test func parameterSetsH265SPSAppliesConformanceWindow() throws {
        let builder = SyntheticParameterSetBuilder(width: 1920, height: 1076, frameRate: 25,
                                                   codec: .h265)
        let sps = try builder.h265SPS().withUnsafeBytes { try H265Parser.parseSPS($0) }
        #expect(sps.codedHeight == 1080)
        #expect(sps.displayHeight == 1076)
    }

    @Test func parameterSetsH265VPSAndPPSParse() throws {
        let builder = SyntheticParameterSetBuilder(width: 1920, height: 1080, frameRate: 25,
                                                   codec: .h265)
        let vps = try builder.h265VPS().withUnsafeBytes { try H265Parser.parseVPS($0) }
        let pps = try builder.h265PPS().withUnsafeBytes { try H265Parser.parsePPS($0) }
        #expect(vps.vpsID == 0)
        #expect(pps.ppsID == 0)
        #expect(pps.spsID == 0)
    }

    @Test func parameterSetsH264PPSParses() throws {
        let builder = SyntheticParameterSetBuilder(width: 1280, height: 720, frameRate: 25,
                                                   codec: .h264)
        let pps = try builder.h264PPS().withUnsafeBytes { try H264Parser.parsePPS($0) }
        #expect(pps.picParameterSetID == 0)
        #expect(pps.seqParameterSetID == 0)
        #expect(pps.entropyCodingModeFlag)
    }

    @Test func parameterSetsHaveCorrectNALTypes() {
        let h264 = SyntheticParameterSetBuilder(width: 640, height: 480, frameRate: 25,
                                                codec: .h264).parameterSetNALs()
        #expect(h264.map { $0[0] & 0x1F } == [7, 8])
        let h265 = SyntheticParameterSetBuilder(width: 640, height: 480, frameRate: 25,
                                                codec: .h265).parameterSetNALs()
        #expect(h265.map { ($0[0] >> 1) & 0x3F } == [32, 33, 34])
    }
}

// MARK: - Encoder

@Suite struct SyntheticEncoderSuite {

    @Test func encoderPlacesKeyframesOnTheGOPBoundary() {
        var encoder = SyntheticEncoder(profile: .hevcCamera(), startTimestamp: 0)
        let units = (0..<50).map { _ in encoder.nextAccessUnit() }
        #expect(units[0].isKeyframe)
        #expect(units[25].isKeyframe)
        #expect(!units[1].isKeyframe)
        #expect(units.filter(\.isKeyframe).count == 2)
    }

    @Test func encoderAdvancesTimestampByOneFramePeriod() {
        let profile = SyntheticCameraProfile.hevcCamera()
        var encoder = SyntheticEncoder(profile: profile, startTimestamp: 1_000)
        let first = encoder.nextAccessUnit()
        let second = encoder.nextAccessUnit()
        #expect(first.rtpTimestamp == 1_000)
        #expect(second.rtpTimestamp == 1_000 &+ profile.ticksPerFrame)
        #expect(profile.ticksPerFrame == 3_600)
    }

    @Test func encoderWrapsTimestampAtTwoToThe32() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.timestampWrapSoon)
        var encoder = SyntheticEncoder(profile: profile, startTimestamp: 0xFFFF_F000)
        var previous: UInt32 = 0xFFFF_F000
        var sawWrap = false
        for _ in 0..<10 {
            let unit = encoder.nextAccessUnit()
            if unit.rtpTimestamp < previous { sawWrap = true }
            previous = unit.rtpTimestamp
        }
        #expect(sawWrap, "a 3600-tick step from 0xFFFFF000 must wrap within ten frames")
    }

    @Test func encoderCarriesParameterSetsInBandAheadOfEveryKeyframe() {
        var encoder = SyntheticEncoder(profile: .hevcCamera(), startTimestamp: 0)
        let keyframe = encoder.nextAccessUnit()
        #expect(keyframe.nalTypeCodes == [32, 33, 34, 19])
        let delta = encoder.nextAccessUnit()
        #expect(delta.nalTypeCodes == [1])
    }

    @Test func encoderOmitsInBandParameterSetsUnderParameterSetsOnlyInSDP() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.parameterSetsOnlyInSDP)
        var encoder = SyntheticEncoder(profile: profile, startTimestamp: 0)
        #expect(encoder.nextAccessUnit().nalTypeCodes == [19])
    }

    @Test func encoderSuppressesIRAPUnderStartMidGOP() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.startMidGOP(seconds: 2))
        var encoder = SyntheticEncoder(profile: profile, startTimestamp: 0)
        let units = (0..<80).map { _ in encoder.nextAccessUnit() }
        // 2 s at 25 fps = 50 access units with no IRAP; the next GOP boundary is 50.
        #expect(units[0..<50].allSatisfy { !$0.isKeyframe })
        #expect(units[50].isKeyframe)
    }

    @Test func encoderChangesGeometryMidStream() throws {
        let profile = SyntheticCameraProfile.hevcCamera()
            .adding(.midStreamResolutionChange(atFrame: 10, newWidth: 1280, newHeight: 720))
        var encoder = SyntheticEncoder(profile: profile, startTimestamp: 0)
        for _ in 0..<10 { _ = encoder.nextAccessUnit() }
        let changed = encoder.nextAccessUnit()
        #expect(changed.isKeyframe)
        let sps = try #require(changed.parameterSets.sps.first)
        let parsed = try Array(sps).withUnsafeBytes { try H265Parser.parseSPS($0) }
        #expect(parsed.displayWidth == 1280)
        #expect(parsed.displayHeight == 720)
    }

    /// The same seed must produce the same bytes, or a failure is not replayable.
    @Test func encoderIsDeterministicForAGivenSeed() {
        var first = SyntheticEncoder(profile: .hevcCamera(seed: 42), startTimestamp: 0)
        var second = SyntheticEncoder(profile: .hevcCamera(seed: 42), startTimestamp: 0)
        for _ in 0..<20 {
            #expect(first.nextAccessUnit().nals == second.nextAccessUnit().nals)
        }
    }

    @Test func encoderDiffersBetweenSeeds() {
        var first = SyntheticEncoder(profile: .hevcCamera(seed: 1), startTimestamp: 0)
        var second = SyntheticEncoder(profile: .hevcCamera(seed: 2), startTimestamp: 0)
        #expect(first.nextAccessUnit().nals != second.nextAccessUnit().nals)
    }
}

// MARK: - RTP generator

@Suite struct SyntheticRTPGeneratorSuite {

    private func packets(_ profile: SyntheticCameraProfile,
                         accessUnits: Int) -> [RTPPacketBytes] {
        var encoder = SyntheticEncoder(profile: profile, startTimestamp: 0)
        var generator = RTPStreamGenerator(profile: profile, ssrc: 0x1234_5678, startSequence: 100)
        var out: [RTPPacketBytes] = []
        for _ in 0..<accessUnits {
            out.append(contentsOf: generator.packetize(encoder.nextAccessUnit()))
        }
        out.append(contentsOf: generator.drain())
        return out
    }

    @Test func rtpGeneratorEmitsPacketsTheRealParserAccepts() throws {
        for profile in SyntheticCameraProfile.allPresets() {
            for packet in packets(profile, accessUnits: 3) {
                let parsed = try RTPPacket.parse(Data(packet.bytes))
                #expect(parsed.version == 2)
                #expect(parsed.payloadType == profile.payloadType)
                #expect(parsed.sequenceNumber == packet.sequenceNumber)
                #expect(parsed.timestamp == packet.timestamp)
                #expect(parsed.marker == packet.marker)
                #expect(!parsed.payload.isEmpty)
            }
        }
    }

    @Test func rtpGeneratorHonoursTheMTU() {
        var profile = SyntheticCameraProfile.hevcCamera()
        profile.mtu = 600
        for packet in packets(profile, accessUnits: 3) {
            #expect(packet.bytes.count <= 600, "packet exceeded the MTU")
        }
    }

    @Test func rtpGeneratorFragmentsWithFUPacketsForH265() {
        let profile = SyntheticCameraProfile.hevcCamera()
        let all = packets(profile, accessUnits: 2)
        let types = all.map { ($0.bytes[12] >> 1) & 0x3F }
        #expect(types.contains(49), "an oversized H.265 slice must fragment into FU packets")
        // The first fragment sets S and the last sets E, exactly once each per NAL.
        let fragments = all.filter { ($0.bytes[12] >> 1) & 0x3F == 49 }
        #expect(fragments.contains { $0.bytes[14] & 0x80 != 0 })
        #expect(fragments.contains { $0.bytes[14] & 0x40 != 0 })
    }

    @Test func rtpGeneratorFragmentsWithFUAPacketsForH264() {
        let profile = SyntheticCameraProfile.ds2cd2143g2()
        let all = packets(profile, accessUnits: 2)
        let types = all.map { $0.bytes[12] & 0x1F }
        #expect(types.contains(28), "an oversized H.264 slice must fragment into FU-A packets")
        let fragments = all.filter { $0.bytes[12] & 0x1F == 28 }
        #expect(fragments.contains { $0.bytes[13] & 0x80 != 0 })
        #expect(fragments.contains { $0.bytes[13] & 0x40 != 0 })
    }

    @Test func rtpGeneratorAggregatesParameterSetsWhenAsked() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.aggregationPackets)
        let all = packets(profile, accessUnits: 1)
        let types = all.map { ($0.bytes[12] >> 1) & 0x3F }
        #expect(types.contains(48), "the three parameter sets should ride in one AP packet")
    }

    @Test func rtpGeneratorSetsTheMarkerOnTheLastPacketOfAnAccessUnit() {
        let all = packets(.hevcCamera(), accessUnits: 4)
        let marked = all.filter(\.marker)
        #expect(marked.count == 4)
        for packet in marked {
            let sameUnit = all.filter { $0.accessUnitIndex == packet.accessUnitIndex }
            #expect(sameUnit.last?.sequenceNumber == packet.sequenceNumber)
        }
    }

    @Test func rtpGeneratorNeverSetsTheMarkerUnderMarkerNeverSet() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.markerNeverSet)
        #expect(packets(profile, accessUnits: 6).allSatisfy { !$0.marker })
    }

    @Test func rtpGeneratorSetsTheMarkerMidPictureUnderMarkerMidPicture() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.markerMidPicture)
        let all = packets(profile, accessUnits: 4)
        let marked = all.filter(\.marker)
        #expect(!marked.isEmpty)
        for packet in marked {
            let sameUnit = all.filter { $0.accessUnitIndex == packet.accessUnitIndex }
            #expect(sameUnit.last?.sequenceNumber != packet.sequenceNumber,
                    "the marker must not land on the real last packet")
        }
    }

    @Test func rtpGeneratorWrapsSequenceNumbersUnderSequenceWrapSoon() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.sequenceWrapSoon)
        let all = packets(profile, accessUnits: 4)
        #expect(all.first?.sequenceNumber == 65_500)
        #expect(all.contains { $0.sequenceNumber < 100 }, "the counter must wrap during the run")
    }

    @Test func rtpGeneratorDropsRoughlyTheRequestedFraction() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.packetLoss(rate: 0.10))
        var encoder = SyntheticEncoder(profile: profile, startTimestamp: 0)
        var generator = RTPStreamGenerator(profile: profile, ssrc: 1, startSequence: 0)
        var emitted = 0
        for _ in 0..<60 { emitted += generator.packetize(encoder.nextAccessUnit()).count }
        let dropped = generator.droppedSequenceNumbers.count
        let fraction = Double(dropped) / Double(dropped + emitted)
        #expect(fraction > 0.05 && fraction < 0.16, "observed loss \(fraction) is far from 10 %")
        #expect(!generator.damagedAccessUnits.isEmpty)
    }

    @Test func rtpGeneratorReordersWithinTheWindow() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.reorder(windowPackets: 8))
        let all = packets(profile, accessUnits: 4)
        var outOfOrder = 0
        for index in 1..<all.count where all[index].sequenceNumber < all[index - 1].sequenceNumber {
            outOfOrder += 1
        }
        #expect(outOfOrder > 0, "the reorder quirk must actually reorder")
        #expect(Set(all.map(\.sequenceNumber)).count == all.count, "no packet may be lost")
    }

    @Test func rtpGeneratorDuplicatesPackets() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.duplicate(rate: 0.2))
        let all = packets(profile, accessUnits: 4)
        #expect(Set(all.map(\.sequenceNumber)).count < all.count)
    }

    @Test func rtpGeneratorSenderReportParsesAsRTCP() {
        var generator = RTPStreamGenerator(profile: .hevcCamera(), ssrc: 0xDEAD_BEEF,
                                           startSequence: 0)
        let report = generator.senderReport(ntpSeconds: 3_900_000_000, ntpFraction: 0,
                                            rtpTimestamp: 90_000, cname: "test@example")
        let packets = RTCPParser.parseCompound(Data(report))
        #expect(packets.count == 2, "a sender report and an SDES should both parse")
    }
}
