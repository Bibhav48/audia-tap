import Foundation
import Dispatch
import Darwin
import CoreGraphics

private let permissionDebugEnabled = ProcessInfo.processInfo.environment["AUDIA_TAP_DEBUG"] == "1"
private let agentSocketPath = "/tmp/audia-tap-\(getuid()).sock"

private func permissionDebug(_ message: String) {
    guard permissionDebugEnabled else { return }
    FileHandle.standardError.write(Data("[audia-tap] \(message)\n".utf8))
}

final class SignalRelay {
    private var sources: [DispatchSourceSignal] = []

    func install(handler: @escaping @Sendable (Int32) -> Void) {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                handler(signalNumber)
            }
            source.resume()
            sources.append(source)
        }
    }
}

private enum AudioCapturePermissionStatus: CustomStringConvertible {
    case authorized
    case denied
    case unknown

    var description: String {
        switch self {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .unknown:
            return "unknown"
        }
    }
}

private enum LaunchMode {
    case agent
    case direct(pid_t)
    case viaAgent(pid_t)
    case requestPermission
    case launchedForPermission
}

private func loadTCCSymbol<T>(_ name: String, type: T.Type) -> T? {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
          let symbol = dlsym(handle, name) else {
        permissionDebug("TCC symbol lookup failed for \(name)")
        return nil
    }
    return unsafeBitCast(symbol, to: T.self)
}

private func rawPreflightAudioCapturePermission() -> Int32? {
    typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int32

    guard let preflight = loadTCCSymbol("TCCAccessPreflight", type: PreflightFunc.self) else {
        return nil
    }
    return preflight("kTCCServiceAudioCapture" as CFString, nil)
}

private func mapAudioCapturePermission(rawValue: Int32?) -> AudioCapturePermissionStatus {
    switch rawValue {
    case 0?, 2?:
        return .authorized
    case 1?:
        return .denied
    default:
        return .unknown
    }
}

private func preflightAudioCapturePermission() -> AudioCapturePermissionStatus {
    let raw = rawPreflightAudioCapturePermission()
    permissionDebug("TCCAccessPreflight(AudioCapture) -> \(raw.map(String.init) ?? "nil")")
    return mapAudioCapturePermission(rawValue: raw)
}

private func requestAudioCapturePermission() -> AudioCapturePermissionStatus {
    typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    guard let request = loadTCCSymbol("TCCAccessRequest", type: RequestFunc.self) else {
        return preflightAudioCapturePermission()
    }

    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    request("kTCCServiceAudioCapture" as CFString, nil) { value in
        granted = value
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 30)
    permissionDebug("TCCAccessRequest(AudioCapture) callback -> \(granted)")

    let status = granted ? AudioCapturePermissionStatus.authorized : preflightAudioCapturePermission()
    permissionDebug("AudioCapture permission after request -> \(status)")
    return status
}

private func bundledAppPath() -> String {
    var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    while url.path != "/" {
        if url.pathExtension == "app" {
            return url.path
        }
        url.deleteLastPathComponent()
    }
    // Fallback: look for the .app relative to the project directory
    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    // Walk up to find the project root (parent of dist/)
    var searchURL = execURL
    for _ in 0..<10 {
        let candidate = searchURL.appendingPathComponent("dist/Debug/audia-tap.app")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate.path
        }
        searchURL.deleteLastPathComponent()
    }
    return "audia-tap.app"
}

private func autoLaunchForPermission() throws {
    let appPath = bundledAppPath()
    guard FileManager.default.fileExists(atPath: appPath) else {
        throw "Cannot find audia-tap.app at \(appPath). Build the Xcode project first."
    }

    FileHandle.standardError.write(Data("[audia-tap] Audio Capture permission required. Launching app to request...\n".utf8))

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", appPath, "--args", "--launched-for-permission", "-W"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    try process.run()
    process.waitUntilExit()

    // Wait a moment for TCC database to update
    Thread.sleep(forTimeInterval: 0.5)

    let status = preflightAudioCapturePermission()
    guard status == .authorized else {
        throw "Audio Capture permission was not granted. Please grant permission when prompted and try again."
    }

    FileHandle.standardError.write(Data("[audia-tap] Audio Capture permission granted.\n".utf8))
}

