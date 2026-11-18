import SwiftUI
import GhosttyTheme

/// One slot's themes as a row of small pictures, each drawn in its own colors.
///
/// A theme is the one setting on the page that has to be seen to be chosen, so
/// the choices themselves are on the page: the slot's default, the user's own
/// theme files, then the built-in schemes. The row scrolls sideways and a tile
/// cut off at the edge says so. Clicking a tile applies it, and the open
/// terminals recolor at once.
///
/// This replaces a pop-up that opened a searchable list. The built-in set is a
/// few dozen names split over two slots, which is a row to look along, not a
/// list to search.
struct ThemeStrip: View {
    let title: String
    /// Whether this slot renders in dark appearance. Explicit rather than read
    /// from the localized title, which is display-only.
    let prefersDark: Bool
    @Binding var selection: String
    /// The user's own theme names, passed in so the parent's reload state stays the
    /// single source of truth for what lives in the Themes folder.
    let userThemeNames: [String]
    /// Asks the parent to copy a theme into the Themes folder and reveal it.
    /// The parent owns the reload and the error alert.
    let onDuplicate: (String) -> Void
    /// Whether this slot is the one painting the window now, given the
    /// appearance mode.
    var isActive = false

    /// Only the slot's own brightness, so a slot never offers a theme that would
    /// render the wrong way. A file of the user's shadows the built-in it was
    /// copied from: one name cannot mean two themes. The selection is added when
    /// nothing else lists it, such as a theme inherited from a Ghostty config,
    /// because the theme painting the window has to be visible in the row that
    /// controls it.
    private var names: [String] {
        let user = userThemeNames.filter { ThemeLibrary.theme(named: $0)?.isDark == prefersDark }
        let owned = Set(user)
        var names = [""] + user + ThemeLibrary.builtInNames(dark: prefersDark).filter { !owned.contains($0) }
        if !names.contains(selection) { names.append(selection) }
        return names
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                if isActive {
                    Text(localized("Current"))
                        .font(.settingsDetail)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: ThemeTileMetrics.spacing) {
                        ForEach(names, id: \.self) { tile($0) }
                    }
                    // Room for the overlay scroller, which otherwise draws across the labels.
                    .padding(.bottom, 10)
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .padding(.vertical, 4)
    }

    private func tile(_ name: String) -> some View {
        let selected = name == selection
        let display = name.isEmpty ? localized("Terminal default") : name
        let metrics = ThemeTileMetrics.self
        return Button { selection = name } label: {
            VStack(spacing: 6) {
                ThemeTile(definition: ThemeLibrary.theme(named: name), prefersDark: prefersDark)
                    .frame(width: metrics.width, height: metrics.height)
                    .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    // The ring stands off the picture by its own width, so it reads
                    // on a tile of any color. Ink, not accent blue: the brand marks
                    // state with weight.
                    .padding(metrics.ringGap)
                    .overlay(
                        RoundedRectangle(cornerRadius: metrics.cornerRadius + metrics.ringGap, style: .continuous)
                            .strokeBorder(Color.primary.opacity(selected ? 0.8 : 0), lineWidth: 2)
                    )
                Text(display)
                    .font(.system(size: 12))
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: metrics.width + 2 * metrics.ringGap)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(name)
        .help(display)
        .accessibilityLabel(display)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if !name.isEmpty {
                // Editing a built-in means owning a copy of it: the file lands
                // in the Themes folder and shadows the scheme it came from.
                Button(localized("Duplicate to Themes Folder")) { onDuplicate(name) }
            }
        }
    }
}

private enum ThemeTileMetrics {
    static let width: CGFloat = 104
    static let height: CGFloat = 66
    static let cornerRadius: CGFloat = 14
    static let ringGap: CGFloat = 2
    /// With the ring's gap on both sides, tiles sit 120pt apart.
    static let spacing: CGFloat = 12
}

/// A horizontal strip of a theme's signature colors — background, foreground, and a
/// few palette accents — so a theme's look is legible without rendering a full
/// terminal preview.
struct ThemeSwatch: View {
    let definition: GhosttyThemeDefinition
    /// The compact form (inside the pop-up button) shows fewer, smaller chips.
    var compact: Bool = false

    private var colors: [Color] {
        var result: [Color] = []
        if let background = Color(hex: definition.background) { result.append(background) }
        if let foreground = Color(hex: definition.foreground) { result.append(foreground) }
        // The ANSI accents people recognize a theme by: red, green, yellow, blue,
        // magenta, cyan (palette slots 1–6).
        for slot in 1...6 {
            if let hex = definition.palette[slot], let color = Color(hex: hex) {
                result.append(color)
            }
        }
        return result
    }

    var body: some View {
        let chipWidth: CGFloat = compact ? 5 : 9
        let chipHeight: CGFloat = compact ? 12 : 14
        HStack(spacing: 0) {
            ForEach(Array(colors.prefix(compact ? 4 : 8).enumerated()), id: \.offset) { _, color in
                color.frame(width: chipWidth, height: chipHeight)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}

/// A theme at thumbnail size: a word and a cursor in its own colors over its
/// six accents. Without a theme ("Terminal default") it is plain black on white,
/// or white on black.
struct ThemeTile: View {
    let definition: GhosttyThemeDefinition?
    let prefersDark: Bool

    var body: some View {
        let background = definition.flatMap { Color(hex: $0.background) } ?? (prefersDark ? .black : .white)
        let foreground = definition.flatMap { Color(hex: $0.foreground) } ?? (prefersDark ? .white : .black)
        let cursor = definition?.cursorColor.flatMap { Color(hex: $0) } ?? foreground
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(verbatim: "Aa ").foregroundStyle(foreground)
                Text(verbatim: "~/ ").foregroundStyle(ansi(4, foreground))
                cursor.frame(width: 7, height: 14)
            }
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                ForEach(1...6, id: \.self) { slot in
                    Capsule()
                        .fill(ansi(slot, foreground))
                        .frame(width: 11, height: 5)
                }
            }
        }
        .font(.system(size: 13, weight: .medium, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        // The name under the tile is what gets read.
        .accessibilityHidden(true)
    }

    private func ansi(_ slot: Int, _ fallback: Color) -> Color {
        definition?.palette[slot].flatMap { Color(hex: $0) } ?? fallback
    }
}
