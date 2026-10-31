import AppKit
import SwiftUI

struct AppearanceSettingsTab: View {
    @ObservedObject var settings: AppSettings

    /// Names of the user's own theme files, loaded from termio's `Themes` folder.
    /// Held in state so dropping in (or editing) a file and hitting Reload — or just
    /// reopening this tab — refreshes the pickers without a relaunch.
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
            // One big picture on the page, the themes: they are the only choice
            // here that has to be seen to be judged. Everything else is a word.
            Section {
                LabeledContent(localized("Appearance")) {
                    Picker(localized("Appearance"), selection: $settings.appearanceMode) {
                        ForEach(AppearanceMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .segmentedChoice()
                }
            }
            Section {
                HStack(alignment: .top, spacing: 16) {
                    ThemePickerField(
                        title: localized("Light"), prefersDark: false, selection: $settings.lightThemeName,
                        userThemeNames: userThemeNames, onDuplicate: duplicate,
                        onOpenFolder: openThemesFolder, onReload: reloadUserThemes, isActive: !showsDark)
                    ThemePickerField(
                        title: localized("Dark"), prefersDark: true, selection: $settings.darkThemeName,
                        userThemeNames: userThemeNames, onDuplicate: duplicate,
                        onOpenFolder: openThemesFolder, onReload: reloadUserThemes, isActive: showsDark)
                }
                .padding(.vertical, 4)
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
                    family: $settings.interfaceFontFamily
                )
                SettingsStepper(
                    title: localized("Sidebar text size"), value: $settings.interfaceFontSize, range: 9...20, step: 1,
                    display: localized("\(Int(settings.interfaceFontSize)) pt"))
                LabeledContent(localized("Sidebar row spacing")) {
                    HStack(spacing: 8) {
                        Slider(value: $settings.interfaceRowPadding, in: 0...12, step: 1)
                            .frame(width: 160)
                        Text(localized("\(Int(settings.interfaceRowPadding)) pt"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
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
