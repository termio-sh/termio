import GhosttyTheme
import SwiftUI
import TermioShared
import UIKit

/// The app's settings sheet — ChatGPT-style two-level: this root is a small
/// menu of categories, each pushing its own page, plus an About group.
/// Connectivity leads (the Mac link is the app's lifeline — its row carries
/// the live link status inline, the only at-a-glance copy of it since the
/// session list dropped its device pill); Appearance carries the terminal look.
final class SettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case pages, about
    }

    private enum Row: Int, CaseIterable {
        case connectivity, appearance, terminalKeyboard, voice

        var title: String {
            switch self {
            case .connectivity: "Connectivity"
            case .appearance: "Appearance"
            case .terminalKeyboard: "Terminal Keyboard"
            case .voice: "Voice"
            }
        }

        /// The row glyph, from the shared Hugeicons set so the Settings page
        /// matches the tab pill and the Mac settings sidebar.
        var icon: HugeIcon {
            switch self {
            case .connectivity: .wireless
            case .appearance: .paintBrush
            case .terminalKeyboard: .keyboard
            case .voice: .voice
            }
        }

        func makePage() -> UIViewController {
            switch self {
            case .connectivity: ConnectivitySettingsViewController()
            case .appearance: AppearanceSettingsViewController()
            case .terminalKeyboard: TerminalKeyboardSettingsViewController()
            case .voice: VoiceSettingsViewController()
            }
        }
    }

    private enum AboutRow: Int, CaseIterable {
        case version, website, privacy
    }

    private static let websiteURL = URL(string: "https://termio.sh")!
    private static let privacyURL = URL(string: "https://termio.sh/privacy")!

    private var stateObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    /// False when the page lives as the home's Settings tab — nothing to
    /// dismiss there; true for the modal presentation (the unpaired zero
    /// state's "Connect a Mac" path).
    var showsCloseButton = true

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        // Tint the backdrop behind the inset cards to the terminal theme, so
        // Settings matches every other page when the theme changes (the cards
        // stay standard grouped-cells for legibility).
        themeObserver = installThemeBackdrop()
        if showsCloseButton {
            // A real glass ✕ at a Telegram-scale target, not the slim system
            // Done text item.
            // Telegram's sheet close: a 44pt glass circle with a ~17pt cross.
            let close = UIButton(type: .system)
            close.applyGlassSymbol("xmark", pointSize: 17)
            close.accessibilityLabel = "Close"
            close.addAction(UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }, for: .touchUpInside)
            NSLayoutConstraint.activate([
                close.widthAnchor.constraint(equalToConstant: 44),
                close.heightAnchor.constraint(equalToConstant: 44),
            ])
            let closeItem = UIBarButtonItem(customView: close)
            if #available(iOS 26.0, *) {
                // The bar wraps items in its own glass; the button already has one.
                closeItem.hidesSharedBackground = true
            }
            navigationItem.rightBarButtonItem = closeItem
        }
        // The Connectivity row's inline status tracks the live link.
        stateObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.tableView.reloadData()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Coming back from Connectivity after pairing/forgetting: refresh
        // the inline status.
        tableView.reloadData()
    }

    /// The Connectivity row's detail: a presence dot + the state. Shared with
    /// the Connectivity page's Status row so the two always read the same.
    static func linkStatus() -> NSAttributedString {
        let (color, text): (UIColor, String) = switch CompanionLink.state {
        case .unpaired: (.tertiaryLabel, "Not Paired")
        case .connecting: (.systemOrange, "Reconnecting…")
        case .connected: (.systemGreen, "Connected")
        }
        // The dot is a drawn image in an NSTextAttachment, not a glyph:
        // mixed-size text runs never sit still (a ● run smaller than the text
        // needs a hand-tuned baseline offset that drifts with every size
        // change), while an attachment centers exactly via its bounds — the
        // standard recipe: y = (capHeight − height) / 2. The text run carries
        // an explicit body font so the line metrics (and the row baseline)
        // are its own.
        let font = UIFont.preferredFont(forTextStyle: .body)
        let diameter: CGFloat = 11
        let dot = NSTextAttachment()
        dot.image = UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter))
            .image { _ in
                color.setFill()
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
            }
        dot.bounds = CGRect(x: 0, y: (font.capHeight - diameter) / 2, width: diameter, height: diameter)
        let status = NSMutableAttributedString(attachment: dot)
        status.append(NSAttributedString(string: " \(text)", attributes: [
            .foregroundColor: UIColor.secondaryLabel,
            .font: font,
        ]))
        return status
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == Section.pages.rawValue ? Row.allCases.count : AboutRow.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == Section.about.rawValue ? "About" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        switch Section(rawValue: indexPath.section) {
        case .pages:
            let row = Row.allCases[indexPath.row]
            cell.textLabel?.text = row.title
            cell.imageView?.image = row.icon.strokeImage(boxSize: 22)
            cell.imageView?.tintColor = .label
            cell.accessoryType = .disclosureIndicator
            if row == .connectivity {
                cell.detailTextLabel?.attributedText = Self.linkStatus()
            }
        default:
            switch AboutRow(rawValue: indexPath.row) {
            case .version:
                cell.textLabel?.text = "Version"
                cell.selectionStyle = .none
                cell.detailTextLabel?.text =
                    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            case .website:
                cell.textLabel?.text = "Website"
                cell.detailTextLabel?.text = "termio.sh"
            case .privacy, nil:
                cell.textLabel?.text = "Privacy Policy"
            }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .pages:
            navigationController?.pushViewController(Row.allCases[indexPath.row].makePage(), animated: true)
        default:
            switch AboutRow(rawValue: indexPath.row) {
            case .website: UIApplication.shared.open(Self.websiteURL)
            case .privacy: UIApplication.shared.open(Self.privacyURL)
            default: break
            }
        }
    }
}

