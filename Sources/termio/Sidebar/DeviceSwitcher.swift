import AppKit
import SwiftUI
import TermioShared

/// Which machines the interface knows about, and which ones it could reach but
/// hasn't. The split follows the ownership rule: the *known* list is state Termio
/// produced itself (a completed handshake, a session it opened), while the
/// reachable-but-unused list is read straight out of `~/.ssh/config`, which stays
/// the only host database Termio has and is never written to.
@MainActor
enum DeviceRoster {
    /// This Mac, then every machine Termio has actually worked on, by alias.
    ///
    /// A machine qualifies two ways: a `hello_ok` recorded it in the device
    /// registry, or a session in the tree says it runs there. The second source
    /// matters on the launch after an upgrade — a state file can name a host the
    /// registry has not re-learned yet, and a device the user can see sessions on
    /// must not be missing from the switcher.
    static func known(in store: TermioStore) -> [KnownDevice] {
        var deviceIDByAlias: [String: String] = [:]
        for device in TermiodDeviceRegistry.shared.all {
            for alias in device.routes.compactMap(\.sshAlias) {
                deviceIDByAlias[alias] = device.id
            }
        }
        var aliases = Set(deviceIDByAlias.keys)
        for project in store.projects {
            for session in project.sessions {
                if let host = session.termiodRemoteHost { aliases.insert(host) }
            }
        }
        // This Mac always leads — not because it is special, but because it is the
        // one machine that is always there.
        return [.thisMac]
            + aliases.sorted().map { KnownDevice(alias: $0, deviceID: deviceIDByAlias[$0]) }
    }

    /// The `~/.ssh/config` aliases no known device answers to — what "Connect to…"
    /// offers. Order follows the config file; duplicates (one alias named in two
    /// blocks) collapse to the first.
    static func unusedAliases(known: [KnownDevice]) -> [String] {
        var seen = Set(known.compactMap(\.alias))
        var result: [String] = []
        for alias in SSHConfigFile.hosts().map(\.alias) where !seen.contains(alias) {
            seen.insert(alias)
            result.append(alias)
        }
        return result
    }

    /// Every machine a repo could be cloned to: the known ones first, then the
    /// aliases that have never been used. Cloning is itself a first contact —
    /// `ensureRemoteReady` installs `termiod` on the way — so an unused alias is a
    /// legitimate target here even though it is not yet a device.
    static func cloneTargets(in store: TermioStore) -> [KnownDevice] {
        let known = known(in: store)
        return known.filter { !$0.isLocal }
            + unusedAliases(known: known).map { KnownDevice(alias: $0, deviceID: nil) }
    }

    /// The device the app is on, resolved against the machines that actually
    /// exist. A stored alias that no longer matches anything (the user deleted the
    /// `Host` block, or closed the last session on it) falls back to this Mac
    /// rather than silently aiming at nothing.
    static func current(_ store: TermioStore, known: [KnownDevice]) -> KnownDevice {
        known.first { $0.alias == store.currentDeviceAlias } ?? .thisMac
    }
}

/// The rows every device switcher shows, wherever it is mounted. The sidebar's
/// toolbar control is the only opening today; the rows live here rather than in it
/// because there is one current device, and it would be a bug for two controls to
/// disagree about which one it is.
struct DeviceSwitcherMenuContent: View {
    @EnvironmentObject var store: TermioStore

    var body: some View {
        let known = DeviceRoster.known(in: store)
        let unused = DeviceRoster.unusedAliases(known: known)
        // An inline Picker is what draws the checkmark on the current device; a
        // row of Buttons would leave the switcher unable to say which machine is
        // selected.
        Picker("", selection: selection) {
            ForEach(known) { device in
                Text(device.name).tag(device.id)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Button(localized("Refresh")) { store.refreshDeviceSessions() }
        if !unused.isEmpty {
            Divider()
            Menu(localized("Connect to…")) {
                ForEach(unused, id: \.self) { alias in
                    Button(alias) { connect(to: alias) }
                }
            }
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: { store.currentDeviceAlias ?? "" },
            set: { alias in
                store.switchToDevice(
                    KnownDevice(alias: alias.isEmpty ? nil : alias, deviceID: nil))
            }
        )
    }

    /// First contact with a machine from `~/.ssh/config`: enter it, then open a
    /// terminal on it — which is what installs `termiod` there if it is missing.
    /// Reaching for a box is also saying that is where you are about to work.
    private func connect(to alias: String) {
        store.switchToDevice(KnownDevice(alias: alias, deviceID: nil))
        store.addRemoteTerminal(host: alias)
    }
}

/// The device switcher, in the sidebar's own toolbar region: which machine you
/// are on, and the control that changes it. It sits in the strip above the list
/// rather than in a row of its own, next to the navigator toggle and the sidebar's
/// other actions — the band belongs to the column below it, and a first row that
/// is not a session is a row the tree has to explain.
///
/// Quiet by design — it names the device and nothing else — and absent entirely
/// while this Mac is the only one, so a user who never leaves their laptop never
/// sees it.
struct DeviceSwitcherToolbarView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.controlActiveState) private var controlActive

