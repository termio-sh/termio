import SwiftUI

/// The app's own chrome (currently the project/session sidebar): a VSCode-style
/// font and density control, kept separate from the terminal's font so the two
/// can be tuned independently.
struct InterfaceSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                FontFamilyField(
                    title: "Family",
                    prompt: "System",
                    families: InstalledFonts.all,
                    previewSize: settings.interfaceFontSize,
                    monospacedDefault: false,
                    family: $settings.interfaceFontFamily
                )
                Stepper(value: $settings.interfaceFontSize, in: 9...20, step: 1) {
                    Text("Size: \(Int(settings.interfaceFontSize)) pt")
                }
            } header: {
                SectionHeaderLabel(title: "Sidebar font")
            } footer: {
                Text("Applies to the project and session list. Need not be monospaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Row padding") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.interfaceRowPadding, in: 0...12, step: 1)
                            .frame(width: 160)
                        Text("\(Int(settings.interfaceRowPadding)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } header: {
                SectionHeaderLabel(title: "Density")
            }
            Section {
                Picker("Sort", selection: $settings.projectSortOrder) {
                    ForEach(ProjectSortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
            } header: {
                SectionHeaderLabel(title: "Project order")
            } footer: {
                Text("How the sidebar orders projects (pinned always first). Fixed holds the order you added them; Recent Activity floats the active project to the top.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
