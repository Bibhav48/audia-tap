import Foundation
import AudioToolbox
import Darwin

private let audioProcessDebugEnabled = ProcessInfo.processInfo.environment["AUDIA_TAP_DEBUG"] == "1"

struct AudioProcess: Hashable, Sendable {
    let id: pid_t
    let name: String
    let bundleID: String?
    let objectID: AudioObjectID

    init(pid: pid_t) throws {
        let requestedInfo = ProcessIdentity(pid: pid)
        let objectID = try AudioProcess.resolveObjectID(for: requestedInfo)
        self.id = pid
        self.objectID = objectID
        let resolvedPID = (try? objectID.read(kAudioProcessPropertyPID, defaultValue: pid)) ?? pid
        self.bundleID = objectID.readProcessBundleID() ?? requestedInfo.bundleID
        self.name = AudioProcess.resolveName(pid: resolvedPID, bundleID: bundleID)
    }

    private static func resolveObjectID(for requested: ProcessIdentity) throws -> AudioObjectID {
        debug("Resolving pid \(requested.pid) bundle=\(requested.bundleID ?? "nil") exec=\(requested.executableName)")

        if let objectID = try? AudioObjectID.translatePIDToProcessObjectID(pid: requested.pid), objectID.isValid {
            debug("Resolved via translatePIDToProcessObjectID -> object \(objectID)")
            return objectID
        }
        debug("translatePIDToProcessObjectID failed for pid \(requested.pid), falling back to HAL process list")

        let processObjects = try AudioObjectID.readProcessList()
        debug("HAL process list count \(processObjects.count)")
        for objectID in processObjects.prefix(10) {
            let pid = (try? objectID.read(kAudioProcessPropertyPID, defaultValue: pid_t(-1))) ?? -1
            let bundleID = objectID.readProcessBundleID() ?? "nil"
            let running = objectID.readProcessIsRunningOutput()
            debug("raw object=\(objectID) pid=\(pid) running=\(running) bundle=\(bundleID)")
        }
        let candidates = processObjects.compactMap { objectID -> Candidate? in
            let candidatePID = (try? objectID.read(kAudioProcessPropertyPID, defaultValue: pid_t(-1))) ?? -1
            guard candidatePID > 0 else { return nil }

            let bundleID = objectID.readProcessBundleID()
            let isRunningOutput = objectID.readProcessIsRunningOutput()
            let candidateInfo = ProcessIdentity(pid: candidatePID, bundleID: bundleID)
            let score = scoreMatch(requested: requested, candidate: candidateInfo, isRunningOutput: isRunningOutput)
            guard score > 0 else { return nil }

            return Candidate(objectID: objectID, pid: candidatePID, score: score)
        }

        debug("HAL fallback produced \(candidates.count) candidates")
        for candidate in candidates.sorted(by: { $0.score > $1.score }).prefix(5) {
            debug("candidate object=\(candidate.objectID) pid=\(candidate.pid) score=\(candidate.score)")
        }

        if let best = candidates.max(by: { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.pid > rhs.pid
            }
            return lhs.score < rhs.score
        }) {
            debug("Selected object \(best.objectID) for pid \(requested.pid)")
            return best.objectID
        }

        debug("No HAL candidate matched pid \(requested.pid)")
        throw "Invalid process identifier: \(requested.pid)"
    }

    private static func scoreMatch(requested: ProcessIdentity, candidate: ProcessIdentity, isRunningOutput: Bool) -> Int {
        var score = 0

        if candidate.pid == requested.pid {
            score += 1_000
        }

        if let requestedBundleID = requested.bundleID, let candidateBundleID = candidate.bundleID {
            if candidateBundleID == requestedBundleID {
                score += 700
            } else if candidateBundleID.hasPrefix(requestedBundleID) || requestedBundleID.hasPrefix(candidateBundleID) {
                score += 500
            }
        }

        if candidate.executableName == requested.executableName {
            score += 300
        } else if candidate.executableName.hasPrefix(requested.executableName) || requested.executableName.hasPrefix(candidate.executableName) {
            score += 150
        }

        if isRunningOutput {
            score += 400
        }

        return score
    }

    private static func resolveName(pid: pid_t, bundleID: String?) -> String {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
        defer { buffer.deallocate() }

        if proc_name(pid, buffer, UInt32(MAXPATHLEN)) > 0 {
            let name = String(cString: buffer)
            if !name.isEmpty {
                return name
            }
        }

        if let bundleID, let last = bundleID.split(separator: ".").last, !last.isEmpty {
            return String(last)
        }

        return "pid-\(pid)"
    }
}

private func debug(_ message: String) {
    guard audioProcessDebugEnabled else { return }
    FileHandle.standardError.write(Data("[audia-tap] \(message)\n".utf8))
}

private struct Candidate {
    let objectID: AudioObjectID
    let pid: pid_t
    let score: Int
}

private struct ProcessIdentity {
    let pid: pid_t
    let bundleID: String?
    let executableName: String

    init(pid: pid_t, bundleID: String? = nil) {
        self.pid = pid
        let path = ProcessIdentity.processPath(pid: pid)
        self.bundleID = bundleID ?? ProcessIdentity.bundleID(fromProcessPath: path)
        self.executableName = ProcessIdentity.executableName(fromProcessPath: path, pid: pid)
    }

    private static func processPath(pid: pid_t) -> String? {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
        defer { buffer.deallocate() }

        guard proc_pidpath(pid, buffer, UInt32(MAXPATHLEN)) > 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    private static func executableName(fromProcessPath path: String?, pid: pid_t) -> String {
        guard let path, !path.isEmpty else {
            return "pid-\(pid)"
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func bundleID(fromProcessPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }

        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if url.pathExtension == "app" {
                return Bundle(url: url)?.bundleIdentifier
            }
            url.deleteLastPathComponent()
        }

        return nil
    }
}
