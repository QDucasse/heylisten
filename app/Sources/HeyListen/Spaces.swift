import AppKit
import ApplicationServices

// MARK: - Accessibility helpers

enum AX {
    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        attr(el, kAXChildrenAttribute) ?? []
    }

    static func point(_ el: AXUIElement, _ name: String = kAXPositionAttribute) -> CGPoint? {
        guard let v: AXValue = attr(el, name) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement) -> CGSize? {
        guard let v: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(el), let s = size(el) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func setFrame(_ el: AXUIElement, _ r: CGRect) {
        var p = r.origin, s = r.size
        if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv) }
        if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv) }
        // Some apps clamp the first resize based on the old position; apply twice.
        if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv) }
    }

    /// Depth-first walk with a depth cap (Mission Control's tree is small but deep).
    static func walk(_ el: AXUIElement, depth: Int = 0, maxDepth: Int = 10, _ visit: (AXUIElement, Int) -> Void) {
        visit(el, depth)
        guard depth < maxDepth else { return }
        for c in children(el) { walk(c, depth: depth + 1, maxDepth: maxDepth, visit) }
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}

// MARK: - Window tiling

enum WindowTiler {
    /// Find a window of the app (title containing `titleContains`, focused window preferred) and set its frame.
    @discardableResult
    static func setFrame(ofFocusedWindowOf bundleID: String, titleContains: String, to frame: CGRect) -> Bool {
        guard AX.trusted,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var candidates: [AXUIElement] = []
        if let f: AXUIElement = AX.attr(axApp, kAXFocusedWindowAttribute) { candidates.append(f) }
        candidates += (AX.attr(axApp, kAXWindowsAttribute) as [AXUIElement]?) ?? []
        for w in candidates {
            let title: String = AX.attr(w, kAXTitleAttribute) ?? ""
            if titleContains.isEmpty || title.contains(titleContains) {
                AX.setFrame(w, frame)
                return true
            }
        }
        return false
    }
}

// MARK: - Spaces (Mission Control UI scripting)

/// There is no public API to create a desktop. We open Mission Control, press "add desktop" on the
/// main display, then click the new desktop's thumbnail. Requires Accessibility permission.
enum Spaces {
    /// Left/right halves of the main display's visible frame, in AX coordinates (top-left origin).
    static func halves() -> (CGRect, CGRect) {
        guard let main = NSScreen.screens.first else { return (.zero, .zero) }
        let vf = main.visibleFrame
        let top = main.frame.maxY - vf.maxY
        let full = CGRect(x: vf.minX, y: top, width: vf.width, height: vf.height)
        let half = floor(full.width / 2)
        return (CGRect(x: full.minX, y: full.minY, width: half, height: full.height),
                CGRect(x: full.minX + half, y: full.minY, width: full.width - half, height: full.height))
    }

    /// Main display rect in AX/global coordinates.
    private static var mainRect: CGRect {
        guard let main = NSScreen.screens.first else { return .zero }
        return CGRect(origin: .zero, size: main.frame.size)
    }

    private static var dock: AXUIElement? {
        guard let d = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        return AXUIElementCreateApplication(d.processIdentifier)
    }

