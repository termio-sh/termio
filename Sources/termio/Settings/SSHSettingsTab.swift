import AppKit
import SwiftUI

/// Settings ▸ SSH: the connectable hosts from `~/.ssh/config`, each one click
/// away from a terminal. The config file stays the single source of truth —
/// termio reads the same hosts `ssh` itself resolves and writes nothing behind
/// the user's back: Add Host appends a plain block, Edit opens the raw file.
struct SSHSettingsTab: View {
    @ObservedObject var settings: AppSettings
    /// Opens an SSH terminal to the alias in the main window (wired to
    /// `TermioStore.addSSHSession` by the app delegate).
    let onConnect: (String) -> Void

    @State private var hosts: [SSHConfigHost] = []
    @State private var publicKeys: [SSHPublicKey] = []
    @State private var addingHost = false
    @State private var configEditor: ConfigEditorTarget?
    /// The key whose Copy button is briefly confirming, so the click visibly took.
    @State private var copiedKeyID: String?

    /// Which file the editor sheet shows — usually `~/.ssh/config`, but a host
    /// defined in an `Include`d file opens that file, at its `Host` line.
    private struct ConfigEditorTarget: Identifiable {
        let url: URL
        let line: Int?
        var id: String { "\(url.path)#\(line ?? 0)" }
    }

