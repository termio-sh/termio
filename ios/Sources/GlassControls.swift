import SwiftUI
import TermioShared
import UIKit

extension UIFont {
    /// Telegram's counter type: SF Rounded + tabular digits — every numbered
    /// badge and count label in the app draws from this one recipe.
    static func roundedCounter(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

extension UIButton {
    /// iMessage-style floating control: on iOS 26 the symbol rides a circular
    /// Liquid Glass button (the system look for controls floating over
    /// content — back, compose, close); earlier it stays the flat symbol.
    /// Only for free-floating buttons — controls inside pills, rows, or
    /// keyboards keep their plain style, matching Messages.
    func applyGlassSymbol(_ symbol: String, pointSize: CGFloat = 15) {
        if #available(iOS 26.0, *) {
            var config = UIButton.Configuration.glass()
            config.image = UIImage(systemName: symbol)
            config.cornerStyle = .capsule
            config.preferredSymbolConfigurationForImage = .init(pointSize: pointSize, weight: .semibold)
            configuration = config
        } else {
            setImage(UIImage(systemName: symbol), for: .normal)
        }
    }

    /// The Hugeicons twin of `applyGlassSymbol`, for floating buttons whose glyph
    /// should read from the same stroke family as the native tab bar and sidebar
    /// rows. `boxSize` is the glyph's drawn size in points; the stroke is the
    /// shared 1.5px-on-24 recipe.
    func applyGlassIcon(_ icon: HugeIcon, boxSize: CGFloat) {
        let image = icon.strokeImage(boxSize: boxSize)
        if #available(iOS 26.0, *) {
            var config = UIButton.Configuration.glass()
            config.image = image
            config.cornerStyle = .capsule
            configuration = config
        } else {
            setImage(image, for: .normal)
        }
    }
}

extension HugeIcon {
    /// The glyph as a tintable template `UIImage` — a bitmap for UIKit chrome
    /// like the native tab bar, where SwiftUI's `HugeIconView` can't be used
    /// directly. Same stroke recipe (1.5px-on-24 with the hairline floor,
    /// round caps); the path is inset by the stroke's half-width so round
    /// caps at the glyph's edge don't clip against the bitmap bounds.
    func strokeImage(boxSize: CGFloat, strokeWeight: CGFloat = 1.5) -> UIImage {
        let lineWidth = max(1.1, boxSize * strokeWeight / viewBox)
        let bounds = CGRect(x: 0, y: 0, width: boxSize, height: boxSize)
        let path = HugeIconShape(icon: self)
            .path(in: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            .cgPath
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { context in
            let cg = context.cgContext
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(lineWidth)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.addPath(path)
            cg.strokePath()
        }.withRenderingMode(.alwaysTemplate)
    }

    /// The glyph's filled twin, for a selected tab — nil for marks that have no
    /// solid reading (see `solidSubpaths`). Drawn from the same path at the same
    /// placement as `strokeImage`, minus the half-stroke inset, so the fill's
    /// outer edge lands exactly where the outline's did and the mark neither
    /// shifts nor changes size when the tab is selected. The remaining subpaths
    /// are punched back out in `.clear`, which is what keeps the bubble's dots,
    /// the terminal's prompt, and the gear's bore legible against the fill: a
    /// closed one becomes a hole, an open one a cleared stroke of the same
    /// round-capped line the outline drew.
    func solidImage(boxSize: CGFloat) -> UIImage? {
        guard let solidSubpaths else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: boxSize, height: boxSize)
        let subpaths = HugeIconShape(icon: self).path(in: bounds).cgPath.subpaths
        // A shade heavier than the outline's own line: a cleared mark on a solid
        // body reads thinner than the same line drawn on its own.
        let detailWidth = max(1.4, boxSize * 2.0 / viewBox)
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            for (index, subpath) in subpaths.enumerated() where solidSubpaths.contains(index) {
                cg.addPath(subpath.path)
            }
            cg.fillPath(using: .evenOdd)

            let detail = subpaths.enumerated()
                .filter { !solidSubpaths.contains($0.offset) }
                .map(\.element)
            cg.setBlendMode(.clear)
            for hole in detail where hole.isClosed {
                cg.addPath(hole.path)
            }
            cg.fillPath(using: .evenOdd)

            cg.setLineWidth(detailWidth)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for mark in detail where !mark.isClosed {
                cg.addPath(mark.path)
            }
            cg.strokePath()
        }.withRenderingMode(.alwaysTemplate)
    }
}

/// One `M`-delimited run of a glyph, and whether it closed — a closed run
/// bounds an area (the gear's bore), an open one is a line (the terminal's
/// prompt), and the solid renderer punches each out accordingly.
private struct Subpath {
    let path: CGPath
    let isClosed: Bool
}

private extension CGPath {
    /// The path split at each `moveTo`, so a glyph's body can be filled while
    /// its interior detail is drawn separately. Walking the built path rather
    /// than splitting the source string keeps relative `m` subpaths correct.
    var subpaths: [Subpath] {
        var paths: [CGMutablePath] = []
        var closed: [Bool] = []
        applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                let subpath = CGMutablePath()
                subpath.move(to: points[0])
                paths.append(subpath)
                closed.append(false)
            case .addLineToPoint:
                paths.last?.addLine(to: points[0])
            case .addQuadCurveToPoint:
                paths.last?.addQuadCurve(to: points[1], control: points[0])
            case .addCurveToPoint:
                paths.last?.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closeSubpath:
                paths.last?.closeSubpath()
                if !closed.isEmpty { closed[closed.count - 1] = true }
            @unknown default:
                break
            }
        }
        return zip(paths, closed).map { Subpath(path: $0, isClosed: $1) }
    }
}
