import SwiftUI

/// The size every picture on the Appearance page is drawn at. One size for the
/// mode, theme and tab choices, so their rows line up and read as one family.
enum ChoiceTileMetrics {
    static let size = CGSize(width: 136, height: 86)
    static let spacing: CGFloat = 20
}

/// A picture to click, with its name beneath and an ink ring when it is the
/// current choice: state is marked with ink, never hue. The ring is the only
/// mark; a radio beside the name said the same thing twice.
struct ChoiceTile<Picture: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let picture: () -> Picture

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                picture()
                    .frame(width: ChoiceTileMetrics.size.width, height: ChoiceTileMetrics.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.primary : Color.primary.opacity(0.15),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A graphical light/dark/system switcher, styled like macOS System Settings:
/// three small windows, each rendered in that appearance.
struct AppearanceModePicker: View {
    @Binding var selection: AppearanceMode

    var body: some View {
        HStack(spacing: ChoiceTileMetrics.spacing) {
            ForEach(AppearanceMode.allCases) { mode in
                ChoiceTile(title: mode.displayName, isSelected: mode == selection) {
                    selection = mode
                } picture: {
                    WindowMock(mode: mode)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

/// Vertical or horizontal tabs, as two miniature windows in the style of `AppearanceModePicker`.
struct TabLayoutPicker: View {
    @Binding var selection: TabLayout

    var body: some View {
        HStack(spacing: ChoiceTileMetrics.spacing) {
            ForEach(TabLayout.allCases) { layout in
                ChoiceTile(title: layout.displayName, isSelected: layout == selection) {
                    selection = layout
                } picture: {
                    TabLayoutMock(layout: layout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

/// A miniature window for `TabLayoutPicker`: vertical shows sessions nested under their group in
/// the sidebar; horizontal shows only groups there and the sessions as tabs across the top.
private struct TabLayoutMock: View {
    let layout: TabLayout
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let ground = dark ? Color(white: 0.18) : Color(white: 0.92)
        let card = dark ? Color(white: 0.11) : Color.white
        let line = dark ? Color(white: 0.36) : Color(white: 0.74)
        let faint = dark ? Color(white: 0.27) : Color(white: 0.84)
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 4, height: 4)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 4, height: 4)
                    Circle().fill(Color(red: 0.24, green: 0.79, blue: 0.33)).frame(width: 4, height: 4)
                }
                .padding(.bottom, 3)
                if layout == .vertical {
                    bar(line, 22); bar(faint, 18, indent: 4); bar(faint, 16, indent: 4)
                    bar(line, 20); bar(faint, 17, indent: 4)
                } else {
                    bar(line, 22); bar(line, 18); bar(line, 20)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 34)
            VStack(spacing: 3) {
                if layout == .horizontal {
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3).fill(line).frame(height: 8)
                        RoundedRectangle(cornerRadius: 3).fill(faint).frame(height: 8)
                        RoundedRectangle(cornerRadius: 3).fill(faint).frame(height: 8)
                    }
                }
                RoundedRectangle(cornerRadius: 4).fill(card)
            }
        }
        .padding(6)
        .background(ground)
    }

    private func bar(_ color: Color, _ width: CGFloat, indent: CGFloat = 0) -> some View {
        RoundedRectangle(cornerRadius: 1.5).fill(color)
            .frame(width: width, height: 3)
            .padding(.leading, indent)
    }
}

/// A miniature window drawn in a fixed light or dark appearance for the
/// `AppearanceModePicker` tiles. `.system` shows both, divided by a diagonal, the
/// way the macOS "Auto" swatch does.
private struct WindowMock: View {
    let mode: AppearanceMode

    var body: some View {
        switch mode {
        case .light:
            pane(dark: false)
        case .dark:
            pane(dark: true)
        case .system:
            ZStack {
                pane(dark: false)
                pane(dark: true).clipShape(DiagonalSplit())
            }
        }
    }

    private func pane(dark: Bool) -> some View {
        let body = dark ? Color(white: 0.13) : Color.white
        let bar = dark ? Color(white: 0.22) : Color(white: 0.93)
        let line = dark ? Color(white: 0.32) : Color(white: 0.82)
        return VStack(spacing: 0) {
            HStack(spacing: 3) {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 0.24, green: 0.79, blue: 0.33)).frame(width: 5, height: 5)
                Spacer()
            }
            .padding(.horizontal, 7)
            .frame(height: 17)
            .frame(maxWidth: .infinity)
            .background(bar)
            ZStack(alignment: .topLeading) {
                body
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 54, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 38, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 46, height: 5)
                }
                .padding(9)
            }
        }
    }
}

/// The trailing region of the "Auto" swatch: a slightly slanted vertical split so
/// the dark pane occupies the right side over the light pane.
private struct DiagonalSplit: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.58, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.width * 0.42, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
