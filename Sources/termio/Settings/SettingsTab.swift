import SwiftUI

/// The top-level settings groups. Each is one icon-over-label button in the
/// `SettingsTabBar`. Not private so the launch reminder can open settings straight
/// to a given tab (see `AppDelegate.openSettings`).
enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance
    case interface
    case terminal
    case keyboard
    case agents
    case usage
    case mobile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .interface: return "Interface"
        case .terminal: return "Terminal"
        case .keyboard: return "Keyboard"
        case .agents: return "Agents"
        case .usage: return "Usage"
        case .mobile: return "Mobile"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "paintbrush"
        case .interface: return "sidebar.left"
        case .terminal: return "terminal"
        case .keyboard: return "keyboard"
        case .agents: return "sparkles"
        case .usage: return "gauge.medium"
        case .mobile: return "iphone"
        }
    }
}

/// Dia's settings navigation: a horizontal row of icon-over-label buttons sitting
/// just under the title bar. The selected tab tints its icon and label with the
/// accent color and floats a soft rounded highlight behind them.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                TabButton(tab: tab, isSelected: tab == selection) {
                    selection = tab
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 0)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    private struct TabButton: View {
        let tab: SettingsTab
        let isSelected: Bool
        let action: () -> Void

        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                VStack(spacing: 3) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 17, weight: .regular))
                        .frame(height: 22)
                    Text(tab.title)
                        .font(.system(size: 11))
                }
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 84, height: 48)
                .background { selectionBackground }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
        }

        /// The selected tab floats on a pure-white glass chip (Tahoe's Liquid Glass
        /// segmented look) with the icon and label tinted accent; an unselected tab
        /// stays flat, picking up a faint gray fill only under the cursor. On macOS
        /// before 26 the glass degrades to the closest translucent material.
        @ViewBuilder
        private var selectionBackground: some View {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            if isSelected {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.regular, in: shape)
                } else {
                    shape
                        .fill(.regularMaterial)
                        .overlay(shape.strokeBorder(.white.opacity(0.6), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.12), radius: 2.5, y: 1)
                }
            } else if isHovering {
                shape.fill(Color.primary.opacity(0.06))
            }
        }
    }
}
