import AppKit
import Foundation

/// Lock-guarded flag so a continuation is resumed exactly once (spawn failure vs termination).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Runs a process asynchronously and returns (exit code, stdout). `stdin` is written to it, if given.
@discardableResult
func runProcess(_ exe: String, _ args: [String], timeout: TimeInterval = 20, stdin: Data? = nil) async -> (Int32, String) {
    await withCheckedContinuation { cont in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let input = stdin.map { _ in Pipe() }
        p.standardInput = input ?? FileHandle.nullDevice
        let once = ResumeOnce()
        @Sendable func finish(_ code: Int32, _ s: String) {
            if once.claim() { cont.resume(returning: (code, s)) }
        }
        do { try p.run() } catch { finish(-1, ""); return }
        if let input, let stdin {
            // Off the caller's thread: a large write blocks until the child reads it.
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
            }
        }
        // Drain stdout while the process runs: reading only after exit deadlocks once the output
        // exceeds the pipe buffer (~64 KB), because the child blocks on write and never exits.
        DispatchQueue.global().async {
            let fh = out.fileHandleForReading
            let d = fh.readDataToEndOfFile()   // returns at EOF
            // Close it ourselves: left to dealloc, the read end stayed open (about one fd per call,
            // and the 3 s front-session poll ran the app out of them in a day, after which every
            // process launch failed and every jump took the "nothing open, new desktop" path).
            try? fh.close()
            p.waitUntilExit()
            finish(p.terminationStatus, String(decoding: d, as: UTF8.self))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { p.terminate() }
            // Something the child left behind (a background process, say) can hold the pipe open
            // past its exit, and the read above then waits for it. Don't make the caller wait too.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(-1, "") }
        }
    }
}

func shellQuote(_ s: String) -> String {
    // A leading '=' or '~' is expanded by zsh (=cmd -> path of cmd), so those words always get quoted.
    if !s.isEmpty, !"=~".contains(s.first!),
       s.allSatisfy({ $0.isLetter || $0.isNumber || "@%_-./=:,+".contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func appleScriptString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// iTerm2 control via AppleScript. All terminal-specific code lives here (used through
/// ITermTerminal, MacPlatform.swift).
enum ITerm {
    static let bundleID = "com.googlecode.iterm2"

    struct FrontSession: Equatable {
        let tty: String
        let uniqueID: String
    }

    static func osascript(_ src: String) async -> String? {
        let (code, out) = await runProcess("/usr/bin/osascript", ["-e", src])
        return code == 0 ? out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func frontSession() async -> FrontSession? {
        guard isRunning else { return nil }
        let r = await osascript("""
        tell application id "\(bundleID)"
          if (count of windows) is 0 then return ""
          set s to current session of current window
          return (tty of s) & "|" & (unique id of s)
        end tell
        """)
        guard let r, let bar = r.firstIndex(of: "|") else { return nil }
        return FrontSession(tty: String(r[..<bar]), uniqueID: String(r[r.index(after: bar)...]))
    }

    /// Focus the iTerm session matching `property` (tty or unique id). Returns true if found.
    private static func focus(where property: String, is value: String) async -> Bool {
        guard isRunning else { return false }
        let r = await osascript("""
        tell application id "\(bundleID)"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if (\(property) of s) is \(appleScriptString(value)) then
                  select w
                  tell t to select
                  tell s to select
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          return "none"
        end tell
        """)
        return r == "ok"
    }

    /// Unique id of the iTerm session whose escape-code window title equals `title`.
    static func session(withTitle title: String) async -> String? {
        guard isRunning else { return nil }
        let r = await osascript("""
        tell application id "\(bundleID)"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if ((variable named "session.terminalWindowName") of s) is \(appleScriptString(title)) then return unique id of s
              end repeat
            end repeat
          end repeat
          return ""
        end tell
        """)
        return (r?.isEmpty ?? true) ? nil : r
    }

    static func currentWindowID() async -> String? {
        guard isRunning else { return nil }
        let r = await osascript("tell application id \"\(bundleID)\" to return id of current window")
        return (r?.isEmpty ?? true) ? nil : r
    }

    static func focus(tty: String) async -> Bool { await focus(where: "tty", is: tty) }
    static func focus(uniqueID: String) async -> Bool { await focus(where: "unique id", is: uniqueID) }

    struct NewWindow {
        let sessionID: String
        let windowID: String
    }

    /// Open a new iTerm window running `shellCommand` (through a login zsh). The command runs from a
    /// throwaway script so iTerm's own argument splitting never touches our quoting.
    static func newWindow(running shellCommand: String) async -> NewWindow? {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches/heylisten")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("open-\(UUID().uuidString.prefix(8)).zsh")
        let script = "#!/bin/zsh -l\nrm -f -- \"$0\"\n\(shellCommand)\n"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch { return nil }
        let r = await osascript("""
        tell application id "\(bundleID)"
          set nw to (create window with default profile command \(appleScriptString(path)))
          activate
          return (unique id of current session of nw) & "|" & (id of nw)
        end tell
        """)
        guard let r, let bar = r.firstIndex(of: "|") else {
            try? FileManager.default.removeItem(atPath: path)   // it deletes itself only once it runs
            return nil
        }
        return NewWindow(sessionID: String(r[..<bar]), windowID: String(r[r.index(after: bar)...]))
    }

    /// Set a window's frame. `rect` is in AppleScript/AX coordinates (top-left origin of the main display).
    static func setBounds(windowID: String, rect: CGRect) async {
        let l = Int(rect.minX), t = Int(rect.minY), r = Int(rect.maxX), b = Int(rect.maxY)
        _ = await osascript("""
        tell application id "\(bundleID)"
          set bounds of (first window whose id is \(windowID)) to {\(l), \(t), \(r), \(b)}
        end tell
        """)
    }
}
