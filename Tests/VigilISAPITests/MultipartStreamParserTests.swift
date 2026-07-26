//
//  MultipartStreamParserTests.swift
//  VigilISAPITests
//
//  The alert-stream parser fed the four boundary spellings, split at every hostile offset, with a
//  JPEG part, with a heartbeat, and with input designed to make it buffer without bound.
//  Covers docs/spec-isapi.md §14.1 and §14.5.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - Fixtures

enum MultipartFixtures {

    /// The motion event of docs/spec-isapi.md §14.2, with its polygon.
    static let motionXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <EventNotificationAlert version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <ipAddress>192.168.1.64</ipAddress>
        <portNo>80</portNo>
        <protocol>HTTP</protocol>
        <macAddress>44:47:cc:11:22:33</macAddress>
        <channelID>1</channelID>
        <dateTime>2024-05-01T12:34:56+08:00</dateTime>
        <activePostCount>1</activePostCount>
        <eventType>VMD</eventType>
        <eventState>active</eventState>
        <eventDescription>Motion alarm</eventDescription>
        <channelName>Driveway</channelName>
        <DetectionRegionList>
        <DetectionRegion>
        <regionID>1</regionID>
        <sensitivityLevel>60</sensitivityLevel>
        <RegionCoordinatesList>
        <RegionCoordinates><positionX>0</positionX><positionY>0</positionY></RegionCoordinates>
        <RegionCoordinates><positionX>1000</positionX><positionY>0</positionY></RegionCoordinates>
        <RegionCoordinates><positionX>1000</positionX><positionY>560</positionY></RegionCoordinates>
        <RegionCoordinates><positionX>0</positionX><positionY>560</positionY></RegionCoordinates>
        </RegionCoordinatesList>
        </DetectionRegion>
        </DetectionRegionList>
        </EventNotificationAlert>
        """

    /// The heartbeat of docs/spec-isapi.md §14.2: `videoloss` / `inactive` / `activePostCount 0`.
    static let heartbeatXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <EventNotificationAlert version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <ipAddress>192.168.1.64</ipAddress>
        <portNo>80</portNo>
        <protocol>HTTP</protocol>
        <macAddress>44:47:cc:11:22:33</macAddress>
        <channelID>1</channelID>
        <dateTime>2024-05-01T12:35:01+08:00</dateTime>
        <activePostCount>0</activePostCount>
        <eventType>videoloss</eventType>
        <eventState>inactive</eventState>
        <eventDescription>videoloss alarm</eventDescription>
        </EventNotificationAlert>
        """

