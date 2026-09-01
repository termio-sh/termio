import GhosttyTerminal
import GhosttyTheme
import PhotosUI
import ShellCraftKit
import TermioShared
import UIKit
import UniformTypeIdentifiers

/// Full-screen terminal for one session — the bundled demo sandbox shell for
/// mock sessions, or a live companion connection to a Mac session. The right
/// screen edge slides in the inspector drawer (file tree + changes); the
/// terminal keeps rendering, dimmed, behind it.
final class TerminalViewController: UIViewController {
    private enum Backend {
        case demoShell
        case device(DeviceEndpoint)
    }

    private let session: MockSession
    private let backend: Backend

    /// Set by RootContainerViewController: the session DIED (exit or lost
    /// connection), as opposed to the user navigating back, which parks the
    /// screen in the container's keep-alive cache.
    var onClose: (() -> Void)?

    /// Set by RootContainerViewController: go back to the session list. The
    /// container keeps this screen parked (view installed, surface alive)
    /// rather than tearing it down — the plain nav-pop that used to do this
    /// freed the surface and raced libghostty's render threads.
    var onRequestBack: (() -> Void)?

    /// Interactive back-swipe hooks (set by RootContainerViewController). The
    /// rightward drag is finger-tracked instead of a discrete pop: `Began`
    /// starts the interactive transition, `Changed` reports the horizontal
    /// finger offset (>= 0, measured in a stable space so moving the screen
    /// doesn't feed back), `Ended` reports the release velocity and whether the
    /// drag crossed the commit threshold.
    var onBackBegan: (() -> Void)?
    var onBackChanged: ((CGFloat) -> Void)?
    var onBackEnded: ((_ velocityX: CGFloat, _ commit: Bool) -> Void)?

