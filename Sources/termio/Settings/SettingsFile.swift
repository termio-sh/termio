import Foundation

/// Where a preference the user actually chose is kept: `~/.termio[-dev]/settings.json`,
/// beside `keybindings.json`, in the same hand-editable JSON the rest of termio's
/// config already uses.
///
/// Only keys the user has *set* are written. That is the rule `KeybindingStore`
/// follows for its own file, and it buys the same two things: a shipped default
/// that changes later still reaches everyone who never touched that setting, and
/// the file stays short enough to read at a glance and keep in a dotfiles repo.
/// A file that seeded every key with its current value would freeze both.
///
/// This layer replaces `UserDefaults`' *persistent* domain and nothing else.
/// Resolution stays what it has always been — user setting > Ghostty config >
/// built-in default — because the lower two layers are still the registration
/// domain `AppSettings.init` seeds. `SettingsStore` is what enforces that order,
/// so no call site has to remember it.
///
/// Writes are synchronous, like `KeybindingStore`'s: the file is a few hundred
/// bytes, `set` ignores a value that didn't change, and saving inline means a
/// preference chosen a moment before quitting is already on disk.
@MainActor
final class SettingsStore {
    /// The user's own values, keyed exactly as `AppSettings.Key` spells them.
    /// Absent key = the user never chose one; fall through to the lower layers.
    private var chosen: [String: Any]
    private let defaults: UserDefaults
    private let fileURL: URL
    /// The `UserDefaults` domain migration reads. Named rather than assumed so a
    /// test can hand in its own suite — `persistentDomain` only answers for the
    /// domain it is asked about.
    private let domainName: String?

    static var defaultURL: URL {
        AppChannel.homeConfigDirectory
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    init(defaults: UserDefaults = .standard,
         fileURL: URL = SettingsStore.defaultURL,
         domainName: String? = Bundle.main.bundleIdentifier) {
        self.defaults = defaults
        self.fileURL = fileURL
        self.domainName = domainName
        chosen = Self.read(fileURL)
    }

    // MARK: - Reading

    // Each getter is "the user's choice, else whatever the registration domain
    // resolves to" — Ghostty's value when the user has a Ghostty config, the
    // built-in otherwise.

    func string(_ key: String) -> String? {
        chosen[key] as? String ?? defaults.string(forKey: key)
    }

    func double(_ key: String) -> Double {
        if let value = chosen[key] as? Double { return value }
        if let value = chosen[key] as? Int { return Double(value) }
        return defaults.double(forKey: key)
    }

    func integer(_ key: String) -> Int {
        if let value = chosen[key] as? Int { return value }
        if let value = chosen[key] as? Double { return Int(value) }
        return defaults.integer(forKey: key)
    }

    func bool(_ key: String) -> Bool {
        chosen[key] as? Bool ?? defaults.bool(forKey: key)
    }

    func stringArray(_ key: String) -> [String]? {
        chosen[key] as? [String] ?? defaults.stringArray(forKey: key)
    }

    func stringDictionary(_ key: String) -> [String: String]? {
        chosen[key] as? [String: String]
            ?? defaults.dictionary(forKey: key) as? [String: String]
    }

    /// Whether the user chose this key themselves, as opposed to inheriting it.
    /// Lets a Reset control clear the value instead of writing today's default
    /// back in as if it were a choice.
    func isChosen(_ key: String) -> Bool { chosen[key] != nil }

    // MARK: - Writing

    /// Records the user's choice. `nil` clears it, handing the key back to the
    /// Ghostty and built-in layers rather than pinning today's default.
    func set(_ value: Any?, forKey key: String) {
        if let value {
            if let existing = chosen[key], Self.equal(existing, value) { return }
            chosen[key] = value
        } else {
            guard chosen[key] != nil else { return }
            chosen.removeValue(forKey: key)
        }
        save()
    }

    // MARK: - Migration

    /// Seeds the file, once, from what an existing install already wrote to
    /// `UserDefaults`. The persistent domain holds exactly the keys the user
    /// chose — defaults live in the registration domain — so it maps onto this
    /// file's rule without having to guess which values were deliberate.
    ///
    /// Only when the file is absent, so a user who has since edited or deleted
    /// keys is never re-seeded from a stale domain.
    func migrateIfNeeded(managing keys: Set<String>) {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let domainName, let domain = defaults.persistentDomain(forName: domainName)
        else { return }
        let carried = domain.filter { keys.contains($0.key) }
        guard !carried.isEmpty else { return }
        chosen.merge(carried) { _, migrated in migrated }
        save()
    }

    // MARK: - File

    private static func read(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return parsed
    }

    /// Sorted and pretty-printed because a human edits this file; the stable key
    /// order also keeps it diffable in a dotfiles repo.
    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: chosen, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error(
                "could not write settings.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Value comparison across the JSON types these settings use. Bridged to
    /// `NSObject` they all answer `isEqual`; anything exotic reports "changed"
    /// and is written, which is the safe direction.
    private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else { return false }
        return lhs.isEqual(rhs)
    }
}
