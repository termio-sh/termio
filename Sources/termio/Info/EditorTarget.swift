import AppKit

/// An external editor termio can hand a file or folder to from the Info pane. The
/// catalog is a fixed set of well-known editors; only the ones actually installed
/// (resolved by bundle id) are offered, so the list configures itself — a machine
/// with VS Code and Zed shows exactly those two, with no setup UI to maintain.
struct EditorTarget: Identifiable, Hashable {
    let name: String
    /// The bundle identifier used to detect the app, launch it, and fetch its real
    /// icon. An editor whose id doesn't resolve is simply never shown, so a stale
    /// or wrong id degrades to "absent" rather than to a broken row.
    let bundleID: String

    var id: String { bundleID }

    /// The installed app's on-disk URL, or `nil` when the editor isn't present.
    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// The editor's real app icon (the `.icns` macOS shows in the Dock/Finder), so
    /// each row is unmistakably that app rather than a generic glyph. `nil` only if
    /// the app isn't installed — but callers render only installed targets.
    ///
    /// Memoized because the caller is a SwiftUI view builder, and a view builder runs
    /// far more often than it renders: `ScrollView` sizing re-evaluates its content on
    /// every layout pass, so an uncached fetch turned one Info pane into thousands of
    /// `NSWorkspace.icon(forFile:)` calls — each a LaunchServices `getattrlist` — and
    /// pinned the main thread for seconds when a project opened. One fetch per editor
    /// per run is plenty: an app's icon does not change under us.
    @MainActor
    var appIcon: NSImage? {
        if let cached = Self.iconCache[bundleID] { return cached }
        guard let icon = applicationURL.map({ NSWorkspace.shared.icon(forFile: $0.path) })
        else { return nil }
        Self.iconCache[bundleID] = icon
        return icon
    }

    @MainActor private static var iconCache: [String: NSImage] = [:]

    /// Every editor termio knows how to open, in display order. Kept deliberately
    /// short — the popular coding editors that open a folder or file cleanly from
    /// `NSWorkspace`.
    static let catalog: [EditorTarget] = [
        EditorTarget(name: "VS Code", bundleID: "com.microsoft.VSCode"),
        EditorTarget(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        EditorTarget(name: "Windsurf", bundleID: "com.exafunction.windsurf"),
        EditorTarget(name: "Zed", bundleID: "dev.zed.Zed"),
        EditorTarget(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        EditorTarget(name: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij"),
        EditorTarget(name: "Sublime Text", bundleID: "com.sublimetext.4"),
    ]

    /// The subset of the catalog installed on this machine, in catalog order. Resolved
    /// once, for the same reason `appIcon` is memoized — this is read from a view
    /// builder, so a bundle-id lookup per editor per layout pass is filesystem work in
    /// the middle of drawing. The cost is that an editor installed while termio is
    /// running appears in the list after the next launch.
    static let installed: [EditorTarget] = catalog.filter { $0.applicationURL != nil }

    /// Opens `url` (a file or a folder) in this editor. A no-op if it isn't
    /// installed — the caller only ever renders installed targets, so this is a
    /// belt-and-braces guard against the app being removed mid-session.
    func open(_ url: URL) {
        guard let app = applicationURL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
