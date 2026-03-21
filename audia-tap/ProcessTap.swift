import Foundation
import AudioToolbox
import AVFoundation
import OSLog

private let processTapDebugEnabled = ProcessInfo.processInfo.environment["AUDIA_TAP_DEBUG"] == "1"

private func processTapDebug(_ message: String) {
    guard processTapDebugEnabled else { return }
    FileHandle.standardError.write(Data("[audia-tap] \(message)\n".utf8))
}

private extension UInt32 {
    var processTapFourCharString: String {
        String(cString: [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
            0
        ])
    }
}

enum TapError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case deviceNotReady

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            return "Failed to create process tap: \(status)"
        case .aggregateCreationFailed(let status):
            return "Failed to create aggregate device: \(status)"
        case .ioProcCreationFailed(let status):
            return "Failed to create IOProc: \(status)"
        case .deviceStartFailed(let status):
            return "Failed to start aggregate device: \(status)"
        case .deviceNotReady:
            return "Aggregate device did not become ready"
        }
    }
}

final class ProcessTapController {
    let process: AudioProcess

    private let logger = Logger(subsystem: "com.audia.tap", category: "ProcessTapController")
    private let queue = DispatchQueue(label: "audia.tap.ProcessTapController", qos: .userInitiated)
    private let ringBuffer: SPSCFloatRingBuffer
    private let targetDeviceUID: String

    private var processTapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?

    private nonisolated(unsafe) var scratchLeft: UnsafeMutablePointer<Float>?
    private nonisolated(unsafe) var scratchRight: UnsafeMutablePointer<Float>?
    private nonisolated(unsafe) var scratchCapacity: Int = 0
    private nonisolated(unsafe) var didLogCallbackFormat = false
    private nonisolated(unsafe) var callbackPeakLogCount = 0

    private(set) var tapStreamDescription: AudioStreamBasicDescription?
    private(set) var activated = false
    private(set) nonisolated(unsafe) var sampleRate: Double = 48_000

    init(process: AudioProcess, targetDeviceUID: String, ringBuffer: SPSCFloatRingBuffer) {
        self.process = process
        self.targetDeviceUID = targetDeviceUID
        self.ringBuffer = ringBuffer
    }

    func activate() throws {
        guard !activated else { return }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [process.objectID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .muted
        self.tapDescription = tapDescription

        var tapID: AudioObjectID = .unknown
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else {
            throw TapError.tapCreationFailed(status)
        }
        processTapID = tapID
        tapStreamDescription = try? tapID.readAudioTapStreamBasicDescription()
        if let tapStreamDescription {
            processTapDebug("Tap ASBD sr=\(tapStreamDescription.mSampleRate) format=\(tapStreamDescription.mFormatID.processTapFourCharString) flags=\(tapStreamDescription.mFormatFlags) bytesPerFrame=\(tapStreamDescription.mBytesPerFrame) channels=\(tapStreamDescription.mChannelsPerFrame) bits=\(tapStreamDescription.mBitsPerChannel)")
        }

        let aggregateDescription = buildAggregateDescription(
            outputUID: targetDeviceUID,
            tapUUID: tapDescription.uuid,
            name: "audia-tap-\(process.id)"
        )

        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID)
        guard status == noErr else {
            cleanupPartialActivation()
            throw TapError.aggregateCreationFailed(status)
        }

        guard aggregateDeviceID.waitUntilReady(timeout: 2.0) else {
            cleanupPartialActivation()
            throw TapError.deviceNotReady
        }

        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate(), deviceSampleRate > 0 {
            sampleRate = deviceSampleRate
        }

        status = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            self.processAudio(inInputData, to: outOutputData)
        }
        guard status == noErr else {
            cleanupPartialActivation()
            throw TapError.ioProcCreationFailed(status)
        }

        status = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard status == noErr else {
            cleanupPartialActivation()
            throw TapError.deviceStartFailed(status)
        }

