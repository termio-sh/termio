import AppKit
import Foundation
import GhosttyKit
import GhosttyTerminal
import os

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
    /// Per-op enter/exit timing for control requests, readable via
    /// `log stream --predicate 'category == "session-control"'`. The exit line's
    /// elapsed time is how long the op occupied the request path — the number
    /// that catches head-of-line blocking on the main actor (design doc §4.2).
    private static let controlTiming = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "sh.termio.app", category: "session-control")

    func handleSessionControl(_ request: ControlRequest) async -> Data {
        let entered = ContinuousClock.now
        Self.controlTiming.info("enter op=\(request.op, privacy: .public)")
        defer {
            let elapsed = entered.duration(to: .now)
            Self.controlTiming.info(
                "exit op=\(request.op, privacy: .public) elapsed_ms=\(Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000), privacy: .public)")
        }
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
    /// the stream to plus the initial status snapshot (one event per scoped session,
    /// unless the client opted out), or an error payload to write back before hanging
    /// up. The same gating as any control op (session control enabled, caller
    /// resolves to a project); the streaming itself is `SessionWatchHub`'s job.
    func resolveWatchScope(_ request: ControlRequest) -> (UUID?, Data?, [SessionWatchEvent]) {
        guard settings.sessionControlEnabled else {
            return (nil, controlError(request, "disabled",
                "Session control is off. Enable it in termio ▸ Settings ▸ Agents."), [])
        }
        guard let project = callerProject(session: request.callerSession, cwd: request.callerCwd) else {
            return (nil, controlError(request, "no_scope",
                "Couldn't tell which project you're in. Run this from inside a termio session."), [])
        }
        guard request.snapshot != false else { return (project.id, nil, []) }
        let snapshot = project.sessions.map { session -> SessionWatchEvent in
            var event = SessionWatchEvent(
                projectID: project.id,
                handle: sessionHandle(for: session),
                status: Self.statusToken(status(for: session.id)),
                title: displayTitle(for: session),
                cwd: runtimes[session.id]?.workingDirectory ?? "",
                snapshot: true)
            attachActionablePayload(to: &event, for: session.id)
            return event
        }
        return (project.id, nil, snapshot)
    }

    /// Fills in what makes an event actionable without a second round-trip (design
    /// doc §4.3): the on-screen question for `needs-you`, the transcript address +
    /// current length for `done`. Shared by the watch snapshot and the live
    /// `setStatus` broadcast.
    func attachActionablePayload(to event: inout SessionWatchEvent, for id: Session.ID) {
        switch event.status {
        case "needs-you":
            event.prompt = promptExcerpt(for: id)
        case "done":
            if let transcript = transcriptPaths[id] {
                event.transcript = transcript
                event.cursorEnd = Self.lineCount(of: transcript)
            }
        default:
            break
        }
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
            return await deliver(payload, to: session, state: state, request: request, in: project)
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
        let delivered = (callerEnvelope(for: request) ?? "") + payload
        // With `--wait`, the caller opted back into blocking — but for the *outcome*
        // (§4.4), never just the plumbing: boot-settle, deliver, then hold the reply
        // until the spawned agent's first turn settles.
        if request.wantsWait {
            await waitForBootSettle(of: state)
            guard await performDelivery(delivered, to: fresh, state: state) else {
                return controlError(request, "not_live",
                    "\(displayTitle(for: fresh)) has no live terminal yet — open it once in termio.")
            }
            let cursorAtSend = transcriptPaths[fresh.id].map(Self.lineCount)
            return await waitForReply(request, session: fresh,
                                      cursorAtSend: cursorAtSend, created: true)
        }
        // Reply with the handle now; boot-settle + prompt delivery continue off the
        // reply path so no verb silently blocks (§4.2). A delivery failure has no
        // caller left to tell — it surfaces through the session's own status and
        // its visibly broken pane, which the caller is about to watch anyway.
        let handle = sessionHandle(for: fresh)
        Task { [weak self] in
            guard let self else { return }
            await self.waitForBootSettle(of: state)
            if await !self.performDelivery(delivered, to: fresh, state: state) {
                FileHandle.standardError.write(Data(
                    "termio: session control could not deliver the queued prompt to \(handle)\n".utf8))
            }
        }
        return spawnQueuedReply(request, fresh)
    }

    /// The provenance envelope prepended to a spawned session's prompt when the
    /// spawner is itself a termio session (design doc §4.6) — without it the new
    /// agent has no idea who spawned it and can only stop as `needs-you` and hope.
    /// It opens exactly one back-channel: a mid-task question, or a one-line
    /// completion ping, via `sessions send` to the caller. The hard limits ride in
    /// the envelope text itself because agent↔agent messaging invites loops and
    /// injection — no conversation, no delegating work back, and completion stays
    /// transcript-as-truth (the supervisor's `watch`/transcript path remains the
    /// reliable backstop). A plain-shell caller resolves no session → no envelope.
    private func callerEnvelope(for request: ControlRequest) -> String? {
        guard let callerID = request.callerSession, let uuid = UUID(uuidString: callerID),
              let caller = session(uuid) else { return nil }
        let callerHandle = sessionHandle(for: caller)
        return """
        [termio] You were spawned by the sibling agent session \(callerHandle). \
        If you hit a question only they can answer, ask it mid-task with: \
        termio sessions send \(callerHandle) "QUESTION: <your question>" — and when \
        you finish you may send at most one line: \
        termio sessions send \(callerHandle) "DONE: <one line>". \
        Use this channel for nothing else: no conversation, no status updates, and \
        never delegate tasks back to them. They read your actual results from your \
        transcript, so put everything that matters in your normal replies. \
        Your task follows.

        """
    }

    /// Types `payload` into an existing sibling's surface and builds the reply.
    /// Without `--wait` the reply is the send acknowledgement (the transcript path
    /// + a cursor to read the response from); with it, the call blocks until the
    /// turn settles and reports the outcome plus the transcript range it landed in.
    private func deliver(
        _ payload: String, to session: Session, state: TerminalViewState,
        request: ControlRequest, in project: Project
    ) async -> Data {
        guard await performDelivery(payload, to: session, state: state) else {
            return controlError(request, "not_live",
                "\(displayTitle(for: session)) has no live terminal yet — open it once in termio.")
        }
        guard request.wantsWait else { return sentReply(request, session) }
        // The cursor to read the reply from: wherever the transcript stands right
        // after submitting. A session's transcript often isn't known until a hook
        // fires mid-turn, so this can be nil and is re-read after the wait.
        let cursorAtSend = transcriptPaths[session.id].map(Self.lineCount)
        return await waitForReply(request, session: session,
                                  cursorAtSend: cursorAtSend, created: false)
    }

    /// Types `payload` into a session's live surface and submits it. Shared by
    /// the existing-sibling reply path and the fresh-spawn detached delivery.
    private func performDelivery(
        _ payload: String, to session: Session, state: TerminalViewState
    ) async -> Bool {
        // The libghostty surface attaches lazily on the pane's first render, so a
        // session never shown in the UI has no surface yet. Selecting it adds it to
        // the mounted set; give the render one cycle. (A session shown even once
        // stays mounted, so this only foregrounds on the very first drive.)
        if state.surface == nil {
            selectedSessionID = session.id
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard let surfaceHandle = Self.rawSurface(from: state) else { return false }

        // Type the prompt through the text path (fine for the body), then submit
        // with a real Return *key event*. A trailing "\r" in the text is delivered
        // as a bracketed paste, which an agent TUI (Claude Code) reads as a newline
        // — never a submit. `ghostty_surface_key` drives the surface directly, with
        // no focus or first-responder needed; this is exactly how Ghostty's own
        // AppleScript `send key` submits Enter.
        _ = state.send(payload)
        try? await Task.sleep(for: .milliseconds(40))
        Self.pressReturn(on: surfaceHandle)
        return true
    }

    /// Blocks until the session the prompt was sent to finishes its turn — or stops
    /// to ask the user (`needs-you`) — or the timeout elapses, then reports the
    /// outcome. This is what lets a caller issue one `send --wait` instead of
    /// sending and then polling `list` in a loop.
    ///
    /// Completion is read primarily from the **status resting**: the turn is done once
    /// the session, having been seen `working`, drops back off `working` and stays there
    /// for `settleWindow` (`needs-you` short-circuits immediately). Status is the signal
    /// every real agent drives — built-ins via hooks, rule-based agents via the screen
    /// classifier — and unlike a raw screen watch it is immune to a TUI footer that keeps
    /// animating after the reply. A 300ms poll always catches the `working` span of a real
    /// turn (an LLM round-trip is far longer). Only a session with no status signal at all
    /// — a plain terminal driven by `send --wait` — falls back to the screen first changing
    /// and then going still. Each poll awaits off the actor, so a long wait never blocks
    /// other control requests (§4.2 stays true even mid-wait).
    ///
    /// Two failure modes end the wait early instead of burning the whole timeout,
    /// both adopted from herdr's agent-wait design:
    /// - **Stalled prompt**: from a non-`working` start, *some* effect — a status
    ///   move or a screen change — must appear within `stallWindow`, or the
    ///   keystrokes were eaten (a half-booted TUI, a program that ignores typed
    ///   text) and no turn is coming: `prompt_stalled`, immediately. A `--timeout`
    ///   at or under the window keeps the plain timeout reply instead.
    /// - **Occupant gone**: the wait is pinned to the session and agent it started
    ///   on. The session closing mid-wait is `session_closed`; its agent exiting
    ///   back to a plain shell is `agent_gone`. (A plain-terminal target is exempt
    ///   from the pin — a sent command line may legitimately start an agent in the
    ///   pane, which is progress, not replacement.)
    private func waitForReply(
        _ request: ControlRequest, session: Session,
        cursorAtSend: Int?, created: Bool
    ) async -> Data {
        let cap = min(max(request.timeoutMs ?? 300_000, 1_000), 600_000)
        let started = Date()
        let deadline = started.addingTimeInterval(Double(cap) / 1_000)
        let settleWindow = 1.5
        let stallWindow = 5.0

        let statusAtSend = status(for: session.id)
        let occupantAtSend = effectiveAgent(for: session)
        var sawWorking = false
        var restingSince: Date?
        var lastFrame = viewportText(for: session.id)
        var lastChangeAt = started
        var changedSinceSend = false
        var settled: SessionStatus?

        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
            guard let live = self.session(session.id) else {
                return controlError(request, "session_closed",
                    "\(sessionHandle(for: session)) was closed while waiting on it.")
            }
            let occupant = effectiveAgent(for: live)
            if occupantAtSend != .terminal, occupant.id != occupantAtSend.id {
                var message = "The \(occupantAtSend.displayName) agent in "
                    + "\(sessionHandle(for: session)) exited mid-wait; no reply is coming."
                if let transcript = transcriptPaths[session.id] {
                    message += " Its transcript (\(transcript)) holds whatever it did first."
                }
                return controlError(request, "agent_gone", message)
            }

            let current = status(for: session.id)
            if current == .working {
                sawWorking = true
                restingSince = nil
            } else if restingSince == nil {
                restingSince = Date()
            }

            let now = Date()
            let frame = viewportText(for: session.id)
            if frame != lastFrame {
                lastFrame = frame
                lastChangeAt = now
                changedSinceSend = true
            }

            // needs-you settles the wait immediately — but only as *new* evidence.
            // A session already blocked at send time (the caller is answering its
            // menu) must not read as "still waiting on you" on the first poll,
            // before the agent has had a chance to react to the answer.
            if current == .needsAttention,
               statusAtSend != .needsAttention || sawWorking || changedSinceSend {
                settled = .needsAttention
                break
            }

            if statusAtSend != .working, !sawWorking, !changedSinceSend,
               current == statusAtSend,
               Double(cap) / 1_000 > stallWindow,
               now.timeIntervalSince(started) >= stallWindow {
                return controlError(request, "prompt_stalled",
                    "The prompt showed no effect in \(sessionHandle(for: session)) within "
                    + "\(Int(stallWindow))s — no status change, no screen change. The input "
                    + "was likely eaten (agent still booting, or a program that ignores "
                    + "typed text); check the pane before resending.")
            }

            guard current != .working else { continue }
            let rested = restingSince.map { now.timeIntervalSince($0) >= settleWindow } ?? false
            let screenQuiet = now.timeIntervalSince(lastChangeAt) >= settleWindow
            // Status-tracked agent: seen working, now rested. (Footer animation can't
            // fool this — it doesn't touch status.)
            if sawWorking, rested { settled = current; break }
            // No status signal at all (a plain terminal): the screen changed, then stilled.
            if !sawWorking, changedSinceSend, screenQuiet { settled = current; break }
        }
        return waitReply(request, session: session,
                         cursorAtSend: cursorAtSend, created: created, settled: settled)
    }

    /// The reply for a completed (or timed-out) `--wait`. Every wait reply — `send`
    /// or `spawn` — shares one shape (§4.4): the turn's final `status` and the exact
    /// transcript range to read, `cursor` (where the reply begins, captured at send)
    /// through `cursor_end` (the log's length now), so the caller's own file tools
    /// read precisely the new content, no polling. When the session is blocked on
    /// the user (`needs-you`), the on-screen question rides along as `prompt` so the
    /// caller can answer without scraping the viewport.
    private func waitReply(
        _ request: ControlRequest, session: Session,
        cursorAtSend: Int?, created: Bool, settled: SessionStatus?
    ) -> Data {
        let handle = sessionHandle(for: session)
        let statusToken = Self.statusToken(status(for: session.id))
        var json: [String: Any] = [
            "target": handle,
            "title": displayTitle(for: session),
            "status": statusToken,
            "timed_out": settled == nil,
        ]
        if created { json["created"] = true }

        let headline: String
        switch settled {
        case .needsAttention: headline = "\(handle) is waiting on you"
        case .some: headline = "\(handle) finished (\(statusToken))"
        case nil: headline = "\(handle) still \(statusToken) after the wait — timed out"
        }
        var text = headline

        // The transcript may only have become known during the wait (a fresh
        // session's first hook), so re-read it here rather than trusting the
        // send-time snapshot.
        if let transcript = transcriptPaths[session.id] {
            let start = cursorAtSend ?? 0
            let end = Self.lineCount(of: transcript)
            json["transcript"] = transcript
            json["cursor"] = start
            json["cursor_end"] = end
            text += "\n  transcript: \(transcript)\n  reply: lines \(start)–\(end) (read this range)"
        }
        if settled == .needsAttention, let prompt = promptExcerpt(for: session.id) {
            json["prompt"] = prompt
            text += "\n  on screen:\n\(prompt)"
        }
        return control(request, ok: true, text: text, json: json)
    }

    /// The current viewport text of a session's terminal, or nil when it has no live
    /// in-memory backend yet (never rendered). Reads only an already-mounted surface —
    /// deliberately no `surface(for:in:)` fallback, so a status broadcast can never
    /// create a surface as a side effect. Reads through the backend's own lock
    /// (`readViewportText`), so it's safe from this actor.
    func viewportText(for id: Session.ID) -> String? {
        guard let state = surfaces[id],
              case .inMemory(let terminal) = state.configuration.backend else { return nil }
        return terminal.readViewportText()
    }

    /// The tail of a session's screen — the question or menu the agent stopped on —
    /// for `needs-you` payloads. The last dozen non-blank rows (right-trimmed, size-
    /// capped) are enough to answer from; the leading rows are the conversation the
    /// caller already has via the transcript.
    func promptExcerpt(for id: Session.ID) -> String? {
        guard let screen = viewportText(for: id) else { return nil }
        var lines = screen.components(separatedBy: "\n").map { line -> String in
            var trimmed = Substring(line)
            while trimmed.last == " " { trimmed.removeLast() }
            return String(trimmed)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        return String(lines.suffix(12).joined(separator: "\n").suffix(1_200))
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
    /// the caller's file tools resume from `cursor`.
    private func sentReply(_ request: ControlRequest, _ session: Session) -> Data {
        let handle = sessionHandle(for: session)
        var json: [String: Any] = [
            "target": handle,
            "title": displayTitle(for: session),
        ]
        var text = "sent to \(handle)"
        if let transcript = transcriptPaths[session.id] {
            let cursor = Self.lineCount(of: transcript)
            json["transcript"] = transcript
            json["cursor"] = cursor
            text += "\n  transcript: \(transcript)\n  cursor: \(cursor)  (read the response from here on)"
        }
        return control(request, ok: true, text: text, json: json)
    }

    /// The immediate reply for a fresh spawn: the handle is the payload, delivery is
    /// still in flight (`queued`). A just-spawned session has no transcript yet — it
    /// appears in `list --json` once the agent's hook reports one.
    private func spawnQueuedReply(_ request: ControlRequest, _ session: Session) -> Data {
        let handle = sessionHandle(for: session)
        let json: [String: Any] = [
            "target": handle,
            "title": displayTitle(for: session),
            "created": true,
            "queued": true,
        ]
        let text = "started \(handle) — prompt queued; use this handle for follow-ups"
            + "\n  (transcript path appears in `termio sessions list --json` once the agent reports it)"
        return control(request, ok: true, text: text, json: json)
    }

    /// Lines currently in a file, counted cheaply by newline bytes — the cursor a
    /// caller resumes a transcript read from.
    static func lineCount(of path: String) -> Int {
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
            // Every JSON reply pins the contract it speaks (§4.5) — agents are
            // coding against these shapes, and versioning them beats breaking them.
            object["schema_version"] = 1
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
