import XCTest
@testable import termio

/// The trajectory page's palette, checked against the contrast it actually needs.
///
/// Observability tools publish this distinction and it is easy to get wrong: Elastic's
/// EUI ships a colourblind-safe categorical palette for *graphics* and warns that only
/// its status palette carries real contrast ratios, with a separate brightened variant
/// for colour used behind text. This page uses its kind colours both ways — a bar in the
/// histogram (a graphic, 3:1) and the KIND tag on every row (10px text, 4.5:1) — so the
/// two roles are separate variables, and this pins both.
final class TrajectoryPaletteTests: XCTestCase {
    /// The `:root` custom properties out of a rendered document, so the test reads the
    /// values that actually ship rather than a copy of them.
    private func palette(dark: Bool) throws -> [String: String] {
        let html = SessionTraceRenderer.placeholder(
            message: "x", theme: .builtin(dark: dark), title: "t", includeHeader: false)
        guard let root = html.range(of: ":root {"),
              let end = html.range(of: "}", range: root.upperBound..<html.endIndex)
        else { throw Failure.noRoot }
        var found: [String: String] = [:]
        for line in html[root.upperBound..<end.lowerBound].split(separator: ";") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("--"), value.hasPrefix("#") { found[name] = value }
        }
        return found
    }

    private enum Failure: Error { case noRoot }

    private func luminance(_ hex: String) -> Double {
        let digits = Array(hex.dropFirst())
        let channels = stride(from: 0, to: 6, by: 2).map { index -> Double in
            let byte = UInt8(String(digits[index...index + 1]), radix: 16) ?? 0
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    private func contrast(_ a: String, _ b: String) -> Double {
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// Every colour the page renders *as text* clears WCAG AA for small text. The KIND
    /// tag is 10px, so 4.5:1 is the bar it has to clear, not 3:1.
    func testTextColorsClearAAOnBothThemes() throws {
        for dark in [true, false] {
            let palette = try palette(dark: dark)
            guard let background = palette["--bg"] else { return XCTFail("no --bg") }
            for name in ["--fg", "--muted", "--accent", "--k-tool", "--k-err-text"] {
                guard let color = palette[name] else { return XCTFail("missing \(name)") }
                let ratio = contrast(color, background)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(name) \(color) on \(background) is \(String(format: "%.2f", ratio)):1 "
                        + "in the \(dark ? "dark" : "light") theme — text needs 4.5:1")
            }
        }
    }

    /// Colours used only as marks — the error rail, histogram segments — carry the
    /// graphic threshold instead. Kept separate so a mark is never quietly promoted to
    /// text without meeting the higher bar.
    func testMarkColorsClearTheGraphicThreshold() throws {
        for dark in [true, false] {
            let palette = try palette(dark: dark)
            guard let background = palette["--bg"] else { return XCTFail("no --bg") }
            for name in ["--k-err", "--k-user", "--k-agent"] {
                guard let color = palette[name] else { continue }
                let ratio = contrast(color, background)
                XCTAssertGreaterThanOrEqual(
                    ratio, 3.0,
                    "\(name) \(color) is \(String(format: "%.2f", ratio)):1 in the "
                        + "\(dark ? "dark" : "light") theme — a graphic needs 3:1")
            }
        }
    }
}
