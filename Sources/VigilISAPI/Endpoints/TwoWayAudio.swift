//
//  TwoWayAudio.swift
//  VigilISAPI
//
//  `/ISAPI/System/TwoWayAudio/channels`: the talk-back channel list, the codec negotiation, and the
//  session that opens, streams and — always — closes.
//  Implements docs/spec-isapi.md §16.
//
//  Two rules are absolute. The device decodes uploaded audio according to the channel's configured
//  `audioCompressionType`, **not** according to what we send, so sending µ-law to a channel set to
//  A-law produces loud static: the codec PUT before `open` is mandatory, not an optimisation. And a
//  session left open blocks every other client until the device times it out 60–120 s later, so
//  `close` is sent on every path out, including cancellation and app termination.
//

import Foundation
import VigilProtocols

// MARK: - TwoWayAudioChannel

/// One talk-back channel.
public struct TwoWayAudioChannel: Sendable, Hashable {
    /// 1 on a camera. On an NVR the NVR's own audio is 1 and IP-channel talk-back uses the channel
    /// number.
    public let id: Int
    public var enabled: Bool
    public var codec: AudioCodecWire
    /// From the `opt` attribute on `audioCompressionType`, when the device offers a menu.
    public var supportedCodecs: [AudioCodecWire]
    public var bitrateKbps: Int
    /// Hertz. The wire says kilohertz as an integer, so `8` becomes 8000 here.
    public var sampleRateHz: Int
    /// `MicIn` or `LineIn`.
    public var inputType: String?
    public var associatedVideoChannels: [ChannelID]
    /// The element as received, for the read-modify-write codec PUT.
    public var originalNode: XMLNode?

    public init(id: Int, enabled: Bool, codec: AudioCodecWire,
                supportedCodecs: [AudioCodecWire], bitrateKbps: Int, sampleRateHz: Int,
                inputType: String?, associatedVideoChannels: [ChannelID],
                originalNode: XMLNode? = nil) {
        self.id = id
        self.enabled = enabled
        self.codec = codec
        self.supportedCodecs = supportedCodecs
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.inputType = inputType
        self.associatedVideoChannels = associatedVideoChannels
        self.originalNode = originalNode
    }

    /// Decodes one `<TwoWayAudioChannel>` element.
    ///
    /// The codec menu lives in an attribute, not an element:
    /// `<audioCompressionType opt="G.711ulaw,G.711alaw,AAC">G.711ulaw</audioCompressionType>`.
    /// Reading `@opt` and splitting on commas is the only way to enumerate the choices.
    public init?(node: XMLNode) {
        guard let id = node["id"].int else { return nil }
        let current = node["audioCompressionType"].string ?? "G.711ulaw"
        let options = (node["audioCompressionType@opt"].string ?? "")
            .split(separator: ",")
            .map { AudioCodecWire(raw: $0.trimmingCharacters(in: .whitespaces)) }
        let associated = node
            .nodes("associateVideoInputs/videoInputChannelList/videoInputChannelID[]")
            .compactMap { Int($0.text).map { ChannelID($0) } }
        self.init(id: id,
                  enabled: node["enabled"].bool ?? true,
                  codec: AudioCodecWire(raw: current),
                  // A device with no `opt` attribute offers exactly what it is already set to.
                  supportedCodecs: options.isEmpty ? [AudioCodecWire(raw: current)] : options,
                  bitrateKbps: node["audioBitRate"].int ?? 64,
                  sampleRateHz: ISAPIUnits.sampleRateHz(fromWire: node["audioSamplingRate"].int ?? 8),
                  inputType: node["audioInputType"].string,
                  associatedVideoChannels: associated,
                  originalNode: node)
    }

    /// Decodes every channel in a `<TwoWayAudioChannelList>`, or the single-channel form.
    public static func list(document: ISAPIDocument) -> [TwoWayAudioChannel] {
        let nodes = document.nodes("TwoWayAudioChannel[]")
        let source = nodes.isEmpty ? [document.root] : nodes
        return source.compactMap(TwoWayAudioChannel.init(node:))
    }

