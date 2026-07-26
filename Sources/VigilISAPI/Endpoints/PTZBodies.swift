//
//  PTZBodies.swift
//  VigilISAPI
//
//  The PTZ command value types and the exact `<PTZData>` bodies they serialise to, kept separate
//  from the controller so every body can be asserted byte-for-byte without an actor or a network.
//  Implements docs/spec-isapi.md §13.1–§13.5 and §13.8.
//
//  Element **order** is part of the wire format here, not a style choice: 5.2.x validators reject a
//  reordered `<PTZData>`, and all three of `pan`, `tilt` and `zoom` must be present even when they
//  are zero. `XMLBuilder` preserves insertion order, which is why the bodies are built with it and
//  never from a dictionary.
//

import Foundation
import VigilProtocols

// MARK: - PTZVelocity

/// A continuous-motion command: percentages of maximum speed on each axis.
///
/// Sign conventions, from docs/spec-isapi.md §13.1: `pan` positive is **right** (clockwise),
/// `tilt` positive is **up**, `zoom` positive is **tele** (in).
public struct PTZVelocity: Sendable, Hashable, Codable {
    /// −100…100. Values outside the range are clamped by the initialiser, never sent.
    public let pan: Int
    public let tilt: Int
    public let zoom: Int

    /// Clamps every axis into −100…100.
    ///
    /// Clamping rather than rejecting is deliberate: a UI that computes 104 from a drag must still
    /// move the camera, and out-of-range values have been observed to make firmware ignore the
    /// *next* valid command as well.
    public init(pan: Int, tilt: Int, zoom: Int) {
        func clamp(_ value: Int) -> Int { min(100, max(-100, value)) }
        self.pan = clamp(pan)
        self.tilt = clamp(tilt)
        self.zoom = clamp(zoom)
    }

    /// The all-zero triple that stops the camera.
    public static let stopped = PTZVelocity(pan: 0, tilt: 0, zoom: 0)

    public var isStopped: Bool { pan == 0 && tilt == 0 && zoom == 0 }

    /// Scales a normalised direction by a 1…10 UI speed setting.
    ///
    /// Diagonals are deliberately **not** normalised to unit length: Hikvision treats pan and tilt
    /// speed independently, and users expect a diagonal drag to move at full speed on both axes.
    public static func from(directionX: Double, directionY: Double, zoom: Double,
                            speed: Int) -> PTZVelocity {
        let scale = Double(min(10, max(1, speed))) * 10.0
        func axis(_ value: Double) -> Int { Int((value * scale).rounded()) }
        return PTZVelocity(pan: axis(directionX), tilt: axis(directionY), zoom: axis(zoom))
    }

    /// `<PTZData><pan>…</pan><tilt>…</tilt><zoom>…</zoom></PTZData>`, in that order.
    public var body: XMLBuilder {
        var builder = XMLBuilder("PTZData")
        builder.add("pan", pan)
        builder.add("tilt", tilt)
        builder.add("zoom", zoom)
        return builder
    }

    /// The momentary form: the same triple plus `<Momentary><duration>` in **milliseconds**.
    ///
    /// `duration` is clamped to 0…60000; the practical range is 50…2000, and Vigil uses 300 ms for
    /// a key tap and 120 ms for a shift-key fine nudge.
    public func momentaryBody(durationMilliseconds: Int) -> XMLBuilder {
        var builder = body
        let clamped = min(60000, max(0, durationMilliseconds))
        builder.addChild("Momentary") { momentary in
            momentary.add("duration", clamped)
        }
        return builder
    }
}

// MARK: - PTZAbsolutePosition

/// An absolute pan/tilt/zoom target, in degrees at the API and in device units on the wire.
public struct PTZAbsolutePosition: Sendable, Hashable, Codable {
    /// 0…360, increasing clockwise from the device's zero reference.
    public var azimuthDegrees: Double
    /// −90…270. Most domes use −90…90; ceiling-mount models report 0…270.
    public var elevationDegrees: Double
    /// 1…1000 wire zoom steps; 10 is roughly 1× wide.
    public var zoomSteps: Int

    public init(azimuthDegrees: Double, elevationDegrees: Double, zoomSteps: Int) {
        self.azimuthDegrees = azimuthDegrees
        self.elevationDegrees = elevationDegrees
        self.zoomSteps = zoomSteps
    }