    private lazy var terminalView = DisplayTerminalView(frame: .zero)
    /// Whether the terminal held the keyboard when an interactive back began, so a
    /// cancelled (non-committed) swipe can hand focus back instead of leaving the
    /// keyboard dismissed (the drag resigns it up front, matching `goBack()`).
    private var terminalWasFirstResponderAtBackBegin = false
    /// Last size actually sent to the engine + the pending coalesced refit —
    /// see viewDidLayoutSubviews for why resizes are rationed.
    private var lastFittedSize: CGSize = .zero
    private var fitDebounce: DispatchWorkItem?
    /// The area the surface may occupy, pinned by constraints between the
    /// header and the keyboard. The surface is framed by hand inside it
    /// (`layoutTerminalSurface`): while another device sizes the session, the
    /// surface has to be laid out at that device's grid, not this rectangle.
    private let terminalHost: UIView = {
        let host = UIView()
        host.clipsToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        return host
    }()
    private lazy var shellSession = ShellSession(shell: defaultSandboxShell)
    private var companion: DeviceSession?
    private var companionSession: InMemoryTerminalSession?
    private let headerBar = UIStackView()
    private let contextLabel = UILabel()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private var surfaceConfigured = false
    private var backendStarted = false
    /// Timestamp of the last renderer-death surface rebuild, to debounce a
    /// scroll that re-trips libghostty's health failsafe many times in a row.
    private var lastRendererRecovery: Date?
    /// Opaque backdrop-colored cover pinned over the surface. libghostty paints
    /// its "non-functional" panel INTO the surface a frame or two before we can
    /// react, so we mask it during the rebuild — the user sees a plain
    /// background blink (like a repaint), never the alarming error text.
    private let rendererCoverView: UIView = {
        let v = UIView()
        v.isHidden = true
        v.isUserInteractionEnabled = false
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    private var settingsObserver: NSObjectProtocol?
    /// System edit menu over the live selection (Copy/Paste), presented at
    /// the touch-selection release point.
    private lazy var editMenuInteraction = UIEditMenuInteraction(delegate: self)
    /// Bottom pin of the surface — its constant tracks the keyboard overlap
    /// (0 when the keyboard is away), see keyboardFrameWillChange.
    private var terminalBottomConstraint: NSLayoutConstraint?
    /// Main-thread only — fed from the companion byte stream, read on key taps.
    private var altScreenSniffer = AlternateScreenSniffer()
    private var uploadClient: DeviceClient?
    private var uploadQueue: [(name: String, data: Data)] = []
    private var uploadInFlight = false
    private var uploadTotal = 0
    private var uploadDone = 0
    private var restylePump: Timer?
    private lazy var controller = TerminalController(
        theme: Self.terminalTheme(),
        terminalConfiguration: Self.appearanceConfiguration()
    )

    // Drawer
    private lazy var inspector: InspectorViewController = {
        let inspector = InspectorViewController(
            session: session,
            endpoint: {
                if case .device(let endpoint) = backend { endpoint } else { nil }
            }()
        )
        inspector.onSendToAgent = { [weak self] text in
            self?.sendSnippetToPrompt(text)
        }
        return inspector
    }()
    private lazy var inspectorNav = UINavigationController(rootViewController: inspector)
    private let dimView = UIControl()
    private var drawerOpen = false
    /// Direction the surface pan locked at its start: rightward = back to
    /// the list, leftward = drag the drawer.
    private var openPanGoesBack = false
    private var drawerWidth: CGFloat { min(view.bounds.width * 0.85, 420) }

    init(session: MockSession) {
        self.session = session
        backend = .demoShell
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    /// A live terminal on a paired machine: bridges a real session's PTY when
    /// `session` carries a roster id, else streams whatever the peer serves
    /// (the companion proof of concept).
    init(endpoint: DeviceEndpoint, session: MockSession? = nil) {
        self.session = session ?? MockSession(
            title: endpoint.url.host ?? "companion",
            project: "companion", agent: RosterAgent.terminal, status: .idle,
            subtitle: "", time: ""
        )
        backend = .device(endpoint)
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    deinit {
        companion?.stop()
        uploadClient?.stop()
        restylePump?.invalidate()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The page trait comes from the window's app-wide Appearance override
        // (set in AppDelegate), and the backdrop is the active theme's
        // background: the surface renders with zero background opacity, so
        // this view is its canvas.
        view.backgroundColor = Self.backdropColor()
        configureHeader()
        configureTerminal()
        configureDrawer()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: MobileSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearanceSettings() }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Swipe-from-left-edge pop stays available with the bar hidden.
        navigationController?.interactivePopGestureRecognizer?.delegate = nil
        // The surface is configured only now, with the view guaranteed to be
        // in a window: its font metrics bake in the display scale at creation,
        // and off-window the scale resolution falls back and sometimes loses —
        // the intermittent third-size rendering. On-window it's always right.
        if !surfaceConfigured {
            surfaceConfigured = true
            terminalView.configuration = TerminalSurfaceOptions(
                backend: .inMemory(makeTerminalSession())
            )
            terminalView.fitToSize()
            lastFittedSize = terminalView.bounds.size
        }
        if !drawerOpen { focusInput() }
        // Once per lifetime: a parked terminal re-entering the screen (the
        // container's keep-alive cache) must not open a second connection —
        // its backend has been streaming the whole time.
        if !backendStarted {
            backendStarted = true
            switch backend {
            case .demoShell:
                shellSession.start()
            case .device:
                // nil only when there was no session to attach to, which
                // `makeTerminalSession` already fell back to the sandbox shell
                // for; starting nothing would leave that shell dead on screen.
                if let companion { companion.start() } else { shellSession.start() }
            }
        } else if case .device = backend {
            // Re-entering a parked session re-sends this phone's viewport: the
            // device stopped counting it when the screen went away, and this
            // view's size didn't change, so no layout pass would re-send it.
            companion?.reassertGrid()
        }
        // Back on screen, so back in the running for the session's size.
        if case .device = backend { companion?.setRendering(true) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Leaving the terminal (popping back to the session list) must take the
        // keyboard with it — otherwise the surface stays first responder and
        // the keyboard + key bar linger over the list.
        terminalView.resignFirstResponder()
        // The container parks this screen rather than tearing it down, so the
        // attachment survives. It stops counting toward the session's size the
        // moment nobody is looking at it, or a session opened once on the phone
        // would hold a Mac pane at phone width for as long as it stayed open.
        if case .device = backend { companion?.setRendering(false) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutDrawer()
        layoutTerminalSurface()
        // Refit only when the surface's size actually changed, and coalesce
        // the per-frame passes of keyboard animations into one call
        // after the size settles. Every `setSize` can deadlock against the
        // byte stream inside libghostty-spm 1.2.8 (`receive` holds the
        // session lock across a blocking write while the io thread's resize
        // ack wants the same lock — the app-freeze bug), so send as few
        // resizes as possible until that's fixed upstream.
        let size = terminalView.bounds.size
        guard size != lastFittedSize else { return }
        fitDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            lastFittedSize = terminalView.bounds.size
            terminalView.fitToSize()
        }
        fitDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Frames the surface inside `terminalHost`: it fills it.
    ///
    /// It used to letterbox — lay the surface out at the shared grid and scale
    /// the whole thing down to fit — because while another device held the write
    /// token the PTY was that device's size, and it could be *smaller* than this
    /// phone's. The device now sizes a session to the smallest viewport
    /// rendering it, so a phone showing one is never wider than the PTY except
    /// against a Mac pane narrower than a phone; there is nothing left to scale
    /// down, and blank space is the honest picture for what remains (§4 of
    /// `docs/design/20260901-pty-size-is-not-the-write-token.md`).
    private func layoutTerminalSurface() {
        let host = terminalHost.bounds
        guard host.width > 0, host.height > 0 else { return }
        terminalView.transform = .identity
        terminalView.frame = host
    }

    // MARK: - Header

    /// A compact stand-in for the navigation bar: back · [context/title] ·
    /// drawer, hugging the status bar so no vertical space is spent on the
    /// floating system bar. Line 1: where you are (project · branch). Line 2:
    /// what the session is doing (live from the agent's OSC titles). While
    /// the link is in doubt the status line stands in for the context line.
    private func configureHeader() {
        contextLabel.font = .preferredFont(forTextStyle: .caption2)
        contextLabel.textColor = .secondaryLabel
        contextLabel.text = [session.project, session.branch]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.text = session.title
        statusLabel.font = .preferredFont(forTextStyle: .caption2)
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = switch backend {
        case .demoShell: "\(session.agent.name) · \(session.time)"
        case .device: localized("Connecting…")
        }
        contextLabel.isHidden = contextLabel.text?.isEmpty ?? true
        switch backend {
        case .device: contextLabel.isHidden = true // until connected
        case .demoShell: break
        }

        // Each line spans the whole width between the two buttons and centers its
        // text inside it. Sizing the labels to their text instead makes every
        // title change a layout pass that re-centers the stack, so a title the
        // agent rewrites as it works visibly jitters left and right.
        let titles = UIStackView(arrangedSubviews: [contextLabel, titleLabel, statusLabel])
        titles.axis = .vertical
        titles.alignment = .fill
        titles.spacing = 0
        for label in [contextLabel, titleLabel, statusLabel] {
            label.textAlignment = .center
        }

        headerBar.axis = .horizontal
        headerBar.alignment = .center
        headerBar.spacing = 4
        // The Messages-conversation header: back chevron to the inbox, the
        // title stack centered (balanced by an equal-width spacer). On
        // iOS 26 the chevron rides a circular Liquid Glass button, matching
        // the system back button over content; earlier it stays flat.
        let back = UIButton(type: .system)
        // Telegram-scale: an 18pt semibold chevron on a 44pt target, not the
        // 15pt default that reads like a caption glyph.
        back.applyGlassSymbol("chevron.left", pointSize: 18)
        back.accessibilityIdentifier = "terminal.back"
        back.addAction(UIAction { [weak self] _ in
            self?.goBack()
        }, for: .touchUpInside)
        // The right slot balances the back chevron (keeping the title centered)
        // and holds an overflow menu of per-session actions — Copy Path for a
        // companion session. With nothing to offer (the demo shell has no Mac
        // project path) it stays an invisible spacer.
        let overflow = UIButton(type: .system)
        overflow.applyGlassSymbol("ellipsis", pointSize: 16)
        overflow.accessibilityIdentifier = "terminal.overflow"
        overflow.tintColor = ThemeChrome.secondaryInk
        overflow.showsMenuAsPrimaryAction = true
        let menu = makeOverflowMenu()
        overflow.menu = menu
        if menu.children.isEmpty {
            overflow.alpha = 0
            overflow.isUserInteractionEnabled = false
        }
        headerBar.addArrangedSubview(back)
        headerBar.addArrangedSubview(titles)
        headerBar.addArrangedSubview(overflow)
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)
        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            back.widthAnchor.constraint(equalToConstant: 44),
            back.heightAnchor.constraint(equalToConstant: 44),
            overflow.widthAnchor.constraint(equalToConstant: 44),
            overflow.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    /// The header overflow menu. Copy Path appears only for a companion session,
    /// where there is a Mac project path to reach; the demo shell has none, so the
    /// menu comes back empty and the button hides itself.
    private func makeOverflowMenu() -> UIMenu {
        var items: [UIMenuElement] = []
        if let path = session.projectPath, !path.isEmpty {
            items.append(UIAction(
                title: localized("Copy Path"), image: UIImage(systemName: "doc.on.doc")
            ) { _ in UIPasteboard.general.string = path })
        }
        return UIMenu(children: items)
    }

    /// Called by RootContainerViewController when this parked screen slides
    /// back into view. The view was only hidden (never removed from the
    /// window), so `viewDidAppear` does not fire — re-run the parts that must
    /// happen on every return.
    func prepareForReappearance() {
        if !drawerOpen { focusInput() }
        // Re-entering a parked session re-sends this phone's grid (applied only
        // while it holds the write token); the view's size didn't change while
        // parked, so no layout pass would.
        if case .device = backend { companion?.reassertGrid() }
    }

    /// Back to the inbox: the screen parks in the container's keep-alive
    /// cache — the session stays live, unlike `close()`.
    private func goBack() {
        // The container PARKS this screen (the view slides away, no pop), so
        // viewWillDisappear never fires — drop the keyboard here or it and
        // the key bar linger over the session list.
        terminalView.resignFirstResponder()
        if let onRequestBack {
            onRequestBack()
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    /// The session is over (child exited, connection lost): tell the
    /// container so the parked screen is dropped, or pop if unowned.
    private func close() {
        if let onClose { onClose() } else { navigationController?.popViewController(animated: true) }
    }

    /// The drawer steals keyboard focus while open and hands it back when
    /// it slides away.
    private func setTerminalFocused(_ focused: Bool) {
        if focused {
            focusInput()
        } else {
            terminalView.resignFirstResponder()
        }
    }

    /// The terminal is the app's single input — first responder brings the
    /// system keyboard (typing straight into the PTY) with the key bar docked
    /// above it.
    private func focusInput() {
        terminalView.becomeFirstResponder()
    }

    // MARK: - Terminal

    private func configureTerminal() {
        terminalView.delegate = self
        // Long-press → floating Paste menu (see wirePasteMenu).
        wirePasteMenu()
        // Scrolling the terminal is reading; give the rows back to content.
        // Dropping first responder only hides the keyboard — tapping the
        // surface refocuses (the wrapper's touch path takes it back).
        terminalView.onScrollGesture = { [weak self] in
            self?.terminalView.resignFirstResponder()
        }
        // configuration (and thus the surface) is deliberately deferred to
        // viewDidAppear — see the display-scale note there.
        terminalView.controller = controller
        terminalView.backgroundColor = .clear
        terminalView.isOpaque = false
        view.addSubview(terminalHost)
        terminalHost.addSubview(terminalView)

        // Sits directly above the surface (below the drawer added later),
        // so unhiding it masks libghostty's panel during a rebuild.
        rendererCoverView.backgroundColor = Self.backdropColor()
        view.addSubview(rendererCoverView)
        NSLayoutConstraint.activate([
            rendererCoverView.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            rendererCoverView.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            rendererCoverView.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            rendererCoverView.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
        ])

        // The key bar lives on the terminal (its inputAccessoryView); the
        // controller only wires its callbacks. Sticky ctrl/alt toggle the
        // view's state machine, which reports every transition back so the
        // keycaps repaint (armed = tinted, locked = filled).
        let keyBar = terminalView.keyBar
        keyBar.onKey = { [weak self] payload in self?.terminalView.send(payload) }
        keyBar.onSticky = { [weak self] key in
            self?.terminalView.toggleStickyModifier(key == .ctrl ? .ctrl : .alt)
        }
        keyBar.onScrollEdge = { [weak self] edge in
            guard let self else { return }
            // Full-screen TUIs (Claude Code holds the alternate screen) have
            // no scrollback for the viewport to jump through — libghostty's
            // scroll actions are primary-screen no-ops there. Fall back to
            // page keys, which those apps parse for their own history.
            if altScreenSniffer.isAlternate {
                terminalView.send(Data((edge == .top ? "\u{1B}[5~" : "\u{1B}[6~").utf8))
            } else {
                switch edge {
                case .top: terminalView.scrollToTop()
                case .bottom: terminalView.scrollToBottom()
                }
            }
        }
        keyBar.onAttach = { [weak self] source in
            switch source {
            case .camera: self?.presentCamera()
            case .photos: self?.presentPhotoPicker()
            case .files: self?.presentDocumentPicker()
            }
        }
        // The transcript types straight into the prompt — no newline, so a
        // dictation never sends a half-formed prompt on its own.
        keyBar.onVoiceTranscript = { [weak self] text in
            self?.terminalView.send(Data(text.utf8))
        }
        terminalView.setStickyModifierChangeHandler { [weak self] in
            guard let self else { return }
            keyBar.setStickyVisual(.ctrl, Self.stickyVisual(terminalView.stickyActivation(for: .ctrl)))
            keyBar.setStickyVisual(.alt, Self.stickyVisual(terminalView.stickyActivation(for: .alt)))
        }
        if case .device = backend, session.projectRosterID != nil {
            keyBar.setAttachAvailable(true)
        }

        activateTerminalConstraints()
    }

    private static func stickyVisual(
        _ activation: TerminalPublicStickyActivation
    ) -> TerminalStickyVisual {
        switch activation {
        case .inactive: .off
        case .armed: .armed
        case .locked: .locked
        }
    }

    /// Pins the surface between the header and the top of the keyboard — the
    /// very bottom of the screen while the keyboard is away.
    ///
    /// Driven by keyboardWillChangeFrame, not `keyboardLayoutGuide`: on
    /// device the guide kept a keyboard-shaped band reserved after the
    /// keyboard dismissed (even with `usesBottomSafeArea = false`), leaving
    /// ~5 rows of dead space under bottom-anchored TUIs. The notification's
    /// end frame is unambiguous — overlap is what it says, zero when hidden.
    private func activateTerminalConstraints() {
        let bottom = terminalHost.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        terminalBottomConstraint = bottom
        NSLayoutConstraint.activate([
            terminalHost.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            terminalHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom,
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
    }

    @objc private func keyboardFrameWillChange(_ note: Notification) {
        // Parked terminals (the container's keep-alive cache) have no window;
        // converting the frame there is meaningless, and the constraint gets
        // refreshed by the next real keyboard event once re-presented.
        guard view.window != nil,
              let endValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else { return }
        let endFrame = view.convert(endValue.cgRectValue, from: nil)
        let overlap = max(0, view.bounds.maxY - endFrame.minY)
        guard let constraint = terminalBottomConstraint, constraint.constant != -overlap else { return }
        constraint.constant = -overlap
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 7
        UIView.animate(
            withDuration: duration, delay: 0,
            options: UIView.AnimationOptions(rawValue: UInt(curve) << 16)
        ) {
            self.view.layoutIfNeeded()
        }
    }

    /// Called by the container right after it removes this screen from the view
    /// hierarchy (which frees the surface via `didMoveToWindow(nil)`), so
    /// libghostty's orphaned Metal layer is dropped before the next
    /// CoreAnimation commit can fault on its dangling delegate.
    func releaseOrphanedSurfaceLayers() {
        detachOrphanedSurfaceLayers()
    }

    /// Neutralize libghostty's orphaned Metal layers after a surface free.
    ///
    /// `ghostty_surface_free` frees the Zig surface object but leaves the
    /// CAMetalLayer it added as a sublayer in the view's layer tree — and that
    /// layer's delegate still points at the now-freed surface. The wrapper never
    /// detaches it, so the next CoreAnimation commit dereferences freed memory:
    /// the `renderer.Metal` / `apprt.surface.Mailbox.push` EXC_BAD_ACCESS inside
    /// `CA::Context::commit_transaction` seen in the device crash logs. Nil the
    /// delegate (a plain unsafe_unretained assignment — never messages the freed
    /// object) and remove the layer, so no commit can call back into it. Only
    /// ever runs while the surface is torn down, never during healthy rendering.
    private func detachOrphanedSurfaceLayers() {
        terminalView.layer.sublayers?.forEach { layer in
            layer.delegate = nil
            layer.removeFromSuperlayer()
        }
    }

    // MARK: - Attachments

    private static let uploadByteCap = 8 << 20

    private func presentPhotoPicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        // Telegram's default batch limit; .ordered gives numbered selection
        // circles from the system picker.
        config.selectionLimit = 10
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        // asCopy avoids the whole security-scope/bookmark dance — the bytes
        // get copied to the Mac anyway.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    /// Pushes picked bytes to the paired machine one file at a time; each reply’s
    /// absolute path is typed into the TUI's own input line — the desktop
    /// drag-a-file-into-terminal semantic, over the app's own link instead of
    /// SCP. Uploads run sequentially because neither backend's reply carries a
    /// correlation id.
    private func enqueueUploads(_ items: [(name: String, data: Data)]) {
        guard case .device = backend, session.projectRosterID != nil else { return }
        let oversized = items.filter { $0.data.count > Self.uploadByteCap }
        reportSkipped(oversized: oversized.map(\.name))
        let accepted = items.filter { $0.data.count <= Self.uploadByteCap }
        guard !accepted.isEmpty else { return }
        uploadQueue.append(contentsOf: accepted)
        uploadTotal += accepted.count
        sendNextUpload()
    }

    private func sendNextUpload() {
        guard !uploadInFlight else { return }
        guard let item = uploadQueue.first else {
            uploadTotal = 0
            uploadDone = 0
            terminalView.keyBar.setAttachBusy(false)
            return
        }
        guard case .device(let endpoint) = backend,
              let projectID = session.projectRosterID else { return }
        uploadQueue.removeFirst()
        uploadInFlight = true
        terminalView.keyBar.setAttachBusy(true, progress: (done: uploadDone, total: uploadTotal))
        if uploadClient == nil {
            // Scoped to this session: a device files a transfer in the session's
            // own scratch directory and reaps it when the session dies, so a
            // pasted screenshot never outlives the conversation it belonged to.
            let client = DeviceBackends.client(for: endpoint, sessionID: session.rosterID)
            client.onUploaded = { [weak self] path in
                guard let self else { return }
                self.typeUploadedPath(path)
                self.uploadDone += 1
                self.uploadInFlight = false
                self.sendNextUpload()
            }
            client.onError = { [weak self] message in
                guard let self else { return }
                self.uploadQueue.removeAll()
                self.uploadInFlight = false
                self.uploadTotal = 0
                self.uploadDone = 0
                self.terminalView.keyBar.setAttachBusy(false)
                self.presentAlert(localized("Upload failed"), message)
            }
            client.start()
            uploadClient = client
        }
        uploadClient?.upload(projectID: projectID, name: item.name, data: item.data)
    }

    /// Pastes a diff selection into the TUI's input line — the drawer's "Send to Agent",
    /// and the phone twin of the desktop's "Add to Chat". Bracketed paste keeps the
    /// whole block one literal insert instead of a line-by-line submit, and the drawer
    /// steps aside so the prompt it landed in is visible.
    private func sendSnippetToPrompt(_ text: String) {
        pasteIntoPrompt(text)
        setDrawer(open: false, animated: true)
    }

    /// Bracketed paste: the whole block lands as one literal insert instead of a
    /// line-by-line submit, and the TUI's own Return still sends it.
    private func pasteIntoPrompt(_ text: String) {
        terminalView.send(Data(("\u{1B}[200~" + text + "\u{1B}[201~").utf8))
    }

    /// Types the uploaded file's Mac path into the TUI's input line, where it
    /// stays editable. The trailing space separates it from whatever gets typed next.
    private func typeUploadedPath(_ path: String) {
        pasteIntoPrompt(path + " ")
    }

    private func reportSkipped(oversized: [String], unreadable: [String] = []) {
        var lines: [String] = []
        if !oversized.isEmpty {
            lines.append(localized("Over the 8 MB cap: \(oversized.joined(separator: ", "))"))
        }
        if !unreadable.isEmpty {
            lines.append(localized("Couldn't read: \(unreadable.joined(separator: ", "))"))
        }
        guard !lines.isEmpty else { return }
        presentAlert(localized("Some files were skipped"), lines.joined(separator: "\n"))
    }

    private func presentAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: localized("OK"), style: .default))
        present(alert, animated: true)
    }

    /// Demo sessions use ShellCraftKit's sandbox shell; a live session bridges
    /// the surface to a PTY on the paired machine — keystrokes out, remote bytes
    /// in, grid resize → window-change.
    private func makeTerminalSession() -> InMemoryTerminalSession {
        switch backend {
        case .demoShell:
            return shellSession.terminalSession
        case .device(let endpoint):
            guard let transport = DeviceBackends.session(
                for: endpoint, sessionID: session.rosterID
            ) else {
                // A device attaches to a session by name and this screen has
                // none, so there is nothing to show. The sandbox shell is the
                // honest fallback: it says what it is rather than sitting on a
                // socket that will never carry anything.
                Log.device.error("no session id to attach to; falling back to the sandbox shell")
                return shellSession.terminalSession
            }
            // The surface answers the host's terminal queries (XTVERSION, DA,
            // DSR) on its own, through this same closure. Those are not the
            // person: they must not claim the write token, and only the
            // writer's surface may answer at all — an observer's reply lands
            // late in the agent's input line as literal text, a stray
            // ">|ghostty 1.3.2…" (`TerminalDeviceReport`).
            let terminalSession = InMemoryTerminalSession(
                write: { [weak transport] data in
                    if TerminalDeviceReport.isReport(data) {
                        transport?.sendDeviceReport(data)
                    } else {
                        transport?.send(data)
                    }
                },
                resize: { [weak transport] viewport in
                    // The surface fills the host, so what it reports *is* this
                    // screen's viewport — how much of a session it could show.
                    transport?.setViewport(
                        columns: Int(viewport.columns), rows: Int(viewport.rows))
                }
            )
            transport.onOutput = { [weak terminalSession, weak self] data in
                terminalSession?.receive(data)
                // The sniffer only decides what the key bar's scroll-edge keys
                // send; a TUI switching screens changes nothing about the grid,
                // which is the writer's and already what the PTY is.
                DispatchQueue.main.async { self?.altScreenSniffer.consume(data) }
            }
            transport.onState = { [weak self] state in
                self?.companionStateChanged(state)
            }
            companion = transport
            companionSession = terminalSession
            return terminalSession
        }
    }

    private func companionStateChanged(_ state: DeviceSessionState) {
        // The status line earns its place only while the link is in doubt;
        // once connected it yields to the project · branch context line.
        statusLabel.isHidden = false
        contextLabel.isHidden = true
        switch state {
        case .connecting:
            statusLabel.text = localized("Connecting…")
        case .reconnecting:
            statusLabel.text = localized("Reconnecting…")
        case .connected:
            statusLabel.isHidden = true
            contextLabel.isHidden = contextLabel.text?.isEmpty ?? true
            // The attach snapshot paints the screen. The grid goes out once
            // more in case this phone is the writer and the PTY moved while the
            // link was down; an observer's re-send is a no-op by design.
            companion?.reassertGrid()
        case .failed(let reason):
            statusLabel.text = localized("Connection failed")
            let alert = UIAlertController(title: localized("Companion connection failed"), message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: localized("OK"), style: .default) { [weak self] _ in
                self?.close()
            })
            present(alert, animated: true)
        case .closed:
            statusLabel.text = localized("Disconnected")
            companionSession?.finish(exitCode: 0, runtimeMilliseconds: 0)
        }
    }

    /// The light/dark pair from settings; libghostty switches slots as the
    /// page's effective appearance changes (system mode tracks the device).
    private static func terminalTheme() -> TerminalTheme {
        let settings = MobileSettings.shared
        let light = GhosttyThemeCatalog.theme(named: settings.lightThemeName)?
            .toTerminalConfiguration() ?? .alabaster
        let dark = GhosttyThemeCatalog.theme(named: settings.darkThemeName)?
            .toTerminalConfiguration() ?? .afterglow
        return TerminalTheme(light: light, dark: dark)
    }

    /// The canvas behind the transparent surface — the theme background, shared
    /// with the app chrome so the terminal and its surrounding pages read as one
    /// continuous color (covers the unpainted band under the keyboard guide and
    /// the safe areas too). See `ThemeChrome`.
    private static func backdropColor() -> UIColor { ThemeChrome.background }

    /// The settings-driven half of the surface config — the single place the
    /// appearance keys are named, so creation and the live re-style path
    /// can't drift apart (same rule as the Mac app's applyAppearance).
    /// The surface's margins in points. Named because `layoutTerminalSurface`
    /// needs the same numbers to size a surface to an exact grid; Y is
    /// libghostty's default, which the configuration below leaves alone.
    private static let terminalPaddingX: CGFloat = 8
    private static let terminalPaddingY: CGFloat = 2

    private static func appearanceConfiguration() -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withBackgroundOpacity(0)
            builder.withFontSize(Float(MobileSettings.shared.fontSize))
            builder.withWindowPaddingX(Int(Self.terminalPaddingX))
            // Without a font-family the phone rendered CJK unlike the Mac —
            // libghostty dropped in proportional PingFang whose metrics fight the
            // Latin face. Set the chain to match the desktop (see `terminalFontChain`).
            for family in terminalFontChain() {
                builder.withFontFamily(family)
            }
            // Ghostty blends in `native` (Display P3) on macOS but `linear-corrected`
            // on every other OS, iOS included. Linear blending thins dark-on-light
            // glyph edges, so the same theme read softer here than on the Mac.
            builder.withCustom("alpha-blending", "native")
            // The phone is a viewer, not the scrollback of record — the Mac keeps
            // the full history. libghostty's renderer paints its "non-functional"
            // panel when it exhausts a GPU/allocator resource reflowing scrollback
            // at this narrow grid during a drag-scroll — a purely internal Zig
            // failure it never reports to us (verified via device logs: it emits
            // no RENDERER_HEALTH action and exposes no health getter). We can't
            // catch it, only reduce what it must build: cap scrollback hard so a
            // drag can't reflow enough rows to tip the renderer over. 256 KB is
            // still ~thousands of lines — plenty for a phone viewer.
            builder.withCustom("scrollback-limit", "256000")
        }
    }

    /// Ghostty reads repeated `font-family` as a fallback chain — first loadable
    /// face is the primary and sets cell metrics; later faces only cover glyphs
    /// it lacks, and unresolvable names are skipped. `SF Mono` matches the Mac's
    /// default (`Menlo` behind it as the always-present floor); the CJK candidates
    /// mirror the Mac's, ending on `PingFang SC` so hanzi never fall to an
    /// arbitrary system face.
    private static func terminalFontChain() -> [String] {
        var chain = ["SF Mono", "Menlo"]
        let cjkCandidates = [
            "Sarasa Term SC", "Sarasa Mono SC", "Sarasa Fixed SC",
            "Maple Mono NF CN", "Maple Mono CN",
            "LXGW WenKai Mono",
            "Noto Sans Mono CJK SC",
        ]
        if let installed = cjkCandidates.first(where: { UIFont(name: $0, size: 12) != nil }) {
            chain.append(installed)
        }
        if UIFont(name: "PingFang SC", size: 12) != nil {
            chain.append("PingFang SC")
        }
        return chain
    }

    /// Restyles the live surface in place after a settings change, then
    /// drives the renderer for a short window: without PTY output nothing
    /// else wakes the surface, and the new look would wait for the next
    /// byte to arrive.
    private func applyAppearanceSettings() {
        // Re-assigned (not just relied on as dynamic) so a theme-name change
        // busts UIKit's resolved-color cache without a trait flip.
        view.backgroundColor = Self.backdropColor()
        guard surfaceConfigured else { return }
        controller.setTheme(Self.terminalTheme())
        controller.setTerminalConfiguration(Self.appearanceConfiguration())
        terminalView.fitToSize()
        restylePump?.invalidate()
        let started = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.controller.tick()
                if Date().timeIntervalSince(started) > 0.5 { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        restylePump = timer
    }

    // MARK: - Drawer

    private func configureDrawer() {
        dimView.backgroundColor = .black
        dimView.alpha = 0
        dimView.isUserInteractionEnabled = false
        dimView.addAction(UIAction { [weak self] _ in
            self?.setDrawer(open: false, animated: true)
        }, for: .touchUpInside)
        view.addSubview(dimView)

        addChild(inspectorNav)
        view.addSubview(inspectorNav.view)
        inspectorNav.didMove(toParent: self)
        inspectorNav.view.layer.shadowColor = UIColor.black.cgColor
        inspectorNav.view.layer.shadowOpacity = 0.3
        inspectorNav.view.layer.shadowRadius = 12
        inspectorNav.view.layer.shadowOffset = CGSize(width: -4, height: 0)

        // A leftward drag anywhere on the surface pulls the drawer out
        // (ChatGPT's sidebar gesture, mirrored). The delegate keeps drags
        // that belong to controls and scrollers out of it,
        // and the direction check leaves vertical scrollback alone.
        let openPan = UIPanGestureRecognizer(target: self, action: #selector(handleOpenPan(_:)))
        openPan.delegate = self
        openPan.maximumNumberOfTouches = 1 // two fingers stay pinch-zoom
        view.addGestureRecognizer(openPan)

        // Swiping the open drawer rightwards closes it.
        let closePan = UIPanGestureRecognizer(target: self, action: #selector(handleClosePan(_:)))
        inspectorNav.view.addGestureRecognizer(closePan)
    }

    private func layoutDrawer(progress: CGFloat? = nil) {
        let openness = progress ?? (drawerOpen ? 1 : 0)
        let x = view.bounds.width - drawerWidth * openness
        inspectorNav.view.frame = CGRect(x: x, y: 0, width: drawerWidth, height: view.bounds.height)
        dimView.frame = view.bounds
        dimView.alpha = 0.15 * openness
    }

    func setDrawer(open: Bool, animated: Bool, initialVelocity: CGFloat = 0) {
        drawerOpen = open
        dimView.isUserInteractionEnabled = open
        if open { setTerminalFocused(false) }
        let animations = { self.layoutDrawer() }
        if animated {
            UIView.animate(withDuration: 0.35, delay: 0,
                           usingSpringWithDamping: 0.9, initialSpringVelocity: initialVelocity,
                           animations: animations)
        } else {
            animations()
        }
        if !open { focusInput() }
    }

    /// One pan, two meanings, split by the direction it starts in (the
    /// delegate only lets clearly horizontal drags through): leftward drags
    /// the drawer out, rightward goes back to the session list — the same
    /// swipe Messages answers with a pop to the inbox.
    @objc private func handleOpenPan(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began {
            openPanGoesBack = pan.velocity(in: view).x > 0
        }
        if openPanGoesBack {
            // Measure in the window, not `view`: the container drags `view`
            // itself during the interactive back, so reading translation in a
            // moving space would feed back on itself.
            guard let ref = view.window, onBackChanged != nil else {
                // No interactive host (e.g. a plain nav stack) — discrete pop.
                if pan.state == .ended {
                    let fling = pan.velocity(in: view).x > 300
                    if fling || pan.translation(in: view).x > view.bounds.width * 0.3 {
                        goBack()
                    }
                }
                return
            }
            let tx = pan.translation(in: ref).x
            switch pan.state {
            case .began:
                // Drop the keyboard as the drag starts, matching goBack() — but remember to hand
                // it back if the swipe is cancelled.
                terminalWasFirstResponderAtBackBegin = terminalView.isFirstResponder
                terminalView.resignFirstResponder()
                onBackBegan?()
            case .changed:
                onBackChanged?(max(0, tx))
            case .ended, .cancelled:
                let vx = pan.velocity(in: ref).x
                // A decisive flick wins over position, in *either* direction: a hard left flick
                // cancels even past the distance threshold. Position only decides a gentle release.
                let commit: Bool
                if pan.state == .ended {
                    commit = abs(vx) > 300 ? vx > 0 : tx > view.bounds.width * 0.3
                } else {
                    commit = false
                }
                // A non-committed swipe returns to the terminal; restore the keyboard it had.
                if !commit, terminalWasFirstResponderAtBackBegin {
                    terminalView.becomeFirstResponder()
                }
                onBackEnded?(vx, commit)
            default:
                break
            }
            return
        }
        let translation = -pan.translation(in: view).x
        let progress = max(0, min(1, translation / drawerWidth))
        switch pan.state {
        case .changed:
            layoutDrawer(progress: progress)
            dimView.isUserInteractionEnabled = true
        case .ended, .cancelled:
            let vOpen = -pan.velocity(in: view).x   // + = toward open
            // A decisive flick wins over position in either direction; position only decides a
            // gentle release. Otherwise a hard flick back the other way still committed the old way.
            let willOpen = abs(vOpen) > 300 ? vOpen > 0 : progress > 0.4
            // Normalize the release speed to fractions of the remaining travel per second, toward
            // the committed target, so a flick that direction carries through and a reversal /
            // gentle release settles from rest.
            let remaining = drawerWidth * (willOpen ? (1 - progress) : progress)
            let towardTarget = willOpen ? vOpen : -vOpen
            let v = remaining > 1 ? min(max(towardTarget / remaining, 0), 30) : 0
            setDrawer(open: willOpen, animated: true, initialVelocity: v)
        default:
            break
        }
    }

    @objc private func handleClosePan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view).x
        let progress = max(0, min(1, 1 - translation / drawerWidth))
        switch pan.state {
        case .changed:
            layoutDrawer(progress: progress)
        case .ended, .cancelled:
            let vClose = pan.velocity(in: view).x   // + = toward close
            let willClose = abs(vClose) > 300 ? vClose > 0 : progress < 0.6
            let open = !willClose
            let remaining = drawerWidth * (open ? (1 - progress) : progress)
            let towardTarget = willClose ? vClose : -vClose
            let v = remaining > 1 ? min(max(towardTarget / remaining, 0), 30) : 0
            setDrawer(open: open, animated: true, initialVelocity: v)
        default:
            break
        }
    }
}

// MARK: - Drawer pan gating

extension TerminalViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, pan.view === view else { return true }
        guard !drawerOpen else { return false }
        let velocity = pan.velocity(in: view)
        // Clearly horizontal either way — vertical drags are the terminal's
        // scrollback. Leftward opens the drawer; rightward pops to the list,
        // so it only engages when there is a stack to pop.
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        // Leftward opens the drawer; rightward goes back to the list, which the
        // container (or a hosting nav stack) must be able to honor.
        let canGoBack = onRequestBack != nil
            || (navigationController?.viewControllers.count ?? 0) > 1
        return velocity.x < 0 || canGoBack
    }

    func gestureRecognizer(
        _ gesture: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        guard gesture.view === view else { return true }
        // Horizontal drags inside controls, scrollers, or the drawer itself
        // mean something else.
        var candidate = touch.view
        while let current = candidate, current !== view {
            if current is UIControl || current is UIScrollView { return false }
            if current === inspectorNav.view { return false }
            candidate = current.superview
        }
        return true
    }

    func gestureRecognizer(
        _ gesture: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        // The surface's own pans (touch scroll, pointer selection) recognize
        // any drag instantly and would win every touch that starts over the
        // terminal — the drawer could then only open from the header. Making
        // them wait for this pan costs vertical scrolling only the ~10pt it
        // takes the direction check to bow out.
        gesture.view === view && other.view is UITerminalView
    }
}

// MARK: - Terminal callbacks

// MARK: - Attachment pickers

extension TerminalViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        // Slots keep the user's selection order while loads land out of order.
        var payloads = [(name: String, data: Data)?](repeating: nil, count: results.count)
        let group = DispatchGroup()
        for (index, result) in results.enumerated() {
            let provider = result.itemProvider
            guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
            group.enter()
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                defer { group.leave() }
                guard let image = object as? UIImage,
                      let data = Self.jpegPayload(from: image) else { return }
                let base = provider.suggestedName.map {
                    ($0 as NSString).deletingPathExtension
                } ?? "photo-\(index + 1)"
                payloads[index] = (base + ".jpg", data)
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.enqueueUploads(payloads.compactMap { $0 })
        }
    }

    /// Downscales to ≤ 2048 px JPEG — plenty for an agent to read, small
    /// enough to ride one WebSocket frame.
    private static func jpegPayload(from image: UIImage) -> Data? {
        let maxSide: CGFloat = 2048
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }
}

