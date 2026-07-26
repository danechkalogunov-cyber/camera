//
//  TilePolicyTests.swift
//  VigilProtocolsTests
//
//  The class A–E table and its hysteresis. Covers docs/API_CONTRACT.md §2.2 (ruling R-21)
//  and §3.7. Every threshold here is quoted from R-21's table, not chosen here.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct TilePolicyTests {

    /// A visible stage tile whose backing short edge is `edge`. 16:9, so the short edge is the
    /// height — which is the point of measuring the short edge and not the width.
    private func tile(shortEdge edge: Int) -> TileContext {
        TileContext(pixelSize: Resolution(width: edge * 16 / 9, height: edge))
    }

    // MARK: - The class table, at its exact boundaries

    @Test func tileClassBoundariesMatchTheContractTable() {
        // Class A: ≥ 1080.
        #expect(TilePolicy.tileClass(for: tile(shortEdge: 4320)) == .a)
        #expect(TilePolicy.tileClass(for: tile(shortEdge: 1080)) == .a)
        // Class B: 480–1079.
        #expect(TilePolicy.tileClass(for: tile(shortEdge: 1079)) == .b)
        #expect(TilePolicy.tileClass(for: tile(shortEdge: 480)) == .b)
        // Class C: 96–479.
        #expect(TilePolicy.tileClass(for: tile(shortEdge: 479)) == .c)
        #expect(TilePolicy.tileClass(for: tile(shortEdge: 96)) == .c)
        // Class D: 1–95.
        #expect(TilePolicy.tileClass(for: tile(shortEdge: 95)) == .d)
        #expect(TilePolicy.tileClass(for: tile(shortEdge: 1)) == .d)
        // Nothing to show at all.
        #expect(TilePolicy.tileClass(for: tile(shortEdge: 0)) == .e)
    }

    @Test func tileClassUsesTheShortEdgeNotTheWidth() {
        // A 1920×135 letterbox strip and a 480×540 cell have almost the same pixel count and need
        // opposite decisions — that is why the unit is the short edge (R-21).
        let strip = TileContext(pixelSize: Resolution(width: 1920, height: 135))
        let cell = TileContext(pixelSize: Resolution(width: 480, height: 540))
        #expect(TilePolicy.tileClass(for: strip) == .c)
        #expect(TilePolicy.tileClass(for: cell) == .b)
    }

    @Test func tileClassIsEWhenHiddenOrOccluded() {
        var hidden = tile(shortEdge: 1920)
        hidden.isVisible = false
        #expect(TilePolicy.tileClass(for: hidden) == .e)

        var occluded = tile(shortEdge: 1920)
        occluded.isOccluded = true
        #expect(TilePolicy.tileClass(for: occluded) == .e)
    }

    @Test func recordingTilesAreExemptFromOcclusionPausing() {
        // F-DEC-06 rule 5: a recording is never demoted and never occlusion-paused.
        var recording = tile(shortEdge: 96)
        recording.isRecording = true
        recording.isVisible = false
        recording.isOccluded = true
        #expect(TilePolicy.tileClass(for: recording) == .a)
        #expect(TilePolicy.choice(for: recording) == .stream(.main))
    }

    @Test func sidebarAndOffscreenSurfacesArePollingSurfaces() {
        var sidebar = tile(shortEdge: 200)
        sidebar.isSidebarThumbnail = true
        #expect(TilePolicy.tileClass(for: sidebar) == .d)

        var offscreen = tile(shortEdge: 600)
        offscreen.isOffscreenScroll = true
        #expect(TilePolicy.tileClass(for: offscreen) == .d)
    }

    @Test func focusDoesNotChangeTheSizeClass() {
        // Focus is an admission-priority input, not a size input: a focused 300 px tile still
        // wants the sub stream.
        var focused = tile(shortEdge: 300)
        focused.isFocused = true
        #expect(TilePolicy.tileClass(for: focused) == .c)
        #expect(TilePolicy.choice(for: focused) == .stream(.sub))
    }

    @Test func tileClassOrdersLargestFirst() {
        #expect(TileClass.a < TileClass.b)
        #expect(TileClass.b < TileClass.c)
        #expect(TileClass.c < TileClass.d)
        #expect(TileClass.d < TileClass.e)
        #expect(TileClass.allCases.count == 5)
    }

    // MARK: - Which stream each class pulls

    @Test func classAPullsMainAndClassCPullsSub() {
        #expect(TilePolicy.choice(for: tile(shortEdge: 1080)) == .stream(.main))
        #expect(TilePolicy.choice(for: tile(shortEdge: 300)) == .stream(.sub))
    }

    @Test func classBPromotesWhenSubIsSofterThanTile() {
        // 0.75 × 800 = 600 lines. A 360-line sub in an 800 px tile is visibly soft: promote.
        var soft = tile(shortEdge: 800)
        soft.subStreamHeight = 360
        #expect(TilePolicy.choice(for: soft) == .stream(.main))

        // A 720-line sub in the same tile is sharp enough: stay on sub.
        var sharp = tile(shortEdge: 800)
        sharp.subStreamHeight = 720
        #expect(TilePolicy.choice(for: sharp) == .stream(.sub))
    }

    @Test func classBDoesNotPromoteOnAnUnknownSubHeight() {
        let unknown = tile(shortEdge: 800)
        #expect(unknown.subStreamHeight == nil)
        #expect(TilePolicy.choice(for: unknown) == .stream(.sub))
    }

    @Test func classBPromotionSitsExactlyOnTheSoftnessRatio() {
        var atRatio = tile(shortEdge: 800)
        atRatio.subStreamHeight = 600            // exactly 0.75 × 800, not *below* it
        #expect(TilePolicy.choice(for: atRatio) == .stream(.sub))
        atRatio.subStreamHeight = 599
        #expect(TilePolicy.choice(for: atRatio) == .stream(.main))
    }

    @Test func aDeviceWithoutASubStreamAlwaysGetsMain() {
        for edge in [800, 300] {
            var analog = tile(shortEdge: edge)
            analog.deviceSupportsSubStream = false
            #expect(TilePolicy.choice(for: analog) == .stream(.main), "short edge \(edge)")
        }
    }

    @Test func classDPollsJPEGAndClassEPullsNothing() {
        #expect(TilePolicy.choice(for: tile(shortEdge: 50)) == .jpegPoll(interval: .seconds(1)))
        var hidden = tile(shortEdge: 1080)
        hidden.isVisible = false
        #expect(TilePolicy.choice(for: hidden) == .none)
    }

    @Test func aQualityLockOverridesTheTableButNotVisibility() {
        var locked = tile(shortEdge: 300)
        locked.qualityOverride = .main
        #expect(TilePolicy.choice(for: locked) == .stream(.main))

        var lockedThumbnail = tile(shortEdge: 50)
        lockedThumbnail.qualityOverride = .sub
        #expect(TilePolicy.choice(for: lockedThumbnail) == .stream(.sub))

        var lockedAndHidden = tile(shortEdge: 300)
        lockedAndHidden.qualityOverride = .main
        lockedAndHidden.isVisible = false
        #expect(TilePolicy.choice(for: lockedAndHidden) == .none)
    }

    // MARK: - Hysteresis

    @Test func deadBandRequiresFifteenPercentPastTheBoundaryWhenGrowing() {
        // 480 × 1.15 = 552.
        #expect(!TilePolicy.clearsDeadBand(current: .c, proposed: .b, shortEdge: 480))
        #expect(!TilePolicy.clearsDeadBand(current: .c, proposed: .b, shortEdge: 551))
        #expect(TilePolicy.clearsDeadBand(current: .c, proposed: .b, shortEdge: 552))
        // 1080 × 1.15 = 1242.
        #expect(!TilePolicy.clearsDeadBand(current: .b, proposed: .a, shortEdge: 1241))
        #expect(TilePolicy.clearsDeadBand(current: .b, proposed: .a, shortEdge: 1242))
    }

    @Test func deadBandRequiresFifteenPercentPastTheBoundaryWhenShrinking() {
        // 480 × 0.85 = 408.
        #expect(!TilePolicy.clearsDeadBand(current: .b, proposed: .c, shortEdge: 479))
        #expect(!TilePolicy.clearsDeadBand(current: .b, proposed: .c, shortEdge: 409))
        #expect(TilePolicy.clearsDeadBand(current: .b, proposed: .c, shortEdge: 408))
        // 1080 × 0.85 = 918.
        #expect(!TilePolicy.clearsDeadBand(current: .a, proposed: .b, shortEdge: 919))
        #expect(TilePolicy.clearsDeadBand(current: .a, proposed: .b, shortEdge: 918))
    }

    @Test func deadBandNeverFiresForAClassThatIsNotChanging() {
        for tileClass in TileClass.allCases {
            #expect(!TilePolicy.clearsDeadBand(current: tileClass, proposed: tileClass,
                                               shortEdge: 900))
        }
    }

    @Test func visibilityChangesBypassTheDeadBand() {
        // Class E is a boolean state, not a size band: the 750 ms dwell damps it, not the 15 %.
        #expect(TilePolicy.clearsDeadBand(current: .b, proposed: .e, shortEdge: 500))
        #expect(TilePolicy.clearsDeadBand(current: .e, proposed: .b, shortEdge: 500))
    }

    @Test func aTileOscillatingAroundABoundaryNeverFlaps() {
        // A window nudged back and forth across 480 px. Not one switch is permitted.
        var current = TileClass.c
        var switches = 0
        for edge in [470, 490, 475, 500, 460, 505, 481, 479, 520, 470] {
            let proposed = TilePolicy.tileClass(for: tile(shortEdge: edge))
            if proposed != current,
               TilePolicy.clearsDeadBand(current: current, proposed: proposed, shortEdge: edge) {
                current = proposed
                switches += 1
            }
        }
        #expect(switches == 0, "a tile wobbling across 480 px switched \(switches) times")
        #expect(current == .c)
    }

    @Test func aContinuousDragFromFourByFourToOneUpSwitchesAtMostOnce() {
        // The mandatory test from R-21: 60 frames of a resize animation, monotonic, 400 → 700 px.
        var current = TileClass.c
        var switches = 0
        for frame in 0..<60 {
            let edge = 400 + (300 * frame) / 59
            let proposed = TilePolicy.tileClass(for: tile(shortEdge: edge))
            if proposed != current,
               TilePolicy.clearsDeadBand(current: current, proposed: proposed, shortEdge: edge) {
                current = proposed
                switches += 1
            }
        }
        #expect(switches == 1, "a monotonic drag produced \(switches) switches")
        #expect(current == .b)
    }

    @Test func aDragThatStopsInsideTheDeadBandChangesNothing() {
        var current = TileClass.c
        var switches = 0
        for frame in 0..<60 {
            let edge = 400 + (140 * frame) / 59      // 400 → 540, short of 552
            let proposed = TilePolicy.tileClass(for: tile(shortEdge: edge))
            if proposed != current,
               TilePolicy.clearsDeadBand(current: current, proposed: proposed, shortEdge: edge) {
                current = proposed
                switches += 1
            }
        }
        #expect(switches == 0)
        #expect(current == .c)
    }

    @Test func theHysteresisConstantsAreTheOnesTheContractStates() {
        #expect(TilePolicy.dwell == .milliseconds(750))
        #expect(TilePolicy.deadBand == 0.15)
        #expect(TilePolicy.classAFloor == 1080)
        #expect(TilePolicy.classBFloor == 480)
        #expect(TilePolicy.classCFloor == 96)
        #expect(TilePolicy.promotionSoftnessRatio == 0.75)
    }

    // MARK: - JPEG cadence

    @Test func jpegCadenceMatchesTheSurfaceTable() {
        #expect(TilePolicy.jpegInterval(for: tile(shortEdge: 50), pollingSurfaces: 1)
            == .seconds(1))

        var sidebar = tile(shortEdge: 50)
        sidebar.isSidebarThumbnail = true
        #expect(TilePolicy.jpegInterval(for: sidebar, pollingSurfaces: 1) == .seconds(5))

        var offscreen = tile(shortEdge: 50)
        offscreen.isOffscreenScroll = true
        #expect(TilePolicy.jpegInterval(for: offscreen, pollingSurfaces: 1) == .seconds(15))

        var hidden = tile(shortEdge: 50)
        hidden.isVisible = false
        #expect(TilePolicy.jpegInterval(for: hidden, pollingSurfaces: 1) == .seconds(15))
    }

    @Test func jpegCadenceScalesSoADeviceNeverSeesMoreThanOneRequestPerSecond() {
        #expect(TilePolicy.jpegInterval(for: tile(shortEdge: 50), pollingSurfaces: 8)
            == .seconds(8))
        // A slower surface is not sped up by the scaling rule.
        var sidebar = tile(shortEdge: 50)
        sidebar.isSidebarThumbnail = true
        #expect(TilePolicy.jpegInterval(for: sidebar, pollingSurfaces: 3) == .seconds(5))
        #expect(TilePolicy.jpegInterval(for: sidebar, pollingSurfaces: 9) == .seconds(9))
    }

    @Test func jpegCadenceTreatsAnImpossibleSurfaceCountAsOne() {
        #expect(TilePolicy.jpegInterval(for: tile(shortEdge: 50), pollingSurfaces: 0)
            == .seconds(1))
        #expect(TilePolicy.jpegInterval(for: tile(shortEdge: 50), pollingSurfaces: -4)
            == .seconds(1))
    }

    @Test func jpegCadenceHonoursAUserOverride() {
        var overridden = tile(shortEdge: 50)
        overridden.jpegPollIntervalOverride = .seconds(30)
        #expect(TilePolicy.jpegInterval(for: overridden, pollingSurfaces: 64) == .seconds(30))
        #expect(TilePolicy.choice(for: overridden) == .jpegPoll(interval: .seconds(30)))
    }
}
