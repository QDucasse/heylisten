import Foundation
import SwiftUI

/// Version of the ccwatch protocol this app expects (see remote/ccwatch VERSION).
let expectedWatcherVersion = 1

// MARK: - Wire format (ccwatch JSON lines)

struct TmuxRef: Codable, Hashable {
    var session: String
    var window: String
    var pane: String
}

struct WireAttention: Codable, Hashable {
    var state: String      // "permission" | "reply" | "error"
    var message: String
    var ts: Double
}

struct WireSession: Codable, Hashable {
    var pid: Int
    var sessionId: String
    var name: String
    var cwd: String
    var status: String     // "busy" | "idle"
    var kind: String?
    var tmux: TmuxRef?
    var attention: WireAttention?
    var tty: String?
    var contextTokens: Int?    // context size after the last turn (nil: unknown, e.g. just compacted)
    var cacheCold: Bool?       // idle past the prompt cache TTL: the next message re-reads it all
    var compacting: Bool?      // a compaction is running
    var subagents: Int?        // subagents running right now
    var longTurn: Bool?        // busy for over 10 minutes
    var model: String?         // model of the last turn
    var lastTurn: Double?      // when the last turn ended (host clock, unix seconds)
    var cacheTtl: Double?      // prompt cache lifetime (s)
}

struct WireClient: Codable, Hashable {
    var tty: String
    var session: String
    var window: String
    var pane: String
}

struct WireTmuxSession: Codable, Hashable {
    var name: String
    var attached: Int
    var window: String
    var pane: String
}

struct WireTmux: Codable, Hashable {
    var available: Bool
    var clients: [WireClient]
    var sessions: [WireTmuxSession]
}

struct WireMessage: Decodable {
    var type: String
    var version: Int?
    var host: String?
    var time: Double?          // hello: the host's clock
    var sessions: [WireSession]?
    var tmux: WireTmux?
}

// MARK: - App model

enum HostStatus: Equatable {
    case connecting
    case online
    case offline(String)
    case notInstalled
    case outdated(Int)

    var label: String {
        switch self {
        case .connecting: return "connecting…"
        case .online: return "online"
        case .offline(let why): return why.isEmpty ? "offline" : "offline: \(why)"
        case .notInstalled: return "not installed (run ./install.sh)"
        case .outdated(let v): return "outdated v\(v) (run ./install.sh)"
        }
    }

    var isUsable: Bool {
        switch self {
        case .online, .outdated: return true
        default: return false
        }
    }
}

struct HostState: Identifiable {
    let name: String             // "local" or an ssh alias
    var status: HostStatus = .connecting
    var sessions: [WireSession] = []
    var tmux: WireTmux?
    var seededNotifications = false
    /// Local clock minus the host's (from hello; includes the connection latency, which is fine
    /// for minute-level times).
    var clockOffset: Double = 0
    var id: String { name }
    var isLocal: Bool { name == localHostName }
}

let localHostName = "local"

/// What an avatar shows. Two questions are kept apart: is Claude waiting on you, and is the
/// session open anywhere (a tmux client attached)?
enum Mood: Equatable {
    case busy        // working
    case permission  // blocked on a permission prompt (shown even when detached: it stops the work)
    case error       // the turn stopped on an API error (rate limit, overload...): shown like permission
    case reply       // open, idle, turn just finished and not seen yet  -> pulsing ?
    case waiting     // open, idle, already seen                         -> steady ?
    case idle        // not open anywhere (no tmux client attached)      -> sleeping + zzz
    case offline     // host unreachable
}

/// How full a session's context window is, from the token count the Stop hook records.
enum ContextLevel: Equatable {
    case normal
    case high   // worth a /compact or /clear soon: a flame on the head
    case full   // auto-compaction is close: a bigger flame

    /// Every session runs with the 1M-token context window.
    static let window = 1_000_000
    static let highFraction = 0.6
    static let fullFraction = 0.8

    init(tokens: Int?) {
        let f = Double(tokens ?? 0) / Double(Self.window)
        self = f >= Self.fullFraction ? .full : f >= Self.highFraction ? .high : .normal
    }
}

struct SessionItem: Identifiable, Equatable {
    let host: String
    let wire: WireSession
    let mood: Mood
    let hostOnline: Bool
    /// Index into Tint.palette, assigned by the Store so visible projects don't share a colour.
    let tint: Int
    var clockOffset: Double = 0

    /// When the last turn ended and when its prompt cache expires, on the local clock.
    var lastTurnDate: Date? { wire.lastTurn.map { Date(timeIntervalSince1970: $0 + clockOffset) } }
    var cacheExpiry: Date? { lastTurnDate.map { $0.addingTimeInterval(wire.cacheTtl ?? 3600) } }

    var id: String { "\(host)|\(wire.sessionId.isEmpty ? String(wire.pid) : wire.sessionId)" }
    var isLocal: Bool { host == localHostName }
    /// Identity for the user's ordering: survives restarts and new sessions in the same project.
    var orderKey: String { "\(host)|\(wire.cwd)" }
    var project: String {
        let p = (wire.cwd as NSString).lastPathComponent
        return p.isEmpty ? wire.name : p
    }
    var context: ContextLevel { ContextLevel(tokens: wire.contextTokens) }
    var cacheCold: Bool { wire.cacheCold ?? false }
    /// Remote sessions outside tmux cannot be reached.
    var jumpable: Bool { isLocal || wire.tmux != nil }
}

// MARK: - Per-project tint

enum Tint {
    static func color(_ index: Int) -> Color { Color(nsColor: nsColor(index)) }

    static func nsColor(_ index: Int) -> NSColor {
        let rgb = palette[((index % palette.count) + palette.count) % palette.count]
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// Vivid, clearly distinct colours that read on the grey widget. Picking from a fixed palette
    /// (rather than a continuous hue) means two projects are either visibly different or identical,
    /// never two near-identical shades.
    static let palette: [UInt32] = [
        0xFF5A36,  // red-orange
        0xFFB800,  // amber
        0xB8F02E,  // lime
        0x2EDB6B,  // green
        0x00D9C0,  // teal
        0x22B8FF,  // cyan
        0x4F7DFF,  // blue
        0xA35CFF,  // purple
        0xFF4FA3,  // pink
        0xFF8A1F,  // orange
    ]

    /// Starting palette slot for a project: FNV-1a hash of its cwd.
    static func hashIndex(_ cwd: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in cwd.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return Int(h % UInt64(palette.count))
    }

    /// Give every visible project a palette slot, keeping earlier (persisted) choices. A project
    /// whose slot is taken by another visible project moves on in steps of 3 (coprime with 10, so
    /// every slot is tried, and the alternative is a clearly different colour).
    static func assign(visible cwds: [String], previous: [String: Int]) -> [String: Int] {
        var result = previous
        var used: Set<Int> = []
        for cwd in Set(cwds).sorted() {
            var slot = previous[cwd] ?? hashIndex(cwd)
            if used.contains(slot) {
                let start = previous[cwd] == nil ? slot : hashIndex(cwd)
                slot = (0..<palette.count).map { (start + 3 * $0) % palette.count }
                    .first { !used.contains($0) } ?? start
            }
            used.insert(slot)
            result[cwd] = slot
        }
        return result
    }
}
