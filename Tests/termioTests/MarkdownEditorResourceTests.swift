import XCTest
@testable import termio

/// What the rendered Markdown face is allowed to load.
///
/// This is the whole attack surface of that face: its page forbids the network outright,
/// so every byte reaching it comes through `DomdResource`. A Markdown image path is
/// somebody else's text, and the one that matters is the one that tries to leave the
/// document's folder.
final class DomdResourceTests: XCTestCase {
    func testPageAndEngineFilesResolveByName() {
        XCTAssertEqual(DomdResource.classify(path: "/index.html"), .page("index.html"))
        XCTAssertEqual(DomdResource.classify(path: "/app.js"), .page("app.js"))
        XCTAssertEqual(DomdResource.classify(path: "/domd.css"), .page("domd.css"))
        XCTAssertEqual(DomdResource.classify(path: "/katex.min.js"), .engine("katex.min.js"))
        XCTAssertEqual(DomdResource.classify(path: "/mermaid.min.js"), .engine("mermaid.min.js"))
    }

    /// Anything not on the allow-list is unreachable, so a crafted URL cannot read the
    /// rest of the resource bundle (agent manifests, the localization catalogs, skills).
    /// The prose face is fetched rather than inlined, so its names are reachable —
    /// and only those names.
    func testFontFilesResolveByName() {
        XCTAssertEqual(DomdResource.classify(path: "/iAWriterQuattroV.woff2"),
                       .font("iAWriterQuattroV.woff2"))
        XCTAssertEqual(DomdResource.classify(path: "/iAWriterQuattroV-Italic.woff2"),
                       .font("iAWriterQuattroV-Italic.woff2"))
    }

    /// A font request is an allow-list hit, never a directory walk: the licence file
    /// sitting beside the woff2s in Resources/Fonts is not reachable, and neither is
    /// any other name that happens to end in .woff2.
    func testUnlistedFontPathsAreRefused() {
        for path in ["/iAWriterQuattro-LICENSE.md", "/Anything.woff2", "/iAWriterQuattroV.woff",
                     "/Fonts/iAWriterQuattroV.woff2", "/iawriterquattrov.woff2"] {
            XCTAssertNil(DomdResource.classify(path: path), "reachable: \(path)")
        }
    }

    func testUnlistedBundlePathsAreRefused() {
        for path in ["/terminal.json", "/agents/claude.json", "/../Info.plist",
                     "/subdir/app.js", "/", "/LICENSE", "/app.js.map"] {
            XCTAssertNil(DomdResource.classify(path: path), "reachable: \(path)")
        }
    }

    func testImagePathsAreDecodedAndRelative() {
        XCTAssertEqual(DomdResource.classify(path: "/img/shot.png"), .image("shot.png"))
        // The page percent-encodes the ref, so a space survives the round trip.
        XCTAssertEqual(DomdResource.classify(path: "/img/my%20shot.png"), .image("my shot.png"))
        XCTAssertEqual(DomdResource.classify(path: "/img/assets%2Fa.png"), .image("assets/a.png"))
        XCTAssertNil(DomdResource.classify(path: "/img/"))
    }

    func testImagesResolveInsideTheDocumentFolder() throws {
        let root = URL(fileURLWithPath: "/tmp/domd-fixture/docs")
        XCTAssertEqual(
            DomdResource.imageURL(forRelativePath: "shot.png", under: root)?.path,
            "/tmp/domd-fixture/docs/shot.png")
        XCTAssertEqual(
            DomdResource.imageURL(forRelativePath: "./assets/shot.png", under: root)?.path,
            "/tmp/domd-fixture/docs/assets/shot.png")
        // A subfolder that climbs back inside is still inside.
        XCTAssertEqual(
            DomdResource.imageURL(forRelativePath: "assets/../shot.png", under: root)?.path,
            "/tmp/domd-fixture/docs/shot.png")
    }

