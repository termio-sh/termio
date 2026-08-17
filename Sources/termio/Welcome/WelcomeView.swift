import AppKit
import SwiftUI

/// The center-pane welcome, shown by `TerminalPane` whenever no session is mounted
/// — the state a returning user lands in after closing everything (the seeded
/// first-run `home` project means this is never the very first launch). It replaces
/// the old dead-end `ContentUnavailableView("No session selected")` with an
/// Xcode-welcome-style **centered** start page: a large app icon stacked *over* the
/// wordmark and tagline (a hero), then a single centered column of full-rounded
/// action buttons (open a project, a new terminal, then one per enabled agent), with
/// a one-click **Recent** projects list beneath.
///
/// Everything here reuses existing store entry points — `presentOpenProjectPanel`,
/// `addScratchTerminal`/`addScratchSession`, `addProject` — so the welcome adds no
/// new session machinery, only a front door onto it.
struct WelcomeView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings

    /// The whole page is one narrow, centered column — hero, actions, recents — so it
    /// reads like Xcode's welcome window rather than a document spread across a wide
    /// pane. 400pt keeps the full-rounded buttons a comfortable, tappable width.
    private let columnWidth: CGFloat = 400

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                startColumn
                recentColumn
            }
            .frame(width: columnWidth)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        }
    }

    /// The hero: the real app icon, big and centered, with the wordmark and tagline
    /// stacked directly beneath — the app introducing itself face-first, the way
    /// Xcode's welcome leads with its hammer icon over "Xcode".
    private var hero: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("Termio")
                    .font(.system(size: 32, weight: .bold))
                Text(localized("Start an agent in a project."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Start

    private var startColumn: some View {
        VStack(spacing: 8) {
            WelcomeActionRow(
                icon: HugeIconView(icon: .folder, size: 16, color: .secondary),
                title: localized("Open Project…"),
                shortcut: "⌘O"
            ) { store.presentOpenProjectPanel() }
            WelcomeActionRow(
                icon: HugeIconView(icon: .terminal, size: 16, color: .secondary),
                title: localized("New Terminal"),
                shortcut: "⌘T"
            ) { store.addScratchTerminal() }

            // Agents only — a plain terminal already has its own "New Terminal" button
            // above (⌘T). Each agent is the same full-rounded button, just with its
            // brand icon, so a new session reads as one more thing you can start here.
            let agents = enabledAgentPresets(settings).filter { $0 != .terminal }
            ForEach(agents) { preset in
                WelcomeActionRow(
                    icon: AgentIconView(agent: preset, size: 17),
                    title: preset.displayName
                ) { store.addScratchSession(agent: preset) }
            }
        }
    }

    // MARK: Recent

    @ViewBuilder
    private var recentColumn: some View {
        if !recentEntries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionLabel(localized("Recent"))
                ForEach(recentEntries) { entry in
                    WelcomeRecentRow(entry: entry) {
                        store.addProject(at: URL(fileURLWithPath: entry.path))
                    }
                }
            }
        }
    }

    /// The Recent list: currently-open projects first (so a user who merely closed
    /// the selected session can jump straight back), then remembered folders that
    /// aren't currently open — deduped by path, capped for a scannable column.
    /// `addProject` collapses both cases to one click: it reopens a closed folder or
    /// selects an already-open one.
    private var recentEntries: [RecentProject] {
        var seen = Set<String>()
        var out: [RecentProject] = []
        for project in store.orderedProjects where seen.insert(project.path).inserted {
            out.append(RecentProject(name: project.name, path: project.path))
        }
        for recent in settings.recentProjects where seen.insert(recent.path).inserted {
            out.append(recent)
        }
        return Array(out.prefix(8))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            // Match the rows' inner inset (8pt) so the header lines up with the
            // action/recent labels below it rather than hanging off to the left.
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }
}

/// A full-width welcome row: a leading glyph (a `HugeIcon` for Start actions, an
/// agent brand icon for a new session), a title, and an optional keyboard shortcut,
/// lifting a faint rounded fill under the cursor — the same hover affordance the
/// sidebar's controls use. Taking the icon as an arbitrary view is what lets the
/// Start actions and the agent sessions share one row type instead of splitting into
/// rows-and-chips.
private struct WelcomeActionRow: View {
    private let icon: AnyView
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var isHovering = false

    init(icon: some View, title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.icon = AnyView(icon)
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A full-rounded filled pill (Xcode's welcome buttons): a subtle fill at
            // rest so it reads as a button even without a cursor, brightening on hover.
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.12 : 0.06))
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
    }
}

/// A Recent-projects row: folder glyph, project name, and its home-relative path.
private struct WelcomeRecentRow: View {
    let entry: RecentProject
    let action: () -> Void
    @State private var isHovering = false

    /// The path with the user's home directory folded to `~`, the way the shell and
    /// Finder title bars show it — a full absolute path would dominate the row.
    private var displayPath: String {
        (entry.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HugeIconView(icon: .folder, size: 15, color: .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Text(displayPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
    }
}
