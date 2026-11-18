import SwiftUI
import GhosttyTheme

/// A searchable theme picker with live color swatches.
///
/// The list is termio's default, the user's own theme files, and the built-in
/// schemes — everything the slot can actually paint, in one place. There is
/// nothing to install first, so a row and a working theme are the same thing.
///
/// A macOS-native pop-up button opening a popover with a search field and a real
/// `List`, rather than a flat `Picker`, so hover, keyboard navigation, selection
/// highlighting, and section headers all come from the system. Selecting applies
/// live: the terminal recolors as you browse.
struct ThemePickerField: View {
    let title: String
    /// Whether this slot renders in dark appearance. Explicit rather than read
    /// from the localized title, which is display-only.
    let prefersDark: Bool
    @Binding var selection: String
    /// The user's own theme names, passed in so the parent's reload state stays the
    /// single source of truth for what lives in the Themes folder.
    let userThemeNames: [String]
    /// Asks the parent to copy a built-in into the Themes folder and reveal it.
    /// The parent owns the reload and the error alert, so the picker only names
    /// the theme.
    let onDuplicate: (String) -> Void
    /// Theme files are a chore done rarely, so their actions live with the list
    /// they change rather than on the page. The parent owns the alert and reload.
    let onOpenFolder: () -> Void
    let onReload: () -> Void

    @State private var isPresented = false
    @State private var query = ""
    /// The List's live selection. Bound separately from `selection` so we can seed it
    /// on open and scroll to it; changes flow back out through `onChange`.
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    /// Whether this slot is the one painting the window now, given the
    /// appearance mode. Marked with ink, so the card the user is looking at
    /// in the terminal is the card they can tell apart here.
    var isActive = false

