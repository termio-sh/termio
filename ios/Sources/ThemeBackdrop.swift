import UIKit
import GhosttyTheme

/// The active terminal theme's background, shared by every chrome page so the
/// whole app tints to whatever the user picked for the terminal — the inbox,
/// project pages, and terminal surface read as one continuous canvas instead of
/// a themed terminal floating on stark `.systemBackground`.
enum ThemeBackdrop {
    /// A dynamic color mirroring the active theme slot's background. It resolves
    /// the light/dark theme name per the trait's appearance, so a system
    /// light↔dark flip already re-resolves it for free (a theme *name* change
    /// does not flip traits, so callers must re-assign — see `installThemeBackdrop`).
    static var color: UIColor {
        UIColor { traits in
            let settings = MobileSettings.shared
            let dark = traits.userInterfaceStyle == .dark
            let name = dark ? settings.darkThemeName : settings.lightThemeName
            return GhosttyThemeCatalog.theme(named: name)
                .flatMap { UIColor(ghosttyHex: $0.background) }
                ?? (dark ? .black : .white)
        }
    }
}

extension UIViewController {
    /// Paints this chrome page with the terminal theme background and returns an
    /// observer token that re-asserts it whenever settings change. Re-assigning
    /// is required because a theme-*name* change (light→a different light theme)
    /// doesn't flip the trait collection, so UIKit keeps serving the stale
    /// resolved color until the dynamic `UIColor` is set again. Store the token
    /// and remove it in `deinit`, matching the other observers in these VCs.
    func installThemeBackdrop() -> NSObjectProtocol {
        view.backgroundColor = ThemeBackdrop.color
        return NotificationCenter.default.addObserver(
            forName: MobileSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.view.backgroundColor = ThemeBackdrop.color
        }
    }
}
