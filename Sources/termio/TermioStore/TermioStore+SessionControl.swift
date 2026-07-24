import AppKit
import Foundation
import GhosttyKit
import GhosttyTerminal

/// Handles `termio sessions …` requests from `SessionControlListener`. Every
/// operation is scoped to the caller's own project (resolved from the caller's
/// `TERMIO_SESSION` or, failing that, its working directory) so an agent can only
/// see and drive its siblings, never sessions in unrelated projects — unpeel's
/// "project-scoped by default" rule.
///
/// Sessions are addressed by a handle, `<agent>@<8-char-id>` (`claude@ab12cd34`).
/// Only the id part resolves; the agent name is a checksum validated against the
/// session it finds, so a caller that mis-splices a name onto the wrong id gets an
/// error instead of a silent misdelivery. `send` with *no* handle starts a fresh
/// agent session — targeting an existing sibling is always an explicit act.
extension TermioStore {
    func handleSessionControl(_ request: ControlRequest) async -> Data {
        guard settings.sessionControlEnabled else {
            return controlError(request, "disabled",
                "Session control is off. Enable it in termio ▸ Settings ▸ Agents.")
        }
        guard let project = callerProject(session: request.callerSession, cwd: request.callerCwd) else {
            return controlError(request, "no_scope",
                "Couldn't tell which project you're in. Run this from inside a termio session.")
        }

        switch request.op {
        case "list": return listSessions(in: project, request: request)
        case "send", "answer": return await sendText(request, in: project)
        case "close": return closeTab(request, in: project)
        case "focus": return focusSession(request, in: project)
        case "read":
            return controlError(request, "read_unavailable",
                "Reading a session's output isn't available in this build yet — it needs a "
                + "terminal-core buffer API. list / send / answer / close / focus work today.")
        default:
            return controlError(request, "bad_op", "Unknown op '\(request.op)'.")
        }
    }

    /// Validates a `watch` subscription and returns the caller's project id to scope
    /// the stream to, or an error payload to write back before hanging up. The same
    /// gating as any control op (session control enabled, caller resolves to a
    /// project); the streaming itself is `SessionWatchHub`'s job.
    func resolveWatchScope(_ request: ControlRequest) -> (UUID?, Data?) {
        guard settings.sessionControlEnabled else {
            return (nil, controlError(request, "disabled",
                "Session control is off. Enable it in termio ▸ Settings ▸ Agents."))
        }
        guard let project = callerProject(session: request.callerSession, cwd: request.callerCwd) else {
            return (nil, controlError(request, "no_scope",
                "Couldn't tell which project you're in. Run this from inside a termio session."))
        }
        return (project.id, nil)
    }

    /// The address a caller drives a session by. The id half is the stable key
    /// (minted at creation, never renumbered — unlike the sidebar's live labels);
    /// the agent half makes the handle self-describing in logs and lets the
    /// resolver catch a name spliced onto the wrong id.
    func sessionHandle(for session: Session) -> String {
        "\(effectiveAgent(for: session).wireName.lowercased())@\(Self.shortID(session.id))"
    }

    private func listSessions(in project: Project, request: ControlRequest) -> Data {
        let entries = project.sessions.map { session -> [String: Any] in
            var entry: [String: Any] = [
                "handle": sessionHandle(for: session),
                "id": Self.shortID(session.id),
                "title": displayTitle(for: session),
                // The *effective* agent, so a plain terminal running a hand-started
                // `claude` reports as Claude to a sibling — the same upgrade the
                // sidebar row shows (see `effectiveAgent`).
                "agent": effectiveAgent(for: session).displayName,
                "status": Self.statusToken(status(for: session.id)),
                "description": statusDescription(for: session.id),
            ]
            // The transcript address, so a caller who wasn't the one to `send`
            // (or who spawned this session before its first hook report) can
            // still find the reply log.
            if let transcript = transcriptPaths[session.id] {
                entry["transcript"] = transcript
            }
            return entry
        }
        let lines = project.sessions.map { session -> String in
            let token = Self.statusToken(status(for: session.id))
            let description = statusDescription(for: session.id)
            let suffix = description.isEmpty ? "" : "  — \(description)"
            return "\(sessionHandle(for: session))  [\(token)]  \(displayTitle(for: session))\(suffix)"
        }
        let header = "\(project.name) — \(project.sessions.count) session(s)"
        let text = ([header] + lines).joined(separator: "\n")
        return control(request, ok: true, text: text, json: ["project": project.name, "sessions": entries])
    }

