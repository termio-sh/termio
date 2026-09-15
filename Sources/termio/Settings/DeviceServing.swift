import CoreImage
import SwiftUI

/// Settings ▸ Mobile: what this Mac serves to phones — the companion port, the
/// pairing token, the QR carrying both, and the tunnel fronting them (RFC §D9).
///
/// This lived inside a machine's pane for a while, on the argument that every
/// line of it is a fact about *one machine*: this Mac's port, this Mac's token,
/// the phones paired to this Mac. The scope reading was right; the placement it
/// implied was not. Pairing is the one step a new user cannot guess at, and it
/// was three levels down a tab named after something else — so nobody found it.
///
/// The tab came back with a machine **picker** on top, and that was the wrong
/// repair: a picker is a mode, so the QR on screen belongs to a box the user has
/// to remember rather than read, and scanning the wrong one is silent. It also
/// still cost a row on the overwhelmingly common setup, where the only machine
/// serving anything is the Mac you are looking at.
///
/// So: this Mac's serving *is* the page, and a remote host is a row that pushes
/// its own. Same information, chosen by navigation instead of by a control, and
/// on a roster of one there is nothing extra on screen at all.
struct MobileSettingsTab: View {
    @ObservedObject var store: TermioStore

    /// The boxes other than this Mac that can serve a phone. Empty for most
    /// setups, and then the whole second section is absent.
    private var remoteHosts: [KnownDevice] {
        DeviceRoster.known(in: store).filter { !$0.isLocal }
    }

