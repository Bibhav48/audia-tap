import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import OSLog

private let processTapStreamDebugEnabled = ProcessInfo.processInfo.environment["AUDIA_TAP_DEBUG"] == "1"

private func processTapStreamDebug(_ message: String) {
    guard processTapStreamDebugEnabled else { return }
    FileHandle.standardError.write(Data("[audia-tap] \(message)\n".utf8))
}

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

    func streamPCM16MonoToStdout(chunkFrames: Int = 4096) async throws {
        try await streamPCM16Mono(chunkFrames: chunkFrames) { bytes, byteCount in
            FileHandle.standardOutput.write(Data(bytes: bytes, count: byteCount))
        }
    }

    func streamPCM16Mono(
        chunkFrames: Int = 4096,
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
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!

        guard let converter = AVAudioConverter(from: sourceFormat, to: destinationFormat) else {
            throw "Failed to create AVAudioConverter"
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.downmix = true
        processTapStreamDebug("Stream source sr=\(sourceFormat.sampleRate) ch=\(sourceFormat.channelCount) interleaved=\(sourceFormat.isInterleaved) -> dest sr=\(destinationFormat.sampleRate) ch=\(destinationFormat.channelCount) interleaved=\(destinationFormat.isInterleaved)")

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

        let tempLeft = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
        let tempRight = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
        defer {
            tempLeft.deallocate()
            tempRight.deallocate()
        }

        while true {
            if Task.isCancelled {
                return
            }

            let shouldExit = controllerQueue.sync { isStopped && ringBuffer.availableToRead == 0 }
            if shouldExit {
                return
            }

            if ringBuffer.availableToRead == 0 {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }

            let framesRead = ringBuffer.read(frames: chunkFrames, intoL: tempLeft, intoR: tempRight)
            if framesRead == 0 {
                try await Task.sleep(nanoseconds: 5_000_000)
                continue
            }

            if processTapStreamDebugEnabled && streamDebugLogCount < 6 {
                var inputPeak: Float = 0
                for index in 0..<min(framesRead, 512) {
                    inputPeak = max(inputPeak, abs(tempLeft[index]), abs(tempRight[index]))
                }
                processTapStreamDebug("Ring read frames=\(framesRead) peak=\(inputPeak)")
            }

            inputBuffer.frameLength = AVAudioFrameCount(framesRead)
            if let left = inputBuffer.floatChannelData?[0], let right = inputBuffer.floatChannelData?[1] {
                memcpy(left, tempLeft, framesRead * MemoryLayout<Float>.size)
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

            if let conversionError {
                throw conversionError
            }

            switch status {
            case .haveData, .inputRanDry, .endOfStream:
                let bytesPerFrame = Int(destinationFormat.streamDescription.pointee.mBytesPerFrame)
                let byteCount = Int(outputBuffer.frameLength) * bytesPerFrame
                guard byteCount > 0, let data = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
                    continue
                }
                if processTapStreamDebugEnabled && streamDebugLogCount < 6 {
                    let samples = data.assumingMemoryBound(to: Int16.self)
                    let sampleCount = Int(outputBuffer.frameLength)
                    var outputPeak: Int16 = 0
                    for index in 0..<min(sampleCount, 512) {
                        outputPeak = max(outputPeak, abs(samples[index]))
                    }
                    processTapStreamDebug("PCM write frames=\(outputBuffer.frameLength) bytes=\(byteCount) peak=\(outputPeak) status=\(status.rawValue)")
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
}
