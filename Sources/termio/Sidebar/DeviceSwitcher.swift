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
    static func known(
        in store: TermioStore, paired: [PairedDevice] = PairedDeviceStore.all()
    ) -> [KnownDevice] {
        var deviceIDByAlias: [String: String] = [:]
        for device in TermiodDeviceRegistry.shared.all {
            // Paired routes come from the keychain below, not from here: a
            // handshake records one before a pairing is accepted, and a refused
            // or cancelled pairing must not leave a machine in the menus.
            for alias in device.routes.filter({ !$0.isPaired }).compactMap(\.hostKey) {
                deviceIDByAlias[alias] = device.id
            }
        }
        var aliases = Set(deviceIDByAlias.keys)
        // A paired Mac's route is never written to the registry file, so after
        // a relaunch the keychain is what still knows it.
        for paired in paired {
            let key = TermiodRoute.paired(paired.hostID).hostKey ?? ""
            aliases.insert(key)
            deviceIDByAlias[key] = paired.hostID
        }
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
        // A paired Mac is left out: cloning runs `git clone` over ssh, and a
        // paired Mac is reached by no ssh at all.
        return known.filter { !$0.isLocal && !TermiodRoute.isPaired(hostKey: $0.alias) }
            + unusedAliases(known: known).map { KnownDevice(alias: $0, deviceID: nil) }
    }
}

// A device has no "open" verb of its own. Reaching a machine is always the side
// effect of putting something on it — New Terminal on that device, Clone to it,
// or File ▸ Connect to… for a box in `~/.ssh/config` Termio has never worked on
// — and each of those already lands the user in the right scope. A menu that
// merely *travels* to a machine is the switcher the workspace replaced.

// MARK: - The device mark

extension KnownDevice {
    /// The machine a session runs on, or `nil` when it runs on this Mac.
    ///
    /// The identity has to be the **machine**, never the road to it. A plain `ssh`
    /// terminal never handshakes with a daemon, so it carries no `deviceID` of its
    /// own; asked for a mark on the session alone it would hash to a different
    /// colour than the durable termiod session sitting beside it on the same box.
    /// The registry already knows where an alias leads, and remembers across
    /// launches, so the alias is resolved before the identity is formed.
    ///
    /// `resolve` is the lookup, injectable so the invariant can be tested without
    /// standing up the shared registry.
    static func running(
        _ session: Session,
        resolvingAlias resolve: (String) -> String? = {
            TermiodDeviceRegistry.shared.deviceID(for: TermiodRoute(hostKey: $0))
        }
    ) -> KnownDevice? {
        guard let alias = session.termiodRemoteHost ?? session.sshHost else { return nil }
        return KnownDevice(alias: alias, deviceID: session.deviceID ?? resolve(alias))
    }
}

/// The mark a device carries wherever it is drawn small enough that its name
/// won't fit — the dot on a row that runs somewhere other than this Mac.
///
/// It is not decoration. The class of accident this app exists to prevent is
/// "I thought I was local, I was on the VPS", and the mark is the cue that
/// arrives *before* the mistake rather than after it. What does that work is the
/// mark's **presence**: a dot means elsewhere, and this Mac carries none.
///
/// What the mark used to encode besides presence was *which* machine, as a hue
/// derived from the device's identity. That has stopped paying for itself. A
/// workspace belongs to exactly one machine and everything filed under it takes
/// its machine from that workspace, so a hue drawn on those rows is the same
/// colour repeated down the whole column — a distinction that distinguishes
/// nothing. It also came from the terminal theme, so an identity changed when
/// the user changed colour scheme, and it moved once more when a handshake
/// replaced the alias with a `host_id`.
///
/// So the channel is spent on the thing the rows cannot otherwise say: whether
/// the machine is answering. That is knowable exactly where it matters — every
/// row in the sidebar belongs to the workspace on screen, and that workspace's
/// device is the one already being asked for a roster.
enum DeviceMark: Equatable {
    /// This Mac: the machine you are on when you are not thinking about
    /// machines, drawn as the absence of a mark.
    case here
    /// Another machine, with nothing live to say about it.
    case elsewhere
    /// Asked, not answered yet. Drawn hollow — "not filled in" is the shape of
    /// the thing it means.
    case reaching
    /// Asked and refused, carrying the device's own words for the tooltip.
    case unreachable(String)