extension TerminalViewController: UIDocumentPickerDelegate {
    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        var items: [(name: String, data: Data)] = []
        var oversized: [String] = []
        var unreadable: [String] = []
        for url in urls {
            // Size gate before reading — no point pulling an over-cap file
            // into memory just to reject it.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            guard size <= Self.uploadByteCap else {
                oversized.append(url.lastPathComponent)
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                unreadable.append(url.lastPathComponent)
                continue
            }
            items.append((url.lastPathComponent, data))
        }
        reportSkipped(oversized: oversized, unreadable: unreadable)
        enqueueUploads(items)
    }
}

extension TerminalViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
              let data = Self.jpegPayload(from: image) else { return }
        enqueueUploads([("camera.jpg", data)])
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

extension TerminalViewController: TerminalSurfaceTitleDelegate, TerminalSurfaceCloseDelegate {
    func terminalDidChangeTitle(_ title: String) {
        // The agent's OSC title rides the byte stream (Claude Code updates it
        // as it works), so the bar tracks what the session is doing live —
        // sanitized and deduplicated, the same guards the Mac sidebar applies
        // to this signal.
        let cleaned = LiveTerminalTitle.sanitized(title)
        guard !cleaned.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.titleLabel.text != cleaned else { return }
            self.titleLabel.text = cleaned
        }
    }

    func terminalDidClose(processAlive _: Bool) {
        close()
    }
}

