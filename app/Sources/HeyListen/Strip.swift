import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating, always-on-top panel.
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect = .zero) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum StripLayout {
    static let padding: CGFloat = 6
    static let spacing: CGFloat = 4
    static let barHeight: CGFloat = 16
}

/// The floating widget: moves anywhere (grip), sizes itself to its content (anchored at its top-left
/// corner), and has two toggles in its top bar: orientation and project names.
@MainActor
final class StripController: ObservableObject {
    static let shared = StripController()

    private let panel = FloatingPanel()
    private let hoverPanel = FloatingPanel()
    private var hosting: NSHostingView<AnyView>!
    private var cancellables: Set<AnyCancellable> = []
    private var dragOrigin: NSPoint?
    /// True while dragging and briefly after, so the mouse-up of a drag that started on an avatar
    /// doesn't count as a click.
    private(set) var suppressClicks = false
    /// Top-left corner of the widget (Cocoa coordinates), so it grows down/right as content changes.
    private var anchor: NSPoint

    private init() {
        hoverPanel.ignoresMouseEvents = true
        if let s = UserDefaults.standard.string(forKey: "stripAnchor") {
            anchor = NSPointFromString(s)
        } else {
            let vf = (NSScreen.screens.first ?? NSScreen.main!).visibleFrame
            anchor = NSPoint(x: vf.maxX - 80, y: vf.midY + 200)
        }
    }

    func start() {
        let store = Store.shared
        hosting = NSHostingView(rootView: AnyView(StripView(store: store, prefs: store.prefs, controller: self)))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        store.objectWillChange.merge(with: store.prefs.objectWillChange)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &cancellables)
        layout()
    }

    func layout() {
        guard Store.shared.prefs.stripVisible else { panel.orderOut(nil); hoverPanel.orderOut(nil); return }
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(width: hosting.fittingSize.width.rounded(.up), height: hosting.fittingSize.height.rounded(.up))
        var f: NSRect
        if Store.shared.prefs.stripPinned {
            // Locked: top-right corner of the main display, growing left and down.
            let vf = (NSScreen.screens.first ?? NSScreen.main!).visibleFrame
            let m: CGFloat = 8
            f = NSRect(x: vf.maxX - size.width - m, y: vf.maxY - size.height - m, width: size.width, height: size.height)
        } else {
            f = NSRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height)
        }
        f = clampToScreen(f)
        panel.setFrame(f, display: true)
        panel.orderFrontRegardless()
    }

    /// Keep the whole widget on the screen it's (mostly) on.
    private func clampToScreen(_ r: NSRect) -> NSRect {
        let screen = NSScreen.screens.max { a, b in
            let ia = a.visibleFrame.intersection(r), ib = b.visibleFrame.intersection(r)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        } ?? NSScreen.main!
        let vf = screen.visibleFrame
        var o = r.origin
        o.x = min(max(o.x, vf.minX), vf.maxX - r.width)
        o.y = min(max(o.y, vf.minY), vf.maxY - r.height)
        return NSRect(x: o.x.rounded(), y: o.y.rounded(), width: r.width, height: r.height)
    }

    // MARK: moving (grip)

    func dragChanged() {
        guard !Store.shared.prefs.stripPinned else { return }
        suppressClicks = true
        hover(nil, frameInPanel: .zero)
        let m = NSEvent.mouseLocation
        if dragOrigin == nil { dragOrigin = NSPoint(x: m.x - panel.frame.minX, y: m.y - panel.frame.minY) }
        guard let d = dragOrigin else { return }
        panel.setFrameOrigin(NSPoint(x: (m.x - d.x).rounded(), y: (m.y - d.y).rounded()))
    }

    func dragEnded() {
        guard !Store.shared.prefs.stripPinned else { return }
        dragOrigin = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.suppressClicks = false }
        let f = clampToScreen(panel.frame)
        anchor = NSPoint(x: f.minX, y: f.maxY)
        UserDefaults.standard.set(NSStringFromPoint(anchor), forKey: "stripAnchor")
        layout()
    }

    // MARK: hover card

    func hover(_ item: SessionItem?, frameInPanel: CGRect) {
        guard let item, dragOrigin == nil else {
            hoverPanel.orderOut(nil)
            return
        }
        let card = NSHostingView(rootView: HoverCard(item: item))
        card.layoutSubtreeIfNeeded()
        let size = card.fittingSize
        hoverPanel.contentView = card
        // SwiftUI .global frames are top-left based inside the panel.
        let pf = panel.frame
        let avatar = NSRect(x: pf.minX + frameInPanel.minX, y: pf.maxY - frameInPanel.maxY,
                            width: frameInPanel.width, height: frameInPanel.height)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: avatar.midX, y: avatar.midY)) }
            ?? panel.screen ?? NSScreen.main!
        let vf = screen.visibleFrame
        let gap: CGFloat = 8
        var x: CGFloat, y: CGFloat
        if Store.shared.prefs.stripVertical {
            // Beside the widget, on the side with more room.
            x = (pf.minX - vf.minX) >= (vf.maxX - pf.maxX) ? pf.minX - size.width - gap : pf.maxX + gap
            y = avatar.midY - size.height / 2
        } else {
            // Above or below the widget, whichever has more room.
            x = avatar.midX - size.width / 2
            y = (vf.maxY - pf.maxY) >= (pf.minY - vf.minY) ? pf.maxY + gap : pf.minY - size.height - gap
        }
        x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
        y = min(max(y, vf.minY + 4), vf.maxY - size.height - 4)
        hoverPanel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
        hoverPanel.orderFrontRegardless()
    }
}

// MARK: - Views

struct StripView: View {
    @ObservedObject var store: Store
    @ObservedObject var prefs: Prefs
    let controller: StripController

