import SwiftUI
import UserNotifications

/// App-level settings that aren't about a specific surface: the `termio`
/// command-line tool, the machine-wide agent integrations (the session-control
/// skill, status hooks), and task-completion notifications. The first three
/// install termio's wiring outside the app — PATH, agent configs, instruction
/// files — rather than configure a particular agent, so they live here rather
/// than in the Agents tab.
struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LanguageRow()
            } header: {
                SectionHeaderLabel(title: localized("Language"))
            }
            Section {
                CommandLineToolRow()
            } header: {
                SectionHeaderLabel(title: localized("Command line"))
            }
            Section {
                Toggle(isOn: $settings.sessionControlEnabled) {
                    SettingsLabel(
                        .huge(.gitBranch),
                        title: localized("Session control"),
                        subtext: localized("Lets an agent see and drive its sibling sessions in this project via the `termio sessions` command. Installs the termio skill into each agent's skills folder.")
                    )
                }
                .toggleStyle(.switch)
                if settings.sessionControlEnabled {
                    InstallButtonRow(title: localized("Reinstall skill")) {
                        .summarizing(SessionSkillInstaller.sync(enabled: true),
                                     headline: localized("Skill reinstalled"), unit: localized("agents"))
                    }
                }
            } header: {
                SectionHeaderLabel(title: localized("Agent skill"))
            }
            Section {
                Toggle(isOn: $settings.agentHooksEnabled) {
                    SettingsLabel(
                        .huge(.wireless),
                        title: localized("Live agent status"),
                        subtext: localized("Shows when an agent is working or waiting on you — the sidebar spinner and menu-bar pulse. Installs Termio’s hooks into each agent’s config.")
                    )
                }
                .toggleStyle(.switch)
                if settings.agentHooksEnabled {
                    // For re-applying after the user (or another tool) has edited
                    // ~/.claude/settings.json; install is idempotent.
                    InstallButtonRow(title: localized("Reinstall hooks")) {
                        .summarizing(AgentStatusHooks.sync(enabled: true),
                                     headline: localized("Hooks reinstalled"), unit: localized("agents"))
                    }
                }
            } header: {
                SectionHeaderLabel(title: localized("Status"))
            }
            Section {
                Toggle(isOn: $settings.notifyOnTaskCompletion) {
                    SettingsLabel(
                        .huge(.checkCircle),
                        title: localized("Task completion"),
                        subtext: localized("Posts a notification when an agent finishes or needs you while Termio is in the background.")
                    )
                }
                .toggleStyle(.switch)
                if settings.notifyOnTaskCompletion {
                    Toggle(localized("Play sound"), isOn: $settings.notificationSoundEnabled)
                    NotificationPermissionRow()
                }
            } header: {
                SectionHeaderLabel(title: localized("Notifications"))
            }
            Section {
                Toggle(isOn: $settings.githubIntegrationEnabled) {
                    SettingsLabel(
                        .huge(.github),
                        title: localized("GitHub"),
                        subtext: localized("Shows the Issues pane in the inspector for projects whose remote is on GitHub.")
                    )
                }
                .toggleStyle(.switch)
            } header: {
                SectionHeaderLabel(title: localized("Integrations"))
            }
        }
        .formStyle(.grouped)
    }
}

