import AppKit
import SwiftUI

struct AppearanceSettingsTab: View {
    @ObservedObject var settings: AppSettings

    /// Names of the user's own theme files, loaded from termio's `Themes` folder.
    /// Held in state so dropping in (or editing) a file refreshes the theme rows
    /// without a relaunch.
    @State private var userThemeNames: [String] = ThemeLibrary.userThemeNames
    @State private var themesFolderError: String?
    @Environment(\.colorScheme) private var colorScheme

    /// Which theme is painting the window now. System follows the Settings
    /// window's own scheme, which follows the Mac's.
    private var showsDark: Bool {
        switch settings.appearanceMode {
        case .light: false
        case .dark: true
        case .system: colorScheme == .dark
        }
    }

    var body: some View {
        Form {
            // One card for how the terminal is painted: the mode as a word, then
            // each slot's themes as pictures, because a theme has to be seen to
            // be judged. Every row starts on the card's one leading edge.
            Section {
                LabeledContent(localized("Appearance")) {
                    Picker(localized("Appearance"), selection: $settings.appearanceMode) {
                        ForEach(AppearanceMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .segmentedChoice()
                }
                ThemeStrip(
                    title: localized("Light"), prefersDark: false, selection: $settings.lightThemeName,
                    userThemeNames: userThemeNames, onDuplicate: duplicate, isActive: !showsDark)
                ThemeStrip(
                    title: localized("Dark"), prefersDark: true, selection: $settings.darkThemeName,
                    userThemeNames: userThemeNames, onDuplicate: duplicate, isActive: showsDark)
                LabeledContent {
                    Button(localized("Open Themes Folder…"), action: openThemesFolder)
                } label: {
                    SettingsLabel(
                        title: localized("Custom themes"),
                        subtext: localized("Drop a Ghostty theme file into the Themes folder to add your own."))
                }
            } header: {
                SectionHeaderLabel(title: localized("Theme"))
            }
            Section {
                LabeledContent(localized("Tabs")) {
                    Picker(localized("Tabs"), selection: $settings.tabLayout) {
                        ForEach(TabLayout.allCases) { Text($0.displayName).tag($0) }
                    }
                    .segmentedChoice()
                }
                FontFamilyField(
                    title: localized("Sidebar font"),
                    prompt: localized("System"),
                    families: InstalledFonts.all,
                    previewSize: settings.interfaceFontSize,
                    monospacedDefault: false,
                    showsSample: false,
                    family: $settings.interfaceFontFamily
                )
                SettingsStepper(
                    title: localized("Sidebar text size"), value: $settings.interfaceFontSize, range: 9...20, step: 1,
                    display: localized("\(Int(settings.interfaceFontSize)) pt"))
                SettingsStepper(
                    title: localized("Sidebar row spacing"), value: $settings.interfaceRowPadding, range: 0...12, step: 1,
                    display: localized("\(Int(settings.interfaceRowPadding)) pt"))
            } header: {
                SectionHeaderLabel(title: localized("Layout"))
            }
            Section {
                Toggle(isOn: $settings.dimIgnoredFiles) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localized("Dim ignored files"))
                        Text(localized("Shows files and folders ignored by Git in a muted color."))
                            .font(.settingsDetail)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                SectionHeaderLabel(title: localized("File Tree"))
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadUserThemes)
        // A file dropped into the Themes folder shows up when the user comes back
        // from the Finder, so there is no Reload to press.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadUserThemes()
        }
        .alert(
            localized("Couldn’t change the Themes folder"),
            isPresented: Binding(get: { themesFolderError != nil }, set: { if !$0 { themesFolderError = nil } }),
            presenting: themesFolderError
        ) { _ in
            Button(localized("OK"), role: .cancel) { themesFolderError = nil }
        } message: { message in
            Text(message)
        }
    }

    /// Copies a theme into the Themes folder and selects it in the Finder, so the
    /// file the user asked for is in front of them rather than somewhere they now
    /// have to go looking.
    private func duplicate(_ name: String) {
        do {
            let url = try ThemeLibrary.duplicateToThemesFolder(named: name)
            reloadUserThemes()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            themesFolderError = error.localizedDescription
        }
    }

    private func openThemesFolder() {
        do {
            NSWorkspace.shared.open(try ThemeLibrary.ensureDirectoryExists())
        } catch {
            themesFolderError = error.localizedDescription
        }
    }

    /// Re-reads the Themes folder and republishes settings so any newly loaded or
    /// edited theme also re-styles the already-open terminals (the store and window
    /// both re-apply appearance on `objectWillChange`).
    private func reloadUserThemes() {
        userThemeNames = ThemeLibrary.reload().map(\.name).sorted { $0.lowercased() < $1.lowercased() }
        settings.objectWillChange.send()
    }
}

private extension View {
    /// One width for every segmented row, so their edges line up down the page
    /// with the other controls instead of stretching to fill what the label leaves.
    func segmentedChoice() -> some View {
        labelsHidden().pickerStyle(.segmented).frame(width: 240)
    }
}
