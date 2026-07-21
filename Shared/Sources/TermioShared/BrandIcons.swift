// Brand vectors shared by the macOS sidebar and the iOS session list, so both
// platforms render the same marks from the same SVG data: agent logos (filled
// vendor marks), Hugeicons stroke glyphs, and the SVG path parser under them.
// Ported from the desktop app's BrandIcons.swift; the desktop still carries
// its own copy until it migrates onto this package.

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Icon reference

/// The data-shaped icon description shared by manifests and the companion wire.
/// Every field is optional so older peers decode additions and an empty reference
/// naturally falls back to the terminal glyph.
public struct IconRef: Codable, Sendable, Equatable {
    public var vector: String?
    public var asset: String?
    public var png: String?
    public var symbol: String?

    public init(
        vector: String? = nil,
        asset: String? = nil,
        png: String? = nil,
        symbol: String? = nil
    ) {
        self.vector = vector
        self.asset = asset
        self.png = png
        self.symbol = symbol
    }
}

public extension Color {
    /// Pure black in light mode, pure white in dark mode, at full opacity —
    /// keeps a monochrome brand mark at original strength (unlike `.primary`,
    /// the ~85%-opacity label color).
    static let monochromeInk: Color = {
        #if canImport(UIKit)
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? .white : .black
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
        })
        #endif
    }()
}

// MARK: - Agent icon

/// A session's leading mark at rest: the vendor logo (the working spinner is
/// composed by the row, not here).
public struct AgentIconView: View {
    let ref: IconRef
    let size: CGFloat
    let tint: Color

    public init(ref: IconRef, size: CGFloat = 13, tint: Color = .monochromeInk) {
        self.ref = ref
        self.size = size
        self.tint = tint
    }

    @ViewBuilder
    public var body: some View {
        if let png = ref.png, let image = Self.image(base64: png) {
            imageTile(image)
        } else if let vector = ref.vector, let logo = BrandLogo(reference: vector) {
            BrandLogoShape(logo: logo)
                .fill(logo.tint, style: FillStyle(eoFill: logo.usesEvenOddFill))
                .frame(width: size, height: size)
        } else if let asset = ref.asset, !asset.isEmpty {
            BrandImageView(resourceName: asset, size: size)
        } else if let symbol = ref.symbol, !symbol.isEmpty {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(tint)
        } else {
            HugeIconView(icon: .terminal, size: size, color: .monochromeInk)
        }
    }

    private func imageTile(_ image: Image) -> some View {
        image
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private static func image(base64: String) -> Image? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }
}

// MARK: - Brand favicon tiles

/// A vendor brand mark carried as its real favicon image (the marks whose
/// detail — Pi's monochrome glyph, OpenCode's two-tone box, Cursor's shaded
/// cube — a single-fill vector path can't reproduce), bundled under this
/// package's `Resources`. The resource name arrives as data instead of an enum,
/// so adding an agent never adds an icon switch.
public struct BrandImageView: View {
    let resourceName: String
    let size: CGFloat

    public init(resourceName: String, size: CGFloat) {
        self.resourceName = resourceName
        self.size = size
    }

    public var body: some View {
        if let image = loadImage() {
            image
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            // The name arrived over the wire from a peer whose bundle may not
            // match ours (an older Mac naming an asset this build dropped) —
            // degrade to the terminal glyph, visibly, never an invisible tile.
            HugeIconView(icon: .terminal, size: size, color: .monochromeInk)
        }
    }

    /// Loads the bundled favicon, or `nil` if it is missing.
    ///
    /// iOS-ONLY on purpose: `Bundle.module` is safe there because the app is
    /// built by Xcode, whose generated accessor resolves the resource bundle
    /// correctly. The macOS app is built with plain `swift build`, where the
    /// generated accessor checks only the .app root plus a hardcoded
    /// build-machine path and fatalErrors in a packaged release (the v0.2.4
    /// crash) — so the desktop must never reach this and keeps loading its own
    /// favicon copies from `Bundle.termioResources`.
    private func loadImage() -> Image? {
        #if canImport(UIKit)
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path)
        else { return nil }
        return Image(uiImage: image)
        #else
        return nil
        #endif
    }
}

