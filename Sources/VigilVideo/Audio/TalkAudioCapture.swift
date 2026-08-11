//
//  TalkAudioCapture.swift
//  VigilVideo
//
//  Microphone -> device PCM format -> pure Swift G.711 framing for push-to-talk.
//

#if os(macOS)

@preconcurrency import AVFAudio
import Foundation
import VigilProtocols
import VigilRTP

public struct TalkAudioFrame: Sendable, Hashable {
    public let data: Data
    public let rmsLevel: Float

    public init(data: Data, rmsLevel: Float) {
        self.data = data
        self.rmsLevel = rmsLevel
    }
}

public actor TalkAudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var codec: VigilProtocols.AudioCodec = .g711U
    private var sampleRate = 8_000
    private var pending: [Int16] = []
    private var continuation: AsyncStream<TalkAudioFrame>.Continuation?
    private var tapInstalled = false

    public init() {}

    /// Starts lazily, so merely launching Vigil never asks for microphone access.
    public func start(codec: VigilProtocols.AudioCodec,
                      sampleRateHz: Int) throws -> AsyncStream<TalkAudioFrame> {
        stop()
        self.codec = codec
        sampleRate = max(8_000, sampleRateHz)
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: Double(sampleRate),
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw TalkAudioCaptureError.unsupportedFormat
        }
        self.converter = converter
        let (stream, continuation) = AsyncStream<TalkAudioFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(8))
        self.continuation = continuation
        input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
            // AVAudioEngine owns and reuses `buffer` after this callback returns. The actor hop may
            // run later, so it receives an owned copy rather than racing the input render thread.
            guard let owned = Self.copy(buffer) else { return }
            Task { await self?.consume(owned, outputFormat: outputFormat) }
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            self.converter = nil
            self.continuation = nil
            throw error
        }
        return stream
    }

    public func stop() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        converter?.reset()
        converter = nil
        pending.removeAll(keepingCapacity: false)
        continuation?.finish()
        continuation = nil
    }

    private func consume(_ input: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / max(1, input.format.sampleRate)
        let capacity = AVAudioFrameCount(max(1, Int(Double(input.frameLength) * ratio) + 32))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            guard !supplied else {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard conversionError == nil, status != .error,
              let channel = output.int16ChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: channel,
                                                       count: Int(output.frameLength)))
        let samplesPerChunk = max(1, sampleRate / 25) // 40 ms; 320 bytes for 8 kHz G.711.
        while pending.count >= samplesPerChunk {
            let samples = Array(pending.prefix(samplesPerChunk))
            pending.removeFirst(samplesPerChunk)
            continuation?.yield(TalkAudioFrame(data: encode(samples), rmsLevel: rms(samples)))
        }
    }

    private func encode(_ samples: [Int16]) -> Data {
        switch codec {
        case .g711U: G711.encode(samples, law: .muLaw)
        case .g711A: G711.encode(samples, law: .aLaw)
        case .pcmS16LE:
            var data = Data(capacity: samples.count * 2)
            for sample in samples {
                let bits = UInt16(bitPattern: sample)
                data.append(UInt8(truncatingIfNeeded: bits))
                data.append(UInt8(truncatingIfNeeded: bits >> 8))
            }
            return data
        default: return Data()
        }
    }

    private func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let energy = samples.reduce(0.0) { partial, sample in
            let value = Double(sample) / 32_768
            return partial + value * value
        }
        return Float(sqrt(energy / Double(samples.count)))
    }

    private nonisolated static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format,
                                          frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData else { continue }
            let count = Int(min(sourceBuffers[index].mDataByteSize,
                                destinationBuffers[index].mDataByteSize))
            destinationData.copyMemory(from: sourceData, byteCount: count)
            destinationBuffers[index].mDataByteSize = UInt32(count)
        }
        return copy
    }
}

public enum TalkAudioCaptureError: Error { case unsupportedFormat }

#endif
