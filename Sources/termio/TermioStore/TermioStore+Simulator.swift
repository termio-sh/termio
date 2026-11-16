import AppKit
import Foundation

/// `termio sim …` — an agent driving the iOS Simulator the person is watching in
/// the Simulator pane. The action rides in `target`, its parameters in
/// `arguments`. Coordinates are device points from the top-left, the unit the
/// accessibility tree reports frames in, so a frame read by `inspect` can be
/// tapped at its centre without conversion.
extension TermioStore {
    func simulator(_ request: ControlRequest) async -> Data {
        let host = SimulatorHost.shared
        let arguments = request.arguments ?? [:]
        let action = request.target ?? ""
        // A shell outside any Termio session sends an empty id; it is no session.
        let session = request.callerSession.flatMap { $0.isEmpty ? nil : $0 }
        if let reason = host.unavailableReason {
            return controlError(request, "unavailable", reason)
        }
        // Checked once before the first request, so an agent on a Mac that
        // isn't set up is told the step to take rather than a helper's error.
        if !host.setupChecked { await host.checkSetup() }
        if let problem = host.setupProblem {
            let step = problem.command.map { " Run: \($0)" } ?? ""
            return controlError(request, "setup", "\(problem.title): \(problem.message)\(step)")
        }
        do {
            if action == "list" { return await listSimulators(request) }
            let (screen, booted) = try await resolveSimulator(
                arguments["device"], session: session, bootIfNeeded: action == "attach")
            let udid = screen.udid
            if !["attach", "detach"].contains(action) {
                try await host.waitUntilReady(udid)
            }
            switch await host.askConsent(for: screen) {
            case true?:
                break
            case false?:
                return controlError(request, "not_allowed",
                    "The person didn’t allow agents to use \(screen.name). Ask them, or use another device.")
            case nil:
                return controlError(request, "awaiting_consent",
                    "Termio is asking the person to allow agents to use \(screen.name). Run the command again once they have.")
            }
            switch action {
            case "attach":
                await host.show(udid)
                showSimulatorPane()
                let shown = host.screen ?? screen
                // Answered once the device is drawing, not once it has booted:
                // an agent builds while it boots, and the first command that
                // needs the device waits for the rest.
                let booting = booted ? " — still booting; the next command waits for it, so build now" : ""
                return control(
                    request, ok: true,
                    text: "attached \(shown.name) (\(Self.points(shown.pointSize)) points)\(booting)",
                    json: Self.describe(shown).merging(["booting": booted]) { $1 })
            case "detach":
                host.detachPane(udid)
                return control(request, ok: true, text: "detached \(screen.name)", json: [:])
            case "launch":
                guard let appPath = arguments["app"].map({ Self.absolute($0, from: request.callerCwd) }) else {
                    return controlError(request, "missing_app", "launch needs the .app to install, e.g. `termio sim launch build/MyApp.app`.")
                }
                let launched = try await host.launch(appPath: appPath, bundleID: arguments["bundle-id"], on: udid)
                // As Claude's launch does: the person should see the app it starts.
                await host.show(udid)
                showSimulatorPane()
                return control(
                    request, ok: true,
                    text: "launched \(launched.bundleID)\(launched.pid.map { " (pid \($0))" } ?? "") on \(screen.name)",
                    json: ["bundleID": launched.bundleID, "pid": launched.pid as Any])
            case "open-url":
                guard let url = arguments["url"], !url.isEmpty else {
                    return controlError(request, "missing_url", "open-url needs a URL.")
                }
                try await host.openURL(url, on: udid)
                return control(request, ok: true, text: "opened \(url)", json: [:])
            case "screenshot":
                let path = arguments["out"].map({ Self.absolute($0, from: request.callerCwd) })
                    ?? FileManager.default.temporaryDirectory
                        .appendingPathComponent("termio-sim-\(Int(Date().timeIntervalSince1970 * 1000)).png").path
                let result = try await host.callObject("screenshot", ["udid": udid, "path": path])
                let pixels = "\(result["pixelWidth"] ?? "?")x\(result["pixelHeight"] ?? "?")"
                let points = "\(result["pointWidth"] ?? "?")x\(result["pointHeight"] ?? "?")"
                return control(
                    request, ok: true,
                    text: "\(path)\n\(pixels) pixels, \(points) points — tap in points",
                    json: result)
            case "inspect":
                var parameters: [String: Any] = ["udid": udid]
                if let x = try Self.optionalNumber(arguments, "x"),
                   let y = try Self.optionalNumber(arguments, "y") {
                    parameters["x"] = x
                    parameters["y"] = y
                }
                if let marker = arguments["marker"], !marker.isEmpty {
                    parameters["marker"] = marker
                    parameters["match"] = arguments["match"] ?? "label"
                }
                let data = try await host.call("inspect", parameters)
                guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw SimulatorHostError.malformedReply
                }
                return control(request, ok: true, text: Self.outline(document, interface: screen.pointSize), json: document)
            case "tap":
                var parameters: [String: Any] = ["udid": udid]
                if let label = arguments["label"], !label.isEmpty {
                    parameters["label"] = label
                } else {
                    parameters["x"] = try Self.requiredNumber(arguments, "x")
                    parameters["y"] = try Self.requiredNumber(arguments, "y")
                }
                if let duration = try Self.optionalNumber(arguments, "duration") {
                    parameters["duration"] = duration
                }
                let result = try await host.callObject("tap", parameters)
                let x = result["x"] ?? parameters["x"] ?? "?"
                let y = result["y"] ?? parameters["y"] ?? "?"
                return control(request, ok: true, text: "tapped \(x),\(y)", json: result)
            case "swipe":
                var parameters: [String: Any] = ["udid": udid]
                for key in ["x", "y", "x2", "y2"] { parameters[key] = try Self.requiredNumber(arguments, key) }
                if let duration = try Self.optionalNumber(arguments, "duration") {
                    parameters["duration"] = duration
                }
                _ = try await host.call("swipe", parameters)
                return control(request, ok: true, text: "swiped", json: [:])
            case "touch-path", "touch2-path":
                let two = action == "touch2-path"
                guard let raw = arguments["points"], let data = raw.data(using: .utf8),
                      let points = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !points.isEmpty
                else {
                    throw SimulatorArgumentError(message: two
                        ? "touch2-path needs --points as JSON: [{\"x1\":…,\"y1\":…,\"x2\":…,\"y2\":…,\"dt_ms\":16}, …]"
                        : "touch-path needs --points as JSON: [{\"x\":…,\"y\":…,\"dt_ms\":16}, …]")
                }
                let result = try await host.callObject(
                    two ? "touch2Path" : "touchPath", ["udid": udid, two ? "points2" : "points": points])
                return control(request, ok: true, text: "traced \(points.count) samples", json: result)
            case "text":
                let text = request.text ?? ""
                guard !text.isEmpty else {
                    return controlError(request, "empty_text", "text needs something to type.")
                }
                try await host.type(text, on: udid)
                return control(request, ok: true, text: "typed", json: [:])
            case "key":
                guard let name = arguments["name"], !name.isEmpty else {
                    return controlError(request, "missing_name", "key needs a name.")
                }
                var parameters: [String: Any] = ["udid": udid, "name": name]
                if let count = try Self.optionalNumber(arguments, "count") { parameters["count"] = count }
                _ = try await host.call("key", parameters)
                return control(request, ok: true, text: "pressed \(name)", json: [:])
            case "button":
                guard let name = arguments["name"], !name.isEmpty else {
                    return controlError(request, "missing_name", "button needs a name.")
                }
                _ = try await host.call("button", ["udid": udid, "name": name])
                return control(request, ok: true, text: "pressed \(name)", json: [:])
            case "rotate":
                var parameters: [String: Any] = ["udid": udid]
                if let orientation = arguments["orientation"] {
                    parameters["orientation"] = orientation
                } else {
                    parameters["direction"] = arguments["direction"] ?? "right"
                }
                let result = try await host.callObject("rotate", parameters)
                let size = "\(result["pointWidth"] ?? "?")x\(result["pointHeight"] ?? "?")"
                return control(request, ok: true, text: "rotated; the screen is now \(size) points", json: result)
            case "logs":
                let bundleID = try appTarget(arguments, udid: udid)
                let level = arguments["level"] ?? "info"
                guard SimulatorDiagnostics.levels.contains(level) else {
                    throw SimulatorArgumentError(message: "--level is one of \(SimulatorDiagnostics.levels.joined(separator: ", ")).")
                }
                let read = try await host.logs(
                    udid: udid, bundleID: bundleID, since: arguments["since"],
                    minutes: Int(try Self.optionalNumber(arguments, "minutes") ?? 5),
                    tail: min(1000, Int(try Self.optionalNumber(arguments, "tail") ?? 100)),
                    level: level, filter: arguments["filter"])
                var text = read.lines.isEmpty ? "no log lines from \(bundleID)" : read.lines.joined(separator: "\n")
                if read.truncated { text = "(older lines omitted)\n" + text }
                if let cursor = read.cursor { text += "\nnext: --since '\(cursor)'" }
                return control(
                    request, ok: true, text: text,
                    json: ["lines": read.lines, "cursor": read.cursor as Any, "truncated": read.truncated])
            case "crash-report":
                let bundleID = try appTarget(arguments, udid: udid)
                guard let crash = try await host.crashReport(udid: udid, bundleID: bundleID) else {
                    return control(
                        request, ok: true,
                        text: "no crash report for \(bundleID) on \(screen.name). macOS writes one seconds to a minute after a crash; try again if it only just died.",
                        json: ["found": false])
                }
                return control(
                    request, ok: true, text: "\(crash.summary)\nreport: \(crash.path)",
                    json: ["found": true, "summary": crash.summary, "path": crash.path])
            case "keyboard":
                guard let state = arguments["state"], state == "show" || state == "hide" else {
                    return controlError(request, "bad_state", "keyboard takes show or hide.")
                }
                try await host.setOnScreenKeyboard(state == "show", on: udid)
                return control(request, ok: true, text: "on-screen keyboard \(state == "show" ? "shown" : "hidden")", json: [:])
            default:
                return controlError(request, "bad_action", "Unknown sim action '\(action)'.")
            }
        } catch let error as SimulatorArgumentError {
            return controlError(request, "bad_argument", error.message)
        } catch {
            return controlError(request, "simulator", error.localizedDescription)
        }
    }

    private func listSimulators(_ request: ControlRequest) async -> Data {
        let host = SimulatorHost.shared
        let devices = await host.refreshDevices()
        let current = host.screen?.udid
        let mine = request.callerSession.flatMap { $0.isEmpty ? nil : host.binding(for: $0) }
        let lines = devices.map { device in
            let marker = device.udid == current ? "*" : " "
            let owner = device.udid == mine ? "  (this session)" : ""
            return "\(marker) \(device.udid)  \(device.state.padding(toLength: 9, withPad: " ", startingAt: 0))  \(device.name) (\(device.os))\(owner)"
        }
        let rows: [[String: Any]] = devices.map {
            [
                "udid": $0.udid, "name": $0.name, "state": $0.state, "os": $0.os,
                "attached": $0.udid == current, "thisSession": $0.udid == mine,
            ]
        }
        return control(
            request, ok: true,
            text: lines.isEmpty ? "no simulators" : lines.joined(separator: "\n"),
            json: ["devices": rows])
    }

    /// The device a request means: the one it names (UDID or name); else the
    /// one this session already drives; else the one the pane shows, if no
    /// other session drives it; else a booted one no other session drives;
    /// else the first booted one — so two agents testing at once each
    /// get their own device when there are two. The answer becomes the
    /// session's device.
    private func resolveSimulator(
        _ named: String?, session: String?, bootIfNeeded: Bool
    ) async throws -> (screen: SimulatorScreen, booted: Bool) {
        let host = SimulatorHost.shared
        let devices = await host.refreshDevices()
        var chosen: SimulatorDevice?
        if let named, !named.isEmpty {
            chosen = devices.first(where: { $0.udid == named })
                ?? devices.first(where: { $0.name.caseInsensitiveCompare(named) == .orderedSame && $0.isBooted })
                ?? devices.first(where: { $0.name.caseInsensitiveCompare(named) == .orderedSame })
            guard chosen != nil else {
                throw SimulatorArgumentError(message: "No simulator named '\(named)'. Run `termio sim list`.")
            }
        } else {
            let mine = session.flatMap { host.binding(for: $0) }
            let others = host.boundElsewhere(than: session)
            // The device the pane shows is the one the person is watching, so a
            // caller with no device of its own starts there unless another
            // session is driving it.
            let watched = host.screen?.udid
            chosen = devices.first(where: { $0.udid == mine && $0.isBooted })
                ?? devices.first(where: { $0.udid == watched && $0.isBooted && !others.contains($0.udid) })
                ?? devices.first(where: { $0.isBooted && !others.contains($0.udid) })
                ?? devices.first(where: \.isBooted)
            guard chosen != nil else {
                throw SimulatorArgumentError(message:
                    "No simulator is booted. Run `termio sim attach --device <name>` to boot one, or `xcrun simctl boot <device>`.")
            }
        }
        guard let device = chosen else { throw SimulatorHostError.malformedReply }
        if !device.isBooted {
            guard bootIfNeeded else {
                throw SimulatorArgumentError(message:
                    "\(device.name) is not booted. `termio sim attach --device \"\(device.name)\"` boots it.")
            }
            // `attach` shows the boot from its first frame (`SimulatorHost.show`).
            if let session { host.bind(session: session, to: device.udid) }
            await host.show(device.udid)
            if let error = host.lastError { throw SimulatorHostError.failed(error) }
            guard let screen = host.screen else { throw SimulatorHostError.helperExited }
            return (screen, true)
        }
        if let session { host.bind(session: session, to: device.udid) }
        if host.screen?.udid == device.udid, let screen = host.screen { return (screen, false) }
        return (try await host.attach(device.udid), false)
    }

    /// The app a log or crash read is about: the one named, else the one
    /// `launch` last started on the device.
    private func appTarget(_ arguments: [String: String], udid: String) throws -> String {
        if let named = arguments["bundle-id"], !named.isEmpty { return named }
        if let launched = SimulatorHost.shared.lastLaunched[udid] { return launched }
        throw SimulatorArgumentError(message:
            "Which app? Pass --bundle-id, or start it with `termio sim launch` first.")
    }

    /// Opens the inspector on the Simulator pane, as choosing it from the pane
    /// menu does.
    private func showSimulatorPane() {
        inspectorTab = .simulator
        if !inspectorVisible {
            NSApp.sendAction(#selector(AppDelegate.toggleFilesInspector(_:)), to: nil, from: nil)
        }
    }

    // MARK: Formatting

    private static func describe(_ screen: SimulatorScreen) -> [String: Any] {
        [
            "udid": screen.udid, "name": screen.name,
            "pointWidth": screen.pointSize.width, "pointHeight": screen.pointSize.height,
        ]
    }

    private static func points(_ size: CGSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }

    /// A path from the CLI, made absolute against the caller's directory —
    /// `termio sim launch build/App.app` means the build folder where the
    /// agent is, not wherever Termio was started from.
    nonisolated static func absolute(_ path: String, from callerDirectory: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/"), let callerDirectory, callerDirectory.hasPrefix("/") else {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        return URL(fileURLWithPath: callerDirectory, isDirectory: true)
            .appendingPathComponent(expanded).standardizedFileURL.path
    }

    private static func optionalNumber(_ arguments: [String: String], _ key: String) throws -> Double? {
        guard let raw = arguments[key], !raw.isEmpty else { return nil }
        guard let value = Double(raw) else {
            throw SimulatorArgumentError(message: "--\(key) must be a number, not '\(raw)'")
        }
        return value
    }

    private static func requiredNumber(_ arguments: [String: String], _ key: String) throws -> Double {
        guard let value = try optionalNumber(arguments, key) else {
            throw SimulatorArgumentError(message: "missing \(key)")
        }
        return value
    }

    /// The accessibility tree as one line per element that says something —
    /// `Button "Continue" @ 120,640 160x44` — indented by depth. Elements with no
    /// label, value or identifier are folded away and their children lifted, so
    /// the outline is the screen's content rather than its container nesting.
    /// Elements lying wholly off the screen (the App Library one swipe to the
    /// right of the home screen, a page not scrolled to) are dropped and counted:
    /// a frame nobody can tap is a frame an agent will try to tap.
    /// The full document is the `--json` reply.
    nonisolated static func outline(_ document: [String: Any], interface: CGSize? = nil) -> String {
        var lines: [String] = []
        var offScreen = 0
        var stale = 0
        var screenRect: CGRect?
        if let screen = document["screen"] as? [String: Any],
           let width = (screen["width"] as? NSNumber)?.doubleValue,
           let height = (screen["height"] as? NSNumber)?.doubleValue, width > 0, height > 0 {
            screenRect = CGRect(x: 0, y: 0, width: width, height: height)
        }
        func string(_ value: Any?) -> String? {
            guard let value, !(value is NSNull) else { return nil }
            if let text = value as? String { return text.isEmpty ? nil : text }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        // A container larger than the screen holds a layout no longer shown —
        // after a rotation the old orientation's views linger in the tree, the
        // same buttons a hand's width from where they are drawn. The root is
        // exempt: an iPad app's root reports a square.
        func isStale(_ element: [String: Any], level: Int) -> Bool {
            guard level > 0, let interface,
                  let frame = element["frame"] as? [String: Any],
                  let width = (frame["width"] as? NSNumber)?.doubleValue,
                  let height = (frame["height"] as? NSNumber)?.doubleValue
            else { return false }
            return width > interface.width + 1 || height > interface.height + 1
        }
        // `depth` indents the outline; `level` is the element's depth in the
        // tree, which folded containers do not add to `depth`.
        func walk(_ elements: [[String: Any]], depth: Int, level: Int, keepSilent: Bool) {
            for element in elements {
                if isStale(element, level: level) {
                    stale += 1
                    continue
                }
                let label = string(element["label"])
                let value = string(element["value"])
                // The helper sends an empty field's placeholder in place of its value.
                let placeholder = value == nil ? string(element["placeholder"]) : nil
                let identifier = string(element["identifier"])
                let children = element["children"] as? [[String: Any]] ?? []
                guard keepSilent || label != nil || value != nil || placeholder != nil || identifier != nil else {
                    walk(children, depth: depth, level: level + 1, keepSilent: false)
                    continue
                }
                var line = String(repeating: "  ", count: depth)
                line += string(element["type"]) ?? "Element"
                if let label { line += " \"\(label)\"" }
                if let value, value != label { line += " = \"\(value)\"" }
                if let placeholder { line += " placeholder \"\(placeholder)\"" }
                if let identifier { line += " #\(identifier)" }
                if let frame = element["frame"] as? [String: Any],
                   let x = frame["x"] as? NSNumber, let y = frame["y"] as? NSNumber,
                   let width = frame["width"] as? NSNumber, let height = frame["height"] as? NSNumber {
                    let rect = CGRect(x: x.doubleValue, y: y.doubleValue,
                                      width: width.doubleValue, height: height.doubleValue)
                    // An empty frame is laid out nowhere — an icon on a page not shown.
                    if rect.isEmpty || screenRect.map({ !rect.intersects($0) }) == true {
                        offScreen += 1
                        continue
                    }
                    line += " @ \(Int(x.doubleValue.rounded())),\(Int(y.doubleValue.rounded()))"
                    line += " \(Int(width.doubleValue.rounded()))x\(Int(height.doubleValue.rounded()))"
                }
                if element["enabled"] as? Bool == false { line += " (disabled)" }
                lines.append(line)
                walk(children, depth: depth + 1, level: level + 1, keepSilent: false)
            }
        }
        let elements = document["elements"] as? [[String: Any]] ?? []
        walk(elements, depth: 0, level: 0, keepSilent: false)
        // A read that names only silent elements — a point on an icon's image,
        // which has no label of its own — still answers what is there.
        if lines.isEmpty, !elements.isEmpty { walk(elements, depth: 0, level: 0, keepSilent: true) }
        if let modal = document["modal"] as? [String: Any], let kind = string(modal["kind"]) {
            lines.insert("modal: \(kind) \(string(modal["label"]) ?? "")", at: 0)
        }
        if stale > 0 {
            lines.append("(\(stale) containers of a layout no longer shown omitted)")
        }
        if offScreen > 0 {
            lines.append("(\(offScreen) off-screen elements omitted)")
        }
        if document["truncated"] as? Bool == true {
            lines.append("(tree truncated — inspect a point with --x/--y to read deeper)")
        }
        return lines.isEmpty ? "no accessible elements" : lines.joined(separator: "\n")
    }
}

struct SimulatorArgumentError: Error {
    let message: String
}
