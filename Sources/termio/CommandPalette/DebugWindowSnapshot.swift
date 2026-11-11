import AppKit

/// Dev-only diagnostics behind the palette's "Debug: Snapshot Window": renders the
/// frontmost window into a PNG and dumps its view hierarchy with frames. Capturing its
/// own window needs no Screen Recording permission, so an automated session can
/// inspect a layout glitch it drove the app into.
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
            let title = note.userInfo?["title"] as? String
            let tab = (note.userInfo?["settings"] as? String).flatMap(SettingsTab.init(rawValue:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // `settings: <tab>` opens that tab first, from inside the
                    // app: driven from outside, the window loses the focus race
                    // to whatever sends the keystroke.
                    guard let tab, let delegate = NSApp.delegate as? AppDelegate else {
                        DebugWindowSnapshot.capture(title: title)
                        return
                    }
                    delegate.openSettings(initialTab: tab)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        MainActor.assumeIsolated { DebugWindowSnapshot.capture(autosaveName: "TermioSettingsWindow") }
                    }
                }
            }
        }
    }

    @MainActor
    static func capture(title: String? = nil, autosaveName: String? = nil) {
        let named = autosaveName.flatMap { name in NSApp.windows.first { $0.frameAutosaveName == name } }
        // A sheet open on the window is what is on screen, so it is the capture.
        guard let window = (named ?? target(title: title)).map({ $0.attachedSheet ?? $0 }) else {
            // Says what there was to pick from, so the next try names one.
            let titles = NSApp.windows.filter(\.isVisible).map { "\($0.title) (\(type(of: $0)))" }
            try? "no visible window titled \(title ?? "")\nwindows: \(titles)".write(
                toFile: "/tmp/termio\(AppChannel.suffix)-views.txt", atomically: true, encoding: .utf8)
            return
        }
        // The frame view (contentView's superview) includes the titlebar/toolbar chrome.
        let root = window.contentView?.superview ?? window.contentView
        guard let view = root else { return }

        // Scoped by channel because every dev-channel app on the machine answers the
        // same distributed notification; a probe build and the dev app would
        // otherwise overwrite each other's capture.
        let stem = "/tmp/termio\(AppChannel.suffix)"
        var lines: [String] = [
            "window frame=\(window.frame) key=\(window.isKeyWindow) visible-on-screen=\(window.occlusionState.contains(.visible))",
        ]
        dump(view, depth: 0, into: &lines)
        try? lines.joined(separator: "\n").write(
            toFile: stem + "-views.txt", atomically: true, encoding: .utf8)
        // A window capture leaves a Metal layer empty, so each stream pane
        // also draws itself offscreen.
        for (index, stream) in streamViews(in: view).enumerated() {
            guard let image = stream.screenImage(),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { continue }
            try? png.write(to: URL(fileURLWithPath: stem + "-stream-\(index).png"))
        }

        guard let rep = composited(window) ?? cached(view),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: stem + "-window.png"))
    }

    /// The window as the window server composited it: materials, glass and SwiftUI
    /// `Form` content included, which `cacheDisplay` leaves blank. A process may
    /// capture its own windows without Screen Recording permission. The function is
    /// marked unavailable in the macOS 15 SDK, so it is looked up at runtime.
    @MainActor
    private static func composited(_ window: NSWindow) -> NSBitmapImageRep? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        let bestResolution: UInt32 = 1 << 3
        guard let image = createImage(
            .null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution
        )?.takeRetainedValue() else { return nil }
        // Under Stage Manager a window off stage composites as its thumbnail,
        // a fraction of its size; the cached render is the one worth reading then.
        guard CGFloat(image.width) >= window.frame.width * window.backingScaleFactor * 0.9 else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    @MainActor
    private static func cached(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Which window a capture means: the frontmost ordinary window.
    ///
    /// It used to be the main window specifically, which made Settings —
    /// a second window, and the one most layout questions are about —
    /// unreachable: a capture driven while it was open returned the terminal
    /// behind it. Panels are skipped because the command palette is one, and it
    /// is *always* frontmost at the moment a palette action runs.
    @MainActor
    /// `title` names the window outright (`userInfo: ["title": "Server"]`): an
    /// app in the background has no key window, and a stray window that never
    /// reached the screen can sit first in the order.
    private static func target(title: String? = nil) -> NSWindow? {
        if let title {
            return NSApp.windows.first { $0.isVisible && $0.title == title }
        }
        return NSApp.orderedWindows.first {
            $0.isVisible && !($0 is NSPanel) && $0.contentView != nil
        }
        ?? NSApp.windows.first { $0.frameAutosaveName == AppDelegate.mainWindowFrameAutosaveName }
        ?? NSApp.mainWindow
    }

    @MainActor
    private static func streamViews(in view: NSView) -> [TermiodStreamView] {
        (view as? TermiodStreamView).map { [$0] } ?? view.subviews.flatMap { streamViews(in: $0) }
    }

    @MainActor
    private static func dump(_ view: NSView, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        var bits = "\(indent)\(type(of: view)) frame=\(view.frame)"
        if view.isHidden { bits += " HIDDEN" }
        if view.alphaValue < 1 { bits += " alpha=\(view.alphaValue)" }
        if let stream = view as? TermiodStreamView { bits += " framesPresented=\(stream.framesPresented)" }
        if let bg = view.layer?.backgroundColor, let c = NSColor(cgColor: bg), c.alphaComponent > 0 {
            bits += " bg=\(c)"
        }
        lines.append(bits)
        for sub in view.subviews {
            dump(sub, depth: depth + 1, into: &lines)
        }
    }
}

