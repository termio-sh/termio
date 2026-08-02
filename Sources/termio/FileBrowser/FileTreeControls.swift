import Foundation
import SwiftUI

/// The one quiet-chip chrome worn by every inspector pane-header icon control — the
/// explorer/Changes buttons, the Issues refresh & filter, the ↗ Open-on-GitHub, and the
/// detail's hide-list / maximize / close. A 22×22 hit target with a faint rounded fill that
/// fades in on hover; the glyph itself is coloured secondary→primary by its host. Factored out
/// so a `Button` and a `Menu` label render pixel-identical chrome despite being different types.
struct TreeHeaderChip: ViewModifier {
    @Binding var hovering: Bool

    func body(content: Content) -> some View {
        content
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A quiet icon button for the explorer / Changes pane headers. The explorer's file
/// actions draw VS Code's own codicon glyphs (see `Codicon`) so the toolbar matches
/// VS Code; the Changes pane uses SF Symbols. Both render quiet `.secondary` at rest,
/// brightening to primary on hover over the shared `TreeHeaderChip` fill.
struct TreeHeaderButton: View {
    /// An SF Symbol, a VS Code codicon, or a Hugeicons stroke glyph — the icon
    /// sources the pane header toolbars draw from.
    enum Source {
        case symbol(String)
        case codicon(Codicon)
        case huge(HugeIcon)
    }

    let source: Source
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    init(codicon: Codicon, help: String, action: @escaping () -> Void) {
        self.source = .codicon(codicon)
        self.help = help
        self.action = action
    }

    init(symbol: String, help: String, action: @escaping () -> Void) {
        self.source = .symbol(symbol)
        self.help = help
        self.action = action
    }

    init(huge: HugeIcon, help: String, action: @escaping () -> Void) {
        self.source = .huge(huge)
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            icon.modifier(TreeHeaderChip(hovering: $isHovering))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var icon: some View {
        switch source {
        case .symbol(let name):
            Image(systemName: name)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
        case .codicon(let codicon):
            CodiconView(icon: codicon, size: 15, color: isHovering ? .primary : .secondary)
        case .huge(let icon):
            // 1.0pt: the one weight every inspector header Hugeicon shares (↗, the detail's
            // window controls, the filter funnel), tuned to sit at the optical weight of the
            // codicon refresh beside it rather than reading heavier than it.
            HugeIconView(icon: icon, size: 15, color: isHovering ? .primary : .secondary,
                         lineWidthOverride: 1.0)
        }
    }
}

/// The right-click menu actions the tree's rows invoke: `newFile`/`newFolder`
/// (created inside the given directory), `rename`, and `delete`. Bundled so
/// `FileRow` carries one value rather than a fistful of closures. (Single-click
/// open is driven by the List's native selection, not a row action — see
/// `FileBrowserView`. Reveal in Finder / Copy Path need no view state, so they
/// live directly in the row menu.)
struct FileTreeActions {
    let newFile: (_ directory: URL) -> Void
    let newFolder: (_ directory: URL) -> Void
    let rename: (URL) -> Void
    let delete: (URL) -> Void
    /// Types the row's path into the selected session's agent prompt — Cursor's
    /// "Add File to Chat" verb, on the same shell-quoted token a drag onto the
    /// terminal inserts.
    let addToChat: (URL) -> Void
    /// Read at menu-open time so the item tracks the live session: a plain shell
    /// has no chat to add to, so the row doesn't offer one.
    let canAddToChat: () -> Bool
}
