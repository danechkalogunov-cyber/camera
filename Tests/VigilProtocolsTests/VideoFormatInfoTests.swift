//
//  VideoFormatInfoTests.swift
//  VigilProtocolsTests
//
//  The geometry passthroughs and `isDecoderCompatible`, which is the single predicate that decides
//  whether a running decode session survives a format change.
//  Covers docs/API_CONTRACT.md §3.6 and §2 R-50.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct VideoFormatInfoTests {

    /// H.264 High profile 1080p, coded 1920x1088 — the shape of every Hikvision main stream.
    private static func h264Main() -> VideoFormatInfo {
        VideoFormatInfo(codec: .h264,
                        geometry: FrameGeometry(codedWidth: 1_920, codedHeight: 1_088,
                                                cropWidth: 1_920, cropHeight: 1_080),
                        frameRate: 25.0, profileIDC: 100, constraintFlags: 0, levelIDC: 41,
                        chromaFormatIDC: 1, profileName: "High", levelName: "4.1")
    }

    // MARK: - Passthroughs

    @Test func videoFormatInfoPassesGeometryThrough() {
        let format = Self.h264Main()
        #expect(format.codedWidth == 1_920)
        #expect(format.codedHeight == 1_088)
        #expect(format.displayWidth == 1_920)
        #expect(format.displayHeight == 1_080)
        #expect(format.sarWidth == 1)
        #expect(format.sarHeight == 1)
        #expect(format.bitDepthLuma == 8)
        #expect(format.isProgressive)
        #expect(format.pixelAspectRatio == 1.0)
        #expect(format.displayAspectRatio == 1_920.0 / 1_080.0)
        #expect(format.codedPixels == 1_920 * 1_088)
    }

    @Test func videoFormatInfoPassesANonSquarePixelAspectThrough() {
        var format = Self.h264Main()
        format.geometry.sarWidth = 12
        format.geometry.sarHeight = 11
        format.geometry.cropWidth = 704
        format.geometry.cropHeight = 576
        #expect(format.displayWidth == 768)
        #expect(format.displayHeight == 576)
        #expect(format.pixelAspectRatio == 12.0 / 11.0)
    }

    @Test func videoFormatInfoDefaultsDescribeAnUnparsedFormat() {
        let minimal = VideoFormatInfo(codec: .h265,
                                      geometry: FrameGeometry(codedWidth: 640, codedHeight: 368,
                                                              cropWidth: 640, cropHeight: 360))
        #expect(minimal.frameRate == nil)
        #expect(minimal.profileIDC == 0)
        #expect(minimal.tier == 0)
        #expect(minimal.chromaFormatIDC == 1, "4:2:0 is the only format Hikvision ships")
        #expect(minimal.maxNumReorderFrames == 0)
        #expect(minimal.numTemporalLayers == 1)
        #expect(!minimal.temporalIDNested)
        #expect(minimal.profileName.isEmpty)
        #expect(minimal.levelName.isEmpty)
    }

    // MARK: - isDecoderCompatible

    @Test func videoFormatInfoIsCompatibleWithItself() {
        let format = Self.h264Main()
        #expect(format.isDecoderCompatible(with: format))
    }

    @Test func videoFormatInfoIsIncompatibleWhenTheCodecChanges() {
        var other = Self.h264Main()
        other.codec = .h265
        #expect(!Self.h264Main().isDecoderCompatible(with: other))
    }

    @Test func videoFormatInfoIsIncompatibleWhenTheCodedSizeChanges() {
        var wider = Self.h264Main()
        wider.geometry.codedWidth = 2_560
        #expect(!Self.h264Main().isDecoderCompatible(with: wider))

        var taller = Self.h264Main()
        taller.geometry.codedHeight = 1_440
        #expect(!Self.h264Main().isDecoderCompatible(with: taller))
    }

    @Test func videoFormatInfoIsIncompatibleWhenChromaFormatOrBitDepthChanges() {
        var chroma = Self.h264Main()
        chroma.chromaFormatIDC = 2
        #expect(!Self.h264Main().isDecoderCompatible(with: chroma))

        var depth = Self.h264Main()
        depth.geometry.bitDepth = 10
        #expect(!Self.h264Main().isDecoderCompatible(with: depth))
    }

    @Test func videoFormatInfoStaysCompatibleAcrossCropSARColourAndRateChanges() {
        // Everything in this test bumps the generation counter but keeps the decode session
        // (API_CONTRACT §3.6): a format change is codec, coded size, chroma or bit depth, nothing else.
        let base = Self.h264Main()

        var cropped = base
        cropped.geometry.cropHeight = 1_072
        cropped.geometry.cropTop = 8
        #expect(base.isDecoderCompatible(with: cropped))

        var stretched = base
        stretched.geometry.sarWidth = 4
        stretched.geometry.sarHeight = 3
        #expect(base.isDecoderCompatible(with: stretched))

        var recoloured = base
        recoloured.geometry.color = .bt601Video
        #expect(base.isDecoderCompatible(with: recoloured))

        var faster = base
        faster.frameRate = 30.0
        #expect(base.isDecoderCompatible(with: faster))

        var higherLevel = base
        higherLevel.levelIDC = 51
        higherLevel.levelName = "5.1"
        higherLevel.profileName = "High 10"
        #expect(base.isDecoderCompatible(with: higherLevel))
    }

    @Test func videoFormatInfoCompatibilityIsSymmetric() {
        var other = Self.h264Main()
        other.geometry.codedHeight = 1_080
        #expect(Self.h264Main().isDecoderCompatible(with: other)
                    == other.isDecoderCompatible(with: Self.h264Main()))
    }

    // MARK: - Value semantics

    @Test func videoFormatInfoRoundTripsThroughCodable() throws {
        let original = Self.h264Main()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VideoFormatInfo.self, from: encoded)
        #expect(decoded == original)
        #expect(decoded.frameRate == 25.0)
        #expect(decoded.profileName == "High")
    }

    @Test func videoFormatInfoEqualValuesHashEqually() {
        #expect(Self.h264Main() == Self.h264Main())
        #expect(Set([Self.h264Main(), Self.h264Main()]).count == 1)
    }
}