        activated = true
        logger.info("Activated tap for pid \(self.process.id, privacy: .public)")
    }

    func invalidate() {
        guard activated || processTapID.isValid || aggregateDeviceID.isValid else { return }
        activated = false

        if aggregateDeviceID.isValid {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if let deviceProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }

        if processTapID.isValid {
            AudioHardwareDestroyProcessTap(processTapID)
        }

        deviceProcID = nil
        aggregateDeviceID = .unknown
        processTapID = .unknown
        tapDescription = nil

        if let scratchLeft {
            scratchLeft.deallocate()
            self.scratchLeft = nil
        }
        if let scratchRight {
            scratchRight.deallocate()
            self.scratchRight = nil
        }
        scratchCapacity = 0
    }

    deinit {
        invalidate()
    }

    private func buildAggregateDescription(outputUID: String, tapUUID: UUID, name: String) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: false
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]
    }

    private func cleanupPartialActivation() {
        if let deviceProcID, aggregateDeviceID.isValid {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
            self.deviceProcID = nil
        }
        if aggregateDeviceID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }
        if processTapID.isValid {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = .unknown
        }
    }

    private func processAudio(
        _ inputBufferList: UnsafePointer<AudioBufferList>,
        to outputBufferList: UnsafeMutablePointer<AudioBufferList>
    ) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))

        if !didLogCallbackFormat {
            didLogCallbackFormat = true
            let inputSummary = inputBuffers.enumerated().map { index, buffer in
                "in[\(index)] bytes=\(buffer.mDataByteSize) ch=\(buffer.mNumberChannels)"
            }.joined(separator: " ")
            let outputSummary = outputBuffers.enumerated().map { index, buffer in
                "out[\(index)] bytes=\(buffer.mDataByteSize) ch=\(buffer.mNumberChannels)"
            }.joined(separator: " ")
            processTapDebug("Callback buffers \(inputSummary) \(outputSummary)")
        }

        if processTapDebugEnabled && callbackPeakLogCount < 4 {
            let inputPeak = rawInputPeak(from: inputBuffers)
            processTapDebug("Callback input peak=\(inputPeak)")
        }

        for outputIndex in 0..<outputBuffers.count {
            let outputBuffer = outputBuffers[outputIndex]
            guard let outputData = outputBuffer.mData else { continue }

            let inputIndex: Int
            if inputBuffers.count > outputBuffers.count {
                inputIndex = inputBuffers.count - outputBuffers.count + outputIndex
            } else {
                inputIndex = outputIndex
            }

            guard inputIndex < inputBuffers.count else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputBuffer = inputBuffers[inputIndex]
            guard let inputData = inputBuffer.mData else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            memcpy(outputData, inputData, Int(min(inputBuffer.mDataByteSize, outputBuffer.mDataByteSize)))
        }

        if outputBuffers.count >= 2 {
            if let leftData = outputBuffers[0].mData, let rightData = outputBuffers[1].mData {
                let leftFloats = leftData.assumingMemoryBound(to: Float.self)
                let rightFloats = rightData.assumingMemoryBound(to: Float.self)
                let frames = Int(outputBuffers[0].mDataByteSize) / MemoryLayout<Float>.size
                if processTapDebugEnabled && frames > 0 && callbackPeakLogCount < 4 {
                    var peak: Float = 0
                    for frame in 0..<min(frames, 512) {
                        peak = max(peak, abs(leftFloats[frame]), abs(rightFloats[frame]))
                    }
                    processTapDebug("Callback planar write frames=\(frames) peak=\(peak)")
                    callbackPeakLogCount += 1
                }
                ringBuffer.write(left: leftFloats, right: rightFloats, frames: frames)
            }
            return
        }

        guard outputBuffers.count == 1, let data = outputBuffers[0].mData else { return }
        let floats = data.assumingMemoryBound(to: Float.self)
        let totalSamples = Int(outputBuffers[0].mDataByteSize) / MemoryLayout<Float>.size
        let channelCount = max(1, Int(outputBuffers[0].mNumberChannels))
        guard channelCount >= 2 else {
            ringBuffer.write(left: UnsafePointer(floats), right: nil, frames: totalSamples)
            return
        }

        let frames = totalSamples / channelCount
        ensureScratchCapacity(frames)
        guard let scratchLeft, let scratchRight else { return }

        for frame in 0..<frames {
            scratchLeft[frame] = floats[frame * channelCount]
            scratchRight[frame] = floats[(frame * channelCount) + 1]
        }

        if processTapDebugEnabled && frames > 0 && callbackPeakLogCount < 4 {
            var peak: Float = 0
            for frame in 0..<min(frames, 512) {
                peak = max(peak, abs(scratchLeft[frame]), abs(scratchRight[frame]))
            }
            processTapDebug("Callback interleaved write frames=\(frames) channels=\(channelCount) peak=\(peak)")
            callbackPeakLogCount += 1
        }

        ringBuffer.write(left: scratchLeft, right: scratchRight, frames: frames)
    }

    private func ensureScratchCapacity(_ frames: Int) {
        guard frames > scratchCapacity else { return }

        if let scratchLeft {
            scratchLeft.deallocate()
        }
        if let scratchRight {
            scratchRight.deallocate()
        }

        let newCapacity = frames + 1024
        scratchLeft = UnsafeMutablePointer<Float>.allocate(capacity: newCapacity)
        scratchRight = UnsafeMutablePointer<Float>.allocate(capacity: newCapacity)
        scratchCapacity = newCapacity
    }

    private func rawInputPeak(from buffers: UnsafeMutableAudioBufferListPointer) -> Float {
        guard !buffers.isEmpty else { return 0 }

        if buffers.count >= 2,
           let leftData = buffers[0].mData,
           let rightData = buffers[1].mData {
            let leftFloats = leftData.assumingMemoryBound(to: Float.self)
            let rightFloats = rightData.assumingMemoryBound(to: Float.self)
            let frames = Int(min(buffers[0].mDataByteSize, buffers[1].mDataByteSize)) / MemoryLayout<Float>.size
            var peak: Float = 0
            for frame in 0..<min(frames, 512) {
                peak = max(peak, abs(leftFloats[frame]), abs(rightFloats[frame]))
            }
            return peak
        }

        guard let data = buffers[0].mData else { return 0 }
        let floats = data.assumingMemoryBound(to: Float.self)
        let channelCount = max(1, Int(buffers[0].mNumberChannels))
        let totalSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        let frames = totalSamples / channelCount
        var peak: Float = 0
        for frame in 0..<min(frames, 512) {
            peak = max(peak, abs(floats[frame * channelCount]))
            if channelCount > 1 {
                peak = max(peak, abs(floats[(frame * channelCount) + 1]))
            }
        }
        return peak
    }
}
