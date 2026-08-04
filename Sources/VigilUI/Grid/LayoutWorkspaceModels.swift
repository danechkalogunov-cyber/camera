//
//  LayoutWorkspaceModels.swift
//  VigilUI
//
//  Layout presets, mosaic editing, zoom, wall, and patrol policies.
//

#if os(macOS)

    import CoreGraphics
    import Foundation

    /// A user-named, serialisable stage arrangement. Camera identifiers are strings deliberately: the
    /// UI package does not depend on VigilCore, while the library document can persist this value as JSON.
    package struct VLayoutPreset: Codable, Sendable, Hashable, Identifiable {
        package let id: UUID
        package var name: String
        package var layout: VGridLayout
        package var cameraIDs: [String]

        package init(id: UUID = UUID(), name: String, layout: VGridLayout, cameraIDs: [String]) {
            self.id = id
            self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.layout = layout
            self.cameraIDs = Array(cameraIDs.prefix(layout.tileCount))
        }
    }

    /// Ordered preset collection used by Save/Manage and by ⌘9 (the first element).
    package struct VLayoutPresetCollection: Codable, Sendable, Hashable {
        package private(set) var presets: [VLayoutPreset]

        package init(_ presets: [VLayoutPreset] = []) { self.presets = presets }

        package mutating func save(_ preset: VLayoutPreset) {
            guard !preset.name.isEmpty else { return }
            if let index = presets.firstIndex(where: { $0.id == preset.id }) {
                presets[index] = preset
            } else {
                presets.append(preset)
            }
        }

        package mutating func move(from source: Int, to destination: Int) {
            guard presets.indices.contains(source), (0...presets.count).contains(destination) else { return }
            let value = presets.remove(at: source)
            presets.insert(
                value, at: min(destination > source ? destination - 1 : destination, presets.count))
        }
    }

    /// Validates custom mosaic edits in the canonical 12×12 coordinate space.
    package struct VMosaicEditor: Sendable, Hashable {
        package static let units = 12
        package static let snapDistance = 0.4
        package private(set) var tiles: [VLayoutRect]

        package init(tiles: [VLayoutRect]) { self.tiles = tiles }

        /// Applies a move/resize only when it remains in bounds and does not overlap another tile.
        @discardableResult
        package mutating func replaceTile(at index: Int, with proposed: VLayoutRect) -> Bool {
            guard tiles.indices.contains(index) else { return false }
            let snapped = snap(proposed)
            guard snapped.x >= 0, snapped.y >= 0, snapped.w > 0, snapped.h > 0,
                snapped.x + snapped.w <= Self.units, snapped.y + snapped.h <= Self.units,
                !tiles.enumerated().contains(where: { $0.offset != index && overlaps($0.element, snapped) })
            else { return false }
            tiles[index] = snapped
            return true
        }

        private func snap(_ rect: VLayoutRect) -> VLayoutRect {
            func edge(_ value: Int) -> Int { min(Self.units, max(0, value)) }
            // VLayoutRect is integral; dragging UI rounds to the nearest grid edge once inside 0.4 unit.
            return VLayoutRect(x: edge(rect.x), y: edge(rect.y), w: rect.w, h: rect.h)
        }

        private func overlaps(_ a: VLayoutRect, _ b: VLayoutRect) -> Bool {
            a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
        }
    }

    /// Renderer-independent digital zoom policy used by ⌘=/⌘-/⌘0 and drag-to-pan.
    package struct VDigitalViewport: Sendable, Hashable {
        package private(set) var scale: CGFloat = 1
        package private(set) var offset: CGSize = .zero
        package static let maximumScale: CGFloat = 8

        package mutating func zoom(by factor: CGFloat) {
            guard factor.isFinite, factor > 0 else { return }
            scale = min(Self.maximumScale, max(1, scale * factor))
            if scale == 1 { offset = .zero } else { offset = clamped(offset) }
        }

        package mutating func pan(by translation: CGSize) {
            guard scale > 1 else { return }
            offset = clamped(
                CGSize(
                    width: offset.width + translation.width,
                    height: offset.height + translation.height))
        }

        package mutating func reset() {
            scale = 1
            offset = .zero
        }

        private func clamped(_ value: CGSize) -> CGSize {
            let limit = (scale - 1) / (2 * scale)
            return CGSize(
                width: min(limit, max(-limit, value.width)),
                height: min(limit, max(-limit, value.height)))
        }
    }

    /// Independent second-display workspace. Wall demand sorts before ordinary live demand.
    package struct VVideoWallConfiguration: Codable, Sendable, Hashable {
        package var screenID: String?
        package var layout: VGridLayout
        package var patrolInterval: TimeInterval
        package var isPatrolling: Bool

        package init(
            screenID: String? = nil, layout: VGridLayout = .grid4x4,
            patrolInterval: TimeInterval = VCycleModel.defaultInterval,
            isPatrolling: Bool = false
        ) {
            self.screenID = screenID
            self.layout = layout
            self.patrolInterval = VCycleModel.clamp(patrolInterval)
            self.isPatrolling = isPatrolling
        }

        package static func decoderPriority(isWall: Bool) -> Int { isWall ? 0 : 1 }
    }

    /// Normalised ring fill for the toolbar patrol icon.
    package enum VCycleProgress {
        package static func fraction(elapsed: TimeInterval, interval: TimeInterval) -> Double {
            guard elapsed.isFinite, interval.isFinite, interval > 0 else { return 0 }
            return min(1, max(0, elapsed / interval))
        }
    }

#endif
