import CoreImage
import SwiftUI

/// Pairing page for the iPhone companion app: a QR code of the address the
/// companion server is serving on this Mac. The phone scans it once (session
/// list ▸ Mac pill ▸ Scan QR Code, or Settings ▸ Connectivity) and every
/// project and session rides that one link — no typing ws:// URLs on a phone
/// keyboard.
struct MobileSettingsTab: View {
    /// The reachable addresses, refreshed on open: Wi-Fi/Ethernet IPv4s
    /// first (the proven path), the Bonjour `.local` name as a fallback that
    /// survives DHCP lease changes.
    @State private var hosts: [String] = []
    @State private var selectedHost = ""
    @State private var copied = false
    @State private var confirmRotate = false
    @State private var token = PairingToken.current
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mobile = MobileAccess.shared

    /// A tunnel is up (or coming up): the QR carries the public URL, not the LAN
    /// address, and the LAN host picker no longer applies.
    private var onTunnel: Bool { tunnel.provider != .off }

    /// What the QR encodes: the tunnel's public URL while one is running,
    /// the LAN address otherwise — either way carrying the pairing token the
    /// server demands before serving anything.
    private var url: String {
        if case .running(let publicURL) = tunnel.status {
            let host = publicURL.absoluteString.replacingOccurrences(of: "https://", with: "wss://")
            return "\(host)/?t=\(token)"
        }
        return "ws://\(selectedHost):\(CompanionServer.defaultPort)/?t=\(token)"
    }

    private var tunnelRunning: Bool {
        if case .running = tunnel.status { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                Toggle("Mobile Access", isOn: $mobile.isEnabled)
            } footer: {
                footnote("Turn off to disconnect your iPhone; pairing is kept.")
            }

            // Everything below only means anything while we're serving, so the
            // master switch reveals it — a dimmed, unscannable QR (and an
            // address nothing is listening on) is more misleading than absent.
            if mobile.isEnabled {
                // One section, one job: connect a phone. The QR is the hero, so
                // it leads; the controls that rewrite it (Tunnel, LAN address)
                // sit as its immediate neighbours below — adjacent enough that
                // there's no "the QR above…" indirection to hold in your head.
                Section {
                    if hosts.isEmpty, !tunnelRunning {
                        footnote("No network address found. Join a network, then reopen this tab.")
                    } else {
                        // QR + its URL are one unit ("scan this, or copy the same
                        // thing") — kept in a single row so no divider splits them.
                        scanBlock
                    }

                    // One precise control: where the companion is reachable —
                    // LAN only, or fronted by a named tunnel.
                    Picker("Tunnel", selection: Binding(
                        get: { tunnel.provider },
                        set: { tunnel.setProvider($0) }
                    )) {
                        ForEach(TunnelManager.Provider.allCases) { provider in
                            Text(provider == .off ? "Off — LAN only" : provider.label).tag(provider)
                        }
                    }
                    if !onTunnel, hosts.count > 1 {
                        Picker("Address", selection: $selectedHost) {
                            ForEach(hosts, id: \.self) { host in
                                Text(host).tag(host)
                            }
                        }
                    }
                    if onTunnel { statusRow }
                } header: {
                    SectionHeaderLabel(title: "Connect iPhone")
                } footer: {
                    footnote(onTunnel
                        ? "On iPhone, tap the Mac pill ▸ Scan QR Code. The tunnel address works from any network."
                        : "On iPhone, tap the Mac pill ▸ Scan QR Code. Both devices must share a LAN.")
                }

                Section {
                    // A rare, destructive maintenance action: it rests as a plain
                    // button and lets the confirmation dialog carry the red.
                    Button("Rotate Pairing Token…") { confirmRotate = true }
                        .confirmationDialog(
                            "Rotate the pairing token?",
                            isPresented: $confirmRotate,
                            titleVisibility: .visible
                        ) {
                            Button("Rotate Token", role: .destructive) {
                                token = PairingToken.regenerate()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Every paired iPhone is signed out and must re-scan the new QR to reconnect.")
                        }
                } footer: {
                    footnote("Issues a new token and revokes every paired iPhone.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshHosts)
    }

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
            Text("Status")
            Spacer()
            switch tunnel.status {
            case .off:
                Text("Starting…")
                    .foregroundStyle(.secondary)
            case .installing:
                ProgressView().controlSize(.small)
                Text("Installing \(tunnel.provider.binaryName)…")
                    .foregroundStyle(.secondary)
            case .starting:
                ProgressView().controlSize(.small)
                Text("Starting tunnel…")
                    .foregroundStyle(.secondary)
            case .running:
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                Text("Connected")
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
            if let qr = Self.qrImage(for: url) {
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
            Text(url)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .fixedSize()
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
            let ip = String(cString: host)
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

    /// Plain CoreImage QR (medium error correction), rendered nearest-neighbor
    /// so the modules stay sharp at display size.
    private static func qrImage(for string: String) -> NSImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(string.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