    var body: some View {
        Form {
            hostsSection
            configSection
            if !publicKeys.isEmpty { keysSection }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .sheet(isPresented: $addingHost, onDismiss: reload) {
            AddSSHHostSheet(existingAliases: Set(hosts.map(\.alias)))
        }
        .sheet(item: $configEditor, onDismiss: reload) { target in
            FileEditorView(
                url: target.url,
                settings: settings,
                jumpLine: target.line,
                onClose: { configEditor = nil }
            )
            .frame(minWidth: 640, minHeight: 460)
            // FileEditorView delegates its close to an external toolbar that only
            // exists over the terminal pane — in a sheet there's none, so supply
            // one. Escape closes too; the visible button is the guaranteed way out.
            .overlay(alignment: .topTrailing) {
                Button { configEditor = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
                .padding(8)
            }
        }
    }

    private var hostsSection: some View {
        Section {
            if hosts.isEmpty {
                Text("No hosts yet — add one, or write a Host block in ~/.ssh/config.")
                    .foregroundStyle(.secondary)
            }
            ForEach(hosts) { host in
                SSHHostRow(
                    host: host,
                    connect: { onConnect(host.alias) },
                    editInConfig: { presentEditor(for: host) }
                )
            }
            Button { addingHost = true } label: {
                Label("Add Host", systemImage: "plus")
            }
        } header: {
            SectionHeaderLabel(title: "Hosts")
        } footer: {
            Text("The Host blocks from ~/.ssh/config (Include'd files too) — exactly the aliases `ssh` resolves. Test Connection probes reachability and auth without opening a session; right-click a host to Connect it as a terminal in the sidebar, same as File ▸ New SSH Connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var configSection: some View {
        Section {
            LabeledContent {
                Button("Edit") { presentEditor(for: nil) }
            } label: {
                SettingsLabel(
                    .huge(.fileDoc),
                    title: "~/.ssh/config",
                    subtext: "The OpenSSH client config is the single source of truth — termio keeps no separate host database. Edits show up here and in plain `ssh` alike."
                )
            }
        } header: {
            SectionHeaderLabel(title: "Config file")
        }
    }

    private var keysSection: some View {
        Section {
            ForEach(publicKeys) { key in
                HStack(spacing: 10) {
                    IconBadge(.huge(.key))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.name)
                        Text(key.comment.isEmpty ? key.algorithm : "\(key.algorithm) · \(key.comment)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(copiedKeyID == key.id ? "Copied" : "Copy") { copy(key) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        } header: {
            SectionHeaderLabel(title: "Public keys")
        } footer: {
            Text("The public keys in ~/.ssh. Copy one to paste into a server's authorized_keys — private keys are never read.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Opens the editor sheet on a host's defining file at its `Host` line, or on
    /// `~/.ssh/config` itself. The config is created empty first when missing so
    /// the editor never opens onto a nonexistent file.
    private func presentEditor(for host: SSHConfigHost?) {
        // Symlinks resolve before the editor opens: its atomic auto-save would
        // otherwise replace a dotfile-managed link with a plain file.
        if let host {
            configEditor = ConfigEditorTarget(url: host.file.resolvingSymlinksInPath(), line: host.line)
        } else {
            try? SSHConfigFile.ensureConfigExists()
            configEditor = ConfigEditorTarget(url: SSHConfigFile.writableConfigURL, line: nil)
        }
    }

    private func reload() {
        hosts = SSHConfigFile.hosts()
        publicKeys = SSHConfigFile.publicKeys()
    }

    private func copy(_ key: SSHPublicKey) {
        guard let text = try? String(contentsOf: key.url, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            text.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string
        )
        copiedKeyID = key.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedKeyID == key.id { copiedKeyID = nil }
        }
    }
}

/// One host row: alias over its `user@host` destination (with the pinned key's
/// filename when the block sets one), and a Test Connection probe. Live
/// connecting is a launch, not a setting — it lives in the context menu (and
/// the sidebar / File menu), keeping this pane about configuring and verifying
/// hosts.
private struct SSHHostRow: View {
    let host: SSHConfigHost
    let connect: () -> Void
    let editInConfig: () -> Void

    private enum ProbeState { case idle, running, result(SSHProbeResult) }
    @State private var probe: ProbeState = .idle

    /// `user@host`, plus the identity file's name when the block pins one — the
    /// full path stays in the tooltip.
    private var subtitle: String {
        guard let identityFile = host.identityFile else { return host.destinationLabel }
        let keyName = (identityFile as NSString).lastPathComponent
        return "\(host.destinationLabel) · \(keyName)"
    }

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(.huge(.serverStack))
            VStack(alignment: .leading, spacing: 2) {
                Text(host.alias).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(host.identityFile.map { "Uses \($0)" } ?? "")
            }
            Spacer(minLength: 8)
            probeControl
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Connect", action: connect)
            Button("Test Connection", action: runProbe)
            Button("Edit in Config", action: editInConfig)
            Button("Copy ssh Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("ssh \(host.alias)", forType: .string)
            }
        }
    }

    /// The trailing control: a Test button that turns into a spinner while the
    /// probe runs, then a tinted result badge that re-tests on click.
    @ViewBuilder
    private var probeControl: some View {
        switch probe {
        case .idle:
            Button("Test", action: runProbe)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .running:
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 44)
        case .result(let outcome):
            Button(action: runProbe) {
                Text(outcome.label)
                    .foregroundStyle(outcome.tint)
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("\(outcome.detail) — click to re-test")
        }
    }

    /// Runs the non-interactive probe off the main thread, hopping back to update
    /// the badge. A fresh click just re-arms it.
    private func runProbe() {
        probe = .running
        Task { @MainActor in
            probe = .result(await SSHConfigFile.testConnection(alias: host.alias))
        }
    }
}

/// How each probe outcome reads in the row: a short tinted label — the wording
/// itself distinguishes outcomes, so color is reinforcement, not the only
/// signal — with the raw ssh detail in the tooltip.
private extension SSHProbeResult {
    var label: String {
        switch self {
        case .reachable: return "Reachable"
        case .authFailed: return "Auth failed"
        case .unreachable(let reason): return reason
        }
    }

    var tint: Color {
        switch self {
        case .reachable: return .green
        case .authFailed: return .orange
        case .unreachable: return .red
        }
    }

    var detail: String {
        switch self {
        case .reachable: return "Connected and authenticated"
        case .authFailed(let message), .unreachable(let message): return message
        }
    }
}

/// The Add Host sheet: the four fields a `Host` block actually needs, appended
/// to `~/.ssh/config` as a block indistinguishable from a hand-written one.
private struct AddSSHHostSheet: View {
    let existingAliases: Set<String>
    @Environment(\.dismiss) private var dismiss

    @State private var alias = ""
    @State private var hostName = ""
    @State private var user = ""
    @State private var port = ""
    @State private var identityFile = ""
    @State private var writeError: String?

    private var trimmedAlias: String { alias.trimmingCharacters(in: .whitespaces) }
    private var aliasTaken: Bool { existingAliases.contains(trimmedAlias) }
    private var canAdd: Bool {
        !trimmedAlias.isEmpty && !trimmedAlias.contains(" ")
            && !hostName.trimmingCharacters(in: .whitespaces).isEmpty
            && !aliasTaken
            && (port.isEmpty || Int(port).map { (1...65535).contains($0) } == true)
            // ssh_config has no escape for a literal double quote — such values
            // can't be written faithfully, so refuse rather than corrupt.
            && ![alias, hostName, user, identityFile].contains(where: { $0.contains("\"") })
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Alias", text: $alias, prompt: Text("myserver"))
                    TextField("Host", text: $hostName, prompt: Text("server.example.com"))
                    TextField("User", text: $user, prompt: Text("optional"))
                    TextField("Port", text: $port, prompt: Text("22"))
                    LabeledContent("Key file") {
                        HStack(spacing: 6) {
                            TextField(
                                "", text: $identityFile,
                                prompt: Text("optional — ~/.ssh/id_ed25519")
                            )
                            .labelsHidden()
                            Button("Choose…", action: chooseIdentityFile)
                        }
                    }
                } header: {
                    SectionHeaderLabel(title: "Add SSH Host")
                } footer: {
                    if aliasTaken {
                        Text("“\(trimmedAlias)” is already in your config.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Appends a Host block to ~/.ssh/config, so the alias works in plain `ssh \(trimmedAlias.isEmpty ? "myserver" : trimmedAlias)` too.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let writeError {
                    Text(writeError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding(12)
        }
        .frame(width: 440, height: 330)
    }

    private func add() {
        do {
            try SSHConfigFile.appendHost(
                alias: trimmedAlias,
                hostName: hostName.trimmingCharacters(in: .whitespaces),
                user: user.trimmingCharacters(in: .whitespaces),
                port: port.trimmingCharacters(in: .whitespaces),
                identityFile: identityFile.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch {
            writeError = "Couldn't write ~/.ssh/config: \(error.localizedDescription)"
        }
    }

    /// A file picker starting in `~/.ssh` with hidden files visible (the whole
    /// directory is dot-hidden). The chosen path is stored `~`-relative, the way
    /// ssh configs are conventionally written.
    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = SSHConfigFile.configURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        identityFile = path.hasPrefix(home + "/")
            ? "~" + path.dropFirst(home.count)
            : path
    }
}