    var body: some View {
        // The picture and the name open the same picker, so they read as one
        // field. Current names the slot painting the window: every slot has a
        // theme selected, so a selection mark here would say nothing.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                if isActive {
                    Text(localized("Current"))
                        .font(.settingsDetail)
                        .foregroundStyle(.secondary)
                }
            }
            Button { isPresented = true } label: {
                ThemePreview(definition: ThemeLibrary.theme(named: selection), prefersDark: prefersDark)
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localized("\(title) theme"))
            Button { isPresented = true } label: {
                HStack(spacing: 4) {
                    Text(selection.isEmpty ? localized("Terminal default") : selection)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(appearanceMismatchHint ?? "")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 340, height: 440)
        .onAppear {
            highlighted = selection
            searchFocused = true
        }
        .onChange(of: highlighted) { _, new in
            // Apply live so the open terminals recolor as the user browses.
            selection = new ?? ""
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(localized("Search themes"), text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if hasResults {
            ScrollViewReader { proxy in
                List(selection: $highlighted) {
                    if query.isEmpty {
                        themeRow(name: "", display: localized("Terminal default"), definition: nil)
                        // Only the slot's own brightness: the Dark slot lists dark
                        // themes, the Light slot lists light ones, so a slot can never
                        // offer a theme that would render the wrong way.
                        if !slotUserNames.isEmpty {
                            Section(localized("Your themes")) { themeRows(slotUserNames) }
                        }
                        Section(localized("Built-in")) { themeRows(slotBuiltInNames) }
                        if !slotInheritedNames.isEmpty {
                            Section(localized("From your Ghostty config")) {
                                themeRows(slotInheritedNames)
                            }
                        }
                    } else {
                        Section(resultsLabel) { themeRows(filteredNames) }
                    }
                }
                .listStyle(.inset)
                .onAppear {
                    guard !selection.isEmpty else { return }
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        } else {
            emptyState
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let hint = appearanceMismatchHint {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                Text(hint)
                    .font(.settingsDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(selection.isEmpty ? localized("Terminal default") : selection)
                    .font(.settingsDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu(localized("Manage")) {
                Button(localized("Open Themes Folder…")) {
                    isPresented = false
                    onOpenFolder()
                }
                Button(localized("Reload"), action: onReload)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(localized("Drop a Ghostty theme file into the Themes folder to add your own."))
            // Return still closes it, but the brand marks nothing with accent blue.
            Button(localized("Done")) { isPresented = false }
                .buttonStyle(.bordered)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var appearanceMismatchHint: String? {
        guard let definition = ThemeLibrary.theme(named: selection) else { return nil }
        guard definition.isDark != prefersDark else { return nil }
        return definition.isDark
            ? localized("\(selection) is a dark theme in the \(title) slot.")
            : localized("\(selection) is a light theme in the \(title) slot.")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "paintpalette")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(localized("No theme matches “\(query)”"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func themeRows(_ names: [String]) -> some View {
        ForEach(names, id: \.self) { name in
            themeRow(name: name, definition: ThemeLibrary.theme(named: name))
                .contextMenu {
                    // Editing a built-in means owning a copy of it: the file lands
                    // in the Themes folder and shadows the scheme it came from.
                    Button(localized("Duplicate to Themes Folder")) {
                        isPresented = false
                        onDuplicate(name)
                    }
                }
        }
    }

    @ViewBuilder
    private func themeRow(name: String, display: String? = nil, definition: GhosttyThemeDefinition?) -> some View {
        HStack(spacing: 8) {
            Text(display ?? name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let definition {
                ThemeSwatch(definition: definition)
            }
        }
        .tag(name)
        .id(name)
    }

    private func matches(_ name: String) -> Bool {
        query.isEmpty || name.localizedCaseInsensitiveContains(query)
    }

    /// The user's own themes this slot can offer — only those matching the slot's
    /// brightness, so a slot can never apply one that renders the wrong way. Read
    /// from the parent's list rather than the library so a reload refreshes it.
    private var slotUserNames: [String] {
        userThemeNames.filter { ThemeLibrary.theme(named: $0)?.isDark == prefersDark }
    }

    /// The built-in schemes for this slot, minus any the user has shadowed with a
    /// file of their own — that file is already listed above, and one name cannot
    /// mean two themes.
    private var slotBuiltInNames: [String] {
        let owned = Set(slotUserNames)
        return ThemeLibrary.builtInNames(dark: prefersDark).filter { !owned.contains($0) }
    }

    /// The selection when it is neither a built-in nor a file — a theme inherited
    /// from the user's Ghostty config. It is painting the window, so it has to be
    /// visible in the list that controls it.
    private var slotInheritedNames: [String] {
        guard !selection.isEmpty,
              !slotUserNames.contains(selection),
              !slotBuiltInNames.contains(selection),
              ThemeLibrary.theme(named: selection)?.isDark == prefersDark
        else { return [] }
        return [selection]
    }

    private var slotNames: [String] { slotUserNames + slotBuiltInNames + slotInheritedNames }
    private var filteredNames: [String] { slotNames.filter(matches) }
    private var hasResults: Bool { query.isEmpty || !filteredNames.isEmpty }
    private var resultsLabel: String {
        let count = filteredNames.count
        return count == 1 ? localized("1 result") : localized("\(count) results")
    }
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

/// A few lines of a shell session drawn in a theme's own colors: the theme as it
/// will look in a pane, rather than a strip of chips to decode. Without a theme
/// ("Terminal default") it falls back to plain black on white, or white on black.
struct ThemePreview: View {
    let definition: GhosttyThemeDefinition?
    let prefersDark: Bool

    var body: some View {
        let background = definition.flatMap { Color(hex: $0.background) } ?? (prefersDark ? .black : .white)
        let foreground = definition.flatMap { Color(hex: $0.foreground) } ?? (prefersDark ? .white : .black)
        let cursor = definition?.cursorColor.flatMap { Color(hex: $0) } ?? foreground
        VStack(alignment: .leading, spacing: 3) {
            line([("~/termio", ansi(4, foreground)), (" git:(", foreground), ("main", ansi(1, foreground)), (")", foreground)])
            line([("✓ ", ansi(2, foreground)), ("42 passed", foreground), (" ", foreground), ("1 skipped", ansi(3, foreground))])
            HStack(spacing: 0) {
                Text(verbatim: "$ ").foregroundStyle(ansi(2, foreground))
                cursor.frame(width: 6, height: 12)
            }
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                ForEach(1...6, id: \.self) { slot in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ansi(slot, foreground))
                        .frame(width: 14, height: 4)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        // A theme preview is not text anyone reads; the name below it is.
        .accessibilityHidden(true)
    }

    private func ansi(_ slot: Int, _ fallback: Color) -> Color {
        definition?.palette[slot].flatMap { Color(hex: $0) } ?? fallback
    }

    private func line(_ runs: [(String, Color)]) -> some View {
        runs.reduce(Text(verbatim: "")) { text, run in
            text + Text(verbatim: run.0).foregroundColor(run.1)
        }
        .lineLimit(1)
    }
}
