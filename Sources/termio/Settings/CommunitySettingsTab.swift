import SwiftUI

/// Where the termio community lives: Discord, GitHub, and the WeChat group.
/// Pure links — nothing in this tab writes settings.
struct CommunitySettingsTab: View {
    var body: some View {
        Form {
            Section {
                CommunityLinkRow(
                    icon: .bubbleChat,
                    title: localized("Discord"),
                    subtext: localized("Chat with the developer and other users."),
                    buttonTitle: localized("Join"),
                    url: "https://discord.gg/H9DKVwsE5f"
                )
                CommunityLinkRow(
                    icon: .github,
                    title: localized("GitHub"),
                    subtext: localized("Termio is open source — star the repo, report bugs, and request features."),
                    buttonTitle: localized("Open"),
                    url: "https://github.com/termio-sh/termio"
                )
            } header: {
                SectionHeaderLabel(title: localized("Channels"))
            }
            if let qrImage = Self.wechatQR {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsLabel(
                            .huge(.bubbleChatAdd),
                            title: localized("WeChat group"),
                            subtext: localized("Scan the QR code with WeChat to join the Chinese community group.")
                        )
                        Image(nsImage: qrImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 4)
                } header: {
                    SectionHeaderLabel(title: localized("WeChat"))
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The WeChat group QR code, bundled as `wechat-community.png` in the app's
    /// resource assets. The whole section stays hidden when the asset isn't in
    /// the build, so a missing image never shows as an empty card.
    private static let wechatQR: NSImage? = Bundle.termioResources
        .url(forResource: "wechat-community", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
}

/// One community destination: the standard two-line label with a trailing
/// button that opens the link in the browser.
private struct CommunityLinkRow: View {
    let icon: HugeIcon
    let title: String
    let subtext: String
    let buttonTitle: String
    let url: String

    var body: some View {
        HStack(spacing: 10) {
            SettingsLabel(.huge(icon), title: title, subtext: subtext)
            Spacer()
            Button(buttonTitle) {
                guard let destination = URL(string: url) else { return }
                NSWorkspace.shared.open(destination)
            }
        }
    }
}