    /// Long aliases truncate rather than push the sort and `+` buttons toward
    /// NSToolbar's `»` overflow: the sidebar region has only the room the
    /// navigator's minimum thickness gives it.
    private static let nameWidthCeiling: CGFloat = 130

    var body: some View {
        let known = DeviceRoster.known(in: store)
        // The single-device collapse. Not "hidden but present": with one machine
        // there is no switch to make, and a control that always reads "This Mac"
        // is a label for a decision the user never took.
        if known.count > 1 {
            let current = DeviceRoster.current(store, known: known)
            Menu {
                DeviceSwitcherMenuContent()
            } label: {
                HStack(spacing: 5) {
                    // Sized against the toolbar's own glyphs (the navigator toggle, the
                    // sort pull-down) rather than shrunk to fit beside them, and set in
                    // the sidebar's interface font — this control belongs to that column.
                    HugeIconView(icon: .serverStack, size: 15, color: color)
                    Text(current.name)
                        .font(settings.interfaceFont)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HugeIconView(icon: .chevronRight, size: 8, color: color,
                                 lineWidthOverride: 1.75)
                        .rotationEffect(.degrees(90))
                }
                .frame(maxWidth: Self.nameWidthCeiling)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(localized("The sidebar shows this device’s sessions"))
        }
    }

    private var color: Color {
        controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .secondary
    }
}

// MARK: - Menu construction

/// The "New Terminal" verb, device-aware: a plain action while this Mac is the
/// only machine, a device submenu once there is more than one. `local` is what
/// the row for this Mac does, which differs per call site (a project's directory,
/// the Terminals section, `$HOME`).
///
/// `project` scopes the remote rows the way the row it hangs off is scoped: from a
/// project it means "this repo, over there" and opens in the checkout that project
/// recorded for the device, so a machine the repo isn't on yet says so instead of
/// dropping a `$HOME` shell somewhere unexpected.
@MainActor
func newTerminalMenuItem(
    store: TermioStore,
    project: Project? = nil,
    local: @escaping () -> Void
) -> SidebarMenuItem {
    let known = DeviceRoster.known(in: store)
    guard known.count > 1 else { return .action(localized("New Terminal"), local) }
    let projectID = project?.id
    return .submenu(localized("New Terminal"), known.map { device in
        guard let alias = device.alias else { return .action(device.name, local) }
        // A project row says which machines already hold this repo, so the menu
        // answers "where does this exist?" before you click. The checkout is keyed
        // by device, so ask the registry for the identity learned earlier and let
        // the lookup fall back to the alias when this box has never been reached.
        let cloned = project?.remoteCheckout(device: device.deviceID, alias: alias) != nil
        let label = project == nil || cloned ? device.name : "\(device.name) — not cloned yet"
        return .action(label) { store.addRemoteTerminal(host: alias, project: projectID) }
    })
}

/// "Clone to <device>…": the project's `origin` is `git clone`d **on** that
/// machine, then a terminal opens inside the clone. `nil` when there is nowhere to
/// clone to — an empty `~/.ssh/config` and no device ever reached — because a
/// disabled row explaining an empty config is the dead end this replaces.
///
/// Only meaningful for a git checkout with a remote. Origin presence is resolved
/// at click time (async): the menu is built synchronously and a git call per
/// right-click would stall the sidebar, so a folder with no origin alerts rather
/// than silently doing nothing.
@MainActor
func cloneToDeviceMenuItem(
    store: TermioStore,
    folder: String,
    project projectID: UUID? = nil
) -> SidebarMenuItem? {
    let targets = DeviceRoster.cloneTargets(in: store)
    guard !targets.isEmpty else { return nil }
    let clone = { (device: KnownDevice) in
        { @MainActor in
            guard let alias = device.alias else { return }
            Task { @MainActor in
                guard let info = await GitService.cloneInfo(in: folder) else {
                    store.presentRemoteSetupFailure(
                        host: alias,
                        message: localized("This folder has no git “origin” remote to clone."))
                    return
                }
                store.cloneOnRemote(host: alias, info: info, project: projectID)
            }
        }
    }
    // One machine needs no submenu — the verb names it outright, which is also the
    // only form that reads as a sentence.
    if targets.count == 1, let only = targets.first {
        return .action(localized("Clone to \(only.name)…"), clone(only))
    }
    return .submenu(localized("Clone to"), targets.map { .action($0.name, clone($0)) })
}
