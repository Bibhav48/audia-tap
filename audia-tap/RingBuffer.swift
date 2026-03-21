import Foundation

final class SPSCFloatRingBuffer {
    private let capacity: Int64
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var writeIndex: Int64 = 0
    private var readIndex: Int64 = 0

    init(capacity: Int) {
        let resolved = max(1, capacity)
        self.capacity = Int64(resolved)
        self.left = .allocate(capacity: resolved)
        self.right = .allocate(capacity: resolved)
        self.left.initialize(repeating: 0, count: resolved)
        self.right.initialize(repeating: 0, count: resolved)
    }

    deinit {
        left.deinitialize(count: Int(capacity))
        right.deinitialize(count: Int(capacity))
        left.deallocate()
        right.deallocate()
    }

    var availableToRead: Int {
        let write = OSAtomicAdd64Barrier(0, &writeIndex)
        let read = OSAtomicAdd64Barrier(0, &readIndex)
        return Int(max(0, write - read))
    }

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int) {
        guard frames > 0 else { return }

        var read = OSAtomicAdd64Barrier(0, &readIndex)
        let write = OSAtomicAdd64Barrier(0, &writeIndex)
        let used = write - read

        var startOffset = 0
        var toWrite = frames

        if Int64(toWrite) >= capacity {
            startOffset = toWrite - Int(capacity)
            toWrite = Int(capacity)
            if used > 0 {
                _ = OSAtomicAdd64Barrier(used, &readIndex)
                read += (used - (capacity - Int64(toWrite)))
            }
        } else {
            let available = capacity - used
            if Int64(toWrite) > available {
                let overflow = Int64(toWrite) - available
                _ = OSAtomicAdd64Barrier(overflow, &readIndex)
                read += overflow
            }
        }

        guard toWrite > 0 else { return }

        var localWrite = write
        var i = 0
        if let right {
            while i < toWrite {
                let idx = Int(localWrite % capacity)
                let srcIndex = startOffset + i
                self.left[idx] = left[srcIndex]
                self.right[idx] = right[srcIndex]
                localWrite += 1
                i += 1
            }
        } else {
            while i < toWrite {
                let idx = Int(localWrite % capacity)
                let srcIndex = startOffset + i
                self.left[idx] = left[srcIndex]
                self.right[idx] = left[srcIndex]
                localWrite += 1
                i += 1
            }
        }

        OSAtomicAdd64Barrier(Int64(toWrite), &writeIndex)
    }

    @discardableResult
    func read(frames: Int, intoL: UnsafeMutablePointer<Float>, intoR: UnsafeMutablePointer<Float>) -> Int {
        guard frames > 0 else { return 0 }

        let write = OSAtomicAdd64Barrier(0, &writeIndex)
        let read = OSAtomicAdd64Barrier(0, &readIndex)
        let available = write - read
        if available <= 0 {
            memset(intoL, 0, frames * MemoryLayout<Float>.stride)
            memset(intoR, 0, frames * MemoryLayout<Float>.stride)
            return 0
        }

        let toRead = min(Int64(frames), available)
        var localRead = read
        let toReadInt = Int(toRead)

        var i = 0
        while i < toReadInt {
            let idx = Int(localRead % capacity)
            intoL[i] = left[idx]
            intoR[i] = right[idx]
            localRead += 1
            i += 1
        }

        OSAtomicAdd64Barrier(toRead, &readIndex)

        if toReadInt < frames {
            let remaining = frames - toReadInt
            memset(intoL.advanced(by: toReadInt), 0, remaining * MemoryLayout<Float>.stride)
            memset(intoR.advanced(by: toReadInt), 0, remaining * MemoryLayout<Float>.stride)
        }

        return toReadInt
    }

    func clear() {
        let currentWrite = OSAtomicAdd64Barrier(0, &writeIndex)
        let currentRead = OSAtomicAdd64Barrier(0, &readIndex)
        _ = OSAtomicAdd64Barrier(-currentWrite, &writeIndex)
        _ = OSAtomicAdd64Barrier(-currentRead, &readIndex)
    }
}
