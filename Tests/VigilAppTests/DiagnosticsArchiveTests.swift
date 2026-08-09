#if os(macOS)

import Foundation
import Testing

@testable import Vigil

@Suite("Diagnostics archive")
struct DiagnosticsArchiveTests {
    @Test func builderStopsBeforeWritingWhenItsTaskIsCancelled() async {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate { break }
            return try DiagnosticsArchiveBuilder.build(
                createdAt: Date(timeIntervalSince1970: 0),
                includesHostnames: false, includesFullLogs: true,
                files: [DiagnosticsArchiveFile(path: "summary.txt", text: "hello")])
        }
        task.cancel()
        release.yield(())
        release.finish()

        do {
            _ = try await task.value
            Issue.record("a cancelled diagnostics build succeeded")
        } catch is CancellationError {
            // Expected: cancellation is checked before redaction, hashing and ZIP encoding.
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }
    }

    @Test func redactsEveryTextFileAtTheArchiveBoundary() throws {
        let knownPassword = "only-for-the-test"
        let authorization = "Digest response=deadbeef, nonce=abc123"
        let archive = try DiagnosticsArchiveBuilder.build(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            includesHostnames: false,
            includesFullLogs: true,
            files: [
                DiagnosticsArchiveFile(
                    path: "logs/vigil.log",
                    text: "password=\(knownPassword) Authorization: \(authorization)"),
                DiagnosticsArchiveFile(
                    path: "capabilities/camera.xml",
                    text: "<serialNumber>DS1234567890</serialNumber>"
                        + "<sessionID>full-session-identifier</sessionID>"),
            ])

        let text = String(decoding: archive, as: UTF8.self)
        #expect(!text.contains(knownPassword))
        #expect(!text.contains("deadbeef"))
        #expect(!text.contains("abc123"))
        #expect(!text.contains("DS1234567890"))
        #expect(!text.contains("full-session-identifier"))
        #expect(text.contains("manifest.json"))
        #expect(text.contains("logs/vigil.log"))
    }

    @Test func manifestDescribesTheExactStoredFiles() throws {
        let archive = try DiagnosticsArchiveBuilder.build(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            includesHostnames: false,
            includesFullLogs: false,
            files: [DiagnosticsArchiveFile(path: "summary.txt", text: "hello")])
        let text = String(decoding: archive, as: UTF8.self)
        #expect(text.contains("\"path\" : \"summary.txt\""))
        #expect(text.contains("\"bytes\" : 5"))
        #expect(text.contains("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"))
        #expect(text.contains("\"includesFullLogs\" : false"))
    }

    @Test func rejectsBundlesOverFortyMegabytesBeforeEncoding() {
        let oversized = Data(repeating: 0x61,
                             count: DiagnosticsArchiveBuilder.maximumBytes + 1)
        #expect(throws: DiagnosticsArchiveError.exceedsSizeLimit(bytes: oversized.count)) {
            try DiagnosticsArchiveBuilder.build(
                createdAt: Date(), includesHostnames: false, includesFullLogs: true,
                files: [DiagnosticsArchiveFile(path: "logs/too-large.log", data: oversized)])
        }
    }
}

#endif