    /// Merges a `/capabilities` document's codec menu into this channel.
    public func mergingCapabilities(_ document: ISAPIDocument) -> TwoWayAudioChannel {
        let options = (document["audioCompressionType@opt"].string ?? "")
            .split(separator: ",")
            .map { AudioCodecWire(raw: $0.trimmingCharacters(in: .whitespaces)) }
        guard !options.isEmpty else { return self }
        var copy = self
        copy.supportedCodecs = options
        return copy
    }

    /// Vigil's send preference, in order.
    ///
    /// G.711 µ-law is first because it is universally supported, encodes from an 8 kHz mono buffer
    /// with a 256-entry table and no framework dependency, and has no container framing. `G.722.1`
    /// and AAC are accepted for *reading* device audio but Vigil never sends them: that would need
    /// an encoder, and the negotiation risk is not worth it for talk-back.
    public static let sendPreference: [AudioCodec] = [.g711U, .g711A, .pcmS16LE]

    /// Chooses the codec to talk with.
    ///
    /// Returns `nil` when the device offers nothing Vigil can encode — the caller then disables the
    /// talk button rather than sending bytes the device will render as static.
    public func negotiatedSendCodec() -> AudioCodec? {
        let available = Set(supportedCodecs.compactMap(\.codec))
        for candidate in Self.sendPreference where available.contains(candidate) {
            return candidate
        }
        return nil
    }

    /// The read-modify-write body that sets the channel's codec.
    ///
    /// Returns `nil` when the original element is not available: a hand-built
    /// `<TwoWayAudioChannel>` is the partial document the validator rejects.
    public func codecPatch(to codec: AudioCodec) -> XMLNode? {
        guard let originalNode else { return nil }
        return originalNode.setting("audioCompressionType",
                                    to: AudioCodecWire.wireName(for: codec))
    }
}

// MARK: - TwoWayAudioOpenResult

/// What `PUT …/open` returned.
public struct TwoWayAudioOpenResult: Sendable, Hashable {
    /// The device's session id, when it sent one. Several firmwares answer `<ResponseStatus>` with
    /// `statusCode 1` and no id; that is success and the id is simply unused.
    public let sessionID: String?

    public init(sessionID: String?) {
        self.sessionID = sessionID
    }

    /// Reads `<TwoWayAudioSession><sessionId>`, tolerating the `ResponseStatus` form.
    public init(document: ISAPIDocument?) {
        self.init(sessionID: document?["sessionId|sessionID"].string)
    }
}

// MARK: - TwoWayAudioSession

