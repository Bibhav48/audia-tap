import Foundation
import Dispatch
import Darwin
import CoreGraphics

// MARK: - Version

private let audiaVersion = "1.1.0"

// MARK: - Debug / quiet

/// Global verbose flag (set by --verbose / -v or AUDIA_TAP_DEBUG=1 env var).
var globalVerbose: Bool = ProcessInfo.processInfo.environment["AUDIA_TAP_DEBUG"] == "1"
/// Global quiet flag (set by --quiet / -q). Suppresses informational stderr messages.
var globalQuiet: Bool = false

private func debugLog(_ message: String) {
    guard globalVerbose else { return }
    fputs("[audia-tap] \(message)\n", stderr)
}

private func infoLog(_ message: String) {
    guard !globalQuiet else { return }
    fputs("[audia-tap] \(message)\n", stderr)
}

// MARK: - Options

/// All user-configurable options parsed from the command line.
struct CLIOptions {
    var format: OutputFormat       = .pcm16
    var sampleRate: Double         = 16_000
    var channels: Int              = 1
    var outputPath: String?        = nil      // nil → stdout
    var duration: Double?          = nil      // nil → unlimited
    var volume: Float              = 1.0
    var silenceThreshold: Float    = 0.0      // 0 → disabled
    var jsonInfo: Bool             = false
    var verbose: Bool              = false
    var quiet: Bool                = false
    var chunkFrames: Int           = 4096
    var agentTimeout: Double       = 8.0
    var socketPath: String         = "/tmp/audia-tap-\(getuid()).sock"
}

// MARK: - Launch mode

private enum LaunchMode {
    case agent
    case direct(pid_t, CLIOptions)
    case viaAgent(pid_t, CLIOptions)
    case list
    case requestPermission
    case launchedForPermission
    case help
    case version
}

// MARK: - Signal relay

final class SignalRelay {
    private var sources: [DispatchSourceSignal] = []

    func install(handler: @escaping @Sendable (Int32) -> Void) {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInteractive))
            source.setEventHandler {
                handler(signalNumber)
            }
            source.resume()
            sources.append(source)
        }
    }
}

// MARK: - Help / version

private func printHelp() {
    print("""
    \u{001B}[1maudia-tap\u{001B}[0m \(audiaVersion) — driverless per-process audio tap for macOS

    \u{001B}[1mUSAGE\u{001B}[0m
      audia-tap [OPTIONS] --pid <PID>
      audia-tap [OPTIONS] --app <NAME>
      audia-tap --list
      audia-tap --agent

    \u{001B}[1mTARGET SELECTION\u{001B}[0m
      --pid  <PID>         Tap the process with this process ID
      --app  <NAME>        Tap the first process whose name matches NAME (case-insensitive)
      --list, -l           List all active audio processes and exit

    \u{001B}[1mOUTPUT FORMAT\u{001B}[0m
      --format <fmt>       Output format: pcm16 (default), wav, f32
                             pcm16  Raw signed 16-bit PCM (little-endian)
                             wav    PCM16 with a streaming RIFF/WAV header prepended
                             f32    Raw 32-bit float PCM
      --sample-rate <hz>   Destination sample rate in Hz (default: 16000)
      --channels <n>       Output channels: 1 = mono (default), 2 = stereo

    \u{001B}[1mOUTPUT DESTINATION\u{001B}[0m
      --output <path>, -o  Write audio to a file instead of stdout
      --duration <secs>    Automatically stop after N seconds

    \u{001B}[1mAUDIO PROCESSING\u{001B}[0m
      --volume <gain>      Linear gain multiplier applied before conversion (default: 1.0)
      --silence-threshold  RMS level below which chunks are dropped (default: 0, off)
        <rms>              Example: 0.01 silences background hiss

    \u{001B}[1mMETADATA\u{001B}[0m
      --json-info          Print a JSON object with stream metadata to stderr before
                           audio begins (pid, name, sampleRate, channels, format)

    \u{001B}[1mAGENT & DAEMON\u{001B}[0m
      --agent              Run as a background permission-anchoring agent (internal use)
      --via-agent          Connect directly to a running agent without auto-launching
      --agent-socket <p>   Override the Unix socket path (default: /tmp/audia-tap-<uid>.sock)
      --timeout <secs>     Seconds to wait for agent socket to appear (default: 8)

    \u{001B}[1mDEBUGGING\u{001B}[0m
      --verbose, -v        Enable verbose debug output on stderr (alias for AUDIA_TAP_DEBUG=1)
      --quiet,   -q        Suppress all informational stderr messages

    \u{001B}[1mMISCELLANEOUS\u{001B}[0m
      --request-permission Request Audio Capture permission and exit
      --chunk-frames <n>   Internal ring-buffer chunk size in frames (default: 4096)
      --help,    -h        Show this help message and exit
      --version            Print version and exit

    \u{001B}[1mEXAMPLES\u{001B}[0m
      # List all processes that are producing audio
      audia-tap --list

      # Tap Safari and pipe to Whisper
      audia-tap --pid $(pgrep Safari) | python3 Scripts/whisper_demo.py /dev/stdin

      # Tap Spotify by name, output stereo WAV at 44.1 kHz, save to file
      audia-tap --app Spotify --format wav --sample-rate 44100 --channels 2 -o spotify.wav

      # Tap Zoom, boost volume 1.5×, suppress silence, run for 60 seconds
      audia-tap --app Zoom --volume 1.5 --silence-threshold 0.01 --duration 60

      # Inspect stream metadata as JSON before piping
      audia-tap --pid 1234 --json-info --quiet | python3 my_model.py
    """)
}

