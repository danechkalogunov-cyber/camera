//
//  FrameGeometry.swift
//  VigilProtocols
//
//  Integer picture size, colour description and the coded/cropped/displayed geometry of one video
//  stream — the values that keep 1920×1088-coded, 1920×1080-displayed H.264 straight everywhere.
//  Implements docs/API_CONTRACT.md §3.6 and §2 R-57 (`Resolution` is the one size type).
//
//  No `import` on purpose: integers, `Double` and `String` are all stdlib.
//

// MARK: - Resolution

/// Integer pixel dimensions. The one size type in Vigil: used for stream resolution, display
/// resolution and tile backing size alike. `PixelSize` does not exist (API_CONTRACT §2 R-57).
public struct Resolution: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {

    // MARK: - Stored Properties

    /// Width in pixels. Never negative in practice; nothing here validates it.
    public var width: Int

    /// Height in pixels.
    public var height: Int

    // MARK: - Initialisation

    /// Builds a size. Values are stored verbatim — validation belongs to the parser that produced
    /// them, so a zero or negative dimension survives to be reported rather than being masked here.
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    // MARK: - Computed Properties

    /// Total pixel count, the input to every decode-budget calculation.
    @inlinable public var pixels: Int { width * height }

    /// Pixel count in millions, for display.
    @inlinable public var megapixels: Double { Double(pixels) / 1_000_000 }

    /// Width over height. Zero — not infinity — when the height is zero, so this never poisons a
    /// layout calculation with a NaN.
    @inlinable public var aspect: Double { height == 0 ? 0 : Double(width) / Double(height) }

    /// `min(width, height)`. The input to the tile-class table (API_CONTRACT §2 R-21).
    @inlinable public var shortEdge: Int { Swift.min(width, height) }

    // MARK: - Well-known sizes

    public static let uhd4K  = Resolution(width: 3840, height: 2160)
    public static let hd1080 = Resolution(width: 1920, height: 1080)
    public static let hd720  = Resolution(width: 1280, height: 720)
    public static let d1     = Resolution(width: 704, height: 576)
    public static let cif    = Resolution(width: 352, height: 288)

    /// The sizes `shortLabel` recognises, with their PAL and NTSC variants. Ascending by pixel
    /// count; the bands do not overlap between two different labels.
    private static let labelTable: [(label: String, size: Resolution)] = [
        ("CIF", Resolution(width: 352, height: 240)),
        ("CIF", .cif),
        ("D1", Resolution(width: 704, height: 480)),
        ("D1", .d1),
        ("720p", .hd720),
        ("1080p", .hd1080),
        ("5MP", Resolution(width: 2592, height: 1944)),
        ("4K", .uhd4K),
    ]

    // MARK: - Public API

    /// Nearest human label: "4K", "5MP", "1080p", "720p", "D1", "CIF", else "W×H".
    ///
    /// "Nearest" is a ±12 % band on pixel count, which is what makes the coded 1920×1088 of a 1080p
    /// H.264 stream and the 2560×1920 of a 5 MP sensor read as "1080p" and "5MP". Anything outside
    /// every band — 3 MP, 4 MP, 6 MP and every unusual crop — falls through to `description`, which
    /// is always correct if less pretty. A zero or negative pixel count also falls through.
    public var shortLabel: String {
        let mine = Double(pixels)
        guard mine > 0 else { return description }
        for entry in Resolution.labelTable {
            let reference = Double(entry.size.pixels)
            if mine >= reference * 0.88, mine <= reference * 1.12 { return entry.label }
        }
        return description
    }

    // MARK: - CustomStringConvertible

    /// `"1920×1080"`, with the multiplication sign. Shown in the inspector and in logs.
    public var description: String { "\(width)×\(height)" }

    // MARK: - Comparable

    /// Ordered by pixel count, then width, so `1440×1080` sorts before `1920×810` (both 1.56 MP)
    /// deterministically rather than by hash order.
    public static func < (a: Self, b: Self) -> Bool {
        a.pixels == b.pixels ? a.width < b.width : a.pixels < b.pixels
    }
}

// MARK: - FieldOrder

/// Scan type of a coded picture. Every Hikvision profile we have seen is `.progressive`; the two
/// interlaced cases exist because an analogue encoder behind a DVR can still produce them.
public enum FieldOrder: UInt8, Sendable, Hashable, Codable {
    case progressive, topFieldFirst, bottomFieldFirst
}

// MARK: - ColorInfo

/// Colour description carried from the SPS/VPS VUI to the renderer. Pure integers and enums, so
/// `VigilBitstream` computes it on Linux and `VigilRenderTests` can assert on it without a GPU.
public struct ColorInfo: Sendable, Hashable, Codable {

    // MARK: - Nested Types

    public enum Matrix: UInt8, Sendable, Hashable, Codable { case bt601, bt709, bt2020ncl, unspecified }

    public enum Range: UInt8, Sendable, Hashable, Codable { case video, full }

    public enum Transfer: UInt8, Sendable, Hashable, Codable {
        case bt709, smpte170m, srgb, pq, hlg, unspecified
    }

    public enum Primaries: UInt8, Sendable, Hashable, Codable {
        case bt709, bt2020, smpte170m, unspecified
    }

    public enum ChromaSiting: UInt8, Sendable, Hashable, Codable { case left, center, topLeft }

    // MARK: - Stored Properties

    /// YCbCr → RGB matrix coefficients.
    public var matrix: Matrix

    /// `.video` is the 16–235 studio swing every camera we have met emits.
    public var range: Range

    /// Opto-electronic transfer function. `.pq` and `.hlg` are the two HDR cases.
    public var transfer: Transfer

