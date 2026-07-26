//
//  FrameGeometryTests.swift
//  VigilProtocolsTests
//
//  Sizes, colour and the coded/cropped/displayed geometry: the 1920x1088-coded 1080p case, non-square
//  sample aspect ratios, the conformance-window crop, and the hostile values that must not trap.
//  Covers docs/API_CONTRACT.md §3.6.
//
//  The SAR values used below are the standard `aspect_ratio_idc` entries of ITU-T H.264 Table E-1
//  (12:11 for 4:3 PAL SD, 10:11 for 4:3 NTSC SD); the frame sizes are the ones Hikvision advertises.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct ResolutionTests {

    @Test func resolutionComputesPixelsAspectAndShortEdge() {
        let size = Resolution(width: 1_920, height: 1_080)
        #expect(size.pixels == 2_073_600)
        #expect(size.megapixels == 2.0736)
        #expect(size.aspect == 1_920.0 / 1_080.0)
        #expect(size.shortEdge == 1_080)
        #expect(Resolution(width: 1_080, height: 1_920).shortEdge == 1_080)
    }

    @Test func resolutionAspectIsZeroRatherThanInfiniteForZeroHeight() {
        #expect(Resolution(width: 1_920, height: 0).aspect == 0)
        #expect(Resolution(width: 0, height: 0).pixels == 0)
    }

    @Test func resolutionDescriptionUsesTheMultiplicationSign() {
        #expect(Resolution(width: 1_920, height: 1_080).description == "1920×1080")
    }

    @Test func resolutionOrdersByPixelCountThenWidth() {
        #expect(Resolution.hd720 < Resolution.hd1080)
        #expect(Resolution.hd1080 < Resolution.uhd4K)
        #expect(Resolution.cif < Resolution.d1)
        // Equal pixel counts fall back to width, so the order is total and deterministic.
        #expect(Resolution(width: 1_440, height: 1_080) < Resolution(width: 1_920, height: 810))
    }

    @Test func resolutionWellKnownSizesHaveTheExpectedDimensions() {
        #expect(Resolution.uhd4K == Resolution(width: 3_840, height: 2_160))
        #expect(Resolution.hd1080 == Resolution(width: 1_920, height: 1_080))
        #expect(Resolution.hd720 == Resolution(width: 1_280, height: 720))
        #expect(Resolution.d1 == Resolution(width: 704, height: 576))
        #expect(Resolution.cif == Resolution(width: 352, height: 288))
    }

    @Test func resolutionShortLabelNamesTheStandardSizes() {
        #expect(Resolution.uhd4K.shortLabel == "4K")
        #expect(Resolution.hd1080.shortLabel == "1080p")
        #expect(Resolution.hd720.shortLabel == "720p")
        #expect(Resolution.d1.shortLabel == "D1")
        #expect(Resolution.cif.shortLabel == "CIF")
        #expect(Resolution(width: 2_592, height: 1_944).shortLabel == "5MP")
    }

    @Test func resolutionShortLabelAbsorbsNearMissesWithinTheBand() {
        // The coded size of a 1080p H.264 stream, and the NTSC variants of D1 and CIF.
        #expect(Resolution(width: 1_920, height: 1_088).shortLabel == "1080p")
        #expect(Resolution(width: 2_560, height: 1_920).shortLabel == "5MP")
        #expect(Resolution(width: 704, height: 480).shortLabel == "D1")
        #expect(Resolution(width: 352, height: 240).shortLabel == "CIF")
        #expect(Resolution(width: 4_096, height: 2_160).shortLabel == "4K")
    }

    @Test func resolutionShortLabelFallsBackToDimensionsOutsideEveryBand() {
        #expect(Resolution(width: 2_048, height: 1_536).shortLabel == "2048×1536")   // 3 MP
        #expect(Resolution(width: 3_072, height: 2_048).shortLabel == "3072×2048")   // 6 MP
        #expect(Resolution(width: 0, height: 0).shortLabel == "0×0")
    }

    @Test func resolutionRoundTripsThroughCodable() throws {
        let encoded = try JSONEncoder().encode(Resolution.hd1080)
        #expect(try JSONDecoder().decode(Resolution.self, from: encoded) == .hd1080)
    }
}

@Suite struct ColorInfoTests {

    @Test func colorInfoDefaultsAreBT709VideoRange() {
        let color = ColorInfo.bt709Video
        #expect(color.matrix == .bt709)
        #expect(color.range == .video)
        #expect(color.transfer == .bt709)
        #expect(color.primaries == .bt709)
        #expect(color.chromaSiting == .left)
        #expect(!color.isHDR)
    }

