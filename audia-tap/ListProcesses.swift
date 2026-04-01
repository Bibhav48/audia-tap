import Foundation
import AudioToolbox
import Darwin

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
        let name = getProcessName(pid: pid, bundleID: bundleID.isEmpty ? nil : bundleID)
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

        let separator = "\(Console.gray)" + String(repeating: "─", count: pidWidth + nameWidth + bundleWidth + 18) + "\(Console.reset)"
        let header = "  \(Console.bold)\(pad("PID", pidWidth))  \(pad("NAME", nameWidth))  \(pad("BUNDLE ID", bundleWidth))  ACTIVE\(Console.reset)"

        print(separator)
        print(header)
        print(separator)
        for p in processes {
            let active = p.isRunningOutput ? "\(Console.green)▶ yes\(Console.reset)" : "\(Console.gray)  no \(Console.reset)"
            let pid = "\(Console.cyan)\(pad(String(p.pid), pidWidth))\(Console.reset)"
            print("  \(pid)  \(pad(p.name, nameWidth))  \(pad(p.bundleID, bundleWidth))  \(active)")
        }
        print(separator)
        print("  \(Console.bold)\(processes.count)\(Console.reset) process(es) listed. Use \(Console.bold)\(Console.magenta)audia-tap --pid <PID>\(Console.reset) to tap one.")
        print(separator)
    } catch {
        Console.error("Listing processes: \(error)")
        exit(1)
    }
}
