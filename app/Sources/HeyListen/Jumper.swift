import AppKit
import Foundation

/// "Take me to that session": focus it if it is open somewhere, else build a workspace
/// (new desktop, tmux on the left, VS Code on the right).
@MainActor
enum Jumper {
    private static let tagKey = "itermTags"   // "host|tmuxSession" -> iTerm session unique id

    static func taggedSession(host: String, tmuxSession: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: tagKey) as? [String: String])?["\(host)|\(tmuxSession)"]
    }

    private static func tag(host: String, tmuxSession: String, id: String) {
        var d = (UserDefaults.standard.dictionary(forKey: tagKey) as? [String: String]) ?? [:]
        d["\(host)|\(tmuxSession)"] = id
        UserDefaults.standard.set(d, forKey: tagKey)
    }

    static func jump(_ item: SessionItem) {
        Task { @MainActor in await jumpAsync(item) }
    }

    private static func jumpAsync(_ item: SessionItem) async {
        let store = Store.shared
        store.acknowledge(item)
        guard item.jumpable else { NSSound.beep(); return }
        let host = store.hosts.first { $0.name == item.host }

        if item.isLocal {
            if let t = item.wire.tmux {
                if let c = host?.tmux?.clients.first(where: { $0.session == t.session }),
                   await ITerm.focus(tty: c.tty) {
                    await selectPane(item, t)
                    await ensureEditor(item)
                    return
                }
            } else {
                if let tty = item.wire.tty, await ITerm.focus(tty: tty) { await ensureEditor(item); return }
                NSSound.beep()   // local session outside tmux and not in an iTerm tab we can see
                return
            }
        } else if let t = item.wire.tmux {
            let attached = host?.tmux?.sessions.first { $0.name == t.session }?.attached ?? 0
            if attached > 0 {
                // 1. A window we know about (opened by us, or found earlier).
                if let id = taggedSession(host: item.host, tmuxSession: t.session),
                   await ITerm.focus(uniqueID: id) {
                    await selectPane(item, t)
                    await ensureEditor(item)
                    return
                }
                // 2. Discover a window the user attached themselves, then remember it.
                if let id = await discoverRemoteWindow(item, t) {
                    tag(host: item.host, tmuxSession: t.session, id: id)
                    _ = await ITerm.focus(uniqueID: id)
                    await selectPane(item, t)
                    await ensureEditor(item)
                    return
                }
            }
        }
        await openWorkspace(item)
    }

    /// After focusing an existing terminal: if no VS Code window shows this project, open one and
    /// tile terminal (left) + editor (right) on the current desktop, then give focus back to iTerm.
    private static func ensureEditor(_ item: SessionItem) async {
        guard let open = await VSCode.hasWindow(for: item) else { return }
        hlog("jump: vscode window for \(item.project)@\(item.host): \(open ? "present" : "missing")")
        guard !open, let wid = await ITerm.currentWindowID(), let sid = await ITerm.frontSession() else { return }
        let (left, right) = Spaces.halves()
        await ITerm.setBounds(windowID: wid, rect: left)
        await VSCode.open(item: item, frame: right)
        _ = await ITerm.focus(uniqueID: sid.uniqueID)
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
            if let id = await ITerm.session(withTitle: marker) { found = id; break }
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
          echo; echo "heylisten: could not attach to \(t.session) on \(item.host) (exit $?)"; exec zsh -l; }
        """
    }

    private static func openWorkspace(_ item: SessionItem) async {
        guard let cmd = attachCommand(item), let t = item.wire.tmux else { NSSound.beep(); return }
        if Store.shared.prefs.newDesktop {
            let ok = await Spaces.createDesktopAndSwitch()
            if !ok { hlog("jump: new desktop failed, tiling on current desktop") }
        }
        guard let win = await ITerm.newWindow(running: cmd) else { NSSound.beep(); return }
        tag(host: item.host, tmuxSession: t.session, id: win.sessionID)

        if !AX.trusted { AX.promptForTrust() }
        let (left, right) = Spaces.halves()
        await ITerm.setBounds(windowID: win.windowID, rect: left)
        await VSCode.open(item: item, frame: right)
        // Bring the terminal back in front: that's where Claude is waiting.
        _ = await ITerm.focus(uniqueID: win.sessionID)
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
