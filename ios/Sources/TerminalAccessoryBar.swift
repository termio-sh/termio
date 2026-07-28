import UIKit

/// One configurable control key: what Settings shows and what the key sends.
/// The catalog is curated from Claude Code's interactive-mode shortcuts — a
/// picker over known-good keys, not a raw byte-sequence builder.
struct TerminalControlKey {
    let id: String
    let title: String
    /// Settings subtitle — what the key does in Claude Code's TUI.
    let detail: String
    let payload: Data
}

enum TerminalKeyCatalog {
    /// Display order everywhere: on the bar and in Settings. Defaults lead,
    /// the long tail follows.
    static let all: [TerminalControlKey] = [
        TerminalControlKey(
            id: "shiftTab", title: "⇧⇥",
            detail: "Cycle permission modes — default, accept edits, plan",
            payload: Data("\u{1B}[Z".utf8)
        ),
        TerminalControlKey(
            id: "tab", title: "tab",
            detail: "Autocomplete, accept a suggestion",
            payload: Data([0x09])
        ),
        TerminalControlKey(
            id: "ctrlO", title: "^O",
            detail: "Toggle the transcript viewer (what the agent did)",
            payload: Data([0x0F])
        ),
        TerminalControlKey(
            id: "ctrlC", title: "^C",
            detail: "Interrupt — pressed twice while idle it exits the agent",
            payload: Data([0x03])
        ),
        TerminalControlKey(
            id: "ctrlL", title: "^L",
            detail: "Redraw a glitched screen",
            payload: Data([0x0C])
        ),
        TerminalControlKey(
            id: "ctrlB", title: "^B",
            detail: "Move the running task to the background",
            payload: Data([0x02])
        ),
        TerminalControlKey(
            id: "ctrlT", title: "^T",
            detail: "Toggle the task checklist",
            payload: Data([0x14])
        ),
        TerminalControlKey(
            id: "ctrlR", title: "^R",
            detail: "Search prompt history",
            payload: Data([0x12])
        ),
        TerminalControlKey(
            id: "ctrlZ", title: "^Z",
            detail: "Suspend the foreground process",
            payload: Data([0x1A])
        ),
        TerminalControlKey(
            id: "ctrlD", title: "^D",
            detail: "End of file — exits a shell or REPL",
            payload: Data([0x04])
        ),
    ]

    /// The research-backed hot set for driving Claude Code from a phone.
    /// Tab earns its default slot on ubiquity: 11 of 12 surveyed mobile
    /// terminals ship it on their bar (completion + field navigation).
    static let defaultIDs = ["shiftTab", "tab", "ctrlO", "ctrlC", "ctrlL"]

    static func keys(for ids: [String]) -> [TerminalControlKey] {
        all.filter { ids.contains($0.id) }
    }
}

/// A sticky modifier on the bar — tap to arm for the next QWERTY key,
/// double-tap to lock (the Termux/iSH state machine, which lives in the
/// terminal view; the bar only reflects it).
enum TerminalStickyKey {
    case ctrl
    case alt
}

/// Where an attachment comes from — the three options of the (+) menu.
enum TerminalAttachSource {
    case camera
    case photos
    case files
}

/// Where a viewport jump lands — the bar's two scroll keys. The owner picks
/// the strategy per tap: on the primary screen it jumps the terminal's own
/// scrollback view; under an alternate-screen TUI (Claude Code) there is no
/// scrollback, so it falls back to page keys the app parses itself.
enum TerminalScrollEdge {
    case top
    case bottom
}

/// The visual face of a sticky key, mirrored from the terminal view's
/// activation state so the two can never drift.
enum TerminalStickyVisual {
    case off
    case armed
    case locked
}