/// Dev-only: drives the Simulator pane's pointer from outside, for an automated
/// session that cannot click — Stage Manager keeps a background window as a
/// thumbnail, so posted mouse events never reach it. Real `NSEvent`s go through
/// `NSWindow.sendEvent`, so AppKit's own hit-testing and dispatch run; only the
/// window server's delivery is skipped.
///
/// `swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("termio.dev.simulator.pointer"), object: "0.5,0.5;0.5,0.2", userInfo: nil, deliverImmediately: true)'`
///
/// The object is `fx,fy;…` as fractions of the screen view's bounds from its
/// top-left: the first is the press, any middle ones drags, the last the release.
enum DebugSimulatorPointer {
    static func installTrigger() {
        DistributedNotificationCenter.default().addObserver(
            Trigger.shared, selector: #selector(Trigger.fire),
            name: Notification.Name("termio.dev.simulator.pointer"), object: nil,
            suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            Trigger.shared, selector: #selector(Trigger.type),
            name: Notification.Name("termio.dev.simulator.keys"), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    // @unchecked: stateless, as `DebugWindowSnapshot.Trigger`.
    private final class Trigger: NSObject, @unchecked Sendable {
        static let shared = Trigger()
        @objc func fire(_ note: Notification) {
            let path = (note.object as? String) ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DebugSimulatorPointer.drive(path) }
            }
        }

        /// The object is the text to type, one key event per character, into
        /// whatever has the window's keyboard focus — the pane's screen, once a
        /// pointer press there has made it first responder.
        @objc func type(_ note: Notification) {
            let text = (note.object as? String) ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DebugSimulatorPointer.type(text) }
            }
        }
    }

    @MainActor
    private static func scroll(_ path: String) {
        let wheel = path.hasPrefix("wheel:")
        let numbers = path.split(separator: ":").last?.split(separator: ",").compactMap { Double($0) } ?? []
        guard numbers.count >= 3,
              let (window, view) = NSApp.windows.lazy.compactMap({ window in
                  find(SimulatorScreenView.self, in: window.contentView).map { (window, $0) }
              }).first
        else { return }
        let inWindow = view.convert(CGPoint(x: numbers[0] * view.bounds.width,
                                            y: (1 - numbers[1]) * view.bounds.height), to: nil)
        // An NSEvent made from a CGEvent has no window, and AppKit then reads its
        // screen location as the window location; so the location given is the
        // window point, flipped to the CGEvent's top-left origin.
        let flipped = CGPoint(x: inWindow.x, y: (NSScreen.screens.first?.frame.height ?? 0) - inWindow.y)
        func post(_ delta: Int32, phase: CGScrollPhase?, after index: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16 * index)) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: wheel ? .line : .pixel,
                                       wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)
                else { return }
                cg.location = flipped
                if path.hasPrefix("pan:") { cg.flags = .maskAlternate }
                if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
                guard let event = NSEvent(cgEvent: cg) else { return }
                window.sendEvent(event)
            }
        }
        if wheel {
            post(Int32(numbers[2]), phase: nil, after: 0)
            return
        }
        let steps = Int(numbers.count > 3 ? numbers[3] : 10)
        post(0, phase: .began, after: 0)
        for index in 1 ... max(1, steps) { post(Int32(numbers[2]), phase: .changed, after: index) }
        post(0, phase: .ended, after: steps + 1)
    }

    @MainActor
    private static func type(_ text: String) {
        guard let window = NSApp.windows.first(where: { find(SimulatorScreenView.self, in: $0.contentView) != nil })
        else { return }
        // `shortcut:cmd+shift+h` presses a key with modifiers, the way a real
        // ⇧⌘H arrives. Arrows are named: left, right, up, down.
        if text.hasPrefix("shortcut:") {
            let parts = text.dropFirst("shortcut:".count).split(separator: "+").map(String.init)
            var flags: NSEvent.ModifierFlags = []
            for part in parts.dropLast() {
                switch part {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "ctrl": flags.insert(.control)
                case "opt": flags.insert(.option)
                default: break
                }
            }
            let arrows = ["left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey,
                          "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey]
            let name = parts.last ?? ""
            let key = arrows[name].flatMap { UnicodeScalar($0).map { String(Character($0)) } } ?? name
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)
            else { return }
            // Posted, not sent: through the event queue, where local monitors —
            // the pane's shortcuts among them — see it as they see a real key.
            NSApp.postEvent(event, atStart: false)
            return
        }
        for (index, character) in text.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30 * index)) {
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                    isARepeat: false, keyCode: 0)
                else { return }
                window.sendEvent(event)
            }
        }
    }

    @MainActor
    private static func drive(_ path: String) {
        // `window:x,y` clicks at a point in the window (points from its
        // top-left), for the SwiftUI controls round the screen — the header's
        // Home, Rotate and Screenshot buttons.
        // `scroll:fx,fy,dy,steps` scrolls a trackpad gesture of `steps` events,
        // `dy` points each, at a point in the screen view; `wheel:fx,fy,lines`
        // turns a mouse wheel by `lines` notches there; `pan:` is `scroll:` with ⌥.
        if path.hasPrefix("scroll:") || path.hasPrefix("wheel:") || path.hasPrefix("pan:") {
            scroll(path)
            return
        }
        // `move:fx,fy` hands the screen view a mouse move there, the way its
        // tracking area would, for Select Element's hover.
        if path.hasPrefix("move:") {
            let parts = path.dropFirst("move:".count).split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2,
                  let (window, view) = NSApp.windows.lazy.compactMap({ window in
                      find(SimulatorScreenView.self, in: window.contentView).map { (window, $0) }
                  }).first
            else { return }
            let inWindow = view.convert(
                CGPoint(x: parts[0] * view.bounds.width, y: (1 - parts[1]) * view.bounds.height), to: nil)
            guard let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: inWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
            else { return }
            view.mouseMoved(with: event)
            return
        }
        // `sheet:x,y` clicks in the sheet open on the window, and
        // `sheetdrag:x,y;x,y;…` drags through those points there, 16 ms apart.
        if path.hasPrefix("sheet:") || path.hasPrefix("sheetdrag:") {
            guard let main = NSApp.windows.first(where: { find(SimulatorScreenView.self, in: $0.contentView) != nil }),
                  let sheet = main.attachedSheet
            else { return }
            let points = path.split(separator: ":").last?.split(separator: ";").compactMap { pair -> CGPoint? in
                let numbers = pair.split(separator: ",").compactMap { Double($0) }
                return numbers.count == 2 ? CGPoint(x: numbers[0], y: sheet.frame.height - numbers[1]) : nil
            } ?? []
            guard let first = points.first, let last = points.last else { return }
            let steps: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, first)]
                + points.dropFirst().map { (.leftMouseDragged, $0) } + [(.leftMouseUp, last)]
            for (index, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16 * index)) {
                    guard let event = NSEvent.mouseEvent(
                        with: step.0, location: step.1, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                        context: nil, eventNumber: index, clickCount: 1, pressure: step.0 == .leftMouseUp ? 0 : 1)
                    else { return }
                    sheet.sendEvent(event)
                }
            }
            return
        }
        if path.hasPrefix("window:") {
            let parts = path.dropFirst("window:".count).split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2,
                  let window = NSApp.windows.first(where: { find(SimulatorScreenView.self, in: $0.contentView) != nil })
            else { return }
            let point = CGPoint(x: parts[0], y: window.frame.height - parts[1])
            for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80 * index)) {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: index, clickCount: 1, pressure: index == 0 ? 1 : 0)
                    else { return }
                    window.sendEvent(event)
                }
            }
            return
        }
        let fractions = path.split(separator: ";").compactMap { pair -> CGPoint? in
            let parts = pair.split(separator: ",").compactMap { Double($0) }
            return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
        }
        guard !fractions.isEmpty,
              let (window, view) = NSApp.windows.lazy.compactMap({ window in
                  find(SimulatorScreenView.self, in: window.contentView).map { (window, $0) }
              }).first
        else { return }
        let points = fractions.map { fraction in
            view.convert(CGPoint(x: fraction.x * view.bounds.width,
                                 y: (1 - fraction.y) * view.bounds.height), to: nil)
        }
        // A frame apart, as a real drag arrives: a whole drag in one instant
        // reads as a jump, not a scroll.
        for (index, point) in points.enumerated() {
            let type: NSEvent.EventType = index == 0 ? .leftMouseDown
                : index == points.count - 1 ? .leftMouseUp : .leftMouseDragged
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16 * index)) {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: index, clickCount: 1, pressure: 1)
                else { return }
                window.sendEvent(event)
            }
        }
        // A press and release at one point is a tap: two events, the same point.
        if points.count == 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) {
                guard let event = NSEvent.mouseEvent(
                    with: .leftMouseUp, location: points[0], modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 0)
                else { return }
                window.sendEvent(event)
            }
        }
    }

    @MainActor
    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews { if let match = find(type, in: subview) { return match } }
        return nil
    }
}