/// One live talk session: open, stream, close.
///
/// At most one of these exists across all cameras. The device allows exactly one open talk session,
/// and the Mac has one microphone, so app-side exclusivity is enforced too.
public actor TwoWayAudioSession {

    /// Where the session is.
    public enum State: Sendable, Hashable {
        case idle, opening, talking, closing, closed
        case failed(String)
    }

    /// The outbound queue depth, in 20 ms frames. Beyond this the **oldest** frame is dropped:
    /// talk-back is worthless if it is late, so latency is protected at the cost of a syllable.
    public static let maximumQueuedFrames = 25

    private let requests: any ISAPIRequesting
    private let channel: Int
    private let logger: any LoggerProtocol

    public private(set) var state: State = .idle
    public private(set) var codec: AudioCodec
    public private(set) var sampleRateHz: Int
    /// Frames dropped because the queue was full. Surfaced in diagnostics, never silently lost.
    public private(set) var droppedFrames = 0
    private var queue: [Data] = []
    private var upload: (any HTTPUploadHandle)?

    public init(requests: any ISAPIRequesting, channel: Int, codec: AudioCodec,
                sampleRateHz: Int, logger: any LoggerProtocol = NullLogger()) {
        self.requests = requests
        self.channel = channel
        self.codec = codec
        self.sampleRateHz = sampleRateHz
        self.logger = logger
    }

    /// Bytes in one 20 ms frame at this session's sample rate.
    ///
    /// 160 for 8 kHz G.711 — one byte per sample. AAC and G.722.1 are frame-based codecs whose
    /// payload size is not a simple product, so they report the PCM-equivalent and the caller is
    /// expected to send whole encoder frames.
    public var frameBytes: Int {
        switch codec {
        case .g711U, .g711A, .g726: sampleRateHz / 50
        case .pcmS16LE: sampleRateHz / 50 * 2
        case .aac: sampleRateHz / 50 * 2
        }
    }

    /// The filler written when the queue is empty.
    ///
    /// Several firmwares close the session after about a second with no data, so silence is written
    /// rather than letting the stream starve. µ-law silence is `0xFF`, A-law silence is `0xD5`, and
    /// linear silence is zero.
    public var silenceFrame: Data {
        let byte: UInt8 = switch codec {
        case .g711U: 0xFF
        case .g711A: 0xD5
        default: 0x00
        }
        return Data(repeating: byte, count: max(1, frameBytes))
    }

    /// Claims the channel and starts the upload.
    ///
    /// The codec PUT — when the device's configured codec differs from the negotiated one — happens
    /// **before** `open`, because the device decodes according to that setting.
    public func open(configuring current: TwoWayAudioChannel?) async throws(ISAPIError) {
        state = .opening
        if let current, current.codec.codec != codec, let patch = current.codecPatch(to: codec) {
            do {
                try await requests.putDocument(ISAPIResource.twoWayAudioChannel(channel),
                                               body: patch.serialized())
            } catch {
                state = .failed("codec configuration refused: \(error)")
                throw error
            }
        }
        do {
            let document = try await requests.putEmpty(ISAPIResource.twoWayAudioOpen(channel))
            _ = TwoWayAudioOpenResult(document: document)
            state = .talking
        } catch {
            state = .failed("open refused: \(error)")
            throw error
        }
    }

    /// Attaches the upload handle the client opened for `…/audioData`.
    public func attach(_ handle: any HTTPUploadHandle) {
        upload = handle
    }

    /// Enqueues one frame of already-encoded codec bytes. Non-blocking.
    public func enqueue(_ frame: Data) {
        guard case .talking = state else { return }
        if queue.count >= Self.maximumQueuedFrames {
            queue.removeFirst()
            droppedFrames += 1
        }
        queue.append(frame)
    }

    /// Takes the next frame to write, or silence when the queue is empty.
    ///
    /// Frames are not batched beyond four (80 ms): batching further would trade the only thing
    /// talk-back has, which is immediacy.
    public func nextFrame() -> Data {
        guard !queue.isEmpty else { return silenceFrame }
        var out = Data()
        var taken = 0
        while taken < 4, !queue.isEmpty {
            out.append(queue.removeFirst())
            taken += 1
        }
        return out
    }

    /// Writes one frame to the device. Any failure fails the session: a half-sent audio stream is
    /// not resumable, so the UI re-arms the button instead.
    public func pump() async {
        guard case .talking = state, let upload else { return }
        let frame = nextFrame()
        do {
            try await upload.send(frame)
        } catch {
            state = .failed("upload lost: \(error)")
            logger.warning(.isapi, "two-way audio upload failed on channel \(channel): \(error)")
        }
    }

    /// Releases the channel. Safe to call from any state and safe to call twice.
    public func close() async {
        guard state != .closed, state != .closing else { return }
        state = .closing
        await upload?.finish()
        upload = nil
        queue.removeAll()
        // The close is sent even when the open failed: a session the device thinks is open blocks
        // every other client, and a redundant close is harmless.
        _ = try? await requests.putEmpty(ISAPIResource.twoWayAudioClose(channel))
        state = .closed
    }
}
