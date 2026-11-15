import AppKit
import PDFKit

/// What a link inside the document points at, drawn small enough to read without going
/// there. A citation, a figure reference or a section number is a question — "what is
/// that?" — and most of the time the answer is a glance, not a trip.
enum PDFLinkPreview {
    /// The popover's width at most; a narrow pane gets a narrower one.
    static let maximumWidth: CGFloat = 520
    /// Height over width. Wide enough for a bibliography entry, tall enough for most of a figure.
    private static let aspect: CGFloat = 0.72
    /// How much of the preview sits above the link's anchor. A reference list entry and a
    /// section heading run downward from their anchor, but a figure sits *above* the caption
    /// its anchor is on, so starting the preview at the anchor shows a caption and no figure.
    private static let leadFraction: CGFloat = 0.4

    /// Where a link annotation goes inside this document, or `nil` for a web link.
    static func destination(of annotation: PDFAnnotation) -> PDFDestination? {
        let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
        guard destination?.page != nil else { return nil }
        return destination
    }

    /// The internal link under a point in page space. Scans the page's links rather than
    /// asking for the topmost annotation, so a highlight laid over a citation doesn't hide it.
    static func link(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.first { annotation in
            annotation.type == "Link" && annotation.bounds.contains(point) && destination(of: annotation) != nil
        }
    }

    static func size(fitting width: CGFloat) -> CGSize {
        let width = min(maximumWidth, max(240, width))
        return CGSize(width: width, height: (width * aspect).rounded())
    }

    /// The part of the destination page around the anchor, at `size`. Drawn when the image
    /// is first shown, on the main thread like every other page render in the reader.
    static func image(of destination: PDFDestination, size: CGSize) -> NSImage? {
        // A rotated page's box and its drawing disagree about which way is up; no preview
        // is better than one of the wrong strip.
        guard let page = destination.page, page.rotation == 0 else { return nil }
        let box = page.bounds(for: .cropBox)
        guard box.width > 1, box.height > 1 else { return nil }

        let regionHeight = min(box.height, box.width * size.height / size.width)
        // A destination that names a page but no point reports a coordinate far outside the
        // page; that means "the top".
        let anchored = box.minY...box.maxY ~= destination.point.y
        let anchorY = anchored ? destination.point.y : box.maxY
        let top = min(box.maxY, max(box.minY + regionHeight, anchorY + regionHeight * leadFraction))
        let region = CGRect(x: box.minX, y: top - regionHeight, width: box.width, height: regionHeight)
        let scale = size.width / region.width

        return NSImage(size: CGSize(width: size.width, height: regionHeight * scale), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(rect)
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -region.minX, y: -region.minY)
            page.draw(with: .cropBox, to: context)
            context.restoreGState()
            // A tick in the margin at the anchor: in a reference list of twelve entries,
            // which one the link meant.
            if anchored {
                let y = (anchorY - region.minY) * scale
                context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
                context.fill(CGRect(x: 0, y: y - 9, width: 3, height: 9))
            }
            return true
        }
    }

    /// A popover holding one preview. It never takes the keyboard and never animates: a
    /// hover cue that fades in is still arriving when the pointer has moved on.
    @MainActor
    static func popover(showing image: NSImage) -> NSPopover {
        let view = NSImageView(image: image)
        view.imageScaling = .scaleNone
        view.frame = CGRect(origin: .zero, size: image.size)
        let controller = NSViewController()
        controller.view = view
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = image.size
        popover.behavior = .applicationDefined
        popover.animates = false
        return popover
    }
}

/// Where you were in each document, so a book reopens on the page you left it at.
///
/// Kept in the app's defaults and not in the marks sidecar: the sidecar is a repo file that
/// reads well in a diff, and a line that changes every time you scroll would bury the marks.
enum PDFReadingPosition {
    struct Place: Equatable {
        /// Zero-based page at the top of the view.
        let page: Int
        /// The view's top-left corner on that page, in page space. Both coordinates: on a
        /// page stored rotated, scrolling down the screen moves along the page's x.
        let x: Double
        let y: Double
    }

    private static let key = "pdfReaderPositions"
    /// Documents remembered. Past it the one read longest ago is dropped.
    private static let limit = 200

    static func place(for url: URL, defaults: UserDefaults = .standard) -> Place? {
        guard let entry = (defaults.dictionary(forKey: key) as? [String: [Double]])?[url.path],
              entry.count == 4, entry[0] >= 0 else { return nil }
        return Place(page: Int(entry[0]), x: entry[1], y: entry[2])
    }

    static func remember(_ place: Place, for url: URL, defaults: UserDefaults = .standard,
                         now: Date = Date()) {
        var all = defaults.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        all[url.path] = [Double(place.page), place.x, place.y, now.timeIntervalSinceReferenceDate]
        if all.count > limit {
            let oldest = all.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }
            for (path, _) in oldest.prefix(all.count - limit) { all.removeValue(forKey: path) }
        }
        defaults.set(all, forKey: key)
    }
}
