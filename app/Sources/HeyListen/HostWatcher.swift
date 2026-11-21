import Foundation

/// Runs `ccwatch` (locally, or over a persistent ssh stream) and feeds decoded lines to a callback.
/// Reconnects with exponential backoff; a missing heartbeat for 45 s counts as a drop.
final class HostWatcher {
    enum Event {
        case message(WireMessage)
        case disconnected(reason: String, notInstalled: Bool)
    }

    static let remoteWatcherPath = "~/.local/share/heylisten/ccwatch"
    static var localWatcherPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/share/heylisten/ccwatch")
    }

    let host: String
    private let onEvent: (Event) -> Void
    private let queue: DispatchQueue
    private var process: Process?
    private var buffer = Data()
    private var stderrTail = ""
    private var lastLine = Date()
    private var backoff: TimeInterval = 2
    private var stopped = false
    private var watchdog: DispatchSourceTimer?
    private var generation = 0

    init(host: String, onEvent: @escaping (Event) -> Void) {
        self.host = host
        self.onEvent = onEvent
        self.queue = DispatchQueue(label: "heylisten.watch.\(host)")
    }

    func start() {
        queue.async { self.stopped = false; self.launch() }
    }

    /// Synchronous stop, for app termination (so no orphan ccwatch/ssh is left behind).
    func stopNow() {
        queue.sync {
            self.stopped = true
            self.watchdog?.cancel()
            self.process?.terminate()
            self.process = nil
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.watchdog?.cancel()
            self.process?.terminate()
            self.process = nil
        }
    }

    // MARK: private (on queue)

    private func launch() {
        guard !stopped else { return }
        generation += 1
        let gen = generation
        buffer = Data()
        stderrTail = ""

        let p = Process()
        if host == localHostName {
            let path = Self.localWatcherPath
            guard FileManager.default.isExecutableFile(atPath: path) else {
                emit(.disconnected(reason: "ccwatch not installed", notInstalled: true))
                scheduleRelaunch(gen: gen, fixed: 10)
                return
            }
            p.executableURL = URL(fileURLWithPath: path)
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = [
                "-T",
                "-o", "BatchMode=yes",
                "-o", "ClearAllForwardings=yes",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3",
                "-o", "ConnectTimeout=10",
                host,
                Self.remoteWatcherPath,
            ]
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        // On EOF, clear the handler *before* anything can return early: a handler left installed
        // on a closed pipe is called again forever (e.g. after reconnect frees this watcher).
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            guard let self else { fh.readabilityHandler = nil; return }
            self.queue.async {
                guard gen == self.generation else { fh.readabilityHandler = nil; return }
                self.consume(d)
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            guard let self else { fh.readabilityHandler = nil; return }
            self.queue.async {
                let s = String(decoding: d, as: UTF8.self)
                self.stderrTail = String((self.stderrTail + s).suffix(400))
            }
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                self.watchdog?.cancel()
                let code = proc.terminationStatus
                let tail = self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                let lastErr = tail.split(separator: "\n").last.map(String.init) ?? ""
                let notInstalled = code == 127 || lastErr.contains("No such file") || lastErr.contains("not found")
                let reason = notInstalled ? "ccwatch not installed" :
                    (lastErr.isEmpty ? "exited (\(code))" : lastErr)
                self.emit(.disconnected(reason: reason, notInstalled: notInstalled))
                self.scheduleRelaunch(gen: gen, fixed: notInstalled ? 60 : nil)
            }
        }

        do {
            try p.run()
            process = p
            lastLine = Date()
            startWatchdog(gen: gen)
        } catch {
            emit(.disconnected(reason: error.localizedDescription, notInstalled: false))
            scheduleRelaunch(gen: gen, fixed: nil)
        }
    }

    private func startWatchdog(gen: Int) {
        watchdog?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in
            guard let self, gen == self.generation else { return }
            if Date().timeIntervalSince(self.lastLine) > 45 {
                self.stderrTail = "no heartbeat"
                self.process?.terminate()
            }
        }
        t.resume()
        watchdog = t
    }

    private func scheduleRelaunch(gen: Int, fixed: TimeInterval?) {
        guard !stopped else { return }
        let delay = fixed ?? backoff
        if fixed == nil { backoff = min(backoff * 2, 60) }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.launch()
        }
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            lastLine = Date()
            backoff = 2
            guard !line.isEmpty else { continue }
            if let msg = try? JSONDecoder().decode(WireMessage.self, from: Data(line)) {
                emit(.message(msg))
            }
        }
    }

    private func emit(_ e: Event) {
        DispatchQueue.main.async { self.onEvent(e) }
    }
}
