import AppKit

/// Dev-only diagnostics behind the palette's "Debug: Snapshot Window": renders the main
/// window into a PNG and dumps its view hierarchy with frames. Self-rendering via
/// `cacheDisplay` needs no Screen Recording permission, so an automated session can
/// inspect a layout glitch it drove the app into. Metal-hosted terminal surfaces may
/// come out empty in the PNG; the text dump is the authoritative geometry record.
enum DebugWindowSnapshot {
    /// Dev-only: lets an automated session trigger a capture without window focus —
    /// `swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("termio.dev.snapshot"), object: nil, userInfo: nil, deliverImmediately: true)'`
    static func installTrigger() {
        // Selector-based registration so `.deliverImmediately` applies — the block API
        // suspends distributed notifications while the app is in the background, which
        // is exactly when an automated session needs this.
        DistributedNotificationCenter.default().addObserver(
            Trigger.shared, selector: #selector(Trigger.fire),
            name: Notification.Name("termio.dev.snapshot"), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    // @unchecked: stateless — it exists only as a selector target, and `fire`
    // hops to the main actor before touching anything.
    private final class Trigger: NSObject, @unchecked Sendable {
        static let shared = Trigger()
        @objc func fire(_ note: Notification) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DebugWindowSnapshot.capture() }
            }
        }
    }

    @MainActor
    static func capture() {
        guard let window = NSApp.windows.first(where: {
            $0.frameAutosaveName == AppDelegate.mainWindowFrameAutosaveName
        }) ?? NSApp.mainWindow else { return }
        // The frame view (contentView's superview) includes the titlebar/toolbar chrome.
        let root = window.contentView?.superview ?? window.contentView
        guard let view = root else { return }

        var lines: [String] = ["window frame=\(window.frame) key=\(window.isKeyWindow)"]
        dump(view, depth: 0, into: &lines)
        try? lines.joined(separator: "\n").write(
            toFile: "/tmp/termio-dev-views.txt", atomically: true, encoding: .utf8)

        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/termio-dev-window.png"))
            }
        }
    }

    private static func dump(_ view: NSView, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        var bits = "\(indent)\(type(of: view)) frame=\(view.frame)"
        if view.isHidden { bits += " HIDDEN" }
        if view.alphaValue < 1 { bits += " alpha=\(view.alphaValue)" }
        if let bg = view.layer?.backgroundColor, let c = NSColor(cgColor: bg), c.alphaComponent > 0 {
            bits += " bg=\(c)"
        }
        lines.append(bits)
        for sub in view.subviews {
            dump(sub, depth: depth + 1, into: &lines)
        }
    }
}
