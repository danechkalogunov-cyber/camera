#if os(macOS)
    import CoreGraphics
    import Testing
    @testable import VigilUI

    @Suite("Layout workspace models")
    struct LayoutWorkspaceModelsTests {
        @Test func presetsTrimNamesLimitAssignmentsAndReorder() {
            var collection = VLayoutPresetCollection()
            let first = VLayoutPreset(
                name: "  Entrance  ", layout: .grid2x2,
                cameraIDs: ["1", "2", "3", "4", "5"])
            let second = VLayoutPreset(name: "Warehouse", layout: .single, cameraIDs: ["9"])
            collection.save(first)
            collection.save(second)
            #expect(collection.presets[0].name == "Entrance")
            #expect(collection.presets[0].cameraIDs.count == 4)
            collection.move(from: 1, to: 0)
            #expect(collection.presets.map(\.name) == ["Warehouse", "Entrance"])
            collection.remove(first.id)
            #expect(collection.presets.map(\.name) == ["Warehouse"])
        }

        @Test func mosaicRejectsOverlapAndOutOfBounds() {
            var editor = VMosaicEditor(tiles: [
                VLayoutRect(x: 0, y: 0, w: 6, h: 6),
                VLayoutRect(x: 6, y: 0, w: 6, h: 6),
            ])
            let overlap = editor.replaceTile(at: 1, with: VLayoutRect(x: 5, y: 0, w: 6, h: 6))
        #expect(!overlap)
            let outOfBounds = editor.replaceTile(at: 1, with: VLayoutRect(x: 7, y: 0, w: 6, h: 6))
        #expect(!outOfBounds)
            let accepted = editor.replaceTile(at: 1, with: VLayoutRect(x: 6, y: 6, w: 6, h: 6))
        #expect(accepted)
        }

        @Test func viewportClampsAndResetRestoresIdentity() {
            var viewport = VDigitalViewport()
            viewport.pan(by: CGSize(width: 1, height: 1))
            #expect(viewport.offset == .zero)
            viewport.zoom(by: 100)
            viewport.pan(by: CGSize(width: 100, height: -100))
            #expect(viewport.scale == 8)
            #expect(abs(viewport.offset.width) <= 0.4375)
            let beforeDrag = viewport.offset
            viewport.panGesture(to: CGSize(width: -0.1, height: 0.1))
            viewport.panGesture(to: CGSize(width: -0.2, height: 0.2))
            #expect(viewport.offset.width < beforeDrag.width)
            viewport.endPanGesture()
            viewport.reset()
            #expect(viewport == VDigitalViewport())
        }

        @Test func wallHasIndependentLayoutAndHighestDecoderPriority() {
            let wall = VVideoWallConfiguration(
                screenID: "display-2", layout: .mosaic4x3,
                patrolInterval: 15, isPatrolling: true)
            #expect(wall.layout == .mosaic4x3)
            #expect(wall.patrolInterval == 15)
            #expect(
                VVideoWallConfiguration.decoderPriority(isWall: true)
                    < VVideoWallConfiguration.decoderPriority(isWall: false))
        }

        @Test func cycleProgressIsNormalised() {
            #expect(VCycleProgress.fraction(elapsed: -1, interval: 10) == 0)
            #expect(VCycleProgress.fraction(elapsed: 5, interval: 10) == 0.5)
            #expect(VCycleProgress.fraction(elapsed: 20, interval: 10) == 1)
        }
    }
#endif