private func printVersion() {
    print("audia-tap \(audiaVersion)")
}

// MARK: - Argument parsing

private func parseArguments(arguments: [String]) throws -> LaunchMode {
    var iterator = arguments.dropFirst().makeIterator()
    var options  = CLIOptions()

    var requestedPID: pid_t?
    var appName: String?
    var requestPermissionOnly   = false
    var launchedForPermission   = false
    var agentMode               = false
    var viaAgent                = false
    var listMode                = false
    var helpMode                = false
    var versionMode             = false
    var sawArgument             = false

    while let argument = iterator.next() {
        sawArgument = true
        switch argument {

        // ── Target selection ──────────────────────────────────────────────
        case "--pid":
            guard let value = iterator.next(), let pid = Int32(value), pid > 0 else {
                throw "Expected a positive integer after --pid"
            }
            requestedPID = pid
        case let v where v.hasPrefix("--pid="):
            let s = String(v.dropFirst("--pid=".count))
            guard let pid = Int32(s), pid > 0 else { throw "Expected a positive integer after --pid=" }
            requestedPID = pid

        case "--app":
            guard let name = iterator.next(), !name.isEmpty else { throw "Expected a process name after --app" }
            appName = name
        case let v where v.hasPrefix("--app="):
            let name = String(v.dropFirst("--app=".count))
            guard !name.isEmpty else { throw "Expected a process name after --app=" }
            appName = name

        case "--list", "-l":
            listMode = true

        // ── Output format ─────────────────────────────────────────────────
        case "--format":
            guard let raw = iterator.next(), let fmt = OutputFormat.parse(raw) else {
                throw "Expected pcm16, wav, or f32 after --format"
            }
            options.format = fmt
        case let v where v.hasPrefix("--format="):
            let raw = String(v.dropFirst("--format=".count))
            guard let fmt = OutputFormat.parse(raw) else { throw "Unknown format '\(raw)'. Choose pcm16, wav, or f32." }
            options.format = fmt

        case "--sample-rate":
            guard let raw = iterator.next(), let hz = Double(raw), hz > 0 else {
                throw "Expected a positive number after --sample-rate"
            }
            options.sampleRate = hz
        case let v where v.hasPrefix("--sample-rate="):
            let raw = String(v.dropFirst("--sample-rate=".count))
            guard let hz = Double(raw), hz > 0 else { throw "Expected a positive number after --sample-rate=" }
            options.sampleRate = hz

        case "--channels":
            guard let raw = iterator.next(), let ch = Int(raw), ch == 1 || ch == 2 else {
                throw "Expected 1 or 2 after --channels"
            }
            options.channels = ch
        case let v where v.hasPrefix("--channels="):
            let raw = String(v.dropFirst("--channels=".count))
            guard let ch = Int(raw), ch == 1 || ch == 2 else { throw "Expected 1 or 2 after --channels=" }
            options.channels = ch

        // ── Output destination ────────────────────────────────────────────
        case "--output", "-o":
            guard let path = iterator.next(), !path.isEmpty else { throw "Expected a file path after --output" }
            options.outputPath = path
        case let v where v.hasPrefix("--output="):
            options.outputPath = String(v.dropFirst("--output=".count))

        case "--duration":
            guard let raw = iterator.next(), let secs = Double(raw), secs > 0 else {
                throw "Expected a positive number of seconds after --duration"
            }
            options.duration = secs
        case let v where v.hasPrefix("--duration="):
            let raw = String(v.dropFirst("--duration=".count))
            guard let secs = Double(raw), secs > 0 else { throw "Expected a positive number after --duration=" }
            options.duration = secs

        // ── Audio processing ──────────────────────────────────────────────
        case "--volume":
            guard let raw = iterator.next(), let gain = Float(raw), gain >= 0 else {
                throw "Expected a non-negative number after --volume"
            }
            options.volume = gain
        case let v where v.hasPrefix("--volume="):
            let raw = String(v.dropFirst("--volume=".count))
            guard let gain = Float(raw), gain >= 0 else { throw "Expected a non-negative number after --volume=" }
            options.volume = gain

        case "--silence-threshold":
            guard let raw = iterator.next(), let rms = Float(raw), rms >= 0 else {
                throw "Expected a non-negative RMS value after --silence-threshold"
            }
            options.silenceThreshold = rms
        case let v where v.hasPrefix("--silence-threshold="):
            let raw = String(v.dropFirst("--silence-threshold=".count))
            guard let rms = Float(raw), rms >= 0 else { throw "Expected a non-negative value after --silence-threshold=" }
            options.silenceThreshold = rms

        // ── Metadata ──────────────────────────────────────────────────────
        case "--json-info":
            options.jsonInfo = true

        // ── Agent / daemon ────────────────────────────────────────────────
        case "--agent":
            agentMode = true
        case "--via-agent":
            viaAgent = true

        case "--agent-socket":
            guard let path = iterator.next(), !path.isEmpty else { throw "Expected a path after --agent-socket" }
            options.socketPath = path
        case let v where v.hasPrefix("--agent-socket="):
            options.socketPath = String(v.dropFirst("--agent-socket=".count))

        case "--timeout":
            guard let raw = iterator.next(), let secs = Double(raw), secs > 0 else {
                throw "Expected a positive number after --timeout"
            }
            options.agentTimeout = secs
        case let v where v.hasPrefix("--timeout="):
            let raw = String(v.dropFirst("--timeout=".count))
            guard let secs = Double(raw), secs > 0 else { throw "Expected a positive number after --timeout=" }
            options.agentTimeout = secs

        // ── Debugging ─────────────────────────────────────────────────────
        case "--verbose", "-v":
            options.verbose = true
        case "--quiet", "-q":
            options.quiet = true

        // ── Misc ──────────────────────────────────────────────────────────
        case "--request-permission":
            requestPermissionOnly = true
        case "--launched-for-permission":
            launchedForPermission = true
        case "--chunk-frames":
            guard let raw = iterator.next(), let n = Int(raw), n > 0 else {
                throw "Expected a positive integer after --chunk-frames"
            }
            options.chunkFrames = n
        case let v where v.hasPrefix("--chunk-frames="):
            let raw = String(v.dropFirst("--chunk-frames=".count))
            guard let n = Int(raw), n > 0 else { throw "Expected a positive integer after --chunk-frames=" }
            options.chunkFrames = n

        case "--help", "-h":
            helpMode = true
        case "--version":
            versionMode = true

        case "-W":
            // Passed by `open -W`; ignore silently
            continue

        default:
            throw "Unknown argument '\(argument)'. Run audia-tap --help for usage."
        }
    }

    // ── Validate ───────────────────────────────────────────────────────────
    if requestedPID != nil && appName != nil {
        throw "Use either --pid or --app, not both."
    }
    if requestPermissionOnly && (requestedPID != nil || appName != nil) {
        throw "Use either --request-permission or a target flag (--pid / --app)."
    }
    if agentMode && (requestedPID != nil || appName != nil) {
        throw "Use either --agent or a target flag (--pid / --app)."
    }

    // ── Apply verbose/quiet globally ───────────────────────────────────────
    if options.verbose { globalVerbose = true }
    if options.quiet   { globalQuiet   = true }

    // ── Resolve mode ───────────────────────────────────────────────────────
    if helpMode               { return .help }
    if versionMode            { return .version }
    if listMode               { return .list }
    if launchedForPermission  { return .launchedForPermission }
    if requestPermissionOnly  { return .requestPermission }

    if let name = appName {
        let pid = try resolveAppNameToPID(name)
        return viaAgent ? .viaAgent(pid, options) : .direct(pid, options)
    }
    if let pid = requestedPID {
        return viaAgent ? .viaAgent(pid, options) : .direct(pid, options)
    }
    if agentMode || !sawArgument {
        return .agent
    }

    throw "No target specified. Run audia-tap --help for usage."
}

