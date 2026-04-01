import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import OSLog

// MARK: - Output format

enum OutputFormat: String, CaseIterable {
    case pcm16
    case wav
    case f32

    static func parse(_ raw: String) -> OutputFormat? {
        OutputFormat(rawValue: raw.lowercased())
    }

    var description: String { rawValue }
}

// MARK: - WAV header helper

/// Writes a canonical RIFF/WAV header for a streaming (unknown-length) file.
/// Uses 0xFFFFFFFF for the data-chunk and RIFF-chunk sizes (streaming convention).
private func makeWAVHeader(sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> Data {
    var header = Data(capacity: 44)
    let bytesPerSample = UInt32(bitsPerSample / 8)
    let byteRate = sampleRate * UInt32(channels) * bytesPerSample
    let blockAlign = UInt16(channels) * UInt16(bytesPerSample)

    func append32LE(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
    func append16LE(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }

    header.append(contentsOf: "RIFF".utf8)
    append32LE(0xFFFFFFFF)                // chunk size: unknown/streaming
    header.append(contentsOf: "WAVE".utf8)
    header.append(contentsOf: "fmt ".utf8)
    append32LE(16)                        // PCM subchunk size
    append16LE(1)                         // audio format: PCM
    append16LE(channels)
    append32LE(sampleRate)
    append32LE(byteRate)
    append16LE(blockAlign)
    append16LE(bitsPerSample)
    header.append(contentsOf: "data".utf8)
    append32LE(0xFFFFFFFF)                // data size: unknown/streaming

    return header
}

// MARK: - ProcessTapStream

final class ProcessTapStream {
    let process: AudioProcess

    private let logger = Logger(subsystem: "com.audia.tap", category: "ProcessTapStream")
    private let ringBuffer: SPSCFloatRingBuffer
    private let controller: ProcessTapController
    private let controllerQueue = DispatchQueue(label: "audia.tap.ProcessTapStream.Controller")

    private var isStopped = false
    private var streamDebugLogCount = 0

    init(process: AudioProcess, bufferCapacity: Int = 131_072) throws {
        self.process = process
        self.ringBuffer = SPSCFloatRingBuffer(capacity: bufferCapacity)
        let outputUID = try AudioDeviceID.readDefaultOutputDevice().readDeviceUID()
        self.controller = ProcessTapController(
            process: process,
            targetDeviceUID: outputUID,
            ringBuffer: ringBuffer
        )
    }

    var tapSampleRate: Double {
        controller.sampleRate
    }

    func start() throws {
        try controllerQueue.sync {
            try controller.activate()
        }
    }

    func stop() {
        controllerQueue.sync {
            guard !isStopped else { return }
            isStopped = true
            controller.invalidate()
        }
        ringBuffer.clear()
    }

    // MARK: - Streaming entry point

    /// Streams audio to `writeChunk`, honouring all `CLIOptions`.
    func stream(
        options: CLIOptions,
        writeChunk: (UnsafeRawPointer, Int) throws -> Void
    ) async throws {
        switch options.format {
        case .pcm16:
            try await streamConverted(
                destSampleRate: options.sampleRate,
                destChannels: options.channels,
                destFormat: .pcmFormatInt16,
                chunkFrames: options.chunkFrames,
                volume: options.volume,
                silenceThreshold: options.silenceThreshold,
                writeChunk: writeChunk
            )
        case .f32:
            try await streamConverted(
                destSampleRate: options.sampleRate,
                destChannels: options.channels,
                destFormat: .pcmFormatFloat32,
                chunkFrames: options.chunkFrames,
                volume: options.volume,
                silenceThreshold: options.silenceThreshold,
                writeChunk: writeChunk
            )
        case .wav:
            // Write header first
            let sr = UInt32(options.sampleRate)
            let ch = UInt16(options.channels)
            let headerData = makeWAVHeader(sampleRate: sr, channels: ch, bitsPerSample: 16)
            try headerData.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                try writeChunk(base, rawBuffer.count)
            }
            // Then stream PCM16 payload
            try await streamConverted(
                destSampleRate: options.sampleRate,
                destChannels: options.channels,
                destFormat: .pcmFormatInt16,
                chunkFrames: options.chunkFrames,
                volume: options.volume,
                silenceThreshold: options.silenceThreshold,
                writeChunk: writeChunk
            )
        }
    }

    // MARK: - Stdout convenience (used by agent)

    func streamToStdout(options: CLIOptions) async throws {
        try await stream(options: options) { bytes, byteCount in
            FileHandle.standardOutput.write(Data(bytes: bytes, count: byteCount))
        }
    }

    // MARK: - Core conversion loop

    private func streamConverted(
        destSampleRate: Double,
        destChannels: Int,
        destFormat: AVAudioCommonFormat,
        chunkFrames: Int,
        volume: Float,
        silenceThreshold: Float,
        writeChunk: (UnsafeRawPointer, Int) throws -> Void
    ) async throws {
        let sourceSampleRate = controller.tapStreamDescription?.mSampleRate ?? tapSampleRate
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 2,
            interleaved: false
        )!
        let destinationFormat = AVAudioFormat(
            commonFormat: destFormat,
            sampleRate: destSampleRate,
            channels: AVAudioChannelCount(destChannels),
            interleaved: true
        )!

        guard let converter = AVAudioConverter(from: sourceFormat, to: destinationFormat) else {
            throw "Failed to create AVAudioConverter"
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        if destChannels == 1 { converter.downmix = true }

        Console.debug("Stream src sr=\(sourceSampleRate) ch=2 -> dst sr=\(destSampleRate) ch=\(destChannels) fmt=\(destFormat.rawValue) vol=\(volume) gate=\(silenceThreshold)")

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(chunkFrames)
        ) else {
            throw "Failed to allocate input PCM buffer"
        }
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: destinationFormat,
            frameCapacity: AVAudioFrameCount(max(1024, chunkFrames))
        ) else {
            throw "Failed to allocate output PCM buffer"
        }

        let tempLeft  = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
        let tempRight = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
        defer {
            tempLeft.deallocate()
            tempRight.deallocate()
        }

        while true {
            if Task.isCancelled { return }

            let shouldExit = controllerQueue.sync { isStopped && ringBuffer.availableToRead == 0 }
            if shouldExit { return }

            if ringBuffer.availableToRead == 0 {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }

            let framesRead = ringBuffer.read(frames: chunkFrames, intoL: tempLeft, intoR: tempRight)
            if framesRead == 0 {
                try await Task.sleep(nanoseconds: 5_000_000)
                continue
            }

            // Apply volume gain
            if volume != 1.0 {
                for i in 0..<framesRead {
                    tempLeft[i]  *= volume
                    tempRight[i] *= volume
                }
            }

            // Silence gate: compute RMS and skip chunk if below threshold
            if silenceThreshold > 0 {
                var sumSq: Float = 0
                for i in 0..<framesRead {
                    let l = tempLeft[i], r = tempRight[i]
                    sumSq += l * l + r * r
                }
                let rms = (sumSq / Float(framesRead * 2)).squareRoot()
                if rms < silenceThreshold {
                    Console.debug("Silence gate: rms=\(rms) < threshold=\(silenceThreshold), skipping chunk")
                    continue
                }
            }

            if globalVerbose && streamDebugLogCount < 6 {
                var inputPeak: Float = 0
                for i in 0..<min(framesRead, 512) {
                    inputPeak = max(inputPeak, abs(tempLeft[i]), abs(tempRight[i]))
                }
                Console.debug("Ring read frames=\(framesRead) peak=\(inputPeak)")
            }

            inputBuffer.frameLength = AVAudioFrameCount(framesRead)
            if let left = inputBuffer.floatChannelData?[0], let right = inputBuffer.floatChannelData?[1] {
                memcpy(left,  tempLeft,  framesRead * MemoryLayout<Float>.size)
                memcpy(right, tempRight, framesRead * MemoryLayout<Float>.size)
            } else {
                throw "Failed to access input float channel data"
            }

            outputBuffer.frameLength = 0
            var didFeedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if didFeedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                didFeedInput = true
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError { throw conversionError }

            switch status {
            case .haveData, .inputRanDry, .endOfStream:
                let bytesPerFrame = Int(destinationFormat.streamDescription.pointee.mBytesPerFrame)
                let byteCount = Int(outputBuffer.frameLength) * bytesPerFrame
                guard byteCount > 0, let data = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
                    continue
                }
                if globalVerbose && streamDebugLogCount < 6 {
                    Console.debug("PCM write frames=\(outputBuffer.frameLength) bytes=\(byteCount) status=\(status.rawValue)")
                    streamDebugLogCount += 1
                }
                try writeChunk(UnsafeRawPointer(data), byteCount)
            case .error:
                throw "AVAudioConverter returned error status"
            @unknown default:
                logger.warning("Unhandled converter status")
            }
        }
    }

    // MARK: - Legacy agent-protocol entry (PCM16 mono 16kHz, no options)

    /// Used by the agent server to pipe audio to a socket.
    /// Defaults match the original fixed behaviour (PCM16, mono, 16 kHz).
    func streamPCM16Mono(
        chunkFrames: Int = 4096,
        writeChunk: (UnsafeRawPointer, Int) throws -> Void
    ) async throws {
        var opts = CLIOptions()
        opts.format = .pcm16
        opts.sampleRate = 16_000
        opts.channels = 1
        opts.chunkFrames = chunkFrames
        opts.volume = 1.0
        opts.silenceThreshold = 0.0
        try await stream(options: opts, writeChunk: writeChunk)
    }
}