    /// The case the confinement exists for: a document that asks for a file above its
    /// own folder gets nothing, however it spells the climb.
    func testImagesCannotEscapeTheDocumentFolder() {
        let root = URL(fileURLWithPath: "/tmp/domd-fixture/docs")
        for path in ["../secret.png", "../../etc/passwd", "a/../../secret.png",
                     "/etc/passwd", "", "../docs-sibling/x.png"] {
            XCTAssertNil(DomdResource.imageURL(forRelativePath: path, under: root),
                         "escaped with: \(path)")
        }
    }

    /// A sibling folder whose name merely starts with the document folder's name is a
    /// different folder — the confinement compares path *components*, not prefixes.
    func testSiblingFolderWithASharedPrefixIsOutside() {
        let root = URL(fileURLWithPath: "/tmp/domd-fixture/docs")
        XCTAssertNil(DomdResource.imageURL(forRelativePath: "../docs-private/x.png", under: root))
    }
}

/// The host hands the page its document by writing a JavaScript literal, so the encoding
/// is the seam where a document's own text could become script. Every case here is
/// something real Markdown contains.
final class DomdScriptEncodingTests: XCTestCase {
    private func encoded(_ value: String) -> String? {
        DomdScript.string(value)
    }

    func testOrdinaryTextRoundTripsAsAJSONString() throws {
        let literal = try XCTUnwrap(encoded("# Title\nbody\n"))
        XCTAssertEqual(literal, "\"# Title\\nbody\\n\"")
    }

    /// A fenced HTML example in a design doc contains `</script>`; unescaped it would
    /// close the element the literal is written into.
    func testScriptTerminatorsAreNeutralized() throws {
        let literal = try XCTUnwrap(encoded("see </script> and <div>"))
        XCTAssertFalse(literal.contains("</script>"))
        XCTAssertFalse(literal.contains("<"))
        XCTAssertTrue(literal.contains("\\u003C"))
    }

    /// U+2028 / U+2029 are legal in JSON strings but terminate a JavaScript line.
    func testLineSeparatorsAreEscaped() throws {
        let literal = try XCTUnwrap(encoded("a\u{2028}b\u{2029}c"))
        XCTAssertFalse(literal.contains("\u{2028}"))
        XCTAssertFalse(literal.contains("\u{2029}"))
        XCTAssertTrue(literal.contains("\\u2028"))
        XCTAssertTrue(literal.contains("\\u2029"))
    }

    func testQuotesBackslashesAndUnicodeSurvive() throws {
        let source = #"a "quoted" \path\ and 🙂 and 中文"#
        let literal = try XCTUnwrap(encoded(source))
        let data = try XCTUnwrap(literal.data(using: .utf8))
        // The literal must parse back as JSON to exactly the original text.
        let decoded = try JSONSerialization.jsonObject(
            with: try XCTUnwrap("[\(literal)]".data(using: .utf8)),
            options: []) as? [String]
        XCTAssertEqual(decoded?.first, source)
        XCTAssertGreaterThan(data.count, 0)
    }

    func testObjectPayloadCarriesTheDocument() throws {
        let literal = try XCTUnwrap(DomdScript.object([
            "markdown": "x", "editable": true, "appearance": "dark",
        ]))
        XCTAssertTrue(literal.hasPrefix("{"))
        XCTAssertTrue(literal.contains("\"markdown\""))
    }
}


/// The vendored page is actually in the resource bundle, at the paths the scheme handler
/// looks for.
///
/// termio has shipped a release-only crash twice from a resource that resolved in a dev
/// build and not in the packaged `.app` (see `Editor/Highlightr/README.md`). A rendered
/// face whose page 404s is a blank overlay with no error, so the lookup is pinned here
/// rather than discovered by opening a Markdown file in a release build.
final class DomdBundleResourceTests: XCTestCase {
    func testEveryPageFileIsInTheBundle() throws {
        for name in DomdResource.pageFiles {
            let url = Bundle.termioResources.url(
                forResource: (name as NSString).deletingPathExtension,
                withExtension: (name as NSString).pathExtension,
                subdirectory: "domd")
            XCTAssertNotNil(url, "missing from termio_termio.bundle/domd: \(name)")
        }
    }

