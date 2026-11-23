import SwiftUI

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
            if let t = item.wire.contextTokens, let w = item.wire.contextWindow, w > 0 {
                row("context", "\(t / 1000)k of \(w / 1000)k (\(t * 100 / w)%)")
            }
            if let m = item.wire.model, !m.isEmpty { row("model", m) }
            // Times count down live while the card is open.
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                VStack(alignment: .leading, spacing: 3) {
                    if item.mood != .busy, let d = item.lastTurnDate {
                        row("last turn", "ended \(Self.ago(tl.date.timeIntervalSince(d)))")
                    }
                    if item.cacheCold {
                        row("cache", "expired: the next message re-reads the context")
                    } else if item.mood != .busy, let e = item.cacheExpiry, e > tl.date {
                        row("cache", "warm, \(Self.span(e.timeIntervalSince(tl.date))) left")
                    }
                }
            }
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

    /// "3 min", "1 h 05 min", "40 s".
    static func span(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return String(format: "%d h %02d min", s / 3600, s % 3600 / 60)
    }

    static func ago(_ t: TimeInterval) -> String { t < 60 ? "just now" : "\(span(t)) ago" }

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
