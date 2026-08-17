import XCTest
import GhosttyTheme
import TermioShared
@testable import termio

/// The theme library's two load-bearing guarantees: a theme written to disk reads
/// back as the same theme, and the store's index stays the curated list it claims
/// to be — every name resolvable, the brightness split intact, and no two rows in
/// a slot close enough to read as the same theme.
@MainActor
final class ThemeLibraryTests: XCTestCase {
    // MARK: - write / parse

    func testWriteRoundTripsThroughParse() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("theme-library-round-trip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let definition = GhosttyThemeDefinition(
            name: "Round Trip",
            background: "1e1e2e",
            foreground: "cdd6f4",
            cursorColor: "f5e0dc",
            cursorText: "11111b",
            selectionBackground: "585b70",
            selectionForeground: "cdd6f4",
            palette: [0: "45475a", 1: "f38ba8", 7: "bac2de", 15: "a6adc8"]
        )
        try ThemeLibrary.write(definition, into: folder)

        let url = folder.appendingPathComponent(definition.name, isDirectory: false)
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(ThemeLibrary.parse(name: definition.name, contents: contents), definition)
    }

    /// A theme with no optional colors at all must survive the trip too — the
    /// serializer has to omit those keys rather than write empty values that parse
    /// back as blank hex.
    func testWriteRoundTripsAThemeWithoutOptionalColors() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("theme-library-minimal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let definition = GhosttyThemeDefinition(
            name: "Bare", background: "ffffff", foreground: "000000")
        try ThemeLibrary.write(definition, into: folder)

        let contents = try String(
            contentsOf: folder.appendingPathComponent(definition.name, isDirectory: false),
            encoding: .utf8)
        XCTAssertEqual(ThemeLibrary.parse(name: definition.name, contents: contents), definition)
    }

    /// Every catalog theme the store can install has to survive being written and
    /// read back, not just a hand-picked one.
    func testEveryStoreThemeRoundTrips() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("theme-library-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for name in ThemeLibrary.storeCatalog {
            let definition = try XCTUnwrap(ThemeLibrary.storeTheme(named: name))
            try ThemeLibrary.write(definition, into: folder)
            let contents = try String(
                contentsOf: folder.appendingPathComponent(name, isDirectory: false), encoding: .utf8)
            XCTAssertEqual(ThemeLibrary.parse(name: name, contents: contents), definition, name)
        }
    }

    // MARK: - Store catalog

    func testEveryStoreCatalogNameResolves() {
        let unresolved = ThemeStoreCatalog.names.filter { GhosttyThemeCatalog.theme(named: $0) == nil }
        XCTAssertEqual(unresolved, [], "store names missing from the pinned catalog")
        // The filter that drops stale rows must be dropping nothing today; a name
        // silently disappearing from the store is exactly what it would look like.
        XCTAssertEqual(ThemeLibrary.storeCatalog, ThemeStoreCatalog.names)
    }

    /// Derived from each theme's own background luminance, never a hand-kept
    /// per-name assignment — that is the whole point of `isDark` deciding the slot.
    func testStoreCatalogSplitsThirtyFiveDarkAndFifteenLight() {
        let definitions = ThemeLibrary.storeCatalog.compactMap { ThemeLibrary.storeTheme(named: $0) }
        XCTAssertEqual(definitions.count, 50)
        XCTAssertEqual(definitions.filter(\.isDark).count, 35)
        XCTAssertEqual(definitions.filter { !$0.isDark }.count, 15)
    }

    /// The curation rule that keeps the store free of near-duplicates: within a
    /// slot, no two themes sit closer than ΔE 12 on the weighted Lab metric the
    /// list was built with. Rejected pairs measure far below it (TokyoNight
    /// Night vs Storm 2.6, Catppuccin Mocha vs Macchiato 4.3), so a family that
    /// sneaks a second variant onto the list fails here.
    func testNoTwoStoreThemesInASlotReadAsTheSameTheme() throws {
        for dark in [true, false] {
            let definitions = ThemeLibrary.storeCatalog
                .compactMap { ThemeLibrary.storeTheme(named: $0) }
                .filter { $0.isDark == dark }
            for first in 0..<definitions.count {
                for second in (first + 1)..<definitions.count {
                    let distance = try weightedDistance(definitions[first], definitions[second])
                    XCTAssertGreaterThanOrEqual(
                        distance, 12,
                        "\(definitions[first].name) and \(definitions[second].name) read as one theme")
                }
            }
        }
    }

    // MARK: - Distinctness metric

    /// Weighted mean CIE Lab distance between two themes: the background dominates
    /// what a theme looks like (×2.5), the body text follows (×1.2), and the six
    /// ANSI colors a user recognizes a scheme by carry the rest (×0.7 each).
    private func weightedDistance(
        _ first: GhosttyThemeDefinition, _ second: GhosttyThemeDefinition
    ) throws -> Double {
        var total = 0.0
        var weight = 0.0
        func accumulate(_ firstHex: String, _ secondHex: String, _ factor: Double) throws {
            let a = try XCTUnwrap(lab(firstHex), firstHex)
            let b = try XCTUnwrap(lab(secondHex), secondHex)
            let distance = ((a.0 - b.0) * (a.0 - b.0)
                + (a.1 - b.1) * (a.1 - b.1)
                + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
            total += factor * distance
            weight += factor
        }
        try accumulate(first.background, second.background, 2.5)
        try accumulate(first.foreground, second.foreground, 1.2)
        for slot in 1...6 {
            guard let firstColor = first.palette[slot], let secondColor = second.palette[slot] else { continue }
            try accumulate(firstColor, secondColor, 0.7)
        }
        guard weight > 0 else { return 0 }
        return total / weight
    }

    /// sRGB hex → CIE Lab under D65, the space the ΔE above is measured in.
    private func lab(_ hex: String) -> (Double, Double, Double)? {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        func linear(_ channel: UInt32) -> Double {
            let component = Double(channel) / 255
            return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        let red = linear((value >> 16) & 0xff)
        let green = linear((value >> 8) & 0xff)
        let blue = linear(value & 0xff)
        let x = (red * 0.4124564 + green * 0.3575761 + blue * 0.1804375) / 0.95047
        let y = red * 0.2126729 + green * 0.7151522 + blue * 0.0721750
        let z = (red * 0.0193339 + green * 0.1191920 + blue * 0.9503041) / 1.08883
        func pivot(_ component: Double) -> Double {
            component > 216.0 / 24389.0 ? pow(component, 1.0 / 3.0) : (841.0 / 108.0) * component + 4.0 / 29.0
        }
        let fx = pivot(x), fy = pivot(y), fz = pivot(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
