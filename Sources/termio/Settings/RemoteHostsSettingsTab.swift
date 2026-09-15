import AppKit
import SwiftUI

/// Settings ▸ Remote Hosts: one row per machine this Mac reaches, each pushing
/// that machine's pane.
///
/// The pane it pushes is `DevicePane`, the same one Settings ▸ Server renders for
/// this Mac. The split between the two tabs is top-level only, so the five things
/// a machine has — its route, its daemon, what Termio installed on it, its agent
/// CLIs, what it serves — are built once and described once. What the split buys
/// is that neither entrance has to render a section that cannot apply.
///
/// Each row is still *the road and the machine at the end of it* in one pane —
/// the RFC's D2 answer. Two surfaces that both list machines would force the user
/// to learn the route/identity distinction before they could find anything; one
/// pane showing both does not. What is not per-machine stays at this level:
/// `~/.ssh/config` itself and the public keys in `~/.ssh`, which are the user's
/// own credentials rather than facts about any one box.
///
/// A grouped `Form`, like every other pane in this window and like System
/// Settings itself. It was a `List` to keep `onMove` live in case the roster ever
/// became reorderable — a container chosen for a feature that does not exist and
/// cannot: the order here is `~/.ssh/config`'s own, and reordering would mean
/// rewriting the user's file.
struct RemoteHostsSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: TermioStore
    /// Opens an SSH terminal to the alias in the main window (wired to
    /// `TermioStore.addSSHSession` by the app delegate).
    let onConnect: (String) -> Void
    /// Runs `ssh-copy-id <alias>` with a public key, for a host whose probe found
    /// it wants a password (wired to `TermioStore.addKeyInstallSession`).
    let onSetUpKey: (String, String) -> Void

    @State private var hosts: [SSHConfigHost] = []
    @State private var publicKeys: [SSHPublicKey] = []
    @State private var addingHost = false
    @State private var configEditor: SSHConfigEditorTarget?
    /// The key whose Copy button is briefly confirming, so the click visibly took.
    @State private var copiedKeyID: String?

    var body: some View {
        Form {
            // No section header: the tab is called Remote Hosts and this is the
            // only list of them in it. The add control is the roster's own
            // gutter rather than a bar pinned to the window bottom, which in a
            // tall window sat a screen away from the roster with two unrelated
            // sections in between — and so read as adding a public key.
            Section {
                ForEach(machines) { machine in
                    NavigationLink(value: DeviceRoute(key: machine.settingsKey)) {
                        RemoteHostListRow(machine: machine, host: host(for: machine))
                    }
                }
                SettingsListGutter {
                    Button { addingHost = true } label: {
                        SettingsGutterGlyph(symbol: "plus")
                    }
                    .buttonStyle(.plain)
                    .help(localized("Add Remote Host"))
                    .accessibilityLabel(localized("Add Remote Host"))
                }
            } footer: {
                Text(machines.isEmpty
                     ? localized("Add a host you reach over SSH and Termio can run sessions on it, with agents that keep working after you disconnect.")
                     : localized("Open one to see how it is reached and what it runs."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button(localized("Edit")) { presentEditor(for: nil) }
                } label: {
                    SettingsLabel(
                        title: "~/.ssh/config",
                        subtext: localized("Reads ~/.ssh/config directly — Termio keeps no separate host list."),
                        titleFont: .headline
                    )
                }
            } header: {
                SectionHeaderLabel(title: localized("Config file"))
            }

            if !publicKeys.isEmpty {
                Section {
                    ForEach(publicKeys) { key in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.name)
                                Text(key.comment.isEmpty
                                     ? key.algorithm : "\(key.algorithm) · \(key.comment)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button(copiedKeyID == key.id
                                   ? localized("Copied") : localized("Copy")) { copy(key) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                } header: {
                    SectionHeaderLabel(title: localized("Public keys"))
                } footer: {
                    Text(localized("The public keys in ~/.ssh. Copy one to paste into a server’s authorized_keys — private keys are never read."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationDestination(for: DeviceRoute.self) { route in
            if let machine = machines.first(where: { $0.settingsKey == route.key }) {
                DevicePane(
                    machine: machine,
                    host: host(for: machine),
                    settings: settings,
                    keyToInstall: host(for: machine).flatMap {
                        SSHConfigFile.publicKeyToInstall(for: $0, keys: publicKeys)
                    },
                    onConnect: onConnect,
                    onSetUpKey: onSetUpKey,
                    onEditConfig: { presentEditor(for: host(for: machine)) }
                )
                .id(route.key)
                .navigationTitle(machine.name)
            } else {
                // The alias left `~/.ssh/config` while its pane was open.
                ContentUnavailableView {
                    Text(localized("Host Unavailable"))
                } description: {
                    Text(localized("This host is no longer in your configuration."))
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $addingHost, onDismiss: reload) {
            AddSSHHostSheet(existingAliases: Set(hosts.map(\.alias)))
        }
        .sheet(item: $configEditor, onDismiss: reload) { target in
            SSHConfigEditorSheet(target: target, settings: settings) { configEditor = nil }
        }
    }

    /// Every machine Termio has worked on except this one, then the aliases in
    /// `~/.ssh/config` it has not. The last group matters: a box you configured
    /// but never opened is exactly the one you came here to set up.
    ///
    /// This Mac is filtered out rather than led with: it has its own tab, and a
    /// roster that also carried it would be two doors to one pane.
    private var machines: [KnownDevice] {
        let known = DeviceRoster.known(in: store)
        return known.filter { !$0.isLocal }
            + DeviceRoster.unusedAliases(known: known)
                .map { KnownDevice(alias: $0, deviceID: nil) }
    }

    /// The `~/.ssh/config` block that reaches this machine, when one names it.
    /// `nil` for a host known only from a session record.
    private func host(for machine: KnownDevice) -> SSHConfigHost? {
        machine.alias.flatMap { alias in hosts.first { $0.alias == alias } }
    }

    private func presentEditor(for host: SSHConfigHost?) {
        // Symlinks resolve before the editor opens: its atomic auto-save would
        // otherwise replace a dotfile-managed link with a plain file.
        if let host {
            configEditor = SSHConfigEditorTarget(
                url: host.file.resolvingSymlinksInPath(), line: host.line)
        } else {
            try? SSHConfigFile.ensureConfigExists()
            configEditor = SSHConfigEditorTarget(url: SSHConfigFile.writableConfigURL, line: nil)
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

/// What a machine row pushes. A named type rather than the bare key so the
/// settings window's shared navigation stack can't confuse a machine with the
/// Agents tab's string destination.
///
/// Not `private`: `SettingsView` seeds the stack with one of these for the deep
/// links that mean a pane rather than a tab (RFC §D9's "Pair a phone…").
struct DeviceRoute: Hashable {
    let key: String
}

/// One host on the roster: its name over how it is reached. No status here — a
/// roster that probed every host on appear would fire ssh at every configured box
/// each time Settings opens, and a sleeping VPS would make that take as long as
/// its timeout. The pane asks; the roster lists.
private struct RemoteHostListRow: View {
    let machine: KnownDevice
    let host: SSHConfigHost?

    /// Empty when nothing is known about the route, so the row is one line rather
    /// than one line and a gap. Apple's rows put the *fact* in the subtitle ("65
    /// apps", "Off"); here the fact is where this host is and what signs in.
    private var detail: String {
        guard let host else { return localized("From your session history") }
        guard let identityFile = host.identityFile else { return host.destinationLabel }
        return "\(host.destinationLabel) · \((identityFile as NSString).lastPathComponent)"
    }

    var body: some View {
        HStack(spacing: 12) {
            // The same glyph, size and ink the main sidebar gives a remote
            // machine — whose comment already claims it matches "its host row in
            // Settings", which was untrue while this drew a filled accent-blue
            // square with an SF Symbol in it. Every row in this list is the same
            // kind of thing, so a tinted chip repeated down the column
            // distinguished nothing and just pulled the eye off the names.
            HugeIconView(icon: .serverStack, size: 15, color: .secondary)
                .frame(width: settingsRowIconWidth, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
        }
    }
}


