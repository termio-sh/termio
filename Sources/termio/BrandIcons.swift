import SwiftUI

/// Renders an `AgentPreset`'s glyph: a muted SF Symbol for the plain terminal, or
/// a vendor's real brand mark for the coding agents, painted in that vendor's
/// brand color. The terminal symbol is decorative chrome, so it stays a calm
/// `.secondary` grey while the brand marks keep their full-strength vendor color —
/// that contrast is what makes an agent session read as "branded" at a glance.
/// Callers give a point `size`; both kinds are drawn at a matched optical weight
/// so a row of mixed icons stays visually even.
struct AgentIconView: View {
    let agent: AgentPreset
    var size: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        switch agent.icon {
        case .symbol(let name):
            // No built-in uses an SF Symbol (the terminal uses a Hugeicons mark), so
            // this is the user-agent / fallback path: paint it in the agent's own tint
            // rather than a fixed grey, matching how its spinner reads.
            Image(systemName: name)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(agent.tintColor)
        case .image(let url):
            AgentImageView(url: url, size: size)
        case .terminalGlyph:
            // A thin stroke already reads lighter than the filled brand tiles, so
            // paint it at full label strength (`.primary`) — anything less looks
            // washed out next to the row text and the opaque vendor marks.
            HugeIconView(icon: .terminal, size: size, color: .primary)
        case .vector(let logo):
            // A brand mark fills its whole box, where an SF Symbol's glyph sits
            // inside cap height with breathing room; shrinking the box a touch
            // makes the two read at the same optical size side by side.
            BrandLogoShape(logo: logo)
                .fill(logo.tint, style: FillStyle(eoFill: logo.usesEvenOddFill))
                .frame(width: size * 0.82, height: size * 0.82)
        }
    }
}

/// Renders any raster/vector image URL as the same rounded icon tile. Bundled
/// favicons and user PNG/SVG paths deliberately share this code path; resource
/// names are resolved before they enter the runtime icon model.
struct AgentImageView: View {
    let url: URL
    var size: CGFloat

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

extension BrandLogo {
    /// Each vendor's brand color, so an agent session reads as its real product at
    /// a glance. The fixed tints are mid-tone enough to stay legible on both the
    /// light grey badge and a dark sidebar. Codex's mark is monochrome, so it uses
    /// full-strength ink (pure black on light, pure white on dark) — not `.primary`,
    /// which is the ~85%-opacity label color and reads as a washed-out grey next to
    /// the opaque favicon tiles.
    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
        case .codex: return .monochromeInk
        }
    }
}


extension Color {
    /// Pure black in light mode, pure white in dark mode, at full opacity. Unlike
    /// `.primary` (label color, ~85% opacity) this keeps a monochrome brand mark at
    /// its original strength while still adapting to the system appearance.
    static let monochromeInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    })
}

/// A `Shape` that draws a `BrandLogo` from its embedded SVG path, scaled to fit
/// the available rect (preserving the source 24×24 aspect, centered).
struct BrandLogoShape: Shape {
    let logo: BrandLogo

    func path(in rect: CGRect) -> Path {
        scaledVectorPath(SVGPath(logo.pathData).cgPath, viewBox: logo.viewBox, in: rect)
    }
}

/// Renders a `HugeIcon` as a rounded stroke (Hugeicons' native line style) in the
/// given color, sized to a square `size`-point box. The stroke width tracks the
/// source's 1.5px-on-24 ratio so the line stays optically right at any size, with
/// a small floor so it never thins to a hairline at sidebar sizes.
struct HugeIconView: View {
    let icon: HugeIcon
    var size: CGFloat
    var color: Color
    /// Overrides the size-derived stroke width. Used where a mark reads too thin at a
    /// small size (e.g. the section disclosure chevron), so it can be bumped heavier
    /// without also growing the glyph.
    var lineWidthOverride: CGFloat? = nil

    var body: some View {
        HugeIconShape(icon: icon)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }

    private var lineWidth: CGFloat {
        lineWidthOverride ?? max(1.1, size * 1.5 / icon.viewBox)
    }
}

/// A `Shape` that draws a `HugeIcon`'s SVG path scaled to fit the rect, to be
/// stroked (not filled) by `HugeIconView`.
struct HugeIconShape: Shape {
    let icon: HugeIcon

