import Foundation

/// Resolves a user-facing string from the String Catalog compiled into the
/// SwiftPM resource bundle. Every UI literal goes through this instead of a
/// bare `String(localized:)`, whose default `Bundle.main` holds no strings in
/// a packaged .app (see `Bundle.termioResources`).
func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .termioResources)
}
