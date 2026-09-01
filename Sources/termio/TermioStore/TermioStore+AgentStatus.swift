import Foundation
import TermioShared
import os

extension TermioStore {
    /// Brings up the hook socket and aligns `~/.claude/settings.json` with the
    /// current setting. The listener always runs (it is harmless when no hooks are
    /// installed); only the settings-file side is toggled.
    /// Starts the status upkeep this app still owns. It no longer *receives*
    /// status — every hook reports to the daemon that owns its PTY, and the app
    /// reads `E status` off the session's own channel.
    ///
    /// What stays is the half that reads a **screen**: the stale-working sweep,
    /// the streak promotion, and the `OSC 0/2` title classification. They are
    /// the only status an agent with no hook system has, so they stay until the
    /// VT itself moves (docs/design/20260819-unify-server-plane.md).
    func startHookMonitoring() {
        installedHooksEnabled = settings.agentHooksEnabled
        syncHooksInstallation()
    }

    /// Whether any session is an agent (declared or detected via `effectiveAgent`). Gates
    /// the "status is off" reminder — a shell-only workspace has nothing to report.
    var isRunningAnyAgent: Bool {
        allSessions.contains { effectiveAgent(for: $0) != .terminal }
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
        syncAgentIntegration()
    }

    /// Brings up the app socket and aligns the agents' awareness note with the
    /// current setting. The socket always runs; only the note written into the agent
    /// instruction files is toggled.
    func startAppSocket() {
        let control = AppSocketListener(
            onRequest: { [weak self] request in
                await self?.handleSessionControl(request) ?? Data()
            },
            onWatch: { [weak self] request in
                self?.resolveWatchScope(request) ?? (nil, nil, [])
            })
        control.start()
        appSocket = control
        installedSessionControlEnabled = settings.sessionControlEnabled
        syncSessionControlInstallation()
    }

    func syncSessionControlInstallationIfNeeded() {
        guard installedSessionControlEnabled != settings.sessionControlEnabled else { return }
        installedSessionControlEnabled = settings.sessionControlEnabled
        syncSessionControlInstallation()
    }

    private func syncSessionControlInstallation() {
        syncAgentIntegration()
    }

    /// Asks the local daemon to align this Mac's agent config with the two
    /// Integration switches.
    ///
    /// Both switches go in one message: the daemon writes hooks and the skill in
    /// one pass, and sending two would install twice for no reason. Fire and
    /// forget — this runs on launch, on a preference change, and on refocus, and
    /// none of those has a place to show a failure, so a failure is logged (by
    /// `AgentIntegrationInstaller`) and the previous state is left alone. The
    /// place that *does* report is Settings, where the user asked.
    func syncAgentIntegration() {
        let hooks: Termiod.AgentHalfAction =
            settings.agentHooksEnabled ? .install : .remove
        let skills: Termiod.AgentHalfAction =
            settings.sessionControlEnabled ? .install : .remove
        Task { _ = await AgentIntegrationInstaller.sync(hooks: hooks, skills: skills) }
    }

    /// Records only the first usable prompt label in a conversation. It stays a
    /// fallback: `displayTitle` gives an explicit Termio name and a meaningful native
    /// OSC title higher priority. Persisting it on `Session` keeps resumed tabs named
    /// before the agent emits any fresh terminal title.
    func recordPromptTitle(_ raw: String, for id: Session.ID) {
        guard let session = session(id),
              session.promptTitle == nil,
              session.agent != .terminal,
              session.givenTitle == nil,
              let title = AgentPromptTitle.normalized(raw)
        else { return }
        updateSession(id) { $0.promptTitle = title }
    }

    /// A reported conversation id, accepted only when it is a bare token — the ids
    /// every agent mints (UUIDs, `ses_…`) always are. The shell-hook path mines the
    /// value out of an arbitrary stdin blob, so anything else (pasted JSON, a path,
    /// whitespace) is treated as no identity rather than adopted into the pin.
    func conversationToken(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 128,
              raw.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
        else { return nil }
        return raw
    }

    /// Not private: the termiod status path (`applyTermiodStatus`) ends a turn
    /// through the same door, so the two cannot drift on what "stopped working"
    /// clears.
    func clearWorking(_ id: Session.ID) {
        setCurrentTool(nil, for: id)
        lastWorkingAt[id] = nil
    }

    /// Drops every per-session activity-tracking entry — the one place that
    /// enumerates these dictionaries, so the teardown paths (close, project
    /// removal, relaunch) can't drift out of step when a new tracker is added.
    /// `transcriptPaths` is deliberately not here: a relaunch resumes the same
    /// conversation, so only the close/remove paths clear it (inline).
    func clearActivityTracking(for id: Session.ID) {
        // Whatever banner the session had delivered no longer describes a live turn.
        TaskNotificationCenter.shared.forget(id)
        lastWorkingAt[id] = nil
        lastHookReportAt[id] = nil
        agentExitStreaks[id] = nil
        blockingAttention.remove(id)
    }

    /// Light the "blocked on you" dot from a genuine, observable blocking condition
    /// (a hook / screen / title "attention" signal). Unlike a one-shot bell, these
    /// have a matching "resolved" transition, so the dot is recorded as blocking
    /// (`blockingAttention`) and survives a click in `markSeen` — looking at a
    /// permission prompt isn't answering it. Only flags a session the user isn't
    /// already watching, mirroring the raw `!isViewing` guard it replaces; the flag
    /// is still set even when the status write is a no-op, so a bell-set dot already
    /// showing gets *upgraded* to blocking when the real signal arrives.
    func flagBlockingAttention(for id: Session.ID) {
        guard !isViewing(id) else { return }
        blockingAttention.insert(id)
        setStatus(.needsAttention, for: id)
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
        guard let home = locate(id) else { return }
        var session = self[home]
        guard !session.isSSH else { return }
        if let detected {
            // Promote a plain terminal only: an already-promoted row seeing its own
            // agent is the idempotent no-op, and a *different* foreground under a
            // promoted row is the agent's own subprocess, not a new identity.
            guard session.agent == .terminal, detected != .terminal else { return }
            // Adopt the declared-session title convention (`addSession`) so the row
            // reads `Claude Code`. Unconditional: a name the user chose lives in
            // `givenTitle` and outranks this at display time, so there is nothing
            // here to protect it from.
            session.title = detected.displayName
            session.agent = detected
            self[home] = session
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
        guard let home = locate(id) else { return }
        var session = self[home]
        guard session.agent != .terminal else { return }
        // Back to the auto `Terminal N` convention (numbered like `addSession`,
        // counting this row itself), so display naming — cwd basename for loose
        // terminals — takes over again. A name the user chose is untouched by this:
        // it lives in `givenTitle` and still outranks the placeholder.
        let terminalCount = roster(at: home).filter { $0.agent == .terminal }.count
        session.title = "Terminal \(terminalCount + 1)"
        session.agent = .terminal
        session.liveTitle = nil
        session.promptTitle = nil
        self[home] = session
        setLiveTitle(nil, for: id)
        // The row is a terminal now; an "agent exited" notice would describe an
        // identity it no longer has.
        runtimes[id]?.agentExitNotice = nil
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