extension TerminalViewController: UIEditMenuInteractionDelegate {
    /// Long-press → the system edit menu with a single Paste (Termius's
    /// hold-to-paste shape). Cross-app paste is the feature; in-terminal
    /// selection/copy was tried and cut as not worth its complexity — the
    /// TUI's own copy affordances cover reading.
    private func presentPasteMenu(at point: CGPoint) {
        let config = UIEditMenuConfiguration(
            identifier: "termio.terminal.paste", sourcePoint: point
        )
        // Deterministically above the finger: at the raw touch point the
        // balloon can flip below it — under the hand — and "when the menu
        // appeared" becomes "when the hand lifted".
        config.preferredArrowDirection = .down
        editMenuInteraction.presentEditMenu(with: config)
    }

    fileprivate func wirePasteMenu() {
        terminalView.addInteraction(editMenuInteraction)
        terminalView.onPasteMenuRequested = { [weak self] point in
            self?.presentPasteMenu(at: point)
        }
    }

    /// An explicit item, NOT the responder-chain suggestions: the system
    /// builds suggested actions from the first responder, and the terminal
    /// deliberately isn't one after a bare long-press (becoming it summons
    /// the keyboard). Relying on suggestions made the menu come up empty in
    /// any session the user hadn't tapped into first.
    func editMenuInteraction(
        _: UIEditMenuInteraction,
        menuFor _: UIEditMenuConfiguration,
        suggestedActions _: [UIMenuElement]
    ) -> UIMenu? {
        guard UIPasteboard.general.hasStrings else { return nil }
        return UIMenu(options: .displayInline, children: [
            UIAction(title: localized("Paste")) { [weak self] _ in
                self?.terminalView.paste(nil)
            },
        ])
    }