    private func sendText(_ request: ControlRequest, in project: Project) async -> Data {
        guard let payload = request.text, !payload.isEmpty else {
            return controlError(request, "no_text", "\(request.op) needs text to send.")
        }
        let token = request.target?.trimmingCharacters(in: .whitespaces) ?? ""
        if token.isEmpty {
            // A bare `send` addresses nobody: it starts a fresh agent session for
            // the prompt. `answer` has no such reading — a menu choice without its
            // session is a mistake, never a spawn.
            guard request.op == "send" else {
                return controlError(request, "no_target",
                    "answer needs a session handle — run `termio sessions list`.")
            }
            return await spawnAndSend(request, in: project, payload: payload)
        }
        switch resolveTarget(token, in: project) {
        case .found(let session):
            let state = surface(for: session, in: project)
            return await deliver(payload, to: session, state: state, request: request, created: false)
        case .notFound:
            return controlError(request, "not_found", targetNotFoundMessage(request.target))
        case .ambiguous:
            return controlError(request, "ambiguous",
                "'\(request.target ?? "")' matches more than one session; use a longer id.")
        case .mismatch(let expected):
            return controlError(request, "wrong_agent",
                "That id belongs to \(expected) — use that handle (copied verbatim from `list`).")
        }
    }

    /// The no-handle `send` path: start a fresh agent session and hand it the
    /// prompt. The agent defaults to the caller's own kind (a Claude asking for
    /// help gets a Claude), then to the user's preferred chat agent; `--agent`
    /// overrides both.
    private func spawnAndSend(_ request: ControlRequest, in project: Project, payload: String) async -> Data {
        let preset: AgentDefinition
        if let name = request.agent, !name.isEmpty {
            guard let resolved = AgentPreset.resolve(name), !resolved.isShell else {
                let names = AgentPreset.codingAgents.map(\.rawValue).joined(separator: ", ")
                return controlError(request, "bad_agent",
                    "Unknown agent '\(name)'. Try one of: \(names).")
            }
            preset = resolved
        } else if let callerID = request.callerSession, let uuid = UUID(uuidString: callerID),
                  let caller = session(uuid), !effectiveAgent(for: caller).isShell {
            preset = effectiveAgent(for: caller)
        } else if let fallback = defaultChatAgent() {
            preset = fallback
        } else {
            return controlError(request, "no_agent",
                "No coding agent is enabled — pass --agent <name>.")
        }

        // Drop the new agent in beside the pane you were watching (a split), not
        // as a full-screen swap that hides the caller — the whole reason to spawn
        // a sibling from the CLI is to see them side by side.
        addSplitSession(to: project.id, agent: preset)
        guard let id = selectedSessionID, let fresh = session(id) else {
            return controlError(request, "start_failed", "Could not start the session.")
        }
        let state = surface(for: fresh, in: project)
        await waitForBootSettle(of: state)
        return await deliver(payload, to: fresh, state: state, request: request, created: true)
    }