    /// Builds a position from the wire units the device reports in `<AbsoluteHigh>`.
    public init(wireAzimuth: Int, wireElevation: Int, wireZoom: Int) {
        self.init(azimuthDegrees: Double(wireAzimuth) / 10.0,
                  elevationDegrees: Double(wireElevation) / 10.0,
                  zoomSteps: wireZoom)
    }

    /// Azimuth in the wire's tenths of a degree.
    public var wireAzimuth: Int { Int((azimuthDegrees * 10).rounded()) }
    /// Elevation in the wire's tenths of a degree.
    public var wireElevation: Int { Int((elevationDegrees * 10).rounded()) }

    /// `<PTZData><AbsoluteHigh><elevation/><azimuth/><absoluteZoom/></AbsoluteHigh></PTZData>`.
    ///
    /// Ranges come from `/PTZCtrl/channels/{ch}/capabilities` and are applied here rather than by
    /// the device: firmware has been seen to answer `deviceError` for an out-of-range value and
    /// then ignore the next valid command too.
    public func body(clampedTo capabilities: PTZCapabilitiesWire?) -> XMLBuilder {
        let azimuthRange = capabilities?.azimuthRange ?? 0...3600
        let elevationRange = capabilities?.elevationRange ?? -900...2700
        let zoomRange = capabilities?.zoomRange ?? 1...1000
        func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
            min(range.upperBound, max(range.lowerBound, value))
        }
        var builder = XMLBuilder("PTZData")
        builder.addChild("AbsoluteHigh") { high in
            high.add("elevation", clamp(wireElevation, elevationRange))
            high.add("azimuth", clamp(wireAzimuth, azimuthRange))
            high.add("absoluteZoom", clamp(zoomSteps, zoomRange))
        }
        return builder
    }
}

// MARK: - PTZRelativeMove

/// A relative move in device steps. Used for trackpad-scroll pan and for recentre-on-double-click
/// when `position3D` is unsupported.
public struct PTZRelativeMove: Sendable, Hashable, Codable {
    /// −255…255, clamped by the initialiser.
    public let positionX: Int
    /// −255…255. Positive is **up**.
    public let positionY: Int
    /// −255…255.
    public let relativeZoom: Int

    public init(positionX: Int, positionY: Int, relativeZoom: Int) {
        func clamp(_ value: Int) -> Int { min(255, max(-255, value)) }
        self.positionX = clamp(positionX)
        self.positionY = clamp(positionY)
        self.relativeZoom = clamp(relativeZoom)
    }

    /// `<PTZData><Relative><positionX/><positionY/><relativeZoom/></Relative></PTZData>`.
    public var body: XMLBuilder {
        var builder = XMLBuilder("PTZData")
        builder.addChild("Relative") { relative in
            relative.add("positionX", positionX)
            relative.add("positionY", positionY)
            relative.add("relativeZoom", relativeZoom)
        }
        return builder
    }
}

// MARK: - PTZ3D

/// A drag-to-zoom rectangle in the device's 0…255 image space.
///
/// The coordinate space is the part everyone gets wrong: `positionX` runs 0 at the left edge to
/// 255 at the right, and `positionY` runs **0 at the bottom edge to 255 at the top** — the origin
/// is lower-left, the opposite of every UI framework. A minority of firmwares (some DS-2DE4xxx
/// builds) use an upper-left origin instead, which is why every conversion takes the flag
/// explicitly rather than reading a global (docs/spec-isapi.md §13.5).
public struct PTZ3D: Sendable, Hashable, Codable {
    /// All four are 0…255, clamped by the initialiser.
    public let startX: Int
    public let startY: Int
    public let endX: Int
    public let endY: Int

    public init(startX: Int, startY: Int, endX: Int, endY: Int) {
        func clamp(_ value: Int) -> Int { min(255, max(0, value)) }
        self.startX = clamp(startX)
        self.startY = clamp(startY)
        self.endX = clamp(endX)
        self.endY = clamp(endY)
    }

    /// True for a click-to-centre rather than a zoom-to-box: the device centres on the point at
    /// the current zoom when start and end coincide.
    public var isPoint: Bool { startX == endX && startY == endY }

    /// The minimum drag, in view points, that counts as a box rather than a click.
    public static let minimumDragPoints: Double = 12