// MARK: - App name resolution

/// Walks the HAL process list and returns the PID of the first process whose
/// name (or bundle ID component) case-insensitively contains `name`.
private func resolveAppNameToPID(_ name: String) throws -> pid_t {
    let processes = try fetchAudioProcessList()
    let lower = name.lowercased()
    if let match = processes.first(where: {
        $0.name.lowercased().contains(lower) || $0.bundleID.lowercased().contains(lower)
    }) {
        debugLog("Resolved --app '\(name)' to pid \(match.pid) (\(match.name))")
        return match.pid
    }
    throw "No audio process found matching '\(name)'. Run audia-tap --list to see available processes."
}

// MARK: - Permissions

private enum AudioCapturePermissionStatus: CustomStringConvertible, Equatable {
    case authorized
    case denied
    case unknown

    var description: String {
        switch self {
        case .authorized: return "authorized"
        case .denied:     return "denied"
        case .unknown:    return "unknown"
        }
    }
}

private func loadTCCSymbol<T>(_ name: String, type: T.Type) -> T? {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
          let symbol = dlsym(handle, name) else {
        debugLog("TCC symbol lookup failed for \(name)")
        return nil
    }
    return unsafeBitCast(symbol, to: T.self)
}

private func rawPreflightAudioCapturePermission() -> Int32? {
    typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int32
    guard let preflight = loadTCCSymbol("TCCAccessPreflight", type: PreflightFunc.self) else { return nil }
    return preflight("kTCCServiceAudioCapture" as CFString, nil)
}

