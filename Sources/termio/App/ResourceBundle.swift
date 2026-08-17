import Foundation

extension Bundle {
    /// The SwiftPM resource bundle for the `termio` target, resolved in a way that
    /// works inside a packaged `.app`.
    ///
    /// `Bundle.module` can't be used here: SwiftPM generates it for an *executable*
    /// target as `Bundle.main.bundleURL/termio_termio.bundle` (i.e. the `.app` root)
    /// with a **hardcoded absolute build path** as the only fallback. But `.app`
    /// packaging puts resource bundles under `Contents/Resources/` (a bundle at the
    /// app root is rejected by `codesign` — "unsealed contents present in the bundle
    /// root"), and the hardcoded path only exists on the machine that built the
    /// binary. So a released build finds neither and `fatalError`s on launch on every
    /// user's machine. Resolve from the standard app resource directory instead, and
    /// degrade to the empty main bundle (a missing icon, never a crash) if absent.
    static let termioResources: Bundle = {
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            // Unit tests: `Bundle.main` is the xctest runner, but the bundle
            // holding this class is the `.xctest` in the SwiftPM build directory,
            // which sits next to the resource bundle.
            Bundle(for: TermioResourcesAnchor.self).bundleURL.deletingLastPathComponent(),
        ].compactMap { $0?.appendingPathComponent("termio_termio.bundle") }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return .main
    }()
}

private final class TermioResourcesAnchor {}