// MARK: - Appearance

/// The terminal appearance controls — the mobile counterpart of the Mac's
/// Settings window: appearance mode, the light/dark theme pair, and font
/// size. Every change lands in `MobileSettings` and applies to open
/// terminals live.
final class AppearanceSettingsViewController: UITableViewController {
    private let settings = MobileSettings.shared

    private enum Row: Int, CaseIterable {
        case appearance, lightTheme, darkTheme, fontSize
    }

    private var themeObserver: NSObjectProtocol?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Appearance"
        themeObserver = installThemeBackdrop()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Coming back from a theme picker: refresh the theme rows' values.
        tableView.reloadData()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Terminal"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // A static four-row form; building cells directly beats reuse plumbing.
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        switch Row(rawValue: indexPath.row) {
        case .appearance:
            cell.textLabel?.text = "Appearance"
            cell.selectionStyle = .none
            let modes = MobileSettings.AppearanceMode.allCases
            let control = UISegmentedControl(items: modes.map(\.label))
            control.selectedSegmentIndex = modes.firstIndex(of: settings.appearanceMode) ?? 0
            control.addAction(UIAction { [weak self, weak control] _ in
                guard let self, let control else { return }
                settings.appearanceMode = modes[control.selectedSegmentIndex]
            }, for: .valueChanged)
            control.sizeToFit()
            cell.accessoryView = control
        case .lightTheme:
            cell.textLabel?.text = "Light Theme"
            cell.detailTextLabel?.text = settings.lightThemeName
            cell.accessoryType = .disclosureIndicator
        case .darkTheme:
            cell.textLabel?.text = "Dark Theme"
            cell.detailTextLabel?.text = settings.darkThemeName
            cell.accessoryType = .disclosureIndicator
        case .fontSize, nil:
            cell.textLabel?.text = "Font Size"
            cell.detailTextLabel?.text = Self.pointsLabel(settings.fontSize)
            cell.selectionStyle = .none
            let stepper = UIStepper()
            stepper.minimumValue = MobileSettings.fontSizeRange.lowerBound
            stepper.maximumValue = MobileSettings.fontSizeRange.upperBound
            stepper.stepValue = 1
            stepper.value = settings.fontSize
            stepper.addAction(UIAction { [weak self, weak cell, weak stepper] _ in
                guard let self, let stepper else { return }
                settings.fontSize = stepper.value
                cell?.detailTextLabel?.text = Self.pointsLabel(stepper.value)
            }, for: .valueChanged)
            cell.accessoryView = stepper
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Row(rawValue: indexPath.row) {
        case .lightTheme:
            navigationController?.pushViewController(ThemePickerViewController(slot: .light), animated: true)
        case .darkTheme:
            navigationController?.pushViewController(ThemePickerViewController(slot: .dark), animated: true)
        default:
            break
        }
    }

    private static func pointsLabel(_ size: Double) -> String {
        "\(Int(size)) pt"
    }
}

// MARK: - Terminal keyboard

