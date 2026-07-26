//
//  AudioSpecificConfig.swift
//  VigilRTP
//
//  ISO/IEC 14496-3 AudioSpecificConfig, parsed from raw bytes or from an SDP `config=` hex string
//  into the `AudioFormatInfo` the decoder needs. The bytes are also kept verbatim, because
//  `AudioConverter` wants them as its decompression magic cookie.
//  See docs/spec-rtp.md §8.5 and docs/API_CONTRACT.md §4.4, §2 R-54.
//

import Foundation

import VigilProtocols

// MARK: - AudioSpecificConfig

/// Parses an MPEG-4 `AudioSpecificConfig`. A namespace, never instantiated.
///
/// Only the fields Vigil needs are decoded: object type, sampling frequency, channel configuration
/// and frame length. Anything past `GASpecificConfig` is ignored, including the backward-compatible
/// SBR sync extension — the RTP clock rate stays the core rate from `a=rtpmap`, because
/// substituting the extension rate doubles every timestamp.
public enum AudioSpecificConfig {

    // MARK: - Public API

    /// The ISO/IEC 14496-3 sampling-frequency index table. Indices 13 and 14 are reserved; index 15
    /// is an escape meaning the next 24 bits carry the rate.
    public static let samplingFrequencies: [Int32] = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050,
        16_000, 12_000, 11_025, 8_000, 7_350,
    ]

    /// Parses an `AudioSpecificConfig` from its bytes.
    ///
    /// - Parameter config: the raw config, at least two bytes. Kept verbatim in
    ///   `AudioFormatInfo.magicCookie`.
    /// - Returns: the decoded format. `channels` falls back to 1 when the config says a program
    ///   config element follows, which Vigil does not parse.
    /// - Throws: `RTPError.malformedAudioConfig` for a truncated config, a reserved sampling
    ///   frequency index, or an object type Vigil cannot frame.
    public static func parse(_ config: Data) throws(RTPError) -> AudioFormatInfo {
        guard config.count >= 2 else { throw .malformedAudioConfig("fewer than two bytes") }
        var reader = BitReader([UInt8](config))
        guard var objectType = read(&reader, 5) else {
            throw .malformedAudioConfig("truncated at audioObjectType")
        }
        if objectType == 31 {
            guard let escape = read(&reader, 6) else {
                throw .malformedAudioConfig("truncated at the audioObjectType escape")
            }
            objectType = 32 + escape
        }

        let sampleRate = try readSamplingFrequency(&reader)
        guard let channelConfiguration = read(&reader, 4) else {
            throw .malformedAudioConfig("truncated at channelConfiguration")
        }

        if objectType == 5 || objectType == 29 {
            // Explicit hierarchical SBR / PS signalling: an extension rate, then the real core
            // object type. The core rate is what the RTP clock counts, so `sampleRate` is kept.
            _ = try readSamplingFrequency(&reader)
            guard var core = read(&reader, 5) else {
                throw .malformedAudioConfig("truncated at the core audioObjectType")
            }
            if core == 22 { _ = read(&reader, 4) }
            if core == 31 {
                guard let escape = read(&reader, 6) else {
                    throw .malformedAudioConfig("truncated at the core audioObjectType escape")
                }
                core = 32 + escape
            }
            objectType = core
        }

        let frameLength = readFrameLength(&reader, objectType: objectType)
        // A channelConfiguration of zero means a program config element follows, which Vigil does
        // not parse; mono is the safe assumption and the only one Hikvision ever needs.
        let channels = channelConfiguration == 0 ? 1 : min(channelConfiguration, 8)
        return AudioFormatInfo(codec: .aac,
                               sampleRate: sampleRate,
                               channels: Int32(channels),
                               framesPerPacket: Int32(frameLength),
                               magicCookie: config)
    }

    /// Parses an `AudioSpecificConfig` from an SDP `config=` value.
    ///
    /// - Parameter hex: an even-length string of hexadecimal digits, upper or lower case.
    ///   Surrounding whitespace is tolerated because folded SDP lines leave it behind.
    /// - Throws: `RTPError.malformedAudioConfig` for odd-length or non-hexadecimal input.
    public static func parse(hex: String) throws(RTPError) -> AudioFormatInfo {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count % 2 == 0 else {
            throw .malformedAudioConfig("config= is empty or has an odd number of digits")
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(trimmed.count / 2)
        var high: UInt8?
        for character in trimmed.unicodeScalars {
            guard let nibble = hexValue(character) else {
                throw .malformedAudioConfig("config= contains a non-hexadecimal character")
            }
            if let pending = high {
                bytes.append(pending << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return try parse(Data(bytes))
    }

    /// The index into `samplingFrequencies` for a rate, or `nil` when the rate is not in the table.
    /// Used by the ADTS builder, which has only an `AudioFormatInfo` in hand.
    public static func frequencyIndex(for sampleRate: Int32) -> UInt8? {
        samplingFrequencies.firstIndex(of: sampleRate).map { UInt8($0) }
    }

    /// The `audioObjectType` encoded in the first five bits of a config, or `nil` when absent.
    public static func objectType(of config: Data?) -> Int? {
        guard let config, let first = config.first else { return nil }
        let value = Int(first >> 3)
        return value == 31 ? nil : value
    }

    // MARK: - Private Helpers

    /// Reads `bits` bits, or returns `nil` when the config ran out.
    private static func read(_ reader: inout BitReader, _ bits: Int) -> Int? {
        guard let value = try? reader.u(bits) else { return nil }
        return Int(value)
    }

    /// Reads a 4-bit sampling-frequency index and resolves it to a rate in hertz.
    private static func readSamplingFrequency(_ reader: inout BitReader) throws(RTPError) -> Int32 {
        guard let index = read(&reader, 4) else {
            throw .malformedAudioConfig("truncated at samplingFrequencyIndex")
        }
        if index == 15 {
            guard let explicit = read(&reader, 24), explicit > 0 else {
                throw .malformedAudioConfig("truncated or zero explicit sampling frequency")
            }
            return Int32(explicit)
        }
        guard index < samplingFrequencies.count else {
            throw .malformedAudioConfig("reserved sampling frequency index \(index)")
        }
        return samplingFrequencies[index]
    }

    /// Reads `frameLengthFlag` for the object types that carry a `GASpecificConfig`.
    ///
    /// A config that ends before the flag is treated as 1024 samples rather than as an error: the
    /// flag is the very next bit after a field we have already read successfully, so a stream that
    /// omits it is still decodable and the common value is the right guess.
    private static func readFrameLength(_ reader: inout BitReader, objectType: Int) -> Int {
        let gaObjectTypes: Set<Int> = [1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23]
        guard gaObjectTypes.contains(objectType) else { return 1024 }
        let longFrame = (try? reader.flag()) ?? false
        if objectType == 23 { return 512 }        // AAC-LD
        return longFrame ? 960 : 1024
    }

    /// The value of one hexadecimal digit, or `nil`.
    private static func hexValue(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "0"..."9": UInt8(scalar.value - 48)
        case "a"..."f": UInt8(scalar.value - 87)
        case "A"..."F": UInt8(scalar.value - 55)
        default: nil
        }
    }
}