    /// Colour primaries of the source.
    public var primaries: Primaries

    /// Chroma sample position relative to luma. `.left` for 4:2:0 MPEG-2/H.264/H.265 as shipped.
    public var chromaSiting: ChromaSiting

    // MARK: - Initialisation

    public init(matrix: Matrix, range: Range, transfer: Transfer,
                primaries: Primaries, chromaSiting: ChromaSiting) {
        self.matrix = matrix
        self.range = range
        self.transfer = transfer
        self.primaries = primaries
        self.chromaSiting = chromaSiting
    }

    // MARK: - Defaults

    /// The default when the VUI is absent, which is most Hikvision firmware:
    /// BT.709, video range, left siting. BT.601 is substituted when `codedHeight < 576`.
    public static let bt709Video = ColorInfo(matrix: .bt709, range: .video, transfer: .bt709,
                                             primaries: .bt709, chromaSiting: .left)

    /// The standard-definition default, substituted when `codedHeight < 576`.
    public static let bt601Video = ColorInfo(matrix: .bt601, range: .video, transfer: .smpte170m,
                                             primaries: .smpte170m, chromaSiting: .left)

    // MARK: - Computed Properties

    /// True only for PQ or HLG. EDR is enabled only for these, and only on a screen whose
    /// `maximumExtendedDynamicRangeColorComponentValue > 1.0`.
    @inlinable public var isHDR: Bool { transfer == .pq || transfer == .hlg }
}

// MARK: - FrameGeometry

/// Coded geometry, clean aperture and sample aspect ratio for one video stream.
///
/// **Report cropped display size; allocate from coded size.** 1080p H.264 is coded 1920×1088 and
/// displayed 1920×1080. `VigilRender`, `VigilUI` and `ClipRecorder` read `displaySize`, never the
/// pixel buffer's extent.
public struct FrameGeometry: Sendable, Hashable, Codable {

    // MARK: - Stored Properties

    /// Allocation size, in luma samples. Always a multiple of the codec's macroblock/CTB size.
    public var codedWidth: Int

    /// Allocation height, in luma samples.
    public var codedHeight: Int

    /// Clean aperture inside the coded frame, origin top-left, in luma samples.
    public var cropLeft: Int

    /// Distance from the top of the coded frame to the top of the clean aperture.
    public var cropTop: Int

    /// Width of the clean aperture, in luma samples.
    public var cropWidth: Int

    /// Height of the clean aperture, in luma samples.
    public var cropHeight: Int

    /// Sample (pixel) aspect ratio. `1:1` when the VUI is absent or says square.
    public var sarWidth: Int

    /// Denominator of the sample aspect ratio.
    public var sarHeight: Int

    /// 8 or 10. Values outside `8...12` are a parse error.
    public var bitDepth: Int

    /// Scan type. `.progressive` for every Hikvision live profile.
    public var fieldOrder: FieldOrder

    /// Colour description, defaulted to BT.709 video range when the VUI is absent.
    public var color: ColorInfo

    // MARK: - Initialisation

    /// Builds a geometry. Values are stored verbatim, including a nonsensical SAR or bit depth: the
    /// SPS parser reports those as parse errors, and the computed properties below are written so
    /// that no stored value — however hostile — can make them trap.
    public init(codedWidth: Int, codedHeight: Int,
                cropLeft: Int = 0, cropTop: Int = 0, cropWidth: Int, cropHeight: Int,
                sarWidth: Int = 1, sarHeight: Int = 1, bitDepth: Int = 8,
                fieldOrder: FieldOrder = .progressive, color: ColorInfo = .bt709Video) {
        self.codedWidth = codedWidth
        self.codedHeight = codedHeight
        self.cropLeft = cropLeft
        self.cropTop = cropTop
        self.cropWidth = cropWidth
        self.cropHeight = cropHeight
        self.sarWidth = sarWidth
        self.sarHeight = sarHeight
        self.bitDepth = bitDepth
        self.fieldOrder = fieldOrder
        self.color = color
    }

    // MARK: - Computed Properties

    /// The size a pixel buffer must be allocated at.
    @inlinable public var codedSize: Resolution { Resolution(width: codedWidth, height: codedHeight) }

    /// The cropped picture, before SAR correction.
    @inlinable public var croppedSize: Resolution { Resolution(width: cropWidth, height: cropHeight) }

    /// Width of one sample divided by its height.
    ///
    /// Falls back to 1.0 for a non-positive numerator or denominator: `sar_height == 0` is
    /// expressible in a VUI, and an infinity here would trap `displaySize`'s conversion to `Int`.
    @inlinable public var pixelAspectRatio: Double {
        sarWidth > 0 && sarHeight > 0 ? Double(sarWidth) / Double(sarHeight) : 1
    }

    /// The size the picture should occupy on a square-pixel display. **This is what the tile,
    /// the window and the recorder use.**
    ///
    /// The corrected width is clamped to `0 ... 2^30` before it becomes an `Int`, so a hostile SAR
    /// of, say, `65535:1` on a wide crop cannot trap the conversion.
    @inlinable public var displaySize: Resolution {
        let scaled = (Double(cropWidth) * pixelAspectRatio).rounded()
        let bounded = Swift.min(Swift.max(scaled, 0), 1_073_741_824)
        return Resolution(width: Int(bounded), height: cropHeight)
    }

    /// Displayed width over displayed height, SAR included. Zero when the crop height is zero.
    @inlinable public var displayAspect: Double {
        cropHeight == 0 ? 0 : Double(cropWidth) * pixelAspectRatio / Double(cropHeight)
    }

    /// True when the picture is not interlaced.
    @inlinable public var isProgressive: Bool { fieldOrder == .progressive }
}
