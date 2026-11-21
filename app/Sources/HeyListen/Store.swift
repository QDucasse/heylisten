import AppKit
import Combine
import Foundation

/// Persistent preferences (UserDefaults).
final class Prefs: ObservableObject {
    private let d = UserDefaults.standard

    @Published var remoteHosts: [String] { didSet { d.set(remoteHosts, forKey: "remoteHosts") } }
    @Published var notifyPermission: Bool { didSet { d.set(notifyPermission, forKey: "notifyPermission") } }
    @Published var notifyReply: Bool { didSet { d.set(notifyReply, forKey: "notifyReply") } }
    @Published var soundPermission: Bool { didSet { d.set(soundPermission, forKey: "soundPermission") } }
    @Published var soundReply: Bool { didSet { d.set(soundReply, forKey: "soundReply") } }
    @Published var newDesktop: Bool { didSet { d.set(newDesktop, forKey: "newDesktop") } }
    @Published var stripVisible: Bool { didSet { d.set(stripVisible, forKey: "stripVisible") } }
    @Published var stripVertical: Bool { didSet { d.set(stripVertical, forKey: "stripVertical") } }
    @Published var showNames: Bool { didSet { d.set(showNames, forKey: "showNames") } }
    @Published var stripPinned: Bool { didSet { d.set(stripPinned, forKey: "stripPinned") } }
    /// "normal" (3x, 48 pt) or "mini" (2x, 32 pt).
    @Published var avatarSize: String { didSet { d.set(avatarSize, forKey: "avatarSize") } }

