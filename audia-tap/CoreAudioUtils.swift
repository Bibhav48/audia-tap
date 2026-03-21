import Foundation
import AudioToolbox
import CoreFoundation

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = kAudioObjectUnknown

    var isUnknown: Bool { self == .unknown }
    var isValid: Bool { !isUnknown }

    static func readDefaultOutputDevice() throws -> AudioDeviceID {
        try AudioDeviceID.system.readDefaultOutputDevice()
    }

    static func translatePIDToProcessObjectID(pid: pid_t) throws -> AudioObjectID {
        try AudioDeviceID.system.translatePIDToProcessObjectID(pid: pid)
    }

    static func readProcessList() throws -> [AudioObjectID] {
        try AudioObjectID.system.readProcessList()
    }

    func readDefaultOutputDevice() throws -> AudioDeviceID {
        try requireSystemObject()
        return try read(
            kAudioHardwarePropertyDefaultOutputDevice,
            defaultValue: AudioDeviceID.unknown
        )
    }

    func translatePIDToProcessObjectID(pid: pid_t) throws -> AudioObjectID {
        try requireSystemObject()

        let processObject = try read(
            kAudioHardwarePropertyTranslatePIDToProcessObject,
            defaultValue: AudioObjectID.unknown,
            qualifier: pid
        )

        guard processObject.isValid else {
            throw "Invalid process identifier: \(pid)"
        }

        return processObject
    }

    func readProcessList() throws -> [AudioObjectID] {
        try requireSystemObject()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else {
            throw "Error reading data size for \(address): \(err)"
        }

        var value = [AudioObjectID](
            repeating: .unknown,
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
        )
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value)
        guard err == noErr else {
            throw "Error reading array for \(address): \(err)"
        }

        return value
    }

    func readProcessBundleID() -> String? {
        if let result = try? readString(kAudioProcessPropertyBundleID) {
            return result.isEmpty ? nil : result
        }
        return nil
    }

    func readProcessIsRunningOutput() -> Bool {
        (try? readBool(kAudioProcessPropertyIsRunningOutput)) ?? false
    }

    func readDeviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    func readNominalSampleRate() throws -> Double {
        try read(kAudioDevicePropertyNominalSampleRate, defaultValue: 0.0)
    }

    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }

    private func requireSystemObject() throws {
        guard self == .system else {
            throw "Only supported for the system object."
        }
    }
}

extension AudioObjectID {
    func read<T, Q>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T,
        qualifier: Q
    ) throws -> T {
        try read(
            AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: scope,
                mElement: element
            ),
            defaultValue: defaultValue,
            qualifier: qualifier
        )
    }

    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T
    ) throws -> T {
        try read(
            AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: scope,
                mElement: element
            ),
            defaultValue: defaultValue
        )
    }

    func read<T, Q>(
        _ address: AudioObjectPropertyAddress,
        defaultValue: T,
        qualifier: Q
    ) throws -> T {
        var inQualifier = qualifier
        let qualifierSize = UInt32(MemoryLayout<Q>.size(ofValue: qualifier))
        return try withUnsafeMutablePointer(to: &inQualifier) { qualifierPtr in
            try read(
                address,
                defaultValue: defaultValue,
                inQualifierSize: qualifierSize,
                inQualifierData: qualifierPtr
            )
        }
    }

    func read<T>(_ address: AudioObjectPropertyAddress, defaultValue: T) throws -> T {
        try read(address, defaultValue: defaultValue, inQualifierSize: 0, inQualifierData: nil)
    }

    func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> String {
        try read(
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element),
            defaultValue: "" as CFString
        ) as String
    }

    func readBool(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> Bool {
        let value: UInt32 = try read(
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element),
            defaultValue: UInt32(0)
        )
        return value != 0
    }

    private func read<T>(
        _ inAddress: AudioObjectPropertyAddress,
        defaultValue: T,
        inQualifierSize: UInt32 = 0,
        inQualifierData: UnsafeRawPointer? = nil
    ) throws -> T {
        var address = inAddress
        var dataSize: UInt32 = 0

        var err = AudioObjectGetPropertyDataSize(
            self,
            &address,
            inQualifierSize,
            inQualifierData,
            &dataSize
        )
        guard err == noErr else {
            throw "Error reading data size for \(inAddress): \(err)"
        }

        var value: T = defaultValue
        err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(
                self,
                &address,
                inQualifierSize,
                inQualifierData,
                &dataSize,
                ptr
            )
        }
        guard err == noErr else {
            throw "Error reading data for \(inAddress): \(err)"
        }

        return value
    }
}

extension AudioObjectID {
    func isDeviceAlive() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &isAlive)
        return status == noErr && isAlive != 0
    }

    func waitUntilReady(timeout: TimeInterval = 1.0, pollInterval: TimeInterval = 0.01) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            if isDeviceAlive() {
                return true
            }
            CFRunLoopRunInMode(.defaultMode, pollInterval, false)
        }
        return false
    }
}

private extension UInt32 {
    var fourCharString: String {
        String(cString: [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
            0
        ])
    }
}

extension AudioObjectPropertyAddress: @retroactive CustomStringConvertible {
    public var description: String {
        let elementDescription = mElement == kAudioObjectPropertyElementMain ? "main" : mElement.fourCharString
        return "\(mSelector.fourCharString)/\(mScope.fourCharString)/\(elementDescription)"
    }
}

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { self }
}
