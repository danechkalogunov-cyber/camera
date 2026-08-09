//
//  StoreOnlyZIP.swift
//  VigilProtocols
//
//  The deliberately small ZIP dialect used by diagnostics exports. It writes ordinary, seek-free
//  PKZIP archives with stored entries, UTF-8 names and no data descriptors. Keeping it in the pure
//  layer makes the byte format testable on every CI host and keeps Foundation's platform archive
//  APIs out of the support path.
//

import Foundation

/// A file to place in a ``StoreOnlyZIP`` archive.
public struct ZIPEntry: Sendable, Hashable {
    public let path: String
    public let data: Data

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }
}

/// Errors raised before an invalid or ambiguous archive can be emitted.
public enum StoreOnlyZIPError: Error, Sendable, Hashable {
    case emptyPath
    case unsafePath(String)
    case duplicatePath(String)
    case entryTooLarge(String)
    case archiveTooLarge
    case tooManyEntries
}

/// A deterministic STORE-only ZIP writer (PKZIP APPNOTE 4.3.7, 4.3.12 and 4.3.16).
///
/// Timestamps are intentionally zero. A diagnostics archive is content-addressed by its manifest;
/// embedding the current local time in two places per entry would make byte-for-byte tests and
/// reproducible support captures needlessly difficult.
public enum StoreOnlyZIP {
    public static func encode(_ entries: [ZIPEntry]) throws(StoreOnlyZIPError) -> Data {
        guard entries.count <= Int(UInt16.max) else { throw .tooManyEntries }

        var seen = Set<String>()
        var output = Data()
        var central = Data()

        for entry in entries {
            try validate(entry.path, seen: &seen)
            let name = Data(entry.path.utf8)
            guard entry.data.count <= Int(UInt32.max), name.count <= Int(UInt16.max) else {
                throw .entryTooLarge(entry.path)
            }
            guard output.count <= Int(UInt32.max) else { throw .archiveTooLarge }

            let offset = UInt32(output.count)
            let size = UInt32(entry.data.count)
            let checksum = crc32(entry.data)

            output.appendLE(UInt32(0x0403_4B50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0x0800))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            // 1980-01-01, the earliest representable DOS date. The archive's real creation instant
            // is in manifest.json; this stable value keeps identical evidence reproducible.
            output.appendLE(UInt16(0x0021))
            output.appendLE(checksum)
            output.appendLE(size)
            output.appendLE(size)
            output.appendLE(UInt16(name.count))
            output.appendLE(UInt16(0))
            output.append(name)
            output.append(entry.data)

            central.appendLE(UInt32(0x0201_4B50))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0x0021))
            central.appendLE(checksum)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt32(0))
            central.appendLE(offset)
            central.append(name)
        }

        guard output.count <= Int(UInt32.max), central.count <= Int(UInt32.max),
              output.count + central.count <= Int(UInt32.max)
        else { throw .archiveTooLarge }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.appendLE(UInt32(0x0605_4B50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt32(central.count))
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))
        return output
    }

    /// Public so manifest verification and tests use the exact checksum implementation the writer
    /// used, rather than maintaining a subtly different table elsewhere.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            crc = (crc >> 8) ^ value
        }
        return crc ^ UInt32.max
    }

    private static func validate(_ path: String, seen: inout Set<String>)
        throws(StoreOnlyZIPError) {
        guard !path.isEmpty else { throw .emptyPath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.hasSuffix("/"),
              !path.contains("\\"), !parts.contains(".."), !parts.contains(".") else {
            throw .unsafePath(path)
        }
        guard seen.insert(path).inserted else { throw .duplicatePath(path) }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
