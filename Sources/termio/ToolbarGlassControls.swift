import AppKit
import Combine
import SwiftUI

/// Geometry shared by every custom glass control in the unified toolbar. Keeping
/// the metrics here prevents an AppKit-hosted group from drifting away from the
/// SwiftUI inspector group by a pixel or two.
enum ToolbarGlassMetrics {
    static let controlHeight: CGFloat = 36
    static let trackPadding: CGFloat = 3
    static let itemSpacing: CGFloat = 2
    static let segmentWidth: CGFloat = 34
    static let containerSpacing: CGFloat = 4

    static var glyphHeight: CGFloat { controlHeight - 2 * trackPadding }
}

@MainActor
final class NavigatorToolbarActionsState: ObservableObject {
    @Published var groupingIsActive = false
}

/// AppKit owns the menus, while this SwiftUI control owns their shared glass
/// appearance. The handler keeps the menu anchored to the hosting view without
/// making the SwiftUI view aware of `NSToolbar` implementation details.
@MainActor
final class NavigatorToolbarActionHandler {
    weak var anchorView: NSView?
    var showSortMenu: ((NSView) -> Void)?
    var showNewMenu: ((NSView) -> Void)?

    func presentSortMenu() {
        guard let anchorView else { return }
        showSortMenu?(anchorView)
    }

    func presentNewMenu() {
        guard let anchorView else { return }
        showNewMenu?(anchorView)
    }
}

/// The navigator's two actions rendered with the exact glass-track vocabulary
/// used by the inspector control: a shared regular-material capsule, 2pt icon rhythm, and
/// a raised interactive pill for the active grouping state.
struct NavigatorActionsToolbar: View {
    @ObservedObject var state: NavigatorToolbarActionsState
    let actionHandler: NavigatorToolbarActionHandler
    @Namespace private var glassNamespace

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                glassControl
            } else {
                legacyControl
            }
        }
        .frame(height: ToolbarGlassMetrics.controlHeight)
        .fixedSize()
    }

    @available(macOS 26.0, *)
    private var glassControl: some View {
        GlassEffectContainer(spacing: ToolbarGlassMetrics.containerSpacing) {
            HStack(spacing: ToolbarGlassMetrics.itemSpacing) {
                actionButton(
                    symbol: "line.3.horizontal.decrease",
                    help: "Choose how projects are ordered",
                    selected: state.groupingIsActive,
                    action: actionHandler.presentSortMenu
                )
                actionButton(
                    symbol: "plus",
                    help: "New terminal or project",
                    selected: false,
                    action: actionHandler.presentNewMenu
                )
            }
            .padding(ToolbarGlassMetrics.trackPadding)
            // Match native single toolbar buttons' base material. The selected pill
            // below supplies the elevated state; a white tint here made the whole
            // multi-button track look heavier and more opaque than its neighbour.
            .glassEffect(.regular, in: .capsule)
        }
    }

    private var legacyControl: some View {
        HStack(spacing: ToolbarGlassMetrics.itemSpacing) {
            actionButton(
                symbol: "line.3.horizontal.decrease",
                help: "Choose how projects are ordered",
                selected: state.groupingIsActive,
                action: actionHandler.presentSortMenu
            )
            actionButton(
                symbol: "plus",
                help: "New terminal or project",
                selected: false,
                action: actionHandler.presentNewMenu
            )
        }
        .padding(ToolbarGlassMetrics.trackPadding)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func actionButton(
        symbol: String,
        help: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            icon(symbol)
                .background {
                    selectionBackground(selected: selected)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func selectionBackground(selected: Bool) -> some View {
        if #available(macOS 26.0, *) {
            if selected {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("navigatorSelection", in: glassNamespace)
            }
        } else {
            Capsule(style: .continuous)
                .fill(selected ? Color(nsColor: .controlColor) : .clear)
                .shadow(color: selected ? .black.opacity(0.18) : .clear, radius: 0.5, y: 0.5)
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: ToolbarGlassMetrics.segmentWidth, height: ToolbarGlassMetrics.glyphHeight)
    }
}