private func ensureAudioCapturePermission() throws {
    switch preflightAudioCapturePermission() {
    case .authorized:
        permissionDebug("Audio Capture permission already authorized.")
        return
    case .denied, .unknown:
        permissionDebug("Audio Capture permission not authorized, attempting auto-launch...")
        try autoLaunchForPermission()
    }
}

private func agentLaunchInstructions() -> String {
    """
    audia-tap agent is not running.
    Start the agent first with: \(CommandLine.arguments[0]) --agent
    Then connect with: \(CommandLine.arguments[0]) --pid <PID>
    """
}

private func parseArguments(arguments: [String]) throws -> LaunchMode {
    var iterator = arguments.dropFirst().makeIterator()
    var requestedPID: pid_t?
    var requestPermissionOnly = false
    var launchedForPermission = false
    var agentMode = false
    var viaAgent = false
    var sawArgument = false

    while let argument = iterator.next() {
        sawArgument = true
        switch argument {
        case "--pid":
            guard let value = iterator.next(), let parsedPID = Int32(value), parsedPID > 0 else {
                throw "Expected a positive integer after --pid"
            }
            requestedPID = parsedPID
        case let value where value.hasPrefix("--pid="):
            let pidString = String(value.dropFirst("--pid=".count))
            guard let parsedPID = Int32(pidString), parsedPID > 0 else {
                throw "Expected a positive integer after --pid="
            }
            requestedPID = parsedPID
        case "--request-permission":
            requestPermissionOnly = true
        case "--launched-for-permission":
            launchedForPermission = true
        case "--agent":
            agentMode = true
        case "--via-agent":
            viaAgent = true
        case "-W":
            // Ignore: passed by `open -W` to wait for app exit
            continue
        default:
            continue
        }
    }

    if requestPermissionOnly && requestedPID != nil {
        throw "Use either --request-permission or --pid <process-id>"
    }
    if agentMode && requestedPID != nil {
        throw "Use either --agent or --pid <process-id>"
    }

    if launchedForPermission {
        return .launchedForPermission
    }
    if requestPermissionOnly {
        return .requestPermission
    }
    if let requestedPID {
        if viaAgent {
            return .viaAgent(requestedPID)
        }
        return .direct(requestedPID)
    }
    if agentMode || !sawArgument {
        return .agent
    }

    throw "Usage: audia-tap --pid <process-id> | --agent | --request-permission"
}

private func setNoSigPipe(fileDescriptor: Int32) {
    var value: Int32 = 1
    _ = withUnsafePointer(to: &value) {
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            $0,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }
}

private func withSocketAddress<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)

    let pathBytes = Array(path.utf8CString)
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= maxPathLength else {
        throw "Socket path too long: \(path)"
    }

    pathBytes.withUnsafeBytes { pathBuffer in
        withUnsafeMutablePointer(to: &address.sun_path) { pathPtr in
            guard let baseAddress = pathBuffer.baseAddress else { return }
            UnsafeMutableRawPointer(pathPtr).copyMemory(from: baseAddress, byteCount: pathBytes.count)
        }
    }

    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    return try withUnsafePointer(to: &address) { addressPtr in
        try addressPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            try body(sockaddrPtr, length)
        }
    }
}

private func writeAll(fileDescriptor: Int32, buffer: UnsafeRawPointer, count: Int) throws {
    var totalWritten = 0
    while totalWritten < count {
        let written = write(fileDescriptor, buffer.advanced(by: totalWritten), count - totalWritten)
        if written > 0 {
            totalWritten += written
            continue
        }
        if written == -1 && errno == EINTR {
            continue
        }
        throw "Socket write failed: \(errno)"
    }
}

private func readRequestLine(fileDescriptor: Int32, maxBytes: Int = 64) throws -> String {
    var bytes = [UInt8]()
    bytes.reserveCapacity(16)

    while bytes.count < maxBytes {
        var value: UInt8 = 0
        let result = read(fileDescriptor, &value, 1)
        if result == 1 {
            if value == 10 {
                break
            }
            bytes.append(value)
            continue
        }
        if result == 0 {
            break
        }
        if errno == EINTR {
            continue
        }
        throw "Socket read failed: \(errno)"
    }

    guard !bytes.isEmpty else {
        throw "Expected PID request from client"
    }

    return String(decoding: bytes, as: UTF8.self)
}

