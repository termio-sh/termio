import SwiftUI
import TermioShared
import UIKit

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
                    WorkingIndicator(tint: session.agent.tintColor)
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

// MARK: - Glass chrome

enum GlassChrome {
    /// A Liquid Glass surface. On iOS 26 it's a real interactive `UIGlassEffect`
    /// (the Telegram tab-bar look); older systems fall back to a chrome-material
    /// blur, which reads as translucent glass too.
    static func makeView(interactive: Bool) -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = interactive
            return UIVisualEffectView(effect: glass)
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
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

    func configure(symbol: String?, title: String, message: String, actionTitle: String?, busy: Bool) {
        if let symbol {
            icon.image = UIImage(systemName: symbol)
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
