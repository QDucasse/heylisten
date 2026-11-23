import AppKit
import SwiftUI

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
