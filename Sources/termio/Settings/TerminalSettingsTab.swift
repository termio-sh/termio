import SwiftUI

/// Terminal behaviour that isn't about how it looks: how much history to keep and
/// what selecting text does.
struct TerminalSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Stepper(value: $settings.scrollbackMegabytes, in: 1...500, step: 1) {
                    Text(localized("Scrollback: \(settings.scrollbackMegabytes) MB"))
                }
            } header: {
                SectionHeaderLabel(title: localized("History"))
            } footer: {
                Text(localized("How much output each session keeps for scrolling back. Agents are verbose, so the default is generous."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(localized("Copy on select"), isOn: $settings.copyOnSelect)
            } header: {
                SectionHeaderLabel(title: localized("Selection"))
            } footer: {
                Text(localized("When on, selecting text copies it straight to the clipboard."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
