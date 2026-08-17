import AppKit
import SwiftUI
import GhosttyTheme

/// The theme store: 50 curated Ghostty schemes, installed one file at a time.
///
/// A sheet over Settings rather than a fourth Settings tab, and deliberately not
/// a live preview — the sheet sits over the settings window, which sits over the
/// terminal, so previewing on highlight would recolor a pane the user cannot see.
/// Live preview stays in the command palette, over installed themes only.
///
/// Install writes one file into termio's `Themes` folder and then selects the
/// slot matching the theme's own brightness, so installing a dark theme from the
/// Light slot's Browse never trips the appearance-mismatch hint.
struct ThemeStoreSheet: View {
    @ObservedObject var settings: AppSettings
    /// The search text the picker was showing when it sent the user here, so a
    /// fruitless "dracula" in the picker lands on Dracula in the store.
    let initialQuery: String
    /// Lets the Appearance tab refresh its own copy of the installed names —
    /// the same state the Reload button owns.
    let onLibraryChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query: String
    @State private var installedNames: Set<String> = []
    @State private var pending: PendingAction?
    @State private var failureMessage: String?

    init(settings: AppSettings, initialQuery: String = "", onLibraryChanged: @escaping () -> Void) {
        self.settings = settings
        self.initialQuery = initialQuery
        self.onLibraryChanged = onLibraryChanged
        _query = State(initialValue: initialQuery)
    }

    /// A destructive step the user has to confirm, carrying the exact path so the
    /// question names the file it is about to overwrite or delete.
    private enum PendingAction {
        case replace(name: String, path: String)
        case removeEdited(name: String, path: String)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .onAppear(perform: refreshInstalled)
        .alert(
            pendingTitle,
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { action in
            switch action {
            case .replace(let name, _):
                Button(localized("Replace"), role: .destructive) { install(name, replacing: true) }
            case .removeEdited(let name, _):
                Button(localized("Remove"), role: .destructive) { remove(name) }
            }
            Button(localized("Cancel"), role: .cancel) { pending = nil }
        } message: { action in
            switch action {
            case .replace(_, let path):
                Text(localized("A file at \(path) already uses that name. Replacing it discards what is in it."))
            case .removeEdited(_, let path):
                Text(localized("The file at \(path) has been edited since it was installed. Removing it deletes those edits."))
            }
        }
        .alert(
            localized("Couldn’t change the Themes folder"),
            isPresented: Binding(get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } }),
            presenting: failureMessage
        ) { _ in
            Button(localized("OK"), role: .cancel) { failureMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private var pendingTitle: String {
        switch pending {
        case .replace(let name, _): return localized("Replace the theme file for “\(name)”?")
        case .removeEdited(let name, _): return localized("Remove “\(name)”?")
        case nil: return ""
        }
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(localized("Search themes"), text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        let dark = matching(dark: true)
        let light = matching(dark: false)
        if dark.isEmpty, light.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(localized("No themes match “\(query)”"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !dark.isEmpty {
                    Section(localized("Dark")) { rows(dark) }
                }
                if !light.isEmpty {
                    Section(localized("Light")) { rows(light) }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func rows(_ names: [String]) -> some View {
        ForEach(names, id: \.self) { name in
            if let definition = ThemeLibrary.storeTheme(named: name) {
                HStack(spacing: 10) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    ThemeSwatch(definition: definition)
                    actionButton(for: name)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func actionButton(for name: String) -> some View {
        if installedNames.contains(name) {
            Button(localized("Remove")) { beginRemove(name) }
                .frame(width: 72)
        } else {
            Button(localized("Install")) { beginInstall(name) }
                .frame(width: 72)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(localized("Open Themes Folder…"), action: openThemesFolder)
            Spacer(minLength: 8)
            Button(localized("Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Rows

    private func matching(dark: Bool) -> [String] {
        ThemeLibrary.storeCatalog.filter { name in
            guard ThemeLibrary.storeTheme(named: name)?.isDark == dark else { return false }
            return query.isEmpty || name.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Actions

    private func beginInstall(_ name: String) {
        do {
            try ThemeLibrary.install(named: name)
            finishInstall(name)
        } catch ThemeLibrary.InstallRefusal.alreadyInstalled(let url) {
            pending = .replace(name: name, path: url.path)
        } catch {
            failureMessage = error.localizedDescription
        }
    }

    private func install(_ name: String, replacing: Bool) {
        do {
            try ThemeLibrary.install(named: name, replacingExisting: replacing)
            finishInstall(name)
        } catch {
            failureMessage = error.localizedDescription
        }
    }

    /// Selects the installed theme in the slot its own brightness belongs to, not
    /// the slot Browse was opened from.
    private func finishInstall(_ name: String) {
        if let definition = ThemeLibrary.storeTheme(named: name) {
            if definition.isDark {
                settings.darkThemeName = name
            } else {
                settings.lightThemeName = name
            }
        }
        refreshInstalled()
    }

    private func beginRemove(_ name: String) {
        // An edited file is the user's work, so deleting it is a question, not a
        // side effect of a one-click Remove.
        if !ThemeLibrary.isPristine(installedTheme: name),
           let url = ThemeLibrary.fileURL(forInstalledTheme: name) {
            pending = .removeEdited(name: name, path: url.path)
            return
        }
        remove(name)
    }

    private func remove(_ name: String) {
        do {
            try ThemeLibrary.remove(named: name)
        } catch {
            failureMessage = error.localizedDescription
            return
        }
        // A slot pointing at a name that no longer resolves would paint nothing
        // and sit off every list; drop it back to termio's own canvas instead.
        if settings.lightThemeName == name { settings.lightThemeName = "" }
        if settings.darkThemeName == name { settings.darkThemeName = "" }
        refreshInstalled()
    }

    private func openThemesFolder() {
        do {
            NSWorkspace.shared.open(try ThemeLibrary.ensureDirectoryExists())
        } catch {
            failureMessage = error.localizedDescription
        }
    }

    private func refreshInstalled() {
        installedNames = Set(ThemeLibrary.reload().map(\.name))
        settings.objectWillChange.send()
        onLibraryChanged()
    }
}