    /// Scope the terminal's resign guard to the menu's actual lifetime.
    func editMenuInteraction(
        _: UIEditMenuInteraction,
        willDismissMenuFor _: UIEditMenuConfiguration,
        animator _: any UIEditMenuInteractionAnimating
    ) {
        terminalView.pasteMenuDidDismiss()
    }
}

extension TerminalViewController: TerminalSurfaceRendererHealthDelegate {
    /// libghostty flipped its renderer health. `healthy == false` means it just
    /// tripped the failsafe that paints the "This terminal is non-functional"
    /// panel INTO the surface — the exact bug we're chasing. Our forked wrapper
    /// forwards this (upstream drops it); log it so the moment is visible in the
    /// unified log, then rebuild the surface so the dead panel doesn't linger.
    func terminalDidChangeRendererHealth(_ healthy: Bool) {
        // NOTE: device logs proved libghostty's embedded build never dispatches
        // GHOSTTY_ACTION_RENDERER_HEALTH, so this never fires — kept only so the
        // wiring is ready if a Zig-source build starts emitting it. The real
        // mitigation is prevention (scrollback + parked-surface caps).
        Log.terminal.error("renderer health changed: healthy=\(healthy, privacy: .public)")
        guard !healthy else { return }
        recoverFromRendererDeath()
    }