private func mapAudioCapturePermission(rawValue: Int32?) -> AudioCapturePermissionStatus {
    switch rawValue {
    case 0?, 2?: return .authorized
    case 1?:     return .denied
    default:     return .unknown
    }
}

private func preflightAudioCapturePermission() -> AudioCapturePermissionStatus {
    let raw = rawPreflightAudioCapturePermission()
    debugLog("TCCAccessPreflight(AudioCapture) -> \(raw.map(String.init) ?? "nil")")
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
    debugLog("TCCAccessRequest(AudioCapture) callback -> \(granted)")

    let status = granted ? AudioCapturePermissionStatus.authorized : preflightAudioCapturePermission()
    debugLog("AudioCapture permission after request -> \(status)")
    return status
}

private func bundledAppPath() -> String {
    var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    while url.path != "/" {
        if url.pathExtension == "app" { return url.path }
        url.deleteLastPathComponent()
    }
    var searchURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    for _ in 0..<10 {
        let candidate = searchURL.appendingPathComponent("dist/Debug/audia-tap.app")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        searchURL.deleteLastPathComponent()
    }
    return "audia-tap.app"
}

private func autoLaunchForPermission() throws {
    let appPath = bundledAppPath()
    guard FileManager.default.fileExists(atPath: appPath) else {
        throw "Cannot find audia-tap.app at \(appPath). Build the Xcode project first."
    }
    infoLog("Audio Capture permission required. Launching app to request...")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", appPath, "--args", "--launched-for-permission", "-W"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError  = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    Thread.sleep(forTimeInterval: 0.5)
    let status = preflightAudioCapturePermission()
    guard status == .authorized else {
        throw "Audio Capture permission was not granted. Please grant permission when prompted and try again."
    }
    infoLog("Audio Capture permission granted.")
}

