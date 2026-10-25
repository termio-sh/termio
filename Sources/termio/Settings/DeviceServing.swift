import Combine
import CoreImage
import SwiftUI

/// This Mac's pairing state: the addresses a phone could dial, the network that
/// carries it, and the invite minted for that address. Held once for the app,
/// because two views show it. The Pairing section configures it, and the QR
/// sheet hangs off the pane's root, which also answers Pair iPhone… from the menu
/// bar. A `Section` deep in a lazy `Form` cannot own a sheet like that: it may
/// not exist yet when the request arrives.
@MainActor
final class PairingModel: ObservableObject {
    static let shared = PairingModel()

    /// The reachable addresses, refreshed on open: Wi-Fi/Ethernet IPv4s
    /// first (the proven path), the Bonjour `.local` name as a fallback that
    /// survives DHCP lease changes.
    @Published private(set) var hosts: [String] = []
    @Published var selectedHost = ""
    @Published private(set) var token = PairingToken.current
    /// This Mac's session-host invite, minted by the daemon whenever the address
    /// it would carry changes. nil while direct attach is off, and between the
    /// address changing and the daemon answering.
    @Published private(set) var invite: RemotePairing.Invite?
    /// Why there is no invite, when there should be one. Rendered in the QR's
    /// place: an empty hero unit reads as a pane still loading.
    @Published private(set) var inviteFailure: String?
    /// Where the tailnet reaches this Mac, read when the pane opens. nil off a
    /// tailnet, which keeps Tailscale out of the picker.
    @Published private(set) var tailnetAddress: String?
    @Published private(set) var tailnetRead = false
    /// The phone reaches this Mac across the user's tailnet. Not a tunnel
    /// provider: nothing is spawned, because both listeners already take every
    /// interface, so only the address in the QR changes.
    @Published var servesTailnet: Bool {
        didSet { UserDefaults.standard.set(servesTailnet, forKey: Self.servesTailnetKey) }
    }
    @Published var showsSheet = false

    /// The address the invite on screen was minted for, so a late answer for an
    /// address the pane has already moved off is dropped rather than shown.
    private var invitedBase: String?
    /// A mint is in flight. The tunnel reports `.starting` and then `.running`
    /// within a second or two, and each is a trigger — without this the pane
    /// forks two `termiod pair` processes for one address.
    private var minting = false
    /// What a refresh asked for while a mint was in flight. Run when the mint
    /// ends: dropping it left the sheet on a spinner, or on the old address.
    private var queuedRefresh: (rotate: Bool, force: Bool)?
    private var tailnetReads = 0
    private let tunnel = TunnelManager.shared
    private let mobile = MobileAccess.shared
    private var observers: Set<AnyCancellable> = []
    private static let servesTailnetKey = "companion.servesTailnet"

    private init() {
        servesTailnet = UserDefaults.standard.bool(forKey: Self.servesTailnetKey)
        // The invite names one address, so it is re-minted whenever that address
        // could have changed: the switches, the picked host, the tailnet, and the
        // tunnel coming up or going away. A publisher fires before its value
        // changes, so the refresh runs on the next turn, against the new value.
        let triggers: [AnyPublisher<Void, Never>] = [
            mobile.$isEnabled.map { _ in }.eraseToAnyPublisher(),
            mobile.$attachesDirectly.map { _ in }.eraseToAnyPublisher(),
            tunnel.$status.map { _ in }.eraseToAnyPublisher(),
            $selectedHost.map { _ in }.eraseToAnyPublisher(),
            $tailnetAddress.map { _ in }.eraseToAnyPublisher(),
            $servesTailnet.map { _ in }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .dropFirst(triggers.count)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshInvite() }
            .store(in: &observers)
    }