    func path(in rect: CGRect) -> Path {
        // Fit by the mark's actual ink box, not the nominal 24 viewBox: Hugeicons'
        // marks fill their viewBox by different amounts across (the terminal glyph
        // spans 18 of 24, a folder 20), so plain viewBox-fitting left them visibly
        // unequal in width in the sidebar's shared icon column. Normalizing every
        // mark's ink width to a fixed fraction of the box — the terminal mark's own
        // 18/24 fill — keeps the terminal identical while pulling the wider folder
        // marks in to match it, so same-`size` HugeIcons line up.
        let glyph = SVGPath(icon.pathData).cgPath
        let ink = glyph.boundingBoxOfPath
        guard ink.width > 0, ink.height > 0 else { return Path(glyph) }
        let targetWidth = rect.width * (18.0 / 24.0)
        let scale = min(targetWidth / ink.width, rect.height / ink.height)
        var transform = CGAffineTransform(
            translationX: rect.midX - scale * ink.midX,
            y: rect.midY - scale * ink.midY
        )
        .scaledBy(x: scale, y: scale)
        return Path(glyph.copy(using: &transform) ?? glyph)
    }
}

/// VS Code's "codicon" glyphs, used for the file-explorer header actions so termio's
/// toolbar reads like VS Code's. The SVG path data is lifted verbatim from Microsoft's
/// `vscode-codicons` (16×16 grid), which is licensed CC BY 4.0 — attribution: the
/// Codicon icons © Microsoft, https://github.com/microsoft/vscode-codicons. Each icon
/// is one or more filled sub-paths (most codicons are a single nonzero-filled path;
/// `collapseAll` stacks three, the last even-odd to punch the square's hole).
enum Codicon {
    case newFile, newFolder, refresh, collapseAll

    /// The 16×16 authoring grid all codicons share.
    var viewBox: CGFloat { 16 }

    /// The filled sub-paths, drawn back-to-front in one color. `eoFill` marks a path
    /// that needs even-odd winding (a ring/hole) rather than the SVG-default nonzero.
    var subpaths: [(data: String, eoFill: Bool)] {
        switch self {
        case .newFile:
            return [("M5 14C4.448 14 4 13.552 4 13V3C4 2.448 4.448 2 5 2H8V4.5C8 5.328 8.672 6 9.5 6H12V6.025C12.344 6.056 12.677 6.121 13 6.213V5.414C13 5.016 12.842 4.635 12.561 4.353L9.647 1.439C9.366 1.158 8.984 1 8.586 1H5C3.895 1 3 1.895 3 3V13C3 14.105 3.895 15 5 15H7.261C7.008 14.693 6.791 14.357 6.607 14H5ZM9 2.207L11.793 5H9.5C9.224 5 9 4.776 9 4.5V2.207ZM11.5 7C9.015 7 7 9.015 7 11.5C7 13.985 9.015 16 11.5 16C13.985 16 16 13.985 16 11.5C16 9.015 13.985 7 11.5 7ZM14 12H12V14C12 14.276 11.776 14.5 11.5 14.5C11.224 14.5 11 14.276 11 14V12H9C8.724 12 8.5 11.776 8.5 11.5C8.5 11.224 8.724 11 9 11H11V9C11 8.724 11.224 8.5 11.5 8.5C11.776 8.5 12 8.724 12 9V11H14C14.276 11 14.5 11.224 14.5 11.5C14.5 11.776 14.276 12 14 12Z", false)]
        case .newFolder:
            return [("M2 4.5V6H5.58579C5.71839 6 5.84557 5.94732 5.93934 5.85355L7.29289 4.5L5.93934 3.14645C5.84557 3.05268 5.71839 3 5.58579 3H3.5C2.67157 3 2 3.67157 2 4.5ZM1 4.5C1 3.11929 2.11929 2 3.5 2H5.58579C5.98361 2 6.36514 2.15804 6.64645 2.43934L8.20711 4H12.5C13.8807 4 15 5.11929 15 6.5V7.25716C14.6929 7.00353 14.3578 6.78261 14 6.59971V6.5C14 5.67157 13.3284 5 12.5 5H8.20711L6.64645 6.56066C6.36514 6.84197 5.98361 7 5.58579 7H2V11.5C2 12.3284 2.67157 13 3.5 13H6.20703C6.30564 13.3486 6.43777 13.6832 6.59971 14H3.5C2.11929 14 1 12.8807 1 11.5V4.5ZM16 11.5C16 13.9853 13.9853 16 11.5 16C9.01472 16 7 13.9853 7 11.5C7 9.01472 9.01472 7 11.5 7C13.9853 7 16 9.01472 16 11.5ZM12 9C12 8.72386 11.7761 8.5 11.5 8.5C11.2239 8.5 11 8.72386 11 9V11H9C8.72386 11 8.5 11.2239 8.5 11.5C8.5 11.7761 8.72386 12 9 12H11V14C11 14.2761 11.2239 14.5 11.5 14.5C11.7761 14.5 12 14.2761 12 14V12H14C14.2761 12 14.5 11.7761 14.5 11.5C14.5 11.2239 14.2761 11 14 11H12V9Z", false)]
        case .refresh:
            return [("M3 8C3 5.23858 5.23858 3 8 3C9.63527 3 11.0878 3.78495 12.0005 5H10C9.72386 5 9.5 5.22386 9.5 5.5C9.5 5.77614 9.72386 6 10 6H12.8904C12.8973 6.00014 12.9041 6.00014 12.911 6H13C13.2761 6 13.5 5.77614 13.5 5.5V2.5C13.5 2.22386 13.2761 2 13 2C12.7239 2 12.5 2.22386 12.5 2.5V4.03138C11.4009 2.78613 9.79253 2 8 2C4.68629 2 2 4.68629 2 8C2 11.3137 4.68629 14 8 14C11.1301 14 13.6999 11.6035 13.9756 8.54488C14.0003 8.26985 13.7975 8.0268 13.5225 8.00202C13.2474 7.97723 13.0044 8.1801 12.9796 8.45512C12.75 11.003 10.6079 13 8 13C5.23858 13 3 10.7614 3 8Z", false)]
        case .collapseAll:
            return [
                ("M14 4.27051C14.5999 4.62053 15 5.26009 15 6V11C15 13.21 13.21 15 11 15H6C5.26009 15 4.62053 14.5999 4.27051 14H11C12.65 14 14 12.65 14 11V4.27051Z", false),
                ("M9.5 7C9.776 7 10 7.224 10 7.5C10 7.776 9.776 8 9.5 8H5.5C5.224 8 5 7.776 5 7.5C5 7.224 5.224 7 5.5 7H9.5Z", false),
                ("M11 2C12.103 2 13 2.897 13 4V11C13 12.103 12.103 13 11 13H4C2.897 13 2 12.103 2 11V4C2 2.897 2.897 2 4 2H11ZM4 3C3.449 3 3 3.449 3 4V11C3 11.552 3.449 12 4 12H11C11.551 12 12 11.552 12 11V4C12 3.449 11.551 3 11 3H4Z", true),
            ]
        }
    }
}

