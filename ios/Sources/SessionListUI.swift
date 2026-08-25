import SwiftUI
import TermioShared
import UIKit

extension Color {
    /// Monochrome ink for the working spinner, matching the Mac sidebar's
    /// black/white comet: the motion already says "working", so color stays
    /// reserved for the status dots (green done / orange attention) that have no
    /// other channel. Adapts to light/dark like the Mac's appearance-matched ink.
    static let sessionWorkingInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .white : .black
    })
}

// Pieces shared by the two home levels (the Projects root and a pushed
// project page): the session row, the zero state, and the floating glass
// chrome they both draw.

// MARK: - Session row

/// A session row, ChatGPT-chat-list style: mostly just the title, the agent
/// mark (or its working spinner) leading, the status dot trailing when it has
/// something to say, and the current session wrapped in a rounded pill. When the session carries live
/// activity text (a pending question, the running command), it appears as a
/// gray preview line under the title — Messages' "last message", shown only
/// when there is one, so quiet sessions stay one dense line. Cross-project
/// strips (the root's "Needs You") pass `showsProject` so the row says where
/// it lives.
struct SessionRow: View {
    let session: MockSession
    let isCurrent: Bool
    var showsProject = false
    /// Hairline under the row, Messages-style — set on every row but a
    /// group's last, so the whitespace between groups stays clean.
    var showsSeparator = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if session.status == .working {
                    WorkingIndicator(tint: .sessionWorkingInk)
                } else {
                    AgentIconView(
                        ref: session.agent.iconRef,
                        size: 14,
                        tint: session.agent.tintColor
                    )
                }
            }
            .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            // Like ProjectRow's trailing summary: the dot only enters the
            // layout when it has something to say, so idle rows don't reserve
            // invisible width and the title runs to the edge (no chevron —
            // ChatGPT/Messages chat lists don't mark drill-down either).
            if session.status == .done || session.status == .needsAttention {
                StatusDot(status: session.status)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            isCurrent ? Color.primary.opacity(0.08) : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        // Fill whatever height the hosting cell settles on (its self-sizing
        // floor can exceed the row's ideal height), so the content centers
        // and the separator pins to the real cell bottom — otherwise the
        // title reads off-center between two separators.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Inset to the text's left edge (10 padding + 16 icon + 10 spacing),
        // like the system separators under Messages' conversation rows.
        .overlay(alignment: .bottom) {
            if showsSeparator { RowSeparator(leadingInset: 36) }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if showsProject, !session.project.isEmpty { parts.append(session.project) }
        // The worktree's branch, verbatim like the Mac sidebar's label — only
        // set for sessions living off the main checkout, so plain rows don't
        // repeat the project branch.
        if let branch = session.worktreeBranch { parts.append(branch) }
        if !session.subtitle.isEmpty { parts.append(session.subtitle) }
        return parts.joined(separator: " · ")
    }
}

/// The system-separator hairline, drawn inside the row (UIKit's own table
/// separators can't do this layout: grouped tables add full-width borders at
/// section edges, and plain tables pin their headers).
struct RowSeparator: View {
    let leadingInset: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 1 / UIScreen.main.scale)
            .padding(.leading, leadingInset)
    }
}

// MARK: - Workspace grouping

/// One workspace's containers — the group a list draws as a section. The Mac's
/// tree is Device → Workspace → Project → Session, and a phone list that
/// flattens it pours every machine's rows into one column, where a VPS clone is
/// indistinguishable from a local one. The workspace is the group; `deviceAlias`
/// is the machine it is on, named in the header the way the Mac names it, and
/// never a level you navigate.
struct WorkspaceGroup {
    let id: String
    let name: String
    let deviceAlias: String?
    var projects: [MockProject]

    /// The machine to put after the workspace name, and nil when there is
    /// nothing to add: this Mac carries no mark — being on the machine you
    /// paired with is the absence of one — and neither does a workspace already
    /// named after its box, where the header says it once. Both rules are the
    /// desktop sidebar's.
    var machineLabel: String? {
        guard let deviceAlias,
              deviceAlias.caseInsensitiveCompare(name) != .orderedSame
        else { return nil }
        return deviceAlias
    }

