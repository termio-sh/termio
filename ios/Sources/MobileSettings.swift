import UIKit

/// App-wide user preferences — the mobile counterpart of the Mac app's
/// `AppSettings`, pared down to the knobs that matter on a phone: appearance
/// mode, the light/dark terminal theme pair, and font size. UserDefaults-
/// backed the same way (every write persists immediately); changes post
/// `didChange` so live surfaces restyle in place instead of waiting for a
/// relaunch.
final class MobileSettings {
    static let shared = MobileSettings()
    static let didChange = Notification.Name("MobileSettingsDidChange")

    /// Same trio as the Mac's Appearance setting: follow the device, or pin
    /// the whole app (shell, sheets, and the terminal's theme slot) to one
    /// side — applied as the window's interface-style override.
    enum AppearanceMode: String, CaseIterable {
        case system, light, dark

        var uiStyle: UIUserInterfaceStyle {
            switch self {
            case .system: .unspecified
            case .light: .light
            case .dark: .dark
            }
        }

        var label: String {
            switch self {
            case .system: localized("System")
            case .light: localized("Light")
            case .dark: localized("Dark")
            }
        }
    }

    /// The Alabaster/Afterglow pair mirrors the Mac app's out-of-the-box
    /// look, so a session opened on the phone matches the desk.
    static let defaultLightThemeName = "Alabaster"
    static let defaultDarkThemeName = "Afterglow"
    static let defaultFontSize = 12.0
    static let fontSizeRange = 8.0 ... 24.0

    private enum Key {
        static let appearanceMode = "appearance.mode"
        static let lightThemeName = "appearance.lightThemeName"
        static let darkThemeName = "appearance.darkThemeName"
        static let fontSize = "appearance.fontSize"
        static let terminalKeys = "terminalKeyboard.keys"
        static let pushToTalk = "voice.pushToTalk"
        static let transcriptionProvider = "voice.provider"
    }

    private let defaults = UserDefaults.standard

    var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: Key.appearanceMode)
            notify()
        }
    }

    var lightThemeName: String {
        didSet {
            defaults.set(lightThemeName, forKey: Key.lightThemeName)
            notify()
        }
    }

    var darkThemeName: String {
        didSet {
            defaults.set(darkThemeName, forKey: Key.darkThemeName)
            notify()
        }
    }

    var fontSize: Double {
        didSet {
            defaults.set(fontSize, forKey: Key.fontSize)
            notify()
        }
    }

    /// The code face every non-terminal code surface (file viewer, diff view)
    /// renders in — the terminal's font-size setting applied to the system
    /// monospace, so code reads in one size across the app.
    func codeFont(weight: UIFont.Weight = .regular) -> UIFont {
        .monospacedSystemFont(ofSize: fontSize, weight: weight)
    }

    /// Which catalog keys join the control bar above the system keyboard, in
    /// catalog order (esc and the arrows are fixed core, not stored here).
    var terminalKeyIDs: [String] {
        didSet {
            defaults.set(terminalKeyIDs, forKey: Key.terminalKeys)
            notify()
        }
    }

    /// Hold-to-talk on the terminal keyboard's space bar. Off by default — the
    /// space bar is just a space until the user opts in (and adds an OpenAI
    /// key). Flipping it reposts `didChange`, which rebuilds the keyboard so
    /// the space bar gains or drops its hold gesture.
    var pushToTalkEnabled: Bool {
        didSet {
            defaults.set(pushToTalkEnabled, forKey: Key.pushToTalk)
            notify()
        }
    }

    /// Which transcription service dictation uses — the user's Settings ▸ Voice
    /// choice. Each provider keeps its own key in the Keychain, so switching
    /// never loses the other's key.
    var transcriptionProvider: TranscriptionProvider {
        didSet {
            defaults.set(transcriptionProvider.rawValue, forKey: Key.transcriptionProvider)
            notify()
        }
    }

    private init() {
        defaults.register(defaults: [
            Key.appearanceMode: AppearanceMode.system.rawValue,
            Key.lightThemeName: Self.defaultLightThemeName,
            Key.darkThemeName: Self.defaultDarkThemeName,
            Key.fontSize: Self.defaultFontSize,
            Key.terminalKeys: TerminalKeyCatalog.defaultIDs,
            Key.pushToTalk: false,
            Key.transcriptionProvider: TranscriptionProvider.openAI.rawValue,
        ])
        appearanceMode = AppearanceMode(
            rawValue: defaults.string(forKey: Key.appearanceMode) ?? ""
        ) ?? .system
        lightThemeName = defaults.string(forKey: Key.lightThemeName) ?? Self.defaultLightThemeName
        darkThemeName = defaults.string(forKey: Key.darkThemeName) ?? Self.defaultDarkThemeName
        fontSize = defaults.double(forKey: Key.fontSize)
        terminalKeyIDs = defaults.stringArray(forKey: Key.terminalKeys)
            ?? TerminalKeyCatalog.defaultIDs
        pushToTalkEnabled = defaults.bool(forKey: Key.pushToTalk)
        transcriptionProvider = TranscriptionProvider(
            rawValue: defaults.string(forKey: Key.transcriptionProvider) ?? ""
        ) ?? .openAI
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

extension UIColor {
    /// Ghostty theme colors are bare RGB hex, with or without a leading `#`.
    convenience init?(ghosttyHex hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            return nil
        }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
