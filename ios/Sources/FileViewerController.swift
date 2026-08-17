import Highlightr
import QuickLook
import TermioShared
import UIKit
import WebKit

/// Full-screen file view — the phone's counterpart of the macOS editor
/// overlay: a compact header (name · repo-relative path · close), the content
/// in a Highlightr-backed text view (same xcode/xcode-dark themes as the
/// desktop, re-highlighting live as you type), and a slim footer (language ·
/// size · save state). Read-only until the pencil is tapped — on a phone
/// stray touches are the norm, so editing is opt-in per open. Edits auto-save
/// like the macOS editor: a short idle after the last keystroke flushes to
/// the Mac, closing flushes anything pending, and a conflicting write on the
/// Mac side (usually the agent) surfaces as Reload / Overwrite instead of a
/// silent clobber. Binary content hands off to Quick Look.
final class FileViewerController: UIViewController {
    private let fileName: String
    private let relativePath: String
    private let file: WireFile

    /// Ship edited bytes to the Mac: `(payload, baseMtime)`; 0 forces the
    /// write past the conflict check. nil = viewer stays read-only (offline
    /// demos, truncated reads).
    var onSave: ((Data, Int) -> Void)?
    /// Re-fetch the file after a conflict reload; called post-dismiss.
    var onReload: (() -> Void)?

    /// Highlightr's editing-aware storage — re-highlights the edited range
    /// live, the same engine the macOS editor's HighlightedTextView rides.
    private let storage = CodeAttributedString()
    private var textView: UITextView!
    private let footerLabel = UILabel()
    private let editButton = UIButton(type: .system)
    private var rendered = false

    /// The Mac-rendered Markdown preview (`WireFile.html`), shown in a web
    /// view over the text view — the TraceViewController pattern. Markdown
    /// opens in preview; the pencil flips to source (and editing, when
    /// allowed). One-way per open: the preview HTML was rendered from the
    /// bytes as fetched, so after edits it would lie — reopening re-renders.
    private var webView: WKWebView?
    private var previewing = false

    private var editMode = false
    /// mtime (ms) the current buffer is based on; advanced by each `written`.
    private var baseMtime: Int
    /// The last content the Mac acknowledged, so idle flushes skip no-ops.
    private var savedText: String
    /// Content in flight (sent, not yet acked).
    private var pendingSaveText: String?
    private var saveDebounce: DispatchWorkItem?

    init(file: WireFile) {
        self.file = file
        fileName = (file.path as NSString).lastPathComponent
        relativePath = file.path
        baseMtime = file.mtime
        savedText = file.data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A Quick Look controller for binary payloads, or nil when writing the
    /// temp file fails. The file keeps its real name so QL sniffs the type.
    static func quickLook(for file: WireFile) -> UIViewController? {
        guard let data = file.data else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-preview", isDirectory: true)
        let name = (file.path as NSString).lastPathComponent
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            return nil
        }
        let preview = QuickLookPreview(url: url)
        preview.modalPresentationStyle = .fullScreen
        return preview
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let header = configureHeader()
        let footer = configureFooter()
        configureText(below: header, above: footer)
        configurePreview(below: header, above: footer)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Rendering waits for presentation: only now does traitCollection
        // reflect the window's real appearance, and the highlight theme
        // (xcode vs xcode-dark) must match it.
        if !rendered {
            rendered = true
            render()
        }
    }

    // MARK: - Chrome

    private func configureHeader() -> UIView {
        let close = UIButton(type: .system)
        close.applyGlassSymbol("xmark")
        close.tintColor = .label
        close.addAction(UIAction { [weak self] _ in
            self?.flushAndClose()
        }, for: .touchUpInside)

        let name = UILabel()
        name.text = fileName
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = .label
        name.lineBreakMode = .byTruncatingTail

        let path = UILabel()
        path.text = relativePath
        path.font = .preferredFont(forTextStyle: .caption2)
        path.textColor = .secondaryLabel
        path.lineBreakMode = .byTruncatingMiddle
        path.isHidden = relativePath == fileName

        let titles = UIStackView(arrangedSubviews: [name, path])
        titles.axis = .vertical
        titles.alignment = .center

        editButton.applyGlassSymbol("pencil")
        editButton.tintColor = .label
        editButton.isHidden = !canEdit
        editButton.addAction(UIAction { [weak self] _ in
            self?.toggleEditing()
        }, for: .touchUpInside)

        let bar = UIStackView(arrangedSubviews: [close, titles, editButton])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 4
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            // Square 40pt circles (Telegram nav-bar scale), not 40×36 ovals.
            close.widthAnchor.constraint(equalToConstant: 40),
            close.heightAnchor.constraint(equalToConstant: 40),
            editButton.widthAnchor.constraint(equalToConstant: 40),
            editButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        return bar
    }