/// The control-key plane docked above the system keyboard while the terminal
/// is focused — two fixed rows, no scrolling (the iSH bar's shape). The
/// system keyboard keeps every letter, digit, symbol, and language; this bar
/// only carries what a terminal needs and the keyboard lacks, in a stable
/// grid so every key is always in the same place:
///
///   esc  ⇧⇥  tab  home  ↑  end  ⤒
///    +   ctrl alt   ←   ↓   →   ⤓
///
/// Two conventions get their corner: esc holds the terminal's top-left, and
/// attach (+) sits bottom-left — where Telegram/WhatsApp put it, the thumb's
/// landing spot beside the QWERTY. The arrows form an inverted T (↑ over ↓,
/// ← → flanking), the desktop muscle-memory layout. ctrl/alt are sticky:
/// tap to arm, then a QWERTY letter forms the combo (ctrl → c = ^C),
/// double-tap locks — so the old configurable ^C/^O keycaps are redundant
/// and gone. esc holds for esc-esc (Claude Code's rewind menu); arrows and
/// ⤒/⤓ auto-repeat. ⤒/⤓ jump the viewport through scrollback on the primary
/// screen and degrade to pgup/pgdn under alternate-screen TUIs.
final class TerminalAccessoryBar: UIInputView {
    /// Raw bytes for the PTY — the owner writes them to the terminal.
    var onKey: ((Data) -> Void)?
    /// A sticky modifier was tapped — the owner toggles the terminal view's
    /// state machine, which reports back through `setStickyVisual`.
    var onSticky: ((TerminalStickyKey) -> Void)?
    /// The attach (+) slot picked a source — photos/files land on the Mac,
    /// their path is typed into the TUI.
    var onAttach: ((TerminalAttachSource) -> Void)?
    /// A viewport jump key was tapped — the owner scrolls the terminal view.
    var onScrollEdge: ((TerminalScrollEdge) -> Void)?
    /// Voice dictation finished — the transcript to type into the terminal.
    /// Never carries a newline: dictation fills the prompt, it never sends it.
    var onVoiceTranscript: ((String) -> Void)?

    static let barHeight: CGFloat = 82
    private static let keyHeight: CGFloat = 32
    private static let keySpacing: CGFloat = 6

    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var stickyButtons: [TerminalStickyKey: UIButton] = [:]
    private let attachButton = UIButton(type: .system)