private func ensureAudioCapturePermission() throws {
    switch preflightAudioCapturePermission() {
    case .authorized:
        debugLog("Audio Capture permission already authorized.")
    case .denied, .unknown:
        debugLog("Audio Capture permission not authorized, attempting auto-launch...")
        try autoLaunchForPermission()
    }
}

// MARK: - Socket helpers

private func setNoSigPipe(fileDescriptor: Int32) {
    var value: Int32 = 1
    _ = withUnsafePointer(to: &value) {
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
    }
}

private func withSocketAddress<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= maxPathLength else { throw "Socket path too long: \(path)" }
    pathBytes.withUnsafeBytes { pathBuffer in
        withUnsafeMutablePointer(to: &address.sun_path) { pathPtr in
            guard let base = pathBuffer.baseAddress else { return }
            UnsafeMutableRawPointer(pathPtr).copyMemory(from: base, byteCount: pathBytes.count)
        }
    }
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    return try withUnsafePointer(to: &address) { addrPtr in
        try addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            try body(sockaddrPtr, length)
        }
    }
}

private func writeAll(fileDescriptor: Int32, buffer: UnsafeRawPointer, count: Int) throws {
    var totalWritten = 0
    while totalWritten < count {
        let written = write(fileDescriptor, buffer.advanced(by: totalWritten), count - totalWritten)
        if written > 0 { totalWritten += written; continue }
        if written == -1 && errno == EINTR { continue }
        throw "Socket write failed: \(errno)"
    }
}

private func readRequestLine(fileDescriptor: Int32, maxBytes: Int = 64) throws -> String {
    var bytes = [UInt8]()
    bytes.reserveCapacity(16)
    while bytes.count < maxBytes {
        var value: UInt8 = 0
        let result = read(fileDescriptor, &value, 1)
        if result == 1 { if value == 10 { break }; bytes.append(value); continue }
        if result == 0 { break }
        if errno == EINTR { continue }
        throw "Socket read failed: \(errno)"
    }
    guard !bytes.isEmpty else { throw "Expected PID request from client" }
    return String(decoding: bytes, as: UTF8.self)
}

// MARK: - Agent server

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
        acceptQueue.async { [weak self] in self?.acceptLoop() }
        debugLog("Agent listening on \(socketPath)")
    }

    func stop() {
        running = false
        if listenerFD >= 0 { close(listenerFD); listenerFD = -1 }
        unlink(socketPath)
    }

    deinit { stop() }

    private func setupListener() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw "Failed to create agent socket: \(errno)" }
        listenerFD = fd
        setNoSigPipe(fileDescriptor: fd)
        let bindStatus = try withSocketAddress(path: socketPath) { address, length in bind(fd, address, length) }
        guard bindStatus == 0 else {
            let error = errno; close(fd); listenerFD = -1
            throw "Failed to bind agent socket: \(error)"
        }
        guard listen(fd, 8) == 0 else {
            let error = errno; close(fd); listenerFD = -1
            throw "Failed to listen on agent socket: \(error)"
        }
        chmod(socketPath, 0o600)
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenerFD, nil, nil)
            if clientFD >= 0 {
                setNoSigPipe(fileDescriptor: clientFD)
                clientQueue.async { [weak self] in self?.handleClient(clientFD) }
                continue
            }
            if errno == EINTR { continue }
            if running { debugLog("accept() failed with errno \(errno)") }
            break
        }
    }

    private var activeClients: Int = 0
    private let clientLock = NSLock()

    private func handleClient(_ clientFD: Int32) {
        clientLock.lock(); activeClients += 1; clientLock.unlock()
        defer {
            close(clientFD)
            clientLock.lock(); activeClients -= 1; let count = activeClients; clientLock.unlock()
            if count == 0 {
                debugLog("Last client disconnected, shutting down agent.")
                self.stop(); exit(0)
            }
        }
        do {
            let request = try readRequestLine(fileDescriptor: clientFD)
            guard let pid = Int32(request.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
                throw "Expected a positive integer PID request"
            }
            let process = try AudioProcess(pid: pid)
            let stream  = try ProcessTapStream(process: process)
            try stream.start()
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                defer { stream.stop(); semaphore.signal() }
                do {
                    try await stream.streamPCM16Mono { bytes, byteCount in
                        try writeAll(fileDescriptor: clientFD, buffer: bytes, count: byteCount)
                    }
                } catch {
                    debugLog("Agent stream error for pid \(pid): \(error)")
                }
            }
            _ = semaphore.wait(timeout: .distantFuture)
        } catch {
            debugLog("Agent request failed: \(error)")
        }
    }
}