// MARK: - Vector data

/// A Hugeicons stroke glyph, stored as its source SVG path data on a 24×24
/// viewBox, drawn as a rounded *stroke* by `HugeIconShape` (Hugeicons' 1.5px
/// line style). Multiple `<path>` elements are concatenated into one data
/// string — each starts with `M`, so the parser treats them as subpaths.
public enum HugeIcon: Hashable, Sendable {
    case terminal
    case folder
    case folderOpen

    /// Side length of the source SVG's square viewBox (Hugeicons uses 24).
    public var viewBox: CGFloat { 24 }

    public var pathData: String {
        switch self {
        case .terminal:
            return "M7.5 7.5L8.72654 8.55719C9.24218 9.00163 9.5 9.22386 9.5 9.5C9.5 9.77614 9.24218 9.99836 8.72654 10.4428L7.5 11.5 M11.5 12.5H15.5 M12 21C15.7497 21 17.6246 21 18.9389 20.0451C19.3634 19.7367 19.7367 19.3634 20.0451 18.9389C21 17.6246 21 15.7497 21 12C21 8.25027 21 6.3754 20.0451 5.06107C19.7367 4.6366 19.3634 4.26331 18.9389 3.95491C17.6246 3 15.7497 3 12 3C8.25027 3 6.3754 3 5.06107 3.95491C4.6366 4.26331 4.26331 4.6366 3.95491 5.06107C3 6.3754 3 8.25027 3 12C3 15.7497 3 17.6246 3.95491 18.9389C4.26331 19.3634 4.6366 19.7367 5.06107 20.0451C6.3754 21 8.25027 21 12 21Z"
        case .folder:
            return "M8 7H16.75C18.8567 7 19.91 7 20.6667 7.50559C20.9943 7.72447 21.2755 8.00572 21.4944 8.33329C22 9.08996 22 10.1433 22 12.25C22 15.7612 22 17.5167 21.1573 18.7779C20.7926 19.3238 20.3238 19.7926 19.7779 20.1573C18.5167 21 16.7612 21 13.25 21H12C7.28595 21 4.92893 21 3.46447 19.5355C2 18.0711 2 15.714 2 11V7.94427C2 6.1278 2 5.21956 2.38032 4.53806C2.65142 4.05227 3.05227 3.65142 3.53806 3.38032C4.21956 3 5.1278 3 6.94427 3C8.10802 3 8.6899 3 9.19926 3.19101C10.3622 3.62712 10.8418 4.68358 11.3666 5.73313L12 7"
        case .folderOpen:
            return "M2.36064 15.1788C1.98502 13.2956 1.79721 12.354 2.33084 11.7159C2.36642 11.6734 2.40405 11.6323 2.44361 11.5927C3.03686 11 4.08674 11 6.1865 11H17.8135C19.9133 11 20.9631 11 21.5564 11.5927C21.5959 11.6323 21.6336 11.6734 21.6692 11.7159C22.2028 12.354 22.015 13.2956 21.6394 15.1788C21.0993 17.8865 20.8292 19.2404 19.8109 20.0721C19.7414 20.1288 19.6698 20.1833 19.5961 20.2354C18.5163 21 17.0068 21 13.9876 21H10.0124C6.99323 21 5.48367 21 4.40387 20.2354C4.33022 20.1833 4.2586 20.1288 4.18914 20.0721C3.17075 19.2404 2.90072 17.8865 2.36064 15.1788Z M4 11V5.5C4 4.11929 5.11929 3 6.5 3H8.92963C9.59834 3 10.2228 3.3342 10.5937 3.8906L12 6M12 6H8.5M12 6H17.5C18.8807 6 20 7.11929 20 8.5V11"
        }
    }
}

/// A vendor brand mark, stored as its official SVG path so it renders crisp
/// at any size without shipping binary image assets.
public enum BrandLogo: Hashable, Sendable {
    case claude
    case codex
    case grok

    public init?(reference: String) {
        switch reference.lowercased() {
        case "claude": self = .claude
        case "codex": self = .codex
        case "grok": self = .grok
        default: return nil
        }
    }

