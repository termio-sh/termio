import SwiftUI

/// The top-level settings groups. Each is one row in the Settings sidebar. Not
/// private so the launch reminder can open settings straight to a given tab (see
/// `AppDelegate.openSettings`).
///
/// The groups are questions, in the order someone asks them: is this Mac ready,
/// how should termio behave, what runs on this Mac, and what else connects to
/// it. Where a setting sits is what says which it is, so nobody has to learn a
/// rule (RFC §D1, §D8).
///
/// Server comes first because it is the machine the rest of the window
/// configures.
///
/// The last two used to be one group called Machines, and that group was the
/// split's own point left unmade: it put the box you are sitting at next to boxes
/// that may not exist, when the whole reason Server and Remote Hosts are separate
/// tabs is that those are different kinds of thing. **Everything above Remote
/// Hosts is this Mac**; Remote Hosts is the box on the other end of an SSH
/// connection.
enum SettingsTab: String, CaseIterable, Identifiable {
    /// This Mac: the `termiod` it runs, the `termio` CLI on its PATH, what Termio
    /// has installed into its agents' configs, and the port it serves phones on.
    ///
    /// A tab rather than the first row of a roster. The roster shape was the
    /// earlier answer and it hid the one machine that is always there behind a
    /// list of one — while its pane rendered nothing about the daemon this Mac
    /// actually runs, because `DevicePane` spent the local branch on the CLI row.
    /// Promoting it is what gives the local `termiod` a place to be looked at.
    ///
    /// First, in a group of its own, on a larger tile than the rows below. It
    /// once opened the Workspaces / Agents group instead, on the worry
    /// that a group of one would read as a fifth kind of setting; the larger
    /// tile at the top is what answers that — it is the machine, not a
    /// preference.
    case server
    case general
    case appearance
    case terminal
    case keyboard
    case workspaces
    case agents
    /// Every other machine sessions can run on, one row apiece, drilling into how
    /// that machine is reached, what it runs, and how a phone pairs with it.
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
    /// **Opens the far-end group**, closing the machine arc that Server began:
    /// this Mac, what runs on it, what is filed on it, then the other boxes
    /// sessions can run on. That this tab is the one that can be empty does not sink it:
    /// empty here is an Add Remote Host button, which is the tab doing its job,
    /// not a dead end. Community still sits below: that is About, not a setting.
    ///
    /// The raw value stays `ssh` because it is the value persisted under
    /// `lastOpenKey`; changing it would reopen Settings on another tab for
    /// everyone who left this one showing. It has now survived five renamings,
    /// which is the point of it.
    case remoteHosts = "ssh"
    case community

    var id: String { rawValue }

    /// Opens a new sidebar group. `server` stands alone at the top as the machine
    /// itself; `general` opens how Termio behaves; `workspaces` opens what is
    /// filed on and installed on this Mac; `remoteHosts` stands for the far end of
    /// a connection; `community` stands alone because it leaves the app entirely.
    ///
    /// Grouped rather than run flat. Collapsing every local tab into one block
    /// would tell the top-level story in a single stroke — this Mac, then what
    /// connects to it — but seven undifferentiated rows is the flat sidebar §D8
    /// set out to fix, and finding Agents among seven is worse than finding it
    /// among two. The gaps are cheap; the chunking is not.
    var startsGroup: Bool {
        self == .general || self == .workspaces || self == .remoteHosts || self == .community
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
        case .community: return .bubbleChat
        }
    }
}
