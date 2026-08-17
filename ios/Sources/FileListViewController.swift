import TermioShared
import UIKit

/// What a file list needs from whoever owns the companion socket. The inspector
/// implements it; every pushed directory screen borrows the same link.
protocol RemoteFileBrowsing: AnyObject {
    /// One directory's entries ("" is the project root). The reply may be slow (it
    /// crosses the wire) or immediate (the offline sample tree).
    func listEntries(at path: String, then: @escaping ([WireFileEntry]) -> Void)
    /// Open a file in the read-only viewer.
    func openFile(at path: String)
    /// The file's absolute path on the Mac — what "Copy Path" yields, ready to paste
    /// into an agent prompt.
    func absolutePath(for path: String) -> String
}

/// One directory, one screen — the Apple Files shape. An indented tree loses 18pt of a
/// 390pt screen per level, so by the fourth folder half the width is gutter and every
/// name is truncated; drilling in spends nothing, and the navigation bar's title and
/// back button say where you are and walk you out.
final class FileListViewController: UITableViewController {
    private let path: String
    private weak var browser: RemoteFileBrowsing?
    private var entries: [WireFileEntry] = []
    private var loaded = false
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(path: String, browser: RemoteFileBrowsing) {
        self.path = path
        self.browser = browser
        super.init(style: .plain)
        title = (path as NSString).lastPathComponent
        // The breadcrumb: where this folder sits, above its own name.
        let parent = (path as NSString).deletingLastPathComponent
        navigationItem.prompt = parent.isEmpty ? nil : parent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        spinner.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        browser?.listEntries(at: path) { [weak self] entries in
            guard let self else { return }
            self.entries = entries
            loaded = true
            spinner.stopAnimating()
            navigationItem.rightBarButtonItem = nil
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        loaded && entries.isEmpty ? localized("This folder is empty.") : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .default, reuseIdentifier: "cell")
        FileRow.configure(cell, entry: entries[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let browser else { return }
        let entry = entries[indexPath.row]
        let child = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
        if entry.isDir {
            navigationController?.pushViewController(
                FileListViewController(path: child, browser: browser), animated: true
            )
        } else {
            browser.openFile(at: child)
        }
    }

    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let browser else { return nil }
        return FileRow.menu(for: entries[indexPath.row], in: path, browser: browser)
    }
}

// MARK: - Shared row

/// The one recipe for a file/folder row, so the root listing in the drawer and every
/// pushed directory read identically.
enum FileRow {
    /// `subtitle` is for the flat search results, where a name alone doesn't say which
    /// file it is; a directory listing needs none.
    static func configure(_ cell: UITableViewCell, entry: WireFileEntry, subtitle: String? = nil) {
        var config = cell.defaultContentConfiguration()
        config.text = entry.name
        config.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        config.secondaryText = subtitle
        config.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
        config.secondaryTextProperties.color = .secondaryLabel
        let icon = entry.isDir ? FileIcons.folder() : FileIcons.icon(forFileName: entry.name)
        config.image = icon.image
        config.imageProperties.tintColor = icon.tint
        // Icons vary in width (folder vs logo vs symbol); a fixed layout box keeps
        // every name at the same leading edge.
        config.imageProperties.maximumSize = CGSize(width: 16, height: 16)
        config.imageProperties.reservedLayoutSize = CGSize(width: 16, height: 16)
        cell.contentConfiguration = config
        // A directory keeps its chevron even when it carries a changed dot: the system
        // accessory type and a custom accessory view are mutually exclusive, so a row
        // that needs both draws both itself.
        cell.accessoryType = .none
        cell.accessoryView = accessory(changed: entry.changed, isDir: entry.isDir)
    }

    private static func accessory(changed: Bool, isDir: Bool) -> UIView? {
        var pieces: [UIView] = []
        if changed { pieces.append(changedDot()) }
        if isDir { pieces.append(chevron()) }
        guard !pieces.isEmpty else { return nil }
        let stack = UIStackView(arrangedSubviews: pieces)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        // A stack lays its children out by intrinsic size and ignores their frames, so
        // both pieces carry constraints — a bare `UIView` dot would otherwise collapse to
        // zero width and vanish. The cell then sizes the accessory from this frame.
        stack.frame = CGRect(
            origin: .zero,
            size: stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        )
        return stack
    }

    static func menu(
        for entry: WireFileEntry, in parent: String, browser: RemoteFileBrowsing
    ) -> UIContextMenuConfiguration {
        let relative = parent.isEmpty ? entry.name : "\(parent)/\(entry.name)"
        let absolute = browser.absolutePath(for: relative)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak browser] _ in
            var actions: [UIMenuElement] = []
            if !entry.isDir {
                actions.append(UIAction(title: localized("Open File"), image: UIImage(systemName: "doc.text")) { _ in
                    browser?.openFile(at: relative)
                })
            }
            actions.append(UIAction(title: localized("Copy Path"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = absolute
            })
            return UIMenu(title: relative, children: actions)
        }
    }

    /// The system disclosure indicator's twin, drawn by hand so it can sit beside the
    /// changed dot (a cell's accessory type and accessory view are mutually exclusive).
    private static func chevron() -> UIView {
        let image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        let view = UIImageView(image: image)
        view.tintColor = .tertiaryLabel
        view.contentMode = .scaleAspectFit
        return view
    }

    /// The dot marking a file the working diff touches (and the folders above it) —
    /// the same signal the desktop tree shows.
    private static func changedDot() -> UIView {
        let dot = UIView()
        dot.backgroundColor = .systemBlue
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        return dot
    }
}