/// Which control keys the accessory bar carries — a toggle per catalog
/// entry (curated Claude Code shortcuts), not a free-form binding editor.
/// The bar itself observes `MobileSettings.didChange` and rebuilds, so a flip
/// here is live on its next appearance.
final class TerminalKeyboardSettingsViewController: UITableViewController {
    private let settings = MobileSettings.shared

    private var themeObserver: NSObjectProtocol?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Terminal Keyboard"
        themeObserver = installThemeBackdrop()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        TerminalKeyCatalog.all.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Control Keys"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Keys on the control bar above the system keyboard. "
            + "Esc and the arrows are always there; "
            + "hold esc for esc-esc (Claude Code's rewind menu)."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let key = TerminalKeyCatalog.all[indexPath.row]
        cell.selectionStyle = .none
        cell.textLabel?.text = key.title
        cell.textLabel?.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        cell.detailTextLabel?.text = key.detail
        cell.detailTextLabel?.textColor = .secondaryLabel

        let toggle = UISwitch()
        toggle.isOn = settings.terminalKeyIDs.contains(key.id)
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let toggle else { return }
            var enabled = Set(settings.terminalKeyIDs)
            if toggle.isOn { enabled.insert(key.id) } else { enabled.remove(key.id) }
            // Stored in catalog order so the keyboard rows never reshuffle.
            settings.terminalKeyIDs = TerminalKeyCatalog.all.map(\.id).filter(enabled.contains)
        }, for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }
}

// MARK: - Voice

/// Voice dictation setup: the master switch, the transcription provider, and
/// that provider's API key. With voice on, holding the terminal keyboard's mic
/// key dictates a prompt. Each provider keeps its own key in the Keychain (via
/// `VoiceDictation`), so switching providers never loses the other's key.
final class VoiceSettingsViewController: UITableViewController {
    private let settings = MobileSettings.shared

    private enum Section: Int, CaseIterable {
        case voice, provider, key
    }

    private enum KeyRow: Int, CaseIterable {
        case apiKey, remove
    }

    /// The provider whose key the Key section is showing — the current choice.
    private var provider: TranscriptionProvider { settings.transcriptionProvider }