    /// Types `payload` into a session's live surface and submits it. Shared by
    /// the existing-sibling and fresh-spawn paths.
    private func deliver(
        _ payload: String, to session: Session, state: TerminalViewState,
        request: ControlRequest, created: Bool
    ) async -> Data {
        // The libghostty surface attaches lazily on the pane's first render, so a
        // session never shown in the UI has no surface yet. Selecting it adds it to
        // the mounted set; give the render one cycle. (A session shown even once
        // stays mounted, so this only foregrounds on the very first drive.)
        if state.surface == nil {
            selectedSessionID = session.id
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard let surfaceHandle = Self.rawSurface(from: state) else {
            return controlError(request, "not_live",
                "\(displayTitle(for: session)) has no live terminal yet — open it once in termio.")
        }

        // Type the prompt through the text path (fine for the body), then submit
        // with a real Return *key event*. A trailing "\r" in the text is delivered
        // as a bracketed paste, which an agent TUI (Claude Code) reads as a newline
        // — never a submit. `ghostty_surface_key` drives the surface directly, with
        // no focus or first-responder needed; this is exactly how Ghostty's own
        // AppleScript `send key` submits Enter.
        _ = state.send(payload)
        try? await Task.sleep(for: .milliseconds(40))
        Self.pressReturn(on: surfaceHandle)
        return sentReply(request, session, created: created)
    }

    /// Waits for a freshly launched agent TUI to finish booting before keystrokes
    /// are typed into it — text sent into a half-drawn banner is simply eaten.
    /// There is no boot hook to wait on (Claude's `SessionStart` hook only fires
    /// on `clear`), so readiness is read off the screen itself: two consecutive
    /// identical non-empty viewport frames mean the boot paint has settled. Capped
    /// because some TUIs animate their banner forever; the cap then just sends,
    /// which is no worse than not having waited.
    private func waitForBootSettle(of state: TerminalViewState, timeout: TimeInterval = 10) async {
        guard case .inMemory(let terminal) = state.configuration.backend else {
            try? await Task.sleep(for: .milliseconds(1500))
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        // Give the process a beat to start painting at all before sampling frames,
        // or the pre-banner blank screen counts as two identical frames.
        try? await Task.sleep(for: .milliseconds(700))
        var previous: String?
        while Date() < deadline {
            let frame = terminal.readViewportText()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let frame, !frame.isEmpty {
                if frame == previous { return }
                previous = frame
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    /// The raw `ghostty_surface_t` behind a session's surface. `TerminalSurface`
    /// exposes only `sendText` publicly and keeps the C handle in a private stored
    /// property, so reach it by reflection — the only way to call `ghostty_surface_key`
    /// (the key-event C entry point, whose Swift wrapper the package marks `internal`).
    private static func rawSurface(from state: TerminalViewState) -> ghostty_surface_t? {
        guard let terminalSurface = state.surface else { return nil }
        for child in Mirror(reflecting: terminalSurface).children where child.label == "surface" {
            if let handle = child.value as? ghostty_surface_t { return handle }
        }
        return nil
    }

    /// Sends a Return key press (and release) to the surface — the submit a user makes
    /// by pressing Enter. `keycode` is the native macOS virtual key for Return
    /// (`kVK_Return`, 0x24) and `text` is left nil so Ghostty's own key encoder emits
    /// the correct bytes for whatever keyboard mode the program negotiated.
    private static func pressReturn(on surface: ghostty_surface_t) {
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.mods = GHOSTTY_MODS_NONE
        event.consumed_mods = GHOSTTY_MODS_NONE
        event.keycode = 0x24
        event.text = nil
        event.unshifted_codepoint = 0
        event.composing = false
        _ = ghostty_surface_key(surface, event)
        event.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, event)
    }

    /// The success reply for a send/answer. Beyond confirming delivery, it hands back
    /// the session's transcript address and a cursor (its line count at send time), so
    /// the caller can read the agent's response straight from its own structured log —
    /// the caller's file tools resume from `cursor`. The transcript is known only once
    /// a hook has reported it, so a just-spawned session's reply points the caller at
    /// `list --json` instead (its whole transcript is this conversation anyway).
    private func sentReply(_ request: ControlRequest, _ session: Session, created: Bool) -> Data {
        let handle = sessionHandle(for: session)
        var json: [String: Any] = [
            "target": handle,
            "title": displayTitle(for: session),
        ]
        var text = created
            ? "started \(handle) and sent the prompt — use this handle for follow-ups"
            : "sent to \(handle)"
        if created { json["created"] = true }
        if let transcript = transcriptPaths[session.id] {
            let cursor = Self.lineCount(of: transcript)
            json["transcript"] = transcript
            json["cursor"] = cursor
            text += "\n  transcript: \(transcript)\n  cursor: \(cursor)  (read the response from here on)"
        } else if created {
            text += "\n  (transcript path appears in `termio sessions list --json` once the agent reports it)"
        }
        return control(request, ok: true, text: text, json: json)
    }

    /// Lines currently in a file, counted cheaply by newline bytes — the cursor a
    /// caller resumes a transcript read from.
    private static func lineCount(of path: String) -> Int {
        guard let data = FileManager.default.contents(atPath: path) else { return 0 }
        return data.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
    }

    private func closeTab(_ request: ControlRequest, in project: Project) -> Data {
        switch resolveTarget(request.target, in: project) {
        case .found(let session):
            let handle = sessionHandle(for: session)
            let title = displayTitle(for: session)
            closeSession(session.id)
            return control(request, ok: true, text: "closed \(handle) (\(title))",
                json: ["closed": handle, "title": title])
        case .notFound:
            return controlError(request, "not_found", targetNotFoundMessage(request.target))
        case .ambiguous:
            return controlError(request, "ambiguous",
                "'\(request.target ?? "")' matches more than one session; use a longer id.")
        case .mismatch(let expected):
            return controlError(request, "wrong_agent",
                "That id belongs to \(expected) — use that handle (copied verbatim from `list`).")
        }
    }

    /// Selects the session in the sidebar and brings termio to the front — the
    /// "come look at this" verb, for jumping to an agent's live pane from any shell.
    private func focusSession(_ request: ControlRequest, in project: Project) -> Data {
        switch resolveTarget(request.target, in: project) {
        case .found(let session):
            let handle = sessionHandle(for: session)
            selectedSessionID = session.id
            NSApp.activate(ignoringOtherApps: true)
            return control(request, ok: true, text: "focused \(handle)", json: ["focused": handle])
        case .notFound:
            return controlError(request, "not_found", targetNotFoundMessage(request.target))
        case .ambiguous:
            return controlError(request, "ambiguous",
                "'\(request.target ?? "")' matches more than one session; use a longer id.")
        case .mismatch(let expected):
            return controlError(request, "wrong_agent",
                "That id belongs to \(expected) — use that handle (copied verbatim from `list`).")
        }
    }

    /// Resolves the calling agent to its project: by the `TERMIO_SESSION` the PTY
    /// carries (exact), else by a working directory that sits inside a project's
    /// directory or one of its session worktrees (the fallback for a plain shell).
    private func callerProject(session id: String?, cwd: String?) -> Project? {
        if let id, let uuid = UUID(uuidString: id), let project = project(for: uuid) {
            return project
        }
        guard let cwd else { return nil }
        let target = URL(fileURLWithPath: cwd).standardizedFileURL.path
        func contains(_ directory: String) -> Bool {
            let base = URL(fileURLWithPath: directory).standardizedFileURL.path
            return target == base || target.hasPrefix(base + "/")
        }
        // A session worktree is the most specific match, so prefer it.
        for project in projects {
            for session in project.sessions where session.worktreePath.map(contains) == true {
                return project
            }
        }
        return projects.first { contains($0.path) }
    }

    private enum TargetResolution {
        case found(Session)
        case notFound
        case ambiguous
        /// The id resolved, but the handle's agent name isn't that session's —
        /// a mis-spliced handle. Carries the correct handle for the error message.
        case mismatch(expected: String)
    }

    /// Matches a target token within the caller's project. A `<agent>@<id>` handle
    /// resolves by the id part alone (prefix match) and then checks the name part
    /// against the session it found; a bare token keeps the pre-handle forms —
    /// full id, id prefix, or display title (case-insensitive). Ambiguity is
    /// reported rather than guessed.
    private func resolveTarget(_ token: String?, in project: Project) -> TargetResolution {
        guard let token = token?.trimmingCharacters(in: .whitespaces).lowercased(), !token.isEmpty else {
            return .notFound
        }
        if let at = token.firstIndex(of: "@"), at != token.startIndex {
            let name = String(token[..<at])
            let idPart = String(token[token.index(after: at)...])
            guard !idPart.isEmpty, idPart.allSatisfy(\.isHexDigit) else { return .notFound }
            let matches = project.sessions.filter {
                $0.id.uuidString.lowercased().hasPrefix(idPart)
            }
            switch matches.count {
            case 0: return .notFound
            case 1:
                let session = matches[0]
                guard agentNames(for: session).contains(name) else {
                    return .mismatch(expected: sessionHandle(for: session))
                }
                return .found(session)
            default: return .ambiguous
            }
        }
        // Match the *displayed* title only, never the stored one: `list` shows the
        // display title (terminals are re-indexed live), so that's what an agent
        // references. The stored title is an internal worktree-slug seed and can
        // collide with another session's display title — matching it would make an
        // unambiguous name read as ambiguous.
        let matches = project.sessions.filter { session in
            let id = session.id.uuidString.lowercased()
            return id == token
                || id.hasPrefix(token)
                || displayTitle(for: session).lowercased() == token
        }
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0])
        default: return .ambiguous
        }
    }

    /// Every name a handle may carry for this session, lowercased: the declared
    /// and the detected (effective) agent both count, so a handle minted before a
    /// plain terminal was upgraded to the agent running inside it stays valid.
    private func agentNames(for session: Session) -> Set<String> {
        var names: Set<String> = []
        for agent in [session.agent, effectiveAgent(for: session)] {
            names.insert(agent.wireName.lowercased())
            names.insert(agent.id.lowercased())
            names.insert(agent.displayName.lowercased())
            names.insert(agent.displayName.lowercased().replacingOccurrences(of: " ", with: "-"))
        }
        return names
    }

    private func targetNotFoundMessage(_ token: String?) -> String {
        "No session '\(token ?? "")' in this project. Run `termio sessions list` to see handles."
    }

    private func control(_ request: ControlRequest, ok: Bool, text: String, json: [String: Any]) -> Data {
        if request.wantsJSON {
            var object = json
            object["ok"] = ok
            let data = (try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return data + Data("\n".utf8)
        }
        return Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
    }

    private func controlError(_ request: ControlRequest, _ code: String, _ message: String) -> Data {
        control(request, ok: false, text: "error: \(message)", json: ["error": code, "message": message])
    }

    private static func shortID(_ id: Session.ID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    static func statusToken(_ status: SessionStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .working: return "working"
        case .done: return "done"
        case .needsAttention: return "needs-you"
        }
    }
}