/// Renders a `Codicon` as a filled vector glyph in `color`, sized to a square box —
/// the file-explorer header's toolbar icons. Sub-paths are stacked (same color, so
/// overlaps simply union) which lets each keep its own winding rule.
struct CodiconView: View {
    let icon: Codicon
    var size: CGFloat
    var color: Color = .primary

    var body: some View {
        ZStack {
            ForEach(Array(icon.subpaths.enumerated()), id: \.offset) { _, subpath in
                CodiconShape(pathData: subpath.data, viewBox: icon.viewBox)
                    .fill(color, style: FillStyle(eoFill: subpath.eoFill))
            }
        }
        .frame(width: size, height: size)
    }
}

/// A `Shape` for one codicon sub-path, scaled from its 16×16 grid to fit the rect.
private struct CodiconShape: Shape {
    let pathData: String
    let viewBox: CGFloat

    func path(in rect: CGRect) -> Path {
        scaledVectorPath(SVGPath(pathData).cgPath, viewBox: viewBox, in: rect)
    }
}

/// Scales a parsed glyph from its square `viewBox` to fit `rect`, centered,
/// preserving aspect. Shared by the filled brand marks and the stroked Hugeicons.
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

/// A small parser for the subset of SVG path syntax used by the embedded brand
/// marks — moveto/lineto/horizontal/vertical, cubic and quadratic curves (with
/// their smooth variants), elliptical arcs, and close. The SVG and Core
/// Graphics coordinate spaces both run y-downward, so no axis flip is needed.
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

/// A forgiving number/command scanner for SVG path data. Handles the quirks the
/// brand marks rely on: implicit separators, signs that start a new number, a
/// second decimal point that ends one (`.686.0608` is two numbers), and arc
/// flags packed as single digits.
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
