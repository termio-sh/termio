import AppKit
import SwiftUI

struct AppearanceSettingsTab: View {
    @ObservedObject var settings: AppSettings
    /// Whether the theme store is up. Owned by `SettingsView` so a palette command
    /// can open Settings straight onto the sheet, and so dismissing it consumes
    /// that request instead of reopening on the next visit to this tab.
    @Binding var isBrowsingStore: Bool

    /// Names of the installed theme files, loaded from termio's `Themes` folder.
    /// Held in state so dropping in (or editing) a file and hitting Reload — or just
    /// reopening this tab — refreshes the pickers without a relaunch.
    @State private var userThemeNames: [String] = ThemeLibrary.userThemeNames
    /// The picker's search text at the moment it handed off to the store, so
    /// "dracula" typed into an empty picker lands on Dracula in the store.
    @State private var storeQuery = ""
    @State private var themesFolderError: String?

    var body: some View {
        Form {
            Section {
                AppearanceModePicker(selection: $settings.appearanceMode)
            } header: {
                SectionHeaderLabel(title: localized("Appearance"))
            } footer: {
                Text(localized("Pin Termio to a light or dark look, or follow the system. The light and dark terminal themes below apply to the matching appearance."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ThemePickerField(title: localized("Light"), prefersDark: false, selection: $settings.lightThemeName, userThemeNames: userThemeNames, onBrowseStore: browseStore)
                ThemePickerField(title: localized("Dark"), prefersDark: true, selection: $settings.darkThemeName, userThemeNames: userThemeNames, onBrowseStore: browseStore)
                HStack {
                    Button(localized("Browse Themes…")) { browseStore(query: "") }
                    Button(localized("Open Themes Folder…"), action: openThemesFolder)
                    Spacer()
                    if !userThemeNames.isEmpty {
                        Text(localized("\(userThemeNames.count) installed"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(localized("Reload"), action: reloadUserThemes)
                }
            } header: {
                SectionHeaderLabel(title: localized("Theme"))
            } footer: {
                Text(localized("Termio switches between these as macOS changes appearance; leave a slot on the default for Termio’s own canvas. Browse Themes installs one of 50 curated schemes, and any Ghostty-format file you drop into the Themes folder shows up here too."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                FontFamilyField(
                    title: localized("Family"),
                    prompt: localized("System monospace"),
                    families: InstalledFonts.monospaced,
                    previewSize: settings.fontSize,
                    monospacedDefault: true,
                    family: $settings.fontFamily
                )
                Stepper(value: $settings.fontSize, in: 8...32, step: 1) {
                    Text(localized("Size: \(Int(settings.fontSize)) pt"))
                }
                Stepper(value: $settings.codeLineHeight, in: 1.0...2.0, step: 0.1) {
                    Text(localized("Line height: \(String(format: "%.1f", settings.codeLineHeight))×"))
                }
                Toggle(localized("Thicken glyphs"), isOn: $settings.fontThicken)
            } header: {
                SectionHeaderLabel(title: localized("Terminal font"))
            } footer: {
                if settings.inheritsGhosttyDefaults {
                    Text(localized("Line height applies to the file editor and diffs; the terminal keeps the font’s own. Font and theme values you haven’t set here follow your Ghostty config."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(localized("Line height applies to the file editor and diffs; the terminal keeps the font’s own."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker(localized("Style"), selection: $settings.cursorStyle) {
                    ForEach(CursorStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Toggle(localized("Blink"), isOn: $settings.cursorBlink)
            } header: {
                SectionHeaderLabel(title: localized("Cursor"))
            }
            Section {
                Stepper(value: $settings.windowPadding, in: 0...40, step: 2) {
                    Text(localized("Padding: \(settings.windowPadding) pt"))
                }
                LabeledContent(localized("Opacity")) {
                    HStack(spacing: 8) {
                        Slider(value: $settings.backgroundOpacity, in: 0.2...1.0)
                            .frame(width: 160)
                        Text(settings.backgroundOpacity.formatted(.percent.precision(.fractionLength(0))))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Stepper(value: $settings.backgroundBlur, in: 0...60, step: 5) {
                    Text(localized("Blur: \(settings.backgroundBlur)"))
                }
                .disabled(settings.backgroundOpacity >= 1.0)
            } header: {
                SectionHeaderLabel(title: localized("Window"))
            } footer: {
                Text(localized("Opacity below 100% lets the desktop show through; blur softens it. The window stays solid at full opacity."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                FontFamilyField(
                    title: localized("Family"),
                    prompt: localized("System"),
                    families: InstalledFonts.all,
                    previewSize: settings.interfaceFontSize,
                    monospacedDefault: false,
                    family: $settings.interfaceFontFamily
                )
                Stepper(value: $settings.interfaceFontSize, in: 9...20, step: 1) {
                    Text(localized("Size: \(Int(settings.interfaceFontSize)) pt"))
                }
                LabeledContent(localized("Row padding")) {
                    HStack(spacing: 8) {
                        Slider(value: $settings.interfaceRowPadding, in: 0...12, step: 1)
                            .frame(width: 160)
                        Text(localized("\(Int(settings.interfaceRowPadding)) pt"))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } header: {
                SectionHeaderLabel(title: localized("Sidebar"))
            } footer: {
                Text(localized("The project and session list. Kept separate from the terminal font, and need not be monospaced."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadUserThemes)
        .sheet(isPresented: $isBrowsingStore) {
            ThemeStoreSheet(settings: settings, initialQuery: storeQuery, onLibraryChanged: reloadUserThemes)
        }
        .alert(
            localized("Couldn’t open the Themes folder"),
            isPresented: Binding(get: { themesFolderError != nil }, set: { if !$0 { themesFolderError = nil } }),
            presenting: themesFolderError
        ) { _ in
            Button(localized("OK"), role: .cancel) { themesFolderError = nil }
        } message: { message in
            Text(message)
        }
    }

    private func browseStore(query: String) {
        storeQuery = query
        isBrowsingStore = true
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
