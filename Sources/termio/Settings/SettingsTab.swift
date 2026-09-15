import SwiftUI

/// The top-level settings groups. Each is one row in the Settings sidebar. Not
/// private so the launch reminder can open settings straight to a given tab (see
/// `AppDelegate.openSettings`).
///
/// The groups are questions, in the order someone asks them: how should termio
/// behave, what is this Mac, what runs on it, and what else connects to it.
/// Where a setting sits is what says which it is, so nobody has to learn a rule
/// (RFC §D1, §D8).
///
/// Server leads the machine half rather than trailing it, because that is the
/// containment order the app itself uses — a workspace belongs to a machine, and
/// an agent is a CLI installed on one, so the box is named before the things
/// filed on it.
///
/// The last two used to be one group called Machines, and that group was the
/// split's own point left unmade: it put the box you are sitting at next to boxes
/// that may not exist, when the whole reason Server and Remote Hosts are separate
/// tabs is that those are different kinds of thing. **Everything above Mobile is
/// this Mac**; Mobile and Remote Hosts are the two tabs about something else on
/// the other end of a connection — a phone, and a box you reach over SSH.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case terminal
    case keyboard
    /// This Mac: the `termiod` it runs, the `termio` CLI on its PATH, and what
    /// Termio has installed into its agents' configs.
    ///
    /// A tab rather than the first row of a roster. The roster shape was the
    /// earlier answer and it hid the one machine that is always there behind a
    /// list of one — while its pane rendered nothing about the daemon this Mac
    /// actually runs, because `DevicePane` spent the local branch on the CLI row.
    /// Promoting it is what gives the local `termiod` a place to be looked at.
    ///
    /// It *opens* the group that holds Agents, Usage and Workspaces rather than
    /// standing in one of its own: those three are what this machine runs and
    /// what is filed on it, so they belong under the same gap, with the box named
    /// first. A group of one would have made the machine look like a fifth kind
    /// of setting instead of the subject of the three below it.
    case server
    case agents
    case usage
    case workspaces
    /// Pairing an iPhone, and the tunnel that carries it.
    ///
    /// Kept first-level rather than folded into the machine that serves it: the
    /// QR is the one step a new user cannot guess at, and three levels down a tab
    /// named after something else is where it went unfound. The scope objection
    /// is answered by navigation instead of a picker — this renders the Mac's own
    /// serving, and a remote host's is pushed from its row.
    case mobile
    /// Every other machine sessions can run on, one row apiece, drilling into how
    /// that machine is reached and what it runs.
    ///
    /// The split from `server` is top-level only: both entrances land on the same
    /// `DevicePane`, so the five concerns a machine has are built once. What the
    /// split buys is that neither pane renders a section that cannot apply — no
    /// "nothing to reach" placeholder on this Mac, no CLI row on a VPS.
    ///
    /// This is still navigation, not a mode, so RFC §D10 holds: what that rule
    /// forbids is a *picker* that silently re-points a page, and it blesses a
    /// page "chosen by navigation" in the same table.
    ///
    /// **Last of the settings tabs**, because it is the only one that can be
    /// empty. Most installs never add a host, and a tab about machines that do
    /// not exist belongs below the ones about machines that do — Server, which
    /// every install has, and Mobile, whose QR is what a new user is hunting for.
    /// It shares Mobile's group: both answer for something at the far end of a
    /// connection. Community still sits below: that is About, not a setting.
    ///
    /// The raw value stays `ssh` because it is the value persisted under
    /// `lastOpenKey`; changing it would reopen Settings on another tab for
    /// everyone who left this one showing. It has now survived five renamings,
    /// which is the point of it.
    case remoteHosts = "ssh"
    case community

    var id: String { rawValue }

    /// Opens a new sidebar group. `server` opens the group about this machine —
    /// the box itself, then what runs on it; `mobile` opens the two tabs about
    /// the far end of a connection; `community` stands alone because it leaves
    /// the app entirely.
    ///
    /// Grouped rather than run flat. Collapsing every local tab into one block
    /// would tell the top-level story in a single stroke — this Mac, then what
    /// connects to it — but eight undifferentiated rows is the flat sidebar §D8
    /// set out to fix, and finding Usage among eight is worse than finding it
    /// among three. The gaps are cheap; the chunking is not.
    var startsGroup: Bool {
        self == .server || self == .mobile || self == .community
    }

    /// `allCases` cut into the sidebar's groups, which System Settings separates
    /// with a gap rather than a header. Derived from `startsGroup` so a new tab
    /// can never fall out of the sidebar by being left off a hand-kept list.
    /// The gap itself is row inset, not a `Section` — see `SettingsView`.
    static var groups: [[SettingsTab]] {
        allCases.reduce(into: [[SettingsTab]]()) { groups, tab in
            if tab.startsGroup || groups.isEmpty {
                groups.append([tab])
            } else {
                groups[groups.count - 1].append(tab)
            }
        }
    }

    /// UserDefaults key remembering the last tab the user had open, so ⌘,
    /// reopens where they left off (see `AppDelegate.showSettings`).
    static let lastOpenKey = "settings.lastTab"

    var title: String {
        switch self {
        case .general: return localized("General")
        case .appearance: return localized("Appearance")
        case .terminal: return localized("Terminal")
        case .workspaces: return localized("Workspaces")
        case .server: return localized("Server")
        case .remoteHosts: return localized("Remote Hosts")
        case .keyboard: return localized("Keyboard")
        case .agents: return localized("Agents")
        case .usage: return localized("Usage")
        case .mobile: return localized("Mobile")
        case .community: return localized("Community")
        }
    }

    /// The sidebar glyph, drawn from the app's Hugeicons set so the settings
    /// window matches the main sidebar's line-icon style instead of SF Symbols.
    var icon: HugeIcon {
        switch self {
        case .general: return .settings
        case .appearance: return .paintBoard
        case .terminal: return .terminal
        case .workspaces: return .copy
        case .server: return .serverStack
        case .remoteHosts: return .network
        case .keyboard: return .keyboard
        case .agents: return .bot
        case .usage: return .chartColumn
        case .mobile: return .smartPhoneWifi
        case .community: return .bubbleChat
        }
    }

    /// The one-line description shown under the pane title in the detail header,
    /// matching macOS System Settings' navigation subtitle.
    var subtitle: String {
        switch self {
        case .general: return localized("Language, GitHub, and privacy")
        case .appearance: return localized("Theme, fonts, cursor, and window")
        case .terminal: return localized("Scrollback history and text selection")
        case .workspaces: return localized("The workspaces your projects and sessions are filed under")
        case .server: return localized("What this Mac runs, and what Termio installed on it")
        case .remoteHosts: return localized("The machines you reach from this Mac")
        case .keyboard: return localized("Keyboard shortcuts for every command")
        case .agents: return localized("The coding agents offered when you start a session")
        case .usage: return localized("Token usage for your connected agents")
        case .mobile: return localized("Pair your iPhone with the machines you work on")
        case .community: return localized("Discord, GitHub, and the WeChat group")
        }
    }
}