    private static func toggleMissionControl() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Mission Control"]
        try? p.run()
    }

    /// The main display's part of Mission Control (from a real dump, macOS 26):
    ///   AXGroup id=mc > AXGroup id=mc.display (one per screen, frame = that screen)
    ///     > AXGroup id=mc.spaces > AXList id=mc.spaces.list > AXButton title="Desktop N"
    ///                                                         (desc "exit to Desktop N")
    ///     > AXButton id=mc.spaces.add (desc "add desktop")
    /// Desktop numbers are global across screens, and a collapsed spaces bar puts its buttons at
    /// negative y, so we select by display group, never by button position.
    private struct MainDisplay {
        var add: AXUIElement?
        var desktops: [AXUIElement] = []   // in list order (left to right)
    }

    private static func ident(_ el: AXUIElement) -> String { AX.attr(el, kAXIdentifierAttribute) ?? "" }

    private static func scanMain() -> MainDisplay? {
        guard let dock else { return nil }
        guard let mc = AX.children(dock).first(where: { ident($0) == "mc" }) else { return nil }
        let displays = AX.children(mc).filter { ident($0) == "mc.display" }
        guard !displays.isEmpty else { return nil }
        // Pick the display group whose frame overlaps the main screen the most.
        let main = mainRect
        func overlap(_ el: AXUIElement) -> CGFloat {
            guard let f = AX.frame(el) else { return 0 }
            let i = f.intersection(main)
            return i.isNull ? 0 : i.width * i.height
        }
        guard let display = displays.max(by: { overlap($0) < overlap($1) }), overlap(display) > 0 else { return nil }
        var r = MainDisplay()
        AX.walk(display, maxDepth: 4) { el, _ in
            switch ident(el) {
            case "mc.spaces.add":
                r.add = el
            case "mc.spaces.list":
                r.desktops = AX.children(el).filter {
                    let title: String = AX.attr($0, kAXTitleAttribute) ?? ""
                    let desc: String = AX.attr($0, kAXDescriptionAttribute) ?? ""
                    return title.hasPrefix("Desktop") || desc.contains("Desktop")
                }
            default:
                break
            }
        }
        return r
    }

    private static func label(_ el: AXUIElement) -> String { AX.attr(el, kAXTitleAttribute) ?? "?" }

    @MainActor
    static func createDesktopAndSwitch() async -> Bool {
        guard AX.trusted else {
            hlog("desktop: no Accessibility permission, skipping")
            AX.promptForTrust()
            return false
        }
        toggleMissionControl()

        var before: MainDisplay?
        for _ in 0..<15 {   // up to ~1.5 s for Mission Control to appear
            try? await Task.sleep(nanoseconds: 100_000_000)
            before = scanMain()
            if before?.add != nil { break }
        }
        guard let before, let add = before.add else {
            hlog("desktop: main display add button not found")
            toggleMissionControl()
            return false
        }
        let known = Set(before.desktops.map(label))
        hlog("desktop: main display before: \(before.desktops.map(label).joined(separator: ","))")
        AXUIElementPerformAction(add, kAXPressAction as CFString)

        // The new desktop is the main display's thumbnail whose title we haven't seen (numbers
        // of other screens' desktops shift up, so compare against the count too).
        var target: AXUIElement?
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let after = scanMain(), after.desktops.count > before.desktops.count else { continue }
            target = after.desktops.last { !known.contains(label($0)) } ?? after.desktops.last
            break
        }
        guard let target else {
            hlog("desktop: new thumbnail not found on main display")
            toggleMissionControl()
            return false
        }
        // A collapsed spaces bar keeps thumbnails off-screen (negative y) and AXPress on them is a
        // no-op. Hover the top edge of the main display to expand the bar, then really click.
        let saved = CGEvent(source: nil)?.location ?? .zero
        let top = CGPoint(x: mainRect.midX, y: mainRect.minY + 2)
        CGWarpMouseCursorPosition(top)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: top, mouseButton: .left)?.post(tap: .cghidEventTap)
        var clicked = false
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let el = scanMain()?.desktops.last { label($0) == label(target) } ?? target
            if let fr = AX.frame(el), fr.minY >= 0, mainRect.contains(CGPoint(x: fr.midX, y: fr.midY)) {
                hlog("desktop: clicking \(label(el)) at \(Int(fr.midX)),\(Int(fr.midY))")
                click(at: CGPoint(x: fr.midX, y: fr.midY))
                clicked = true
                break
            }
        }
        if !clicked {
            let r = AXUIElementPerformAction(target, kAXPressAction as CFString)
            hlog("desktop: bar did not expand; AXPress \(label(target)) -> \(r.rawValue)")
        }
        CGWarpMouseCursorPosition(saved)
        try? await Task.sleep(nanoseconds: 900_000_000)   // let the Space transition finish
        return true
    }

    private static func click(at p: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Debug aid: open Mission Control, dump the Dock's AX tree to a file, close it.
    @MainActor
    static func dumpMissionControlTree() async -> String {
        guard AX.trusted else { AX.promptForTrust(); return "Accessibility permission missing" }
        toggleMissionControl()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var lines: [String] = []
        if let dock {
            AX.walk(dock, maxDepth: 12) { el, depth in
                let role: String = AX.attr(el, kAXRoleAttribute) ?? "?"
                let desc: String = AX.attr(el, kAXDescriptionAttribute) ?? ""
                let title: String = AX.attr(el, kAXTitleAttribute) ?? ""
                let ident: String = AX.attr(el, kAXIdentifierAttribute) ?? ""
                let fr = AX.frame(el).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? ""
                lines.append(String(repeating: "  ", count: depth) + "\(role) desc=\(desc) title=\(title) id=\(ident) \(fr)")
            }
        }
        toggleMissionControl()
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches/heylisten")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("mission-control-tree.txt")
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}
