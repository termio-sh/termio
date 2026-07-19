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
        let control = SessionControlListener { [weak self] request in
            await self?.handleSessionControl(request) ?? Data()
        }
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
    /// layers coexist by writing the same `statuses` — hooks add precision when
    /// installed, the zero-config signals remain the fallback when they are not.
    private func applyStatusReport(_ report: StatusReport) {
        guard let id = sessionID(for: report) else { return }
        // Remember the session's transcript address whenever a hook carries it, so
        // `sessions send` can hand it back as the place to read the response.
        if let path = report.transcriptPath, !path.isEmpty {
            transcriptPaths[id] = path
            // The hook path is the one signal that can carry a *new* conversation id
            // (after `/clear`), so advance the resume pin to match — a no-op unless it
            // actually rotated. See docs/design/agent-resume-identity.md.
            reconcileResumeID(id, transcriptPath: path)
        } else if transcriptPaths[id] == nil, let path = resolveTranscriptPath(for: id) {
            // The hook didn't carry a path (Codex never does; a pre-hook Claude session
            // never will), so learn it from the agent's own on-disk transcript instead —
            // same result as Claude's hook-carried path, just discovered.
            transcriptPaths[id] = path
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
            statuses[id] = .working
            currentTool[id] = report.tool
            // Remember when work was last seen, so a turn that ends abnormally
            // (the agent crashed and never sent `done`) can be swept back to calm
            // instead of spinning forever — the failure mode cmux's own tracker
            // suffers from (issue #3749).
            lastWorkingAt[id] = Date()
            // A working agent is the strongest "this project is active" signal, so
            // float its project up under the "Recent Activity" sort (see `orderedProjects`).
            if let pid = project(for: id)?.id { liveActivity[pid] = Date() }
        case "done":
            // The turn finished. If the user is looking at it, calm; otherwise a
            // gentle "ready for you" cue — distinct from `needsAttention`, which is
            // reserved for the agent actually being blocked on the user.
            clearWorking(id)
            statuses[id] = (selectedSessionID == id) ? .idle : .done
        case "attention":
            // The agent is blocked waiting on the user (a permission prompt or a
            // free-text answer). Mirror the bell path: only flag a session the user
            // isn't already looking at.
            clearWorking(id)
            if selectedSessionID != id { statuses[id] = .needsAttention }
        case "idle":
            clearWorking(id)
            statuses[id] = .idle
        default:
            break
        }
    }

    private func clearWorking(_ id: Session.ID) {
        currentTool[id] = nil
        lastWorkingAt[id] = nil
        promotionStreaks[id] = nil
    }

    /// How many consecutive changed-screen pokes (at the tap's ~1s cadence) an
    /// un-working agent session must show before it is promoted back to
    /// `.working`, and how large a gap between pokes breaks the run. Three
    /// pokes ≈ 3s of sustained repaint — long enough to skip one-off redraws
    /// (a resize, a settled prompt), short enough that a missed hook shows a
    /// spinner within a few seconds of real streaming.
    private var promotionStreakThreshold: Int { 3 }
    private var promotionStreakMaxGap: TimeInterval { 5 }

    /// Judges a session's liveness — and, when the evidence is sustained, its
    /// working-ness — from the rendered screen. Two directions share this tap:
    ///
    /// **Sustain** — while `.working`, a changing viewport keeps `lastWorkingAt`
    /// fresh; the moment the screen goes static (the agent is back at its
    /// prompt), the timestamp stops advancing and `sweepStaleWorking` clears the
    /// spinner. Keying on the *screen* rather than raw bytes is what closes the
    /// gap for a finished agent that keeps dribbling output at an idle prompt (a
    /// redraw, a blinking cursor) — the stuck-spinner failure.
    ///
    /// **Promote** — hooks are the primary working authority, but a single
    /// missed `working` report (a failed hook script, an early `Stop` on a
    /// continued turn) used to pin the row calm forever while output streamed:
    /// this tap could only sustain, never start, a spinner. A sustained run of
    /// changed-screen pokes now flips an agent row back to `.working`, behind
    /// four guards: only agent sessions (a bare terminal never spins), never
    /// while `needsAttention` is asserted (a blocked prompt repaints too — the
    /// hook keeps sole authority over attention), never within the input-echo
    /// window (typing a prompt repaints the composer sub-second), and only
    /// after `promotionStreakThreshold` consecutive pokes (a one-off redraw is
    /// not a turn). Downgrades still come only from hooks and the stale sweep,
    /// so hooks remain the one authority for attention/done.
    ///
    /// Fed by a throttled tap on the PTY stream (see `surface(for:in:)`);
    /// `inputRecently` derives from `PTYProcess.lastInputAt`, which both the
    /// Mac and phone input paths stamp.
    func noteOutputActivity(_ id: Session.ID, screenChanged: Bool, inputRecently: Bool) {
        if statuses[id] == .working {
            promotionStreaks[id] = nil
            guard screenChanged else { return }
            lastWorkingAt[id] = Date()
            return
        }
        guard screenChanged, !inputRecently else {
            promotionStreaks[id] = nil
            return
        }
        guard statuses[id] != .needsAttention else { return }
        guard let session = session(id), effectiveAgent(for: session) != .terminal else { return }
        let now = Date()
        var streak = promotionStreaks[id] ?? (count: 0, last: now)
        if now.timeIntervalSince(streak.last) > promotionStreakMaxGap {
            streak = (count: 0, last: now)
        }
        streak = (count: streak.count + 1, last: now)
        guard streak.count >= promotionStreakThreshold else {
            promotionStreaks[id] = streak
            return
        }
        promotionStreaks[id] = nil
        statuses[id] = .working
        lastWorkingAt[id] = now
        if let pid = project(for: id)?.id { liveActivity[pid] = now }
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
            statuses[id] = .working
            if let pid = project(for: id)?.id { liveActivity[pid] = Date() }
        case .attention:
            clearWorking(id)
            if selectedSessionID != id { statuses[id] = .needsAttention }
        case .idle:
            clearWorking(id)
            if previous == .working || previous == .attention {
                statuses[id] = (selectedSessionID == id) ? .idle : .done
            } else {
                statuses[id] = .idle
            }
        }
    }

    /// Records (or clears) the agent detected running in a plain terminal's
    /// foreground, upgrading the row to a first-class agent while it runs (brand icon,
    /// adopted live title, working spinner) and reverting it to a plain terminal when
    /// it exits. Terminal-only (a declared agent session is never reclassified) and
    /// idempotent (unchanged detection is a no-op, so the once-a-second poll is cheap).
    /// On clear it also drops the transient agent title and any lingering spinner so
    /// the row can't be left mid-turn once the agent is gone.
    func noteForegroundAgent(_ detected: AgentDefinition?, for id: Session.ID) {
        guard session(id)?.agent == .terminal else { return }
        guard detectedAgents[id] != detected else { return }
        if let detected {
            detectedAgents[id] = detected
        } else {
            detectedAgents[id] = nil
            liveTitles[id] = nil
            clearWorking(id)
            if statuses[id] == .working || statuses[id] == .done { statuses[id] = .idle }
        }
    }

    /// Resolves a session's transcript file from disk when its hook hasn't handed
    /// termio one — the source of truth for the Info pane's trace when no hook fired.
    /// Claude Code names its transcript by the id termio pinned (`Session.resumeID`),
    /// so it's located directly; Codex/OpenCode fall back to the launch-time file
    /// match (`AgentSessionStore`). `nil` until a matching transcript exists on disk.
    func resolveTranscriptPath(for id: Session.ID) -> String? {
        guard let session = session(id), session.launched else { return nil }
        if session.agent == .claudeCode {
            return session.resumeID.flatMap(ClaudeConversation.transcriptPath)
        }
        guard let directory = session.worktreePath ?? project(for: id)?.path else { return nil }
        return AgentSessionStore.discoverTranscript(
            agent: session.agent, directory: directory, after: session.launchedAt)
    }

    /// Sweeps sessions stuck in `.working` with no activity for a generous window
    /// back to `.idle`. This only matters while the user is looking elsewhere —
    /// selecting a session already clears it — so the timeout is long enough never
    /// to interrupt a genuinely long turn (tool events keep refreshing it), and is
    /// purely a recovery path for an agent that died mid-turn.
    private func sweepStaleWorking() {
        let now = Date()
        for (id, since) in lastWorkingAt where now.timeIntervalSince(since) > staleWorkingTimeout {
            if statuses[id] == .working { statuses[id] = .idle }
            clearWorking(id)
        }
    }

    /// Resolves a status report back to its session. The exact key is the
    /// `TERMIO_SESSION` id termio stamped into the PTY and the agent echoed back, so
    /// this is unambiguous even when several sessions share one project directory.
    /// `cwd` is only a fallback for an agent whose environment didn't carry the id
    /// through to the hook.
    private func sessionID(for report: StatusReport) -> Session.ID? {
        if let token = report.termioSession,
           let id = UUID(uuidString: token),
           session(id) != nil {
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
            if let tool = currentTool[sessionID] { return "Working — \(tool)" }
            return "Working…"
        case .done:
            return "Done"
        case .needsAttention:
            return "Waiting for you"
        }
    }
}
