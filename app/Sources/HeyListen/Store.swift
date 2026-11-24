import AppKit
import Combine
import Foundation

/// Persistent preferences (UserDefaults).
final class Prefs: ObservableObject {
    private let d = UserDefaults.standard

    @Published var remoteHosts: [String] { didSet { d.set(remoteHosts, forKey: "remoteHosts") } }
    @Published var newDesktop: Bool { didSet { d.set(newDesktop, forKey: "newDesktop") } }
    @Published var stripVisible: Bool { didSet { d.set(stripVisible, forKey: "stripVisible") } }
    @Published var stripVertical: Bool { didSet { d.set(stripVertical, forKey: "stripVertical") } }
    @Published var showNames: Bool { didSet { d.set(showNames, forKey: "showNames") } }
    @Published var stripPinned: Bool { didSet { d.set(stripPinned, forKey: "stripPinned") } }
    /// "normal" (3x, 48 pt) or "mini" (2x, 32 pt).
    @Published var avatarSize: String { didSet { d.set(avatarSize, forKey: "avatarSize") } }
    /// User-chosen avatar order, as SessionItem.orderKey values (host + project dir). Keys not
    /// listed sort after listed ones, in arrival order.
    @Published var itemOrder: [String] { didSet { d.set(itemOrder, forKey: "itemOrder") } }

    init() {
        d.register(defaults: [
            "remoteHosts": [String](),
            "newDesktop": true, "stripVisible": true,
            "stripVertical": true, "showNames": false, "stripPinned": false, "avatarSize": "normal",
        ])
        remoteHosts = d.stringArray(forKey: "remoteHosts") ?? []
        newDesktop = d.bool(forKey: "newDesktop")
        stripVisible = d.bool(forKey: "stripVisible")
        stripVertical = d.bool(forKey: "stripVertical")
        showNames = d.bool(forKey: "showNames")
        stripPinned = d.bool(forKey: "stripPinned")
        avatarSize = d.string(forKey: "avatarSize") ?? "normal"
        itemOrder = d.stringArray(forKey: "itemOrder") ?? []
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
    private(set) var front: TerminalSession?

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
                if let t = m.time { hosts[i].clockOffset = Date().timeIntervalSince1970 - t }
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

    /// Every session, hosts in order, each host's sessions in the user's chosen order.
    var items: [SessionItem] { itemsByHost().flatMap(\.items) }

    func itemsByHost() -> [(host: HostState, items: [SessionItem])] {
        let rank = Dictionary(prefs.itemOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return hosts.map { h in
            let items = h.sessions.map {
                SessionItem(host: h.name, wire: $0, mood: mood(host: h, s: $0), hostOnline: h.status.isUsable, tint: tint($0.cwd),
                            clockOffset: h.clockOffset)
            }
            // Stable: unranked projects (and sessions sharing a project) keep their arrival order.
            let sorted = items.enumerated().sorted { a, b in
                let ra = rank[a.element.orderKey] ?? .max, rb = rank[b.element.orderKey] ?? .max
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element)
            return (h, sorted)
        }
    }

    /// Record a host group's new order (keys in display order). Other hosts' keys are kept.
    func setOrder(_ keys: [String]) {
        var seen = Set<String>()
        let unique = keys.filter { seen.insert($0).inserted }
        let kept = prefs.itemOrder.filter { !seen.contains($0) }
        prefs.itemOrder = Array((kept + unique).suffix(300))   // bounded: stale projects age out
    }

    private func key(_ host: String, _ s: WireSession) -> String {
        "\(host)|\(s.sessionId.isEmpty ? String(s.pid) : s.sessionId)"
    }

    private func mood(host h: HostState, s: WireSession) -> Mood {
        if !h.status.isUsable { return .offline }
        if s.attention?.state == "permission" { return .permission }
        if s.status == "busy" { return .busy }
        if s.attention?.state == "error" { return .error }
        guard isOpen(host: h, s: s) else { return .idle }
        if let a = s.attention, a.state == "reply", a.ts > (acked[key(h.name, s)] ?? 0) { return .reply }
        return .waiting
    }

    /// Open = some tmux client is attached to the session (any terminal, any machine). Sessions
    /// outside tmux count as open: a local one lives in a terminal tab, and for a remote one we
    /// can't tell, so we'd rather show ? than a possibly wrong zzz.
    private func isOpen(host h: HostState, s: WireSession) -> Bool {
        guard let t = s.tmux else { return true }
        return (h.tmux?.sessions.first { $0.name == t.session }?.attached ?? 0) > 0
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
            let item = SessionItem(host: host, wire: s, mood: mood(host: h, s: s), hostOnline: true, tint: tint(s.cwd),
                                   clockOffset: h.clockOffset)
            Task { @MainActor in
                let inFront = await self.isInFront(item)
                if inFront {
                    if a.state == "reply" { self.acknowledge(item) }
                    return
                }
                // Sound only when the work is stuck: a finished turn can wait, a blocked one can't.
                Platform.alerts.notify(Alert(item: item, sound: a.state != "reply"), item: item)
            }
        }
        if notified.count > 2000 { notified.removeAll() }
    }

    // MARK: "in front" detection

    func isInFront(_ item: SessionItem) async -> Bool {
        guard let f = await Platform.terminal.frontSession() else { return false }
        front = f
        return matchesFront(item, f)
    }

    private func matchesFront(_ item: SessionItem, _ f: TerminalSession) -> Bool {
        guard let host = hosts.first(where: { $0.name == item.host }) else { return false }
        if item.isLocal {
            if let t = item.wire.tmux {
                return host.tmux?.clients.contains { $0.tty == f.tty && $0.session == t.session && $0.pane == t.pane } ?? false
            }
            return item.wire.tty == f.tty
        }
        guard let t = item.wire.tmux, Jumper.taggedSession(host: item.host, tmuxSession: t.session) == f.id else {
            return false
        }
        return host.tmux?.sessions.contains { $0.name == t.session && $0.pane == t.pane } ?? false
    }

    private var refreshingFront = false

    /// One poll at a time: when iTerm is slow to answer (osascript can wait up to 20 s), polls
    /// started every 3 s would otherwise pile up.
    private func refreshFront() {
        guard !refreshingFront else { return }
        refreshingFront = true
        Task { @MainActor in
            defer { self.refreshingFront = false }
            guard let f = await Platform.terminal.frontSession() else { return }
            self.front = f
            for item in self.items where item.mood == .reply && self.matchesFront(item, f) {
                self.acknowledge(item)
            }
        }
    }
}
