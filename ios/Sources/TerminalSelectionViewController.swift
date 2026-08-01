import UIKit

/// The long-press "select text" page: a frozen snapshot of the terminal
/// viewport in a plain text view, where iOS's own selection machinery —
/// handles, magnifier, the system edit menu — does the work the Metal
/// surface can't. The wrapper resolves the word under the finger before
/// presenting, so the page opens with that word already selected and the
/// user only adjusts the handles (the Termius/blink select-mode shape).
///
/// The page is also where touch users reach Paste: the bar's Paste button
/// hands the clipboard back to the owner, who types it into the PTY. The
/// page itself never touches the byte stream.
final class TerminalSelectionViewController: UIViewController {
    /// Clipboard text the user asked to type into the terminal.
    var onPaste: ((String) -> Void)?
    /// The page left the screen by any route (Copy, Paste, swipe-down) —
    /// the owner hands keyboard focus back to the terminal.
    var onClosed: (() -> Void)?

    private let snapshotText: String
    private let anchorRange: NSRange?
    private let textView = UITextView()
    private var backdropObserver: NSObjectProtocol?
    private var didPreselect = false

    init(text: String, anchorRange: NSRange?) {
        snapshotText = text
        self.anchorRange = anchorRange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let backdropObserver {
            NotificationCenter.default.removeObserver(backdropObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Select Text"
        backdropObserver = installThemeBackdrop()

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Paste", style: .plain,
            target: self, action: #selector(pasteTapped)
        )
        // `hasStrings` never triggers the system paste prompt; reading
        // `.string` is deferred to the tap, where iOS grants it as a
        // user-initiated paste.
        navigationItem.leftBarButtonItem?.isEnabled = UIPasteboard.general.hasStrings
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Copy", style: .done,
            target: self, action: #selector(copyTapped)
        )

        // The terminal's own text, so the page reads as a still frame of the
        // surface underneath — monospaced, on the theme backdrop.
        textView.text = snapshotText
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Selection handles need the text view to hold first responder; the
        // view is non-editable, so no keyboard comes with it. Only once —
        // reappearing must not clobber a selection the user already adjusted.
        guard !didPreselect else { return }
        didPreselect = true
        textView.becomeFirstResponder()
        let range = anchorRange
            ?? NSRange(location: 0, length: (snapshotText as NSString).length)
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onClosed?()
    }

    @objc private func copyTapped() {
        let text = textView.text ?? ""
        let selected = textView.selectedRange
        let raw = selected.length > 0
            ? (text as NSString).substring(with: selected)
            : text
        UIPasteboard.general.string = Self.sanitizedForClipboard(raw)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss(animated: true)
    }

    @objc private func pasteTapped() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        let onPaste = onPaste
        dismiss(animated: true) { onPaste?(text) }
    }

    /// blink's clipboard rule: the terminal grid pads rows with spaces, so
    /// strip trailing spaces/tabs from every line (and normalize CRLF) or a
    /// pasted command drags a wall of padding with it.
    static func sanitizedForClipboard(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                var trimmed = Substring(line)
                while let last = trimmed.last, last == " " || last == "\t" {
                    trimmed.removeLast()
                }
                return String(trimmed)
            }
            .joined(separator: "\n")
    }
}
