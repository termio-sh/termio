import SwiftUI
import UserNotifications

/// App-level settings that aren't about a specific surface: the `termio`
/// command-line tool (an app integration, not an agent feature, so it lives here
/// rather than in the Agents tab) and task-completion notifications.
struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.notifyOnTaskCompletion) {
                    SettingsLabel(
                        .huge(.checkCircle),
                        title: "Task completion",
                        subtext: "Posts a macOS notification when an agent finishes a task — or stops to ask you something — while termio is in the background. Quick replies and answer-only turns that ran no tools stay quiet; a blocked agent always notifies. Click the notification to jump to that session. macOS asks for permission the first time."
                    )
                }
                .toggleStyle(.switch)
                if settings.notifyOnTaskCompletion {
                    Toggle("Play sound", isOn: $settings.notificationSoundEnabled)
                    NotificationPermissionRow()
                }
            } header: {
                SectionHeaderLabel(title: "Notifications")
            }
            Section {
                CommandLineToolRow()
            } header: {
                SectionHeaderLabel(title: "Command line")
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
                    Text("macOS hasn't been asked to allow termio's notifications yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Request Permission") {
                        Task {
                            _ = await TaskNotificationCenter.requestPermission()
                            status = await TaskNotificationCenter.authorizationStatus()
                        }
                    }
                }
            case .denied:
                HStack(spacing: 10) {
                    Text("Notifications for termio are turned off in System Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open System Settings") {
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

/// Installs and reports the `termio` command-line tool. It audits on appear so the
/// row always reflects reality (a moved app shows "Update"), and re-audits after
/// the install action so the button and caption update in place.
private struct CommandLineToolRow: View {
    @State private var status: CommandLineTool.Status = .notInstalled

    var body: some View {
        HStack(spacing: 10) {
            SettingsLabel(.huge(.terminal), title: "Command-line tool", subtext: description)
            Spacer()
            if let title = buttonTitle {
                Button(title) { status = CommandLineTool.install() }
            }
        }
        .onAppear { status = CommandLineTool.audit() }
    }

    private var description: String {
        let tool = CommandLineTool.toolName
        switch status {
        case .installed:
            return "`\(tool)` is on your PATH. Run `\(tool) sessions …` to drive sibling sessions, or `\(tool) .` to open a folder."
        case .stale(let path):
            return "An older install points at \(path). Update it to this version of termio."
        case .notInstalled:
            return "Install `\(tool)` so you (and agents) can run `\(tool) sessions …` from any shell. Links to /usr/local/bin."
        case .conflict:
            return "A different `\(tool)` already exists at \(CommandLineTool.installURL.path). Remove it first — termio won't overwrite a file it didn't create."
        case .unavailable:
            return "Available when termio runs from the built app bundle."
        }
    }

    private var buttonTitle: String? {
        switch status {
        case .installed: return "Reinstall"
        case .stale: return "Update"
        case .notInstalled: return "Install"
        case .conflict, .unavailable: return nil
        }
    }
}