// MARK: - Client (--via-agent)

private func connectToAgent(socketPath: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw "Failed to create client socket: \(errno)" }
    setNoSigPipe(fileDescriptor: fd)
    do {
        let status = try withSocketAddress(path: socketPath) { address, length in connect(fd, address, length) }
        guard status == 0 else {
            let error = errno; close(fd)
            if error == ENOENT || error == ECONNREFUSED {
                throw agentLaunchInstructions()
            }
            throw "Failed to connect to audia-tap agent: \(error)"
        }
    } catch { close(fd); throw error }
    return fd
}

private func agentLaunchInstructions() -> String {
    "audia-tap agent is not running.\nStart the agent first with: \(CommandLine.arguments[0]) --agent\nThen connect with: \(CommandLine.arguments[0]) --pid <PID>"
}

private func runClient(pid: pid_t, options: CLIOptions) throws {
    let fd = try connectToAgent(socketPath: options.socketPath)
    defer { close(fd) }

    let request = "\(pid)\n"
    try request.utf8.withContiguousStorageIfAvailable { buffer in
        try writeAll(fileDescriptor: fd, buffer: buffer.baseAddress!, count: buffer.count)
    } ?? {
        let data = Data(request.utf8)
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            try writeAll(fileDescriptor: fd, buffer: base, count: rawBuffer.count)
        }
    }()

    let outputHandle = try openOutputHandle(options: options)
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let bytesRead = read(fd, &buffer, buffer.count)
        if bytesRead > 0 { outputHandle.write(Data(buffer.prefix(bytesRead))); continue }
        if bytesRead == 0 { return }
        if errno == EINTR { continue }
        throw "Failed reading from audia-tap agent: \(errno)"
    }
}

// MARK: - Agent lifecycle helpers

private func killStaleAgents() {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    proc.arguments = ["-f", "audia-tap --agent"]
    try? proc.run()
    proc.waitUntilExit()
}

private func autoLaunchAgent(appPath: String) throws {
    debugLog("Auto-launching agent via \(appPath)")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    proc.arguments = ["-njg", appPath, "--args", "--agent"]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError  = FileHandle.nullDevice
    try proc.run()
}

private func waitForAgentSocket(socketPath: String, timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !FileManager.default.fileExists(atPath: socketPath) {
        guard Date() < deadline else {
            throw """
            Timed out waiting for audia-tap agent to start.
            If this persists, verify Screen & System Audio Recording is granted.
            """
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    Thread.sleep(forTimeInterval: 0.2)
    debugLog("Agent socket ready at \(socketPath)")
}

// MARK: - Output handle

private func openOutputHandle(options: CLIOptions) throws -> FileHandle {
    guard let path = options.outputPath else { return FileHandle.standardOutput }
    FileManager.default.createFile(atPath: path, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: path) else {
        throw "Cannot open output file for writing: \(path)"
    }
    return handle
}

// MARK: - JSON info

private func emitJSONInfo(process: AudioProcess, options: CLIOptions, tapSampleRate: Double) {
    guard options.jsonInfo else { return }
    let obj: [String: Any] = [
        "pid":        process.id,
        "name":       process.name,
        "bundleID":   process.bundleID ?? "",
        "format":     options.format.rawValue,
        "sampleRate": options.sampleRate,
        "channels":   options.channels,
        "tapSourceSampleRate": tapSampleRate
    ]
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted]),
       let json = String(data: data, encoding: .utf8) {
        fputs(json + "\n", stderr)
    }
}