final class AgentServer {
    private let socketPath: String
    private let acceptQueue = DispatchQueue(label: "audia.tap.Agent.Accept", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "audia.tap.Agent.Client", qos: .userInitiated, attributes: .concurrent)

    private var listenerFD: Int32 = -1
    private var running = false

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() throws {
        try setupListener()
        running = true
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
        permissionDebug("Agent listening on \(socketPath)")
    }

    func stop() {
        running = false
        if listenerFD >= 0 {
            close(listenerFD)
            listenerFD = -1
        }
        unlink(socketPath)
    }

    deinit {
        stop()
    }

    private func setupListener() throws {
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw "Failed to create agent socket: \(errno)"
        }

        listenerFD = fd
        setNoSigPipe(fileDescriptor: fd)

        let bindStatus = try withSocketAddress(path: socketPath) { address, length in
            bind(fd, address, length)
        }
        guard bindStatus == 0 else {
            let error = errno
            close(fd)
            listenerFD = -1
            throw "Failed to bind agent socket: \(error)"
        }

        guard listen(fd, 8) == 0 else {
            let error = errno
            close(fd)
            listenerFD = -1
            throw "Failed to listen on agent socket: \(error)"
        }

        chmod(socketPath, 0o600)
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenerFD, nil, nil)
            if clientFD >= 0 {
                setNoSigPipe(fileDescriptor: clientFD)
                clientQueue.async { [weak self] in
                    self?.handleClient(clientFD)
                }
                continue
            }

            if errno == EINTR {
                continue
            }

            if running {
                permissionDebug("accept() failed with errno \(errno)")
            }
            break
        }
    }

    private var activeClients: Int = 0
    private let clientLock = NSLock()

    private func handleClient(_ clientFD: Int32) {
        clientLock.lock()
        activeClients += 1
        clientLock.unlock()

        defer {
            close(clientFD)
            clientLock.lock()
            activeClients -= 1
            let count = activeClients
            clientLock.unlock()
            
            if count == 0 {
                // All clients disconnected, cleanly shut down the background agent
                // to avoid leaving a lingering daemon process.
                permissionDebug("Last client disconnected, shutting down agent.")
                self.stop()
                exit(0)
            }
        }

        do {
            let request = try readRequestLine(fileDescriptor: clientFD)
            guard let requestedPID = Int32(request.trimmingCharacters(in: .whitespacesAndNewlines)), requestedPID > 0 else {
                throw "Expected a positive integer PID request"
            }

            let process = try AudioProcess(pid: requestedPID)
            let stream = try ProcessTapStream(process: process)
            try stream.start()

            let semaphore = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                defer {
                    stream.stop()
                    semaphore.signal()
                }

                do {
                    try await stream.streamPCM16Mono { bytes, byteCount in
                        try writeAll(fileDescriptor: clientFD, buffer: bytes, count: byteCount)
                    }
                } catch {
                    permissionDebug("Agent stream error for pid \(requestedPID): \(error)")
                }
            }
            _ = semaphore.wait(timeout: .distantFuture)
        } catch {
            permissionDebug("Agent request failed: \(error)")
        }
    }
}

private func connectToAgent(socketPath: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw "Failed to create client socket: \(errno)"
    }

    setNoSigPipe(fileDescriptor: fd)
    do {
        let status = try withSocketAddress(path: socketPath) { address, length in
            connect(fd, address, length)
        }
        guard status == 0 else {
            let error = errno
            close(fd)
            if error == ENOENT || error == ECONNREFUSED {
                throw agentLaunchInstructions()
            }
            throw "Failed to connect to audia-tap agent: \(error)"
        }
    } catch {
        close(fd)
        throw error
    }

    return fd
}

