import AppKit
import Foundation

/// "Take me to that session": focus it if it is open somewhere, else build a workspace
/// (new desktop, tmux on the left, the editor on the right). This decides what to do; the
/// platform backends (Platform.swift) do it.
@MainActor
enum Jumper {
    private static let tagKey = "itermTags"   // "host|tmuxSession" -> iTerm session unique id

    static func taggedSession(host: String, tmuxSession: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: tagKey) as? [String: String])?["\(host)|\(tmuxSession)"]
    }

    private static var tags: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: tagKey) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: tagKey) }
    }

    /// A window shows one tmux session at a time, so an older link to the same window is stale.
    private static func tag(host: String, tmuxSession: String, id: String) {
        var d = tags.filter { $0.value != id }
        d["\(host)|\(tmuxSession)"] = id
        tags = d
    }

    private static func untag(host: String, tmuxSession: String) {
        tags["\(host)|\(tmuxSession)"] = nil
    }

    /// Drop a host's links to tmux sessions it no longer has. Session names are reused (numbers,
    /// mostly), and a leftover link would send a new session with an old name to whatever window
    /// the old one was in.
    static func pruneTags(host: String, sessions: [String]) {
        let live = Set(sessions)
        let d = tags
        let kept = d.filter { key, _ in
            guard let bar = key.lastIndex(of: "|"), key[..<bar] == host else { return true }
            return live.contains(String(key[key.index(after: bar)...]))
        }
        if kept.count != d.count {
            hlog("jump: dropped links to gone tmux sessions on \(host): \(d.keys.filter { kept[$0] == nil }.sorted())")
            tags = kept
        }
    }

    static func jump(_ item: SessionItem) {
        Task { @MainActor in await jumpAsync(item) }
    }

    private static func jumpAsync(_ item: SessionItem) async {
        let store = Store.shared
        store.acknowledge(item)
        guard item.jumpable else { Platform.alerts.beep(); return }
        let host = store.hosts.first { $0.name == item.host }

        if item.isLocal {
            if let t = item.wire.tmux {
                if let c = host?.tmux?.clients.first(where: { $0.session == t.session }),
                   await Platform.terminal.focus(tty: c.tty) {
                    await selectPane(item, t)
                    await ensureEditor(item)
                    return
                }
            } else {
                if let tty = item.wire.tty, await Platform.terminal.focus(tty: tty) { await ensureEditor(item); return }
                Platform.alerts.beep()   // local session outside tmux and not in a terminal we can see
                return
            }
        } else if let t = item.wire.tmux {
            let attached = host?.tmux?.sessions.first { $0.name == t.session }?.attached ?? 0
            if attached > 0 {
                // 1. A window we know about (opened by us, or found earlier).
                if let id = taggedSession(host: item.host, tmuxSession: t.session) {
                    if await Platform.terminal.focus(session: id) {
                        await selectPane(item, t)
                        await ensureEditor(item)
                        return
                    }
                    untag(host: item.host, tmuxSession: t.session)   // that window is gone
                }
                // 2. Discover a window the user attached themselves, then remember it.
                if let id = await discoverRemoteWindow(item, t) {
                    tag(host: item.host, tmuxSession: t.session, id: id)
                    _ = await Platform.terminal.focus(session: id)
                    await selectPane(item, t)
                    await ensureEditor(item)
                    return
                }
            }
        }
        await openWorkspace(item)
    }

    /// After focusing an existing terminal: if no editor window shows this project, open one and
    /// tile terminal + editor on the current desktop, keeping the terminal in front.
    private static func ensureEditor(_ item: SessionItem) async {
        let p = Platform.self
        guard let open = await p.editor.hasWindow(for: item) else { return }
        hlog("jump: editor window for \(item.project)@\(item.host): \(open ? "present" : "missing")")
        guard !open, let wid = await p.terminal.currentWindow(), let sid = await p.terminal.frontSession() else { return }
        let tiles = p.workspace.tiles()
        await p.terminal.place(window: wid, frame: tiles.terminal)
        await openEditor(item, frame: tiles.editor, terminalSession: sid.id)
    }

    private static func ssh(_ host: String, _ cmd: String) async {
        await runProcess("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes",
                                          "-o", "ConnectTimeout=8", host, cmd])
    }

    /// Ask the remote tmux to title this session's clients with a one-off marker, find the iTerm
    /// session showing it, then restore the title. Returns that iTerm session's unique id.
    private static func discoverRemoteWindow(_ item: SessionItem, _ t: TmuxRef) async -> String? {
        let marker = "heylisten-" + UUID().uuidString.prefix(8).lowercased()
        let s = shellQuote("=" + t.session + ":")   // "=name:" = exact session match for set-option/list-clients
        let refresh = "for c in $(tmux list-clients -t \(s) -F '#{client_tty}'); do tmux refresh-client -t \"$c\"; done"
        await ssh(item.host, "tmux set-option -t \(s) set-titles on \\; set-option -t \(s) set-titles-string \(shellQuote(marker)) && \(refresh)")
        var found: String?
        for _ in 0..<10 {
            if let id = await Platform.terminal.session(titled: marker) { found = id; break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        // Restore: show the pane title, then drop our session-level overrides (global settings win again).
        await ssh(item.host, "tmux set-option -t \(s) set-titles-string '#T' && \(refresh); tmux set-option -u -t \(s) set-titles \\; set-option -u -t \(s) set-titles-string")
        hlog("jump: discovery \(item.host):\(t.session) -> \(found ?? "none")")
        return found
    }

    private static func selectPane(_ item: SessionItem, _ t: TmuxRef) async {
        if item.isLocal {
            await runProcess("/usr/bin/env", ["tmux", "select-window", "-t", t.window, ";", "select-pane", "-t", t.pane])
        } else {
            let cmd = "tmux select-window -t \(shellQuote(t.window)) \\; select-pane -t \(shellQuote(t.pane))"
            await runProcess("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes",
                                              "-o", "ConnectTimeout=8", item.host, cmd])
        }
    }

    static func attachCommand(_ item: SessionItem) -> String? {
        guard let t = item.wire.tmux else { return nil }
        let tmux = "tmux attach-session -t \(shellQuote("=" + t.session)) \\; select-window -t \(shellQuote(t.window)) \\; select-pane -t \(shellQuote(t.pane))"
        if item.isLocal { return "exec \(tmux)" }
        // No port forwards (they belong to your own interactive ssh, and a forward clash over the shared
        // ControlMaster connection can hang the attach), a connect timeout, and on failure keep the
        // window open with the error instead of a silent blank window.
        return """
        ssh -t -o ClearAllForwardings=yes -o ConnectTimeout=10 \(shellQuote(item.host)) \(shellQuote(tmux)) || {
          rc=$?; echo
          printf 'heylisten: could not attach to %s on %s (exit %s)\\n' \(shellQuote(t.session)) \(shellQuote(item.host)) "$rc"
          exec zsh -l; }
        """
    }

    private static func openWorkspace(_ item: SessionItem) async {
        let p = Platform.self
        guard let cmd = attachCommand(item), let t = item.wire.tmux else { p.alerts.beep(); return }
        if Store.shared.prefs.newDesktop {
            let ok = await p.workspace.newWorkspace()
            if !ok { hlog("jump: new desktop failed, tiling on current desktop") }
        }
        guard let win = await p.terminal.open(running: cmd, for: item) else { p.alerts.beep(); return }
        tag(host: item.host, tmuxSession: t.session, id: win.session)

        let tiles = p.workspace.tiles()
        await p.terminal.place(window: win.window, frame: tiles.terminal)
        await openEditor(item, frame: tiles.editor, terminalSession: win.session)
    }

    /// Open the editor beside the terminal without waiting for it: the editor's window can take
    /// seconds to show up (a remote one connecting), or never come at all, and you'd sit in front of
    /// another editor window meanwhile. It is placed in the background when it shows up; the
    /// terminal goes back in front at once, since that's where Claude is waiting.
    private static func openEditor(_ item: SessionItem, frame: CGRect, terminalSession: String) async {
        Task { @MainActor in await Platform.editor.open(item, frame: frame) }
        _ = await Platform.terminal.focus(session: terminalSession)
        await keepInFront(session: terminalSession)
    }

    /// The editor can grab focus again well after its window appeared (a remote window finishing its
    /// connection, say). For a while, put the terminal back in front whenever another app takes it,
    /// unless you clicked or typed since: then that app is your choice.
    private static func keepInFront(session: String, for duration: TimeInterval = 20) async {
        // Called right after focusing the terminal, so the frontmost app is the terminal.
        guard let terminal = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let start = Date()
        while Date().timeIntervalSince(start) < duration {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if userActed(since: start) { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != terminal {
                hlog("jump: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") took focus, back to the terminal")
                if await !Platform.terminal.focus(session: session) { return }
            }
        }
    }

    private static func userActed(since t: Date) -> Bool {
        let elapsed = Date().timeIntervalSince(t)
        let kinds: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        return kinds.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < elapsed }
    }
}