    /// Side length of the source SVG's square viewBox (the marks use 24).
    public var viewBox: CGFloat { 24 }

    public var tint: Color {
        switch self {
        case .claude: Color(red: 0.851, green: 0.467, blue: 0.341) // #D97757
        case .codex, .grok: .monochromeInk
        }
    }

    /// Whether the mark's holes are cut with the even-odd fill rule. Codex's
    /// mark and Grok's slashed ring declare `fill-rule="evenodd"` to carve their
    /// glyphs out of the blob; Claude's single outline needs nonzero.
    public var usesEvenOddFill: Bool {
        switch self {
        case .codex, .grok: true
        case .claude: false
        }
    }

    public var pathData: String {
        switch self {
        case .claude:
            return "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
        case .codex:
            return "M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z"
        case .grok:
            // xAI Grok mark (x.ai): a slashed ring, two subpaths cut with even-odd
            // fill. Source viewBox 24, `currentColor` (monochrome).
            return "M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272.98 2.369.542 5.215-1.41 7.169-1.951 1.954-4.667 2.382-7.149 1.406l-2.711 1.257c3.889 2.661 8.611 2.003 11.562-.953 2.341-2.344 3.066-5.539 2.388-8.42l.006.007c-.983-4.232.242-5.924 2.75-9.383.06-.082.12-.164.179-.248l-3.301 3.305v-.01L9.267 15.292M7.623 16.723c-2.792-2.67-2.31-6.801.071-9.184 1.761-1.763 4.647-2.483 7.166-1.425l2.705-1.25a7.808 7.808 0 00-1.829-1A8.975 8.975 0 005.984 5.83c-2.533 2.536-3.33 6.436-1.962 9.764 1.022 2.487-.653 4.246-2.34 6.022-.599.63-1.199 1.259-1.682 1.925l7.62-6.815"
        }
    }
}

// MARK: - Shapes

/// A `Shape` that draws a `BrandLogo` from its embedded SVG path, scaled to
/// fit the available rect (preserving the source 24×24 aspect, centered).
public struct BrandLogoShape: Shape {
    let logo: BrandLogo

    public init(logo: BrandLogo) {
        self.logo = logo
    }

    public func path(in rect: CGRect) -> Path {
        scaledVectorPath(SVGPath(logo.pathData).cgPath, viewBox: logo.viewBox, in: rect)
    }
}

/// Renders a `HugeIcon` as a rounded stroke in the given color. The stroke
/// width tracks the source's 1.5px-on-24 ratio with a small floor so the
/// line never thins to a hairline at list sizes.
public struct HugeIconView: View {
    let icon: HugeIcon
    let size: CGFloat
    let color: Color

    public init(icon: HugeIcon, size: CGFloat, color: Color) {
        self.icon = icon
        self.size = size
        self.color = color
    }

    public var body: some View {
        HugeIconShape(icon: icon)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }

    private var lineWidth: CGFloat {
        max(1.1, size * 1.5 / icon.viewBox)
    }
}

/// A `Shape` that draws a `HugeIcon`'s SVG path scaled to fit the rect, to be
/// stroked (not filled) by `HugeIconView`.
public struct HugeIconShape: Shape {
    let icon: HugeIcon

    public init(icon: HugeIcon) {
        self.icon = icon
    }

    public func path(in rect: CGRect) -> Path {
        scaledVectorPath(SVGPath(icon.pathData).cgPath, viewBox: icon.viewBox, in: rect)
    }
}

/// Scales a parsed glyph from its square `viewBox` to fit `rect`, centered,
/// preserving aspect. Shared by the filled brand marks and stroked Hugeicons.
private func scaledVectorPath(_ glyph: CGPath, viewBox: CGFloat, in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / viewBox
    var transform = CGAffineTransform(
        translationX: rect.midX - viewBox * scale / 2,
        y: rect.midY - viewBox * scale / 2
    )
    .scaledBy(x: scale, y: scale)
    let scaled = glyph.copy(using: &transform) ?? glyph
    return Path(scaled)
}

// MARK: - SVG path parser

