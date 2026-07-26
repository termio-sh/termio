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
@MainActor
final class TaskNotificationCenter: NSObject {
    static let shared = TaskNotificationCenter()

    /// Set at launch by `activate(store:)`; weak because the store owns the
    /// app's object graph, not the notifier.
    private weak var store: TermioStore?

    /// `UNUserNotificationCenter.current()` aborts ("bundleProxyForCurrentProcess
    /// is nil") outside a real app bundle, so every entry point bails in a bare
    /// `swift run` executable or the test runner.
    private static let isSupported = Bundle.main.bundleIdentifier != nil

    /// Sessions with a notification delivered this run, so engaging with a
    /// session withdraws its stale banner from Notification Center.
    private var delivered: Set<Session.ID> = []

    /// Per-session generation counters that invalidate in-flight posts: the
    /// authorization/settings round-trip is async, so a user who engages with
    /// the session (or closes it) in that window must win over the pending
    /// `add`. `withdraw` bumps the counter; the post re-checks it on the main
    /// actor just before scheduling.
    private var generations: [Session.ID: Int] = [:]

    private override init() { super.init() }

    /// Wires the notifier up at launch. The delegate must be in place before
    /// any notification is clicked — including one whose click launches the app.
    func activate(store: TermioStore) {
        self.store = store
        guard Self.isSupported else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// A turn shorter than this settles without a notification: a quick
    /// conversational reply means the user is still in the loop, and banner-ing
    /// every exchange while they glance at a browser is spam (Ghostty's
    /// `notify-on-command-finish-after` idea, tuned for agent turns). A blocked
    /// agent is exempt — it stalls all progress no matter how fast it got there.
    private static let minimumTurnDuration: TimeInterval = 10

    /// When each session's current turn entered `.working`, for the
    /// minimum-duration gate. Absent (a settle with no observed start) counts
    /// as long: better a surplus banner than a silent finished agent.
    private var workingSince: [Session.ID: Date] = [:]

    /// A session's turn began. Called from the status choke point on the
    /// genuine transition into `.working`.
    func sessionDidStartWorking(_ id: Session.ID) {
        workingSince[id] = Date()
    }

    /// A session's status settled on a "your turn" state. Called from the status
    /// choke point (`TermioStore.setStatus`) on genuine transitions only, which
    /// is what keeps one completion to one notification.
    func sessionDidSettle(_ id: Session.ID, status: SessionStatus) {
        let turnDuration = workingSince.removeValue(forKey: id)
            .map { Date().timeIntervalSince($0) }
        guard Self.isSupported, let store, store.settings.notifyOnTaskCompletion else { return }
        guard let session = store.session(id) else { return }
        let agent = store.effectiveAgent(for: session)
        // Only real agent turns notify; a plain terminal's bell/OSC noise doesn't.
        guard agent != .terminal else { return }
        // The notification's one job is "you stepped away, come back" — the
        // policy Cursor and Codex both ship (`unfocused`-only). While termio is
        // frontmost, the sidebar dot and menu-bar pulse are the completion
        // channel; a banner would duplicate them in a louder one.
        guard !NSApp.isActive else { return }
        // A quick reply isn't worth an interruption; a blocked agent always is.
        if status == .done, let turnDuration, turnDuration < Self.minimumTurnDuration {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = status == .needsAttention
            ? "\(agent.displayName) needs your input"
            : "\(agent.displayName) finished"
        if let project = store.project(for: id) { content.subtitle = project.name }
        content.body = store.displayTitle(for: session)
        if store.settings.notificationSoundEnabled { content.sound = .default }
        content.userInfo = [Self.sessionKey: id.uuidString]

        let generation = generations[id, default: 0]
        let center = UNUserNotificationCenter.current()
        // Idempotent after the user's first answer; asking here rather than at
        // launch means the prompt appears the moment it's explainable.
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            DispatchQueue.main.async {
                // Re-validate on the main actor: the user may have engaged with
                // the session (`withdraw` bumps the generation) or switched the
                // setting off while the authorization round-trip was in flight.
                guard self.generations[id, default: 0] == generation,
                      self.store?.settings.notifyOnTaskCompletion == true else { return }
                // The banner's leading icon is always termio's own (macOS
                // reserves it for the posting app), so the agent's identity
                // rides as the trailing thumbnail instead. Created only now,
                // when the request is certain to be scheduled — the system
                // *moves* the attached file, so a copy made before any of the
                // bail-outs above would be orphaned in the temp directory.
                if let attachment = self.agentIconAttachment(for: agent) {
                    content.attachments = [attachment]
                }
                // One identifier per session: a follow-up settle *replaces* the
                // delivered banner rather than stacking, so a session never
                // shows two at once.
                center.add(UNNotificationRequest(
                    identifier: Self.identifier(for: id), content: content, trigger: nil))
                self.delivered.insert(id)
            }
        }
    }

    /// Withdraws a session's notification: the user engaged with the session
    /// another way (clicked its row, closed it), so the banner is stale. Always
    /// bumps the generation so a post still in its authorization round-trip is
    /// invalidated too, and clears the pending queue alongside the delivered one
    /// (they are separate stores).
    func withdraw(for id: Session.ID) {
        guard Self.isSupported else { return }
        generations[id, default: 0] += 1
        guard delivered.remove(id) != nil else { return }
        let identifier = Self.identifier(for: id)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Full per-session reset for the teardown paths (close, relaunch): the
    /// banner goes, and so does the turn clock — whatever turn was running no
    /// longer exists.
    func forget(_ id: Session.ID) {
        workingSince[id] = nil
        withdraw(for: id)
    }

    /// Quit takes the sessions with it, so any banners left behind would point
    /// at nothing.
    func withdrawAll() {
        guard Self.isSupported else { return }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    nonisolated private static let sessionKey = "sessionID"

    nonisolated private static func identifier(for id: Session.ID) -> String {
        "task-settled.\(id.uuidString)"
    }

    // MARK: Agent icon attachment

    /// Rendered agent-icon PNGs by agent id, so each agent's mark is rasterized
    /// once per run rather than per notification.
    private var renderedIcons: [String: URL] = [:]

    /// The agent's brand mark as a notification attachment. The system *moves*
    /// an attached file into its own store, so the cached render is handed over
    /// as a throwaway copy.
    private func agentIconAttachment(for agent: AgentPreset) -> UNNotificationAttachment? {
        guard let master = renderedIcon(for: agent) else { return nil }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("termio-notification-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: master, to: copy)
            return try UNNotificationAttachment(identifier: "agent-icon", url: copy)
        } catch {
            try? FileManager.default.removeItem(at: copy)
            return nil
        }
    }

    /// Rasterizes the sidebar's own `AgentIconView` onto a white rounded tile —
    /// pinned to light mode so the monochrome marks (Codex, Grok) resolve to
    /// black ink that stays legible on a dark-appearance banner too.
    private func renderedIcon(for agent: AgentPreset) -> URL? {
        if let cached = renderedIcons[agent.id],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let side: CGFloat = 96
        let renderer = ImageRenderer(
            content: AgentIconView(agent: agent, size: side * 0.58)
                .frame(width: side, height: side)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
                .environment(\.colorScheme, .light)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        let slug = agent.id.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("termio-agent-icon-\(String(slug)).png")
        do { try png.write(to: url) } catch { return nil }
        renderedIcons[agent.id] = url
        return url
    }
}

extension TaskNotificationCenter: UNUserNotificationCenterDelegate {
    /// `willPresent` only fires while termio is frontmost — which under the
    /// background-only policy means the user came back between the post and its
    /// presentation. Attention has returned, so the in-app signals own it again
    /// and the banner is suppressed (it stays in Notification Center until the
    /// session's `withdraw`).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    /// A click focuses the originating session — same verb as `termio sessions focus`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let id = (userInfo[Self.sessionKey] as? String).flatMap(UUID.init)
        DispatchQueue.main.async {
            if let id { self.store?.revealSession(id) }
            completionHandler()
        }
    }
}
