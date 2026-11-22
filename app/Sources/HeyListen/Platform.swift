import Foundation

// The platform pieces behind a jump, the "in front" check and notifications. Jumper and Store
// decide *what* to do; a backend does it. The macOS backends (MacPlatform.swift) drive iTerm,
// VS Code, Mission Control and the notification centre. Each one is wrapped so that a user script
// in ~/.config/heylisten/actions/<action> can take over that step (docs/actions.md): it lets you
// swap the terminal or editor without a rebuild, and a port to another OS reuses the same steps.

/// A terminal session: its tty and the terminal's own id for it.
struct TerminalSession: Equatable {
    let tty: String
    let id: String
}

/// A freshly opened terminal window: the id of its session and of the window itself.
struct TerminalWindow {
    let session: String
    let window: String
}

@MainActor
protocol TerminalBackend {
    /// The focused terminal session, if the terminal app is the frontmost app.
    func frontSession() async -> TerminalSession?
    /// Bring the session on this tty to the front. False if no terminal session has it.
    func focus(tty: String) async -> Bool
    /// Bring the session with this id to the front. False if it no longer exists.
    func focus(session id: String) async -> Bool
    /// Id of the session whose window title (set by tmux) is `title`.
    func session(titled title: String) async -> String?
    /// Id of the window holding the focused session.
    func currentWindow() async -> String?
    /// A new terminal window running `command` (a shell script body), brought to the front.
    func open(running command: String, for item: SessionItem) async -> TerminalWindow?
    /// Move and resize a window.
    func place(window: String, frame: CGRect) async
}

@MainActor
protocol EditorBackend {
    /// Whether an editor window shows this project. nil: can't tell (no editor), so don't open one.
    func hasWindow(for item: SessionItem) async -> Bool?
    /// Open the project in a new editor window placed at `frame`.
    func open(_ item: SessionItem, frame: CGRect) async
}

@MainActor
protocol WorkspaceBackend {
    /// Create a desktop / workspace and switch to it. False if that failed.
    func newWorkspace() async -> Bool
    /// Where the terminal and the editor go on the current screen.
    func tiles() -> (terminal: CGRect, editor: CGRect)
}

/// A notification, worded the same on every platform.
struct Alert {
    let key: String        // SessionItem.id: clicking it jumps there
    let id: String         // unique per event
    let title: String
    let subtitle: String
    let body: String
    let sound: Bool

    init(item: SessionItem, sound: Bool) {
        let state = item.wire.attention?.state
        let permission = state == "permission"
        let msg = item.wire.attention?.message ?? ""
        key = item.id
        id = "\(item.id)|\(item.wire.attention?.ts ?? 0)"
        subtitle = item.wire.name + (item.isLocal ? "" : " · \(item.host)")
        self.sound = sound
        if state == "error" {
            title = "\(item.project) stopped"
            body = "The turn ended on an API error: \(msg.isEmpty ? "unknown" : msg)."
        } else {
            title = permission ? "\(item.project) needs permission" : "\(item.project) is waiting for you"
            body = msg.isEmpty || msg == "Turn finished" ? (permission ? "Claude is asking to continue." : "Turn finished.") : msg
        }
    }
}

@MainActor
protocol AlertBackend {
    func notify(_ alert: Alert, item: SessionItem)
    /// "Can't do that" feedback.
    func beep()
}

@MainActor
enum Platform {
    static let terminal: TerminalBackend = ScriptedTerminal(ITermTerminal())
    static let editor: EditorBackend = ScriptedEditor(VSCodeEditor())
    static let workspace: WorkspaceBackend = ScriptedWorkspace(MacWorkspace())
    static let alerts: AlertBackend = ScriptedAlerts(MacAlerts())
}

// MARK: - User action scripts

/// Runs ~/.config/heylisten/actions/<name> ($XDG_CONFIG_HOME) with a JSON object on stdin.
/// Exit 0: done / yes (stdout carries the answer, if any). Exit 1: no / not found.
/// Anything else (2+, a crash, a timeout) or no script: the built-in step runs instead.
enum Actions {
    static var directory: String {
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (config as NSString).appendingPathComponent("heylisten/actions")
    }

    enum Outcome {
        case yes(String)   // stdout, trimmed
        case no
    }

    /// nil: no script for this action, or it passed (use the built-in).
    static func run(_ name: String, _ input: [String: Any], timeout: TimeInterval = 20) async -> Outcome? {
        let path = (directory as NSString).appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        var payload = input
        payload["action"] = name
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        let (code, out) = await runProcess(path, [], timeout: timeout, stdin: data)
        if name != "front-session" { hlog("action \(name): exit \(code)") }   // that one runs every 3 s
        switch code {
        case 0: return .yes(out.trimmingCharacters(in: .whitespacesAndNewlines))
        case 1: return .no
        default: return nil
        }
    }

