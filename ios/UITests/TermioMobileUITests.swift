import XCTest

/// Smoke suite over the app's deterministic demo states (`-demo …` launch
/// arguments), so every screen is reachable without a Mac companion link:
/// the home stack (the Projects root with its "Needs You" strip, and a pushed
/// project page), the terminal session screen (the iSH shape: the keyboard
/// types straight into the PTY, no separate prompt field), and the file viewer.
final class TermioMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", mode]
        app.launch()
        return app
    }

    // MARK: - Projects root (needs-you strip + project rows)

    func testRootListsProjectsWithNeedsYouStrip() {
        let app = launch("list")
        // The blocked session rides the root strip; the projects list under it.
        XCTAssertTrue(app.staticTexts["fix-sidebar"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["termio"].exists)      // project row
        XCTAssertTrue(app.staticTexts["vibewizard"].exists)  // second project
        // Non-blocked sessions live one level down, not on the root.
        XCTAssertFalse(app.staticTexts["landing-hero"].exists)
    }

    func testProjectRowPushesItsSessionPage() {
        let app = launch("list")
        let project = app.staticTexts["termio"]
        XCTAssertTrue(project.waitForExistence(timeout: 8))
        project.tap()
        // The project page: every session of that project, ready to open.
        XCTAssertTrue(app.staticTexts["landing-hero"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["fix-sidebar"].exists)
        // Back to the root.
        app.buttons["project.back"].tap()
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["landing-hero"].exists)
    }

    func testSidebarSortMenuReordersProjects() {
        let app = launch("list")
        let sort = app.buttons["Sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 8))
        sort.tap()
        // The Mac sidebar's two orders, mirrored.
        XCTAssertTrue(app.buttons["Name"].waitForExistence(timeout: 3))
        app.buttons["Name"].tap()
        XCTAssertTrue(app.staticTexts["termio"].waitForExistence(timeout: 3))
        // Restore the default so this test doesn't leak state.
        sort.tap()
        app.buttons["Recent Activity"].tap()
    }

    func testHomeTabSelectionSwitchesDestinations() {
        let app = launch("list")
        let projects = app.buttons["home.tab.projects"]
        let chats = app.buttons["home.tab.chats"]
        let terminals = app.buttons["home.tab.terminals"]
        XCTAssertTrue(projects.waitForExistence(timeout: 8))
        XCTAssertTrue(projects.isSelected)

        chats.tap()
        XCTAssertTrue(app.staticTexts["Chats"].waitForExistence(timeout: 3))
        XCTAssertTrue(chats.isSelected)
        XCTAssertFalse(projects.isSelected)

        terminals.tap()
        XCTAssertTrue(app.staticTexts["Terminals"].waitForExistence(timeout: 3))
        XCTAssertTrue(terminals.isSelected)
        XCTAssertFalse(chats.isSelected)
    }

    func testHomeUsesNativeTabBar() {
        let app = launch("list")
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 8))
        XCTAssertTrue(tabBar.buttons["home.tab.projects"].isSelected)
        XCTAssertTrue(tabBar.buttons["home.tab.chats"].exists)
        XCTAssertTrue(tabBar.buttons["home.tab.terminals"].exists)
        XCTAssertTrue(tabBar.buttons["home.tab.settings"].exists)
    }

    // MARK: - Session screen (direct terminal input)

    func testOpenSessionFromNeedsYouStripPushesTerminal() {
        let app = launch("list")
        // The strip is the fast path: blocked session → terminal, one tap,
        // no project page in between.
        let row = app.staticTexts["fix-sidebar"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        // The terminal pushes over the list: back chevron, and the surface
        // takes first responder so the key bar rides up with the keyboard.
        XCTAssertTrue(app.buttons["terminal.back"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["esc"].waitForExistence(timeout: 4))
    }

    func testTerminalSwipeRightPopsToList() {
        let app = launch("terminal")
        XCTAssertTrue(app.buttons["terminal.back"].waitForExistence(timeout: 8))
        // A rightward pan anywhere on the surface goes back home,
        // the same swipe Messages answers with a pop.
        app.swipeRight()
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["fix-sidebar"].exists)
    }

    func testTerminalBackChevronPopsToList() {
        let app = launch("terminal")
        let back = app.buttons["terminal.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 8))
        back.tap()
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["fix-sidebar"].exists)
    }

    func testTerminalFingerScrollDoesNotCrash() {
        let app = launch("terminal")
        XCTAssertTrue(app.buttons["terminal.back"].waitForExistence(timeout: 8))
        // Vertical pan over the terminal surface — the scroll path seeds the
        // ghostty mouse position via reflection into the wrapper's internals,
        // so this guards that chain against wrapper updates breaking it.
        app.swipeUp()
        app.swipeDown()
        XCTAssertTrue(app.buttons["terminal.back"].exists)
    }

    func testTypingReachesTerminalDirectly() {
        let app = launch("terminal")
        XCTAssertTrue(app.buttons["terminal.back"].waitForExistence(timeout: 8))
        // The surface is first responder on load — keystrokes go straight to
        // the PTY (the demo sandbox shell). No prompt field exists to grab
        // them, and the app must survive the round trip.
        XCTAssertTrue(app.buttons["esc"].waitForExistence(timeout: 4))
        app.typeText("echo hi\n")
        XCTAssertTrue(app.buttons["terminal.back"].exists)
    }

    func testTerminalKeyBarShowsStickyModifiers() {
        let app = launch("terminal")
        // The surface auto-focuses, so the key bar is already docked above
        // the keyboard: esc leads, then the sticky ctrl/alt pair.
        XCTAssertTrue(app.buttons["esc"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["ctrl"].exists)
        XCTAssertTrue(app.buttons["alt"].exists)
        // Arm ctrl — the state machine consumes it on the next QWERTY key;
        // this only asserts the tap round-trips without wedging the bar.
        app.buttons["ctrl"].tap()
        app.typeText("c")
        XCTAssertTrue(app.buttons["esc"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "terminal-key-bar"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Inspector drawer (file tree)

    func testInspectorFileTreeShowsLanguageIcons() {
        let app = launch("terminal")
        XCTAssertTrue(app.buttons["terminal.back"].waitForExistence(timeout: 8))
        // A leftward pan on the surface pulls the inspector drawer out.
        app.swipeLeft()
        // The mock tree's rows come up; files draw their language marks.
        XCTAssertTrue(app.staticTexts["App.swift"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["README.md"].exists)
        XCTAssertTrue(app.staticTexts["Package.swift"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "inspector-file-tree"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Attachments (live companion only)

    /// End-to-end over a REAL companion link: multi-select two photos and
    /// watch the queue upload them; the Mac-side paths are typed into the
    /// TUI itself, so the assertable signal is the attach slot going busy
    /// and coming back. Skips itself when no Mac companion server is
    /// reachable, so the demo suite stays green without one.
    func testAttachPhotoBatchUploadsToCompanion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-roster-url", "ws://127.0.0.1:8787"]
        app.launch()
        // Sessions live one level down now: root strip first (a blocked Claude
        // session rides it), else drill into the first project row.
        var row = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Claude Code'")).firstMatch
        if !row.waitForExistence(timeout: 15) {
            let firstProject = app.cells.firstMatch
            try XCTSkipUnless(firstProject.exists, "no live companion roster")
            firstProject.tap()
            row = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS 'Claude Code'")).firstMatch
            try XCTSkipUnless(row.waitForExistence(timeout: 5), "no live Claude session")
        }
        row.tap()
        let attach = app.buttons["Attach"]
        try XCTSkipUnless(attach.waitForExistence(timeout: 10), "session has no upload backend")
        // The (+) pops a source menu (Camera / Photos / Files); Photos hands
        // off to the system PHPicker.
        attach.tap()
        let photos = app.buttons["Photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 4))
        photos.tap()
        sleep(3)
        attachShot(app, "picker-open")
        // PHPicker is a REMOTE view: any element query into its tree kills
        // the runner with SIGKILL — drive it by screen coordinates only
        // (grid row 1 at y≈0.63, columns 0.17/0.50/0.83; Add at 0.91,0.167).
        tapNormalized(app, 0.17, 0.63)
        tapNormalized(app, 0.50, 0.63)
        attachShot(app, "picker-selected")
        tapNormalized(app, 0.91, 0.167)
        // The queue dims the attach slot while uploading and re-enables it
        // once every path has been typed into the TUI.
        let reEnabled = NSPredicate(format: "isEnabled == true")
        expectation(for: reEnabled, evaluatedWith: attach)
        waitForExpectations(timeout: 30)
        attachShot(app, "attach-upload-done")
    }

    private func tapNormalized(_ app: XCUIApplication, _ dx: Double, _ dy: Double) {
        app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
    }

    private func attachShot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Mac pairing (QR)

    /// Pairing lives in Settings ▸ Connectivity: its Scan QR Code row brings
    /// up the scanner sheet (camera-less simulators show its typed-address
    /// fallback instead of a preview — presentation is what's under test).
    func testScanEntryPresentsScanner() throws {
        let app = launch("list")
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 8))
        app.buttons["Settings"].tap()
        let connectivity = app.staticTexts["Connectivity"]
        XCTAssertTrue(connectivity.waitForExistence(timeout: 4))
        connectivity.tap()
        let scan = app.staticTexts["Scan QR Code"]
        XCTAssertTrue(scan.waitForExistence(timeout: 4))
        scan.tap()
        XCTAssertTrue(app.navigationBars["Scan QR Code"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Connectivity"].waitForExistence(timeout: 3))
    }

    // MARK: - File viewer

    func testFileViewerShowsHighlightedSource() {
        let app = launch("file")
        XCTAssertTrue(app.staticTexts["RootContainerViewController.swift"]
            .waitForExistence(timeout: 8))
        // Footer: language · size.
        XCTAssertTrue(app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "swift"))
            .firstMatch.exists)
    }
}