private func runClient(pid: pid_t, socketPath: String) throws {
    let fd = try connectToAgent(socketPath: socketPath)
    defer { close(fd) }

    let request = "\(pid)\n"
    try request.utf8.withContiguousStorageIfAvailable { buffer in
        try writeAll(fileDescriptor: fd, buffer: buffer.baseAddress!, count: buffer.count)
    } ?? {
        let data = Data(request.utf8)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            try writeAll(fileDescriptor: fd, buffer: baseAddress, count: rawBuffer.count)
        }
    }()

    let stdout = FileHandle.standardOutput
    var buffer = [UInt8](repeating: 0, count: 16_384)

    while true {
        let bytesRead = read(fd, &buffer, buffer.count)
        if bytesRead > 0 {
            stdout.write(Data(buffer.prefix(bytesRead)))
            continue
        }
        if bytesRead == 0 {
            return
        }
        if errno == EINTR {
            continue
        }
        throw "Failed reading from audia-tap agent: \(errno)"
    }
}
private func killStaleAgents() {
    // Kill any existing audia-tap --agent processes so we don't have overlapping ghosts.
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    proc.arguments = ["-f", "audia-tap --agent"]
    try? proc.run()
    proc.waitUntilExit()
}

private func autoLaunchAgent() throws {
    let appPath = bundledAppPath()
    guard FileManager.default.fileExists(atPath: appPath) else {
        throw "Cannot auto-start agent: audia-tap.app not found at \(appPath). Build the Xcode project first."
    }

    permissionDebug("Auto-launching agent via \(appPath)")

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // -j: launch hidden/background, -g: don't activate (no Dock bounce)
    // -n: launch a fresh instance
    proc.arguments = ["-njg", appPath, "--args", "--agent"]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try proc.run()
}

private func waitForAgentSocket(timeout: TimeInterval = 8.0) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !FileManager.default.fileExists(atPath: agentSocketPath) {
        guard Date() < deadline else {
            throw """
            Timed out waiting for audia-tap agent to start.
            If this persists, verify Screen & System Audio Recording is granted.
            """
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    Thread.sleep(forTimeInterval: 0.2)
    permissionDebug("Agent socket ready at \(agentSocketPath)")
}

private func runDirect(pid: pid_t) throws {
    // 1. Ensure permissions in foreground
    try ensureAudioCapturePermission()

    // 2. Try existing agent socket
    if FileManager.default.fileExists(atPath: agentSocketPath) {
        do {
            permissionDebug("Agent socket found, attempting connection")
            try runClient(pid: pid, socketPath: agentSocketPath)
            return
        } catch {
            permissionDebug("Stale socket detected (\(error)), cleaning up")
        }
    }

    // 3. Stale or missing socket: clean up old processes, wipe socket, launch new
    FileHandle.standardError.write(Data("[audia-tap] Auto-starting background agent...\n".utf8))
    killStaleAgents()
    try? FileManager.default.removeItem(atPath: agentSocketPath)
    
    // 4. Auto-launch the macOS app in the background so it anchors the TCC permissions
    try autoLaunchAgent()
    try waitForAgentSocket()

    // 5. Connect
    try runClient(pid: pid, socketPath: agentSocketPath)
}

do {
    switch try parseArguments(arguments: CommandLine.arguments) {
    case .launchedForPermission:
        // Because of macOS App contexts, we can pre-trigger Screen Recording here natively
        _ = CGRequestScreenCaptureAccess()
        
        let status = requestAudioCapturePermission()
        if status == .authorized {
            FileHandle.standardError.write(Data("[audia-tap] Audio Capture permission granted.\n".utf8))
        } else {
            FileHandle.standardError.write(Data("[audia-tap] Audio Capture permission was denied.\n".utf8))
            exit(1)
        }
    case .requestPermission:
        try ensureAudioCapturePermission()
        FileHandle.standardError.write(Data("Audio Capture permission authorized.\n".utf8))
    case .agent:
        // Agent runs in the background. DO NOT call ensureAudioCapturePermission() here,
        // because it uses 'open -a' which deadlocks Background apps missing AppDelegates!
        // The foreground CLI already handled permissions!
        let server = AgentServer(socketPath: agentSocketPath)
        try server.start()

        let relay = SignalRelay()
        relay.install { _ in
            server.stop()
            exit(0)
        }

        RunLoop.main.run()
    case .direct(let pid):
        try runDirect(pid: pid)
    case .viaAgent(let pid):
        try runClient(pid: pid, socketPath: agentSocketPath)
    }
} catch {
    FileHandle.standardError.write(Data("audia-tap error: \(error)\n".utf8))
    exit(1)
}