    /// Rebuild the surface in place, reusing the SAME in-memory session so the
    /// companion byte stream is never dropped — only the dead Metal surface
    /// is replaced. Debounced: if a single scroll re-trips health repeatedly we
    /// must not loop-flicker, so we rebuild at most once every couple seconds.
    private func recoverFromRendererDeath() {
        let now = Date()
        if let last = lastRendererRecovery, now.timeIntervalSince(last) < 2 {
            Log.terminal.error("renderer recovery skipped (debounced)")
            return
        }
        lastRendererRecovery = now

        let existing: InMemoryTerminalSession?
        switch backend {
        case .demoShell: existing = shellSession.terminalSession
        case .device: existing = companionSession
        }
        guard surfaceConfigured, let session = existing else { return }

        Log.terminal.error("rebuilding surface after renderer death")
        // Mask first, synchronously, so the panel libghostty already painted is
        // hidden by the backdrop before the next screen commit shows it.
        rendererCoverView.backgroundColor = Self.backdropColor()
        rendererCoverView.isHidden = false
        // Drop the freed surface's orphaned Metal layer before the rebuild adds
        // a fresh one, else the dead panel's layer stays composited underneath.
        detachOrphanedSurfaceLayers()
        terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminalView.fitToSize()
        lastFittedSize = terminalView.bounds.size
        // A rebuilt surface starts blank; the stream won't repaint until the
        // next byte. Reclaim the grid so the host re-sends current content.
        if case .device = backend { companion?.reassertGrid() }
        // Reveal once the rebuilt surface has had a beat to repaint (companion
        // content arrives over the network) so we don't uncover a blank grid.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.rendererCoverView.isHidden = true
        }
    }
}

// MARK: - Direct-input surface

/// The terminal IS the app's input (the iSH shape): it takes first responder,
/// the system keyboard types straight into the PTY — the agent's TUI already
/// has the composer, slash menu, history, and @-completion, so the phone adds
/// no second input line to learn. The key bar above the keyboard carries what
/// QWERTY lacks (esc, sticky ctrl/alt, arrows, the configured control keys)
/// and the attach (+), whose uploaded Mac paths are typed into the TUI.
private final class DisplayTerminalView: UITerminalView {
    /// termio's own key bar replaces the wrapper's bundled accessory — the
    /// sticky ctrl/alt state machine stays the view's (via the public sticky
    /// API), the bar only reflects it.
    let keyBar = TerminalAccessoryBar()
    override var inputAccessoryView: UIView? { keyBar }