    private func configureFooter() -> UIView {
        footerLabel.font = .preferredFont(forTextStyle: .caption2)
        footerLabel.textColor = .secondaryLabel
        footerLabel.textAlignment = .center
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footerLabel)
        NSLayoutConstraint.activate([
            footerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            footerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            // The keyboard guide tracks the safe-area bottom when hidden, so
            // the footer rides above the keyboard while editing.
            footerLabel.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -4),
        ])
        return footerLabel
    }

    private func configureText(below header: UIView, above footer: UIView) {
        // TextKit stack around Highlightr's storage — the text view edits the
        // attributed string the highlighter owns, so colors stay live.
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        textView = UITextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.delegate = self
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
        ])
    }

    /// The Markdown preview layer, only when the Mac sent one. Sits over the
    /// text view with the same frame; transparent like TraceViewController so
    /// the themed page's own background shows through cleanly.
    private func configurePreview(below header: UIView, above footer: UIView) {
        guard let html = file.html else { return }
        let web = WKWebView()
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
        ])
        web.loadHTMLString(html, baseURL: nil)
        webView = web
        previewing = true
        textView.isHidden = true
    }

    private func leavePreview() {
        previewing = false
        webView?.removeFromSuperview()
        webView = nil
        textView.isHidden = false
    }

    // MARK: - Content

    private var canEdit: Bool {
        onSave != nil && !file.binary && !file.truncated
    }

    private func render() {
        guard let data = file.data, let text = String(data: data, encoding: .utf8) else {
            textView.text = localized("Couldn't decode this file as text.")
            footerLabel.text = Self.format(bytes: file.size)
            editButton.isHidden = true
            return
        }
        let language = CodeHighlighter.language(forFileNamed: fileName)
        let dark = traitCollection.userInterfaceStyle == .dark
        storage.highlightr.setTheme(to: dark ? "xcode-dark" : "xcode")
        storage.highlightr.theme.setCodeFont(MobileSettings.shared.codeFont())
        textView.text = text
        // Setting the language kicks the initial (async) highlight pass.
        storage.language = language
        updateFooter()
    }

    private func updateFooter(state: String? = nil) {
        var parts = [
            CodeHighlighter.language(forFileNamed: fileName) ?? localized("plain text"),
            Self.format(bytes: file.size),
        ]
        if file.truncated { parts.append(localized("truncated preview")) }
        if let state { parts.append(state) }
        footerLabel.text = parts.joined(separator: " · ")
    }

    private static func format(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Editing / auto-save

    private func toggleEditing() {
        // From the Markdown preview, the pencil first drops to the source —
        // then straight into editing, one tap, like the Mac's Preview→edit flip.
        if previewing { leavePreview() }
        if editMode {
            // Done: flush whatever is pending and drop the keyboard.
            saveDebounce?.cancel()
            flushSave()
            editMode = false
            textView.isEditable = false
            textView.resignFirstResponder()
            editButton.applyGlassSymbol("pencil")
        } else {
            editMode = true
            textView.isEditable = true
            textView.becomeFirstResponder()
            editButton.applyGlassSymbol("checkmark")
            updateFooter(state: "editing")
        }
    }

    private func scheduleSave() {
        updateFooter(state: "edited")
        saveDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        saveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func flushSave(force: Bool = false) {
        guard let onSave else { return }
        let text = textView.text ?? ""
        guard force || (text != savedText && pendingSaveText == nil) else { return }
        pendingSaveText = text
        updateFooter(state: localized("saving…"))
        onSave(Data(text.utf8), force ? 0 : baseMtime)
    }

    /// The Mac acknowledged the write (routed in by the inspector).
    func didSave(mtime: Int) {
        baseMtime = mtime
        if let pending = pendingSaveText { savedText = pending }
        pendingSaveText = nil
        updateFooter(state: localized("saved"))
        // Keystrokes landed while the write was in flight — save them too.
        if textView.text != savedText { scheduleSave() }
    }

    /// A write failed (routed in by the inspector). Conflicts offer the two
    /// honest ways out; other errors just surface.
    func saveFailed(_ message: String) {
        pendingSaveText = nil
        guard message.hasPrefix("conflict") else {
            updateFooter(state: localized("save failed"))
            let alert = UIAlertController(title: localized("Couldn't save"), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: localized("OK"), style: .default))
            present(alert, animated: true)
            return
        }
        updateFooter(state: localized("conflict"))
        let alert = UIAlertController(
            title: localized("File changed on the Mac"),
            message: localized("\(fileName) was modified since you opened it — likely by the agent."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: localized("Reload"), style: .default) { [weak self] _ in
            guard let self else { return }
            let onReload = onReload
            dismiss(animated: true) { onReload?() }
        })
        alert.addAction(UIAlertAction(title: localized("Overwrite"), style: .destructive) { [weak self] _ in
            self?.flushSave(force: true)
        })
        alert.addAction(UIAlertAction(title: localized("Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func flushAndClose() {
        saveDebounce?.cancel()
        // Fire-and-forget is safe: the inspector owns the socket and outlives
        // this screen, so a close right after a keystroke still lands.
        if editMode { flushSave() }
        dismiss(animated: true)
    }
}

extension FileViewerController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        guard editMode else { return }
        scheduleSave()
    }
}

// MARK: - Quick Look host

/// QLPreviewController with a single local item — used for binary payloads
/// (images, PDFs) written to a temp file.
private final class QuickLookPreview: QLPreviewController, QLPreviewControllerDataSource {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        url as NSURL
    }
}