    /// The prose face has to be in the bundle at the name the stylesheet asks for, or
    /// the page silently falls through to system sans — the exact regression this port
    /// exists to fix, and one that looks like "the font just isn't very good" rather
    /// than like a missing file.
    func testFontFilesAreInTheBundle() throws {
        for name in DomdResource.fontFiles {
            let url = Bundle.termioResources.url(
                forResource: (name as NSString).deletingPathExtension, withExtension: "woff2")
            XCTAssertNotNil(url, "missing from termio_termio.bundle: \(name)")
        }
    }

    /// The stylesheet and the allow-list have to name the same files. They are edited in
    /// different languages in different directories, so nothing but a test keeps them
    /// in step.
    func testTheStylesheetAsksOnlyForFontsTheHandlerServes() throws {
        let url = try XCTUnwrap(Bundle.termioResources.url(
            forResource: "app", withExtension: "css", subdirectory: "domd"))
        let css = try String(contentsOf: url, encoding: .utf8)
        var requested: Set<String> = []
        for line in css.split(separator: "\n") where line.contains(".woff2") {
            guard let open = line.range(of: "url(\""),
                  let close = line.range(of: "\")", range: open.upperBound..<line.endIndex)
            else { continue }
            requested.insert(String(line[open.upperBound..<close.lowerBound]))
        }
        XCTAssertFalse(requested.isEmpty, "the stylesheet no longer requests the prose face")
        XCTAssertTrue(requested.isSubset(of: DomdResource.fontFiles),
                      "the stylesheet asks for fonts the handler will refuse: "
                      + requested.subtracting(DomdResource.fontFiles).sorted().joined(separator: ", "))
    }

    /// KaTeX and mermaid are shared with the reader and the Issues pane, so they sit at
    /// the bundle root rather than in the vendored folder. The handler resolves them
    /// there; if that ever moves, this is what says so.
    func testEngineFilesAreAtTheBundleRoot() throws {
        // highlight.min.js joined this set when the rendered face gained syntax
        // highlighting; it is the same file and the same path the reader uses.
        for name in DomdResource.engineFiles {
            let url = Bundle.termioResources.url(
                forResource: (name as NSString).deletingPathExtension, withExtension: "js")
            XCTAssertNotNil(url, "missing from termio_termio.bundle: \(name)")
        }
    }

    /// The GPL terms the kernel ships under require its licence and exception files to be
    /// conveyed with it (see `Resources/domd/README.md`). They have to be *in the bundle*,
    /// not merely in the repo, because the bundle is what reaches a user.
    func testLicenceNoticesShipWithTheKernel() throws {
        for name in ["LICENSE", "LICENSE-EXCEPTIONS.md"] {
            let url = Bundle.termioResources.url(
                forResource: (name as NSString).deletingPathExtension,
                withExtension: (name as NSString).pathExtension,
                subdirectory: "domd")
            XCTAssertNotNil(url, "the kernel's \(name) is not shipped")
        }
    }