    /// Long-press anywhere → the owner floats a Paste menu at the finger.
    /// App-owned recognizer (the wrapper's own long-press stays disarmed
    /// without its selection delegates): cross-app paste is the one
    /// clipboard feature the phone terminal supports — in-terminal
    /// selection/copy was cut as not worth its complexity.
    var onPasteMenuRequested: ((CGPoint) -> Void)?
    /// The paste menu is on screen (set at gesture `.began`, cleared when
    /// the menu dismisses — with a next-touch reset as belt-and-braces).
    /// While set, the wrapper's tap-dismiss must not collapse the keyboard
    /// under the menu.
    private var touchSequencePresentedPasteMenu = false
    private var pasteLongPressInstalled = false
    private lazy var pasteLongPress: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(
            target: self, action: #selector(pasteLongPressFired(_:))
        )
        // 0.3s matches the system text views' long-press feel.
        gesture.minimumPressDuration = 0.3
        // 20pt, not the 10pt default: a thumb planted for 300ms drifts a few
        // points routinely, and a failed press with zero feedback reads as
        // "the gesture is unreliable". A deliberate scroll blows past 20
        // immediately.
        gesture.allowableMovement = 20
        // Cancel the touch once the menu gesture wins: the wrapper's pan
        // must not scroll the viewport under the open menu, and the release
        // arrives as touchesCancelled so the tap-to-keyboard path never runs.
        gesture.cancelsTouchesInView = true
        return gesture
    }()

    /// Warmed at touch-down, fired at gesture `.began`: an unprepared
    /// generator adds Taptic-Engine spin-up (~50-200ms) to the confirmation
    /// cue, and time-to-first-feedback is what sets perceived gesture speed.
    private let pasteHaptic = UIImpactFeedbackGenerator(style: .light)

    /// Cached gate for the paste long-press. `hasStrings` is a synchronous
    /// XPC round-trip to pasteboardd — too slow for
    /// `gestureRecognizerShouldBegin`, which runs exactly when the
    /// long-press timer fires and the user is waiting for feedback.
    /// Pasteboard changes land while backgrounded, so the foreground
    /// re-check is mandatory; the changeCount compare keeps it to one query.
    private var clipboardHasStrings = UIPasteboard.general.hasStrings
    private var clipboardChangeCount = UIPasteboard.general.changeCount
    private var clipboardObservers: [NSObjectProtocol] = []

    private func refreshClipboardGate() {
        let count = UIPasteboard.general.changeCount
        guard count != clipboardChangeCount else { return }
        clipboardChangeCount = count
        clipboardHasStrings = UIPasteboard.general.hasStrings
    }

    deinit {
        for observer in clipboardObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func installPasteLongPressIfNeeded() {
        guard !pasteLongPressInstalled, window != nil else { return }
        pasteLongPressInstalled = true
        addGestureRecognizer(pasteLongPress)
        clipboardObservers = [
            NotificationCenter.default.addObserver(
                forName: UIPasteboard.changedNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshClipboardGate() } },
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshClipboardGate() } },
        ]
    }

    /// The menu left the screen — the resign guard is scoped to exactly the
    /// menu's lifetime, so controller-driven resigns (pane close, scroll
    /// handoff) work again immediately.
    func pasteMenuDidDismiss() {
        touchSequencePresentedPasteMenu = false
    }

    @objc private func pasteLongPressFired(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        touchSequencePresentedPasteMenu = true
        pasteHaptic.impactOccurred()
        onPasteMenuRequested?(gesture.location(in: self))
    }

    /// The wrapper disarms every long-press unless its selection delegates
    /// are adopted — allow ours through; and only when the clipboard has
    /// text (cached — see clipboardHasStrings), so a menu with nothing to
    /// offer never eats the hold.
    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === pasteLongPress {
            return clipboardHasStrings
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// The wrapper's tap-dismiss resigns on any unscrolled release; when
    /// that release just presented the paste menu, keep the keyboard as it
    /// was — collapsing it would yank the layout under the menu.
    override func resignFirstResponder() -> Bool {
        if touchSequencePresentedPasteMenu { return false }
        return super.resignFirstResponder()
    }

    /// The software keyboard's Return arrives as `insertText("\n")`, and the
    /// wrapper routes it through `sendText` — which rides inside bracketed
    /// paste once the TUI enabled mode 2004, so Claude Code reads a pasted
    /// newline instead of a submit. iSH's rule at the byte level: a bare
    /// Return is a raw CR straight into the PTY. (The same fix sits in the
    /// vendored fork's UITerminalView+UITextInput for upstreaming; the app
    /// resolves the package from the remote, so it must live here too.)
    ///
    /// The same rule extends to every typed character: a single grapheme from
    /// the keyboard is a KEYSTROKE, and paste-wrapping it breaks TUIs that
    /// treat pastes literally — pi's editor deliberately never opens its
    /// slash/@ autocomplete from a paste (pi-tui `handlePaste`), so "/" typed
    /// on the phone never showed the command menu, while the same key on the
    /// Mac (a real key event, no paste markers) worked. Termux/iSH/Blink all
    /// send soft-keyboard keys as raw bytes; matching them fixes pi and
    /// anything else that distinguishes typing from pasting. Multi-character
    /// inserts (real pastes, IME phrase commits, autocorrect replacements)
    /// keep the bracketed-paste path — that wrapping is what stops a pasted
    /// newline from auto-submitting. A char with a sticky ctrl/alt armed also
    /// stays on the wrapper path, which applies the modifier.
    override func insertText(_ text: String) {
        deleteRepeat.reset()
        if text == "\n" {
            send(Data([0x0D]))
            return
        }
        if text.count == 1, !stickyModifierArmed,
           let scalar = text.unicodeScalars.first, scalar.value >= 0x20 {
            send(Data(text.utf8))
            return
        }
        super.insertText(text)
    }

    /// Paste — the long-press menu and hardware Cmd+V both land here. The
    /// clipboard goes through `insertText`, whose multi-character path rides
    /// the wrapper's sendText: bracketed once the TUI enabled mode 2004
    /// (Claude Code's parser only ingests paste in that form), raw before
    /// then — the same delivery a Mac paste gets. `hasStrings` gates the
    /// menu item without tripping the system paste prompt; the `.string`
    /// read waits for the user-initiated action.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.paste(_:)) {
            return UIPasteboard.general.hasStrings
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        insertText(text)
    }

    // MARK: - Software-keyboard delete auto-repeat (phantom document)

    /// Owns the phantom-document state and hold-acceleration policy that make
    /// the on-screen keyboard's delete key auto-repeat over the terminal. The
    /// `UITextInput` overrides below are the thin UIKit glue that feed it; the
    /// reasoning lives in `SoftwareKeyboardDeleteRepeat`.
    private var deleteRepeat = SoftwareKeyboardDeleteRepeat()

    /// True while an IME (e.g. pinyin) is composing. In that state we defer to
    /// the wrapper's real geometry so composition, cursor, and candidate
    /// replacement keep working — the phantom document is only for plain typing.
    private var isComposingIME: Bool { super.markedTextRange != nil }

    override func deleteBackward() {
        // IME composition and armed sticky modifiers own the keystroke — never
        // accelerate those; one delete, real geometry, streak cleared.
        guard !isComposingIME, !stickyModifierArmed else {
            deleteRepeat.reset()
            super.deleteBackward()
            return
        }
        // Re-use the wrapper's own delete encoding (correct per backend,
        // marked-text-safe) rather than hand-rolling the byte.
        let count = deleteRepeat.backspaceCount(now: CACurrentMediaTime())
        for _ in 0..<count { super.deleteBackward() }
    }

    override var beginningOfDocument: UITextPosition {
        isComposingIME ? super.beginningOfDocument : PhantomTextPosition(0)
    }

    override var endOfDocument: UITextPosition {
        isComposingIME
            ? super.endOfDocument
            : PhantomTextPosition(SoftwareKeyboardDeleteRepeat.documentLength)
    }

    override var selectedTextRange: UITextRange? {
        get {
            guard !isComposingIME else { return super.selectedTextRange }
            let caret = PhantomTextPosition(deleteRepeat.caret)
            return PhantomTextRange(start: caret, end: caret)
        }
        set {
            guard !isComposingIME else { super.selectedTextRange = newValue; return }
            if let caret = (newValue?.start as? PhantomTextPosition)?.index {
                deleteRepeat.moveCaret(to: caret)
            }
        }
    }

    override func textRange(
        from fromPosition: UITextPosition, to toPosition: UITextPosition
    ) -> UITextRange? {
        guard !isComposingIME,
              let from = fromPosition as? PhantomTextPosition,
              let to = toPosition as? PhantomTextPosition
        else { return super.textRange(from: fromPosition, to: toPosition) }
        return PhantomTextRange(start: from, end: to)
    }

    override func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard !isComposingIME, let pos = position as? PhantomTextPosition else {
            return super.position(from: position, offset: offset)
        }
        let index = pos.index + offset
        guard index >= 0, index <= SoftwareKeyboardDeleteRepeat.documentLength else { return nil }
        return PhantomTextPosition(index)
    }

    override func position(
        from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int
    ) -> UITextPosition? {
        guard !isComposingIME, position is PhantomTextPosition else {
            return super.position(from: position, in: direction, offset: offset)
        }
        return self.position(from: position, offset: offset)
    }

    override func compare(
        _ position: UITextPosition, to other: UITextPosition
    ) -> ComparisonResult {
        guard !isComposingIME,
              let lhs = position as? PhantomTextPosition,
              let rhs = other as? PhantomTextPosition
        else { return super.compare(position, to: other) }
        if lhs.index < rhs.index { return .orderedAscending }
        if lhs.index > rhs.index { return .orderedDescending }
        return .orderedSame
    }

    override func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard !isComposingIME,
              let f = from as? PhantomTextPosition,
              let t = toPosition as? PhantomTextPosition
        else { return super.offset(from: from, to: toPosition) }
        return t.index - f.index
    }

    override func text(in range: UITextRange) -> String? {
        guard !isComposingIME, let range = range as? PhantomTextRange else {
            return super.text(in: range)
        }
        // Any non-empty string keeps the keyboard convinced there is content
        // to delete; the bytes never leave this class.
        let length = max(0, range.length)
        return String(repeating: " ", count: min(length, 64))
    }

    /// Whether any sticky modifier (key bar's ctrl/alt/cmd chips) is armed or
    /// locked — those keystrokes must go through the wrapper's `insertText`,
    /// whose state machine folds the modifier into the byte (ctrl-c → 0x03).
    private var stickyModifierArmed: Bool {
        [TerminalPublicStickyModifier.ctrl, .alt, .command]
            .contains { stickyActivation(for: $0) != .inactive }
    }

    /// Fired when a finger scroll begins on the surface. The controller uses
    /// it to drop the keyboard — scrolling back through output means
    /// reading, so the screen yields to content; a completed tap (see
    /// `touchesEnded`) brings the keyboard back.
    var onScrollGesture: (() -> Void)?
    private var scrollHookInstalled = false

    /// The wrapper retakes first responder at touch-DOWN whenever the software
    /// keyboard is hidden (`UITerminalView+Interaction.touchesBegan`). After a
    /// scroll has dropped the keyboard, the next finger that lands to keep
    /// scrolling pops the keyboard up, and the pan's scroll-begin immediately
    /// dismisses it again — the keyboard bounces on every swipe. True only for
    /// the synchronous span of `super.touchesBegan`, so the wrapper's retake is
    /// the one `becomeFirstResponder` call that gets refused; presentation
    /// moves to touch-UP, and only for a touch that never scrolled.
    private var suppressTouchDownKeyboardRetake = false
    /// Whether the current direct-touch sequence scrolled — set by the pan
    /// hook's `.began`, or from birth when the finger lands mid-glide (that
    /// touch stops the fling; it is part of the scroll, not a keyboard tap).
    private var touchSequenceScrolled = false
    /// First-responder state at touch-down. A tap while the keyboard is up is
    /// the wrapper's dismiss-toggle — don't re-present over its resign.
    private var wasFirstResponderAtTouchDown = false

    /// The wrapper's `ghostty_surface_t`, resolved once per scroll interaction
    /// so the per-frame draw path never re-walks its private mirror at touch-
    /// sample rate (up to 120 Hz on ProMotion).
    private var scrollSurfaceHandle: UnsafeMutableRawPointer?

    /// Vsync-aligned draw pump that owns the whole scroll interaction — the
    /// active finger drag AND the momentum glide after it lifts. The wrapper
    /// paints through `DispatchQueue.main.async` (its `startDisplayLink` is a
    /// stub), off the vsync boundary, so we drive the draws ourselves.
    ///
    /// Crucially the pump draws *at most once per vsync*. The active drag used
    /// to draw synchronously on every pan `.changed`, which fires several times
    /// per frame — each `ghostty_surface_draw` grabs a `CAMetalDrawable`, and
    /// the layer's pool is only ~3 deep. Faster-than-vsync draws starve it, the
    /// next drawable comes back nil, libghostty logs a Metal error, and after a
    /// few it trips its renderer-health failsafe — the "This terminal is
    /// non-functional" panel painted straight into the surface. Coalescing the
    /// drag onto this link caps us at one drawable per frame, so the pool never
    /// empties. See docs/design/20260706-ios-scroll-renderer-health.md.
    private var scrollPump: CADisplayLink?
    /// Set by pan `.changed`; the pump consumes it once per frame during a drag.
    private var needsScrollDraw = false
    /// True once the finger lifts: the pump paints every frame through the
    /// deceleration tail instead of waiting on `needsScrollDraw`.
    private var scrollCoasting = false
    private var scrollCoastDeadline: CFTimeInterval = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installScrollHookIfNeeded()
        installPasteLongPressIfNeeded()
    }

    /// The wrapper's own pan-to-scroll recognizer (direct touches, single
    /// finger) gains a second target so scroll-begin is observable without
    /// a competing recognizer.
    private func installScrollHookIfNeeded() {
        guard !scrollHookInstalled else { return }
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
        guard let pan = gestureRecognizers?
            .compactMap({ $0 as? UIPanGestureRecognizer })
            .first(where: {
                !($0 is UIScreenEdgePanGestureRecognizer)
                    && $0.maximumNumberOfTouches == 1
                    && $0.allowedTouchTypes == [directTouch]
            })
        else { return }
        pan.addTarget(self, action: #selector(scrollGestureChanged(_:)))
        scrollHookInstalled = true
    }

    /// The wrapper renders every frame through `DispatchQueue.main.async`
    /// (its `startDisplayLink` is a stub — no real vsync loop), so a finger
    /// scroll lands a beat behind the gesture: the viewport is already moved
    /// but the GPU draw slips past the CA commit deadline. We ride the same
    /// pan recognizer — our target is added after the wrapper's, so by the
    /// time `.changed` reaches us the viewport is current — and hand the draw
    /// to the vsync pump, which coalesces it to one frame. The pump keeps
    /// painting through the momentum tail until the wrapper's glide decelerates.
    @objc private func scrollGestureChanged(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            touchSequenceScrolled = true
            onScrollGesture?()
            scrollSurfaceHandle = ghosttySurfaceHandle()
            scrollCoasting = false
            needsScrollDraw = true
            startScrollPump()
        case .changed:
            // Mark the frame dirty; the pump draws it once at the next vsync.
            // Never draw synchronously here — see `scrollPump` for why that
            // starves the drawable pool and trips libghostty's failsafe.
            needsScrollDraw = true
        case .ended, .cancelled, .failed:
            // Enter the momentum tail; the already-running pump keeps painting.
            scrollCoasting = true
            scrollCoastDeadline = 0 // armed from the first coasting frame
        default:
            break
        }
    }

    /// Mirror the coordinator's proven per-tick sequence (refresh then draw),
    /// on the vsync-aligned call path instead of a deferred main-queue block.
    private func drawScrollFrameNow() {
        guard let handle = scrollSurfaceHandle ?? ghosttySurfaceHandle() else { return }
        termio_ghostty_surface_refresh(handle)
        termio_ghostty_surface_draw(handle)
    }

    private func startScrollPump() {
        guard scrollPump == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(scrollPumpFrame(_:)))
        link.add(to: .main, forMode: .common)
        scrollPump = link
    }

    @objc private func scrollPumpFrame(_ link: CADisplayLink) {
        if scrollCoasting {
            // 0.92-per-frame decel from a hard fling reaches the wrapper's
            // <50 px/s cutoff well inside 1.2 s; past that the surface is idle
            // and the pump is pure waste, so it stops itself.
            if scrollCoastDeadline == 0 { scrollCoastDeadline = link.timestamp + 1.2 }
            if link.timestamp >= scrollCoastDeadline { stopScrollPump(); return }
            drawScrollFrameNow()
        } else if needsScrollDraw {
            // One drawable per vsync, no matter how many `.changed` events the
            // pan delivered this frame — that cap is the whole fix.
            needsScrollDraw = false
            drawScrollFrameNow()
        }
    }

    private func stopScrollPump() {
        scrollPump?.invalidate()
        scrollPump = nil
        scrollCoasting = false
        needsScrollDraw = false
        scrollSurfaceHandle = nil
    }

    /// Raw bytes straight to the PTY — every termio backend is in-memory.
    /// Prompts and terminal keys are whole writes, the same delivery a
    /// keyboard's keys would use.
    func send(_ data: Data) {
        guard case let .inMemory(session) = configuration.backend else { return }
        session.sendInput(data)
    }

    /// Ghostty's embedded surface starts its mouse position at (-1,-1) and
    /// only `ghostty_surface_mouse_pos` moves it — which the wrapper's touch
    /// path never calls. Mouse-reporting TUIs (Claude Code sets ?1003/?1006)
    /// then never receive the scroll gesture: the core encodes wheel events
    /// at the last mouse position and silently drops any event that falls
    /// outside the viewport. Seeding the position from every direct touch
    /// makes the wrapper's own pan-to-scroll reporting work. Remove once the
    /// wrapper sends positions itself (or once we hold a fork of it).
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let hasDirectTouch = touches.contains { $0.type == .direct }
        if hasDirectTouch, let touch = touches.first(where: { $0.type == .direct }),
           let handle = ghosttySurfaceHandle() {
            let location = touch.location(in: self)
            termio_ghostty_surface_mouse_pos(handle, location.x, location.y, 0)
        }
        if hasDirectTouch {
            // A finger that lands while the fling pump is alive is stopping or
            // continuing the scroll — never a keyboard tap.
            touchSequenceScrolled = scrollPump != nil
            touchSequencePresentedPasteMenu = false
            wasFirstResponderAtTouchDown = isFirstResponder
            suppressTouchDownKeyboardRetake = true
            // Warm the Taptic Engine while the 0.3s hold runs, so the
            // long-press confirmation lands AT the timer, not after
            // engine spin-up.
            if clipboardHasStrings { pasteHaptic.prepare() }
        }
        super.touchesBegan(touches, with: event)
        suppressTouchDownKeyboardRetake = false
    }

    /// Refuses only the wrapper's touch-down retake (see
    /// `suppressTouchDownKeyboardRetake`); every other caller — the
    /// controller's focus handoffs, the wrapper's selection copy menu —
    /// passes straight through.
    override func becomeFirstResponder() -> Bool {
        if suppressTouchDownKeyboardRetake { return false }
        return super.becomeFirstResponder()
    }

    /// The keyboard-presenting half of the tap: the touch ran to completion
    /// without ever scrolling, and the keyboard was down when it landed.
    /// (When the pan recognizer wins it usually cancels the touch instead,
    /// which lands in `touchesCancelled` and presents nothing.)
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard touches.contains(where: { $0.type == .direct }) else { return }
        // The paste long-press never reaches here: winning the gesture
        // cancels its touch (touchesCancelled), so an ended touch that
        // didn't scroll really is a tap.
        let wasTap = !touchSequenceScrolled
        touchSequenceScrolled = false
        if wasTap, !wasFirstResponderAtTouchDown, window != nil {
            _ = becomeFirstResponder()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        if touches.contains(where: { $0.type == .direct }) {
            touchSequenceScrolled = false
        }
    }

    /// The `ghostty_surface_t` behind this view, via the wrapper's stored
    /// properties (`core` → `surface` → `surface`) — none of them public.
    /// Resolved fresh per touch so a recreated surface is never stale.
    /// `ghostty_surface_t` is `void *`, which Swift imports as
    /// `UnsafeMutableRawPointer`.
    private func ghosttySurfaceHandle() -> UnsafeMutableRawPointer? {
        guard let coordinator = storedProperty(of: self, named: "core"),
              let terminalSurface = storedProperty(of: coordinator, named: "surface"),
              let handle = storedProperty(of: terminalSurface, named: "surface")
        else { return nil }
        return handle as? UnsafeMutableRawPointer
    }

    private func storedProperty(of subject: Any, named label: String) -> Any? {
        var mirror: Mirror? = Mirror(reflecting: subject)
        while let current = mirror {
            if let value = current.children.first(where: { $0.label == label })?.value {
                let valueMirror = Mirror(reflecting: value)
                guard valueMirror.displayStyle == .optional else { return value }
                return valueMirror.children.first?.value
            }
            mirror = current.superclassMirror
        }
        return nil
    }
}