    @Test func colorInfoStandardDefinitionDefaultIsBT601() {
        #expect(ColorInfo.bt601Video.matrix == .bt601)
        #expect(ColorInfo.bt601Video.transfer == .smpte170m)
        #expect(ColorInfo.bt601Video.primaries == .smpte170m)
        #expect(!ColorInfo.bt601Video.isHDR)
    }

    @Test func colorInfoIsHDROnlyForPQAndHLG() {
        for transfer in [ColorInfo.Transfer.pq, .hlg] {
            let color = ColorInfo(matrix: .bt2020ncl, range: .video, transfer: transfer,
                                  primaries: .bt2020, chromaSiting: .topLeft)
            #expect(color.isHDR)
        }
        for transfer in [ColorInfo.Transfer.bt709, .smpte170m, .srgb, .unspecified] {
            let color = ColorInfo(matrix: .bt709, range: .full, transfer: transfer,
                                  primaries: .bt709, chromaSiting: .left)
            #expect(!color.isHDR)
        }
    }

    @Test func colorInfoRoundTripsThroughCodable() throws {
        let encoded = try JSONEncoder().encode(ColorInfo.bt601Video)
        #expect(try JSONDecoder().decode(ColorInfo.self, from: encoded) == .bt601Video)
    }
}

@Suite struct FrameGeometryTests {

    @Test func frameGeometryReportsCodedAndDisplayedSizeSeparatelyFor1080p() {
        // The case the whole type exists for: H.264 1080p is coded 1920x1088 and shown 1920x1080.
        let geometry = FrameGeometry(codedWidth: 1_920, codedHeight: 1_088,
                                     cropWidth: 1_920, cropHeight: 1_080)
        #expect(geometry.codedSize == Resolution(width: 1_920, height: 1_088))
        #expect(geometry.croppedSize == Resolution.hd1080)
        #expect(geometry.displaySize == Resolution.hd1080)
        #expect(geometry.displaySize.height == 1_080, "never allocate-size height")
        #expect(geometry.pixelAspectRatio == 1.0)
        #expect(geometry.isProgressive)
    }

    @Test func frameGeometryAppliesTheConformanceWindowCrop() {
        // H.265 conformance window: 4 chroma samples off the bottom of a 4:2:0 frame is 8 luma
        // samples, which is exactly how 1088 becomes 1080 (ITU-T H.265 §7.4.3.2.1).
        let confWinBottomOffsetInChromaSamples = 4
        let subHeightC = 2
        let codedHeight = 1_088
        let cropHeight = codedHeight - confWinBottomOffsetInChromaSamples * subHeightC
        let geometry = FrameGeometry(codedWidth: 1_920, codedHeight: codedHeight,
                                     cropWidth: 1_920, cropHeight: cropHeight)
        #expect(geometry.croppedSize == Resolution.hd1080)
        #expect(geometry.codedSize.pixels > geometry.croppedSize.pixels)
    }

    @Test func frameGeometryCropOriginIsHonouredInSizeButNotInDisplaySize() {
        // An inset crop: the origin moves the aperture, the size is what the renderer draws.
        let geometry = FrameGeometry(codedWidth: 1_920, codedHeight: 1_088,
                                     cropLeft: 8, cropTop: 8,
                                     cropWidth: 1_904, cropHeight: 1_072)
        #expect(geometry.cropLeft == 8)
        #expect(geometry.cropTop == 8)
        #expect(geometry.croppedSize == Resolution(width: 1_904, height: 1_072))
        #expect(geometry.displaySize == Resolution(width: 1_904, height: 1_072))
    }

    @Test func frameGeometryCorrectsForNonSquarePixels() {
        // PAL SD, aspect_ratio_idc 2 -> 12:11. 704 x 12/11 = 768 exactly, giving a 4:3 picture.
        let pal = FrameGeometry(codedWidth: 704, codedHeight: 576,
                                cropWidth: 704, cropHeight: 576,
                                sarWidth: 12, sarHeight: 11)
        #expect(pal.pixelAspectRatio == 12.0 / 11.0)
        #expect(pal.displaySize == Resolution(width: 768, height: 576))
        #expect(pal.displayAspect == 768.0 / 576.0)

        // NTSC SD, aspect_ratio_idc 3 -> 10:11. 720 x 10/11 = 654.54..., which rounds to 655.
        let ntsc = FrameGeometry(codedWidth: 720, codedHeight: 480,
                                 cropWidth: 720, cropHeight: 480,
                                 sarWidth: 10, sarHeight: 11)
        #expect(ntsc.displaySize == Resolution(width: 655, height: 480))
    }