    /// Re-reads everything that can change while the pane is closed. The invite
    /// is minted again even for the same address: `termiod pair --rotate` run in
    /// a terminal revokes the token it carries without moving the address.
    func refresh() {
        token = PairingToken.current
        // The address read last time may belong to another tailnet account by
        // now, and a QR minted for it would save an address nothing answers on.
        tailnetAddress = nil
        tailnetRead = false
        refreshHosts()
        refreshInvite(force: true)
        // The section and the sheet both refresh on appear, and a stalled read
        // that finishes last must not replace the answer a later one gave.
        tailnetReads &+= 1
        let read = tailnetReads
        Task {
            let address = await Tailnet.ownAddress()
            guard read == tailnetReads else { return }
            tailnetAddress = address
            tailnetRead = true
        }
    }

    /// Rotate Token: on the session protocol the secret belongs to the daemon,
    /// so revoking it is the daemon's verb rather than a defaults key this app
    /// clears.
    func rotateToken() {
        if mobile.attachesDirectly {
            refreshInvite(rotate: true)
        } else {
            token = PairingToken.regenerate()
        }
    }

    /// A tunnel is up (or coming up): the QR carries the public URL, not the LAN
    /// address, and the LAN host picker no longer applies.
    var onTunnel: Bool { tunnel.provider != .off }

    var tunnelRunning: Bool {
        if case .running = tunnel.status { return true }
        return false
    }

    /// The host the QR names when no tunnel is up: this Mac's tailnet address, or
    /// the LAN address picked in the section.
    var servedHost: String {
        guard servesTailnet else { return selectedHost }
        guard let tailnetAddress else { return "" }
        return tailnetAddress.contains(":") ? "[\(tailnetAddress)]" : tailnetAddress
    }

    /// What the QR encodes: over the companion wire the socket address itself,
    /// carrying the token as the query the server reads; over the session
    /// protocol the `termio://device` invite the daemon minted, which is the
    /// same link a Linux box's QR carries.
    var qrPayload: String {
        if mobile.attachesDirectly { return invite?.link ?? "" }
        return companionURL
    }