    var body: some View {
        Form {
            DeviceServingSection()
            if !remoteHosts.isEmpty {
                Section {
                    ForEach(remoteHosts) { machine in
                        NavigationLink(value: ServingRoute(key: machine.settingsKey)) {
                            HStack(spacing: 12) {
                                HugeIconView(icon: .serverStack, size: 15, color: .secondary)
                                    .frame(width: settingsRowIconWidth, alignment: .center)
                                Text(machine.name)
                                Spacer(minLength: 4)
                            }
                        }
                    }
                } header: {
                    SectionHeaderLabel(title: localized("Other machines"))
                } footer: {
                    Text(localized("A phone can attach straight to one of these instead, and keep working when this Mac is asleep."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationDestination(for: ServingRoute.self) { route in
            if let machine = remoteHosts.first(where: { $0.settingsKey == route.key }) {
                Form { RemotePairingSection(machine: machine) }
                    .formStyle(.grouped)
                    .navigationTitle(machine.name)
                    // Rebuilt per machine: the pane's whole state is one box's
                    // invite, and carrying the previous box's QR into the next
                    // would offer a working code for the wrong host.
                    .id(route.key)
            } else {
                ContentUnavailableView {
                    Text(localized("Host Unavailable"))
                } description: {
                    Text(localized("This host is no longer in your configuration."))
                }
            }
        }
    }
}

/// What a serving row pushes. Distinct from `DeviceRoute` so that a machine's
/// *pane* and a machine's *serving* can never be confused on the settings
/// window's shared navigation stack.
struct ServingRoute: Hashable {
    let key: String
}

/// The pane's one card: everything this Mac serves, under the machine's own name
/// so the scope is on screen rather than assumed.
struct DeviceServingSection: View {
    /// The reachable addresses, refreshed on open: Wi-Fi/Ethernet IPv4s
    /// first (the proven path), the Bonjour `.local` name as a fallback that
    /// survives DHCP lease changes.
    @State private var hosts: [String] = []
    @State private var selectedHost = ""
    @State private var copied = false
    @State private var inviteCopied = false
    @State private var confirmRotate = false
    @State private var token = PairingToken.current
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mobile = MobileAccess.shared
    /// Draft custom-relay fields, loaded from the persisted values on appear and
    /// written back only when the user commits them, so a half-typed command
    /// never becomes the live spec mid-keystroke.
    @State private var customCommand = ""
    @State private var customURLPattern = ""
    /// This Mac's session-host invite, minted by the daemon whenever the address
    /// it would carry changes. nil while direct attach is off, and between the
    /// address changing and the daemon answering.
    @State private var invite: RemotePairing.Invite?
    /// Why there is no invite, when there should be one. Rendered in the QR's
    /// place: an empty hero unit reads as a pane still loading.
    @State private var inviteFailure: String?
    /// The address the invite on screen was minted for, so a late answer for an
    /// address the pane has already moved off is dropped rather than shown.
    @State private var invitedBase: String?
    /// A mint is in flight. The tunnel reports `.starting` and then `.running`
    /// within a second or two, and each is a trigger — without this the pane
    /// forks two `termiod pair` processes for one address.
    @State private var minting = false

    /// A tunnel is up (or coming up): the QR carries the public URL, not the LAN
    /// address, and the LAN host picker no longer applies.
    private var onTunnel: Bool { tunnel.provider != .off }

    /// What the QR encodes: over the companion wire the socket address itself,
    /// carrying the token as the query the server reads; over the session
    /// protocol the `termio://device` invite the daemon minted, which is the
    /// same link a Linux box's QR carries.
    private var qrPayload: String {
        if mobile.attachesDirectly { return invite?.link ?? "" }
        return companionURL
    }

    /// The address under the QR — what the user copies and what they can check
    /// against the phone. The invite link is not it: it is a `termio://` URL
    /// with a secret in it, and it says nothing about where this Mac is.
    private var addressText: String {
        if mobile.attachesDirectly { return invite?.url ?? "" }
        return companionURL
    }

    private var companionURL: String {
        if case .running(let publicURL) = tunnel.status {
            let host = publicURL.absoluteString.replacingOccurrences(of: "https://", with: "wss://")
            return "\(host)/?t=\(token)"
        }
        return "ws://\(selectedHost):\(CompanionServer.defaultPort)/?t=\(token)"
    }

    /// Where a phone would reach this Mac's session host: the public URL while a
    /// tunnel is up, the selected LAN address otherwise. nil when there is no
    /// address to hand out, which is what stops a QR being minted for one.
    private var directBase: String? {
        if case .running(let publicURL) = tunnel.status {
            return publicURL.absoluteString
        }
        guard !selectedHost.isEmpty else { return nil }
        return "http://\(selectedHost):\(AppChannel.devicePort)"
    }

    private var tunnelRunning: Bool {
        if case .running = tunnel.status { return true }
        return false
    }

    /// One card, not the four this was the first time it was a tab: a card per
    /// lone switch read as four unrelated subjects. The switches stay rows with
    /// their sentence as subtext, which is the shape every settings row has.
    var body: some View {
        Section {
            Toggle(isOn: $mobile.isEnabled) {
                SettingsLabel(
                    title: localized("Mobile Access"),
                    subtext: localized("Turn off to disconnect your iPhone; pairing is kept."),
                    titleFont: .headline
                )
            }
            .toggleStyle(.switch)

            // Everything below only means anything while we're serving, so the
            // master switch reveals it — a dimmed, unscannable QR (and an
            // address nothing is listening on) is more misleading than absent.
            if mobile.isEnabled {
                Toggle(isOn: $mobile.attachesDirectly) {
                    SettingsLabel(
                        title: localized("Direct Attach"),
                        subtext: localized("Pairs your iPhone straight to this Mac's session host. Projects with nothing running don't appear yet."),
                        titleFont: .headline
                    )
                }
                .toggleStyle(.switch)
                // The switch changes what the QR means, so every phone paired
                // the other way is signed out by flipping it. Said here rather
                // than in a dialog: it is a fact about the switch, not a
                // consequence of one particular flip.
                footnote(localized("Paired iPhones must scan the code again after switching."))

                if hosts.isEmpty, !tunnelRunning {
                    footnote(localized("No network address found. Join a network, then reopen this pane."))
                } else if mobile.attachesDirectly, let inviteFailure {
                    footnote(inviteFailure)
                } else if mobile.attachesDirectly, invite == nil {
                    // A QR generated from an empty string is a scannable code
                    // for nothing, which is worse than the wait it hides.
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    // QR + its URL are one unit ("scan this, or copy the same
                    // thing") — kept in a single row so no divider splits them.
                    scanBlock
                }

                // One precise control: where the companion is reachable —
                // LAN only, or fronted by a named tunnel.
                Picker(localized("Tunnel"), selection: Binding(
                    get: { tunnel.provider },
                    set: { tunnel.setProvider($0) }
                )) {
                    ForEach(TunnelManager.Provider.allCases) { provider in
                        Text(Self.pickerLabel(provider)).tag(provider)
                    }
                }
                // The custom-relay editor: shown only when Custom is picked,
                // so the common third-party path stays uncluttered.
                if tunnel.provider == .custom { customTunnelEditor }
                if !onTunnel, hosts.count > 1 {
                    Picker(localized("Address"), selection: $selectedHost) {
                        ForEach(hosts, id: \.self) { host in
                            Text(host).tag(host)
                        }
                    }
                }
                if onTunnel { statusRow }

                LabeledContent {
                    // A rare, destructive maintenance action: it rests as a plain
                    // button and lets the confirmation dialog carry the red.
                    Button(localized("Rotate Token…")) { confirmRotate = true }
                        .confirmationDialog(
                            localized("Rotate the pairing token?"),
                            isPresented: $confirmRotate,
                            titleVisibility: .visible
                        ) {
                            Button(localized("Rotate Token"), role: .destructive) {
                                if mobile.attachesDirectly {
                                    refreshInvite(rotate: true)
                                } else {
                                    token = PairingToken.regenerate()
                                }
                            }
                            Button(localized("Cancel"), role: .cancel) {}
                        } message: {
                            Text(localized("Every paired iPhone is signed out and must re-scan the new QR to reconnect."))
                        }
                } label: {
                    SettingsLabel(
                        title: localized("Pairing Token"),
                        subtext: localized("Issues a new token and revokes every paired iPhone."),
                        titleFont: .headline
                    )
                }

                // The QR is unscannable without the companion installed, so the
                // one step that happens off this Mac stays on the pane. The
                // TestFlight icon does the explaining a sentence would: this
                // link leaves for Apple's beta installer.
                betaRow
            }
        } header: {
            // The machine, not "Serving": this pane answers for exactly one Mac,
            // and naming it is what keeps the settings from reading as app-wide.
            SectionHeaderLabel(title: KnownDevice.thisMac.name)
        } footer: {
            // Say plainly whose server the phone's traffic crosses, so the
            // "can I self-host the relay?" question is answered in the app: the
            // bundled providers all terminate on a third party, Custom is one
            // the user runs themselves.
            if mobile.isEnabled { footnote(tunnelFootnote) }
        }
        .onAppear {
            refreshHosts()
            let custom = CustomTunnel.current
            customCommand = custom.command
            customURLPattern = custom.urlPattern
            refreshInvite()
        }
        // The invite names one address, so it is re-minted whenever that address
        // could have changed: the switch, the picked LAN host, and the tunnel
        // coming up or going away.
        .onChange(of: mobile.attachesDirectly) { refreshInvite() }
        .onChange(of: selectedHost) { refreshInvite() }
        .onChange(of: tunnel.status) { refreshInvite() }
    }

    /// A provider's name as the picker shows it. `Spec.label` is the tool's own
    /// name, so it reaches the screen untranslated — right for the three brands
    /// (Tunelo, Cloudflare, ngrok are proper nouns everywhere), wrong for the
    /// two entries that are ordinary words. Those go through the catalog, which
    /// already carries "Custom" for the theme picker.
    private static func pickerLabel(_ provider: TunnelManager.Provider) -> String {
        switch provider {
        case .off: return localized("Off — LAN only")
        case .custom: return localized("Custom")
        case .tunelo, .cloudflared, .ngrok: return provider.label
        }
    }

    /// Whose server the phone's traffic crosses, phrased for the current
    /// selection: a self-hosted Custom relay, a bundled third-party tunnel, or
    /// LAN-only. Answers the "is the relay self-hostable?" question in the app.
    private var tunnelFootnote: String {
        if tunnel.provider == .custom {
            return localized("On iPhone, tap the Mac pill ▸ Scan QR Code. Traffic crosses the relay you run yourself — no third party in the path.")
        }
        if onTunnel {
            return localized("On iPhone, tap the Mac pill ▸ Scan QR Code. The tunnel address works from any network, and terminates on the provider's servers. Pick Custom to run your own relay instead.")
        }
        return localized("On iPhone, tap the Mac pill ▸ Scan QR Code. Both devices must share a LAN.")
    }

    /// Command + URL-pattern editor for a self-hosted relay. A run-any-command
    /// field is a code-execution surface, so it is fronted by an explicit
    /// warning rather than presented as a bare text field — the command runs on
    /// the user's own machine, with their own privileges, and only when they
    /// select Custom. Committed on submit (or via Apply) so a half-typed command
    /// never becomes the live spec.
    @ViewBuilder
    private var customTunnelEditor: some View {
        // The prompts stay untranslated: they are literal command lines and a
        // literal regex, not prose.
        TextField(localized("Command"), text: $customCommand, prompt: Text(verbatim: "cloudflared tunnel run --url http://127.0.0.1:{port} my-tunnel"))
            .font(.system(.callout, design: .monospaced))
            .onSubmit(commitCustomTunnel)
        TextField(localized("URL Pattern"), text: $customURLPattern, prompt: Text(verbatim: #"https://[a-z0-9-]+\.example\.com"#))
            .font(.system(.callout, design: .monospaced))
            .onSubmit(commitCustomTunnel)
        HStack {
            if !customURLPattern.isEmpty, !patternCompiles {
                Label(localized("Not a valid regular expression"), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button(localized("Apply"), action: commitCustomTunnel)
                .disabled(!customTunnelChanged)
        }
        footnote(localized("Runs on this Mac with your privileges when Custom is selected — no shell, arguments split on spaces. Use {port} for the companion port; the URL pattern is a regex matching the public https URL your relay prints."))
    }

    /// Whether the draft URL pattern is a compilable regex.
    private var patternCompiles: Bool {
        (try? NSRegularExpression(pattern: customURLPattern)) != nil
    }

    /// Whether the draft differs from what's persisted (drives the Apply button).
    private var customTunnelChanged: Bool {
        let saved = CustomTunnel.current
        return customCommand != saved.command || customURLPattern != saved.urlPattern
    }

    /// Persist the draft relay and, if Custom is the active provider, restart the
    /// tunnel so the new command takes effect. Trimmed so trailing whitespace
    /// doesn't smuggle an empty argv token in.
    private func commitCustomTunnel() {
        let command = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = customURLPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        CustomTunnel.save(command: command, urlPattern: pattern)
        customCommand = command
        customURLPattern = pattern
        if tunnel.provider == .custom { tunnel.reloadCustom() }
    }

    /// Where the iPhone app comes from: Apple's beta installer, named by its own
    /// icon so the destination is obvious before the click.
    private var betaRow: some View {
        HStack(spacing: 12) {
            if let icon = Self.testFlightIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsLabel(
                    title: localized("Termio for iPhone is in beta"),
                    subtext: localized("Open the invite on your iPhone to install it with TestFlight."),
                    titleFont: .headline
                )
                // The invite only installs anything on the phone, so opening it
                // here would land on the wrong device — copying is the whole
                // action: paste it into a message and open it on the iPhone.
                Button(inviteCopied ? localized("Copied") : localized("Copy Link")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.testFlightInvite, forType: .string)
                    inviteCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { inviteCopied = false }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private static let testFlightInvite = "https://testflight.apple.com/join/1Arf1UKR"

    /// TestFlight's own icon, bundled the way the agent favicons are. Missing
    /// art drops the image and keeps the rest of the row, rather than leaving a
    /// hole where the icon should be.
    private static let testFlightIcon: NSImage? = Bundle.termioResources
        .url(forResource: "testflight", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// Just the tunnel's health — the public host already shows in the address
    /// row above, so this line carries state, not a second copy of the URL.
    @ViewBuilder
    private var statusRow: some View {
        HStack {
            Text(localized("Status"))
            Spacer()
            switch tunnel.status {
            case .off:
                Text(localized("Starting…"))
                    .foregroundStyle(.secondary)
            case .installing:
                ProgressView().controlSize(.small)
                Text(localized("Installing \(tunnel.provider.binaryName)…"))
                    .foregroundStyle(.secondary)
            case .starting:
                ProgressView().controlSize(.small)
                Text(localized("Starting tunnel…"))
                    .foregroundStyle(.secondary)
            case .running:
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                Text(localized("Connected"))
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    /// The hero unit: the QR to scan with its own URL captioned directly beneath
    /// it. One row (no divider between) so the pair reads as a single thing.
    private var scanBlock: some View {
        VStack(spacing: 12) {
            if let qr = Self.qrImage(for: qrPayload) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .padding(10)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            addressRow
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// The scannable address as a value row: the URL leading (monospaced,
    /// middle-truncated so the token tail never pushes the button off-screen),
    /// a trailing Copy the way Apple pins Copy to a serial-number row.
    private var addressRow: some View {
        HStack(spacing: 8) {
            Text(addressText)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(addressText, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? localized("Copied") : localized("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .fixedSize()
        }
    }

    /// Asks this Mac's daemon for the invite that names `directBase`.
    ///
    /// `rotate` mints a fresh pairing token first, which is what Rotate Token
    /// does on this side: the secret belongs to the daemon, so revoking it is
    /// the daemon's verb rather than a defaults key this app clears.
    private func refreshInvite(rotate: Bool = false) {
        guard mobile.isEnabled, mobile.attachesDirectly, let base = directBase else {
            invite = nil
            inviteFailure = nil
            invitedBase = nil
            return
        }
        guard !minting else { return }
        guard rotate || base != invitedBase || invite == nil else { return }
        invitedBase = base
        minting = true
        Task {
            defer { minting = false }
            do {
                let minted = try await RemotePairing.localInvite(url: base, rotate: rotate)
                // The pane may have moved to another address while the daemon
                // was answering; a QR for the previous one would scan and then
                // reach nothing.
                guard base == invitedBase else { return }
                invite = minted
                inviteFailure = nil
            } catch let failure as RemotePairing.Failure {
                guard base == invitedBase else { return }
                invite = nil
                inviteFailure = failure.message
            } catch {
                guard base == invitedBase else { return }
                invite = nil
                inviteFailure = error.localizedDescription
            }
        }
    }

    private func refreshHosts() {
        hosts = Self.lanIPv4Addresses() + [Self.bonjourName()].compactMap { $0 }
        if !hosts.contains(selectedHost) {
            selectedHost = hosts.first ?? ""
        }
    }

    /// IPv4 addresses of the real interfaces (`en*` — Wi-Fi and Ethernet),
    /// skipping link-local self-assignments.
    private static func lanIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var cursor = list
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en"),
                  let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            if !ip.hasPrefix("169.254."), !addresses.contains(ip) {
                addresses.append(ip)
            }
        }
        return addresses
    }

    /// The `<name>.local` mDNS hostname, when the system reports one.
    private static func bonjourName() -> String? {
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? name : nil
    }

    private static func qrImage(for string: String) -> NSImage? { pairingQRImage(for: string) }
}

/// Plain CoreImage QR (medium error correction), rendered nearest-neighbor so
/// the modules stay sharp at display size. Shared by both arms of the pane:
/// this Mac encodes its own `ws://…` address, a remote box encodes the
/// `termio://device` invite its own `termiod pair` minted.
func pairingQRImage(for string: String) -> NSImage? {
    let filter = CIFilter(name: "CIQRCodeGenerator")
    filter?.setValue(Data(string.utf8), forKey: "inputMessage")
    filter?.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter?.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
}