/// A small parser for the subset of SVG path syntax used by the embedded
/// brand marks — moveto/lineto/horizontal/vertical, cubic and quadratic
/// curves (with smooth variants), elliptical arcs, and close. SVG and Core
/// Graphics coordinate spaces both run y-downward, so no axis flip.
private struct SVGPath {
    let pathData: String

    init(_ pathData: String) { self.pathData = pathData }

    var cgPath: CGPath {
        let path = CGMutablePath()
        var scanner = Scanner(pathData)

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var previousCommand: Character = " "

        func reflectedCubic() -> CGPoint {
            guard let last = lastCubicControl, "CcSs".contains(previousCommand) else { return current }
            return CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
        }
        func reflectedQuad() -> CGPoint {
            guard let last = lastQuadControl, "QqTt".contains(previousCommand) else { return current }
            return CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
        }

        while !scanner.isAtEnd {
            // A bare number means "repeat the previous command"; after a moveto
            // the implicit repeat is a lineto, per the SVG spec.
            var command: Character
            if let explicit = scanner.readCommand() {
                command = explicit
            } else if previousCommand != " " {
                command = previousCommand
                if command == "M" { command = "L" }
                if command == "m" { command = "l" }
            } else {
                break
            }

            let relative = command.isLowercase
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch command.uppercased() {
            case "M":
                current = point(scanner.readNumber(), scanner.readNumber())
                path.move(to: current)
                subpathStart = current
            case "L":
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addLine(to: current)
            case "H":
                let x = scanner.readNumber()
                current = relative ? CGPoint(x: current.x + x, y: current.y) : CGPoint(x: x, y: current.y)
                path.addLine(to: current)
            case "V":
                let y = scanner.readNumber()
                current = relative ? CGPoint(x: current.x, y: current.y + y) : CGPoint(x: current.x, y: y)
                path.addLine(to: current)
            case "C":
                let c1 = point(scanner.readNumber(), scanner.readNumber())
                let c2 = point(scanner.readNumber(), scanner.readNumber())
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2
            case "S":
                let c1 = reflectedCubic()
                let c2 = point(scanner.readNumber(), scanner.readNumber())
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2
            case "Q":
                let c = point(scanner.readNumber(), scanner.readNumber())
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c
            case "T":
                let c = reflectedQuad()
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c
            case "A":
                let rx = scanner.readNumber()
                let ry = scanner.readNumber()
                let rotation = scanner.readNumber()
                let largeArc = scanner.readFlag()
                let sweep = scanner.readFlag()
                let end = point(scanner.readNumber(), scanner.readNumber())
                addArc(to: path, from: current, to: end, rx: rx, ry: ry,
                       rotationDegrees: rotation, largeArc: largeArc, sweep: sweep)
                current = end
            case "Z":
                path.closeSubpath()
                current = subpathStart
            default:
                break
            }

            if command.uppercased() != "C" && command.uppercased() != "S" { lastCubicControl = nil }
            if command.uppercased() != "Q" && command.uppercased() != "T" { lastQuadControl = nil }
            previousCommand = command
        }
        return path
    }

    /// Appends an SVG elliptical arc to `path` as a sequence of cubic Béziers,
    /// using the endpoint-to-center conversion from the SVG implementation notes.
    private func addArc(
        to path: CGMutablePath, from start: CGPoint, to end: CGPoint,
        rx rxIn: CGFloat, ry ryIn: CGFloat, rotationDegrees: CGFloat,
        largeArc: Bool, sweep: Bool
    ) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 { path.addLine(to: end); return }
        if start == end { return }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        let radiiCheck = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if radiiCheck > 1 {
            let scale = sqrt(radiiCheck)
            rx *= scale
            ry *= scale
        }

        let rx2 = rx * rx, ry2 = ry * ry, x1Sq = x1 * x1, y1Sq = y1 * y1
        let numerator = max(0, rx2 * ry2 - rx2 * y1Sq - ry2 * x1Sq)
        let denominator = rx2 * y1Sq + ry2 * x1Sq
        var coefficient = denominator == 0 ? 0 : sqrt(numerator / denominator)
        if largeArc == sweep { coefficient = -coefficient }

