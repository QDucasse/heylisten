import AppKit
import QuartzCore
import SwiftUI

/// Sprite PNGs bundled in Contents/Resources/sprites (rendered by art/render.py at scale 1).
enum Sprites {
    static let avatarPixels: CGFloat = 16   // art/tiles grid size
    static let overlayPixels: CGFloat = 9   // art/overlays grid size
    static let markPixels: CGFloat = 5      // art/marks grid size (unread sparkle, sweat drop)
    static let miniPixels: CGFloat = 7      // art/minis grid size (subagent followers)

    private static var cache: [String: NSImage] = [:]
    private static var cgCache: [String: CGImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let i = cache[name] { return i }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "sprites"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }

    static func cgImage(_ name: String) -> CGImage? {
        image(name)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The sprite multiplied by `color` (what SwiftUI's colorMultiply did), optionally desaturated.
    /// Done once per (sprite, colour) and cached, so animating between tints is a contents swap.
    static func tinted(_ name: String, _ color: NSColor?, grey: Bool) -> CGImage? {
        let c = color?.usingColorSpace(.sRGB)
        let comps: [Double] = c.map { [Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)] } ?? [1, 1, 1]
        let key = "\(name)|\(comps)|\(grey)"
        if let i = cgCache[key] { return i }
        guard let src = cgImage(name),
              let ctx = CGContext(data: nil, width: src.width, height: src.height, bitsPerComponent: 8,
                                  bytesPerRow: src.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
        let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * src.height)
        for i in stride(from: 0, to: ctx.bytesPerRow * src.height, by: 4) {
            // Premultiplied channels: multiplying them by a colour is still a correct multiply.
            var r = Double(px[i]) * comps[0], g = Double(px[i + 1]) * comps[1], b = Double(px[i + 2]) * comps[2]
            if grey { let l = 0.2126 * r + 0.7152 * g + 0.0722 * b; r = l; g = l; b = l }
            px[i] = UInt8(min(255, r.rounded())); px[i + 1] = UInt8(min(255, g.rounded())); px[i + 2] = UInt8(min(255, b.rounded()))
        }
        let img = ctx.makeImage()
        cgCache[key] = img
        return img
    }
}

/// One avatar: the tinted mascot body + eyes, an overlay badge, and stepped whole-pixel motion.
/// The sprites are Core Animation layers and every loop is a discrete keyframe animation, so
/// the render server plays them: the app does no per-frame work, and SwiftUI never re-lays out.
struct AvatarView: View {
    let item: SessionItem
    let scale: CGFloat          // screen points per sprite pixel (4 normal, 2 compact)

    var body: some View {
        let side = Sprites.avatarPixels * scale
        AvatarLayers(config: .init(id: item.id, mood: item.mood, tint: item.tint, scale: scale,
                                   context: item.context, cacheCold: item.cacheCold,
                                   compacting: item.wire.compacting ?? false,
                                   subagents: item.wire.subagents ?? 0, longTurn: item.wire.longTurn ?? false))
            .frame(width: side, height: side)
            .overlay {
                if !item.jumpable {
                    RoundedRectangle(cornerRadius: 4 * scale)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(.secondary)
                }
            }
    }
}

private struct AvatarLayers: NSViewRepresentable {
    let config: AvatarLayerView.Config
    func makeNSView(context: Context) -> AvatarLayerView { AvatarLayerView() }
    func updateNSView(_ v: AvatarLayerView, context: Context) { v.configure(config) }
}

final class AvatarLayerView: NSView {
    struct Config: Equatable {
        var id: String
        var mood: Mood
        var tint: Int
        var scale: CGFloat
        var context: ContextLevel
        var cacheCold: Bool
        var compacting: Bool
        var subagents: Int
        var longTurn: Bool
    }

    /// Followers drawn for running subagents, at most.
    private static let maxFollowers = 3

