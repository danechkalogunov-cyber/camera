//
//  AlertPartAssembler.swift
//  VigilISAPI
//

import Foundation

// MARK: - AlertPartAssembler

struct AlertPartAssembler: Sendable {

    private let policy: AlertStreamMonitor.Policy

    private enum PartKind: Sendable { case text, image, other }
    private var kind: PartKind = .other
    private var partBuffer = Data()
    private var partOverflowed = false
    /// The decoded event waiting to see whether a JPEG follows it.
    private var pending: (alert: EventNotificationAlert, since: Date)?

    init(policy: AlertStreamMonitor.Policy) {
        self.policy = policy
    }

    /// The parser limits implied by this policy.
    var parserLimits: MultipartStreamParser.Limits {
        MultipartStreamParser.Limits(
            maxTextPartBytes: policy.textPartMaxBytes,
            maxBinaryPartBytes: policy.snapshotMaxBytes)
    }

    /// Consumes one parser output and returns any events it completed.
    mutating func accept(
        _ output: MultipartStreamParser.Output,
        now: Date
    ) -> [EventNotificationAlert] {
        switch output {
        case .partBegan(let headers, _):
            let contentType = (headers["content-type"] ?? "").lowercased()
            if contentType.contains("xml") {
                kind = .text
            } else if contentType.contains("image/") {
                kind = .image
            } else {
                kind = contentType.isEmpty ? .text : .other
            }
            partBuffer = Data()
            partOverflowed = false
            return []
        case .partData(let data):
            let cap = kind == .image ? policy.snapshotMaxBytes : policy.textPartMaxBytes
            guard partBuffer.count + data.count <= cap else {
                partOverflowed = true
                partBuffer = Data()
                return []
            }
            partBuffer.append(data)
            return []
        case .partTruncated:
            partOverflowed = true
            partBuffer = Data()
            return []
        case .partEnded:
            return completePart(now: now)
        case .streamEnded:
            return flushAll()
        }
    }

    /// Emits a pending event whose pairing window has closed.
    mutating func flushExpired(now: Date) -> [EventNotificationAlert] {
        guard let held = pending,
            now.timeIntervalSince(held.since) >= policy.snapshotPairingWindowSeconds
        else {
            return []
        }
        pending = nil
        return [held.alert]
    }

    /// Emits anything still held, at the end of a connection.
    mutating func flushAll() -> [EventNotificationAlert] {
        defer { pending = nil }
        return pending.map { [$0.alert] } ?? []
    }

    /// Finishes the current part.
    private mutating func completePart(now: Date) -> [EventNotificationAlert] {
        defer {
            partBuffer = Data()
            partOverflowed = false
            kind = .other
        }
        switch kind {
        case .text:
            guard !partOverflowed, !partBuffer.isEmpty else { return flushPending() }
            guard let document = try? ISAPIDocument(parsing: partBuffer),
                let alert = try? EventNotificationAlert(document: document, receivedAt: now)
            else {
                // A part that will not decode is not worth stalling the pending event for.
                return flushPending()
            }
            // The previous event never got an image; emit it and hold this one instead.
            let released = flushPending()
            if policy.attachSnapshots {
                pending = (alert, now)
                return released
            }
            return released + [alert]
        case .image:
            guard var held = pending?.alert else { return [] }
            if !partOverflowed, !partBuffer.isEmpty { held.snapshot = partBuffer }
            pending = nil
            return [held]
        case .other:
            return []
        }
    }

    /// Releases the pending event without an image.
    private mutating func flushPending() -> [EventNotificationAlert] {
        defer { pending = nil }
        return pending.map { [$0.alert] } ?? []
    }
}
