import AppKit
import SwiftUI

/// The center-pane welcome, shown by `TerminalPane` whenever no session is mounted
/// — the state a returning user lands in after closing everything (the seeded
/// first-run `home` project means this is never the very first launch). It replaces
/// the old dead-end `ContentUnavailableView("No session selected")` with a start
/// page: one left-aligned column, centred in the pane, holding a small header, the
/// two general actions, a compact grid of agents, and a one-click **Recent** list.
/// Only the two general actions wear a fill, so they read first and a long roster
/// of agents cannot push Recent off the screen.
///
/// Everything here reuses existing store entry points — `presentOpenProjectPanel`,
/// `addScratchTerminal`/`addScratchSession`, `addProject` — so the welcome adds no
/// new session machinery, only a front door onto it.
struct WelcomeView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings

    private let columnWidth: CGFloat = 520

    var body: some View {
        GeometryReader { pane in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    primaryActions
                    agentSection
                    recentSection
                }
                .frame(maxWidth: columnWidth, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 40)
                // Centred when it fits, scrolling from the top when it does not.
                .frame(maxWidth: .infinity, minHeight: pane.size.height)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("Termio")
                    .font(.system(size: 22, weight: .semibold))
                Text(localized("Start an agent in a project."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var primaryActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { primaryButtons }
            VStack(spacing: 8) { primaryButtons }
        }
    }

    @ViewBuilder
    private var primaryButtons: some View {
        WelcomePrimaryButton(icon: .folder, title: localized("Open Project…"), shortcut: "⌘O") {
            store.presentOpenProjectPanel()
        }
        WelcomePrimaryButton(icon: .terminal, title: localized("New Terminal"), shortcut: "⌘T") {
            store.addScratchTerminal()
        }
    }

    // MARK: Agents

    /// A plain terminal is left out: it already has New Terminal above.
    @ViewBuilder
    private var agentSection: some View {
        let agents = enabledAgentPresets(settings).filter { $0 != .terminal }
        if !agents.isEmpty {
            WelcomeSection(title: localized("Agents")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 2)], spacing: 2) {
                    ForEach(agents) { preset in
                        WelcomeRow(action: { store.addScratchSession(agent: preset) }) {
                            AgentIconView(agent: preset, size: 16)
                            Text(preset.displayName)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    // MARK: Recent

    @ViewBuilder
    private var recentSection: some View {
        if !recentEntries.isEmpty {
            WelcomeSection(title: localized("Recent")) {
                VStack(spacing: 2) {
                    ForEach(recentEntries) { entry in
                        WelcomeRow(action: { store.addProject(at: URL(fileURLWithPath: entry.path)) }) {
                            HugeIconView(icon: .folder, size: 16, color: .secondary)
                            Text(entry.name)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Spacer(minLength: 16)
                            Text((entry.path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
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
        // Local projects only: a row here reopens its path with `addProject`,
        // which is this Mac's folder picker's verb. A checkout on another machine
        // has no local folder to reopen, and the path would land as a local
        // project pointing at a directory that isn't here.
        for project in store.orderedProjects
        where !store.isOnAnotherDevice(project) && seen.insert(project.path).inserted {
            out.append(RecentProject(name: project.name, path: project.path))
        }
        for recent in settings.recentProjects where seen.insert(recent.path).inserted {
            out.append(recent)
        }
        return Array(out.prefix(5))
    }
}

private struct WelcomeSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            // The rows' hover fill overhangs the column, so their glyphs stay on its edge.
            content.padding(.horizontal, -8)
        }
    }
}

/// One of the two actions that wear a fill at rest.
private struct WelcomePrimaryButton: View {
    let icon: HugeIcon
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HugeIconView(icon: icon, size: 16, color: .primary)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 12)
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.12 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A quiet row for agents and recent projects: no fill until the pointer is on it.
private struct WelcomeRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { content }
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
