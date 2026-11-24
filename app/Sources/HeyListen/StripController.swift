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
    /// Recreated if it ever stops showing on the current Space (see showHover).
    private var hoverPanel = StripController.makeHoverPanel()
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

    private static func makeHoverPanel() -> FloatingPanel {
        let p = FloatingPanel()
        p.ignoresMouseEvents = true
        p.animationBehavior = .none   // no fade/zoom when it shows: just appear
        return p
    }

    private init() {
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
        startHoverTracking()
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
            hideHover()
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

    /// How long the pointer has to rest on an avatar before its card shows, so sweeping across the
    /// strip doesn't flash a card for every avatar it passes.
    static let hoverDelay: TimeInterval = 0.2
    /// The avatar under the pointer, and since when.
    private var hoveredID: String?
    private var hoveredSince = Date.distantPast
    private var cardShown = false
    private var hoverTimer: Timer?

    /// Hover is worked out from the pointer position and the avatars' reported frames, polled, not
    /// from SwiftUI's onHover: after the strip relaid out (a session went away), the avatars that
    /// were already there got an exit right after every enter, so their card never showed.
    private func startHoverTracking() {
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackHover() }
        }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    private func trackHover() {
        let m = NSEvent.mouseLocation
        let pf = panel.frame
        guard dragMode == .none, panel.isVisible, pf.contains(m) else {
            if hoveredID != nil { hideHover() }
            return
        }
        // SwiftUI .global frames are top-left based inside the panel.
        let p = CGPoint(x: m.x - pf.minX, y: pf.maxY - m.y)
        // Only sessions that still exist: a removed avatar's onDisappear doesn't always fire, so its
        // last frame can linger in itemFrames and overlap the avatar that slid into its place.
        let items = Store.shared.itemsByHost().flatMap(\.items)
        let live = Set(items.map(\.id))
        itemFrames = itemFrames.filter { live.contains($0.key) }
        let id = itemFrames.first { $0.value.contains(p) }?.key
        if id != hoveredID {
            hideHover()
            hoveredID = id
            hoveredSince = Date()
            return
        }
        guard let id, !cardShown, Date().timeIntervalSince(hoveredSince) >= Self.hoverDelay,
              let frame = itemFrames[id],
              let item = items.first(where: { $0.id == id }) else { return }
        showHover(item, frameInPanel: frame)
        cardShown = true
    }

    private func hideHover() {
        hoveredID = nil
        cardShown = false
        hoverPanel.orderOut(nil)
    }

    private func showHover(_ item: SessionItem, frameInPanel: CGRect) {
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
        let target = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        hoverPanel.setFrame(target, display: true)
        hoverPanel.orderFrontRegardless()
        // After a Space is removed, a panel that was ordered out can come back stuck to a Space
        // other than the one on screen: start over with a fresh panel.
        if !hoverPanel.isOnActiveSpace {
            hlog("hover: card panel not on the active Space, recreating it")
            hoverPanel.orderOut(nil)
            hoverPanel.close()   // not released on close, but leaves AppKit's window list
            hoverPanel = Self.makeHoverPanel()
            hoverPanel.contentView = card
            hoverPanel.setFrame(target, display: true)
            hoverPanel.orderFrontRegardless()
        }
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