// MARK: - Direct tap

private func runDirect(pid: pid_t, options: CLIOptions) throws {
    try ensureAudioCapturePermission()

    if FileManager.default.fileExists(atPath: options.socketPath) {
        do {
            debugLog("Agent socket found, attempting connection")
            try runClient(pid: pid, options: options)
            return
        } catch {
            debugLog("Stale socket detected (\(error)), cleaning up")
        }
    }

    infoLog("Auto-starting background agent...")
    killStaleAgents()
    try? FileManager.default.removeItem(atPath: options.socketPath)

    let appPath = bundledAppPath()
    guard FileManager.default.fileExists(atPath: appPath) else {
        throw "Cannot auto-start agent: audia-tap.app not found at \(appPath). Build the Xcode project first."
    }

    try autoLaunchAgent(appPath: appPath)
    try waitForAgentSocket(socketPath: options.socketPath, timeout: options.agentTimeout)
    try runClient(pid: pid, options: options)
}

// MARK: - Duration-limited streaming task

/// Wraps a streaming task and cancels it after `duration` seconds.
private func runWithDuration(_ duration: Double?, task: @escaping () async throws -> Void) async throws {
    if let duration {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await task() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                // Timer fired — let the group finish naturally by cancelling the stream task
            }
            // Take the first result (either stream ended or timer fired)
            try await group.next()
            group.cancelAll()
        }
    } else {
        try await task()
    }
}

// MARK: - Entry point

do {
    switch try parseArguments(arguments: CommandLine.arguments) {

    case .help:
        printHelp()

    case .version:
        printVersion()

    case .list:
        printAudioProcessList(quiet: globalQuiet)

    case .launchedForPermission:
        _ = CGRequestScreenCaptureAccess()
        let status = requestAudioCapturePermission()
        if status == .authorized {
            fputs("[audia-tap] Audio Capture permission granted.\n", stderr)
        } else {
            fputs("[audia-tap] Audio Capture permission was denied.\n", stderr)
            exit(1)
        }

    case .requestPermission:
        try ensureAudioCapturePermission()
        fputs("Audio Capture permission authorized.\n", stderr)

    case .agent:
        let agentSocketPath = CLIOptions().socketPath
        let server = AgentServer(socketPath: agentSocketPath)
        try server.start()
        let relay = SignalRelay()
        relay.install { _ in server.stop(); exit(0) }
        // Block the main thread; signal handlers drive exit.
        dispatchMain()

    case .direct(let pid, let options):
        try ensureAudioCapturePermission()

        let process = try AudioProcess(pid: pid)
        let stream  = try ProcessTapStream(process: process)
        try stream.start()

        emitJSONInfo(process: process, options: options, tapSampleRate: stream.tapSampleRate)

        let outputHandle = try openOutputHandle(options: options)

        infoLog("Tapping \(process.name) (pid \(pid)) → \(options.format.rawValue) \(Int(options.sampleRate))Hz \(options.channels)ch")

        let signal = SignalRelay()
        signal.install { _ in stream.stop(); exit(0) }

        let streamSemaphore = DispatchSemaphore(value: 0)
        var streamError: Error?
        Task.detached(priority: .userInitiated) {
            defer { stream.stop(); streamSemaphore.signal() }
            do {
                try await runWithDuration(options.duration) {
                    try await stream.stream(options: options) { bytes, byteCount in
                        outputHandle.write(Data(bytes: bytes, count: byteCount))
                    }
                }
            } catch {
                streamError = error
            }
        }
        streamSemaphore.wait()
        if let error = streamError { throw error }

    case .viaAgent(let pid, let options):
        try runClient(pid: pid, options: options)
    }
} catch {
    fputs("audia-tap error: \(error)\n", stderr)
    exit(1)
}
