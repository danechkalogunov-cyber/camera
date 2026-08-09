//
//  AudioPlaybackEngine.swift
//  VigilVideo
//
//  Process-wide live audio graph. Camera audio is silent until explicitly unmuted.
//

#if os(macOS)

@preconcurrency import AVFAudio
import AudioToolbox
import Foundation
import VigilProtocols

/// Live audio counters used by the UI level meter and diagnostics.
public struct AudioPlaybackStatistics: Sendable, Hashable {
    public var submittedFrames = 0
    public var droppedFrames = 0
    public var decodeErrors = 0
    public var underruns = 0
    public var peakLevel: Float = 0
    public var rmsLevel: Float = 0

    public init() {}
}

/// One `AVAudioEngine` graph for all live cameras.
///
/// G.711 is already decoded to signed 16-bit PCM by `VigilRTP`; this actor converts that PCM to
/// the common 48 kHz float graph without ever blocking the video path. AAC frames are rejected
/// independently until their decoder can be constructed from a valid magic cookie.
public actor AudioPlaybackEngine {
    private final class Route {
        let player = AVAudioPlayerNode()
        var muted = true
        var scheduledFrames = 0
        var primed = false
        var rampGeneration: UInt32 = 0
        var statistics = AudioPlaybackStatistics()
        var aacDecoder: AACDecoder?
        var aacConfiguration: AudioFormatInfo?
    }

    private final class AACDecoder {
        let converter: AVAudioConverter
        let inputFormat: AVAudioFormat
        let outputFormat: AVAudioFormat

        init?(format: AudioFormatInfo, outputFormat: AVAudioFormat) {
            guard let cookie = format.magicCookie, !cookie.isEmpty else { return nil }
            let objectType = UInt32(cookie[cookie.startIndex] >> 3)
            var description = AudioStreamBasicDescription(
                mSampleRate: Double(format.sampleRate),
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: objectType,
                mBytesPerPacket: 0,
                mFramesPerPacket: UInt32(max(1, format.framesPerPacket)),
                mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(max(1, format.channels)),
                mBitsPerChannel: 0,
                mReserved: 0)
            guard let input = AVAudioFormat(streamDescription: &description) else { return nil }
            input.magicCookie = cookie
            guard let made = AVAudioConverter(from: input, to: outputFormat) else { return nil }
            inputFormat = input
            converter = made
            self.outputFormat = outputFormat
        }

        func decode(_ data: Data) -> AVAudioPCMBuffer? {
            guard !data.isEmpty else { return nil }
            let input = AVAudioCompressedBuffer(format: inputFormat,
                                                packetCapacity: 1,
                                                maximumPacketSize: data.count)
            let outputFrames = max(1, Double(inputFormat.streamDescription.pointee.mFramesPerPacket)
                * outputFormat.sampleRate / inputFormat.sampleRate)
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(outputFrames.rounded(.up) + 32)) else { return nil }
            data.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { input.data.copyMemory(from: base, byteCount: data.count) }
            }
            input.byteLength = UInt32(data.count)
            input.packetCount = 1
            if let descriptions = input.packetDescriptions {
                descriptions[0] = AudioStreamPacketDescription(
                    mStartOffset: 0,
                    mVariableFramesInPacket: 0,
                    mDataByteSize: UInt32(data.count))
            }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard !supplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            guard conversionError == nil, status != .error, output.frameLength > 0 else {
                converter.reset()
                return nil
            }
            return output
        }
    }

    private let engine = AVAudioEngine()
    private let graphFormat: AVAudioFormat?
    private var routes: [StreamKey: Route] = [:]
    private var engineStarted = false
    private let targetFrames = 3_840  // 80 ms at 48 kHz.
    private let maximumFrames = 12_000  // 250 ms at 48 kHz.

    public init() {
        graphFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: 48_000,
                                    channels: 1,
                                    interleaved: false)
    }

    /// Defaults to muted, including after a route is recreated.
    public func isMuted(_ key: StreamKey) -> Bool { routes[key]?.muted ?? true }

    public func setMuted(_ muted: Bool, for key: StreamKey) {
        let route = route(for: key)
        route.muted = muted
        if muted {
            route.rampGeneration &+= 1
            route.player.volume = 0
            route.player.stop()
            route.scheduledFrames = 0
            route.primed = false
        } else {
            startEngineIfNeeded()
            ramp(route.player, to: 1)
        }
    }

    public func muteAll() {
        for route in routes.values {
            route.muted = true
            route.rampGeneration &+= 1
            route.player.volume = 0
            route.player.stop()
            route.scheduledFrames = 0
            route.primed = false
        }
    }

    /// Unmutes one camera and fades every other route out.
    public func solo(_ key: StreamKey) {
        for (candidate, route) in routes {
            route.muted = candidate != key
            if candidate != key {
                fadeOut(route)
            }
        }
        let selected = route(for: key)
        selected.muted = false
        startEngineIfNeeded()
        ramp(selected.player, to: 1)
    }

    /// Accepts an audio frame. Unsupported or malformed audio is counted and discarded locally.
    public func submit(_ frame: EncodedFrame, for key: StreamKey) {
        guard let format = frame.audioFormat else { return }
        let route = route(for: key)
        route.statistics.submittedFrames += 1
        if format.codec == .aac {
            guard let graphFormat else { return }
            if route.aacConfiguration != format {
                route.aacDecoder = AACDecoder(format: format, outputFormat: graphFormat)
                route.aacConfiguration = format
            }
            guard let buffer = route.aacDecoder?.decode(frame.data) else {
                route.statistics.decodeErrors += 1
                return
            }
            if let samples = buffer.floatChannelData?[0] {
                updateLevels(UnsafeBufferPointer(start: samples,
                                                 count: Int(buffer.frameLength)), route: route)
            }
            guard !route.muted else { return }
            schedule(buffer, route: route, key: key)
            return
        }
        guard format.codec == .pcmS16LE else {
            route.statistics.decodeErrors += 1
            return
        }
        let samples = decodePCM(frame.data, channels: max(1, Int(format.channels)))
        updateLevels(samples, route: route)
        guard !route.muted else { return }
        guard route.scheduledFrames < maximumFrames else {
            route.statistics.droppedFrames += 1
            return
        }
        // Keep the queue near 80 ms by changing its fill rate by at most ±0.5 %. This prevents
        // independent device clocks from slowly walking audio away from immediate live video.
        let fillError = Double(targetFrames - route.scheduledFrames) / Double(targetFrames)
        let correction = min(1.005, max(0.995, 1 + fillError * 0.005))
        let resampled = resample(samples, from: Double(format.sampleRate),
                                 to: 48_000 * correction)
        guard !resampled.isEmpty, let graphFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: graphFormat,
                                            frameCapacity: AVAudioFrameCount(resampled.count)),
              let destination = buffer.floatChannelData?[0] else {
            route.statistics.decodeErrors += 1
            return
        }
        resampled.withUnsafeBufferPointer { samples in
            if let base = samples.baseAddress {
                destination.update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(resampled.count)
        schedule(buffer, route: route, key: key)
    }

    public func statistics(for key: StreamKey) -> AudioPlaybackStatistics {
        routes[key]?.statistics ?? AudioPlaybackStatistics()
    }

    public func remove(_ key: StreamKey) {
        guard let route = routes.removeValue(forKey: key) else { return }
        route.player.stop()
        engine.disconnectNodeInput(route.player)
        engine.detach(route.player)
    }

    private func route(for key: StreamKey) -> Route {
        if let existing = routes[key] { return existing }
        let made = Route()
        made.player.volume = 0
        engine.attach(made.player)
        engine.connect(made.player, to: engine.mainMixerNode, format: graphFormat)
        routes[key] = made
        return made
    }

    private func startEngineIfNeeded() {
        guard !engineStarted else { return }
        engine.prepare()
        do {
            try engine.start()
            engineStarted = true
        } catch {
            for route in routes.values { route.statistics.decodeErrors += 1 }
        }
    }

    private func completed(_ count: Int, for key: StreamKey) {
        guard let route = routes[key] else { return }
        route.scheduledFrames = max(0, route.scheduledFrames - count)
        if route.scheduledFrames == 0, route.primed, !route.muted {
            // AVAudioEngine renders silence when a player queue is empty. Count that silence as an
            // underrun and re-prime to 80 ms before resuming; never replay an old buffer.
            route.statistics.underruns += 1
            route.primed = false
            route.player.pause()
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, route: Route, key: StreamKey) {
        let count = Int(buffer.frameLength)
        guard route.scheduledFrames + count <= maximumFrames else {
            route.statistics.droppedFrames += 1
            return
        }
        route.scheduledFrames += count
        startEngineIfNeeded()
        route.player.scheduleBuffer(buffer) { [weak self] in
            Task { await self?.completed(count, for: key) }
        }
        if !route.primed, route.scheduledFrames >= targetFrames {
            route.primed = true
            if !route.player.isPlaying { route.player.play() }
        }
    }

    private func ramp(_ player: AVAudioPlayerNode, to target: Float) {
        // Six small steps over roughly 60 ms avoids the click from a hard mute transition.
        let start = player.volume
        guard let route = routes.values.first(where: { $0.player === player }) else { return }
        route.rampGeneration &+= 1
        let generation = route.rampGeneration
        for step in 1...6 {
            let value = start + (target - start) * Float(step) / 6
            Task {
                try? await Task.sleep(for: .milliseconds(step * 10))
                guard route.rampGeneration == generation else { return }
                player.volume = value
            }
        }
    }

    private func fadeOut(_ route: Route) {
        let start = route.player.volume
        route.rampGeneration &+= 1
        let generation = route.rampGeneration
        for step in 1...6 {
            Task {
                try? await Task.sleep(for: .milliseconds(step * 10))
                guard route.rampGeneration == generation else { return }
                route.player.volume = start * (1 - Float(step) / 6)
                if step == 6 {
                    route.player.stop()
                    route.scheduledFrames = 0
                    route.primed = false
                }
            }
        }
    }

    private func decodePCM(_ data: Data, channels: Int) -> [Float] {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var mono: [Float] = []
            mono.reserveCapacity(sampleCount / channels)
            var index = 0
            while index + channels * 2 <= bytes.count {
                var sum: Int32 = 0
                for channel in 0..<channels {
                    let offset = index + channel * 2
                    let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                    sum += Int32(Int16(bitPattern: bits))
                }
                mono.append(Float(sum) / Float(channels) / 32_768)
                index += channels * 2
            }
            return mono
        }
    }

    private func resample(_ input: [Float], from sourceRate: Double,
                          to destinationRate: Double) -> [Float] {
        guard sourceRate > 0, !input.isEmpty else { return [] }
        if sourceRate == destinationRate { return input }
        let count = max(1, Int((Double(input.count) * destinationRate / sourceRate).rounded()))
        var output = [Float](repeating: 0, count: count)
        let scale = sourceRate / destinationRate
        for index in output.indices {
            let position = Double(index) * scale
            let lower = min(Int(position), input.count - 1)
            let upper = min(lower + 1, input.count - 1)
            let fraction = Float(position - Double(lower))
            output[index] = input[lower] + (input[upper] - input[lower]) * fraction
        }
        return output
    }

    private func updateLevels(_ samples: some Collection<Float>, route: Route) {
        guard !samples.isEmpty else { return }
        var peak: Float = 0
        var energy: Double = 0
        for sample in samples {
            peak = max(peak, abs(sample))
            energy += Double(sample * sample)
        }
        route.statistics.peakLevel = peak
        route.statistics.rmsLevel = Float((energy / Double(samples.count)).squareRoot())
    }
}

#endif