enum VSCode {
    static let bundleID = "com.microsoft.VSCode"

    static var cli: String? {
        [
            "/opt/homebrew/bin/code",
            "/usr/local/bin/code",
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether some VS Code window shows this project (on any desktop), from `code --status`
    /// window titles like "file.c — project" or "file.py — project [SSH: host]".
    /// nil if VS Code isn't installed or the status call failed.
    static func hasWindow(for item: SessionItem) async -> Bool? {
        guard let cli else { return nil }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        if !running { return false }
        let (code, out) = await runProcess(cli, ["--status"], timeout: 20)
        guard code == 0 else { return nil }
        let wantSSH = item.isLocal ? nil : "[SSH: \(item.host)]"
        if workspaceFolders(out).contains(where: { $0.remote == wantSSH.map { String($0.dropFirst().dropLast()) } && $0.folder == item.project }) {
            return true
        }
        for line in out.split(separator: "\n") {
            guard let r = line.range(of: "window ["), let open = line[r.upperBound...].firstIndex(of: "("),
                  line.hasSuffix(")") else { continue }
            var title = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
            var ssh: String?
            if let b = title.range(of: " [SSH: ", options: .backwards) {
                ssh = String(title[title.index(after: b.lowerBound)...])
                title = String(title[..<b.lowerBound])
            }
            guard ssh == wantSSH else { continue }
            let root = title.components(separatedBy: " — ").last?
                .replacingOccurrences(of: " (Workspace)", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "● ")) ?? ""
            if root == item.project { return true }
        }
        return false
    }

    /// The folders open in VS Code windows, from the "Workspace Stats" part of `code --status`: the
    /// local ones first, then a "Remote: SSH: host" block per remote window, each with its
    /// "Folder (name): N files" line. The process list above it can leave windows out (a remote
    /// window seen open was missing from it), these blocks don't.
    static func workspaceFolders(_ status: String) -> [(remote: String?, folder: String)] {
        var out: [(remote: String?, folder: String)] = []
        var inStats = false
        var remote: String?
        for line in status.split(separator: "\n") {
            if line.hasPrefix("Workspace Stats:") { inStats = true; remote = nil; continue }
            if line.hasPrefix("Remote:") {
                inStats = true
                remote = line.dropFirst("Remote:".count).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard inStats, let r = line.range(of: "Folder ("), let close = line[r.upperBound...].range(of: "): ") else { continue }
            out.append((remote, String(line[r.upperBound..<close.lowerBound])))
        }
        return out
    }

    @MainActor
    static func open(item: SessionItem, frame: CGRect) async {
        guard let cli else { return }
        var args = ["-n"]
        if !item.isLocal { args += ["--remote", "ssh-remote+\(item.host)"] }
        args.append(item.wire.cwd)
        await runProcess(cli, args, timeout: 30)
        let project = item.project
        // Wait for VS Code's new window (title contains the folder name), then tile it.
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if WindowTiler.setFrame(ofFocusedWindowOf: bundleID, titleContains: project, to: frame) { return }
        }
    }
}