    /// Voice dictation: the recorder/transcriber, the Messages-style pill that
    /// replaces the two control-key rows while recording, and a reference to
    /// those rows so they can be hidden (the QWERTY keyboard stays put).
    private let voice = VoiceDictation()
    private let voiceBar = VoiceRecordingBar()
    private var keyPlane: UIStackView?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.barHeight),
                   inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = .flexibleWidth

        configureAttachButton()

        // Equal-width columns keep the two rows aligned into a grid — the
        // inverted-T arrows only read as one cluster if ↑ sits exactly over ↓.
        let top = makeRow([
            makeEscButton(),
            makeKeyButton(title: "⇧⇥", payload: Data("\u{1B}[Z".utf8)),
            makeKeyButton(title: "tab", payload: Data([0x09])),
            makeKeyButton(title: "home", payload: Data("\u{1B}[H".utf8)),
            makeKeyButton(title: "↑", payload: Data("\u{1B}[A".utf8), repeats: true),
            makeKeyButton(title: "end", payload: Data("\u{1B}[F".utf8)),
            makeScrollEdgeButton(title: "⤒", edge: .top),
        ])
        let bottom = makeRow([
            attachButton,
            makeStickyButton(title: "ctrl", key: .ctrl),
            makeStickyButton(title: "alt", key: .alt),
            makeKeyButton(title: "←", payload: Data("\u{1B}[D".utf8), repeats: true),
            makeKeyButton(title: "↓", payload: Data("\u{1B}[B".utf8), repeats: true),
            makeKeyButton(title: "→", payload: Data("\u{1B}[C".utf8), repeats: true),
            makeScrollEdgeButton(title: "⤓", edge: .bottom),
        ])

        let plane = UIStackView(arrangedSubviews: [top, bottom])
        plane.axis = .vertical
        plane.spacing = Self.keySpacing
        plane.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plane)
        keyPlane = plane
        NSLayoutConstraint.activate([
            plane.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            plane.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            plane.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            plane.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        // The recording pill fills the bar band. It's hidden until Voice is
        // picked; then the two key rows hide and it takes their place — the
        // system QWERTY keyboard below stays put.
        voiceBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(voiceBar)
        NSLayoutConstraint.activate([
            voiceBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            voiceBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            voiceBar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            voiceBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        voiceBar.onCancel = { [weak self] in
            self?.voice.cancel()
            self?.voiceBar.dismiss()
        }
        voiceBar.onStop = { [weak self] in
            guard let self else { return }
            haptic.impactOccurred()
            voiceBar.showTranscribing()
            voice.stopAndTranscribe { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let text):
                    voiceBar.dismiss()
                    onVoiceTranscript?(text)
                case .failure(let failure):
                    voiceBar.showError(failure.hudMessage)
                }
            }
        }
        // Every exit path (success, cancel, auto-dismissed error) cross-fades
        // the control-key rows back in as the pill leaves.
        voiceBar.onDismissed = { [weak self] in
            self?.hideVoiceBar()
        }
    }

    /// Picked Voice from the (+) menu: swap the two control-key rows for the
    /// pill and start recording. A start failure (no key, mic denied) surfaces
    /// in the pill itself. The QWERTY keyboard is untouched.
    private func startVoiceRecording() {
        haptic.impactOccurred()
        showVoiceBar()
        voice.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                voiceBar.beginRecording(levelProvider: { [weak self] in self?.voice.currentLevel() ?? 0 })
            case .failure(let failure):
                voiceBar.showError(failure.hudMessage)
            }
        }
    }

    /// Materialize the pill: it scales up from 0.96 + fades in while the key
    /// rows fade out under it — critically damped, no overshoot (the pill
    /// didn't come from a flick), under 300ms, ease-out for an entrance. Under
    /// Reduce Motion it's a plain opacity cross-fade, no transform.
    private func showVoiceBar() {
        let reduce = UIAccessibility.isReduceMotionEnabled
        bringSubviewToFront(voiceBar)
        voiceBar.isHidden = false
        voiceBar.alpha = 0
        voiceBar.transform = reduce ? .identity : CGAffineTransform(scaleX: 0.96, y: 0.96)
        UIView.animate(
            withDuration: reduce ? 0.2 : 0.28, delay: 0,
            usingSpringWithDamping: 1, initialSpringVelocity: 0,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            self.voiceBar.alpha = 1
            self.voiceBar.transform = .identity
            self.keyPlane?.alpha = 0
        } completion: { _ in
            self.keyPlane?.isHidden = true
        }
    }

    /// Reverse of `showVoiceBar` — the pill fades/scales out along the same path
    /// as the key rows fade back in, so the swap reads as one motion.
    private func hideVoiceBar() {
        let reduce = UIAccessibility.isReduceMotionEnabled
        keyPlane?.alpha = 0
        keyPlane?.isHidden = false
        UIView.animate(
            withDuration: reduce ? 0.2 : 0.24, delay: 0,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            self.voiceBar.alpha = 0
            self.voiceBar.transform = reduce ? .identity : CGAffineTransform(scaleX: 0.96, y: 0.96)
            self.keyPlane?.alpha = 1
        } completion: { _ in
            self.voiceBar.isHidden = true
            self.voiceBar.transform = .identity
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight)
    }

    private func makeRow(_ keys: [UIView]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: keys)
        row.axis = .horizontal
        row.spacing = Self.keySpacing
        row.distribution = .fillEqually
        return row
    }

    // MARK: - Attach slot

    private func configureAttachButton() {
        var config: UIButton.Configuration = if #available(iOS 26.0, *) {
            .glass()
        } else {
            .gray()
        }
        config.image = UIImage(
            systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        )
        config.cornerStyle = .medium
        attachButton.configuration = config
        attachButton.accessibilityLabel = "Attach"
        attachButton.tintColor = .label
        // Invisible until the owner reports an upload backend, but never
        // removed — the grid must not reflow around it.
        attachButton.alpha = 0
        attachButton.isEnabled = false
        attachButton.heightAnchor.constraint(equalToConstant: Self.keyHeight).isActive = true
        // The messenger interaction: + pops a light source menu hugging the
        // key bar's top edge, then hands off to the matching SYSTEM picker.
        // Hand-rolled and anchored by frame math: UIMenu decides its own
        // placement and floats way above the keyboard when its anchor lives
        // in the keyboard window.
        attachButton.addAction(UIAction { [weak self] _ in
            self?.haptic.impactOccurred()
            self?.toggleAttachMenu()
        }, for: .touchUpInside)
        // A quick dip on finger-down gives the key iMessage's tactile press
        // before the menu even opens.
        attachButton.addAction(UIAction { [weak self] _ in
            UIView.animate(withDuration: 0.12, delay: 0, options: .allowUserInteraction) {
                self?.attachButton.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
            }
        }, for: .touchDown)
    }

    /// Spins the (+) glyph into an (×) while the menu is up, and back on
    /// close — plus a spring pop that releases the touch-down dip.
    private func setAttachButtonOpen(_ open: Bool) {
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.6,
                       initialSpringVelocity: 0, options: .allowUserInteraction) {
            self.attachButton.transform = .identity
            self.attachButton.imageView?.transform =
                open ? CGAffineTransform(rotationAngle: .pi / 4) : .identity
        }
    }

    // MARK: - Attach source menu

    private var attachMenuScrim: UIControl?
    private weak var attachMenuCard: UIView?

    private func toggleAttachMenu() {
        if attachMenuScrim != nil {
            dismissAttachMenu()
        } else {
            presentAttachMenu()
        }
    }

    /// The floating source card, placed directly above the (+) key in the
    /// keyboard's own window — same window, so no cross-window z-order can
    /// clip it and the keyboard never occludes it.
    private func presentAttachMenu() {
        guard let window, attachMenuScrim == nil else { return }

        let scrim = UIControl(frame: window.bounds)
        scrim.addAction(UIAction { [weak self] _ in self?.dismissAttachMenu() }, for: .touchUpInside)
        window.addSubview(scrim)
        attachMenuScrim = scrim

        // The native menu look: Liquid Glass on iOS 26 (the same material a
        // real UIMenu wears), the classic thick blur before it, wrapped in a
        // shadowed container because the glass view must clip its rows.
        let effect: UIVisualEffect = if #available(iOS 26, *) {
            UIGlassEffect(style: .regular)
        } else {
            UIBlurEffect(style: .systemThickMaterial)
        }
        let glass = UIVisualEffectView(effect: effect)
        glass.clipsToBounds = true
        glass.layer.cornerRadius = 26
        glass.layer.cornerCurve = .continuous

        // iMessage's (+) chips aren't flat — each is a diagonal gradient
        // squircle. We mirror its palette: a dark camera lens, the Photos
        // rainbow, a red-orange audio capsule, and the Files blue.
        let rows = UIStackView(arrangedSubviews: [
            makeMenuRow(title: "Camera", symbol: "camera.fill",
                        colors: [Self.hex(0x8A8F98), Self.hex(0x3A3D42)]) { [weak self] in self?.onAttach?(.camera) },
            makeMenuRow(title: "Photos", symbol: "photo.fill",
                        colors: [Self.hex(0xFCC72E), Self.hex(0xF6499A), Self.hex(0x3E9BFE)]) { [weak self] in self?.onAttach?(.photos) },
            makeMenuRow(title: "Voice", symbol: "waveform",
                        colors: [Self.hex(0xFF8A5B), Self.hex(0xFB2C55)]) { [weak self] in self?.startVoiceRecording() },
            makeMenuRow(title: "Files", symbol: "folder.fill",
                        colors: [Self.hex(0x39B9FF), Self.hex(0x0A7BFF)]) { [weak self] in self?.onAttach?(.files) },
        ])
        rows.axis = .vertical
        rows.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(rows)

        // Bottom-left corner of the card sits just above the (+) key.
        let anchor = attachButton.convert(attachButton.bounds, to: window)
        let size = CGSize(width: 258, height: 4 * 54 + 12)
        let card = UIView(frame: CGRect(
            x: max(8, anchor.minX),
            y: anchor.minY - size.height - 8,
            width: size.width, height: size.height
        ))
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.18
        card.layer.shadowRadius = 34
        card.layer.shadowOffset = CGSize(width: 0, height: 12)
        card.layer.shadowPath = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 26
        ).cgPath
        glass.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            glass.topAnchor.constraint(equalTo: card.topAnchor),
            glass.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            rows.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 6),
            rows.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -6),
        ])
        scrim.addSubview(card)
        attachMenuCard = card

        // UIMenu's entrance: grow from the bottom-left corner (the (+) key)
        // with a soft spring — the translate keeps that corner pinned while
        // the card scales up out of it. Under Reduce Motion it's a plain fade,
        // no scale-from-corner (matches showVoiceBar's pattern).
        let reduce = UIAccessibility.isReduceMotionEnabled
        let collapsed = CGAffineTransform(scaleX: 0.4, y: 0.4)
            .translatedBy(x: -size.width * 0.5, y: size.height * 0.5)
        card.alpha = 0
        card.transform = reduce ? .identity : collapsed
        UIView.animate(withDuration: reduce ? 0.2 : 0.4, delay: 0,
                       usingSpringWithDamping: 0.78, initialSpringVelocity: 0) {
            card.alpha = 1
            card.transform = .identity
        }
        setAttachButtonOpen(true)
    }

    private func dismissAttachMenu() {
        setAttachButtonOpen(false)
        guard let scrim = attachMenuScrim else { return }
        attachMenuScrim = nil
        // Collapse back into the (+) key, mirroring the entrance.
        let card = attachMenuCard
        let size = card?.bounds.size ?? .zero
        // Decouple the shrink from the fade rather than easing both IN (which delayed the whole
        // exit): the card collapses toward the (+) key on ease-OUT so the response is immediate,
        // while its alpha rides ease-IN — staying opaque until the small end so no faint large
        // "ghost" lingers. Under Reduce Motion it's a plain fade, no scale-into-the-corner.
        let reduce = UIAccessibility.isReduceMotionEnabled
        if !reduce {
            UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
                card?.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
                    .translatedBy(x: -size.width * 0.5, y: size.height * 0.5)
            }
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseIn) {
            card?.alpha = 0
        } completion: { _ in
            scrim.removeFromSuperview()
        }
    }

    /// One source row in the newest-Messages style: a filled SF symbol in a
    /// tinted rounded chip on the leading edge, then the label — the iMessage
    /// (+) app-row look, cleaner than the plain UIMenu icon-on-the-right shape.
    private func makeMenuRow(
        title: String, symbol: String, colors: [UIColor], handler: @escaping () -> Void
    ) -> UIView {
        let button = UIButton(type: .system)
        button.heightAnchor.constraint(equalToConstant: 54).isActive = true
        button.addAction(UIAction { [weak self] _ in
            self?.dismissAttachMenu()
            handler()
        }, for: .touchUpInside)

        let chip = GradientChipView(colors: colors)
        chip.isUserInteractionEnabled = false
        chip.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        ))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(icon)

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 17)
        label.textColor = .label
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false

        button.addSubview(chip)
        button.addSubview(label)
        button.accessibilityLabel = title
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
            chip.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            chip.widthAnchor.constraint(equalToConstant: 34),
            chip.heightAnchor.constraint(equalToConstant: 34),
            icon.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -16),
        ])
        return button
    }

    /// 0xRRGGBB → UIColor, for the fixed iMessage-style chip palette.
    static func hex(_ rgb: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Shows the attach (+) — only sessions with a Mac behind them can
    /// receive uploads. The slot stays in the grid either way.
    func setAttachAvailable(_ available: Bool) {
        attachButton.alpha = available ? 1 : 0
        attachButton.isEnabled = available
    }

    /// Dims the attach slot while an upload is in flight; a batch shows its
    /// "n/m" position in place of the plus.
    func setAttachBusy(_ busy: Bool, progress: (done: Int, total: Int)? = nil) {
        attachButton.isEnabled = !busy
        var config = attachButton.configuration
        if busy, let progress, progress.total > 1 {
            config?.image = nil
            config?.title = "\(progress.done + 1)/\(progress.total)"
        } else {
            config?.title = nil
            config?.image = UIImage(
                systemName: "plus",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            )
        }
        attachButton.configuration = config
    }

    // MARK: - Sticky modifiers

    /// The terminal view's state machine reported a transition — repaint the
    /// key so armed/locked are visible (armed = tinted, locked = filled).
    func setStickyVisual(_ key: TerminalStickyKey, _ visual: TerminalStickyVisual) {
        guard let button = stickyButtons[key] else { return }
        var config = button.configuration
        switch visual {
        case .off:
            config?.baseBackgroundColor = nil
            config?.baseForegroundColor = .label
        case .armed:
            config?.baseBackgroundColor = UIColor.tintColor.withAlphaComponent(0.3)
            config?.baseForegroundColor = .label
        case .locked:
            config?.baseBackgroundColor = .tintColor
            config?.baseForegroundColor = .white
        }
        button.configuration = config
    }

    private func makeStickyButton(title: String, key: TerminalStickyKey) -> UIButton {
        // .gray() (not glass) on every OS: the armed/locked repaint needs a
        // background the configuration owns — the iOS 26 glass background
        // ignores baseBackgroundColor.
        var config: UIButton.Configuration = .gray()
        config.title = title
        config.baseForegroundColor = .label
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        config.titleTextAttributesTransformer = .init { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 14)
            return attributes
        }
        let button = UIButton(configuration: config)
        button.accessibilityLabel = title
        button.heightAnchor.constraint(equalToConstant: Self.keyHeight).isActive = true
        button.addAction(UIAction { [weak self] _ in
            self?.haptic.impactOccurred()
            self?.onSticky?(key)
        }, for: .touchUpInside)
        stickyButtons[key] = button
        return button
    }

    // MARK: - Keys

    private func makeKeyConfiguration(title: String) -> UIButton.Configuration {
        var config: UIButton.Configuration = if #available(iOS 26.0, *) {
            .glass()
        } else {
            .gray()
        }
        config.title = title
        config.baseForegroundColor = .label
        config.cornerStyle = .medium
        // Slim insets: the grid fixes each cell's width, so word keys like
        // "home" need every point for their glyphs.
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        config.titleTextAttributesTransformer = .init { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 14)
            return attributes
        }
        return config
    }

    private func makeKeyButton(title: String, payload: Data, repeats: Bool = false) -> UIButton {
        let config = makeKeyConfiguration(title: title)
        let fire: () -> Void = { [weak self] in
            self?.haptic.impactOccurred()
            self?.onKey?(payload)
        }
        let button: UIButton
        if repeats {
            let repeating = RepeatingKeyButton(configuration: config)
            repeating.onFire = fire
            button = repeating
        } else {
            button = UIButton(configuration: config)
            button.addAction(UIAction { _ in fire() }, for: .touchUpInside)
        }
        button.accessibilityLabel = title
        button.titleLabel?.numberOfLines = 1
        button.heightAnchor.constraint(equalToConstant: Self.keyHeight).isActive = true
        return button
    }

    /// A viewport jump key (⤒/⤓) — fires `onScrollEdge` instead of a fixed
    /// payload so the owner can pick scrollback jump vs page key. Repeats on
    /// hold: paging an alternate-screen TUI takes one fire per page.
    private func makeScrollEdgeButton(title: String, edge: TerminalScrollEdge) -> UIButton {
        let button = RepeatingKeyButton(configuration: makeKeyConfiguration(title: title))
        button.onFire = { [weak self] in
            self?.haptic.impactOccurred()
            self?.onScrollEdge?(edge)
        }
        button.accessibilityLabel = edge == .top ? "Scroll to top" : "Scroll to bottom"
        button.heightAnchor.constraint(equalToConstant: Self.keyHeight).isActive = true
        return button
    }

    /// esc with a hold: tap interrupts, a long press sends esc-esc — Claude
    /// Code's rewind menu (or clear-draft), which has no single-key form.
    private func makeEscButton() -> UIButton {
        let button = makeKeyButton(title: "esc", payload: Data([0x1B]))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(escHeld(_:)))
        hold.cancelsTouchesInView = true
        button.addGestureRecognizer(hold)
        return button
    }

    @objc private func escHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        haptic.impactOccurred()
        onKey?(Data([0x1B]))
        // Two distinct presses, not one write: back-to-back 0x1B bytes read
        // as a single Alt-prefixed key to a terminal parser.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.onKey?(Data([0x1B]))
        }
    }
}

