import AppKit
import SwiftUI

struct AppearanceSettingsTab: View {
    @ObservedObject var settings: AppSettings

    /// Names of the user's own theme files, loaded from termio's `Themes` folder.
    /// Held in state so dropping in (or editing) a file and hitting Reload — or just
    /// reopening this tab — refreshes the pickers without a relaunch.
    @State private var userThemeNames: [String] = ThemeLibrary.userThemeNames

    var body: some View {
        Form {
            Section {
                AppearanceModePicker(selection: $settings.appearanceMode)
            } header: {
                SectionHeaderLabel(title: "Appearance")
            } footer: {
                Text("Pin termio to a light or dark look, or follow the system. The light and dark terminal themes below apply to the matching appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                FontFamilyField(
                    title: "Family",
                    prompt: "System monospace",
                    families: InstalledFonts.monospaced,
                    previewSize: settings.fontSize,
                    monospacedDefault: true,
                    family: $settings.fontFamily
                )
                Stepper(value: $settings.fontSize, in: 8...32, step: 1) {
                    Text("Size: \(Int(settings.fontSize)) pt")
                }
                Toggle("Thicken glyphs", isOn: $settings.fontThicken)
            } header: {
                SectionHeaderLabel(title: "Font")
            }
            Section {
                Picker("Style", selection: $settings.cursorStyle) {
                    ForEach(CursorStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Toggle("Blink", isOn: $settings.cursorBlink)
            } header: {
                SectionHeaderLabel(title: "Cursor")
            }
            Section {
                Stepper(value: $settings.windowPadding, in: 0...40, step: 2) {
                    Text("Padding: \(settings.windowPadding) pt")
                }
                LabeledContent("Opacity") {
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
                    Text("Blur: \(settings.backgroundBlur)")
                }
                .disabled(settings.backgroundOpacity >= 1.0)
            } header: {
                SectionHeaderLabel(title: "Window")
            } footer: {
                Text("Opacity below 100% lets the desktop show through; blur softens it. The window stays solid at full opacity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ThemePickerField(title: "Light", selection: $settings.lightThemeName, userThemeNames: userThemeNames)
                ThemePickerField(title: "Dark", selection: $settings.darkThemeName, userThemeNames: userThemeNames)
                HStack {
                    Button("Open Themes Folder…", action: openThemesFolder)
                    Spacer()
                    if !userThemeNames.isEmpty {
                        Text("\(userThemeNames.count) custom")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Reload", action: reloadUserThemes)
                }
            } header: {
                SectionHeaderLabel(title: "Theme")
            } footer: {
                Text("termio switches between these as macOS changes appearance; leave a slot on the default for termio's own canvas. Drop Ghostty-format theme files into the Themes folder to add your own — they appear under “Custom.”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Open Config File…", action: openConfigFile)
                    Spacer()
                    Text(verbatim: "~/.config/termio/config")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                SectionHeaderLabel(title: "Config File")
            } footer: {
                Text("Every setting is stored in a plain-text config file you can edit directly (or with `termio config edit`). termio applies changes live; the options above are the common subset, but the file exposes more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadUserThemes)
    }

    private func openThemesFolder() {
        NSWorkspace.shared.open(ThemeLibrary.ensureDirectoryExists())
    }

    /// Opens the config file in the user's default editor for text files. It always
    /// exists by the time Settings can be shown (`AppSettings` seeds it at launch), but
    /// guard anyway so a missing file just no-ops rather than opening a blank Finder.
    private func openConfigFile() {
        let url = ConfigFile.url
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(ConfigFile.directory)
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
