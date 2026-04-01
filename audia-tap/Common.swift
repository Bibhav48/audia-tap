import Foundation
import Darwin

/// Resolves a human-readable name for a given PID, falling back gracefully.
func getProcessName(pid: pid_t, bundleID: String?) -> String {
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
    defer { buffer.deallocate() }
    if proc_name(pid, buffer, UInt32(MAXPATHLEN)) > 0 {
        let name = String(cString: buffer)
        if !name.isEmpty { return name }
    }
    if let bundleID, let last = bundleID.split(separator: ".").last, !last.isEmpty {
        return String(last)
    }
    return "pid-\(pid)"
}

extension UInt32 {
    /// Converts a 4-character code (as UInt32) to a String.
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
