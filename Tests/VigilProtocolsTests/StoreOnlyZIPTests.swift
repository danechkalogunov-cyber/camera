import Foundation
import Testing

@testable import VigilProtocols

@Suite("STORE-only ZIP")
struct StoreOnlyZIPTests {
    @Test func emptyArchiveHasAValidEndRecord() throws {
        let archive = try StoreOnlyZIP.encode([])
        #expect(archive.count == 22)
        #expect(Self.read(UInt32.self, archive, at: 0) == 0x0605_4B50)
        #expect(Self.read(UInt16.self, archive, at: 8) == 0)
    }

    @Test func writesLocalPayloadAndCentralDirectory() throws {
        let payload = Data("Vigil diagnostics\n".utf8)
        let archive = try StoreOnlyZIP.encode([ZIPEntry(path: "summary.txt", data: payload)])

        #expect(Self.read(UInt32.self, archive, at: 0) == 0x0403_4B50)
        #expect(Self.read(UInt16.self, archive, at: 6) == 0x0800)
        #expect(Self.read(UInt32.self, archive, at: 14) == StoreOnlyZIP.crc32(payload))
        #expect(Self.read(UInt32.self, archive, at: 18) == UInt32(payload.count))
        #expect(Self.read(UInt16.self, archive, at: 26) == 11)
        #expect(archive.subdata(in: 30..<41) == Data("summary.txt".utf8))
        #expect(archive.subdata(in: 41..<(41 + payload.count)) == payload)

        let centralOffset = 41 + payload.count
        #expect(Self.read(UInt32.self, archive, at: centralOffset) == 0x0201_4B50)
        #expect(Self.read(UInt32.self, archive, at: centralOffset + 42) == 0)
        #expect(Self.read(UInt32.self, archive, at: archive.count - 22) == 0x0605_4B50)
    }

    @Test func checksumMatchesThePKZIPReferenceVector() {
        #expect(StoreOnlyZIP.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func rejectsTraversalAndDuplicateNames() {
        #expect(throws: StoreOnlyZIPError.unsafePath("../secret")) {
            try StoreOnlyZIP.encode([ZIPEntry(path: "../secret", data: Data())])
        }
        #expect(throws: StoreOnlyZIPError.duplicatePath("same.txt")) {
            try StoreOnlyZIP.encode([
                ZIPEntry(path: "same.txt", data: Data()),
                ZIPEntry(path: "same.txt", data: Data()),
            ])
        }
    }

    private static func read<T: FixedWidthInteger>(_ type: T.Type, _ data: Data,
                                                    at offset: Int) -> T {
        let width = MemoryLayout<T>.size
        var value: T = 0
        for index in 0..<width {
            value |= T(data[offset + index]) << T(index * 8)
        }
        return value
    }
}