    /// A tripwire event whose "polygon" is legitimately two points.
    static let lineCrossingXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <EventNotificationAlert version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <channelID>1</channelID>
        <dynChannelID>7</dynChannelID>
        <dateTime>2024-05-01T12:36:00Z</dateTime>
        <activePostCount>2</activePostCount>
        <eventType>linedetection</eventType>
        <eventState>active</eventState>
        <DetectionRegionList><DetectionRegion>
        <regionID>1</regionID>
        <RegionCoordinatesList>
        <RegionCoordinates><positionX>100</positionX><positionY>250</positionY></RegionCoordinates>
        <RegionCoordinates><positionX>900</positionX><positionY>250</positionY></RegionCoordinates>
        </RegionCoordinatesList>
        </DetectionRegion></DetectionRegionList>
        </EventNotificationAlert>
        """

    /// A synthetic JPEG: the SOI marker, a body that deliberately contains the boundary token
    /// **not** preceded by a line ending, and the EOI marker.
    static func jpeg(containing token: String) -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        data.append(Data("padding--\(token)padding".utf8))
        data.append(Data([0x00, 0x01, 0x02, 0xFF, 0xD9]))
        return data
    }

    /// Builds a multipart stream. `lineEnding` is the delimiter's terminator, so the bare-LF
    /// firmware and the CRLF firmware are the same builder.
    static func stream(boundary token: String, parts: [(headers: [String: String], body: Data)],
                       closing: Bool = true, lineEnding: String = "\r\n",
                       preamble: String = "") -> Data {
        var out = Data(preamble.utf8)
        for part in parts {
            out.append(Data("--\(token)\(lineEnding)".utf8))
            for (name, value) in part.headers.sorted(by: { $0.key < $1.key }) {
                out.append(Data("\(name): \(value)\r\n".utf8))
            }
            out.append(Data("\r\n".utf8))
            out.append(part.body)
            out.append(Data("\r\n".utf8))
        }
        if closing { out.append(Data("--\(token)--\(lineEnding)".utf8)) }
        return out
    }

    /// The §14.2 sample: motion, then its JPEG, then the heartbeat, then the closing delimiter.
    static func realisticStream(boundary token: String = "<boundary>") -> Data {
        let motion = Data(motionXML.utf8)
        let image = jpeg(containing: token)
        let heartbeat = Data(heartbeatXML.utf8)
        return stream(boundary: token, parts: [
            (["Content-Type": "application/xml; charset=\"UTF-8\"",
              "Content-Length": String(motion.count)], motion),
            (["Content-Type": "image/jpeg", "Content-Length": String(image.count)], image),
            (["Content-Type": "application/xml; charset=\"UTF-8\"",
              "Content-Length": String(heartbeat.count)], heartbeat),
        ])
    }

    /// Drives a parser with one chunk size and collects every output.
    static func run(_ data: Data, boundary: String, chunkSize: Int,
                    limits: MultipartStreamParser.Limits = .init())
        throws -> [MultipartStreamParser.Output] {
        var parser = MultipartStreamParser(boundary: boundary, limits: limits)
        var outputs: [MultipartStreamParser.Output] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: min(chunkSize, data.distance(from: offset,
                                                                               to: data.endIndex)))
            outputs += try parser.ingest(Data(data[offset..<end]))
            offset = end
        }
        outputs += parser.finish()
        return outputs
    }

    /// Reassembles the bodies of every part in an output sequence.
    static func bodies(_ outputs: [MultipartStreamParser.Output]) -> [Data] {
        var out: [Data] = []
        var current = Data()
        var open = false
        for output in outputs {
            switch output {
            case .partBegan:
                current = Data()
                open = true
            case .partData(let data):
                current.append(data)
            case .partEnded:
                if open { out.append(current) }
                open = false
            case .partTruncated, .streamEnded:
                break
            }
        }
        return out
    }
}

// MARK: - BoundarySuite

@Suite struct MultipartBoundarySuite {

    @Test func multipartBoundaryTakesTheTokenVerbatim() {
        // docs/spec-isapi.md §14.1's four observed spellings. Only surrounding double quotes are
        // stripped: angle brackets and leading dashes are part of the token.
        #expect(MultipartStreamParser.boundary(
            fromContentType: "multipart/mixed; boundary=<boundary>") == "<boundary>")
        #expect(MultipartStreamParser.boundary(
            fromContentType: "multipart/mixed; boundary=boundary") == "boundary")
        #expect(MultipartStreamParser.boundary(
            fromContentType: "multipart/mixed;boundary=--myboundary") == "--myboundary")
        #expect(MultipartStreamParser.boundary(
            fromContentType: "multipart/mixed; boundary=\"MIME_boundary\"") == "MIME_boundary")
    }

    @Test func multipartBoundaryIsCaseInsensitiveOnTheParameterName() {
        #expect(MultipartStreamParser.boundary(
            fromContentType: "multipart/mixed; BOUNDARY=abc") == "abc")
    }

    @Test func multipartBoundaryReturnsNilWhenAbsent() {
        #expect(MultipartStreamParser.boundary(fromContentType: "multipart/mixed") == nil)
        #expect(MultipartStreamParser.boundary(fromContentType: "text/plain") == nil)
        #expect(MultipartStreamParser.boundary(
            fromContentType: "multipart/mixed; boundary=") == nil)
    }

    @Test func multipartSniffsABoundaryFromThePreamble() {
        // Seen on one 5.1.x build: the header carries no boundary at all.
        let body = Data("\r\n--MIME_boundary\r\nContent-Type: application/xml\r\n\r\n".utf8)
        #expect(MultipartStreamParser.sniffBoundary(inPreamble: body) == "MIME_boundary")
        // A line with spaces is not a delimiter.
        let noise = Data("--not a boundary\r\n--realBoundary\r\n".utf8)
        #expect(MultipartStreamParser.sniffBoundary(inPreamble: noise) == "realBoundary")
        #expect(MultipartStreamParser.sniffBoundary(inPreamble: Data("no delimiters".utf8)) == nil)
    }

    @Test func multipartParsesEveryBoundarySpelling() throws {
        for token in ["<boundary>", "boundary", "--myboundary", "MIME_boundary"] {
            let stream = MultipartFixtures.realisticStream(boundary: token)
            let outputs = try MultipartFixtures.run(stream, boundary: token, chunkSize: 4096)
            let bodies = MultipartFixtures.bodies(outputs)
            #expect(bodies.count == 3, "token \(token)")
            #expect(bodies[0] == Data(MultipartFixtures.motionXML.utf8), "token \(token)")
            #expect(bodies[1] == MultipartFixtures.jpeg(containing: token), "token \(token)")
            #expect(outputs.contains { if case .streamEnded = $0 { true } else { false } })
        }
    }
}

// MARK: - HostileSplitSuite

@Suite struct MultipartHostileSplitSuite {

    @Test func multipartSurvivesEveryChunkBoundary() throws {
        // Parameterised over every chunk size from 1 byte up: the delimiter, the header terminator
        // and the JPEG all get split at every possible offset across the whole stream.
        let token = "<boundary>"
        let stream = MultipartFixtures.realisticStream(boundary: token)
        let expected = [Data(MultipartFixtures.motionXML.utf8),
                        MultipartFixtures.jpeg(containing: token),
                        Data(MultipartFixtures.heartbeatXML.utf8)]
        for chunkSize in 1...64 {
            let outputs = try MultipartFixtures.run(stream, boundary: token, chunkSize: chunkSize)
            #expect(MultipartFixtures.bodies(outputs) == expected, "chunk size \(chunkSize)")
        }
        // And a handful of larger, less regular sizes.
        for chunkSize in [97, 128, 251, 512, 1023, 4096, 65_536] {
            let outputs = try MultipartFixtures.run(stream, boundary: token, chunkSize: chunkSize)
            #expect(MultipartFixtures.bodies(outputs) == expected, "chunk size \(chunkSize)")
        }
    }

    @Test func multipartSplitsTheDelimiterAtEveryOffset() throws {
        // The single most dangerous split: the stream cut inside the delimiter itself.
        let token = "MIME_boundary"
        let stream = MultipartFixtures.realisticStream(boundary: token)
        let expected = [Data(MultipartFixtures.motionXML.utf8),
                        MultipartFixtures.jpeg(containing: token),
                        Data(MultipartFixtures.heartbeatXML.utf8)]
        for cut in 1..<min(stream.count, 400) {
            var parser = MultipartStreamParser(boundary: token)
            var outputs = try parser.ingest(Data(stream.prefix(cut)))
            outputs += try parser.ingest(Data(stream.dropFirst(cut)))
            outputs += parser.finish()
            #expect(MultipartFixtures.bodies(outputs) == expected, "cut at \(cut)")
        }
    }

    @Test func multipartToleratesBareLineFeeds() throws {
        // Hikvision 5.2.x sends a bare LF after the boundary and CRLF in headers, in one stream.
        let token = "boundary"
        let motion = Data(MultipartFixtures.motionXML.utf8)
        let stream = MultipartFixtures.stream(
            boundary: token,
            parts: [(["Content-Type": "application/xml",
                      "Content-Length": String(motion.count)], motion)],
            lineEnding: "\n")
        for chunkSize in [1, 3, 17, 4096] {
            let outputs = try MultipartFixtures.run(stream, boundary: token, chunkSize: chunkSize)
            #expect(MultipartFixtures.bodies(outputs) == [motion], "chunk size \(chunkSize)")
        }
    }

    @Test func multipartHandlesAPartWithNoContentLength() throws {
        // Without a declared length the parser has to scan, retaining only its carry.
        let token = "boundary"
        let motion = Data(MultipartFixtures.motionXML.utf8)
        let stream = MultipartFixtures.stream(
            boundary: token,
            parts: [(["Content-Type": "application/xml"], motion)])
        for chunkSize in [1, 7, 64, 4096] {
            let outputs = try MultipartFixtures.run(stream, boundary: token, chunkSize: chunkSize)
            #expect(MultipartFixtures.bodies(outputs) == [motion], "chunk size \(chunkSize)")
        }
    }

    @Test func multipartDoesNotSplitOnTheTokenInsideJPEGData() throws {
        // The JPEG body contains `--<boundary>` with no preceding line ending. Matching on
        // `LF + "--" + token` is what stops that from cutting the image in half.
        let token = "<boundary>"
        let image = MultipartFixtures.jpeg(containing: token)
        #expect(String(decoding: image, as: UTF8.self).contains("--\(token)"))
        let stream = MultipartFixtures.stream(
            boundary: token,
            parts: [(["Content-Type": "image/jpeg"], image)])
        let outputs = try MultipartFixtures.run(stream, boundary: token, chunkSize: 5)
        #expect(MultipartFixtures.bodies(outputs) == [image])
    }

    @Test func multipartDiscardsAPreamble() throws {
        let token = "boundary"
        let motion = Data(MultipartFixtures.motionXML.utf8)
        let stream = MultipartFixtures.stream(
            boundary: token,
            parts: [(["Content-Length": String(motion.count),
                      "Content-Type": "application/xml"], motion)],
            preamble: "HTTP noise the device sent before the first delimiter\r\n")
        let outputs = try MultipartFixtures.run(stream, boundary: token, chunkSize: 13)
        #expect(MultipartFixtures.bodies(outputs) == [motion])
    }

    @Test func multipartThrowsWhenThePreambleNeverEnds() {
        var parser = MultipartStreamParser(
            boundary: "boundary",
            limits: MultipartStreamParser.Limits(maxPreambleBytes: 1024))
        #expect(throws: ISAPIError.self) {
            for _ in 0..<10 {
                _ = try parser.ingest(Data(repeating: 0x41, count: 512))
            }
        }
    }

    @Test func multipartResynchronizesAfterGarbageBetweenParts() throws {
        let token = "boundary"
        let motion = Data(MultipartFixtures.motionXML.utf8)
        var stream = Data("--\(token)\r\nContent-Type: application/xml\r\n\r\n".utf8)
        stream.append(motion)
        stream.append(Data("\r\n".utf8))
        // Junk that is not a delimiter, then a real part.
        stream.append(Data("garbage that is not a delimiter at all\r\n".utf8))
        stream.append(Data("--\(token)\r\nContent-Type: application/xml\r\nContent-Length: ".utf8))
        stream.append(Data("\(motion.count)\r\n\r\n".utf8))
        stream.append(motion)
        stream.append(Data("\r\n--\(token)--\r\n".utf8))
        let outputs = try MultipartFixtures.run(stream, boundary: token, chunkSize: 29)
        let bodies = MultipartFixtures.bodies(outputs)
        // The first part's scanned body absorbs the junk line, and the second part is clean.
        #expect(bodies.count == 2)
        #expect(bodies[1] == motion)
        #expect(outputs.contains { if case .streamEnded = $0 { true } else { false } })
    }

    @Test func multipartFinishClosesAnOpenPart() throws {
        let token = "boundary"
        let motion = Data(MultipartFixtures.motionXML.utf8)
        var stream = Data("--\(token)\r\nContent-Type: application/xml\r\n\r\n".utf8)
        stream.append(motion)              // no trailing delimiter: the connection just died
        var parser = MultipartStreamParser(boundary: token)
        var outputs = try parser.ingest(stream)
        #expect(!outputs.contains { if case .partEnded = $0 { true } else { false } })
        outputs += parser.finish()
        #expect(MultipartFixtures.bodies(outputs) == [motion])
    }
}

// MARK: - MemoryBoundSuite

@Suite struct MultipartMemoryBoundSuite {

    @Test func multipartNeverRetainsMoreThanTheCarryInBodyStates() throws {
        // The invariant docs/spec-isapi.md §14.5 states outright: in the body states the retained
        // buffer is at most `boundary.count + 4` bytes, whatever the device sends.
        let token = "MIME_boundary"
        var parser = MultipartStreamParser(boundary: token)
        let header = Data("--\(token)\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        _ = try parser.ingest(header)
        #expect(parser.isInBodyState)
        for _ in 0..<64 {
            _ = try parser.ingest(Data(repeating: 0x5A, count: 64 * 1024))
            #expect(parser.isInBodyState)
            #expect(parser.retainedByteCount <= token.utf8.count + 4)
        }
    }

    @Test func multipartTruncatesAnOversizedBinaryPartAndKeepsTheStream() throws {
        let token = "boundary"
        var limits = MultipartStreamParser.Limits()
        limits.maxBinaryPartBytes = 4096
        var parser = MultipartStreamParser(boundary: token, limits: limits)
        var outputs = try parser.ingest(
            Data("--\(token)\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        outputs += try parser.ingest(Data(repeating: 0x5A, count: 16 * 1024))
        #expect(outputs.contains { if case .partTruncated = $0 { true } else { false } })
        // Only the budget's worth of body was handed out.
        let emitted = outputs.reduce(0) { total, output in
            if case .partData(let data) = output { return total + data.count }
            return total
        }
        #expect(emitted == 4096)
        // The stream survives: a following part parses normally.
        let motion = Data(MultipartFixtures.motionXML.utf8)
        var tail = Data("\r\n--\(token)\r\nContent-Type: application/xml\r\nContent-Length: ".utf8)
        tail.append(Data("\(motion.count)\r\n\r\n".utf8))
        tail.append(motion)
        tail.append(Data("\r\n--\(token)--\r\n".utf8))
        let after = try parser.ingest(tail)
        #expect(MultipartFixtures.bodies(after).contains(motion))
    }

    @Test func multipartTruncatesAnOversizedTextPart() throws {
        let token = "boundary"
        var limits = MultipartStreamParser.Limits()
        limits.maxTextPartBytes = 512
        var parser = MultipartStreamParser(boundary: token, limits: limits)
        var outputs = try parser.ingest(
            Data("--\(token)\r\nContent-Type: application/xml\r\n\r\n".utf8))
        outputs += try parser.ingest(Data(repeating: 0x41, count: 4096))
        #expect(outputs.contains { if case .partTruncated = $0 { true } else { false } })
    }

    @Test func multipartTruncatesOversizedHeadersAndResynchronizes() throws {
        let token = "boundary"
        var limits = MultipartStreamParser.Limits()
        limits.maxHeaderBytes = 256
        var parser = MultipartStreamParser(boundary: token, limits: limits)
        var outputs = try parser.ingest(Data("--\(token)\r\n".utf8))
        // A header block that never terminates.
        outputs += try parser.ingest(Data("X-Junk: \(String(repeating: "j", count: 2048))\r\n".utf8))
        #expect(outputs.contains { if case .partTruncated = $0 { true } else { false } })
        // A real part after it still parses.
        let motion = Data(MultipartFixtures.motionXML.utf8)
        var tail = Data("\r\n--\(token)\r\nContent-Type: application/xml\r\nContent-Length: ".utf8)
        tail.append(Data("\(motion.count)\r\n\r\n".utf8))
        tail.append(motion)
        tail.append(Data("\r\n--\(token)--\r\n".utf8))
        let after = try parser.ingest(tail)
        #expect(MultipartFixtures.bodies(after) == [motion])
    }

    @Test func multipartIgnoresEverythingAfterTheClosingDelimiter() throws {
        let token = "boundary"
        let stream = MultipartFixtures.realisticStream(boundary: token)
        var parser = MultipartStreamParser(boundary: token)
        var outputs = try parser.ingest(stream)
        #expect(outputs.contains { if case .streamEnded = $0 { true } else { false } })
        outputs = try parser.ingest(Data(repeating: 0x41, count: 4096))
        #expect(outputs.isEmpty)
    }

    @Test func multipartHandlesAZeroLengthPart() throws {
        let token = "boundary"
        let stream = MultipartFixtures.stream(
            boundary: token,
            parts: [(["Content-Type": "application/xml", "Content-Length": "0"], Data()),
                    (["Content-Type": "application/xml",
                      "Content-Length": String(MultipartFixtures.heartbeatXML.utf8.count)],
                     Data(MultipartFixtures.heartbeatXML.utf8))])
        let outputs = try MultipartFixtures.run(stream, boundary: token, chunkSize: 11)
        let bodies = MultipartFixtures.bodies(outputs)
        #expect(bodies.count == 2)
        #expect(bodies[0].isEmpty)
        #expect(bodies[1] == Data(MultipartFixtures.heartbeatXML.utf8))
    }

    @Test func multipartReportsHeadersLowercasedWithTheDeclaredLength() throws {
        let token = "boundary"
        let motion = Data(MultipartFixtures.motionXML.utf8)
        let stream = MultipartFixtures.stream(
            boundary: token,
            parts: [(["Content-Type": "application/xml; charset=\"UTF-8\"",
                      "Content-Length": String(motion.count)], motion)])
        let outputs = try MultipartFixtures.run(stream, boundary: token, chunkSize: 4096)
        guard case .partBegan(let headers, let declared) = outputs.first else {
            Issue.record("first output was not partBegan")
            return
        }
        #expect(headers["content-type"] == "application/xml; charset=\"UTF-8\"")
        #expect(headers["content-length"] == String(motion.count))
        #expect(declared == motion.count)
    }
}
