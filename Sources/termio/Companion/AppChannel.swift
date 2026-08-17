import Foundation

/// Distinguishes a shipped release from a side-by-side **dev** build so the two
/// can run at once without fighting over on-disk state, control sockets, or the
/// companion port.
///
/// Everything keys off the bundle identifier: a dev build ships an id ending in
/// `.dev` (`sh.termio.app.dev`), and that single fact fans out here into every
/// termio-owned path and port. A release build (`sh.termio.app`) is unsuffixed and
/// behaves exactly as before. UserDefaults and LaunchServices already isolate by
/// bundle id for free; this type covers the paths that don't.
///
/// Note: a *project's* own `<project>/.termio/…` sidecar (phone uploads, etc.) is
/// deliberately NOT routed through here — it's relative to the user's repo, not to
/// termio's config, so both channels share it.
enum AppChannel {
    /// `"-dev"` for a `*.dev` bundle id, `""` for a release build.
    ///
    /// `TERMIO_CHANNEL` overrides the bundle reading — the same switch
    /// `build-app.sh` takes at build time, now honoured at runtime. It exists for
    /// the unbundled case: `swift run` has no bundle identifier, so without it a
    /// bare binary falls into the *release* channel and shares the shipped app's
    /// state directory, control socket and companion port.
    static let suffix: String = {
        let requested = ProcessInfo.processInfo.environment["TERMIO_CHANNEL"]?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        // Only a plain name becomes a path component — anything else is a typo we
        // must not turn into a stray directory next to the real ones.
        if !requested.isEmpty, requested != "release",
           requested.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            return "-" + requested
        }
        if requested == "release" { return "" }
        return (Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false) ? "-dev" : ""
    }()

    /// True for the side-by-side dev build. Use this to gate diagnostics that must
    /// survive a release-configuration compile (`build-app.sh` builds the dev bundle
    /// in release config, so `#if DEBUG` would strip them) yet never appear in the
    /// shipped release app.
    static var isDev: Bool { !suffix.isEmpty }

    /// The URL scheme this channel claims for session deep links (`termio://` /
    /// `termio-dev://`), so dev and release never route each other's links.
    /// Registered in Info.plist; `build-app.sh` rewrites it for the dev bundle.
    static var urlScheme: String { "termio" + suffix }

    /// True when running from a real `.app` bundle (either channel). A bare SwiftPM
    /// binary (`swift run`, the test runner) has no bundle identifier, and
    /// bundle-dependent frameworks — `UNUserNotificationCenter` aborts with
    /// "bundleProxyForCurrentProcess is nil" — must not be touched without one.
    static let isBundledApp = Bundle.main.bundleIdentifier != nil

    /// Internal state — control/status sockets, `state.json`, custom themes, and
    /// downloaded tunnel binaries: `~/Library/Application Support/termio[-dev]`.
    /// Falls back to a home dotfolder if Application Support can't be resolved.
    static var supportDirectory: URL {
        let name = "termio" + suffix
        if let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return base.appendingPathComponent(name, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("." + name, isDirectory: true)
    }

    /// User-facing config the user drops files into (agent definitions, worktrees):
    /// `~/.termio[-dev]`.
    static var homeConfigDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".termio" + suffix, isDirectory: true)
    }

    /// Companion (phone) server port: 8787 for release, 8788 for dev, so both can
    /// bind at once.
    static var companionPort: UInt16 { suffix.isEmpty ? 8787 : 8788 }
}