/// Surfaces the macOS-side notification authorization under the toggle. An app
/// cannot grant itself notification permission — only the system prompt or
/// System Settings can — so this row offers whichever of the two applies:
/// "Request Permission" while macOS has never been asked, a System Settings
/// deep link once the user has denied. Silent when already authorized (or when
/// running unbundled, where the framework is untouchable). Re-audits whenever
/// the app comes back to front, so returning from System Settings updates it.
private struct NotificationPermissionRow: View {
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        Group {
            switch status {
            case .notDetermined:
                HStack(spacing: 10) {
                    Text(localized("macOS hasn’t been asked to allow Termio’s notifications yet."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(localized("Request Permission")) {
                        Task {
                            _ = await TaskNotificationCenter.requestPermission()
                            status = await TaskNotificationCenter.authorizationStatus()
                        }
                    }
                }
            case .denied:
                HStack(spacing: 10) {
                    Text(localized("Notifications for Termio are turned off in System Settings."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(localized("Open System Settings")) {
                        let id = Bundle.main.bundleIdentifier ?? ""
                        if let url = URL(string:
                            "x-apple.systempreferences:com.apple.preference.notifications?id=\(id)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            default:
                EmptyView()
            }
        }
        .task { status = await TaskNotificationCenter.authorizationStatus() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { status = await TaskNotificationCenter.authorizationStatus() }
        }
    }
}

/// Installs and reports the `termio` command-line tool, as a switch like the other
/// feature rows: on means the PATH symlink exists, off removes it. The switch is
/// bound to the audit, not a stored preference, so it always reflects reality (a
/// declined admin prompt snaps it back). It audits on appear (a moved app shows
/// "Update") and re-audits after every action so the caption updates in place.
private struct CommandLineToolRow: View {
    @State private var status: CommandLineTool.Status = .notInstalled
    @State private var state = InstallFeedbackState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { isOn }, set: { setEnabled($0) })) {
                SettingsLabel(.huge(.terminal), title: localized("Command-line tool"), subtext: description)
            }
            .toggleStyle(.switch)
            .disabled(!isSwitchable)
            if let feedback = state.feedback {
                // Aligned under the caption, past the row's icon badge.
                InstallFeedbackLabel(feedback: feedback)
                    .padding(.leading, 32)
            }
        }
        .onAppear { status = CommandLineTool.audit() }
        .autoDismissing($state)
        if isOn {
            // For re-linking after something else has touched /usr/local/bin;
            // install is idempotent. Reports through its own feedback line.
            InstallButtonRow(title: buttonTitle) { withAnimation { runInstall() } }
        }
    }

    private var isOn: Bool {
        switch status {
        case .installed, .stale: return true
        case .notInstalled, .conflict, .unavailable: return false
        }
    }

    /// A conflicting file isn't ours to remove and a bare binary has nothing to
    /// link, so in both states the switch is disabled and the caption explains.
    private var isSwitchable: Bool {
        switch status {
        case .installed, .stale, .notInstalled: return true
        case .conflict, .unavailable: return false
        }
    }

    private func setEnabled(_ enabled: Bool) {
        withAnimation {
            if enabled {
                state.show(runInstall())
            } else {
                status = CommandLineTool.uninstall()
                state.show(isOn
                    ? .failure(localized("Couldn’t remove \(CommandLineTool.installURL.path)."))
                    : .success(localized("Removed from PATH.")))
            }
        }
    }

    /// Installs, then reports the fresh audit. The caption alone can't carry this:
    /// a declined admin prompt leaves the row reading exactly as it did before the
    /// click, so success and cancellation would be indistinguishable. The
    /// confirmation stays short — the caption above it already names the path — and
    /// echoes the verb that was offered: an "Update" that lands says "Updated."
    private func runInstall() -> InstallFeedback {
        let wasStale: Bool
        if case .stale = status { wasStale = true } else { wasStale = false }
        let result = CommandLineTool.install()
        status = result
        switch result {
        case .installed:
            return .success(wasStale ? localized("Updated.") : localized("Installed."))
        case .conflict:
            return .failure(localized("Something else already owns \(CommandLineTool.installURL.path)."))
        case .unavailable:
            return .failure(localized("No bundled tool to install from."))
        case .notInstalled, .stale:
            let directory = CommandLineTool.installURL.deletingLastPathComponent().path
            return .failure(localized("Couldn’t link `\(CommandLineTool.toolName)` into \(directory)."))
        }
    }

    private var description: String {
        let tool = CommandLineTool.toolName
        switch status {
        case .installed:
            return localized("`\(tool)` is on your PATH. Run `\(tool) sessions …` to drive sibling sessions, or `\(tool) .` to open a folder.")
        case .stale(let path):
            return localized("An older install points at \(path). Update it to this version of Termio.")
        case .notInstalled:
            return localized("Links `\(tool)` into /usr/local/bin so you (and agents) can run `\(tool) sessions …` from any shell.")
        case .conflict:
            return localized("A different `\(tool)` already exists at \(CommandLineTool.installURL.path). Remove it first — Termio won’t overwrite a file it didn’t create.")
        case .unavailable:
            return localized("Available when Termio runs from the built app bundle.")
        }
    }

    private var buttonTitle: String {
        if case .stale = status { return localized("Update") }
        return localized("Reinstall")
    }
}
