import AppKit
import SwiftUI
import TermioShared
import UserNotifications

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

    private override init() { super.init() }

    /// Wires the notifier up at launch. The delegate must be in place before
    /// any notification is clicked — including one whose click launches the app.
    func activate(store: TermioStore) {
        self.store = store
        guard Self.isSupported else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// A session's status settled on a "your turn" state. Called from the status
    /// choke point (`TermioStore.setStatus`) on genuine transitions only, which
    /// is what keeps one completion to one notification.
    func sessionDidSettle(_ id: Session.ID, status: SessionStatus) {
        guard Self.isSupported, let store, store.settings.notifyOnTaskCompletion else { return }
        guard let session = store.session(id) else { return }
        let agent = store.effectiveAgent(for: session)
        // Only real agent turns notify; a plain terminal's bell/OSC noise doesn't.
        guard agent != .terminal else { return }
        // The user is already looking at this session — the banner would only
        // echo the sidebar dot already in front of them.
        if NSApp.isActive,
           store.selectedSessionID == id || store.splitRoot?.contains(id) == true {
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
        // The banner's leading icon is always termio's own (macOS reserves it for
        // the posting app), so the agent's identity rides as the trailing
        // thumbnail instead — which agent finished, at a glance.
        if let attachment = agentIconAttachment(for: agent) {
            content.attachments = [attachment]
        }

        // One identifier per session: a follow-up settle *replaces* the delivered
        // banner rather than stacking, so a session never shows two at once.
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: id), content: content, trigger: nil)

        let center = UNUserNotificationCenter.current()
        // Idempotent after the user's first answer; asking here rather than at
        // launch means the prompt appears the moment it's explainable.
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            center.add(request)
        }
        delivered.insert(id)
    }

    /// Withdraws a session's delivered notification: the user engaged with the
    /// session another way (clicked its row, closed it), so the banner is stale.
    func withdraw(for id: Session.ID) {
        guard Self.isSupported, delivered.remove(id) != nil else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.identifier(for: id)])
    }

    /// Quit takes the sessions with it, so any banners left behind would point
    /// at nothing.
    func withdrawAll() {
        guard Self.isSupported else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    private static let sessionKey = "sessionID"

    private static func identifier(for id: Session.ID) -> String {
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
    /// Show the banner even while termio is frontmost — the send path already
    /// suppressed the session the user is looking at, so a banner that reaches
    /// here is always about some *other* session.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
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
            if let id {
                self.delivered.remove(id)
                self.store?.revealSession(id)
            }
            completionHandler()
        }
    }
}
