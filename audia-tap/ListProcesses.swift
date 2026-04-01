import Foundation
import AudioToolbox
import Darwin

/// Resolves a human-readable name for a given PID, falling back gracefully.
private func processName(pid: pid_t, bundleID: String?) -> String {
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

struct AudioProcessInfo {
    let pid: pid_t
    let name: String
    let bundleID: String
    let isRunningOutput: Bool
}

/// Returns all processes that the HAL knows about, sorted by PID.
func fetchAudioProcessList() throws -> [AudioProcessInfo] {
    let objectIDs = try AudioObjectID.readProcessList()
    return objectIDs.compactMap { objectID -> AudioProcessInfo? in
        guard let pid = try? objectID.read(kAudioProcessPropertyPID, defaultValue: pid_t(-1)), pid > 0 else {
            return nil
        }
        let bundleID = objectID.readProcessBundleID() ?? ""
        let name = processName(pid: pid, bundleID: bundleID.isEmpty ? nil : bundleID)
        let running = objectID.readProcessIsRunningOutput()
        return AudioProcessInfo(pid: pid, name: name, bundleID: bundleID, isRunningOutput: running)
    }.sorted { $0.pid < $1.pid }
}

/// Prints a neatly formatted table of all audio processes to stdout.
func printAudioProcessList(quiet: Bool) {
    do {
        let processes = try fetchAudioProcessList()
        if processes.isEmpty {
            fputs("No audio processes found.\n", stderr)
            return
        }

        // Column widths
        let pidWidth    = max(5, processes.map { String($0.pid).count }.max() ?? 5)
        let nameWidth   = max(16, processes.map { $0.name.count }.max() ?? 16)
        let bundleWidth = max(20, processes.map { $0.bundleID.count }.max() ?? 20)

        func pad(_ s: String, _ width: Int) -> String {
            s + String(repeating: " ", count: max(0, width - s.count))
        }

        let separator = String(repeating: "─", count: pidWidth + nameWidth + bundleWidth + 18)
        let header = "  \(pad("PID", pidWidth))  \(pad("NAME", nameWidth))  \(pad("BUNDLE ID", bundleWidth))  ACTIVE"

        print(separator)
        print(header)
        print(separator)
        for p in processes {
            let active = p.isRunningOutput ? "▶ yes" : "  no "
            print("  \(pad(String(p.pid), pidWidth))  \(pad(p.name, nameWidth))  \(pad(p.bundleID, bundleWidth))  \(active)")
        }
        print(separator)
        print("  \(processes.count) process(es) listed. Use \u{001B}[1maudia-tap --pid <PID>\u{001B}[0m to tap one.")
        print(separator)
    } catch {
        fputs("audia-tap error listing processes: \(error)\n", stderr)
        exit(1)
    }
}