    private var themeObserver: NSObjectProtocol?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Voice"
        themeObserver = installThemeBackdrop()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .voice, .provider, nil: 1
        // "Remove" only earns a row once the selected provider has a key.
        case .key: VoiceDictation.hasAPIKey(for: provider) ? KeyRow.allCases.count : 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .provider: "Transcription"
        // The key belongs to the chosen provider — name it so the two read together.
        case .key: provider.displayName
        default: nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .voice, nil:
            "Hold the mic key on the terminal keyboard to dictate a prompt — "
                + "release to send it, slide up to cancel."
        case .provider:
            "Which service transcribes your voice. Each keeps its own key."
        case .key:
            provider.keyFooter
                + " Your key stays in this device's Keychain and is used only for transcription."
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .voice, nil:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = "Voice Input"
            cell.selectionStyle = .none
            let toggle = UISwitch()
            toggle.isOn = settings.pushToTalkEnabled
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                settings.pushToTalkEnabled = toggle.isOn
            }, for: .valueChanged)
            cell.accessoryView = toggle
            return cell
        case .provider:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = "Provider"
            cell.selectionStyle = .none
            let providers = TranscriptionProvider.allCases
            let control = UISegmentedControl(items: providers.map(\.displayName))
            control.selectedSegmentIndex = providers.firstIndex(of: provider) ?? 0
            control.addAction(UIAction { [weak self, weak control] _ in
                guard let self, let control else { return }
                settings.transcriptionProvider = providers[control.selectedSegmentIndex]
                // The Key section below tracks the selected provider.
                tableView.reloadData()
            }, for: .valueChanged)
            control.sizeToFit()
            cell.accessoryView = control
            return cell
        case .key:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            let isSet = VoiceDictation.hasAPIKey(for: provider)
            switch KeyRow(rawValue: indexPath.row) {
            case .apiKey, nil:
                cell.textLabel?.text = "API Key"
                cell.detailTextLabel?.text = isSet ? "•••• Set" : "Not Set"
                cell.detailTextLabel?.textColor = isSet ? .systemGreen : .secondaryLabel
                cell.accessoryType = .disclosureIndicator
            case .remove:
                cell.textLabel?.text = "Remove Key"
                cell.textLabel?.textColor = .systemRed
            }
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .key else { return }
        switch KeyRow(rawValue: indexPath.row) {
        case .apiKey, nil:
            presentKeyEditor()
        case .remove:
            VoiceDictation.setAPIKey(nil, for: provider)
            tableView.reloadData()
        }
    }

    private func presentKeyEditor() {
        let provider = self.provider
        let alert = UIAlertController(
            title: "\(provider.displayName) API Key",
            message: "Paste your key. It's stored in this device's Keychain.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = provider.keyPlaceholder
            field.isSecureTextEntry = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.text = VoiceDictation.apiKey(for: provider)
        }
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            VoiceDictation.setAPIKey(alert?.textFields?.first?.text, for: provider)
            self?.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - Connectivity

/// The Mac pairing page: live link status (the same state as the sidebar's
/// presence dot), the saved address, and forget. The sidebar owns the socket;
/// this page reads `CompanionLink.state` and posts `pairingDidChange` for the
/// sidebar to act on.
final class ConnectivitySettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case mac, forget
    }

    private enum MacRow: Int, CaseIterable {
        case status, address, scan
    }

    private var stateObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Connectivity"
        themeObserver = installThemeBackdrop()
        stateObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.tableView.reloadData()
        }
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        // Nothing to forget while unpaired. Live state, not the saved URL:
        // dev runs pair via a launch arg without touching defaults.
        CompanionLink.state == .unpaired && CompanionLink.savedURL == nil
            ? 1 : Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == Section.mac.rawValue ? MacRow.allCases.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == Section.mac.rawValue ? "Mac" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == Section.mac.rawValue else { return nil }
        return "Pair once with the address termio on your Mac is serving — every project and session rides this one link."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        // Every row leads with a Hugeicons glyph, matching the root Settings page.
        cell.imageView?.tintColor = .label
        switch (Section(rawValue: indexPath.section), MacRow(rawValue: indexPath.row)) {
        case (.mac, .status):
            cell.textLabel?.text = "Status"
            cell.imageView?.image = HugeIcon.link.strokeImage(boxSize: 22)
            cell.selectionStyle = .none
            // The dot rides right before the state word ("● Connected"), not
            // out front as the row's icon — same rendering as the root page.
            cell.detailTextLabel?.attributedText = SettingsViewController.linkStatus()
        case (.mac, .address):
            cell.accessoryType = .disclosureIndicator
            if let url = CompanionLink.savedURL {
                cell.textLabel?.text = "Address"
                cell.imageView?.image = HugeIcon.network.strokeImage(boxSize: 22)
                // Host + port only: the scheme is noise and the pairing token
                // riding the query is a secret — and the full URL overflows the
                // row. The edit alert still carries the complete URL.
                cell.detailTextLabel?.text = Self.displayAddress(url)
                cell.detailTextLabel?.lineBreakMode = .byTruncatingMiddle
            } else {
                // Empty state: a plain "Not Set" is a dead end. Make the row
                // the invitation to type the address itself.
                cell.textLabel?.text = "Enter Address Manually"
                cell.imageView?.image = HugeIcon.keyboard.strokeImage(boxSize: 22)
            }
        case (.mac, .scan):
            cell.textLabel?.text = "Scan QR Code"
            cell.imageView?.image = HugeIcon.qrCode.strokeImage(boxSize: 22)
        default:
            cell.textLabel?.text = "Forget This Mac"
            cell.textLabel?.textColor = .systemRed
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (Section(rawValue: indexPath.section), MacRow(rawValue: indexPath.row)) {
        case (.mac, .address):
            presentEditAddress()
        case (.mac, .scan):
            presentScanner()
        case (.forget, _):
            forgetMac()
        default:
            break
        }
    }

    /// "ws://studio.local:8787?t=<token>" → "studio.local:8787".
    private static func displayAddress(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        let port = url.port.map { ":\($0)" } ?? ""
        return host + port
    }

    // MARK: - Actions

    private func presentEditAddress() {
        let alert = UIAlertController(
            title: "Connect to Mac",
            message: "The address termio on your Mac is serving.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "ws://mac-hostname:8787"
            field.text = CompanionLink.savedURL?.absoluteString
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self, weak alert] _ in
            guard let raw = alert?.textFields?.first?.text,
                  let url = CompanionLink.normalize(raw) else { return }
            UserDefaults.standard.set(url.absoluteString, forKey: CompanionLink.defaultsKey)
            NotificationCenter.default.post(name: CompanionLink.pairingDidChange, object: nil)
            self?.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    /// Camera pairing — same save/notify path as typing the address, minus
    /// the typing. The QR lives on the Mac's Settings ▸ Mobile tab.
    private func presentScanner() {
        let scanner = QRScannerViewController()
        scanner.onCode = { [weak self] code in
            guard let url = CompanionLink.normalize(code) else { return }
            UserDefaults.standard.set(url.absoluteString, forKey: CompanionLink.defaultsKey)
            NotificationCenter.default.post(name: CompanionLink.pairingDidChange, object: nil)
            self?.tableView.reloadData()
        }
        present(UINavigationController(rootViewController: scanner), animated: true)
    }

    private func forgetMac() {
        UserDefaults.standard.removeObject(forKey: CompanionLink.defaultsKey)
        NotificationCenter.default.post(name: CompanionLink.pairingDidChange, object: nil)
        tableView.reloadData()
    }
}

