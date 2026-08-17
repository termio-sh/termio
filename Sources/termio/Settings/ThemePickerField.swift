import SwiftUI
import GhosttyTheme

/// A searchable theme picker with live color swatches.
///
/// The list is termio's default plus the themes installed in the `Themes` folder
/// — what the user actually has, not a warehouse. Browsing the curated 50 is the
/// store's job (**Browse Themes…**), and an uninstalled name is deliberately
/// absent here: a slot resolves against the library only, so listing a name the
/// picker could not paint would be a dead row.
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
    /// The installed theme names, passed in so the parent's reload state stays the
    /// single source of truth for what lives in the Themes folder.
    let userThemeNames: [String]
    /// Opens the store, carrying whatever the user had typed here — an empty
    /// search for a name they haven't installed is exactly when they want it.
    let onBrowseStore: (String) -> Void

    @State private var isPresented = false
    @State private var query = ""
    /// The List's live selection. Bound separately from `selection` so we can seed it
    /// on open and scroll to it; changes flow back out through `onChange`.
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        LabeledContent(title) {
            Button { isPresented = true } label: {
                HStack(spacing: 8) {
                    if let definition = ThemeLibrary.theme(named: selection) {
                        ThemeSwatch(definition: definition, compact: true)
                    }
                    Text(selection.isEmpty ? localized("Terminal default") : selection)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 200)
            }
            .help(appearanceMismatchHint ?? "")
            .buttonStyle(.bordered)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) { popover }
        }
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
                        Section(localized("Installed")) { themeRows(slotInstalledNames) }
                    } else {
                        Section(resultsLabel) { themeRows(filteredInstalled) }
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
                    .foregroundStyle(.yellow)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(selection.isEmpty ? localized("Terminal default") : selection)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(localized("Browse Themes…")) {
                isPresented = false
                onBrowseStore(query)
            }
            Button(localized("Done")) { isPresented = false }
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
            Text(localized("No installed theme matches “\(query)”"))
                .foregroundStyle(.secondary)
            Button(localized("Browse Themes…")) {
                isPresented = false
                onBrowseStore(query)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func themeRows(_ names: [String]) -> some View {
        ForEach(names, id: \.self) { name in
            themeRow(name: name, definition: ThemeLibrary.theme(named: name))
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

    /// The installed themes this slot can offer — only those matching the slot's
    /// brightness, so a slot can never apply one that renders the wrong way.
    private var slotInstalledNames: [String] {
        userThemeNames.filter { ThemeLibrary.theme(named: $0)?.isDark == prefersDark }
    }

    private var filteredInstalled: [String] { slotInstalledNames.filter(matches) }
    private var hasResults: Bool { query.isEmpty || !filteredInstalled.isEmpty }
    private var resultsLabel: String {
        let count = filteredInstalled.count
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