/// A button that behaves like a held key: a tap fires once, holding fires and
/// then repeats — long agent menus would otherwise cost one tap per row.
/// Used by the accessory bar's arrows.
final class RepeatingKeyButton: UIButton {
    var onFire: (() -> Void)?

    private static let initialDelay: TimeInterval = 0.4
    private static let repeatInterval: TimeInterval = 0.12

    private var repeatTimer: Timer?
    private var heldLongEnoughToRepeat = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(pressBegan), for: .touchDown)
        addTarget(
            self, action: #selector(pressEnded),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        repeatTimer?.invalidate()
    }

    @objc private func pressBegan() {
        heldLongEnoughToRepeat = false
        let timer = Timer(timeInterval: Self.initialDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginRepeating() }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func beginRepeating() {
        heldLongEnoughToRepeat = true
        onFire?()
        let timer = Timer(timeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFire?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    @objc private func pressEnded() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        // A quick tap never reached the repeat threshold — fire it once here;
        // a held press already delivered its keys.
        if !heldLongEnoughToRepeat {
            onFire?()
        }
        heldLongEnoughToRepeat = false
    }
}

/// A rounded chip filled with a top-left→bottom-right gradient — the depth
/// iMessage gives its (+) source icons, which a flat tint can't match.
final class GradientChipView: UIView {
    private let gradient = CAGradientLayer()

    init(colors: [UIColor]) {
        super.init(frame: .zero)
        gradient.colors = colors.map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        // iMessage's source chips are full circles, not rounded squares.
        gradient.cornerRadius = bounds.height / 2
    }
}
