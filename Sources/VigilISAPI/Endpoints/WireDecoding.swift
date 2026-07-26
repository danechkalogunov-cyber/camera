//
//  WireDecoding.swift
//  VigilISAPI
//
//  The small reading helpers every endpoint family shares: typed reads that fail as `ISAPIError`,
//  the lenient enumeration matcher, and the wire-unit conversions Hikvision gets wrong on purpose.
//  Implements docs/spec-isapi.md §7.4, §12.1 (units) and §9.2.
//
//  These deliberately use only the *optional* accessors on `XMLValue`. A missing element is a
//  routine firmware difference, so the decision to fail belongs to the caller that knows whether
//  the field is load-bearing — and when it does fail, the message names the path and the element's
//  siblings, because "missing element" without a path has cost this project hours before.
//

import Foundation
import VigilProtocols

// MARK: - Required reads

extension XMLValue {

    /// The element's text, or `.malformedResponse` naming `context` and the path.
    ///
    /// An element that is present but empty counts as missing: Hikvision emits `<name/>` for
    /// "unset", and a zero-length device name is never useful.
    func requireString(_ context: String) throws(ISAPIError) -> String {
        guard let value = string, !value.isEmpty else {
            throw ISAPIError.malformedResponse("\(context): missing or empty <\(path)>")
        }
        return value
    }

    /// The element's integer value, or `.malformedResponse` naming `context` and the path.
    func requireInt(_ context: String) throws(ISAPIError) -> Int {
        guard let value = int else {
            throw ISAPIError.malformedResponse(
                "\(context): <\(path)> is missing or is not an integer (\(string ?? "absent"))")
        }
        return value
    }

    /// The element's date value, or `.malformedResponse` naming `context` and the path.
    func requireDate(_ context: String) throws(ISAPIError) -> Date {
        guard let value = date else {
            throw ISAPIError.malformedResponse(
                "\(context): <\(path)> is not a time Vigil recognises (\(string ?? "absent"))")
        }
        return value
    }
}

// MARK: - Node helpers

extension XMLNode {

    /// The child list at `path`, or an empty array. Never throws: a device that omits a list
    /// entirely and a device that sends `<list/>` mean the same thing.
    func list(_ path: String) -> [XMLNode] { nodes(path) }

    /// Reads an attribute by its lowercased name. Attribute keys are lowercased on parse, values
    /// are verbatim, so `opt="G.711ulaw,AAC"` survives intact.
    func attribute(_ name: String) -> String? { attributes[name.lowercased()] }
}

// MARK: - Wire units

/// The unit conversions between Hikvision's wire encoding and the numbers a person reads.
///
/// Every one of these has been implemented wrongly in the field, which is why they are one
/// namespace with tests in both directions rather than inline arithmetic at call sites
/// (docs/spec-isapi.md §12.1).
public enum ISAPIUnits {

    /// `maxFrameRate` is **fps × 100**: `2000` is 20 fps and `50` is 0.5 fps.
    ///
    /// Values below 100 are legitimate sub-1-fps modes, not errors, so they are not clamped up.
    /// A non-positive wire value yields `nil` — a camera reporting 0 fps is reporting "unknown",
    /// and showing "0 fps" in the UI would be a lie.
    public static func frameRate(fromWire wire: Int) -> Double? {
        guard wire > 0 else { return nil }
        return Double(wire) / 100.0
    }

    /// Inverse of `frameRate(fromWire:)`, rounded to the nearest hundredth of a frame.
    ///
    /// Rounds half away from zero so 12.005 fps becomes `1201`, never `1200`; the device clamps
    /// to its own ladder anyway and the re-GET reports what it actually chose.
    public static func wireFrameRate(fromFPS fps: Double) -> Int {
        Int((fps * 100.0).rounded())
    }

    /// `keyFrameInterval` is **milliseconds**, not frames. `2000` is a 2 s keyframe interval.
    public static func keyFrameSeconds(fromWireMilliseconds wire: Int) -> Double {
        Double(wire) / 1000.0
    }

    /// Inverse of `keyFrameSeconds(fromWireMilliseconds:)`.
    public static func wireKeyFrameMilliseconds(fromSeconds seconds: Double) -> Int {
        Int((seconds * 1000.0).rounded())
    }

    /// Storage capacity is **decimal MB** in Hikvision's accounting: 1 MB = 1 000 000 bytes.
    /// Displaying it any other way makes Vigil disagree with the camera's own web UI.
    public static func bytes(fromDecimalMB mb: Int) -> Int64 { Int64(mb) * 1_000_000 }

    /// `audioSamplingRate` is **kHz as an integer**: `8` means 8000 Hz.
    ///
    /// A device that already reports hertz (seen once, as `8000`) is passed through unchanged;
    /// the discriminator is simply whether the value is large enough to be a hertz reading.
    public static func sampleRateHz(fromWire wire: Int) -> Int {
        wire >= 1000 ? wire : wire * 1000
    }

    /// Detection-region coordinates are 0…1000 on both axes, but 5.5+ smart cameras emit
    /// 0…10000. The magnitude is the only discriminator the wire gives us, so it is the one used
    /// (docs/spec-isapi.md §14.4).
    public static func regionScale(forMaximumCoordinate maximum: Int) -> Double {
        maximum > 1000 ? 10000.0 : 1000.0
    }
}

// MARK: - Lenient enumerations

/// Case- and punctuation-insensitive matching for the enumerated strings ISAPI sends.
///
/// Firmware writes `G.711ulaw`, `G.711uLaw` and `g711ulaw` for the same codec, and `H.264-BP`,
/// `H264` and `h.264` for the same video codec. Normalising to lowercase with `.`, `-`, `_` and
/// spaces removed collapses all of those without a per-firmware table.
public enum ISAPIVocabulary {

    /// Lowercases and drops `.`, `-`, `_` and spaces.
    public static func normalize(_ raw: String) -> String {
        var out = String()
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case ".", "-", "_", " ": continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out.lowercased()
    }

    /// True when `raw` normalises to a value that starts with `prefix` (already normalised).
    public static func hasNormalizedPrefix(_ raw: String, _ prefix: String) -> Bool {
        normalize(raw).hasPrefix(prefix)
    }
}