    /// What to draw for `device`, given the device the window is showing and
    /// what that one last said.
    ///
    /// Liveness is only claimed for the device being shown, because it is the
    /// only one this app has asked. Answering for the others would mean a roster
    /// round trip per row — 216–292 ms cold, each
    /// (`docs/design/20260819-workspace-switch-latency.md`) — to animate dots
    /// nobody is looking at.
    ///
    /// Matched by identity rather than by alias, so a machine reached over a LAN
    /// name and a tailnet name is one machine and not two: a mark keyed to the
    /// road taken would give one box several marks as the user moves between
    /// networks, which is worse than no mark at all.
    static func mark(
        for device: KnownDevice, current: KnownDevice, state: DeviceSessionsState
    ) -> DeviceMark {
        guard !device.isLocal else { return .here }
        guard isSameMachine(device, current) else { return .elsewhere }
        switch state {
        case .loading: return .reaching
        case .failed(let message): return .unreachable(message)
        case .ready, .unavailable: return .elsewhere
        }
    }

    private static func isSameMachine(_ one: KnownDevice, _ other: KnownDevice) -> Bool {
        if let left = one.deviceID, let right = other.deviceID { return left == right }
        return one.alias == other.alias
    }
}

/// `DeviceMark` drawn: a 6pt dot, hollow while the machine has not answered and
/// struck through once it has refused.
///
/// Shape carries the state, not colour alone — the palette belongs to the
/// terminal theme, and a cue that only exists as a hue is a cue some users
/// cannot see. Colour appears once, on the failure, because that is the state
/// worth pulling an eye toward; a machine that is simply elsewhere and fine is
/// not news.
struct DeviceMarkView: View {
    let mark: DeviceMark
    let name: String

    private static let size: CGFloat = 6

    var body: some View {
        switch mark {
        case .here:
            EmptyView()
        case .elsewhere:
            Circle().fill(Color.secondary)
                .frame(width: Self.size, height: Self.size)
                .help(localized("Runs on \(name)"))
        case .reaching:
            Circle().stroke(Color.secondary, lineWidth: 1)
                .frame(width: Self.size, height: Self.size)
                .help(localized("Reaching \(name)…"))
        case .unreachable(let message):
            ZStack {
                Circle().stroke(Color.orange, lineWidth: 1)
                Capsule()
                    .fill(Color.orange)
                    .frame(width: Self.size + 3, height: 1)
                    .rotationEffect(.degrees(-45))
            }
            .frame(width: Self.size, height: Self.size)
            .help(localized("Can’t reach \(name): \(message)"))
        }
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
    local: @escaping @MainActor () -> Void
) -> SidebarMenuItem {
    let known = DeviceRoster.known(in: store)
    guard known.count > 1 else { return .action(localized("New Terminal"), local) }
    let projectID = project?.id
    return .submenu(localized("New Terminal"), known.map { device in
        guard let alias = device.alias else { return .action(device.name, local) }
        // A project row says which machines already hold this repo, so the menu
        // answers "where does this exist?" before you click. Asked through the
        // store rather than the project alone: a repo can be on a machine because
        // it is filed under that machine's workspace, with no checkout recorded.
        let cloned = project.map { store.remoteCheckout(for: $0, on: device) != nil } ?? false
        let label = project == nil || cloned ? device.name : "\(device.name) — not cloned yet"
        return .action(label) { store.addRemoteTerminal(host: alias, project: projectID) }
    })
}

/// "Move to Workspace ▸": files a project under a different scope on the same
/// machine. `nil` when nothing is left to offer — a submenu naming only the
/// workspace the project is already in is a dead click, and one naming a
/// workspace the move would refuse is worse.
///
/// Same machine only, because `moveProject` refuses the rest: a checkout is a
/// directory on one box, and the move would not move the directory. Putting the
/// repo on another machine is a clone, which is `Clone to <device>…`.
@MainActor
func moveToWorkspaceMenuItem(store: TermioStore, project: Project) -> SidebarMenuItem? {
    guard let device = store.device(of: project) else { return nil }
    let targets = store.orderedWorkspaces.filter {
        $0.id != project.workspaceID && $0.device == device
    }
    guard !targets.isEmpty else { return nil }
    return .submenu(localized("Move to Workspace"), targets.map { workspace in
        .action(workspace.name) { store.moveProject(project.id, toWorkspace: workspace.id) }
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
                store.cloneOnRemote(
                    host: alias, info: info,
                    into: projectID.map(TermioStore.RemoteCloneDestination.existing))
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
