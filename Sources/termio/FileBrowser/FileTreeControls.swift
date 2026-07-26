import Foundation
import SwiftUI

/// A quiet icon button for the explorer / Changes pane headers. The explorer's file
/// actions draw VS Code's own codicon glyphs (see `Codicon`) so the toolbar matches
/// VS Code; the Changes pane uses SF Symbols. Both render quiet `.secondary` at rest,
/// brightening to primary on hover over a faint rounded fill.
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
            icon
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
            // 1.5pt override matches the inspector switch's optical weight — the
            // size-derived default reads hairline next to SF Symbols.
            HugeIconView(icon: icon, size: 15, color: isHovering ? .primary : .secondary,
                         lineWidthOverride: 1.5)
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
}
