import AppKit
import SwiftUI
import TermioShared
@preconcurrency import UserNotifications

/// Posts a native macOS notification when an agent turn settles — finished
/// (`.done`) or blocked on the user (`.needsAttention`) — so the user can work
/// elsewhere and come back when the agent is ready. Modeled on Ghostty's
/// desktop-notification handling: authorization is requested lazily at the
/// first notification (so the permission prompt lands in context), the session
/// id rides in `userInfo` so a click can focus the originating session, and a
/// delivered notification is withdrawn the moment the user engages with its
/// session some other way.
///
/// The policy stack for a finished turn: setting on → real agent → termio in
/// the background → the turn ran ≥ `minimumTurnDuration` → the turn used at
/// least one tool (when the session has tool telemetry). A blocked agent skips
/// the last two gates — blocked stalls all progress no matter how fast it got
/// there.
@MainActor
final class TaskNotificationCenter: NSObject {
    static let shared = TaskNotificationCenter()

    /// Set at launch by `activate(store:)`; weak because the store owns the
    /// app's object graph, not the notifier.
    private weak var store: TermioStore?

    /// Per-session turn and notification bookkeeping, one struct per session so
    /// the lifecycle paths can't half-clear it — `forget` drops the whole entry.
    private struct TurnState {
        /// When the current turn entered `.working`. Absent at settle (no
        /// observed start) counts as long: better a surplus banner than a
        /// silent finished agent.
        var workingSince: Date?
        /// Whether the current turn has run at least one tool — the signal
        /// that it produced work to come back to, not just a streamed answer
        /// the user read as it rendered.
        var sawTool = false
        /// Whether this session has *ever* reported a tool, proving tool
        /// telemetry exists for it (the hook path is the only source — a
        /// screen-promoted agent never reports one). The task-vs-chat gate
        /// applies only then; with no visibility, silence would mean never
        /// notifying, so unknown counts as work.
        var toolCapable = false
        /// Bumped by `withdraw` to invalidate a post whose authorization
        /// round-trip is still in flight when the user engages the session.
        var generation = 0
    }
    private var states: [Session.ID: TurnState] = [:]

    /// A turn shorter than this settles without a notification: a quick
    /// conversational reply means the user is still in the loop, and banner-ing
    /// every exchange while they glance at a browser is spam (Ghostty's
    /// `notify-on-command-finish-after` idea, tuned for agent turns).
    private static let minimumTurnDuration: TimeInterval = 10

    private override init() { super.init() }

