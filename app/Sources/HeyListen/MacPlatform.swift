import AppKit
import Foundation

// macOS backends (Platform.swift): thin adapters over ITerm, VSCode, Spaces, WindowTiler and
// Notifier, which keep the actual AppleScript / Accessibility / Mission Control code.

@MainActor
struct ITermTerminal: TerminalBackend {
    func frontSession() async -> TerminalSession? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ITerm.bundleID,
              let f = await ITerm.frontSession() else { return nil }
        return TerminalSession(tty: f.tty, id: f.uniqueID)
    }

    func focus(tty: String) async -> Bool { await ITerm.focus(tty: tty) }
    func focus(session id: String) async -> Bool { await ITerm.focus(uniqueID: id) }
    func session(titled title: String) async -> String? { await ITerm.session(withTitle: title) }
    func currentWindow() async -> String? { await ITerm.currentWindowID() }

    func open(running command: String, for item: SessionItem) async -> TerminalWindow? {
        guard let w = await ITerm.newWindow(running: command) else { return nil }
        return TerminalWindow(session: w.sessionID, window: w.windowID)
    }

    func place(window: String, frame: CGRect) async { await ITerm.setBounds(windowID: window, rect: frame) }
}

@MainActor
struct VSCodeEditor: EditorBackend {
    func hasWindow(for item: SessionItem) async -> Bool? { await VSCode.hasWindow(for: item) }

    func open(_ item: SessionItem, frame: CGRect) async {
        if !AX.trusted { AX.promptForTrust() }   // needed to place the window
        await VSCode.open(item: item, frame: frame)
    }
}

@MainActor
struct MacWorkspace: WorkspaceBackend {
    func newWorkspace() async -> Bool { await Spaces.createDesktopAndSwitch() }

    func tiles() -> (terminal: CGRect, editor: CGRect) {
        let (left, right) = Spaces.halves()
        return (left, right)
    }
}

@MainActor
struct MacAlerts: AlertBackend {
    func notify(_ alert: Alert, item: SessionItem) { Notifier.shared.post(alert) }
    func beep() { NSSound.beep() }
}