    /// Converts a rectangle in **top-left-origin view coordinates** into the device's space.
    ///
    /// The caller must already have mapped the drag from the view's coordinates onto the video's
    /// letterboxed content rect: with digital zoom or pillarboxing applied, view coordinates are
    /// not image coordinates, and `VigilRender` exposes `contentRect` for exactly this.
    ///
    /// `StartPoint` is the rectangle's top-left corner and `EndPoint` its bottom-right, matching
    /// the sample in docs/spec-isapi.md §13.5 where the start's Y (180) is *above* the end's (60).
    /// Drag direction is irrelevant to the device; only the rectangle matters.
    ///
    /// - Parameters:
    ///   - rect: the drag rectangle, in the same coordinate space as `viewSize`, top-left origin.
    ///   - viewSize: the size of the video content area. A non-positive dimension yields a
    ///     centred point rather than a division by zero.
    ///   - originIsTopLeft: `true` only for firmware whose `positionY` grows downwards.
    public static func box(rectX: Double, rectY: Double, rectWidth: Double, rectHeight: Double,
                           viewWidth: Double, viewHeight: Double,
                           originIsTopLeft: Bool) -> PTZ3D {
        guard viewWidth > 0, viewHeight > 0 else {
            return PTZ3D(startX: 128, startY: 128, endX: 128, endY: 128)
        }
        let left = min(rectX, rectX + rectWidth)
        let right = max(rectX, rectX + rectWidth)
        let top = min(rectY, rectY + rectHeight)
        let bottom = max(rectY, rectY + rectHeight)
        func axisX(_ value: Double) -> Int { Int(((value / viewWidth) * 255).rounded()) }
        func axisY(_ value: Double) -> Int {
            let fraction = value / viewHeight
            // The Y flip is the whole point: a view coordinate of 0 is the *top*, which is 255 in
            // the device's lower-left space.
            return Int(((originIsTopLeft ? fraction : 1 - fraction) * 255).rounded())
        }
        return PTZ3D(startX: axisX(left), startY: axisY(top),
                     endX: axisX(right), endY: axisY(bottom))
    }

    /// A click-to-centre command at one view point.
    public static func point(x: Double, y: Double, viewWidth: Double, viewHeight: Double,
                             originIsTopLeft: Bool) -> PTZ3D {
        box(rectX: x, rectY: y, rectWidth: 0, rectHeight: 0,
            viewWidth: viewWidth, viewHeight: viewHeight, originIsTopLeft: originIsTopLeft)
    }

    /// `<PTZData><Position3D><StartPoint>…</StartPoint><EndPoint>…</EndPoint></Position3D></…>`.
    public var body: XMLBuilder {
        var builder = XMLBuilder("PTZData")
        builder.addChild("Position3D") { position in
            position.addChild("StartPoint") { start in
                start.add("positionX", startX)
                start.add("positionY", startY)
            }
            position.addChild("EndPoint") { end in
                end.add("positionX", endX)
                end.add("positionY", endY)
            }
        }
        return builder
    }
}

/// The name docs/spec-isapi.md §13.5 uses for the drag rectangle. `PTZ3D` is the name
/// docs/API_CONTRACT.md §4.5 gives the same type, and the contract wins.
public typealias PTZBox = PTZ3D

// MARK: - Auxiliary commands

/// An auxiliary output. Support is discovered from PTZ capabilities; absent means hide the button.
public enum PTZAuxiliary: String, Sendable, Hashable, Codable, CaseIterable {
    case light = "LIGHT"
    case wiper = "WIPER"
    case heater = "HEATER"
    case fan = "FAN"
    case aux1 = "AUX1"
    case aux2 = "AUX2"

    /// `<PTZAux><id>…</id><type>…</type><status>on|off</status></PTZAux>`.
    public func body(id: Int, on: Bool) -> XMLBuilder {
        var builder = XMLBuilder("PTZAux")
        builder.add("id", id)
        builder.add("type", rawValue)
        builder.add("status", on ? "on" : "off")
        return builder
    }
}

// MARK: - Focus and iris

/// The continuous focus and iris bodies.
///
/// Both live under `/System/Video/inputs/channels/{ch}`, **not** under `/PTZCtrl` — an unusual
/// path that is easy to get wrong and produces a silent 404.
public enum PTZLensCommand {

    /// `<FocusData><focus>…</focus></FocusData>`. −100…100 velocity, zero to stop.
    public static func focus(_ velocity: Int) -> XMLBuilder {
        var builder = XMLBuilder("FocusData")
        builder.add("focus", min(100, max(-100, velocity)))
        return builder
    }

    /// `<IrisData><iris>…</iris></IrisData>`. −100…100 velocity, zero to stop.
    public static func iris(_ velocity: Int) -> XMLBuilder {
        var builder = XMLBuilder("IrisData")
        builder.add("iris", min(100, max(-100, velocity)))
        return builder
    }
}
