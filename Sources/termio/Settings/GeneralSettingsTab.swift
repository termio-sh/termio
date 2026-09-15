import SwiftUI

/// App-and-account settings: language, the GitHub integration, and the
/// usage-statistics opt-out. What is left is what belongs to the install and the
/// person, rather than to a machine or to the agents.
///
/// It used to also carry the `termio` command-line tool, the session-control
/// skill and the status hooks. Every one of those installs a file **on a
/// machine** — an agent's config directory, `/usr/local/bin` — so presented here
/// they read as app-wide and silently meant this Mac, which is why a VPS agent
/// had no hook status and nobody could see why. They now live on a machine's pane
/// (RFC §D8).
///
/// Task-completion notifications left too, to Settings ▸ Agents. A banner fires
/// because a *hook* fired, and the hook's switch was on another tab — so the two
/// halves of one feature sat where neither could say it depended on the other,
/// and a user who turned the banner on with the hooks off got a switch that did
/// nothing and no way to find out why.
struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LanguageRow()
            } header: {
                SectionHeaderLabel(title: localized("Language"))
            }
            Section {
                Toggle(isOn: $settings.githubIntegrationEnabled) {
                    SettingsLabel(
                        title: localized("GitHub"),
                        subtext: localized("Shows the Issues pane in the inspector for projects whose remote is on GitHub."),
                        titleFont: .headline
                    )
                }
                .toggleStyle(.switch)
            } header: {
                SectionHeaderLabel(title: localized("Integrations"))
            }
            Section {
                Toggle(isOn: $settings.analyticsEnabled) {
                    SettingsLabel(
                        title: localized("Usage statistics"),
                        subtext: localized("Sends one anonymous event a day so the project can count active installs. No project paths, no terminal contents, no account."),
                        titleFont: .headline
                    )
                }
                .toggleStyle(.switch)
            } header: {
                SectionHeaderLabel(title: localized("Privacy"))
            }
        }
        .formStyle(.grouped)
    }
}
