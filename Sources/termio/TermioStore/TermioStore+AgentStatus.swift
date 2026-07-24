import Foundation

extension TermioStore {
    /// Brings up the hook socket and aligns `~/.claude/settings.json` with the
    /// current setting. The listener always runs (it is harmless when no hooks are
    /// installed); only the settings-file side is toggled.
    func startHookMonitoring() {
        let listener = HookListener { [weak self] report in
            self?.applyStatusReport(report)
        }
        listener.start()
        hookListener = listener
        installedHooksEnabled = settings.agentHooksEnabled
        syncHooksInstallation()

        // The timeout it enforces is a handful of seconds (a quiet terminal is the
        // "turn ended" signal), so the sweep has to tick at that granularity to
        // clear a stuck spinner promptly. A 2s repeating timer is negligible.
        staleWorkingSweep = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepStaleWorking() }
        }
    }

    /// Re-aligns the installed hooks when, and only when, the hooks setting itself
    /// changed. Called from the shared settings observer, which fires for every
    /// preference, so the guard keeps unrelated changes from rewriting the file.
    func syncHooksInstallationIfNeeded() {
        guard installedHooksEnabled != settings.agentHooksEnabled else { return }
        installedHooksEnabled = settings.agentHooksEnabled
        syncHooksInstallation()
    }

    private func syncHooksInstallation() {
        AgentStatusHooks.sync(enabled: settings.agentHooksEnabled)
    }

    /// Brings up the control socket and aligns the agents' awareness note with the
    /// current setting. Like the hook listener, the socket always runs; only the
    /// note written into the agent instruction files is toggled.
    func startSessionControl() {
        let control = SessionControlListener(
            onRequest: { [weak self] request in
                await self?.handleSessionControl(request) ?? Data()
            },
            onWatch: { [weak self] request in
                self?.resolveWatchScope(request) ?? (nil, nil, [])
            })
        control.start()
        sessionControl = control
        installedSessionControlEnabled = settings.sessionControlEnabled
        syncSessionControlInstallation()
    }

    func syncSessionControlInstallationIfNeeded() {
        guard installedSessionControlEnabled != settings.sessionControlEnabled else { return }
        installedSessionControlEnabled = settings.sessionControlEnabled
        syncSessionControlInstallation()
    }

    private func syncSessionControlInstallation() {
        SessionSkillInstaller.sync(enabled: settings.sessionControlEnabled)
    }

    /// Maps a normalized agent status report onto the session's status. This is the
    /// only path that drives `.working`: an agent's hooks expose when a turn (or a
    /// tool) *starts*, which the surface bell/OSC signals never could. The two
    /// layers coexist by writing the same per-session status — hooks add precision when
    /// installed, the zero-config signals remain the fallback when they are not.
    private func applyStatusReport(_ report: StatusReport) {
        guard let id = sessionID(for: report) else { return }
        // Remember the session's transcript address whenever a hook carries it, so
        // `sessions send` can hand it back as the place to read the response.
        let carriedTranscript = report.transcriptPath.flatMap { $0.isEmpty ? nil : $0 }
        if let path = carriedTranscript {
            transcriptPaths[id] = path
        }
        // Conversation identity may only move on an *exactly-stamped* report — the
        // hook files are global, so every same-agent process on the machine reports
        // here, and a cwd-guessed match must never re-pin this tab to an outside
        // run's conversation. And only at a turn boundary: a working-state payload
        // embeds prompt/tool content on stdin, where a colliding field name could be
        // mined as the id by mistake; SessionStart/Stop payloads are the agent's own
        // minimal envelope. (`sessionID(for:)` already validated the stamp maps to a
        // session this app owns.)
        let stamped = report.termioSession.map { !$0.isEmpty } ?? false
        if stamped, report.state != "working" {
            if let path = carriedTranscript {
                // A hook-carried path can name a *new* conversation id in its filename
                // (after `/clear`), so advance the resume pin to match — a no-op unless
                // it actually rotated. See docs/design/agent-resume-identity.md.
                reconcileResumeID(id, transcriptPath: path)
            }
            if let conversation = conversationToken(report.conversationID) {
                // An identity-bearing report names the live conversation outright — the
                // rotation signal for agents whose hook host exposes the id (the
                // manifest's `hooks.conversation`). On a rotation without a hook-carried
                // transcript, drop the stale path that described the discarded
                // conversation; the shared resolve below re-learns it against the new pin.
                if adoptConversationID(conversation, for: id), carriedTranscript == nil {
                    transcriptPaths[id] = nil
                }
            } else if report.state == "done" {
                // Identity-blind turn end: for a discovered-id agent, re-scan its store
                // in case the conversation rotated in-process (`/new`) since discovery.
                rediscoverConversation(for: id)
            }
        }
        if transcriptPaths[id] == nil, let path = resolveTranscriptPath(for: id) {
            // The hook didn't carry a path (a pre-hook Claude session never will), so
            // learn it from the agent's own on-disk transcript instead — same result
            // as Claude's hook-carried path, just discovered.
            transcriptPaths[id] = path
        }
        // Any recognized report proves this session's hooks are alive and speaking,
        // which tells the screen-driven promotion to stand down (`hookQuietWindow`).
        if ["working", "done", "attention", "idle"].contains(report.state) {
            lastHookReportAt[id] = Date()
        }
        switch report.state {
        case "working":
            // Spin a row only when it's genuinely an agent: a declared agent session,
            // or a plain terminal we've detected a hand-started agent running in (its
            // hook carries `TERMIO_SESSION`, so it routes here correctly). A bare
            // terminal with nothing detected — or a cwd-matched report from a sibling —
            // stays calm, so only real agent rows show the thinking spinner.
            guard let session = session(id), effectiveAgent(for: session) != .terminal
            else { break }
            setStatus(.working, for: id)
            setCurrentTool(report.tool, for: id)
            // Remember when work was last seen, so a turn that ends abnormally
            // (the agent crashed and never sent `done`) can be swept back to calm
            // instead of spinning forever — the failure mode cmux's own tracker
            // suffers from (issue #3749). (Floating the project up the Recent-Activity
            // sort is handled by `setStatus`'s working transition.)
            lastWorkingAt[id] = Date()
        case "done":
            // The turn finished — always leave a "ready for you" green dot, even on
            // the session the user is currently looking at, so a finished agent stays
            // on the menu-bar roster instead of blinking off the instant it stops.
            // The dot is cleared by engaging with the row (`markSeen`, wired to the
            // sidebar/tray click) or by the next turn starting. Distinct from
            // `needsAttention`, which is reserved for the agent being blocked on you.
            clearWorking(id)
            setStatus(.done, for: id)
        case "attention":
            // The agent is blocked waiting on the user (a permission prompt or a
            // free-text answer). Mirror the bell path: only flag a session the user
            // isn't already looking at.
            clearWorking(id)
            if selectedSessionID != id { setStatus(.needsAttention, for: id) }
        case "idle":
            clearWorking(id)
            setStatus(.idle, for: id)
        default:
            break
        }
    }

    /// A reported conversation id, accepted only when it is a bare token — the ids
    /// every agent mints (UUIDs, `ses_…`) always are. The shell-hook path mines the
    /// value out of an arbitrary stdin blob, so anything else (pasted JSON, a path,
    /// whitespace) is treated as no identity rather than adopted into the pin.
    private func conversationToken(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 128,
              raw.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
        else { return nil }
        return raw
    }

    private func clearWorking(_ id: Session.ID) {
        setCurrentTool(nil, for: id)
        lastWorkingAt[id] = nil
        promotionStreak[id] = nil
    }

    /// Drops every per-session activity-tracking entry — the one place that
    /// enumerates these dictionaries, so the teardown paths (close, project
    /// removal, relaunch) can't drift out of step when a new tracker is added.
    /// `transcriptPaths` is deliberately not here: a relaunch resumes the same
    /// conversation, so only the close/remove paths clear it (inline).
    func clearActivityTracking(for id: Session.ID) {
        lastWorkingAt[id] = nil
        lastHookReportAt[id] = nil
        lastUserInputAt[id] = nil
        promotionStreak[id] = nil
        lastTitleActivity[id] = nil
        lastScreenActivity[id] = nil
    }

    /// Marks the moment of live user input into a session's terminal. Keystroke
    /// echo and mouse-mode scrolling repaint the screen exactly like agent
    /// output, so promotion holds off while the human is the one causing the
    /// changes. Fed each status poke from `PTYProcess.lastInputAt` — the choke
    /// point every input path crosses (Mac surface, phone companion bridge,
    /// synthetic `sessions send`) — hence the monotonic guard: a poke can only
    /// carry the timestamp forward.
    func noteUserInput(_ id: Session.ID, at instant: Date) {
        if let existing = lastUserInputAt[id], existing >= instant { return }
        lastUserInputAt[id] = instant
    }

    /// Keeps a session's status honest against its live output, in both directions.
    ///
    /// *Sustain*: while `.working`, a changed rendered screen (streaming tokens, a
    /// ticking spinner) refreshes `lastWorkingAt` so `sweepStaleWorking` leaves the
    /// turn alone; a static screen lets the timestamp age out — the recovery for a
    /// turn that ended without a `Stop` hook. The screen, not raw bytes, is the
    /// primary key: a finished agent still dribbles output at an idle prompt (a
    /// redraw, a blinking cursor), which is exactly the stuck-spinner failure. The
    /// byte-rate floor is the one exception — a viewport the user scrolled away
    /// from stops changing even mid-stream (`readViewportText` follows the scroll),
    /// so a genuinely streaming byte volume also counts as liveness.
    ///
    /// *Promote*: a session whose hooks have gone quiet can also come back the
    /// other way. Hooks miss turns in the wild — an uninstalled/broken hook file, a
    /// turn the sweep cleared mid-stream, an agent whose TUI never fires them — and
    /// historically nothing could re-light the spinner until the next hook event.
    /// Two consecutive changed ticks promote `.idle` back to `.working`, guarded
    /// so precision states are never guessed over: never out of `.done` or
    /// `.needsAttention`, not while recent hooks are speaking for the session
    /// (`hookQuietWindow`), not right after launch (the banner painting), not right
    /// after user input (keystroke echo), and never for a plain terminal or an
    /// agent whose declared screen rules already own its status.
    ///
    /// Fed by a throttled once-a-second tap on the PTY stream (see
    /// `surface(for:in:)`); no-ops cost a dictionary lookup.
    func noteOutputActivity(_ id: Session.ID, screenChanged: Bool, bytes: Int) {
        if status(for: id) == .working {
            promotionStreak[id] = nil
            if screenChanged || bytes >= streamingByteFloor {
                lastWorkingAt[id] = Date()
            }
            return
        }
        guard screenChanged else {
            promotionStreak[id] = nil
            return
        }
        guard status(for: id) == .idle,
              let session = session(id),
              effectiveAgent(for: session) != .terminal,
              effectiveAgent(for: session).statusRules == nil
        else { return }
        let now = Date()
        if let launched = session.launchedAt, now.timeIntervalSince(launched) < launchGraceWindow {
            return
        }
        if let input = lastUserInputAt[id], now.timeIntervalSince(input) < userInputQuietWindow {
            return
        }
        if let report = lastHookReportAt[id], now.timeIntervalSince(report) < hookQuietWindow {
            return
        }
        let streak = (promotionStreak[id] ?? 0) + 1
        guard streak >= 2 else {
            promotionStreak[id] = streak
            return
        }
        promotionStreak[id] = nil
        setStatus(.working, for: id)
        lastWorkingAt[id] = now
    }

    /// Drives status from an agent's own screen when it ships no hook system — the path
    /// for user agents whose `agent.json` declared `status` regex rules (see
    /// `AgentStatusRules`). Called each throttled viewport tick with the freshly
    /// classified activity. Status is only rewritten on a *transition*, so an idle
    /// screen doesn't re-emit `done` every second; a working screen refreshes the
    /// liveness timestamp every tick so the stale sweep can't clear a live turn whose
    /// screen briefly stopped changing. Mirrors `applyStatusReport`'s state mapping —
    /// `attention` only flags a session the user isn't already looking at; a turn that
    /// just ended reads `done` when unselected, `idle` when selected or merely calm.
    func applyScreenDetectedActivity(_ activity: AgentStatusRules.Activity, for id: Session.ID) {
        if activity == .working { lastWorkingAt[id] = Date() }
        guard lastScreenActivity[id] != activity else { return }
        let previous = lastScreenActivity[id]
        lastScreenActivity[id] = activity
        switch activity {
        case .working:
            setStatus(.working, for: id)
        case .attention:
            clearWorking(id)
            if selectedSessionID != id { setStatus(.needsAttention, for: id) }
        case .idle:
            clearWorking(id)
            if previous == .working || previous == .attention {
                setStatus(selectedSessionID == id ? .idle : .done, for: id)
            } else {
                setStatus(.idle, for: id)
            }
        }
    }

    /// Drives status from the agent's live `OSC 0/2` title — the in-band state
    /// broadcast some agents ship (Claude prefixes a braille spinner mid-turn,
    /// Codex/Grok flip to "Action Required" when blocked). Unlike the screen path
    /// this *coexists* with hooks: the title is the agent's own deliberate signal
    /// on a channel that cannot break, so it corrects a missed `working` hook the
    /// instant the turn starts and ends a lost turn the instant the title calms —
    /// no 12s sweep wait, no promotion evidence-gathering. Transitions only
    /// (`lastTitleActivity`), with hooks kept senior where they are more precise:
    /// a title-working never overrides `needsAttention` (a blocked agent's title
    /// can keep spinning), and a title-idle only ends a turn — an arbitrary title
    /// (which classifies idle by no-match) must not clear hook-set states.
    func applyTitleActivity(_ activity: AgentStatusRules.Activity, for id: Session.ID) {
        guard lastTitleActivity[id] != activity else { return }
        let previous = lastTitleActivity[id]
        lastTitleActivity[id] = activity
        switch activity {
        case .working:
            guard status(for: id) != .needsAttention else { return }
            guard let session = session(id), effectiveAgent(for: session) != .terminal
            else { return }
            setStatus(.working, for: id)
            lastWorkingAt[id] = Date()
        case .attention:
            clearWorking(id)
            if selectedSessionID != id { setStatus(.needsAttention, for: id) }
        case .idle:
            guard previous == .working, status(for: id) == .working else { return }
            clearWorking(id)
            setStatus(selectedSessionID == id ? .idle : .done, for: id)
        }
    }

    /// Reclassifies a shell-backed session to whatever agent runs in its foreground —
    /// for real, not as a runtime overlay: a hand-started `claude` makes the session
    /// *become* a Claude Code session (persisted, so a reopened app relaunches it as
    /// that agent, resuming the conversation its hooks pinned meanwhile), and the
    /// agent exiting back to the shell demotes it to a plain terminal again. The
    /// identity always says what the pane runs. Only sessions spawned with a shell
    /// underneath ever report here (the detection sink exists solely for them), so a
    /// promoted row keeps polling and the demotion fires when its shell resurfaces.
    /// Idempotent per poll; an SSH terminal is never reclassified (its foreground is
    /// the local `ssh`, and the agents run remotely).
    func noteForegroundAgent(_ detected: AgentDefinition?, for id: Session.ID) {
        guard let location = locate(id) else { return }
        var session = projects[location.project].sessions[location.session]
        guard !session.isSSH else { return }
        if let detected {
            // Promote a plain terminal only: an already-promoted row seeing its own
            // agent is the idempotent no-op, and a *different* foreground under a
            // promoted row is the agent's own subprocess, not a new identity.
            guard session.agent == .terminal, detected != .terminal else { return }
            // Adopt the declared-session title convention (`addSession`) so the row
            // reads `Claude Code` — but never overwrite a name the user chose.
            if Self.isAutoTerminalName(session.title) {
                session.title = detected.displayName
            }
            session.agent = detected
            projects[location.project].sessions[location.session] = session
        } else if session.agent != .terminal {
            demoteSessionToTerminal(id)
        }
    }

    /// The one place a session stops being an agent: reverts the row to a plain
    /// terminal (persisted) and clears the conversation-scoped runtime state — the
    /// adopted topic title and any lingering spinner — so the row can't be left
    /// mid-turn once the agent is gone. The resume pin deliberately survives: it is
    /// dormant on a terminal row, and it still names the conversation this pane last
    /// hosted. Shared by the foreground poll (agent quit back to its shell) and the
    /// clean-exit revert of an exec'd agent session (`revertSessionToShell`).
    func demoteSessionToTerminal(_ id: Session.ID) {
        guard let location = locate(id) else { return }
        var session = projects[location.project].sessions[location.session]
        guard session.agent != .terminal else { return }
        // Un-renamed rows fall back to the auto `Terminal N` convention (numbered
        // like `addSession`, counting this row itself), so display naming — cwd
        // basename for loose terminals — takes over again.
        if session.title == session.agent.displayName {
            let terminalCount = projects[location.project].sessions
                .filter { $0.agent == .terminal }.count
            session.title = "Terminal \(terminalCount + 1)"
        }
        session.agent = .terminal
        session.liveTitle = nil
        projects[location.project].sessions[location.session] = session
        setLiveTitle(nil, for: id)
        lastTitleActivity[id] = nil
        clearWorking(id)
        let current = status(for: id)
        if current == .working || current == .done { setStatus(.idle, for: id) }
    }

    /// Resolves a session's transcript file from disk when its hook hasn't handed
    /// termio one — the source of truth for the Info pane's trace when no hook fired.
    /// A pinned-id agent whose store is a file-per-conversation (Claude Code) names its
    /// transcript by the id termio pinned (`Session.resumeID`), so it's located directly.
    /// A discovered-id agent with a known pin is likewise looked up by that exact id —
    /// the launch-time earliest-match below would drift back to a rotated-away record —
    /// and only an unpinned session falls back to the launch-time file match
    /// (`AgentSessionStore`). For a directory-based store (Grok: `dir:{id}`), the
    /// directory itself is located and its contents scanned for a transcript file.
    /// `nil` until a matching transcript exists on disk.
    func resolveTranscriptPath(for id: Session.ID) -> String? {
        guard let session = session(id), session.launched else { return nil }
        if let store = session.agent.resumeSpec.store, !store.isDirectory,
           let resumeID = session.resumeID,
           let path = SessionStore.locate(store, id: resumeID) {
            return path
        }
        if let store = session.agent.resumeSpec.store, store.isDirectory,
           let resumeID = session.resumeID,
           let dirPath = SessionStore.locate(store, id: resumeID) {
            // Directory-based store: the session is a directory of files. Prefer the
            // manifest's `transcriptName` when set (Grok: `chat_history.jsonl`). Do not
            // fall through to sole-jsonl when a name is declared — Grok dirs routinely
            // hold several `.jsonl` files (`updates.jsonl`, `events.jsonl`, …), and a
            // briefly-missing named file must not pin a sibling. Sole-jsonl is only for
            // undeclared names where exactly one candidate exists.
            if let name = store.transcriptName {
                return transcriptFile(in: dirPath, named: name)
            }
            return soleJSONLFile(in: dirPath)
        }
        if session.agent.resumeSpec.discover != nil, let resumeID = session.resumeID {
            return AgentSessionStore.transcript(agent: session.agent, id: resumeID)
        }
        guard let directory = session.worktreePath ?? project(for: id)?.path else { return nil }
        return AgentSessionStore.discoverTranscript(
            agent: session.agent, directory: directory, after: session.launchedAt)
    }

    /// Returns the path to a named file inside a directory, or `nil` if it doesn't exist.
    private func transcriptFile(in directory: String, named name: String) -> String? {
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir),
              !isDir.boolValue else { return nil }
        return candidate
    }

    /// Returns the path to the single `.jsonl` file in a directory, or `nil` when there
    /// are zero or more than one — the transcript is ambiguous with multiple candidates.
    private func soleJSONLFile(in directory: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
        else { return nil }
        let jsonlFiles = entries.filter {
            $0.pathExtension.lowercased() == "jsonl"
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard jsonlFiles.count == 1 else { return nil }
        return jsonlFiles[0].path
    }

    /// Sweeps sessions stuck in `.working` with no activity for a generous window
    /// back to `.idle`. This only matters while the user is looking elsewhere —
    /// selecting a session already clears it — so the timeout is long enough never
    /// to interrupt a genuinely long turn (tool events keep refreshing it), and is
    /// purely a recovery path for an agent that died mid-turn.
    private func sweepStaleWorking() {
        let now = Date()
        for (id, since) in lastWorkingAt where now.timeIntervalSince(since) > staleWorkingTimeout {
            if status(for: id) == .working { setStatus(.idle, for: id) }
            clearWorking(id)
        }
    }

    /// Resolves a status report back to its session. The exact key is the
    /// `TERMIO_SESSION` id termio stamped into the PTY and the agent echoed back, so
    /// this is unambiguous even when several sessions share one project directory.
    /// A report that *carries* an id this app didn't stamp is another channel's
    /// session (the CLI broadcasts each report to both the release and dev app's
    /// sockets) and must be dropped, not cwd-guessed — that guess is exactly how a
    /// prod session's activity would light up a dev session sharing its directory.
    /// `cwd` is only a fallback for an agent whose environment didn't carry the id
    /// through to the hook at all (an agent hand-started outside termio).
    private func sessionID(for report: StatusReport) -> Session.ID? {
        if let token = report.termioSession, !token.isEmpty {
            guard let id = UUID(uuidString: token), session(id) != nil else { return nil }
            return id
        }
        return sessionID(forCwd: report.cwd)
    }

    /// Fallback correlation by working directory, for a report that arrived without
    /// a usable session id. A session's worktree directory is unique, so a single
    /// match is exact; in a shared directory we don't guess and leave status alone.
    private func sessionID(forCwd cwd: String?) -> Session.ID? {
        guard let cwd else { return nil }
        let target = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let matches = projects.flatMap { project in
            project.sessions.filter { session in
                let directory = session.worktreePath ?? project.path
                return URL(fileURLWithPath: directory).standardizedFileURL.path == target
            }
        }
        guard matches.count == 1 else { return nil }
        return matches.first?.id
    }

    /// A short description of a session's current agent activity, for the sidebar
    /// status tooltip: the tool in use while working, or what it is waiting on.
    /// Empty when idle, so the tooltip simply does not appear.
    func statusDescription(for sessionID: Session.ID) -> String {
        switch status(for: sessionID) {
        case .idle:
            return ""
        case .working:
            if let tool = runtimes[sessionID]?.currentTool { return "Working — \(tool)" }
            return "Working…"
        case .done:
            return "Done"
        case .needsAttention:
            return "Waiting for you"
        }
    }
}