    /// What every action gets to know about the session it is about.
    @MainActor
    static func describe(_ item: SessionItem) -> [String: Any] {
        var d: [String: Any] = [
            "key": item.id,
            "host": item.host,
            "local": item.isLocal,
            "project": item.project,
            "cwd": item.wire.cwd,
            "name": item.wire.name,
            "tty": item.wire.tty ?? NSNull(),
            "attach": Jumper.attachCommand(item) ?? NSNull(),
        ]
        if let t = item.wire.tmux {
            d["tmux"] = ["session": t.session, "window": t.window, "pane": t.pane]
        } else {
            d["tmux"] = NSNull()
        }
        return d
    }

    /// Frames: points, origin at the top left of the main display.
    static func describe(_ r: CGRect) -> [String: Any] {
        ["x": Int(r.minX), "y": Int(r.minY), "width": Int(r.width), "height": Int(r.height)]
    }

    static func words(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }
}

// MARK: - Script-first wrappers

@MainActor
struct ScriptedTerminal: TerminalBackend {
    let base: TerminalBackend
    init(_ base: TerminalBackend) { self.base = base }

    func frontSession() async -> TerminalSession? {
        switch await Actions.run("front-session", [:], timeout: 5) {
        case .yes(let out):
            let w = Actions.words(out)
            return w.count >= 2 ? TerminalSession(tty: w[0], id: w[1]) : nil
        case .no: return nil
        case nil: return await base.frontSession()
        }
    }

    func focus(tty: String) async -> Bool {
        switch await Actions.run("focus-terminal", ["tty": tty]) {
        case .yes: return true
        case .no: return false
        case nil: return await base.focus(tty: tty)
        }
    }

    func focus(session id: String) async -> Bool {
        switch await Actions.run("focus-terminal", ["session": id]) {
        case .yes: return true
        case .no: return false
        case nil: return await base.focus(session: id)
        }
    }

    func session(titled title: String) async -> String? {
        switch await Actions.run("find-terminal", ["title": title], timeout: 5) {
        case .yes(let out): return out.isEmpty ? nil : out
        case .no: return nil
        case nil: return await base.session(titled: title)
        }
    }

    func currentWindow() async -> String? {
        switch await Actions.run("current-window", [:], timeout: 5) {
        case .yes(let out): return out.isEmpty ? nil : out
        case .no: return nil
        case nil: return await base.currentWindow()
        }
    }

    func open(running command: String, for item: SessionItem) async -> TerminalWindow? {
        var input = Actions.describe(item)
        input["command"] = command
        switch await Actions.run("open-terminal", input, timeout: 30) {
        case .yes(let out):
            let w = Actions.words(out)
            return w.count >= 2 ? TerminalWindow(session: w[0], window: w[1]) : nil
        case .no: return nil
        case nil: return await base.open(running: command, for: item)
        }
    }

    func place(window: String, frame: CGRect) async {
        if await Actions.run("place-window", ["window": window, "frame": Actions.describe(frame)]) != nil { return }
        await base.place(window: window, frame: frame)
    }
}

@MainActor
struct ScriptedEditor: EditorBackend {
    let base: EditorBackend
    init(_ base: EditorBackend) { self.base = base }

    func hasWindow(for item: SessionItem) async -> Bool? {
        switch await Actions.run("editor-has-window", Actions.describe(item)) {
        case .yes: return true
        case .no: return false
        case nil: return await base.hasWindow(for: item)
        }
    }

    func open(_ item: SessionItem, frame: CGRect) async {
        var input = Actions.describe(item)
        input["frame"] = Actions.describe(frame)
        if await Actions.run("open-editor", input, timeout: 60) != nil { return }
        await base.open(item, frame: frame)
    }
}

@MainActor
struct ScriptedWorkspace: WorkspaceBackend {
    let base: WorkspaceBackend
    init(_ base: WorkspaceBackend) { self.base = base }

    func newWorkspace() async -> Bool {
        switch await Actions.run("new-workspace", [:], timeout: 30) {
        case .yes: return true
        case .no: return false
        case nil: return await base.newWorkspace()
        }
    }

    // Layout is decided here (synchronously, used by every jump), not by a script.
    func tiles() -> (terminal: CGRect, editor: CGRect) { base.tiles() }
}

@MainActor
struct ScriptedAlerts: AlertBackend {
    let base: AlertBackend
    init(_ base: AlertBackend) { self.base = base }

    func notify(_ alert: Alert, item: SessionItem) {
        Task { @MainActor in
            var input = Actions.describe(item)
            input["title"] = alert.title
            input["subtitle"] = alert.subtitle
            input["body"] = alert.body
            input["sound"] = alert.sound
            input["id"] = alert.id
            if await Actions.run("notify", input) != nil { return }
            base.notify(alert, item: item)
        }
    }

    func beep() { base.beep() }
}