    /// The shipped bundle still carries the hydration refusal.
    ///
    /// The kernel has three load paths and only one of them is synchronous: measured at
    /// 0.12.3, a 2402-line document loaded through `initMd` or `resetMDChunked` yields
    /// 3882 of 19299 bytes immediately, and what it yields is a PREFIX of the real
    /// document. `flush` answers null only when the document is UNCHANGED, so a
    /// truncation would read as a legitimate edit and be written to disk — the one case
    /// that must be refused is the one that would otherwise sail through. The page
    /// refuses while it is not holding the whole document; this is the line that says
    /// the refusal is still in the build.
    func testTheBundleStillCarriesTheHydrationRefusal() throws {
        let url = try XCTUnwrap(Bundle.termioResources.url(
            forResource: "app", withExtension: "js", subdirectory: "domd"))
        let bundle = try String(contentsOf: url, encoding: .utf8)
        // Only the guard is asserted here. Which load path the page uses is NOT —
        // `resetMDChunked` is the kernel's own method and is in the bundle either way,
        // so grepping for it would test domd, not termio. The guard is the protection
        // that holds whichever path is used, because it checks the RESULT.
        XCTAssertTrue(bundle.contains("isHydrated"),
                      "the page no longer reports whether it holds the whole document")
        // The code rules were deleted once by a bad splice and nothing caught it: the
        // kernel's own .DOMD-Pre simply won, leaving 17px Consolas with no padding.
        // A stylesheet that no longer sizes code is the shape of that regression.
        let css = try String(contentsOf: XCTUnwrap(Bundle.termioResources.url(
            forResource: "app", withExtension: "css", subdirectory: "domd")), encoding: .utf8)
        for rule in ["DOMD-PreCode", "DOMD-Code", "DOMD-Kbd", "DOMD-Img"] {
            XCTAssertTrue(css.contains(rule), "the stylesheet no longer styles \(rule)")
        }
    }

    /// The page must never reach for the network: it is loaded over a custom scheme with
    /// no host, and its own CSP says so. A CDN `src` slipped into the bundle would work
    /// on a dev machine and fail on a plane.
    func testThePageLoadsNothingOverTheNetwork() throws {
        let url = try XCTUnwrap(Bundle.termioResources.url(
            forResource: "index", withExtension: "html", subdirectory: "domd"))
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(html.contains("//"), "absolute or protocol-relative URL in the page")
        XCTAssertTrue(html.contains("connect-src 'none'"), "the CSP no longer forbids the network")
    }
}


/// The image path EXAMPLE.md actually contains, walked end to end through the
/// mapping the page and the scheme handler agree on.
///
/// The page turns `![](web/landing/public/screenshots/hero1.png)` into
/// `termio-domd:///img/web%2Flanding%2F…`; this is the other half — the handler
/// turning that back into a file it can serve. It is deliberately pinned against the
/// real document in the repo, because the failure mode is a path that looks right and
/// resolves to nothing.
final class DomdImageResolutionTests: XCTestCase {
    /// The repo root, found by walking up from this file rather than hardcoded.
    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("EXAMPLE.md").path) {
                return url
            }
        }
        throw XCTSkip("run from a checkout that still has EXAMPLE.md at its root")
    }

    func testExampleDocumentImageResolvesToAFileThatExists() throws {
        let root = try repositoryRoot()
        let document = root.appendingPathComponent("EXAMPLE.md")
        let markdown = try String(contentsOf: document, encoding: .utf8)

        // The reference as the document actually writes it today.
        let reference = "web/landing/public/screenshots/hero1.png"
        XCTAssertTrue(markdown.contains("](\(reference))"),
                      "EXAMPLE.md no longer references \(reference); update this test with it")

        // What the page sends: percent-encoded, under /img/.
        let encoded = try XCTUnwrap(
            reference.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let path = "/img/" + encoded

        // What the handler makes of it.
        guard case .image(let relative)? = DomdResource.classify(path: path) else {
            return XCTFail("the handler did not classify \(path) as an image")
        }
        XCTAssertEqual(relative, reference, "percent-decoding lost the path")

        let resolved = try XCTUnwrap(
            DomdResource.imageURL(forRelativePath: relative,
                                  under: document.deletingLastPathComponent()),
            "the confinement check rejected the document's own image")
        XCTAssertEqual(resolved.path, root.appendingPathComponent(reference).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path),
                      "resolved to a file that is not there: \(resolved.path)")
    }

    /// The same walk for an image beside the document, the ordinary case.
    func testSiblingImageResolves() throws {
        let root = try repositoryRoot()
        let reference = "web/landing/public/logo.png"
        guard case .image(let relative)? = DomdResource.classify(
            path: "/img/" + (reference.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? reference))
        else { return XCTFail("not classified as an image") }
        let resolved = DomdResource.imageURL(forRelativePath: relative, under: root)
        XCTAssertEqual(resolved?.path, root.appendingPathComponent(reference).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved?.path ?? ""))
    }
}