    /// Wires the notifier up at launch. The delegate must be in place before
    /// any notification is clicked — including one whose click launches the app.
    func activate(store: TermioStore) {
        self.store = store
        guard AppChannel.isBundledApp else { return }
        UNUserNotificationCenter.current().delegate = self
        // Ask for authorization eagerly, at launch, when the feature is on.
        // The lazy per-settle request (below) only ever fires while termio is
        // *backgrounded* — so a user who watches their agents finish never
        // trips it, the prompt never appears, and no grant is ever recorded
        // (the failure is completely silent). Requesting here guarantees the
        // prompt is offered once. `requestAuthorization` is idempotent: after
        // the first decision it returns the recorded answer without
        // re-prompting, so this is free on every later launch.
        guard store.settings.notifyOnTaskCompletion else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    // An ad-hoc-signed dev build is rejected outright here
                    // (UNErrorDomain 1) — dev builds can NEVER banner; test on
                    // the release build. A user denial just reads granted=false.
                    Log.app.error("notification authorization failed at launch: \(error.localizedDescription, privacy: .public)")
                } else {
                    Log.app.info("notification authorization at launch: granted=\(granted, privacy: .public)")
                }
            }
    }

    /// A session's turn began. Called from the status choke point on the
    /// genuine transition into `.working`.
    func sessionDidStartWorking(_ id: Session.ID) {
        states[id, default: TurnState()].workingSince = Date()
        states[id]?.sawTool = false
    }

    /// The session reported a running tool (via `TermioStore.setCurrentTool`,
    /// the tool observations' choke point).
    func sessionDidUseTool(_ id: Session.ID) {
        states[id, default: TurnState()].sawTool = true
        states[id]?.toolCapable = true
    }

    /// A session's status settled on a "your turn" state. Called from the status
    /// choke point (`TermioStore.setStatus`) on genuine transitions only, which
    /// is what keeps one completion to one notification.
    func sessionDidSettle(_ id: Session.ID, status: SessionStatus) {
        let turn = states[id]
        states[id]?.workingSince = nil
        guard AppChannel.isBundledApp, let store, store.settings.notifyOnTaskCompletion else { return }
        guard let session = store.session(id) else { return }
        let agent = store.effectiveAgent(for: session)
        // Only real agent turns notify; a plain terminal's bell/OSC noise doesn't.
        guard agent != .terminal else { return }
        // The notification's one job is "you stepped away, come back" — the
        // policy Cursor and Codex both ship (`unfocused`-only). While termio is
        // frontmost, the sidebar dot and menu-bar pulse are the completion
        // channel; a banner would duplicate them in a louder one.
        guard !NSApp.isActive else {
            Log.app.debug("notification suppressed for \(id, privacy: .public): termio is frontmost")
            return
        }
        if status == .done {
            // A quick reply isn't worth an interruption; a blocked agent always is.
            if let since = turn?.workingSince,
               Date().timeIntervalSince(since) < Self.minimumTurnDuration {
                Log.app.debug("notification suppressed for \(id, privacy: .public): turn shorter than \(Self.minimumTurnDuration, privacy: .public)s")
                return
            }
            // Task vs chat: a turn that ran no tools produced an answer, not work.
            // Applied only to sessions with proven tool telemetry.
            if let turn, turn.toolCapable, !turn.sawTool {
                Log.app.debug("notification suppressed for \(id, privacy: .public): tool-capable turn ran no tool")
                return
            }
        }

        let content = UNMutableNotificationContent()
        content.title = status == .needsAttention
            ? "\(agent.displayName) needs your input"
            : "\(agent.displayName) finished"
        if let project = store.project(for: id) { content.subtitle = project.name }
        content.body = store.displayTitle(for: session)
        if store.settings.notificationSoundEnabled { content.sound = .default }
        content.userInfo = [Self.sessionKey: id.uuidString]

        // One identifier per session: a follow-up settle *replaces* the delivered
        // banner rather than stacking, so a session never shows two at once.
        let generation = states[id, default: TurnState()].generation
        deliver(content, identifier: Self.identifier(for: id), agent: agent) { [weak self] in
            // Re-validate on the main actor before posting: the user may have
            // engaged with the session (`withdraw` bumps the generation), closed
            // it, or switched the setting off while authorization was in flight.
            guard let self else { return false }
            return self.states[id]?.generation == generation
                && self.store?.session(id) != nil
                && self.store?.settings.notifyOnTaskCompletion == true
        }
    }

    /// Posts a notification on an agent's explicit request (`termio notify`),
    /// bypassing the automatic path's policy gates — the agent asked for it, so it
    /// fires whether or not termio is frontmost. When a calling session is known,
    /// the banner is keyed to it (so a click focuses it and a later automatic
    /// banner replaces rather than stacks) and carries the agent's icon; a
    /// plain-shell caller posts a standalone, unlinked banner. Deliberately not
    /// gated on `notifyOnTaskCompletion`: that switch governs the *automatic*
    /// banners, whereas this is a direct, opt-in call.
    func postManual(title: String, body: String, project: Project?, session: Session?) {
        guard AppChannel.isBundledApp else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let project { content.subtitle = project.name }
        content.body = body
        if store?.settings.notificationSoundEnabled == true { content.sound = .default }
        let agent = session.flatMap { store?.effectiveAgent(for: $0) }
        let identifier: String
        if let session {
            content.userInfo = [Self.sessionKey: session.id.uuidString]
            identifier = Self.identifier(for: session.id)
        } else {
            identifier = "task-manual.\(UUID().uuidString)"
        }
        deliver(content, identifier: identifier, agent: agent)
    }

    /// Shared delivery tail for both the automatic settle banner and the manual
    /// `termio notify` path. Authorization is requested once at launch
    /// (`activate`); here we read the *settled* decision via
    /// `getNotificationSettings` rather than re-prompting each time, and only fall
    /// back to a request when it's still `.notDetermined` (e.g. a settle before
    /// the launch prompt was answered — chaining on that request preserves the
    /// very banner that triggered it). The icon attachment and the caller's
    /// `precondition` re-check run together on the main actor, so the "attachment
    /// is created only when the post is certain" invariant lives in one place —
    /// the system *moves* the attached file, so an earlier copy would be orphaned
    /// by any bail-out.
    private func deliver(_ content: UNMutableNotificationContent,
                         identifier: String,
                         agent: AgentPreset?,
                         precondition: @escaping () -> Bool = { true }) {
        // The whole flow stays on the main actor — content and precondition
        // never cross an isolation boundary; only the awaits on the center do.
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let post = {
                guard precondition() else { return }
                // The banner's leading icon is always termio's own (macOS reserves
                // it for the posting app), so the agent's mark rides as the trailing
                // thumbnail instead.
                if let agent, let attachment = Self.agentIconAttachment(for: agent) {
                    content.attachments = [attachment]
                }
                center.add(UNNotificationRequest(
                    identifier: identifier, content: content, trigger: nil)) { error in
                    if let error {
                        Log.app.error("notification post failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                post()
            case .notDetermined:
                // No decision yet — request now. An ad-hoc-signed dev build is
                // rejected outright here (UNErrorDomain 1: dev builds can never
                // banner — test on a release build); a denial reads granted=false.
                do {
                    if try await center.requestAuthorization(options: [.alert, .sound]) { post() }
                } catch {
                    Log.app.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
                }
            default:
                break  // .denied — the user said no; nothing to post.
            }
        }
    }

    /// Withdraws a session's notification: the user engaged with the session
    /// another way (clicked its row, answered from the phone), so the banner is
    /// stale. The removal is unconditional — identifiers are deterministic, so
    /// this also clears a banner delivered by a previous run that crashed past
    /// `withdrawAll`, and removing an absent identifier is a no-op.
    func withdraw(for id: Session.ID) {
        states[id, default: TurnState()].generation += 1
        guard AppChannel.isBundledApp else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.identifier(for: id)])
    }

    /// Full per-session reset for the teardown paths (close, relaunch): the
    /// banner goes, and so does the turn bookkeeping — whatever turn was running
    /// no longer exists. An in-flight post dies on its session-exists re-check.
    func forget(_ id: Session.ID) {
        withdraw(for: id)
        states.removeValue(forKey: id)
    }

    /// Quit takes the sessions with it, so any banners left behind would point
    /// at nothing.
    func withdrawAll() {
        guard AppChannel.isBundledApp else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// The macOS-side authorization for termio's notifications, for the Settings
    /// row. `nil` outside a bundled app (the framework can't be touched there).
    static func authorizationStatus() async -> UNAuthorizationStatus? {
        guard AppChannel.isBundledApp else { return nil }
        return await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
    }

    /// An explicit permission request from Settings — the same idempotent call
    /// the first notification makes, just user-initiated. Returns whether the
    /// user granted it.
    static func requestPermission() async -> Bool {
        guard AppChannel.isBundledApp else { return false }
        return (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    nonisolated private static let sessionKey = "sessionID"

    nonisolated private static func identifier(for id: Session.ID) -> String {
        "task-settled.\(id.uuidString)"
    }

    /// The agent's brand mark as a notification attachment: the sidebar's own
    /// `AgentIconView` rasterized onto a white rounded tile — pinned to light
    /// mode so the monochrome marks (Codex, Grok) resolve to black ink that
    /// stays legible on a dark-appearance banner too. Rendered fresh per
    /// notification (human-paced, so caching would buy nothing) into a unique
    /// temp file the system then moves into its own store.
    private static func agentIconAttachment(for agent: AgentPreset) -> UNNotificationAttachment? {
        let side: CGFloat = 96
        let renderer = ImageRenderer(
            content: AgentIconView(agent: agent, size: side * 0.58)
                .frame(width: side, height: side)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
                .environment(\.colorScheme, .light)
        )
        renderer.scale = 2
        guard let png = renderer.nsImage?.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("termio-notification-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return try UNNotificationAttachment(identifier: "agent-icon", url: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }
}

extension TaskNotificationCenter: UNUserNotificationCenterDelegate {
    /// `willPresent` only fires while termio is frontmost — which under the
    /// background-only policy means the user came back between the post and its
    /// presentation. Attention has returned, so the banner and sound are
    /// suppressed; `.list` keeps the notification quietly findable in
    /// Notification Center until the session's `withdraw`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.list])
    }

    /// A click focuses the originating session — same verb as `termio sessions focus`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let id = (userInfo[Self.sessionKey] as? String).flatMap(UUID.init)
        // The handler is UN's own continuation — called exactly once, after the
        // main-actor work; the box only carries it across the hop.
        let done = UncheckedSendable(completionHandler)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let id { self.store?.revealSession(id) }
            }
            done.value()
        }
    }
}

/// Carries a non-Sendable value across a hop the compiler cannot check; every
/// use site documents why the crossing is safe.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