    @Test func frameGeometryAnamorphicWideScreenStretchesRatherThanCrops() {
        // 1280x1080 with a 3:2 SAR is a 1920x1080 picture: the crop is untouched, the width grows.
        let geometry = FrameGeometry(codedWidth: 1_280, codedHeight: 1_088,
                                     cropWidth: 1_280, cropHeight: 1_080,
                                     sarWidth: 3, sarHeight: 2)
        #expect(geometry.croppedSize == Resolution(width: 1_280, height: 1_080))
        #expect(geometry.displaySize == Resolution.hd1080)
        #expect(geometry.displayAspect == 1_920.0 / 1_080.0)
    }

    @Test func frameGeometryTreatsUnspecifiedSampleAspectRatioAsSquare() {
        // `sar_height == 0` is expressible in a VUI; an infinite ratio would trap the Int conversion.
        for (w, h) in [(0, 0), (1, 0), (0, 1), (-4, 3), (4, -3)] {
            let geometry = FrameGeometry(codedWidth: 1_920, codedHeight: 1_088,
                                         cropWidth: 1_920, cropHeight: 1_080,
                                         sarWidth: w, sarHeight: h)
            #expect(geometry.pixelAspectRatio == 1.0)
            #expect(geometry.displaySize == Resolution.hd1080)
            #expect(geometry.displayAspect == 1_920.0 / 1_080.0)
        }
    }

    @Test func frameGeometryClampsAnAbsurdlyStretchedDisplayWidth() {
        // A hostile SAR on a huge crop must clamp, not trap on the Double-to-Int conversion.
        let geometry = FrameGeometry(codedWidth: 1_000_000_000, codedHeight: 1_000,
                                     cropWidth: 1_000_000_000, cropHeight: 1_000,
                                     sarWidth: 1_000, sarHeight: 1)
        #expect(geometry.displaySize.width == 1_073_741_824)
        #expect(geometry.displaySize.height == 1_000)
    }

    @Test func frameGeometryDisplayAspectIsZeroForAZeroHeightCrop() {
        let geometry = FrameGeometry(codedWidth: 1_920, codedHeight: 1_088,
                                     cropWidth: 1_920, cropHeight: 0)
        #expect(geometry.displayAspect == 0)
        #expect(geometry.displaySize == Resolution(width: 1_920, height: 0))
    }

    @Test func frameGeometryDefaultsAreProgressiveEightBitBT709() {
        let geometry = FrameGeometry(codedWidth: 1_920, codedHeight: 1_088,
                                     cropWidth: 1_920, cropHeight: 1_080)
        #expect(geometry.cropLeft == 0)
        #expect(geometry.cropTop == 0)
        #expect(geometry.sarWidth == 1)
        #expect(geometry.sarHeight == 1)
        #expect(geometry.bitDepth == 8)
        #expect(geometry.fieldOrder == .progressive)
        #expect(geometry.color == .bt709Video)
    }

    @Test func frameGeometryInterlacedFieldOrderIsNotProgressive() {
        let geometry = FrameGeometry(codedWidth: 704, codedHeight: 576,
                                     cropWidth: 704, cropHeight: 576,
                                     fieldOrder: .topFieldFirst)
        #expect(!geometry.isProgressive)
        #expect(FrameGeometry(codedWidth: 704, codedHeight: 576, cropWidth: 704, cropHeight: 576,
                              fieldOrder: .bottomFieldFirst).isProgressive == false)
    }

    @Test func frameGeometryStoresHostileValuesVerbatimForTheParserToReport() {
        // A bit depth outside 8...12 is a parse error the SPS parser raises; this type stores it.
        let geometry = FrameGeometry(codedWidth: 16, codedHeight: 16,
                                     cropWidth: 16, cropHeight: 16, bitDepth: 99)
        #expect(geometry.bitDepth == 99)
    }

    @Test func frameGeometryRoundTripsThroughCodable() throws {
        let original = FrameGeometry(codedWidth: 1_920, codedHeight: 1_088,
                                     cropLeft: 0, cropTop: 0, cropWidth: 1_920, cropHeight: 1_080,
                                     sarWidth: 12, sarHeight: 11, bitDepth: 10,
                                     fieldOrder: .topFieldFirst, color: .bt601Video)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FrameGeometry.self, from: encoded)
        #expect(decoded == original)
        #expect(decoded.displaySize == original.displaySize)
    }
}