/// `ghostty_surface_mouse_pos` from the statically linked GhosttyKit, bound
/// by symbol name because the package neither re-exports the C module to app
/// targets nor wraps this call in public API.
@_silgen_name("ghostty_surface_mouse_pos")
private func termio_ghostty_surface_mouse_pos(
    _ surface: UnsafeMutableRawPointer, _ x: Double, _ y: Double, _ mods: Int32
)

/// `ghostty_surface_refresh` / `ghostty_surface_draw` — the same synchronous
/// render pair the coordinator runs each tick, bound by symbol so the scroll
/// path can present a frame at vsync instead of on a deferred main-queue block.
@_silgen_name("ghostty_surface_refresh")
private func termio_ghostty_surface_refresh(_ surface: UnsafeMutableRawPointer)

@_silgen_name("ghostty_surface_draw")
private func termio_ghostty_surface_draw(_ surface: UnsafeMutableRawPointer)

/// Tracks whether the app behind the PTY holds the alternate screen, by
/// watching the output stream for DECSET/DECRST of modes 1049/1047/47 (and
/// RIS, which resets to the primary screen). The terminal core knows this,
/// but libghostty exposes no query for it — and the key bar's viewport jumps
/// must pick a strategy per tap: scrollback jumps on the primary screen,
/// page keys on the alternate one.
private struct AlternateScreenSniffer {
    private(set) var isAlternate = false
    /// Unfinished escape sequence at a chunk's tail, re-parsed with the next
    /// chunk — a mode switch can split across WebSocket frames.
    private var carry = Data()

    mutating func consume(_ chunk: Data) {
        var bytes = [UInt8](carry)
        bytes.append(contentsOf: chunk)
        carry.removeAll(keepingCapacity: true)

        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else { index += 1; continue }
            switch parseEscape(bytes, at: index) {
            case .incomplete:
                // A real mode switch is short; anything longer is content
                // that happens to contain ESC — don't carry it forever.
                if bytes.count - index <= 40 { carry = Data(bytes[index...]) }
                return
            case .altScreen(let entered):
                isAlternate = entered
                index += 1
            case .reset:
                isAlternate = false
                index += 1
            case .other:
                index += 1
            }
        }
    }

    private enum Parse {
        case incomplete
        case altScreen(Bool)
        case reset
        case other
    }

    /// Parses the escape at `start` just far enough to classify it: RIS
    /// (`ESC c`) or a private mode set/reset (`ESC [ ? params h|l`) naming
    /// an alternate-screen mode.
    private func parseEscape(_ bytes: [UInt8], at start: Int) -> Parse {
        var index = start + 1
        guard index < bytes.count else { return .incomplete }
        if bytes[index] == UInt8(ascii: "c") { return .reset }
        guard bytes[index] == UInt8(ascii: "[") else { return .other }
        index += 1
        guard index < bytes.count else { return .incomplete }
        guard bytes[index] == UInt8(ascii: "?") else { return .other }
        index += 1

        var parameters = ""
        while index < bytes.count, parameters.utf8.count <= 32 {
            let byte = bytes[index]
            if (0x30 ... 0x39).contains(byte) || byte == UInt8(ascii: ";") {
                parameters.append(Character(Unicode.Scalar(byte)))
                index += 1
                continue
            }
            guard byte == UInt8(ascii: "h") || byte == UInt8(ascii: "l") else { return .other }
            let names = parameters.split(separator: ";")
            guard names.contains(where: { $0 == "1049" || $0 == "1047" || $0 == "47" }) else {
                return .other
            }
            return .altScreen(byte == UInt8(ascii: "h"))
        }
        return parameters.utf8.count > 32 ? .other : .incomplete
    }
}
