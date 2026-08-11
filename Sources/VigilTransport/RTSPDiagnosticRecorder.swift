//
//  RTSPDiagnosticRecorder.swift
//  VigilTransport
//
//  Bounded, redacted RTSP/SDP transcripts for the user-created diagnostics archive.
//

#if os(macOS)

import Foundation

/// Stores recent redacted RTSP control traffic separately for every camera.
///
/// Network actors append synchronously so transcript ordering is identical to wire ordering. The
/// lock is held only while replacing a small `String`; archive collection never reaches into an
/// actor or delays the media path. Both entry and byte limits are enforced to keep a misbehaving
/// camera from growing the process indefinitely.
public final class RTSPDiagnosticRecorder: @unchecked Sendable {
    private struct Stream {
        var entries: [String] = []
        var byteCount = 0
        var lastSDP: String?
    }

    private let lock = NSLock()
    private var streams: [String: Stream] = [:]
    private let maximumEntries: Int
    private let maximumBytes: Int

    public init(maximumEntries: Int = 256, maximumBytes: Int = 512 * 1_024) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1_024, maximumBytes)
    }

    public func append(_ text: String, streamID: String) {
        let redacted = Redact.secrets(in: text)
        let rawEntry = redacted + "\n\n"
        let entry: String
        if rawEntry.utf8.count > maximumBytes {
            let budget = maximumBytes - 64
            entry = String(decoding: rawEntry.utf8.prefix(budget), as: UTF8.self)
                + "\n<transcript entry truncated>\n"
        } else {
            entry = rawEntry
        }
        let bytes = entry.utf8.count
        lock.lock()
        defer { lock.unlock() }
        var stream = streams[streamID] ?? Stream()
        if let sdp = Self.sdpBody(in: redacted) {
            stream.lastSDP = String(decoding: sdp.utf8.prefix(maximumBytes), as: UTF8.self)
        }
        stream.entries.append(entry)
        stream.byteCount += bytes
        while stream.entries.count > maximumEntries || stream.byteCount > maximumBytes {
            guard stream.entries.count > 1 else { break }
            stream.byteCount -= stream.entries.removeFirst().utf8.count
        }
        streams[streamID] = stream
    }

    public func transcript(streamID: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return streams[streamID]?.entries.joined()
            ?? "No RTSP session transcript recorded.\n"
    }

    /// Last complete redacted SDP body observed for this camera, as a standalone diagnostic file.
    public func lastSDP(streamID: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return streams[streamID]?.lastSDP ?? "No SDP recorded.\n"
    }

    public func reset(streamID: String) {
        lock.lock()
        streams.removeValue(forKey: streamID)
        lock.unlock()
    }

    private static func sdpBody(in transcript: String) -> String? {
        guard transcript.range(of: "content-type: application/sdp",
                               options: .caseInsensitive) != nil,
              let separator = transcript.range(of: "\n\n")
        else { return nil }
        let body = transcript[separator.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body + "\n"
    }
}

#endif
