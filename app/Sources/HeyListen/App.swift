import AppKit
import ServiceManagement
import SwiftUI

@main
struct HeyListenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store, prefs: store.prefs)
        } label: {
            MenuLabel(count: store.attentionCount)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // `kill`/`pkill` (SIGTERM) should quit cleanly too, so watchers (ccwatch, ssh) don't outlive us.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src
        Notifier.shared.setUp()
        MainActor.assumeIsolated {
            Store.shared.start()
            StripController.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Store.shared.stopAll() }
    }
}

struct MenuLabel: View {
    let count: Int
    var body: some View {
        HStack(spacing: 2) {
            if let img = menuIcon { Image(nsImage: img) }
            if count > 0 { Text("\(count)") }
        }
    }

    /// Fairy silhouette ("Hey! Listen!") as a template image, so macOS tints it for the menu bar.
    /// 16x16 sprite drawn at exactly 1x: whole-number scale keeps the pixels crisp.
    private var menuIcon: NSImage? {
        guard let base = Sprites.image("fairy_menu") else { return nil }
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            NSGraphicsContext.current?.imageInterpolation = .none
            base.draw(in: r)
            return true
        }
        img.isTemplate = true
        return img
    }
}

struct MenuContent: View {
    @ObservedObject var store: Store
    @ObservedObject var prefs: Prefs

    var body: some View {
        let items = store.items
        if items.isEmpty { Text("No Claude sessions") }
        ForEach(items) { item in
            Button("\(symbol(item.mood))  \(item.project)  ·  \(item.wire.name)\(item.isLocal ? "" : "  @\(item.host)")") {
                Jumper.jump(item)
            }
            .disabled(!item.jumpable)
        }
        Divider()
        Toggle("Show strip", isOn: $prefs.stripVisible)
        Picker("Avatar size", selection: $prefs.avatarSize) {
            Text("Normal").tag("normal")
            Text("Mini").tag("mini")
        }
        Toggle("Open sessions in a new desktop", isOn: $prefs.newDesktop)
        Menu("Notifications") {
            Toggle("Needs permission", isOn: $prefs.notifyPermission)
            Toggle("Turn finished", isOn: $prefs.notifyReply)
            Divider()
            Toggle("Sound: permission", isOn: $prefs.soundPermission)
            Toggle("Sound: turn finished", isOn: $prefs.soundReply)
        }
        Menu("Hosts") {
            ForEach(store.hosts) { h in
                Button("\(h.name): \(h.status.label)  (\(h.sessions.count))") { store.reconnect(h.name) }
            }
            Divider()
            Button("Edit remote hosts…") { editHosts() }
        }
        Toggle("Launch at login", isOn: Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
        ))
        Menu("Debug") {
            Button("Grant Accessibility…") { AX.promptForTrust() }
            Button("Dump Mission Control tree") {
                Task { @MainActor in
                    let path = await Spaces.dumpMissionControlTree()
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
            }
        }
        Divider()
        Button("Quit heylisten") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func symbol(_ m: Mood) -> String {
        switch m {
        case .permission: return "❗"
        case .reply: return "💬"
        case .busy: return "⚙︎"
        case .idle: return "💤"
        case .offline: return "🔌"
        }
    }

    private func editHosts() {
        let alert = NSAlert()
        alert.messageText = "Remote hosts"
        alert.informativeText = "SSH aliases, comma-separated (run ./install.sh <host> on each first)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = prefs.remoteHosts.joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            prefs.remoteHosts = field.stringValue.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }
}
