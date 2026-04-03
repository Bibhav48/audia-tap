import Foundation
import AudioToolbox
import Darwin

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
        self.name = getProcessName(pid: resolvedPID, bundleID: bundleID)
    }

    private static func resolveObjectID(for requested: ProcessIdentity) throws -> AudioObjectID {
        Console.debug("Resolving pid \(requested.pid) bundle=\(requested.bundleID ?? "nil") exec=\(requested.executableName)")

        let processObjects = try AudioObjectID.readProcessList()
        let translatedObject = (try? AudioObjectID.translatePIDToProcessObjectID(pid: requested.pid)).flatMap { $0.isValid ? $0 : nil }

        if let translatedObject {
            Console.debug("Resolved via translatePIDToProcessObjectID -> object \(translatedObject)")
        } else {
            Console.debug("translatePIDToProcessObjectID failed for pid \(requested.pid), falling back to HAL process list")
        }

        Console.debug("HAL process list count \(processObjects.count)")
        for objectID in processObjects.prefix(10) {
            let pid = (try? objectID.read(kAudioProcessPropertyPID, defaultValue: pid_t(-1))) ?? -1
            let bundleID = objectID.readProcessBundleID() ?? "nil"
            let running = objectID.readProcessIsRunningOutput()
            Console.debug("raw object=\(objectID) pid=\(pid) running=\(running) bundle=\(bundleID)")
        }

        let candidates = processObjects.compactMap { objectID -> Candidate? in
            let candidatePID = (try? objectID.read(kAudioProcessPropertyPID, defaultValue: pid_t(-1))) ?? -1
            guard candidatePID > 0 else { return nil }

            let bundleID = objectID.readProcessBundleID()
            let isRunningOutput = objectID.readProcessIsRunningOutput()
            let candidateInfo = ProcessIdentity(pid: candidatePID, bundleID: bundleID)
            let score = scoreMatch(requested: requested, candidate: candidateInfo, isRunningOutput: isRunningOutput)
            guard score > 0 else { return nil }

            return Candidate(objectID: objectID, pid: candidatePID, score: score, runningOutput: isRunningOutput, identity: candidateInfo)
        }

        Console.debug("HAL fallback produced \(candidates.count) candidates")
        for candidate in candidates.sorted(by: { $0.score > $1.score }).prefix(5) {
            Console.debug("candidate object=\(candidate.objectID) pid=\(candidate.pid) score=\(candidate.score) running=\(candidate.runningOutput)")
        }

        if let translatedObject {
            let translatedRunning = translatedObject.readProcessIsRunningOutput()
            Console.debug("translated object \(translatedObject) runningOutput=\(translatedRunning)")
            if translatedRunning {
                return translatedObject
            }

            // Browser-style helper models: user may pass the visible app PID, but audio
            // is emitted by a helper PID within the same app family.
            if let bestRunningFamily = bestCandidate(from: candidates, requested: requested, onlyRunningOutput: true, sameFamilyOnly: true) {
                Console.debug("Translated object is not running output; selected running family candidate object \(bestRunningFamily.objectID)")
                return bestRunningFamily.objectID
            }

            if let bestRunning = bestCandidate(from: candidates, requested: requested, onlyRunningOutput: true, sameFamilyOnly: false) {
                Console.debug("Translated object is not running output; selected best running candidate object \(bestRunning.objectID)")
                return bestRunning.objectID
            }

            Console.debug("No running-output candidate found; using translated object \(translatedObject)")
            return translatedObject
        }

        if let best = bestCandidate(from: candidates, requested: requested, onlyRunningOutput: false, sameFamilyOnly: false) {
            Console.debug("Selected object \(best.objectID) for pid \(requested.pid)")
            return best.objectID
        }

        Console.debug("No HAL candidate matched pid \(requested.pid)")
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

    private static func bestCandidate(
        from candidates: [Candidate],
        requested: ProcessIdentity,
        onlyRunningOutput: Bool,
        sameFamilyOnly: Bool
    ) -> Candidate? {
        let filteredRunning = onlyRunningOutput ? candidates.filter(\.runningOutput) : candidates
        let filteredFamily = sameFamilyOnly ? filteredRunning.filter { inSameAppFamily(requested: requested, candidate: $0.identity) } : filteredRunning
        guard !filteredFamily.isEmpty else { return nil }
        return filteredFamily.max(by: { lhs, rhs in
            if lhs.score == rhs.score {
                if lhs.runningOutput != rhs.runningOutput {
                    return !lhs.runningOutput && rhs.runningOutput
                }
                return lhs.pid > rhs.pid
            }
            return lhs.score < rhs.score
        })
    }

    private static func inSameAppFamily(requested: ProcessIdentity, candidate: ProcessIdentity) -> Bool {
        if let requestedRoot = requested.rootAppBundleID, let candidateRoot = candidate.rootAppBundleID {
            return requestedRoot == candidateRoot
        }
        if let requestedBundle = requested.bundleID, let candidateBundle = candidate.bundleID {
            return requestedBundle == candidateBundle
                || requestedBundle.hasPrefix(candidateBundle)
                || candidateBundle.hasPrefix(requestedBundle)
        }
        return false
    }
}

private struct Candidate {
    let objectID: AudioObjectID
    let pid: pid_t
    let score: Int
    let runningOutput: Bool
    let identity: ProcessIdentity
}

private struct ProcessIdentity {
    let pid: pid_t
    let bundleID: String?
    let executableName: String
    let rootAppBundleID: String?

    init(pid: pid_t, bundleID: String? = nil) {
        self.pid = pid
        let path = ProcessIdentity.processPath(pid: pid)
        self.bundleID = bundleID ?? ProcessIdentity.bundleID(fromProcessPath: path)
        self.executableName = ProcessIdentity.executableName(fromProcessPath: path, pid: pid)
        self.rootAppBundleID = ProcessIdentity.rootAppBundleID(fromProcessPath: path)
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

    private static func rootAppBundleID(fromProcessPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        var url = URL(fileURLWithPath: path)
        var lastAppURL: URL?
        while url.path != "/" {
            if url.pathExtension == "app" {
                lastAppURL = url
            }
            url.deleteLastPathComponent()
        }
        guard let rootAppURL = lastAppURL else { return nil }
        return Bundle(url: rootAppURL)?.bundleIdentifier
    }
}
