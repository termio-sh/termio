import Foundation

/// Resolves a user-facing string from `Localizable.xcstrings`. Xcode compiles
/// the catalog into the app bundle itself, so `Bundle.main` is already the
/// right table — unlike the Mac app, whose strings live in a SwiftPM resource
/// bundle and need an explicit one. The call shape is deliberately the same as
/// the Mac's `localized(_:)` so one sweep finds every UI string on both sides.
func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}