    /// The invite as a link another Mac pastes, carrying this Mac's name so the
    /// other side can label it. nil until the daemon has minted one. The phone
    /// ignores the extra field.
    var macLink: String? {
        guard mobile.attachesDirectly, let invite,
              var components = URLComponents(string: invite.link) else { return nil }
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "name", value: name)]
        return components.string
    }

    /// The address under the QR — what the user copies and what they can check
    /// against the phone. The invite link is not it: it is a `termio://` URL
    /// with a secret in it, and it says nothing about where this Mac is.
    var addressText: String {
        if mobile.attachesDirectly { return invite?.url ?? "" }
        return companionURL
    }

    private var companionURL: String {
        if case .running(let publicURL) = tunnel.status {
            let host = publicURL.absoluteString.replacingOccurrences(of: "https://", with: "wss://")
            return "\(host)/?t=\(token)"
        }
        return "ws://\(servedHost):\(CompanionServer.defaultPort)/?t=\(token)"
    }

    /// Where a phone would reach this Mac's session host: the public URL while a
    /// tunnel is up, the selected address otherwise. nil when there is no
    /// address to hand out, which is what stops a QR being minted for one.
    private var directBase: String? {
        if case .running(let publicURL) = tunnel.status {
            return publicURL.absoluteString
        }
        guard !servedHost.isEmpty else { return nil }
        return "http://\(servedHost):\(AppChannel.devicePort)"
    }

    /// Asks this Mac's daemon for the invite that names `directBase`.
    ///
    /// `rotate` mints a fresh pairing token first, which is what Rotate Token
    /// does on this side.
    private func refreshInvite(rotate: Bool = false, force: Bool = false) {
        guard mobile.isEnabled, mobile.attachesDirectly, let base = directBase else {
            invite = nil
            inviteFailure = nil
            invitedBase = nil
            return
        }
        // A forced or rotating mint means the invite on screen may carry a token
        // that no longer works, so it stops being scannable until the new one.
        if force || rotate { invite = nil }
        guard !minting else {
            let queued = queuedRefresh
            queuedRefresh = (rotate || queued?.rotate == true, force || queued?.force == true)
            return
        }
        guard rotate || force || base != invitedBase || invite == nil else { return }
        invitedBase = base
        minting = true
        Task {
            defer {
                minting = false
                if let queued = queuedRefresh {
                    queuedRefresh = nil
                    refreshInvite(rotate: queued.rotate, force: queued.force)
                }
            }
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

}

/// What this Mac serves to phones — the companion port, the pairing token, the
/// network fronting them, and the way in to the QR (RFC §D9). A section of the
/// Server pane: a phone attaches to a port this Mac serves, so it is a fact
/// about the machine.
struct DeviceServingSection: View {
    @ObservedObject private var pairing = PairingModel.shared
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mobile = MobileAccess.shared
    @State private var inviteCopied = false
    @State private var confirmRotate = false
    /// Draft custom-relay fields, loaded from the persisted values on appear and
    /// written back only when the user commits them, so a half-typed command
    /// never becomes the live spec mid-keystroke.
    @State private var customCommand = ""
    @State private var customURLPattern = ""

    private var onTunnel: Bool { pairing.onTunnel }

    /// One picker for every way the phone reaches this Mac, so Tailscale sits
    /// beside the tunnels it replaces.
    private enum Reach: Hashable {
        case tailnet
        case tunnel(TunnelManager.Provider)
    }

    private var reach: Binding<Reach> {
        Binding(
            get: { pairing.servesTailnet && !onTunnel ? .tailnet : .tunnel(tunnel.provider) },
            set: { choice in
                switch choice {
                case .tailnet:
                    tunnel.setProvider(.off)
                    pairing.servesTailnet = true
                case .tunnel(let provider):
                    pairing.servesTailnet = false
                    tunnel.setProvider(provider)
                }
            }
        )
    }

    /// Configuration first, the code last. The QR is something you do once per
    /// phone, not a setting, so it sits behind Pair iPhone in a sheet, the way
    /// Rex puts "Pair Device with QR Code" behind a button. The pane then reads
    /// top to bottom as: is this Mac paired at all, which network carries it,
    /// pair a phone, and the rare maintenance.
    var body: some View {
        Section {
            Toggle(isOn: $mobile.isEnabled) {
                SettingsLabel(
                    title: localized("Allow Paired Devices"),
                    subtext: localized("Turn off to disconnect your iPhone; pairing is kept.")
                )
            }
            .toggleStyle(.switch)

            // Everything below only means anything while we're serving, so the
            // master switch reveals it — a dimmed, unscannable QR (and an
            // address nothing is listening on) is more misleading than absent.
            if mobile.isEnabled {
                // One precise control: where the phone reaches this Mac — the
                // LAN, the user's tailnet, or a named tunnel.
                Picker(localized("Network"), selection: reach) {
                    ForEach(TunnelManager.Provider.allCases) { provider in
                        Text(Self.pickerLabel(provider)).tag(Reach.tunnel(provider))
                        // Offered only on a tailnet, but kept while chosen so
                        // the picker never shows a selection it has no row for.
                        if provider == .off, pairing.tailnetAddress != nil || pairing.servesTailnet {
                            Text(verbatim: "Tailscale").tag(Reach.tailnet)
                        }
                    }
                }
                // The custom-relay editor: shown only when Custom is picked,
                // so the common third-party path stays uncluttered.
                if tunnel.provider == .custom { customTunnelEditor }
                if !onTunnel, !pairing.servesTailnet, pairing.hosts.count > 1 {
                    Picker(localized("Address"), selection: $pairing.selectedHost) {
                        ForEach(pairing.hosts, id: \.self) { host in
                            Text(host).tag(host)
                        }
                    }
                }
                if onTunnel { statusRow }
                if pairing.servesTailnet, !onTunnel { tailnetRow }

                LabeledContent {
                    Button(localized("Show QR Code…")) { pairing.showsSheet = true }
                } label: {
                    SettingsLabel(
                        title: localized("Pair a Device"),
                        subtext: localized("Scan the code with your iPhone, or copy its link to another Mac.")
                    )
                }

                Toggle(isOn: $mobile.attachesDirectly) {
                    SettingsLabel(
                        title: localized("Direct Attach"),
                        subtext: localized("Pairs your iPhone straight to this Mac's session host. Projects with nothing running don't appear yet.")
                    )
                }
                .toggleStyle(.switch)
                // The switch changes what the QR means, so every phone paired
                // the other way is signed out by flipping it. Said here rather
                // than in a dialog: it is a fact about the switch, not a
                // consequence of one particular flip.
                footnote(localized("Paired iPhones must scan the code again after switching."))

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
                                pairing.rotateToken()
                            }
                            Button(localized("Cancel"), role: .cancel) {}
                        } message: {
                            Text(localized("Every paired iPhone is signed out and must re-scan the new QR to reconnect."))
                        }
                } label: {
                    SettingsLabel(
                        title: localized("Pairing Token"),
                        subtext: localized("Issues a new token and revokes every paired iPhone.")
                    )
                }

                // The QR is unscannable without the companion installed, so the
                // one step that happens off this Mac stays on the pane. The
                // TestFlight icon does the explaining a sentence would: this
                // link leaves for Apple's beta installer.
                betaRow
            }
        } header: {
            SectionHeaderLabel(title: localized("Pairing"))
        } footer: {
            // Say plainly whose server the phone's traffic crosses, so the
            // "can I self-host the relay?" question is answered in the app: the
            // bundled providers all terminate on a third party, Custom is one
            // the user runs themselves.
            if mobile.isEnabled { footnote(networkFootnote) }
        }
        .onAppear {
            pairing.refresh()
            let custom = CustomTunnel.current
            customCommand = custom.command
            customURLPattern = custom.urlPattern
        }
    }

    /// Where Tailscale stands on this Mac, in the place a tunnel shows its
    /// status. The IP is the fact the phone is about to dial.
    @ViewBuilder
    private var tailnetRow: some View {
        LabeledContent(localized("Status")) {
            if let tailnetAddress = pairing.tailnetAddress {
                Text(localized("Connected · \(tailnetAddress)"))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if pairing.tailnetRead, FileManager.default.fileExists(atPath: Self.tailscaleApp.path) {
                Button(localized("Open Tailscale")) { NSWorkspace.shared.open(Self.tailscaleApp) }
            } else if pairing.tailnetRead {
                // A Homebrew install has no app to open; `tailscale up` is its own.
                Text(localized("Not Connected"))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private static let tailscaleApp = URL(fileURLWithPath: "/Applications/Tailscale.app")

    /// A provider's name as the picker shows it. `Spec.label` is the tool's own
    /// name, so it reaches the screen untranslated — right for the two brands
    /// (Cloudflare and ngrok are proper nouns everywhere), wrong for the
    /// two entries that are ordinary words. Those go through the catalog, which
    /// already carries "Custom" for the theme picker.
    private static func pickerLabel(_ provider: TunnelManager.Provider) -> String {
        switch provider {
        case .off: return localized("Local Network")
        case .custom: return localized("Custom")
        case .cloudflared, .ngrok: return provider.label
        }
    }

    /// Whose network the phone's traffic crosses, phrased for the current
    /// selection. Answers the "is the relay self-hostable?" question in the app.
    private var networkFootnote: String {
        if tunnel.provider == .custom {
            return localized("Traffic crosses the relay you run yourself — no third party in the path.")
        }
        if onTunnel {
            return localized("The tunnel address works from any network, and terminates on the provider's servers. Pick Custom to run your own relay instead.")
        }
        if pairing.servesTailnet {
            return localized("Works from any network while Tailscale is connected on both devices. Traffic stays on your tailnet.")
        }
        return localized("Your iPhone must be on the same network as this Mac.")
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
            .font(.system(.body, design: .monospaced))
            .onSubmit(commitCustomTunnel)
        TextField(localized("URL Pattern"), text: $customURLPattern, prompt: Text(verbatim: #"https://[a-z0-9-]+\.example\.com"#))
            .font(.system(.body, design: .monospaced))
            .onSubmit(commitCustomTunnel)
        HStack {
            if !customURLPattern.isEmpty, !patternCompiles {
                Label(localized("Not a valid regular expression"), systemImage: "exclamationmark.triangle.fill")
                    .font(.settingsDetail)
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
                    subtext: localized("Open the invite on your iPhone to install it with TestFlight.")
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

    private func footnote(_ text: String) -> some View { pairingFootnote(text) }

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
                    .font(.settingsDetail)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

}

/// The QR to scan and the link to copy, opened by Pair a Device in the section
/// and by Pair a Device… in the menu bar and the command palette.
struct PairingSheet: View {
    @ObservedObject private var pairing = PairingModel.shared
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mobile = MobileAccess.shared
    @State private var copied = false
    @State private var linkCopied = false

    /// The QR with its address, or the one reason there is none yet. Mobile
    /// Access switching off while it is open leaves nothing to scan, so the
    /// sheet says that instead of keeping a code for a server that stopped.
    var body: some View {
        VStack(spacing: 16) {
            Text(localized("Pair a Device"))
                .font(.headline)
            Group {
                if !mobile.isEnabled {
                    // Reached from the menu bar with serving off: the one step
                    // that makes a code possible is offered here, not described.
                    VStack(spacing: 10) {
                        footnote(localized("Turn on Allow Paired Devices to pair an iPhone."))
                        Button(localized("Turn On")) { mobile.isEnabled = true }
                    }
                } else if pairing.servesTailnet, !pairing.onTunnel, pairing.tailnetAddress == nil {
                    if pairing.tailnetRead {
                        footnote(localized("Tailscale isn’t connected on this Mac. Connect it, then reopen this pane."))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else if !pairing.servesTailnet, pairing.hosts.isEmpty, !pairing.tunnelRunning {
                    footnote(localized("No network address found. Join a network, then reopen this pane."))
                } else if pairing.onTunnel, !pairing.tunnelRunning {
                    // The QR would name the LAN until the tunnel prints its URL,
                    // and a phone that scans it in that second is paired to an
                    // address the picker says is not in use.
                    if case .failed(let message) = tunnel.status {
                        footnote(message)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else if mobile.attachesDirectly, let inviteFailure = pairing.inviteFailure {
                    footnote(inviteFailure)
                } else if mobile.attachesDirectly, pairing.invite == nil {
                    // A QR generated from an empty string is a scannable code
                    // for nothing, which is worse than the wait it hides.
                    ProgressView().controlSize(.small)
                } else {
                    scanBlock
                }
            }
            .frame(minHeight: 120)
            footnote(localized("On iPhone, tap the Mac pill ▸ Scan QR Code."))
                .multilineTextAlignment(.center)
            // Another Mac has no camera pointed at this screen, so it takes the
            // same invite as text. Only the session-host invite carries a Mac
            // can dial; the companion wire speaks the phone's protocol alone.
            if mobile.isEnabled, !mobile.attachesDirectly {
                footnote(localized("To pair another Mac, turn on Direct Attach."))
                    .multilineTextAlignment(.center)
            } else if mobile.isEnabled {
                footnote(localized("On another Mac, choose Remote Hosts ▸ ＋ ▸ Pair with a Mac…, then paste the link."))
                    .multilineTextAlignment(.center)
            }
            HStack {
                if mobile.isEnabled, mobile.attachesDirectly, let link = pairing.macLink {
                    Button(linkCopied ? localized("Copied") : localized("Copy Link")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                        linkCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { linkCopied = false }
                    }
                }
                Spacer()
                Button(localized("Done")) { pairing.showsSheet = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        // Opened from the menu bar, the sheet is the first thing to need fresh
        // addresses, before the section below it has appeared.
        .onAppear { pairing.refresh() }
    }

    /// The hero unit: the QR to scan with its own URL captioned directly beneath
    /// it. One row (no divider between) so the pair reads as a single thing.
    private var scanBlock: some View {
        VStack(spacing: 12) {
            if let qr = pairingQRImage(for: pairing.qrPayload) {
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
            Text(pairing.addressText)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pairing.addressText, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? localized("Copied") : localized("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .fixedSize()
        }
    }

    private func footnote(_ text: String) -> some View { pairingFootnote(text) }
}

private func pairingFootnote(_ text: String) -> some View {
    Text(text)
        .font(.settingsDetail)
        .foregroundStyle(.secondary)
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