    init() {
        d.register(defaults: [
            "remoteHosts": [String](),
            "notifyPermission": true, "notifyReply": true,
            "soundPermission": true, "soundReply": false,
            "newDesktop": true, "stripVisible": true,
            "stripVertical": true, "showNames": false, "stripPinned": false, "avatarSize": "normal",
        ])
        remoteHosts = d.stringArray(forKey: "remoteHosts") ?? []
        notifyPermission = d.bool(forKey: "notifyPermission")
        notifyReply = d.bool(forKey: "notifyReply")
        soundPermission = d.bool(forKey: "soundPermission")
        soundReply = d.bool(forKey: "soundReply")
        newDesktop = d.bool(forKey: "newDesktop")
        stripVisible = d.bool(forKey: "stripVisible")
        stripVertical = d.bool(forKey: "stripVertical")
        showNames = d.bool(forKey: "showNames")
        stripPinned = d.bool(forKey: "stripPinned")
        avatarSize = d.string(forKey: "avatarSize") ?? "normal"
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    let prefs = Prefs()
    @Published private(set) var hosts: [HostState] = []
    /// sessionKey -> attention ts that the user has already seen (reply markers only).
    @Published private(set) var acked: [String: Double] = [:]
    /// Snapshot of what's currently in front in iTerm (refreshed while iTerm is frontmost).
    private(set) var front: ITerm.FrontSession?

    /// cwd -> palette slot, persisted so projects keep their colour across restarts.
    private var tints: [String: Int] = (UserDefaults.standard.dictionary(forKey: "tintSlots") as? [String: Int]) ?? [:]
    private var watchers: [String: HostWatcher] = [:]
    private var notified: Set<String> = []
    private var frontTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    func start() {
        rebuildHosts()
        prefs.$remoteHosts.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildHosts() }
        }.store(in: &cancellables)
        frontTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFront() }
        }
    }

    // MARK: hosts

    private func rebuildHosts() {
        let names = [localHostName] + prefs.remoteHosts.filter { !$0.isEmpty && $0 != localHostName }
        for (name, w) in watchers where !names.contains(name) {
            w.stop()
            watchers[name] = nil
        }
        var newHosts: [HostState] = []
        for n in names {
            if let existing = hosts.first(where: { $0.name == n }) {
                newHosts.append(existing)
            } else {
                newHosts.append(HostState(name: n))
                let w = HostWatcher(host: n) { [weak self] ev in
                    MainActor.assumeIsolated { self?.handle(host: n, event: ev) }
                }
                watchers[n] = w
                w.start()
            }
        }
        hosts = newHosts
    }

    func stopAll() {
        for w in watchers.values { w.stopNow() }
    }

    private func updateTints() {
        let visible = hosts.flatMap { $0.sessions.map(\.cwd) }
        let next = Tint.assign(visible: visible, previous: tints)
        if next != tints {
            tints = next
            UserDefaults.standard.set(tints, forKey: "tintSlots")
        }
    }

    private func tint(_ cwd: String) -> Int { tints[cwd] ?? Tint.hashIndex(cwd) }

    func reconnect(_ host: String) {
        watchers[host]?.stop()
        let w = HostWatcher(host: host) { [weak self] ev in
            MainActor.assumeIsolated { self?.handle(host: host, event: ev) }
        }
        watchers[host] = w
        w.start()
    }

    private func handle(host: String, event: HostWatcher.Event) {
        guard let i = hosts.firstIndex(where: { $0.name == host }) else { return }
        switch event {
        case .message(let m):
            switch m.type {
            case "hello":
                let v = m.version ?? 0
                hosts[i].status = v < expectedWatcherVersion ? .outdated(v) : .online
            case "snapshot":
                if !hosts[i].status.isUsable { hosts[i].status = .online }
                hosts[i].sessions = m.sessions ?? []
                hosts[i].tmux = m.tmux
                updateTints()
                let seed = !hosts[i].seededNotifications
                hosts[i].seededNotifications = true
                processAttention(host: host, seedOnly: seed)
            default:
                break
            }
        case .disconnected(let reason, let notInstalled):
            hosts[i].status = notInstalled ? .notInstalled : .offline(reason)
            // keep the last known sessions so avatars stay visible (rendered as offline)
        }
    }

    // MARK: items

    var items: [SessionItem] {
        hosts.flatMap { h in
            h.sessions.map { s in
                SessionItem(host: h.name, wire: s, mood: mood(host: h, s: s), hostOnline: h.status.isUsable, tint: tint(s.cwd))
            }
        }
    }

    func itemsByHost() -> [(host: HostState, items: [SessionItem])] {
        hosts.map { h in
            (h, h.sessions.map {
                SessionItem(host: h.name, wire: $0, mood: mood(host: h, s: $0), hostOnline: h.status.isUsable, tint: tint($0.cwd))
            })
        }
    }

    var attentionCount: Int {
        items.filter { $0.mood == .permission || $0.mood == .reply }.count
    }

    private func key(_ host: String, _ s: WireSession) -> String {
        "\(host)|\(s.sessionId.isEmpty ? String(s.pid) : s.sessionId)"
    }

    private func mood(host h: HostState, s: WireSession) -> Mood {
        if !h.status.isUsable { return .offline }
        if s.attention?.state == "permission" { return .permission }
        if s.status == "busy" { return .busy }
        if let a = s.attention, a.state == "reply", a.ts > (acked[key(h.name, s)] ?? 0) { return .reply }
        return .idle
    }

    func acknowledge(_ item: SessionItem) {
        if let a = item.wire.attention { acked[item.id] = a.ts }
    }

    // MARK: notifications

    private func processAttention(host: String, seedOnly: Bool) {
        guard let h = hosts.first(where: { $0.name == host }) else { return }
        for s in h.sessions {
            guard let a = s.attention else { continue }
            let nkey = "\(key(host, s))|\(a.state)|\(a.ts)"
            if notified.contains(nkey) { continue }
            notified.insert(nkey)
            if seedOnly { continue }
            let item = SessionItem(host: host, wire: s, mood: mood(host: h, s: s), hostOnline: true, tint: tint(s.cwd))
            let wanted = a.state == "permission" ? prefs.notifyPermission : prefs.notifyReply
            guard wanted else { continue }
            Task { @MainActor in
                let inFront = await self.isInFront(item)
                if inFront {
                    if a.state == "reply" { self.acknowledge(item) }
                    return
                }
                Notifier.shared.post(item: item, sound: a.state == "permission" ? self.prefs.soundPermission : self.prefs.soundReply)
            }
        }
        if notified.count > 2000 { notified.removeAll() }
    }

    // MARK: "in front" detection

    func isInFront(_ item: SessionItem) async -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ITerm.bundleID else { return false }
        guard let f = await ITerm.frontSession() else { return false }
        front = f
        return matchesFront(item, f)
    }

    private func matchesFront(_ item: SessionItem, _ f: ITerm.FrontSession) -> Bool {
        guard let host = hosts.first(where: { $0.name == item.host }) else { return false }
        if item.isLocal {
            if let t = item.wire.tmux {
                return host.tmux?.clients.contains { $0.tty == f.tty && $0.session == t.session && $0.pane == t.pane } ?? false
            }
            return item.wire.tty == f.tty
        }
        guard let t = item.wire.tmux, Jumper.taggedSession(host: item.host, tmuxSession: t.session) == f.uniqueID else {
            return false
        }
        return host.tmux?.sessions.contains { $0.name == t.session && $0.pane == t.pane } ?? false
    }

    private func refreshFront() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ITerm.bundleID else { return }
        Task { @MainActor in
            guard let f = await ITerm.frontSession() else { return }
            self.front = f
            for item in self.items where item.mood == .reply && self.matchesFront(item, f) {
                self.acknowledge(item)
            }
        }
    }
}
