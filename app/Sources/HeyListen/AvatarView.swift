import AppKit
import SwiftUI

/// Sprite PNGs bundled in Contents/Resources/sprites (rendered by art/render.py at scale 1).
enum Sprites {
    static let avatarPixels: CGFloat = 16   // art/tiles grid size
    static let overlayPixels: CGFloat = 9   // art/overlays grid size
    static let markPixels: CGFloat = 5      // art/marks grid size (unread sparkle)

    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let i = cache[name] { return i }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "sprites"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }
}

/// One avatar: the tinted mascot body + eyes, an overlay badge, and procedural whole-pixel motion.
struct AvatarView: View {
    let item: SessionItem
    let scale: CGFloat          // screen points per sprite pixel (4 normal, 2 compact)
    /// Badges: 9x9 art at 2x = 18 pt (12x12 art only offered 12 or 24 pt at whole-number scales).
    private let overlayScale: CGFloat = 2

    private var face: String {
        switch item.mood {
        case .busy, .reply, .waiting: return "mascot_awake"
        case .permission: return "mascot_alarmed"
        case .idle, .offline: return "mascot_sleeping"
        }
    }

    private var overlay: String? {
        switch item.mood {
        case .permission: return "excl"
        case .reply, .waiting: return "question"   // animated either way; unseen also gets the sparkle
        case .idle: return "zzz"
        case .offline: return "unplugged"
        case .busy: return nil
        }
    }

    var body: some View {
        let side = Sprites.avatarPixels * scale
        TimelineView(.periodic(from: .now, by: item.mood == .permission ? 0.12 : 0.25)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let m = motion(t)
            ZStack(alignment: .topTrailing) {
                ZStack {
                    sprite("\(face)_mask")
                        .colorMultiply(bodyColor(shimmer: m.shimmer))
                    sprite("\(face)_detail")
                }
                .frame(width: side, height: side)
                .offset(x: m.dx * scale, y: m.dy * scale)
                .opacity(m.opacity)
                .saturation(item.mood == .offline ? 0 : 1)

                if let overlay {
                    // Two-frame badge animation: <id> / <id>_b.
                    let period = item.mood == .permission ? 0.36 : 0.7
                    let alt = Int((t / period).rounded(.down)) % 2 == 1
                    sprite(alt ? overlay + "_b" : overlay)
                        .frame(width: Sprites.overlayPixels * overlayScale, height: Sprites.overlayPixels * overlayScale)
                        .offset(x: 2, y: 0)
                }
            }
            .frame(width: side, height: side)
            // Unread mark, top left: turn finished and not seen yet. A small twinkling sparkle
            // (5x5 art at 2x = 10 pt) that sits in the empty rows above the mascot.
            .overlay(alignment: .topLeading) {
                if item.mood == .reply {
                    let big = Int((t / 0.5).rounded(.down)) % 2 == 0
                    sprite(big ? "unread" : "unread_b")
                        .frame(width: Sprites.markPixels * 2, height: Sprites.markPixels * 2)
                        .offset(x: -2, y: 0)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if !item.jumpable {
                    RoundedRectangle(cornerRadius: 4 * scale)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tintColor: Color { Tint.color(item.tint) }

    private func bodyColor(shimmer: Double) -> Color {
        let base = Tint.nsColor(item.tint)
        guard shimmer != 0 else { return Color(nsColor: base) }
        let c = base.usingColorSpace(.deviceRGB) ?? base
        let b = min(1, max(0, c.brightnessComponent + 0.12 * shimmer))
        return Color(nsColor: NSColor(hue: c.hueComponent, saturation: c.saturationComponent, brightness: b, alpha: 1))
    }

    @ViewBuilder
    private func sprite(_ name: String) -> some View {
        if let img = Sprites.image(name) {
            Image(nsImage: img).interpolation(.none).resizable()
        } else {
            Color.clear
        }
    }

    private struct Motion { var dx = 0.0, dy = 0.0, opacity = 1.0, shimmer = 0.0 }

    /// Whole-pixel offsets only: no rotation, no fractional scaling.
    private func motion(_ t: TimeInterval) -> Motion {
        var m = Motion()
        let phase = Double(abs(item.id.hashValue % 1000)) / 1000.0 * 2   // desync avatars
        switch item.mood {
        case .busy:
            let step = Int((t / 0.25 + phase * 4).rounded(.down)) % 4
            m.dy = [0, -1, 0, 0][step]
            m.shimmer = [0, 1, 0.5, 0][step]
        case .idle:
            m.opacity = 0.62 + 0.13 * sin((t + phase) * 2 * .pi / 4)
        case .permission:
            let step = Int((t / 0.12).rounded(.down)) % 6
            m.dy = [0, -2, -1, 0, -2, 0][step]
            m.dx = [0, 1, 0, -1, 0, 0][step]
        case .reply, .waiting:
            break   // ? animates in both; unseen adds the unread sparkle
        case .offline:
            m.opacity = 0.5
        }
        return m
    }
}
