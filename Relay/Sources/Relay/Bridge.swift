import Foundation

/// JSON lines over stdio to the Agent SDK sidecar (sidecar/index.ts, compiled into Relay.app), which runs your installed `claude`.
/// Supervised: if the sidecar exits it is restarted, and writes never take the app down.
@MainActor
final class Bridge {
    private var process: Process?
    private var stdin: Pipe?
    private var buffer = Data()
    /// Commands sent while the sidecar is (re)starting; flushed once it's up.
    private var queue: [Data] = []
    private var stopping = false
    private var restarts: [Date] = []

    var onEvent: ([String: Any]) -> Void = { _ in }
    /// Called when the sidecar died and was restarted: every card's session is gone and must reopen.
    var onRestart: () -> Void = {}

    static let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Relay/sidecar.log")

    init() {
        // A write to a dead pipe must be an error, not a SIGPIPE that silently kills Relay.
        signal(SIGPIPE, SIG_IGN)
        start()
    }

    private func start() {
        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        // Relay.app carries its own compiled sidecar (make-app.sh), so it doesn't depend on bun, the checkout or its branch.
        // A dev build (swift run) has none and runs the source with bun.
        if let fake = ProcessInfo.processInfo.environment["RELAY_SIDECAR"] {
            // Test hook: a stand-in sidecar (a script that speaks the same JSON lines), so the UI can be driven without claude.
            process.executableURL = URL(fileURLWithPath: fake)
        } else if let bundled = Bundle.main.url(forAuxiliaryExecutable: "relay-sidecar") {
            process.executableURL = bundled
        } else {
            let sidecar = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("sidecar/index.ts")
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "exec bun run '\(sidecar.path)'"]
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.shellPath
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Self.logHandle()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.ingest(chunk) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.exited(status: status) }
        }
        buffer = Data()
        do {
            try process.run()
            self.process = process
            self.stdin = stdin
            let pending = queue
            queue = []
            pending.forEach(write)
        } catch {
            Self.log("could not start sidecar: \(error)")
        }
    }

    /// Launched from the Dock, Relay gets launchd's bare PATH, and bun, claude and node live in dirs only ~/.zshrc adds.
    /// Ask an interactive shell once, like editors do; fall back to the known install dirs.
    private static let shellPath: String = {
        let home = NSHomeDirectory()
        let known = ["\(home)/.bun/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let shell = Process()
        let out = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-ilc", "print -rn -- \"__PATH__${PATH}__PATH__\""]
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        var resolved = ""
        if (try? shell.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            shell.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            if let start = text.range(of: "__PATH__"), let end = text.range(of: "__PATH__", range: start.upperBound..<text.endIndex) {
                resolved = String(text[start.upperBound..<end.lowerBound])
            }
        }
        var dirs = resolved.split(separator: ":").map(String.init)
        for dir in known where !dirs.contains(dir) { dirs.append(dir) }
        return dirs.joined(separator: ":")
    }()

    private func exited(status: Int32) {
        process = nil
        stdin = nil
        guard !stopping else { return }
        Self.log("sidecar exited with status \(status); restarting")
        // Commands queued for the dead process reference its sessions; the model reopens cards itself.
        queue = []
        onRestart()
        // Back off if it keeps dying right away.
        restarts = restarts.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
        let delay = restarts.count > 3 ? 5.0 : 0.3
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if self.process == nil && !self.stopping { self.start() }
        }
    }

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { onEvent(event) }
        }
    }

    func send(_ command: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        let line = data + Data([0x0A])
        if process?.isRunning == true { write(line) } else { queue.append(line) }
    }

    private func write(_ line: Data) {
        do {
            try stdin?.fileHandleForWriting.write(contentsOf: line)
        } catch {
            Self.log("write failed: \(error)")
            queue.append(line)
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
    }

    // MARK: Log (~/Library/Logs/Relay/sidecar.log, sidecar stderr included)

    private static func logHandle() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: logURL)
        _ = try? handle?.seekToEnd()
        return handle
    }

    static func log(_ message: String) {
        guard let handle = logHandle() else { return }
        try? handle.write(contentsOf: Data("[\(Date.now.formatted(.iso8601))] relay: \(message)\n".utf8))
        try? handle.close()
    }
}
