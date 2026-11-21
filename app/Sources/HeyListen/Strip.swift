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
    /// Between avatars (and host groups): room for the badges that stick out of each avatar.
    static let itemSpacing: CGFloat = 10
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
    /// What the current drag does, decided where it starts: on an avatar it reorders, elsewhere it
    /// moves the widget (or nothing, when locked).
    private enum DragMode { case none, move, reorder, ignore }
    private var dragMode: DragMode = .none
    /// Avatars' layout frames (SwiftUI global coordinates), reported by each ItemView.
    var itemFrames: [String: CGRect] = [:]
    let reorder = ReorderState()
    private struct ReorderContext {
        let id: String
        let ids: [String]            // the host group, in display order at drag start
        let keys: [String: String]   // id -> orderKey
        let index: Int
        var target: Int
    }
    private var reorderCtx: ReorderContext?
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
            // Locked: top-right corner of the screen the widget is on (where its free position
            // is), growing left and down.
            let vf = anchorScreen.visibleFrame
            let m: CGFloat = 8
            f = NSRect(x: vf.maxX - size.width - m, y: vf.maxY - size.height - m, width: size.width, height: size.height)
        } else {
            f = NSRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height)
        }
        f = clampToScreen(f)
        panel.setFrame(f, display: true)
        panel.orderFrontRegardless()
    }

    /// The screen holding the widget's free (unlocked) position; the main screen if that one is
    /// gone. Probed just inside the top-left corner, since the anchor can sit on a screen edge.
    private var anchorScreen: NSScreen {
        let probe = NSPoint(x: anchor.x + 1, y: anchor.y - 1)
        return NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.screens.first ?? NSScreen.main!
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

    // MARK: dragging: move the widget, or reorder avatars

    func dragChanged(_ v: DragGesture.Value) {
        if dragMode == .none {
            suppressClicks = true
            hover(nil, frameInPanel: .zero)
            if let id = itemFrames.first(where: { $0.value.contains(v.startLocation) })?.key, beginReorder(id) {
                dragMode = .reorder
            } else {
                dragMode = Store.shared.prefs.stripPinned ? .ignore : .move
            }
        }
        switch dragMode {
        case .move:
            let m = NSEvent.mouseLocation
            if dragOrigin == nil { dragOrigin = NSPoint(x: m.x - panel.frame.minX, y: m.y - panel.frame.minY) }
            guard let d = dragOrigin else { return }
            panel.setFrameOrigin(NSPoint(x: (m.x - d.x).rounded(), y: (m.y - d.y).rounded()))
        case .reorder:
            updateReorder(v.translation)
        case .none, .ignore:
            break
        }
    }

    func dragEnded() {
        let mode = dragMode
        dragMode = .none
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.suppressClicks = false }
        switch mode {
        case .move:
            dragOrigin = nil
            let f = clampToScreen(panel.frame)
            anchor = NSPoint(x: f.minX, y: f.maxY)
            UserDefaults.standard.set(NSStringFromPoint(anchor), forKey: "stripAnchor")
            layout()
        case .reorder:
            endReorder()
        case .none, .ignore:
            break
        }
    }

    /// Start reordering within the avatar's host group (a lone avatar has nothing to swap with, so
    /// dragging it moves the widget instead).
    private func beginReorder(_ id: String) -> Bool {
        guard let g = Store.shared.itemsByHost().first(where: { $0.items.contains { $0.id == id } }),
              g.items.count > 1, let i = g.items.firstIndex(where: { $0.id == id }) else { return false }
        reorderCtx = ReorderContext(id: id, ids: g.items.map(\.id),
                                    keys: Dictionary(g.items.map { ($0.id, $0.orderKey) }, uniquingKeysWith: { a, _ in a }),
                                    index: i, target: i)
        reorder.draggingID = id
        reorder.offset = 0
        reorder.shifts = [:]
        return true
    }

    /// The dragged avatar follows the mouse along the strip's axis; the others slide aside, animated,
    /// to open the slot it would drop into. The real order only changes on drop.
    private func updateReorder(_ t: CGSize) {
        guard var ctx = reorderCtx, let f = itemFrames[ctx.id] else { return }
        let vertical = Store.shared.prefs.stripVertical
        let d = vertical ? t.height : t.width
        reorder.offset = d
        let mid = { (r: CGRect) in vertical ? r.midY : r.midX }
        let others = ctx.ids.filter { $0 != ctx.id }
        let center = mid(f) + d
        let target = others.filter { o in itemFrames[o].map { mid($0) < center } ?? false }.count
        guard target != ctx.target else { return }
        ctx.target = target
        reorderCtx = ctx
        let step = (vertical ? f.height : f.width) + StripLayout.itemSpacing
        var shifts: [String: CGFloat] = [:]
        for (k, o) in others.enumerated() {
            let j = k < ctx.index ? k : k + 1   // original position
            if j > ctx.index && k < target { shifts[o] = -step }
            if j < ctx.index && k >= target { shifts[o] = step }
        }
        withAnimation(.easeOut(duration: 0.15)) { reorder.shifts = shifts }
    }

    private func endReorder() {
        guard let ctx = reorderCtx else { return }
        reorderCtx = nil
        var ids = ctx.ids.filter { $0 != ctx.id }
        ids.insert(ctx.id, at: min(ctx.target, ids.count))
        withAnimation(.easeOut(duration: 0.15)) {
            if ctx.target != ctx.index { Store.shared.setOrder(ids.compactMap { ctx.keys[$0] }) }
            reorder.draggingID = nil
            reorder.offset = 0
            reorder.shifts = [:]
        }
    }

    // MARK: hover card

    func hover(_ item: SessionItem?, frameInPanel: CGRect) {
        guard let item, dragMode == .none else {
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

/// Live drag-to-reorder state the avatars render from.
@MainActor
final class ReorderState: ObservableObject {
    @Published var draggingID: String?
    /// The dragged avatar's displacement along the strip's axis.
    @Published var offset: CGFloat = 0
    /// Other avatars' displacement while they make room.
    @Published var shifts: [String: CGFloat] = [:]
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
                                     vertical: vertical, controller: controller, reorder: controller.reorder)
                        }
                    }
                    if g.host.isLocal {
                        items
                    } else {
                        HostSection(host: g.host, vertical: vertical) { items }
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
        // Drag an avatar to reorder it within its host; drag anywhere else to move the widget.
        .simultaneousGesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { controller.dragChanged($0) }
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
            VStack(alignment: .leading, spacing: StripLayout.itemSpacing) { c() }
        } else {
            HStack(alignment: .center, spacing: StripLayout.itemSpacing) { c() }
        }
    }
}