    /// Every session in the group's containers, in roster order — what the
    /// session tabs (Terminals, Chats) list under the header, where the
    /// container itself is the tab and only its sessions are rows.
    var sessions: [MockSession] { projects.flatMap(\.sessions) }

    /// Containers grouped by workspace. Workspaces keep the order the Mac pushed
    /// them in — the sidebar's own order — and only the projects inside a group
    /// re-sort when the caller asks for Name, so switching sort never reshuffles
    /// the machines out from under the user.
    static func grouped(_ projects: [MockProject], sortedByName: Bool = false) -> [WorkspaceGroup] {
        var groups: [WorkspaceGroup] = []
        var indexByWorkspace: [String: Int] = [:]
        for project in projects {
            if let index = indexByWorkspace[project.workspaceID] {
                groups[index].projects.append(project)
                continue
            }
            indexByWorkspace[project.workspaceID] = groups.count
            groups.append(WorkspaceGroup(
                id: project.workspaceID,
                name: project.workspaceName,
                deviceAlias: project.deviceAlias,
                projects: [project]
            ))
        }
        guard sortedByName else { return groups }
        return groups.map { group in
            var sorted = group
            sorted.projects.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return sorted
        }
    }
}

extension Array where Element == WorkspaceGroup {
    /// Whether the sections are headed by their workspace. One unnamed local
    /// workspace is the case almost everyone is in, and the Mac hides its own
    /// workspace switcher there too — the page title already says what the list
    /// is. A second workspace, or one that names a machine, is what makes the
    /// grouping worth a header.
    var namesWorkspaces: Bool {
        count > 1 || contains { $0.deviceAlias != nil && !$0.name.isEmpty }
    }
}

/// A small gray caps label capping a workspace group, with room for one
/// trailing detail — the machine that workspace is on. Mail and Files head their
/// groups the same way: the account or location names the section, and the rows
/// underneath say nothing more about where they live.
///
/// The detail keeps its own case. It is an `~/.ssh/config` alias, a literal the
/// user typed, and uppercasing it would make it something they can't find again.
final class WorkspaceSectionHeaderView: UITableViewHeaderFooterView {
    static let reuseID = "workspaceSectionHeader"
    /// The height a table should give it — the Projects list's, so the three
    /// workspace-grouped lists cap their groups identically.
    static let height: CGFloat = 28

    private let label = UILabel()
    private let detailLabel = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = .tertiaryLabel
        detailLabel.textAlignment = .right
        // The workspace name is the section's identity; the machine gives way
        // when there isn't room for both.
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        contentView.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            detailLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -22),
            detailLabel.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, detail: String? = nil) {
        label.text = title.uppercased()
        detailLabel.text = detail
        detailLabel.isHidden = detail == nil
        isAccessibilityElement = true
        accessibilityTraits = .header
        // VoiceOver reads the group once, so the machine belongs in the same
        // breath as the name rather than as a second, orphaned element.
        accessibilityLabel = detail.map { "\(title), \(localized("on \($0)"))" } ?? title
    }
}

// MARK: - Empty state view

/// The centered zero state — a quiet glyph (or spinner), a title, a line of
/// guidance, and an optional pill button. Modeled on Messages/Telegram's empty
/// inbox: never fake content, always a status + a next step.
final class ListEmptyStateView: UIView {
    private let icon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    /// Fired when the pill button is tapped (only shown when it has a title).
    var onAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        icon.contentMode = .center
        icon.tintColor = .tertiaryLabel
        icon.preferredSymbolConfiguration = .init(pointSize: 44, weight: .regular)
        spinner.color = .secondaryLabel
        spinner.hidesWhenStopped = true

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center

        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        actionButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        actionButton.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, spinner, titleLabel, messageLabel, actionButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(16, after: icon)
        stack.setCustomSpacing(20, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Nudged above dead-center so it reads as content, not a modal.
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -44),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 44),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(icon glyph: HugeIcon?, title: String, message: String, actionTitle: String?, busy: Bool) {
        if let glyph {
            icon.image = glyph.strokeImage(boxSize: 44)
            icon.isHidden = false
        } else {
            icon.isHidden = true
        }
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        titleLabel.text = title
        messageLabel.text = message
        if let actionTitle {
            actionButton.setTitle(actionTitle, for: .normal)
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
    }
}
