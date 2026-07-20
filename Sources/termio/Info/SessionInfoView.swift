import AppKit
import SwiftUI

/// The inspector's Info pane — the third tab beside Files and Changes. At-a-glance
/// facts about the selected session plus quick actions on its working directory and,
/// for an agent session, its conversation transcript: copy the path, reveal it in
/// Finder, open the folder in an installed editor, or open a rendered HTML trace of
/// the agent's conversation in the browser.
struct SessionInfoView: View {
    @EnvironmentObject var store: TermioStore

    private var session: Session? {
        store.selectedSessionID.flatMap { store.session($0) }
    }

    private var project: Project? {
        store.selectedSessionID.flatMap { store.project(for: $0) }
    }

    /// Where the session runs: its worktree if it has one, else the project root.
    /// A loose terminal reports its live cwd (the session's own mutable path)
    /// rather than the container's `$HOME` fallback.
    private var workingDirectory: String? {
        guard let project else { return nil }
        if project.kind == .terminals, let id = store.selectedSessionID {
            return store.workingDirectories[id]
                ?? session?.lastWorkingDirectory
                ?? project.path
        }
        return session?.worktreePath ?? project.path
    }

    /// The agent's conversation log for this session (`TermioStore.transcriptPaths`) —
    /// carried in Claude Code's hook stream, or discovered from Codex's on-disk rollout.
    /// `nil` until the agent reports its first status.
    private var transcriptPath: String? {
        store.selectedSessionID.flatMap { store.transcriptPaths[$0] }
    }

    /// The working directory's page on its forge (GitHub, GitLab, …), detected from
    /// the origin remote — `nil` (row hidden) for a non-repo or an unrecognized host.
    @State private var remotePage: GitService.RemotePage?

    var body: some View {
        content
            // Learn the transcript from disk when no hook has delivered it — so the
            // trace is available even for a session that fired no termio hook (one
            // started before the hook was installed). Runs once per selection, only
            // while the path is still unknown; a later hook value simply agrees.
            .task(id: store.selectedSessionID) {
                guard let id = store.selectedSessionID,
                      store.transcriptPaths[id] == nil,
                      let path = store.resolveTranscriptPath(for: id) else { return }
                store.transcriptPaths[id] = path
            }
            .task(id: workingDirectory) {
                remotePage = nil
                guard let workingDirectory else { return }
                remotePage = await GitService.remotePage(in: workingDirectory)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let session, let workingDirectory {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    workingDirectorySection(workingDirectory)
                    if session.agent != .terminal {
                        agentSection(session)
                    }
                }
                // Outer inset is 4, not 14: every row and section label already carries its own
                // 10pt horizontal padding (which also insets the hover highlight), so 4 + 10 lands
                // their text at 14pt — flush with the file-tree header (`FileBrowserView.header`,
                // `.padding(.leading, 14)`). At 14 the whole outer inset the Info list read
                // noticeably further right than every other pane.
                .padding(.horizontal, 4)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "No Session",
                systemImage: "info.circle",
                description: Text("Select a session to see its info.")
            )
        }
    }

    // MARK: Working directory

    private func workingDirectorySection(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Working Directory")

            VStack(alignment: .leading, spacing: 1) {
                InfoRow(symbol: "doc.on.doc", title: "Copy Path") { copy(path) }
                InfoRow(symbol: "folder", title: "Reveal in Finder") { revealInFinder(path) }
                if let remotePage {
                    InfoRow(forge: remotePage.forge, title: "View on \(remotePage.forge.name)") {
                        NSWorkspace.shared.open(remotePage.url)
                    }
                }
                ForEach(EditorTarget.installed) { editor in
                    InfoRow(appIcon: editor.appIcon, title: "Open in \(editor.name)") {
                        editor.open(URL(fileURLWithPath: path))
                    }
                }
            }
        }
    }

    // MARK: Agent

    private func agentSection(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Agent")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                AgentIconView(agent: session.agent, size: 15)
                Text(session.agent.displayName)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 10)

            if let transcriptPath {
                VStack(alignment: .leading, spacing: 1) {
                    InfoRow(symbol: "list.bullet.rectangle", title: "View Trace") { viewTrace(transcriptPath, session: session) }
                    InfoRow(symbol: "doc.on.doc", title: "Copy Path") { copy(transcriptPath) }
                    InfoRow(symbol: "folder", title: "Reveal in Finder") { revealInFinder(transcriptPath) }
                }
            } else {
                Text("Waiting for the agent's first status report.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: Pieces

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
    }

    // MARK: Actions

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Reveals `path` in Finder: a directory opens with itself selected in its
    /// parent, a file is highlighted in its folder.
    private func revealInFinder(_ path: String) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if exists, isDir.boolValue {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    /// Opens the session's rendered trace over the terminal (the `TraceView` overlay),
    /// like clicking a file or a diff. Rendering — and any failure — is handled inside
    /// the overlay, themed to match termio.
    private func viewTrace(_ jsonlPath: String, session: Session) {
        store.openTrace = TraceRequest(jsonlPath: jsonlPath, title: store.displayTitle(for: session))
    }
}

/// A single action row in the Info pane: a leading glyph, a label, and a hover
/// highlight — the same calm, borderless look as the actions in the reference Info
/// panel. The leading glyph is either a muted SF Symbol (for termio's own actions —
/// Copy Path, Reveal, View Trace) or an editor's real app icon (for "Open in …"),
/// so an editor row is unmistakably that app. `.buttonStyle(.plain)` keeps it flat;
/// the highlight is drawn on hover.
private struct InfoRow: View {
    private enum Leading {
        case symbol(String)
        case appIcon(NSImage?)
        case forge(GitService.Forge)
    }

    private let leading: Leading
    let title: String
    let action: () -> Void

    @State private var hovering = false

    init(symbol: String, title: String, action: @escaping () -> Void) {
        self.leading = .symbol(symbol)
        self.title = title
        self.action = action
    }

    init(appIcon: NSImage?, title: String, action: @escaping () -> Void) {
        self.leading = .appIcon(appIcon)
        self.title = title
        self.action = action
    }

    init(forge: GitService.Forge, title: String, action: @escaping () -> Void) {
        self.leading = .forge(forge)
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                leadingGlyph
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        switch leading {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        case .appIcon(let image):
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "app")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        case .forge(let forge):
            // A brand mark fills its box edge-to-edge; 14 in the 18pt slot lands it
            // at the same optical size as the 13pt SF Symbols above it.
            ForgeIconView(forge: forge, size: 14)
        }
    }
}