/// A remote host's group: a rule along its leading edge with the host's name and connection dot.
/// Vertical strip: rule on top, name below it. Horizontal strip: rule on the left, name rotated
/// to read bottom-to-top beside it, so it costs a text line's height rather than its width.
struct HostSection<Content: View>: View {
    let host: HostState
    let vertical: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if vertical {
                VStack(alignment: .leading, spacing: 4) { label; content() }
                    .padding(.top, 5)
            } else {
                HStack(alignment: .center, spacing: 4) {
                    Rotated90 { label.rotationEffect(.degrees(-90)) }
                    content()
                }
                .padding(.leading, 5)
            }
        }
        // Drawn as an edge of the section (like the toggle separator) so it spans it exactly.
        .overlay(alignment: vertical ? .top : .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: vertical ? nil : 1, height: vertical ? 1 : nil)
        }
        .help("\(host.name): \(host.status.label)")
    }

    private var label: some View {
        HStack(spacing: 3) {
            Circle().fill(dotColor).frame(width: 5, height: 5)
            Text(host.name.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var dotColor: Color {
        switch host.status {
        case .online: return .green
        case .connecting, .outdated: return .orange
        case .offline, .notInstalled: return .gray
        }
    }
}

/// Lays out its single child rotated a quarter turn: reports the child's size with width and
/// height swapped (rotationEffect alone only changes how it's drawn, not the space it takes).
struct Rotated90: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first?.sizeThatFits(.unspecified) else { return .zero }
        return CGSize(width: s.height, height: s.width)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let v = subviews.first else { return }
        let s = v.sizeThatFits(.unspecified)
        v.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                proposal: ProposedViewSize(width: s.width, height: s.height))
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
    let vertical: Bool
    let controller: StripController
    @ObservedObject var reorder: ReorderState

    var body: some View {
        let dragging = reorder.draggingID == item.id
        let o = dragging ? reorder.offset : (reorder.shifts[item.id] ?? 0)
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
                            .foregroundStyle(item.mood == .permission || item.mood == .error ? Color.red : Color.secondary)
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
        // Layout frame, measured before the reorder offset so drags compare slots, not positions.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { setFrame(geo.frame(in: .global)) }
                .onChange(of: geo.frame(in: .global)) { _, f in setFrame(f) }
                .onDisappear { controller.itemFrames[item.id] = nil }
        })
        .onHover { inside in
            controller.hover(inside ? item : nil, frameInPanel: frame)
        }
        .offset(x: vertical ? 0 : o, y: vertical ? o : 0)
        .zIndex(dragging ? 1 : 0)
        .opacity(dragging ? 0.85 : 1)
    }

    private func setFrame(_ f: CGRect) {
        frame = f
        controller.itemFrames[item.id] = f
    }

    @State private var frame: CGRect = .zero

    private var subtitle: String {
        let state: String
        switch item.mood {
        case .busy: state = "working"
        case .idle: state = "parked (not open)"
        case .permission: state = "needs permission"
        case .error: state = "stopped on an error"
        case .reply: state = "just finished"
        case .waiting: state = "waiting for you"
        case .offline: state = "offline"
        }
        return state   // the host is in the section header
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
            if let t = item.wire.contextTokens {
                row("context", "\(t / 1000)k of \(ContextLevel.window / 1000)k (\(t * 100 / ContextLevel.window)%)")
            }
            if item.cacheCold { row("cache", "expired: the next message re-reads the context") }
            if item.wire.compacting == true { row("context", "compacting…") }
            if let n = item.wire.subagents, n > 0 { row("subagents", "\(n) running") }
            if item.wire.longTurn == true { row("turn", "running for over 10 min") }
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
        case .idle: return "parked: not open in any terminal"
        case .permission: return "needs permission"
        case .error: return "stopped on an API error"
        case .reply: return "turn finished, not seen yet"
        case .waiting: return "waiting for your next message"
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
