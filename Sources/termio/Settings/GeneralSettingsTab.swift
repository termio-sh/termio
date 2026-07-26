import SwiftUI

/// App-level settings that aren't about a specific surface. Today that's the `termio`
/// command-line tool — an app integration (install the binary to your PATH), not an
/// agent feature, so it lives here rather than in the Agents tab.
struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                CommandLineToolRow()
            } header: {
                SectionHeaderLabel(title: "Command line")
            }
        }
        .formStyle(.grouped)
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
