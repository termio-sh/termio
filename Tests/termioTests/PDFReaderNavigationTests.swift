import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import termio

/// Getting around a document without losing your place: following a link and coming back,
/// seeing what a link points at, finding words, and reopening where you stopped.
@MainActor
final class PDFReaderNavigationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var document: URL!

    private static let pageCount = 6
    /// Where the link on page two sits, and where it goes: page five, a third of the way down.
    private static let linkBounds = CGRect(x: 72, y: 394, width: 300, height: 20)
    private static let linkTarget = (page: 4, y: CGFloat(400))

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "pdf-navigation-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        document = directory.appendingPathComponent("linked.pdf")
        try writeLinkedDocument(to: document)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - Reading position

    func testReadingPositionIsKeptPerDocument() {
        let other = directory.appendingPathComponent("other.pdf")
        XCTAssertNil(PDFReadingPosition.place(for: document, defaults: defaults))
        PDFReadingPosition.remember(.init(page: 41, y: 512.5), for: document, defaults: defaults)
        PDFReadingPosition.remember(.init(page: 3, y: 90), for: other, defaults: defaults)
        XCTAssertEqual(PDFReadingPosition.place(for: document, defaults: defaults), .init(page: 41, y: 512.5))
        XCTAssertEqual(PDFReadingPosition.place(for: other, defaults: defaults), .init(page: 3, y: 90))
    }

    /// The list is bounded, and what goes is the document read longest ago — not the one
    /// that happens to sort first.
    func testReadingPositionsForgetTheOldestFirst() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        func url(_ index: Int) -> URL { directory.appendingPathComponent("book-\(index).pdf") }
        for index in 0..<205 {
            PDFReadingPosition.remember(.init(page: index, y: 0), for: url(index), defaults: defaults,
                                        now: start.addingTimeInterval(TimeInterval(index)))
        }
        XCTAssertNil(PDFReadingPosition.place(for: url(0), defaults: defaults))
        XCTAssertNil(PDFReadingPosition.place(for: url(4), defaults: defaults))
        XCTAssertEqual(PDFReadingPosition.place(for: url(5), defaults: defaults)?.page, 5)
        XCTAssertEqual(PDFReadingPosition.place(for: url(204), defaults: defaults)?.page, 204)
    }

    // MARK: - Link preview

    func testPreviewIsOfferedForLinksInsideTheDocumentOnly() throws {
        let pdf = try XCTUnwrap(PDFDocument(url: document))
        let page = try XCTUnwrap(pdf.page(at: 1))
        let inside = try XCTUnwrap(PDFLinkPreview.link(at: CGPoint(x: 100, y: 400), on: page))
        let destination = try XCTUnwrap(PDFLinkPreview.destination(of: inside))
        XCTAssertEqual(destination.page.map(pdf.index(for:)), Self.linkTarget.page)
        XCTAssertNil(PDFLinkPreview.link(at: CGPoint(x: 100, y: 600), on: page), "plain text is not a link")
        XCTAssertNil(PDFLinkPreview.link(at: CGPoint(x: 100, y: 300), on: page),
                     "a web link has no page to show")
    }

    /// A highlight drawn over a citation must not hide the citation from the pointer.
    func testPreviewFindsALinkUnderAHighlight() throws {
        let pdf = try XCTUnwrap(PDFDocument(url: document))
        let page = try XCTUnwrap(pdf.page(at: 1))
        page.addAnnotation(PDFAnnotation(bounds: Self.linkBounds.insetBy(dx: -4, dy: -4),
                                         forType: .highlight, withProperties: nil))
        XCTAssertNotNil(PDFLinkPreview.link(at: CGPoint(x: 100, y: 400), on: page))
    }

    func testPreviewImageHasTheSizeAskedFor() throws {
        let pdf = try XCTUnwrap(PDFDocument(url: document))
        let link = try XCTUnwrap(PDFLinkPreview.link(at: CGPoint(x: 100, y: 400), on: try XCTUnwrap(pdf.page(at: 1))))
        let destination = try XCTUnwrap(PDFLinkPreview.destination(of: link))
        let size = PDFLinkPreview.size(fitting: 2_000)
        XCTAssertEqual(size.width, PDFLinkPreview.maximumWidth)
        let image = try XCTUnwrap(PDFLinkPreview.image(of: destination, size: size))
        XCTAssertEqual(image.size.width, size.width, accuracy: 0.5)
        XCTAssertEqual(image.size.height, size.height, accuracy: 1)
        XCTAssertEqual(PDFLinkPreview.size(fitting: 100).width, 240, "a narrow pane still gets a readable preview")
    }

    // MARK: - History

    /// Following a link and pressing Back returns to the line you were reading, not to the
    /// top of the page it was on.
    func testBackReturnsToTheExactPlaceALinkWasFollowedFrom() throws {
        let (model, window) = try openInWindow()
        defer { window.orderOut(nil) }
        XCTAssertFalse(model.canGoBack)

        let pdf = try XCTUnwrap(model.pdfView.document)
        let from = try XCTUnwrap(pdf.page(at: 1))
        model.pdfView.go(to: PDFDestination(page: from, at: CGPoint(x: 0, y: 520)))
        settle(0.3)
        let before = try XCTUnwrap(model.pdfView.currentDestination)

        let target = try XCTUnwrap(pdf.page(at: Self.linkTarget.page))
        model.pdfView.go(to: PDFDestination(page: target, at: CGPoint(x: 0, y: Self.linkTarget.y)))
        settle(0.3)
        XCTAssertTrue(model.canGoBack)
        XCTAssertEqual(model.currentPage, Self.linkTarget.page)

        model.goBack()
        settle(0.3)
        let after = try XCTUnwrap(model.pdfView.currentDestination)
        XCTAssertEqual(after.page.map(pdf.index(for:)), before.page.map(pdf.index(for:)))
        XCTAssertEqual(after.point.y, before.point.y, accuracy: 2)
        XCTAssertTrue(model.canGoForward)

        model.goForward()
        settle(0.3)
        XCTAssertEqual(model.currentPage, Self.linkTarget.page)
    }

    /// ⌘[ and ⌘] belong to the document only while it has the keyboard: key equivalents are
    /// offered to every view in the window, a terminal pane beside the reader included.
    func testBackKeyIsTakenOnlyWhileTheDocumentHasTheKeyboard() throws {
        let (model, window) = try openInWindow()
        defer { window.orderOut(nil) }
        let pdf = try XCTUnwrap(model.pdfView.document)
        model.pdfView.go(to: PDFDestination(page: try XCTUnwrap(pdf.page(at: 3)), at: CGPoint(x: 0, y: 700)))
        settle(0.3)
        XCTAssertTrue(model.canGoBack)

        let back = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "[",
            charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33))

        window.makeFirstResponder(nil)
        XCTAssertFalse(model.pdfView.performKeyEquivalent(with: back))
        XCTAssertEqual(model.currentPage, 3)

        window.makeFirstResponder(model.pdfView)
        XCTAssertTrue(model.pdfView.performKeyEquivalent(with: back))
        settle(0.3)
        XCTAssertEqual(model.currentPage, 0)
    }

    // MARK: - Reopening

    func testADocumentReopensWhereItWasLeft() throws {
        let (model, window) = try openInWindow()
        let pdf = try XCTUnwrap(model.pdfView.document)
        model.pdfView.go(to: PDFDestination(page: try XCTUnwrap(pdf.page(at: 3)), at: CGPoint(x: 0, y: 450)))
        settle(0.3)
        let left = try XCTUnwrap(model.pdfView.currentDestination)
        model.rememberPosition()
        window.orderOut(nil)

        let (reopened, second) = try openInWindow()
        defer { second.orderOut(nil) }
        let back = try XCTUnwrap(reopened.pdfView.currentDestination)
        let reopenedDocument = try XCTUnwrap(reopened.pdfView.document)
        XCTAssertEqual(back.page.map(reopenedDocument.index(for:)), 3)
        XCTAssertEqual(back.point.y, left.point.y, accuracy: 3)
        XCTAssertFalse(reopened.canGoBack, "returning to your place is not a jump to go back from")
    }

    // MARK: - Find

    func testFindStartsFromThePageYouAreOnAndWraps() throws {
        let (model, window) = try openInWindow()
        defer { window.orderOut(nil) }
        model.go(toPage: 2)
        settle(0.3)

        model.find("NEEDLE", caseSensitive: false)
        try waitForFind(model)
        // One needle a page.
        XCTAssertEqual(model.findMatchCount, Self.pageCount)
        XCTAssertEqual(model.findIndex, 2, "the first result is the next one from where you are")
        XCTAssertEqual(model.currentPage, 2)

        model.stepFind(by: 1)
        XCTAssertEqual(model.findIndex, 3)
        model.stepFind(by: -4)
        XCTAssertEqual(model.findIndex, Self.pageCount - 1, "stepping back past the first wraps to the last")
        settle(0.3)
        XCTAssertEqual(model.currentPage, Self.pageCount - 1)

        model.find("NEEDLE", caseSensitive: true)
        try waitForFind(model)
        XCTAssertEqual(model.findMatchCount, 0, "the document spells it in lower case")

        model.endFind()
        XCTAssertNil(model.pdfView.highlightedSelections)
        XCTAssertEqual(model.findMatchCount, 0)
    }

    /// A search costs one history entry however many results are stepped through, so Back
    /// after it returns to the page it started on.
    func testBackAfterASearchReturnsToWhereItBegan() throws {
        let (model, window) = try openInWindow()
        defer { window.orderOut(nil) }
        model.find("needle", caseSensitive: false)
        try waitForFind(model)
        for _ in 0..<4 { model.stepFind(by: 1) }
        settle(0.3)
        XCTAssertEqual(model.currentPage, 4)

        model.goBack()
        settle(0.3)
        XCTAssertEqual(model.currentPage, 0)
        XCTAssertFalse(model.canGoBack)
    }

    // MARK: - The assembled reader

    /// Renders the reader mid-use into PNGs, composited by the window server so the PDF
    /// page and the preview popover are in the picture:
    ///
    ///     TERMIO_DUMP_DIR=/tmp/pdf swift test --filter PDFReaderNavigationTests/testRendersForVisualReview
    ///
    /// `TERMIO_SAMPLE_PDF` points it at a real document; the first link inside it is the
    /// one hovered.
    func testRendersForVisualReview() throws {
        guard let dump = ProcessInfo.processInfo.environment["TERMIO_DUMP_DIR"] else {
            throw XCTSkip("set TERMIO_DUMP_DIR to render the reader")
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        guard CGSessionCopyCurrentDictionary() != nil else { throw XCTSkip("needs a GUI session to lay out") }
        let directoryURL = URL(fileURLWithPath: dump, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let sample = ProcessInfo.processInfo.environment["TERMIO_SAMPLE_PDF"].map {
            URL(fileURLWithPath: $0)
        } ?? document!
        let query = ProcessInfo.processInfo.environment["TERMIO_SAMPLE_QUERY"] ?? "needle"
        let settings = AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(
                defaults: defaults, fileURL: directory.appendingPathComponent("settings.json"),
                domainName: suiteName))
        let store = TermioStore(workspaces: [Workspace(name: "Default")], settings: settings)
        let reader = PDFReaderView(url: sample, settings: settings, addToChat: { _ in },
                                   canAddToChat: { true }, onClose: {})
            .environmentObject(store)
            .environmentObject(settings)
        let hosting = NSHostingView(rootView: reader)
        hosting.frame = CGRect(x: 0, y: 0, width: 1100, height: 760)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        settle(1.5)
        defer { window.orderOut(nil) }

        let pdfView = try XCTUnwrap(firstDescendant(of: hosting, as: ContextMenuPDFView.self))
        let pdf = try XCTUnwrap(pdfView.document)

        // Hover the first internal link, wherever it is.
        var hovered: (page: PDFPage, link: PDFAnnotation)?
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            if let link = page.annotations.first(where: {
                $0.type == "Link" && PDFLinkPreview.destination(of: $0) != nil
            }) {
                hovered = (page, link)
                break
            }
        }
        let target = try XCTUnwrap(hovered, "the sample has no link inside the document")
        pdfView.go(to: target.link.bounds.insetBy(dx: 0, dy: -260), on: target.page)
        settle(0.5)
        let inView = pdfView.convert(CGPoint(x: target.link.bounds.midX, y: target.link.bounds.midY),
                                     from: target.page)
        let moved = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: pdfView.convert(inView, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        pdfView.mouseMoved(with: moved)
        settle(1.0)
        try capture(window, to: directoryURL.appendingPathComponent("link-hover-window.png"))
        let popover = try XCTUnwrap(
            NSApp.windows.first { $0 !== window && $0.isVisible && $0.className.contains("Popover") },
            "hovering a link opened no preview")
        try capture(popover, to: directoryURL.appendingPathComponent("link-hover-preview.png"))

        // Find, typed the way a person types it.
        NotificationCenter.default.post(name: .termioShowFindBar, object: nil)
        settle(0.6)
        let field = try XCTUnwrap(window.firstResponder as? NSTextView, "⌘F did not put the keyboard in the find field")
        field.insertText(query, replacementRange: field.selectedRange())
        settle(4.0)
        try capture(window, to: directoryURL.appendingPathComponent("find-window.png"))
    }

    // MARK: - Helpers

    /// The model's view inside a window that never comes on screen: PDFKit only lays pages
    /// out, scrolls and keeps history for a view that has a size and a window.
    private func openInWindow() throws -> (PDFReaderModel, NSWindow) {
        guard CGSessionCopyCurrentDictionary() != nil else { throw XCTSkip("needs a GUI session to lay out") }
        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        XCTAssertTrue(model.opened)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 700, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        model.pdfView.frame = CGRect(x: 0, y: 0, width: 700, height: 600)
        window.contentView = model.pdfView
        window.orderFrontRegardless()
        settle(0.5)
        return (model, window)
    }

    private func waitForFind(_ model: PDFReaderModel, file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(10)
        while model.isFinding, Date() < deadline { settle(0.05) }
        XCTAssertFalse(model.isFinding, "the search never finished", file: file, line: line)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func firstDescendant<View: NSView>(of view: NSView, as type: View.Type) -> View? {
        if let match = view as? View { return match }
        for subview in view.subviews {
            if let match = firstDescendant(of: subview, as: type) { return match }
        }
        return nil
    }

    /// The window as the window server composited it. `cacheDisplay` leaves PDFKit's tiled
    /// page layers blank, and a process may capture its own windows without Screen Recording.
    private func capture(_ window: NSWindow, to url: URL) throws {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"))
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let image = try XCTUnwrap(createImage(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?
            .takeRetainedValue())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    /// Six pages of numbered rows with one "needle" each. Page two links to page five, and
    /// carries a web link as well.
    private func writeLinkedDocument(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in 1...Self.pageCount {
            context.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            for row in 0..<20 {
                let text = row == 10 ? "Page \(page) row \(row): see section five, the needle"
                                     : "Page \(page) row \(row): the session lives on the box"
                text.draw(at: CGPoint(x: 72, y: 736 - CGFloat(row) * 34),
                          withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        let pdf = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(pdf.page(at: 1))
        let inside = PDFAnnotation(bounds: Self.linkBounds, forType: .link, withProperties: nil)
        inside.action = PDFActionGoTo(destination: PDFDestination(
            page: try XCTUnwrap(pdf.page(at: Self.linkTarget.page)), at: CGPoint(x: 0, y: Self.linkTarget.y)))
        page.addAnnotation(inside)
        let web = PDFAnnotation(bounds: CGRect(x: 72, y: 292, width: 300, height: 20),
                                forType: .link, withProperties: nil)
        web.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com")))
        page.addAnnotation(web)
        XCTAssertTrue(pdf.write(to: url))
    }
}