// MARK: - Theme picker

/// Full-catalog picker for one slot of the theme pair: the curated popular
/// shortlist up top (same names the Mac picker leads with — dark schemes for
/// the Dark slot, light for Light), the whole Ghostty catalog underneath,
/// and a search field over all of it. Picking a row applies immediately —
/// no confirm step, matching the Mac's live-preview behavior.
final class ThemePickerViewController: UITableViewController {
    enum Slot {
        case light, dark
    }

    private let slot: Slot
    private let settings = MobileSettings.shared

    /// The Mac picker's popular shortlists, filtered against the catalog so
    /// a package rename drops a stale entry instead of showing a dead row.
    private static let popularDarkNames: [String] = [
        "Dracula",
        "Catppuccin Mocha",
        "TokyoNight Storm",
        "Nord",
        "Gruvbox Dark",
        "Atom One Dark",
        "Monokai Pro",
        "Rose Pine",
        "Ayu Mirage",
        "Night Owl",
        "Kanagawa Wave",
        "Everforest Dark Hard",
        "GitHub Dark Default",
        "iTerm2 Solarized Dark",
    ].filter { GhosttyThemeCatalog.theme(named: $0) != nil }

    private static let popularLightNames: [String] = [
        "Catppuccin Latte",
        "Rose Pine Dawn",
        "Gruvbox Light",
        "Ayu Light",
        "Atom One Light",
        "GitHub Light Default",
        "TokyoNight Day",
        "Everforest Light Med",
        "iTerm2 Solarized Light",
    ].filter { GhosttyThemeCatalog.theme(named: $0) != nil }

    private let popular: [GhosttyThemeDefinition]
    private let all = GhosttyThemeCatalog.allThemes.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    private var query = ""
    private var matches: [GhosttyThemeDefinition] = []

    private var selectedName: String {
        get { slot == .light ? settings.lightThemeName : settings.darkThemeName }
        set {
            if slot == .light {
                settings.lightThemeName = newValue
            } else {
                settings.darkThemeName = newValue
            }
        }
    }

    init(slot: Slot) {
        self.slot = slot
        popular = (slot == .light ? Self.popularLightNames : Self.popularDarkNames)
            .compactMap { GhosttyThemeCatalog.theme(named: $0) }
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = slot == .light ? "Light Theme" : "Dark Theme"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "theme")

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private var isSearching: Bool { !query.isEmpty }

    private func theme(at indexPath: IndexPath) -> GhosttyThemeDefinition {
        if isSearching { return matches[indexPath.row] }
        return indexPath.section == 0 ? popular[indexPath.row] : all[indexPath.row]
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        isSearching ? 1 : 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isSearching { return matches.count }
        return section == 0 ? popular.count : all.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if isSearching { return nil }
        return section == 0 ? "Popular" : "All Themes"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "theme", for: indexPath)
        let theme = theme(at: indexPath)
        cell.contentConfiguration = UIHostingConfiguration {
            ThemeRow(theme: theme, isSelected: theme.name == selectedName)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selectedName = theme(at: indexPath).name
        // The pick shows up in every visible copy of the row (popular + all).
        tableView.reloadData()
    }
}

extension ThemePickerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        if !query.isEmpty {
            matches = GhosttyThemeCatalog.search(query).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        tableView.reloadData()
    }
}

/// One catalog row: a small background/foreground swatch so themes are
/// recognizable at a glance without applying them one by one.
private struct ThemeRow: View {
    let theme: GhosttyThemeDefinition
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(swatchHex: theme.background))
                Text("Aa")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(swatchHex: theme.foreground))
            }
            .frame(width: 36, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.15))
            )
            Text(theme.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }
}

private extension Color {
    init(swatchHex hex: String) {
        if let color = UIColor(ghosttyHex: hex) {
            self.init(uiColor: color)
        } else {
            self = .primary
        }
    }
}