        let cxPrime = coefficient * (rx * y1 / ry)
        let cyPrime = coefficient * (-ry * x1 / rx)
        let centerX = cosPhi * cxPrime - sinPhi * cyPrime + (start.x + end.x) / 2
        let centerY = sinPhi * cxPrime + cosPhi * cyPrime + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let length = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            let clamped = max(-1, min(1, length == 0 ? 0 : dot / length))
            let result = acos(clamped)
            return ux * vy - uy * vx < 0 ? -result : result
        }

        let ux = (x1 - cxPrime) / rx, uy = (y1 - cyPrime) / ry
        let vx = (-x1 - cxPrime) / rx, vy = (-y1 - cyPrime) / ry
        let startAngle = angle(1, 0, ux, uy)
        var sweepAngle = angle(ux, uy, vx, vy)
        if !sweep && sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep && sweepAngle < 0 { sweepAngle += 2 * .pi }

        let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let delta = sweepAngle / CGFloat(segments)
        let controlScale = 4.0 / 3.0 * tan(delta / 4)

        func onEllipse(_ cosA: CGFloat, _ sinA: CGFloat) -> CGPoint {
            let ex = rx * cosA, ey = ry * sinA
            return CGPoint(x: cosPhi * ex - sinPhi * ey + centerX,
                           y: sinPhi * ex + cosPhi * ey + centerY)
        }
        func tangent(_ cosA: CGFloat, _ sinA: CGFloat) -> CGPoint {
            let ex = -rx * sinA, ey = ry * cosA
            return CGPoint(x: cosPhi * ex - sinPhi * ey,
                           y: sinPhi * ex + cosPhi * ey)
        }

        var a = startAngle
        for _ in 0..<segments {
            let cosA = cos(a), sinA = sin(a)
            let cosB = cos(a + delta), sinB = sin(a + delta)
            let p1 = onEllipse(cosA, sinA)
            let p2 = onEllipse(cosB, sinB)
            let t1 = tangent(cosA, sinA)
            let t2 = tangent(cosB, sinB)
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + controlScale * t1.x, y: p1.y + controlScale * t1.y),
                control2: CGPoint(x: p2.x - controlScale * t2.x, y: p2.y - controlScale * t2.y)
            )
            a += delta
        }
    }
}

/// A forgiving number/command scanner for SVG path data. Handles the quirks
/// the brand marks rely on: implicit separators, signs that start a new
/// number, a second decimal point that ends one (`.686.0608` is two numbers),
/// and arc flags packed as single digits.
private struct Scanner {
    private let characters: [Character]
    private var index = 0

    init(_ string: String) { characters = Array(string) }

    var isAtEnd: Bool {
        var probe = index
        while probe < characters.count, isSeparator(characters[probe]) { probe += 1 }
        return probe >= characters.count
    }

    private func isSeparator(_ c: Character) -> Bool {
        c == " " || c == "," || c == "\n" || c == "\t" || c == "\r"
    }

    private mutating func skipSeparators() {
        while index < characters.count, isSeparator(characters[index]) { index += 1 }
    }

    mutating func readCommand() -> Character? {
        skipSeparators()
        guard index < characters.count, characters[index].isLetter else { return nil }
        defer { index += 1 }
        return characters[index]
    }

    mutating func readNumber() -> CGFloat {
        skipSeparators()
        var text = ""
        if index < characters.count, characters[index] == "+" || characters[index] == "-" {
            text.append(characters[index])
            index += 1
        }
        var seenDot = false
        var seenExponent = false
        while index < characters.count {
            let c = characters[index]
            if c.isNumber {
                text.append(c)
                index += 1
            } else if c == "." && !seenDot && !seenExponent {
                seenDot = true
                text.append(c)
                index += 1
            } else if (c == "e" || c == "E") && !seenExponent {
                seenExponent = true
                text.append(c)
                index += 1
                if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                    text.append(characters[index])
                    index += 1
                }
            } else {
                break
            }
        }
        return CGFloat(Double(text) ?? 0)
    }

    mutating func readFlag() -> Bool {
        skipSeparators()
        guard index < characters.count else { return false }
        let c = characters[index]
        if c == "0" || c == "1" {
            index += 1
            return c == "1"
        }
        return readNumber() != 0
    }
}