/// When the rendered face may hold first responder.
///
/// Both faces stay mounted in the ZStack, so this rule has two jobs that pull opposite
/// ways: the visible face must actually get focus (without it the surface reads as
/// unclickable), and the dormant one must never take it from the source editor beside
/// it. The old code claimed focus once, from the page's `ready` message, at a moment
/// when the view might not be in a window yet — and a Markdown file opens straight into
/// the rendered face, so there was no later "became active" transition to retry on.
final class DomdFocusTests: XCTestCase {
    func testTheVisibleFaceInAWindowClaimsFocus() {
        XCTAssertTrue(DomdFocus.shouldClaim(isActive: true, isHidden: false, hasWindow: true))
    }

    /// The regression that made the face unclickable: asked before there was a window,
    /// the answer is no — and because nothing retried, no was permanent.
    func testAFaceWithNoWindowYetClaimsNothing() {
        XCTAssertFalse(DomdFocus.shouldClaim(isActive: true, isHidden: false, hasWindow: false))
    }

    /// The opposite hazard: a dormant face is still mounted, and must not pull the caret
    /// out of the source editor the user is typing in.
    func testTheDormantFaceNeverClaimsFocus() {
        XCTAssertFalse(DomdFocus.shouldClaim(isActive: false, isHidden: true, hasWindow: true))
        XCTAssertFalse(DomdFocus.shouldClaim(isActive: false, isHidden: false, hasWindow: true))
        XCTAssertFalse(DomdFocus.shouldClaim(isActive: true, isHidden: true, hasWindow: true))
    }
}

/// Who gets the Escape key.
///
/// Two claimants sit on opposite sides of the web view: the page's full-screen viewer,
/// whose listener lives in the document, and the editor's own close, which is AppKit's
/// `cancelOperation:` and never passes through the DOM at all. `stopPropagation` cannot
/// reach across that boundary, so the host is told when the overlay is up and consumes
/// the keystroke on its side. Consuming — not merely reading — is what makes it
/// deterministic: the page's "closed" report and `cancelOperation:` race, and whichever
/// lands first, exactly one Escape is absorbed.
final class DomdViewerEscapeTests: XCTestCase {
    @MainActor
    private func coordinator(viewerOpen: Bool) -> MarkdownEditorView.Coordinator {
        let made = MarkdownEditorView.Coordinator()
        made.receiveForTesting(["type": "viewer", "state": viewerOpen ? "open" : "closed"])
        return made
    }

    @MainActor
    func testEscapeIsNotClaimedWhenTheViewerIsClosed() {
        XCTAssertFalse(coordinator(viewerOpen: false).consumeViewerEscape())
    }

    @MainActor
    func testEscapeIsClaimedOnceWhileTheViewerIsOpen() {
        let made = coordinator(viewerOpen: true)
        XCTAssertTrue(made.consumeViewerEscape(), "the overlay should take the first Escape")
        // The second belongs to the editor again: one keystroke closes one thing.
        XCTAssertFalse(made.consumeViewerEscape())
    }

    /// The page closing itself (a click on the overlay) gives the key back without one
    /// having to be pressed.
    @MainActor
    func testClosingTheViewerReleasesTheClaim() {
        let made = coordinator(viewerOpen: true)
        made.receiveForTesting(["type": "viewer", "state": "closed"])
        XCTAssertFalse(made.consumeViewerEscape())
    }
}