    var body: some View {
        let groups = store.itemsByHost().filter { !$0.items.isEmpty }
        let vertical = prefs.stripVertical
        // Toggles sit on top in vertical mode and on the left in horizontal mode.
        outer(vertical) {
            TopBar(prefs: prefs, vertical: vertical)
            stack(vertical) {
                ForEach(groups, id: \.host.id) { g in
                    let items = stack(vertical) {
                        ForEach(g.items) { item in
                            ItemView(item: item, showName: prefs.showNames, scale: prefs.avatarSize == "mini" ? 2 : 3,   // whole-number scales: 48 pt / 32 pt
                                     controller: controller)
                        }
                    }
                    if g.host.isLocal {
                        items
                    } else {
                        // Remote hosts sit in a subtle tray instead of a text header; the host name is
                        // in the names line and the hover card.
                        items
                            .padding(3)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(g.host.status.isUsable ? 0.07 : 0.03)))
                            .help("\(g.host.name): \(g.host.status.label)")
                    }
                }
            }
            // Separator between the toggles and the avatars, drawn as an edge of the avatar area so it
            // always spans it: a vertical line on its left (horizontal mode), a horizontal line on top
            // (vertical mode).
            .padding(vertical ? .top : .leading, 5)
            .overlay(alignment: vertical ? .top : .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: vertical ? nil : 1, height: vertical ? 1 : nil)
            }
        }
        .padding(StripLayout.padding)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08)))
        )
        .fixedSize()
        // Drag from anywhere (background, bar, or an avatar) to move the widget.
        .simultaneousGesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in controller.dragChanged() }
            .onEnded { _ in controller.dragEnded() })
    }

    @ViewBuilder
    private func outer<C: View>(_ vertical: Bool, @ViewBuilder _ c: () -> C) -> some View {
        if vertical {
            VStack(alignment: .trailing, spacing: StripLayout.spacing) { c() }
        } else {
            HStack(alignment: .center, spacing: StripLayout.spacing) { c() }
        }
    }

    @ViewBuilder
    private func stack<C: View>(_ vertical: Bool, @ViewBuilder _ c: () -> C) -> some View {
        if vertical {
            VStack(alignment: .leading, spacing: StripLayout.spacing) { c() }
        } else {
            HStack(alignment: .center, spacing: StripLayout.spacing) { c() }
        }
    }
}

/// Orientation toggle + names toggle (the whole widget is draggable, so no grip).
struct TopBar: View {
    @ObservedObject var prefs: Prefs
    let vertical: Bool   // widget orientation: bar is a row on top (vertical) or a column on the left

    var body: some View {
        let layout = vertical ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
        layout {
            BarButton(symbol: prefs.stripVertical ? "arrow.left.and.right" : "arrow.up.and.down",
                      help: prefs.stripVertical ? "Lay out horizontally" : "Lay out vertically",
                      active: false) { prefs.stripVertical.toggle() }
            BarButton(symbol: "textformat", help: prefs.showNames ? "Hide project names" : "Show project names",
                      active: prefs.showNames) { prefs.showNames.toggle() }
            BarButton(symbol: prefs.stripPinned ? "lock.fill" : "lock.open",
                      help: prefs.stripPinned ? "Unlock (float freely)" : "Lock to the top-right corner",
                      active: prefs.stripPinned) { prefs.stripPinned.toggle() }
        }
    }
}

struct BarButton: View {
    let symbol: String
    let help: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: StripLayout.barHeight, height: StripLayout.barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// One session: the avatar, optionally followed by the project name and state.
struct ItemView: View {
    let item: SessionItem
    let showName: Bool
    /// Passed in (not read from a global) so SwiftUI re-renders when the avatar size changes.
    let scale: CGFloat
    let controller: StripController

    var body: some View {
        Button { if !controller.suppressClicks { Jumper.jump(item) } } label: {
            HStack(spacing: 6) {
                AvatarView(item: item, scale: scale)
                    .frame(width: Sprites.avatarPixels * scale, height: Sprites.avatarPixels * scale)
                if showName {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.project)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(item.mood == .permission ? Color.red : Color.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 140, alignment: .leading)
                    .padding(.trailing, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Measure our frame (behind the button), but take hover on the button itself: a view behind
        // the button never receives hover events.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { frame = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { _, f in frame = f }
        })
        .onHover { inside in
            controller.hover(inside ? item : nil, frameInPanel: frame)
        }
    }

    @State private var frame: CGRect = .zero

    private var subtitle: String {
        let state: String
        switch item.mood {
        case .busy: state = "working"
        case .idle: state = "idle"
        case .permission: state = "needs permission"
        case .reply: state = "waiting for you"
        case .offline: state = "offline"
        }
        return item.isLocal ? state : "\(state) · \(item.host)"
    }
}

struct HoverCard: View {
    let item: SessionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(Tint.color(item.tint)).frame(width: 10, height: 10)
                Text(item.project).font(.system(size: 15, weight: .semibold))
            }
            row("session", item.wire.name)
            row("host", item.host)
            if let t = item.wire.tmux { row("tmux", "\(t.session) \(t.window) \(t.pane)") }
            row("state", stateText)
            if let m = item.wire.attention?.message, !m.isEmpty {
                Text(m).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: 320, alignment: .leading)
            }
            Text(item.wire.cwd).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head).frame(maxWidth: 320, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .fixedSize()
    }

    private var stateText: String {
        switch item.mood {
        case .busy: return "working"
        case .idle: return "idle"
        case .permission: return "needs permission"
        case .reply: return "waiting for your reply"
        case .offline: return "host offline"
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(k).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
            Text(v).font(.system(size: 13, design: .monospaced))
        }
    }
}