    /// Badges: 9x9 art at 2x = 18 pt (12x12 art only offered 12 or 24 pt at whole-number scales).
    private let overlayScale: CGFloat = 2
    private var config: Config?
    private let bodyLayer = CALayer()     // moves and fades as a whole
    private let maskLayer = CALayer()     // tinted mascot body
    private let detailLayer = CALayer()   // eyes, outline
    private let badgeLayer = CALayer()    // top right: ! ? x zzz unplugged
    private let markLayer = CALayer()     // top left: unseen sparkle, or sweat drop on a long turn
    private let flameLayer = CALayer()    // on the head (inside bodyLayer): context filling up
    private let snowLayer = CALayer()     // over the whole tile: prompt cache gone cold
    /// Bottom right: one small mascot per running subagent (container, tinted body, eyes).
    private let followers: [(box: CALayer, mask: CALayer, detail: CALayer)] =
        (0..<maxFollowers).map { _ in (CALayer(), CALayer(), CALayer()) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        bodyLayer.addSublayer(maskLayer)
        bodyLayer.addSublayer(detailLayer)
        bodyLayer.addSublayer(flameLayer)
        for l in [bodyLayer, snowLayer, badgeLayer, markLayer] { layer!.addSublayer(l) }
        for f in followers {
            f.box.addSublayer(f.mask)
            f.box.addSublayer(f.detail)
            layer!.addSublayer(f.box)
        }
        for l in [maskLayer, detailLayer, flameLayer, snowLayer, badgeLayer, markLayer] + followers.flatMap({ [$0.mask, $0.detail] }) {
            l.magnificationFilter = .nearest
            l.contentsGravity = .resize
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Purely decorative: clicks, hovers and drags go to the SwiftUI button around it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ c: Config) {
        guard c != config else { return }   // unchanged: keep the running animations
        config = c
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Layer coordinates here are bottom-left origin: "up" is +y.
        let s = c.scale, side = Sprites.avatarPixels * s
        let badge = Sprites.overlayPixels * overlayScale, mark = Sprites.markPixels * 2
        let center = CGPoint(x: side / 2, y: side / 2)
        let all = [bodyLayer, maskLayer, detailLayer, flameLayer, snowLayer, badgeLayer, markLayer] + followers.flatMap { [$0.box, $0.mask, $0.detail] }
        for l in all { l.removeAllAnimations() }
        bodyLayer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        maskLayer.frame = bodyLayer.bounds
        detailLayer.frame = bodyLayer.bounds
        flameLayer.frame = bodyLayer.bounds
        snowLayer.frame = bodyLayer.bounds
        badgeLayer.frame = CGRect(x: side - badge + 2, y: side - badge, width: badge, height: badge)
        markLayer.frame = CGRect(x: -2, y: side - mark, width: mark, height: mark)

        let grey = c.mood == .offline
        let phase = Double(Tint.hashIndex(c.id + "#phase") % 1000) / 1000 * 2   // desync avatars
        // Compacting: pressed like in a trash compactor (squashes down onto its feet, eyes shut,
        // springs back), whatever else it is doing (except when stuck on you or an error).
        let pressed = c.compacting && ![.permission, .error, .offline].contains(c.mood)
        let face = pressed ? "mascot_press0" : Self.face(c.mood)
        let tinted = { (face: String, shimmer: Double) in Sprites.tinted("\(face)_mask", Self.bodyColor(c.tint, shimmer), grey: grey) as Any }
        let detail = { (face: String) in Sprites.tinted("\(face)_detail", nil, grey: grey) as Any }
        maskLayer.contents = tinted(face, 0)
        detailLayer.contents = detail(face)
        bodyLayer.opacity = c.mood == .offline ? 0.5 : 1
        let shimmer: [Double] = [0, 1, 0.5, 0]   // busy: a brightness wave over the body

        if let o = Self.overlay(c.mood) {
            badgeLayer.isHidden = false
            badgeLayer.contents = Sprites.cgImage(o)
            let period = c.mood == .permission ? 0.36 : 0.7
            animate(badgeLayer, "contents", [Sprites.cgImage(o) as Any, Sprites.cgImage(o + "_b") as Any], step: period)
        } else {
            badgeLayer.isHidden = true
        }

        // Context window filling up: a flame on the head, bigger and flickering faster once
        // auto-compaction is close (not while compacting: that is what puts it out).
        let flame = c.mood == .offline || pressed ? nil : c.context == .full ? "flame_l" : c.context == .high ? "flame_s" : nil
        flameLayer.isHidden = flame == nil
        if let f = flame {
            flameLayer.contents = Sprites.cgImage(f)
            animate(flameLayer, "contents", [Sprites.cgImage(f) as Any, Sprites.cgImage(f + "_b") as Any], step: f == "flame_l" ? 0.15 : 0.3)
        }
        // Prompt cache gone cold (the next message re-reads it all): snow falling over the mascot.
        let snowing = c.cacheCold && c.mood != .offline
        snowLayer.isHidden = !snowing
        if snowing {
            let flakes = (0..<8).map { Sprites.cgImage("snow\($0)") as Any }
            snowLayer.contents = flakes[0]
            animate(snowLayer, "contents", flakes, step: 0.3, phase: phase)
        }

        // Top-left mark, in the empty rows above the mascot. Unread: turn finished and not seen
        // yet, a twinkling sparkle. Long turn: working for over 10 minutes, a dripping sweat drop.
        let mark_ = c.mood == .reply ? "unread" : c.mood == .busy && c.longTurn ? "sweat" : nil
        markLayer.isHidden = mark_ == nil
        if let m = mark_ {
            markLayer.contents = Sprites.cgImage(m)
            animate(markLayer, "contents", [Sprites.cgImage(m) as Any, Sprites.cgImage(m + "_b") as Any], step: m == "sweat" ? 0.4 : 0.5)
        }

        // Subagent followers: small mascots in the project colour along the bottom edge, right to
        // left, trotting (legs swap and a 1px hop), each a little out of step with the others.
        let ms = s / 2, mw = Sprites.miniPixels * ms
        let shown = c.mood == .offline ? 0 : min(c.subagents, Self.maxFollowers)
        let mini = ["mini", "mini_b"]
        for (i, f) in followers.enumerated() {
            f.box.isHidden = i >= shown
            guard i < shown else { continue }
            f.box.frame = CGRect(x: side - mw * CGFloat(i + 1) - ms * CGFloat(i), y: -ms, width: mw, height: mw)
            f.mask.frame = f.box.bounds
            f.detail.frame = f.box.bounds
            let fmask = mini.map { Sprites.tinted("\($0)_mask", Self.bodyColor(c.tint, 0), grey: false) as Any }
            let fdetail = mini.map { Sprites.tinted("\($0)_detail", nil, grey: false) as Any }
            f.mask.contents = fmask[0]
            f.detail.contents = fdetail[0]
            let p = phase + Double(i) * 0.13
            animate(f.mask, "contents", fmask, step: 0.2, phase: p)
            animate(f.detail, "contents", fdetail, step: 0.2, phase: p)
            let base = f.box.position
            animate(f.box, "position", [base, CGPoint(x: base.x, y: base.y + ms)].map { NSValue(point: $0) }, step: 0.2, phase: p)
        }

        let at = { (dx: CGFloat, dy: CGFloat) in NSValue(point: CGPoint(x: center.x + dx * s, y: center.y + dy * s)) }
        if pressed {
            // Press: squash down over a few frames, hold, spring back, rest.
            let frames = [0, 1, 2, 2, 2, 1, 0, 0].map { "mascot_press\($0)" }
            animate(maskLayer, "contents", frames.map { tinted($0, 0) }, step: 0.12, phase: phase)
            animate(detailLayer, "contents", frames.map(detail), step: 0.12, phase: phase)
            return
        }
        switch c.mood {
        case .busy:
            animate(bodyLayer, "position", [0, 1, 0, 0].map { at(0, $0) }, step: 0.25, phase: phase)
            animate(maskLayer, "contents", shimmer.map { tinted(face, $0) }, step: 0.25, phase: phase)
        case .idle:
            // Slow breathing, stepped at 4 Hz like the rest.
            let values = (0..<16).map { 0.62 + 0.13 * sin(Double($0) * 0.25 * 2 * .pi / 4) }
            bodyLayer.opacity = 0.62
            animate(bodyLayer, "opacity", values, step: 0.25, phase: phase)
        case .permission:
            animate(bodyLayer, "position", zip([0, 1, 0, -1, 0, 0], [0, 2, 1, 0, 2, 0]).map { at($0, $1) }, step: 0.12)
        case .reply, .waiting, .offline, .error:
            break
        }
    }

    /// A looping, stepped animation locked to the wall clock, so restarting it (on any config
    /// change) is seamless and each avatar keeps its phase.
    private func animate(_ layer: CALayer, _ key: String, _ values: [Any], step: Double, phase: Double = 0) {
        let a = CAKeyframeAnimation(keyPath: key)
        a.values = values
        // Discrete mode needs one more key time than values (closing 1.0): with exactly one per
        // value, Core Animation holds the first frame forever.
        a.keyTimes = (0...values.count).map { NSNumber(value: Double($0) / Double(values.count)) }
        a.calculationMode = .discrete
        a.duration = step * Double(values.count)
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        a.timeOffset = (Date().timeIntervalSinceReferenceDate + phase).truncatingRemainder(dividingBy: a.duration)
        layer.add(a, forKey: key)
    }

    private static func face(_ mood: Mood) -> String {
        switch mood {
        case .busy, .reply, .waiting: return "mascot_awake"
        case .permission: return "mascot_alarmed"
        case .error: return "mascot_ko"
        case .idle, .offline: return "mascot_sleeping"
        }
    }

    private static func overlay(_ mood: Mood) -> String? {
        switch mood {
        case .permission: return "excl"
        case .error: return "error"
        case .reply, .waiting: return "question"   // animated either way; unseen also gets the sparkle
        case .idle: return "zzz"
        case .offline: return "unplugged"
        case .busy: return nil
        }
    }

    private static func bodyColor(_ tint: Int, _ shimmer: Double) -> NSColor {
        let base = Tint.nsColor(tint)
        guard shimmer != 0 else { return base }
        let c = base.usingColorSpace(.deviceRGB) ?? base
        let b = min(1, max(0, c.brightnessComponent + 0.12 * shimmer))
        return NSColor(hue: c.hueComponent, saturation: c.saturationComponent, brightness: b, alpha: 1)
    }
}
