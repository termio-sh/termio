import SwiftUI

/// The display-language override. macOS resolves a process's language from the
/// `AppleLanguages` array in the app's own defaults domain — the same mechanism
/// behind System Settings ▸ Language & Region ▸ Applications — so writing that
/// one key is the whole feature: after a relaunch, framework-provided strings
/// and termio's own catalog follow together. No custom lookup layer, and no
/// live switching: AppKit resolves strings at call time from the launch
/// language, so an in-place switch would leave the window half-translated.
enum LanguageOverride {
    private static let defaultsKey = "AppleLanguages"

    /// Languages the app actually ships strings for, endonym-sorted for the picker.
    static var available: [String] {
        Bundle.termioResources.localizations
            .filter { $0 != "Base" }
            .sorted { endonym(for: $0) < endonym(for: $1) }
    }

    /// The explicit override, nil when termio follows the system language.
    /// `UserDefaults.standard.array(forKey:)` can't answer this — it inherits
    /// `AppleLanguages` from the global domain for every process — so only a
    /// value present in termio's own persistent domain counts.
    static var current: String? {
        let domainName = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        guard let domain = UserDefaults.standard.persistentDomain(forName: domainName),
              let languages = domain[defaultsKey] as? [String],
              let stored = languages.first
        else { return nil }
        // Normalize casing against the shipped localizations so a value written
        // with different capitalization still matches a picker tag.
        return available.first { $0.caseInsensitiveCompare(stored) == .orderedSame } ?? stored
    }

    static func apply(_ code: String?) {
        if let code {
            UserDefaults.standard.set([code], forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    /// The language this process launched with — what the UI is actually showing.
    /// Captured once so later defaults writes don't shift the comparison point.
    static let active: String = Bundle.termioResources.preferredLocalizations.first ?? "en"

    /// What the app would resolve to with no override. Read from the global
    /// defaults domain: asking this process (or the bundle) would just echo an
    /// active override back, so with Chinese applied the "System" item would
    /// wrongly present the system language as Chinese too.
    static var systemResolved: String {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let preferences = global?[defaultsKey] as? [String] ?? ["en"]
        return Bundle.preferredLocalizations(
            from: Bundle.termioResources.localizations.filter { $0 != "Base" },
            forPreferences: preferences
        ).first ?? "en"
    }

    /// A language's name in that language ("简体中文", "日本語"), the convention
    /// that keeps every entry recognizable to its own speakers.
    static func endonym(for code: String) -> String {
        let locale = Locale(identifier: code)
        guard let name = locale.localizedString(forIdentifier: code) else { return code }
        return name.capitalized(with: locale)
    }

    /// Relaunches the bundled app by handing the reopen to a detached `open`
    /// that outlives the process; unbundled (`swift run`) there is nothing to
    /// reopen, so it just terminates.
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // The path rides as a positional argument — interpolating it into
            // the command string would hand any shell syntax in it to sh.
            process.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", bundleURL.path]
            do {
                try process.run()
            } catch {
                Log.app.error("language relaunch failed to spawn open: \(error.localizedDescription, privacy: .public)")
            }
        }
        NSApp.terminate(nil)
    }
}

/// The Settings ▸ General row. Selection is the language code, "" meaning
/// "follow the system". Changing it writes the override immediately (so the
/// choice sticks however the app next starts) and offers a relaunch — with
/// "Later" as the safe default, because relaunching ends running sessions.
struct LanguageRow: View {
    @State private var selection: String = LanguageOverride.current ?? ""
    @State private var confirmingRelaunch = false

    var body: some View {
        Picker(selection: $selection) {
            Text(localized("System (\(LanguageOverride.endonym(for: LanguageOverride.systemResolved)))"))
                .tag("")
            Divider()
            ForEach(LanguageOverride.available, id: \.self) { code in
                Text(LanguageOverride.endonym(for: code)).tag(code)
            }
        } label: {
            SettingsLabel(
                .huge(.textFont),
                title: localized("App language"),
                subtext: localized("Takes effect after Termio relaunches.")
            )
        }
        .onChange(of: selection) { _, newValue in
            LanguageOverride.apply(newValue.isEmpty ? nil : newValue)
            let effective = newValue.isEmpty ? LanguageOverride.systemResolved : newValue
            if effective != LanguageOverride.active {
                confirmingRelaunch = true
            }
        }
        .alert(localized("Relaunch Termio to switch language?"),
               isPresented: $confirmingRelaunch) {
            Button(localized("Later"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button(localized("Relaunch Now")) {
                LanguageOverride.relaunch()
            }
        } message: {
            Text(localized("Running terminal sessions will end. You can relaunch later instead."))
        }
    }
}
