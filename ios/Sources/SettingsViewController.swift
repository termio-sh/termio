import GhosttyTheme
import SwiftUI
import TermioShared
import UIKit

/// The app's settings sheet — ChatGPT-style two-level: this root is a small
/// menu of categories, each pushing its own page, plus an About group.
/// Devices leads (the Mac link is the app's lifeline — its row carries
/// the live link status inline, the only at-a-glance copy of it since the
/// session list dropped its device pill); Appearance carries the terminal look.
final class SettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case pages, about
    }

    private enum Row: Int, CaseIterable {
        case devices, appearance, terminalKeyboard, voice

        var title: String {
            switch self {
            case .devices: localized("Devices")
            case .appearance: localized("Appearance")
            case .terminalKeyboard: localized("Terminal Keyboard")
            case .voice: localized("Voice")
            }
        }

        /// The row glyph, from the shared Hugeicons set so the Settings page
        /// matches the native tab bar and the Mac settings sidebar.
        var icon: HugeIcon {
            switch self {
            case .devices: .wireless
            case .appearance: .paintBoard
            case .terminalKeyboard: .keyboard
            case .voice: .voice
            }
        }

        func makePage() -> UIViewController {
            switch self {
            case .devices: DevicesSettingsViewController()
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
        title = localized("Settings")
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
            close.accessibilityLabel = localized("Close")
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
        // The Devices row's inline status tracks the live link.
        stateObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.tableView.reloadData()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Coming back from the Devices page after pairing/forgetting: refresh
        // the inline status.
        tableView.reloadData()
    }

    /// The Devices row's detail: a presence dot + the state. Shared with the
    /// Devices page's active-Mac row so the two always read the same.
    static func linkStatus(textStyle: UIFont.TextStyle = .body) -> NSAttributedString {
        let (color, text): (UIColor, String) = switch CompanionLink.state {
        case .unpaired: (.tertiaryLabel, localized("Not Paired"))
        case .connecting: (.systemOrange, localized("Reconnecting…"))
        case .connected: (.systemGreen, localized("Connected"))
        case .failed: (.systemRed, localized("Connection Failed"))
        }
        // The dot is a drawn image in an NSTextAttachment, not a glyph:
        // mixed-size text runs never sit still (a ● run smaller than the text
        // needs a hand-tuned baseline offset that drifts with every size
        // change), while an attachment centers exactly via its bounds — the
        // standard recipe: y = (capHeight − height) / 2. The text run carries
        // an explicit font so the line metrics (and the row baseline)
        // are its own.
        let font = UIFont.preferredFont(forTextStyle: textStyle)
        let diameter: CGFloat = textStyle == .body ? 11 : 9
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
        section == Section.about.rawValue ? localized("About") : nil
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
            if row == .devices {
                cell.detailTextLabel?.attributedText = Self.linkStatus()
            }
        default:
            switch AboutRow(rawValue: indexPath.row) {
            case .version:
                cell.textLabel?.text = localized("Version")
                cell.selectionStyle = .none
                cell.detailTextLabel?.text =
                    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            case .website:
                cell.textLabel?.text = localized("Website")
                cell.detailTextLabel?.text = "termio.sh"
            case .privacy, nil:
                cell.textLabel?.text = localized("Privacy Policy")
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
        title = localized("Appearance")
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
        localized("Terminal")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // A static four-row form; building cells directly beats reuse plumbing.
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        switch Row(rawValue: indexPath.row) {
        case .appearance:
            cell.textLabel?.text = localized("Appearance")
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
            cell.textLabel?.text = localized("Light Theme")
            cell.detailTextLabel?.text = settings.lightThemeName
            cell.accessoryType = .disclosureIndicator
        case .darkTheme:
            cell.textLabel?.text = localized("Dark Theme")
            cell.detailTextLabel?.text = settings.darkThemeName
            cell.accessoryType = .disclosureIndicator
        case .fontSize, nil:
            cell.textLabel?.text = localized("Font Size")
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
        localized("\(Int(size)) pt")
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
        title = localized("Terminal Keyboard")
        themeObserver = installThemeBackdrop()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        TerminalKeyCatalog.all.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        localized("Control Keys")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        localized("Keys on the control bar above the system keyboard. Esc and the arrows are always there; hold esc for esc-esc (Claude Code's rewind menu).")
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
        title = localized("Voice")
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
        case .provider: localized("Transcription")
        // The key belongs to the chosen provider — name it so the two read together.
        case .key: provider.displayName
        default: nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .voice, nil:
            localized("Hold the mic key on the terminal keyboard to dictate a prompt — release to send it, slide up to cancel.")
        case .provider:
            localized("Which service transcribes your voice. Each keeps its own key.")
        case .key:
            provider.keyFooter
                + localized(" Your key stays in this device's Keychain and is used only for transcription.")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .voice, nil:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = localized("Voice Input")
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
            cell.textLabel?.text = localized("Provider")
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
                cell.textLabel?.text = localized("API Key")
                cell.detailTextLabel?.text = isSet ? localized("•••• Set") : localized("Not Set")
                cell.detailTextLabel?.textColor = isSet ? .systemGreen : .secondaryLabel
                cell.accessoryType = .disclosureIndicator
            case .remove:
                cell.textLabel?.text = localized("Remove Key")
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
            title: localized("\(provider.displayName) API Key"),
            message: localized("Paste your key. It's stored in this device's Keychain."),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = provider.keyPlaceholder
            field.isSecureTextEntry = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.text = VoiceDictation.apiKey(for: provider)
        }
        alert.addAction(UIAlertAction(title: localized("Save"), style: .default) { [weak self, weak alert] _ in
            VoiceDictation.setAPIKey(alert?.textFields?.first?.text, for: provider)
            self?.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: localized("Cancel"), style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - Devices

/// The paired-Mac list, shaped like Settings ▸ Bluetooth's My Devices: every
/// paired Mac keeps a row carrying its connection state, tapping one switches
/// the whole app to it, and its ⓘ opens that Mac's own page for the address and
/// Forget. Adding a Mac scans its QR or takes a typed address. The sidebar owns
/// the socket; this page edits `CompanionLink` and the socket's owner follows
/// `pairingDidChange`.
final class DevicesSettingsViewController: UITableViewController {
    private enum Section {
        case macs, add
    }

    private enum AddRow: Int, CaseIterable {
        case scan, manual
    }

    private var sections: [Section] = []
    private var macs: [PairedMac] = []

    private var stateObserver: NSObjectProtocol?
    private var macsObserver: NSObjectProtocol?
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
        if let macsObserver {
            NotificationCenter.default.removeObserver(macsObserver)
        }
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = localized("Devices")
        themeObserver = installThemeBackdrop()
        stateObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        macsObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.macsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    private func reload() {
        macs = CompanionLink.pairedMacs
        sections = (macs.isEmpty ? [] : [.macs]) + [.add]
        tableView.reloadData()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .macs: macs.count
        case .add: AddRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .macs: localized("My Devices")
        case .add: localized("Add a Device")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .macs:
            localized("One device is connected at a time — tap another to switch to it. Switching closes the terminals open on this phone; the sessions keep running on the Mac.")
        case .add:
            localized("Scan the QR code in Settings ▸ Mobile on the Mac you want to pair. Re-scanning a paired Mac updates its address.")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .macs:
            let mac = macs[indexPath.row]
            let isActive = mac.id == CompanionLink.activeMac?.id
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = mac.name
            // Wi-Fi's selection mark: the checkmark leads the row, leaving the
            // trailing side to the state and the ⓘ. The unselected rows carry
            // the same glyph drawn clear, so every name starts on one column.
            // Scaled off the body text style, or it stays 17pt while the names
            // grow with the reader's text size and the column drifts.
            let checkmark = UIImage(
                systemName: "checkmark",
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)
            )
            cell.imageView?.image = isActive
                ? checkmark
                : checkmark?.withTintColor(.clear, renderingMode: .alwaysOriginal)
            cell.imageView?.tintColor = cell.tintColor
            // The connection state is the row's value, Bluetooth-style, so the
            // selected Mac also says whether the link to it is actually up.
            if isActive {
                cell.detailTextLabel?.attributedText = SettingsViewController.linkStatus()
            } else {
                cell.detailTextLabel?.text = localized("Not Connected")
            }
            cell.accessoryType = .detailButton
            // A checkmark is a picture: VoiceOver reads the name and the state
            // but would never say which device is the chosen one without the
            // trait carrying it.
            if isActive { cell.accessibilityTraits.insert(.selected) }
            return cell
        case .add:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.imageView?.tintColor = .label
            switch AddRow(rawValue: indexPath.row) {
            case .scan, nil:
                cell.textLabel?.text = localized("Scan QR Code")
                cell.imageView?.image = HugeIcon.qrCode.strokeImage(boxSize: 22)
            case .manual:
                cell.textLabel?.text = localized("Enter Address Manually")
                cell.imageView?.image = HugeIcon.keyboard.strokeImage(boxSize: 22)
            }
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .macs:
            CompanionLink.switchTo(macs[indexPath.row].id)
        case .add:
            switch AddRow(rawValue: indexPath.row) {
            case .scan, nil: presentScanner()
            case .manual: presentEnterAddress()
            }
        }
    }

    /// The ⓘ button opens that Mac's own page — address and Forget live there,
    /// the way a Wi-Fi network's details do.
    override func tableView(
        _ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath
    ) {
        guard sections[indexPath.section] == .macs else { return }
        navigationController?.pushViewController(
            MacDetailViewController(macID: macs[indexPath.row].id), animated: true
        )
    }

    // MARK: - Actions

    private func presentEnterAddress() {
        let alert = UIAlertController(
            title: localized("Connect to Mac"),
            message: localized("The address Termio on your Mac is serving."),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "ws://mac-hostname:8787"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: localized("Connect"), style: .default) { [weak alert] _ in
            guard let raw = alert?.textFields?.first?.text else { return }
            CompanionLink.pair(rawAddress: raw)
        })
        alert.addAction(UIAlertAction(title: localized("Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    /// Camera pairing — same path as typing the address, minus the typing.
    /// The QR lives on the Mac's Settings ▸ Mobile tab.
    private func presentScanner() {
        let scanner = QRScannerViewController()
        scanner.onCode = { code in
            CompanionLink.pair(rawAddress: code)
        }
        present(UINavigationController(rootViewController: scanner), animated: true)
    }
}

/// One paired Mac's page, behind the ⓘ on the Devices list — Settings ▸
/// Wi-Fi's network details, translated: the live state, the address the socket
/// dials, and Forget. Read-only: an address changes by re-scanning that Mac's
/// QR, which folds into this entry rather than adding a second one.
final class MacDetailViewController: UITableViewController {
    private enum Row: Int, CaseIterable {
        case status, address
    }

    private let macID: String
    private var mac: PairedMac?

    private var stateObserver: NSObjectProtocol?
    private var macsObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?

    init(macID: String) {
        self.macID = macID
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
        if let macsObserver {
            NotificationCenter.default.removeObserver(macsObserver)
        }
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        themeObserver = installThemeBackdrop()
        stateObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        macsObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.macsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    private func reload() {
        // Forgotten from under us (or from another screen): there is nothing
        // left to show, so leave rather than render a stale page.
        guard let match = CompanionLink.pairedMacs.first(where: { $0.id == macID }) else {
            navigationController?.popViewController(animated: true)
            return
        }
        mac = match
        title = match.name
        tableView.reloadData()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? Row.allCases.count : 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard indexPath.section == 0 else {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = localized("Forget This Mac")
            cell.textLabel?.textColor = .systemRed
            return cell
        }
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .none
        switch Row(rawValue: indexPath.row) {
        case .status, nil:
            cell.textLabel?.text = localized("Status")
            if macID == CompanionLink.activeMac?.id {
                cell.detailTextLabel?.attributedText = SettingsViewController.linkStatus()
            } else {
                cell.detailTextLabel?.text = localized("Not Connected")
            }
        case .address:
            cell.textLabel?.text = localized("Address")
            // Host + port only: the scheme is noise and the pairing token
            // riding the query is a secret.
            cell.detailTextLabel?.text = mac?.displayAddress
            cell.detailTextLabel?.lineBreakMode = .byTruncatingMiddle
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        confirmForget()
    }

    /// Forgetting drops the address and the pairing token, so it costs a new
    /// QR scan to undo — worth a confirmation, the way Wi-Fi confirms.
    private func confirmForget() {
        let name = mac?.name ?? localized("This Mac")
        let alert = UIAlertController(
            title: localized("Forget \(name)?"),
            message: localized("You'll need to scan its QR code again to reconnect."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: localized("Forget"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            CompanionLink.forget(macID)
        })
        alert.addAction(UIAlertAction(title: localized("Cancel"), style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - Theme picker

/// Picker for one slot of the theme pair: the slot's own default, then the
/// store's curated set for that brightness (the same names the Mac's Browse
/// Themes offers), with a search field over both. Picking a row applies
/// immediately — no confirm step, matching the Mac's live-preview behavior.
///
/// The phone has no theme store: it resolves these names out of the compiled
/// catalog to render them and never writes a file. Themes the user installed on
/// the Mac stay on the Mac.
final class ThemePickerViewController: UITableViewController {
    enum Slot {
        case light, dark
    }

    private let slot: Slot
    private let settings = MobileSettings.shared

    /// The slot's default plus the store's half for this brightness, resolved
    /// against the catalog so a package rename drops a stale entry instead of
    /// showing a dead row. Brightness is each theme's own `isDark`, so a slot can
    /// never offer a theme that would render the wrong way.
    private let themes: [GhosttyThemeDefinition]
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
        let names = [
            MobileSettings.defaultLightThemeName,
            MobileSettings.defaultDarkThemeName,
        ] + ThemeStoreCatalog.names
        var seen: Set<String> = []
        themes = names
            .compactMap { GhosttyThemeCatalog.theme(named: $0) }
            .filter { $0.isDark == (slot == .dark) && seen.insert($0.name).inserted }
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = slot == .light ? localized("Light Theme") : localized("Dark Theme")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "theme")

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private var isSearching: Bool { !query.isEmpty }

    private var rows: [GhosttyThemeDefinition] { isSearching ? matches : themes }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        isSearching ? nil : localized("Themes")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "theme", for: indexPath)
        let theme = rows[indexPath.row]
        cell.contentConfiguration = UIHostingConfiguration {
            ThemeRow(theme: theme, isSelected: theme.name == selectedName)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selectedName = rows[indexPath.row].name
        tableView.reloadData()
    }
}

extension ThemePickerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        // Search stays inside the offered set: a hit the picker would refuse to
        // list is a row that cannot be picked.
        matches = themes.filter { $0.name.localizedCaseInsensitiveContains(query) }
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
