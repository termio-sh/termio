import TermioShared
import UIKit

/// The chat lens: a session's conversation rendered natively from the content
/// plane, as an alternative to looking at the same session's terminal grid.
///
/// It is not a second kind of session and not a chat client bolted onto a
/// terminal — it is the same live session seen through its structured events.
/// The four things it can do that an 80-column grid on a phone cannot are the
/// whole reason it exists, and the bar it has to clear:
///
/// 1. A dormant session still reads — the transcript outlives the process, so
///    this view has content where the terminal has a blank screen.
/// 2. Diffs render as diffs, at phone width, instead of wrapped grid rows.
/// 3. A plan is a checklist rather than a redrawn box.
/// 4. (Next) a permission question is a button rather than a menu you arrow to.
///
/// Two rules keep it smooth on a long conversation, both borrowed from how chat
/// clients that scroll well are built:
///
/// - **Attributed text is produced once per row and cached**, never rebuilt in
///   `cellForRowAt`. Parsing Markdown during scrolling is the classic way to
///   turn a transcript into a stuttering one.
/// - **The table is driven by a diffable data source.** An arriving batch
///   appends or reconfigures the rows it touches; it never reloads the table,
///   which would rebuild every visible cell and unseat the scroll position.
final class ChatLensViewController: UIViewController {
    /// One row. Tool and diff rows are addressed by their event's upsert key so
    /// a later version of the same event replaces it **in place** — the client
    /// keeps first-seen order, which is what stops a tool card from jumping to
    /// the bottom of the transcript the moment it finishes.
    ///
    /// A reference type so the rendered text can be memoized on first display
    /// without copying the row back into the table's snapshot.
    private final class Row {
        enum Kind {
            case text(role: AgentEvent.Role, markdown: String, thinking: Bool)
            case tool(name: String, kind: AgentEvent.ToolKind, title: String,
                      subtitle: String?, status: AgentEvent.ToolStatus)
            case diff(path: String, unified: String)
            case plan(items: [AgentEvent.PlanItem])
            /// "Today", "Yesterday", "12 August" — the pill every messenger
            /// puts between two days of conversation.
            case day(String)
        }

        let id: String
        var kind: Kind
        /// The transcript's clock for this row, shown on prose and used to
        /// decide where a day boundary falls.
        var at: Date?
        /// True when the row above is the same speaker, which tightens the gap
        /// above this one. Grouping is what turns a list of bubbles into a
        /// conversation with a rhythm.
        var grouped = false
        /// A message this phone wrote that the transcript has not echoed back
        /// yet. Drawn dimmed, and replaced by the real event when it lands.
        var pending = false
        /// Memoized on first display. Cleared whenever `kind` changes, so an
        /// upserted tool card re-renders exactly once.
        var rendered: NSAttributedString?

        init(id: String, kind: Kind) {
            self.id = id
            self.kind = kind
        }
    }

    private var rowsByID: [String: Row] = [:]
    /// The highest `seq` applied. Handed back on reconnect so the Mac replays
    /// only the gap.
    private(set) var cursor = 0

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    /// Shown only for a dormant session. Worth its own row rather than a
    /// navigation prompt: "there is no process behind this, and you are reading
    /// it anyway" is the one thing this view does that the terminal cannot, so
    /// it should not be a subtitle the eye skips.
    private let dormantBanner = UILabel()
    private var dataSource: UITableViewDiffableDataSource<Int, String>?

    /// Called when the view wants events from `since`. Set by the presenter so
    /// this controller never owns a transport.
    var onNeedEvents: ((Int) -> Void)?
    /// Back to the session list.
    var onRequestBack: (() -> Void)?
    /// Switch this session to its terminal.
    var onRequestTerminal: (() -> Void)?
    /// Submit what the user typed to the agent.
    var onSend: ((String) -> Void)?

    /// Where you are, above the title — the same two-line header the terminal
    /// draws, because the two views are one session and swapping between them
    /// should not move the chrome.
    var context: String? {
        didSet {
            contextLabel.text = context
            contextLabel.isHidden = context?.isEmpty ?? true
        }
    }
    override var title: String? {
        didSet { titleLabel.text = title }
    }

    /// What the session is doing right now, in the line under the title —
    /// Telegram's "typing…" slot, filled from the same agent status the
    /// session list shows. It replaces the project · branch line while the
    /// agent is busy or blocked, and yields back when there is nothing to say.
    var activity: SessionStatus = .idle {
        didSet {
            guard activity != oldValue else { return }
            switch activity {
            case .working: contextLabel.text = localized("working…")
            case .needsAttention: contextLabel.text = localized("waiting for you")
            case .idle, .done: contextLabel.text = context
            }
            contextLabel.textColor = activity == .needsAttention ? .systemOrange : .secondaryLabel
            contextLabel.isHidden = contextLabel.text?.isEmpty ?? true
            // Liveness has two sources — the header event, sent once when the
            // subscription opened, and this status, which is current. An agent
            // that is working is by definition running, so the banner cannot
            // keep claiming otherwise.
            if activity == .working || activity == .needsAttention { showDormantBanner(false) }
        }
    }

    private let headerBar = UIStackView()
    private let titleLabel = UILabel()
    private let contextLabel = UILabel()
    private lazy var composer = ChatComposerView()
    /// Numbers the local echoes, so two identical messages stay two rows.
    private var pendingCount = 0
    /// The day and speaker of the last row appended, for separators and
    /// grouping. Both follow append order, which is conversation order.
    private var lastDayKey: String?
    private var lastRole: AgentEvent.Role?
    /// Jumps back to the newest message. Hidden while already at the bottom —
    /// a control that is always visible over a conversation reads as chrome.
    private let jumpButton = UIButton(type: .system)
    private let sendFeedback = UIImpactFeedbackGenerator(style: .light)
    /// Measured row heights, fed back as estimates. Self-sizing cells with one
    /// fixed estimate make a long conversation lurch while scrolling: every
    /// row that turns out taller than the guess shifts everything below it.
    private var heights: [String: CGFloat] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        tableView.separatorStyle = .none
        tableView.allowsSelection = false
        tableView.estimatedRowHeight = 64
        tableView.rowHeight = UITableView.automaticDimension
        tableView.keyboardDismissMode = .interactive
        tableView.register(ChatTextCell.self, forCellReuseIdentifier: ChatTextCell.reuseID)
        tableView.register(ChatToolCell.self, forCellReuseIdentifier: ChatToolCell.reuseID)
        tableView.register(ChatDiffCell.self, forCellReuseIdentifier: ChatDiffCell.reuseID)
        tableView.register(ChatPlanCell.self, forCellReuseIdentifier: ChatPlanCell.reuseID)
        tableView.register(ChatDayCell.self, forCellReuseIdentifier: ChatDayCell.reuseID)
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        dataSource = UITableViewDiffableDataSource<Int, String>(tableView: tableView) {
            [weak self] table, indexPath, identifier in
            guard let self, let row = self.rowsByID[identifier] else { return UITableViewCell() }
            return self.cell(for: row, in: table, at: indexPath)
        }
        // Arrivals rise from the bottom edge, the way a message does in every
        // messenger; a fade reads as content changing rather than arriving.
        dataSource?.defaultRowAnimation = .bottom

        emptyLabel.text = localized("No conversation yet.")
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .subheadline)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        dormantBanner.font = UIFontMetrics(forTextStyle: .caption1)
            .scaledFont(for: .systemFont(ofSize: 12, weight: .medium))
        dormantBanner.adjustsFontForContentSizeCategory = true
        dormantBanner.textColor = .secondaryLabel
        dormantBanner.textAlignment = .center
        dormantBanner.backgroundColor = .secondarySystemBackground
        dormantBanner.isHidden = true
        dormantBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dormantBanner)

        configureHeader()

        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.onSend = { [weak self] text in self?.submit(text) }
        view.addSubview(composer)

        jumpButton.applyGlassSymbol("chevron.down", pointSize: 15)
        jumpButton.accessibilityIdentifier = "chat.jump"
        jumpButton.accessibilityLabel = localized("Scroll to Latest")
        jumpButton.tintColor = .label
        jumpButton.alpha = 0
        jumpButton.addAction(
            UIAction { [weak self] _ in self?.scrollToBottom(animated: true) }, for: .touchUpInside)
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(jumpButton)

        bannerHeight = dormantBanner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            dormantBanner.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 4),
            dormantBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dormantBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bannerHeight,
            tableView.topAnchor.constraint(equalTo: dormantBanner.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Runs to the bottom edge and clears the floating bar with a content
            // inset instead of stopping at it, so the transcript passes behind
            // the pill rather than being cut off by an invisible wall.
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The bar's fill runs to the screen edge so nothing shows through
            // beneath it; the pill inside is what rides the keyboard. The guide
            // collapses to the safe area when the keyboard is down, so one
            // constraint covers both states and tracks an interactive dismissal
            // frame by frame.
            composer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composer.pillBottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),

            jumpButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            jumpButton.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -12),
            jumpButton.widthAnchor.constraint(equalToConstant: 38),
            jumpButton.heightAnchor.constraint(equalToConstant: 38),
        ])

        onNeedEvents?(cursor)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The composer rides the keyboard, so how much of the table it covers
        // changes frame by frame during an interactive dismissal — the inset is
        // read from its actual frame rather than assumed.
        let covered = max(0, view.bounds.maxY - composer.frame.minY)
        guard abs(tableView.contentInset.bottom - covered) > 0.5 else { return }
        tableView.contentInset.bottom = covered
        tableView.verticalScrollIndicatorInsets.bottom = covered
    }

    /// The session's chrome: back chevron to the list, the two-line title
    /// centered, and the one control that matters here — the switch to the
    /// terminal. Deliberately the terminal's own header, because a session that
    /// changed its bar when you switched views would read as two screens
    /// instead of two views of one conversation.
    private func configureHeader() {
        contextLabel.font = .preferredFont(forTextStyle: .caption2)
        contextLabel.textColor = .secondaryLabel
        contextLabel.textAlignment = .center
        // Whatever the presenter set before this view loaded.
        contextLabel.text = context
        contextLabel.isHidden = context?.isEmpty ?? true
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        let titles = UIStackView(arrangedSubviews: [contextLabel, titleLabel])
        titles.axis = .vertical
        titles.alignment = .fill

        let back = UIButton(type: .system)
        back.applyGlassSymbol("chevron.left", pointSize: 18)
        back.accessibilityIdentifier = "chat.back"
        back.tintColor = .label
        back.addAction(UIAction { [weak self] _ in self?.onRequestBack?() }, for: .touchUpInside)

        let terminal = UIButton(type: .system)
        terminal.applyGlassSymbol("apple.terminal", pointSize: 16)
        terminal.accessibilityIdentifier = "chat.terminal"
        terminal.accessibilityLabel = localized("Terminal")
        terminal.tintColor = .label
        terminal.addAction(UIAction { [weak self] _ in self?.onRequestTerminal?() }, for: .touchUpInside)

        headerBar.axis = .horizontal
        headerBar.alignment = .center
        headerBar.spacing = 4
        headerBar.addArrangedSubview(back)
        headerBar.addArrangedSubview(titles)
        headerBar.addArrangedSubview(terminal)
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)
        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            back.widthAnchor.constraint(equalToConstant: 44),
            back.heightAnchor.constraint(equalToConstant: 44),
            terminal.widthAnchor.constraint(equalToConstant: 44),
            terminal.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private var bannerHeight = NSLayoutConstraint()

    private func showDormantBanner(_ shown: Bool) {
        dormantBanner.isHidden = !shown
        bannerHeight.constant = shown ? 26 : 0
    }

    /// Send what was typed, and show it immediately.
    ///
    /// The message is not confirmed until the agent's transcript records the
    /// turn, which is a second or so away — a chat that showed nothing until
    /// then would read as having swallowed it. So the row goes up dimmed and is
    /// replaced by the real event when it arrives (`reconcilePendingRow`).
    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let dataSource else { return }
        onSend?(trimmed)

        pendingCount += 1
        let identifier = "pending:\(pendingCount)"
        var snapshot = dataSource.snapshot()
        if snapshot.numberOfSections == 0 { snapshot.appendSections([0]) }
        // The separator first: it clears the grouping run, so asking it after
        // would group this message under yesterday's last one.
        let sentAt = Date()
        if let separator = daySeparator(before: sentAt) {
            rowsByID[separator.id] = separator
            snapshot.appendItems([separator.id], toSection: 0)
        }

        let row = Row(id: identifier, kind: .text(role: .user, markdown: trimmed, thinking: false))
        row.pending = true
        row.at = sentAt
        row.grouped = lastRole == .user
        lastRole = .user
        rowsByID[identifier] = row
        snapshot.appendItems([identifier], toSection: 0)
        sendFeedback.impactOccurred()
        emptyLabel.isHidden = true
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            self?.scrollToBottom()
        }
    }

    /// Drops the local echo an arriving user event stands in for. Matching on
    /// text rather than an id is what the transcript allows: the agent's record
    /// of the turn carries no reference to the keystrokes that produced it.
    private func reconcilePendingRow(matching text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return rowsByID.first { _, row in
            guard row.pending, case .text(_, let markdown, _) = row.kind else { return false }
            return markdown == trimmed
        }?.key
    }

    /// Folds a batch into the view. Safe to call with events already applied:
    /// an upsert-keyed event replaces its earlier version and a stale `seq` is
    /// ignored, so a duplicate batch after a reconnect is a no-op.
    func apply(_ events: [AgentEvent]) {
        guard !events.isEmpty, let dataSource else { return }
        var snapshot = dataSource.snapshot()
        if snapshot.numberOfSections == 0 { snapshot.appendSections([0]) }

        var appended = false
        var reconfigured: [String] = []

        for event in events {
            switch event.payload {
            case .sessionInfo(let sessionTitle, _, let state):
                if title?.isEmpty ?? true { title = sessionTitle }
                dormantBanner.text = localized("Not running — showing saved history")
                showDormantBanner(state == .dormant && activity != .working)
                continue
            case .turnStart, .turnEnd, .usage:
                // Nothing to draw yet. Turn boundaries earn their keep when the
                // composer lands and needs to know a turn is in flight.
                continue
            default:
                break
            }

            guard event.seq > cursor || event.upsertKey != nil else { continue }
            cursor = max(cursor, event.seq)

            let kind: Row.Kind
            switch event.payload {
            case .text(let text, let thinking):
                kind = .text(role: event.role, markdown: text, thinking: thinking)
            case .tool(_, let name, let toolKind, let title, let subtitle, let status, _):
                kind = .tool(
                    name: name, kind: toolKind, title: title, subtitle: subtitle, status: status)
            case .diff(_, let path, let unified):
                kind = .diff(path: path, unified: unified)
            case .plan(let planItems):
                kind = .plan(items: planItems)
            default:
                continue
            }

            // The transcript caught up with something this phone sent: the real
            // event takes the local echo's place rather than sitting under it.
            // The echo's clock is inherited when the event has none, so a
            // confirmed message never loses the time it was sent at.
            var inheritedClock: Date?
            if case .text(let text, false) = event.payload, event.role == .user,
                let echo = reconcilePendingRow(matching: text) {
                inheritedClock = rowsByID.removeValue(forKey: echo)?.at
                snapshot.deleteItems([echo])
            }

            let identifier = event.upsertKey ?? "seq:\(event.seq)"
            if let existing = rowsByID[identifier] {
                existing.kind = kind
                existing.rendered = nil
                heights[identifier] = nil
                reconfigured.append(identifier)
            } else {
                let clock = event.at ?? inheritedClock
                if let separator = daySeparator(before: clock) {
                    rowsByID[separator.id] = separator
                    snapshot.appendItems([separator.id], toSection: 0)
                }
                let row = Row(id: identifier, kind: kind)
                row.at = clock
                if case .text = kind {
                    row.grouped = lastRole == event.role
                    lastRole = event.role
                } else {
                    lastRole = nil
                }
                rowsByID[identifier] = row
                snapshot.appendItems([identifier], toSection: 0)
                appended = true
            }
        }

        emptyLabel.isHidden = !rowsByID.isEmpty
        if !reconfigured.isEmpty {
            // reconfigure, not reload: the cell keeps its identity and its
            // place, so an in-flight tool card updating cannot scroll the view.
            snapshot.reconfigureItems(reconfigured.filter { snapshot.itemIdentifiers.contains($0) })
        }
        guard appended || !reconfigured.isEmpty else { return }

        let shouldStickToBottom = appended && isNearBottom
        // A live message slides in; a cold replay of hundreds does not — an
        // animated diff over a whole conversation is a visible stall, and
        // nobody is watching the moment it lands anyway.
        let arrived = snapshot.numberOfItems - dataSource.snapshot().numberOfItems
        let animates = appended && arrived <= 3 && view.window != nil
        dataSource.apply(snapshot, animatingDifferences: animates) { [weak self] in
            guard shouldStickToBottom else { return }
            self?.scrollToBottom(animated: animates)
        }
    }

    /// The text a long press copies: the message, the command, or the diff —
    /// whatever that row is actually made of. A day pill has nothing to copy.
    private func copyableText(of identifier: String) -> String? {
        guard let row = rowsByID[identifier] else { return nil }
        switch row.kind {
        case .text(_, let markdown, _): return markdown
        case .tool(_, _, let title, _, _): return title
        case .diff(let path, let unified): return "\(path)\n\(unified)"
        case .plan(let items): return items.map { "- \($0.text)" }.joined(separator: "\n")
        case .day: return nil
        }
    }

    /// A pill row when the day changes, and nothing otherwise. Rows without a
    /// timestamp inherit the current day rather than forcing a break: a
    /// separator that appeared because one event lacked a clock would be worse
    /// than no separator at all.
    private func daySeparator(before date: Date?) -> Row? {
        guard let date else { return nil }
        let key = Self.dayKey.string(from: date)
        guard key != lastDayKey else { return nil }
        lastDayKey = key
        // Grouping never spans a day break.
        lastRole = nil
        return Row(id: "day:\(key)", kind: .day(Self.dayLabel(for: date)))
    }

    private static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dayName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMMM")
        return formatter
    }()

    static let timeOfDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return localized("Today") }
        if calendar.isDateInYesterday(date) { return localized("Yesterday") }
        return dayName.string(from: date)
    }

    /// Only follow new output when the reader is already at the end — yanking
    /// someone back down while they are reading earlier output is the single
    /// most irritating thing a live transcript can do.
    private var isNearBottom: Bool {
        let offset = tableView.contentOffset.y + tableView.bounds.height
        return offset >= tableView.contentSize.height - 120
    }

    private func scrollToBottom(animated: Bool = false) {
        guard let count = dataSource?.snapshot().numberOfItems, count > 0 else { return }
        tableView.scrollToRow(
            at: IndexPath(row: count - 1, section: 0), at: .bottom, animated: animated)
        updateJumpButton()
    }

    /// The jump control fades rather than pops: it appears while the reader is
    /// scrolling, and a control that materializes mid-gesture is the kind of
    /// motion that reads as a glitch.
    private func updateJumpButton() {
        let wanted: CGFloat = isNearBottom ? 0 : 1
        guard jumpButton.alpha != wanted else { return }
        UIView.animate(withDuration: 0.2) { self.jumpButton.alpha = wanted }
    }

    private func cell(for row: Row, in table: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        switch row.kind {
        case .text(let role, let markdown, let thinking):
            let cell =
                table.dequeueReusableCell(withIdentifier: ChatTextCell.reuseID, for: indexPath)
                as? ChatTextCell ?? ChatTextCell()
            if row.rendered == nil {
                var style = MarkdownAttributedText.Style()
                if thinking { style.textColor = .secondaryLabel }
                row.rendered = MarkdownAttributedText.render(markdown, style: style)
            }
            cell.configure(
                role: role, text: row.rendered, thinking: thinking, pending: row.pending,
                time: row.at.map(Self.timeOfDay.string(from:)), grouped: row.grouped)
            return cell
        case .tool(let name, let kind, let title, let subtitle, let status):
            let cell =
                table.dequeueReusableCell(withIdentifier: ChatToolCell.reuseID, for: indexPath)
                as? ChatToolCell ?? ChatToolCell()
            cell.configure(name: name, kind: kind, title: title, subtitle: subtitle, status: status)
            return cell
        case .diff(let path, let unified):
            let cell =
                table.dequeueReusableCell(withIdentifier: ChatDiffCell.reuseID, for: indexPath)
                as? ChatDiffCell ?? ChatDiffCell()
            if row.rendered == nil { row.rendered = ChatDiffCell.render(unified) }
            cell.configure(path: path, body: row.rendered)
            return cell
        case .plan(let planItems):
            let cell =
                table.dequeueReusableCell(withIdentifier: ChatPlanCell.reuseID, for: indexPath)
                as? ChatPlanCell ?? ChatPlanCell()
            cell.configure(items: planItems)
            return cell
        case .day(let label):
            let cell =
                table.dequeueReusableCell(withIdentifier: ChatDayCell.reuseID, for: indexPath)
                as? ChatDayCell ?? ChatDayCell()
            cell.configure(label)
            return cell
        }
    }
}

// MARK: - Scrolling and message actions

extension ChatLensViewController: UITableViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateJumpButton()
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell,
                   forRowAt indexPath: IndexPath) {
        guard let identifier = dataSource?.itemIdentifier(for: indexPath) else { return }
        heights[identifier] = cell.bounds.height
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let identifier = dataSource?.itemIdentifier(for: indexPath) else { return 64 }
        return heights[identifier] ?? 64
    }

    /// Long press to copy — the one message action worth having before replies
    /// and reactions exist, and the one people reach for on a phone when the
    /// text is a path or a command they want on the Mac.
    func tableView(
        _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let identifier = dataSource?.itemIdentifier(for: indexPath),
            let text = copyableText(of: identifier)
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: localized("Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = text
                }
            ])
        }
    }
}


// MARK: - Cells

/// Prose. The asymmetry is deliberate and matches what every phone client of a
/// long-form assistant converges on: what the human typed is short and gets a
/// bubble; what the agent wrote is long, contains code, and gets the full
/// column. Bubbling agent output would cost ~20% of the width that its code
/// blocks need most.
private final class ChatTextCell: UITableViewCell {
    static let reuseID = "text"

    private let bubble = UIView()
    private let body = UITextView()
    private let caption = UILabel()
    private let time = UILabel()
    /// Adjusted per configure: a message under the same speaker sits closer to
    /// it than to a change of speaker.
    private var topSpacing = NSLayoutConstraint()
    /// The cell's bottom is owned by the bubble or by the time label, never
    /// both — two required constraints to the same edge is how a stamp ends up
    /// silently collapsed to nothing.
    private var bubbleClosesCell = NSLayoutConstraint()
    private var timeClosesCell = NSLayoutConstraint()
    /// Both layouts are built once and toggled. Rebuilding constraints on every
    /// configure is a per-scroll cost for a decision that only has two answers.
    private var userLayout: [NSLayoutConstraint] = []
    private var agentLayout: [NSLayoutConstraint] = []
    private var bubbleInsets: [NSLayoutConstraint] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        body.isEditable = false
        body.isScrollEnabled = false
        body.backgroundColor = .clear
        body.textContainerInset = .zero
        body.textContainer.lineFragmentPadding = 0
        body.dataDetectorTypes = [.link]
        body.adjustsFontForContentSizeCategory = true
        body.translatesAutoresizingMaskIntoConstraints = false

        caption.font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .systemFont(ofSize: 11, weight: .medium))
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = .secondaryLabel
        caption.translatesAutoresizingMaskIntoConstraints = false

        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false

        time.font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .systemFont(ofSize: 10))
        time.adjustsFontForContentSizeCategory = true
        time.textColor = .tertiaryLabel
        time.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(bubble)
        contentView.addSubview(caption)
        contentView.addSubview(time)
        bubble.addSubview(body)

        let top = body.topAnchor.constraint(equalTo: bubble.topAnchor)
        let bottom = body.bottomAnchor.constraint(equalTo: bubble.bottomAnchor)
        let leading = body.leadingAnchor.constraint(equalTo: bubble.leadingAnchor)
        let trailing = body.trailingAnchor.constraint(equalTo: bubble.trailingAnchor)
        bubbleInsets = [top, bottom, leading, trailing]

        topSpacing = caption.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10)
        bubbleClosesCell = bubble.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor, constant: -4)
        timeClosesCell = time.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor, constant: -4)
        NSLayoutConstraint.activate([
            topSpacing,
            caption.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            bubble.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 2),
            bubbleClosesCell,
            bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            top, bottom, leading, trailing,

            time.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -2),
            time.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 2),
        ])

        userLayout = [
            bubble.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentView.leadingAnchor, constant: 60)
        ]
        agentLayout = [
            bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        ]
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        role: AgentEvent.Role, text: NSAttributedString?, thinking: Bool, pending: Bool = false,
        time stamp: String? = nil, grouped: Bool = false
    ) {
        let isUser = role == .user && !thinking
        caption.text = thinking ? localized("Thinking") : nil
        caption.isHidden = !thinking
        body.attributedText = text
        // A clock on every line is noise; the user's own messages are the ones
        // people scan for ("when did I ask for that?"), so only those carry it.
        let showsTime = isUser && stamp != nil
        time.text = stamp
        time.isHidden = !showsTime
        bubbleClosesCell.isActive = !showsTime
        timeClosesCell.isActive = showsTime
        topSpacing.constant = grouped ? 2 : 10
        // Dimmed until the transcript confirms it — the same "sent, not yet
        // acknowledged" grammar every messenger uses.
        contentView.alpha = pending ? 0.45 : 1

        // The one thing on the page that is *yours* sits highest in the fill
        // ladder; everything the agent produced sits below it. Same family, so
        // the page still reads as one material in both light and dark.
        bubble.backgroundColor = isUser ? .secondarySystemFill : .clear
        let inset: CGFloat = isUser ? 12 : 0
        bubbleInsets[0].constant = inset
        bubbleInsets[1].constant = -inset
        bubbleInsets[2].constant = inset
        bubbleInsets[3].constant = -inset

        NSLayoutConstraint.deactivate(isUser ? agentLayout : userLayout)
        NSLayoutConstraint.activate(isUser ? userLayout : agentLayout)

        accessibilityLabel = text?.string
    }
}

/// A tool call. One row, because on a phone the useful information is *which*
/// tool touched *what* and whether it worked — the output itself is usually
/// hundreds of lines and belongs behind a tap, not in the scroll.
private final class ChatToolCell: UITableViewCell {
    static let reuseID = "tool"

    private let card = UIView()
    private let icon = UIImageView()
    private let title = UILabel()
    private let subtitle = UILabel()
    private let statusIcon = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = .tertiarySystemFill
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        title.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .label
        title.numberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        subtitle.font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .systemFont(ofSize: 11))
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 1
        subtitle.lineBreakMode = .byTruncatingHead
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        statusIcon.contentMode = .scaleAspectFit
        statusIcon.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(card)
        [icon, title, subtitle, statusIcon].forEach(card.addSubview)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: statusIcon.leadingAnchor, constant: -10),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),

            statusIcon.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            statusIcon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 14),
            statusIcon.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        name: String, kind: AgentEvent.ToolKind, title toolTitle: String,
        subtitle toolSubtitle: String?, status: AgentEvent.ToolStatus
    ) {
        icon.image = UIImage(systemName: Self.symbol(for: kind))
        title.text = toolTitle
        subtitle.text = toolSubtitle ?? name

        let statusDescription: String
        switch status {
        case .pending, .running:
            statusIcon.image = UIImage(systemName: "circle.dotted")
            statusIcon.tintColor = .tertiaryLabel
            statusDescription = localized("running")
        case .done:
            statusIcon.image = UIImage(systemName: "checkmark")
            statusIcon.tintColor = .systemGreen
            statusDescription = localized("finished")
        case .error:
            statusIcon.image = UIImage(systemName: "xmark")
            statusIcon.tintColor = .systemRed
            statusDescription = localized("failed")
        }

        isAccessibilityElement = true
        accessibilityLabel = "\(name), \(toolTitle), \(statusDescription)"
    }

    private static func symbol(for kind: AgentEvent.ToolKind) -> String {
        switch kind {
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .execute: return "terminal"
        case .search: return "magnifyingglass"
        case .think: return "sparkles"
        case .fetch: return "globe"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

/// A diff, parsed with the same `DiffParser` the Mac's git pane uses so the
/// phone never learns a second diff shape. Long hunks are capped: a 900-line
/// edit is not something anyone reads inside a chat scroll.
private final class ChatDiffCell: UITableViewCell {
    static let reuseID = "diff"
    /// Counted in *logical* diff lines, but the budget is set by visual ones: at
    /// phone width a line of prose wraps to three or four rows, so 40 logical
    /// lines is a screen-and-a-half of solid colour. A diff here is a preview
    /// that says which file changed and roughly how — the full hunk belongs
    /// behind a tap.
    private static let maximumLines = 14

    private let card = UIView()
    private let pathLabel = UILabel()
    private let bodyLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = .tertiarySystemFill
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .systemFont(ofSize: 11, weight: .medium))
        pathLabel.adjustsFontForContentSizeCategory = true
        pathLabel.textColor = .secondaryLabel
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        bodyLabel.numberOfLines = 0
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(card)
        card.addSubview(pathLabel)
        card.addSubview(bodyLabel)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            pathLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            pathLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            pathLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            bodyLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 6),
            bodyLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            bodyLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            bodyLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(path: String, body: NSAttributedString?) {
        pathLabel.text = (path as NSString).lastPathComponent
        bodyLabel.attributedText = body
    }

    /// Built once per row and cached by the caller — the parse plus per-line
    /// attribute runs are far too much work to repeat on every dequeue.
    static func render(_ unified: String) -> NSAttributedString {
        let font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .monospacedSystemFont(ofSize: 11, weight: .regular))
        let rendered = NSMutableAttributedString()
        var shown = 0
        var hidden = 0

        for line in DiffParser.lines(from: unified) where line.kind != .hunk {
            guard shown < maximumLines else {
                hidden += 1
                continue
            }
            shown += 1
            // `DiffLine.text` has its marker stripped so renderers can style it
            // separately; here the marker goes back inline, which is what reads
            // at phone width without a gutter column.
            let marker: String
            let color: UIColor
            let background: UIColor
            switch line.kind {
            case .addition:
                marker = "+"
                color = .systemGreen
                background = UIColor.systemGreen.withAlphaComponent(0.12)
            case .deletion:
                marker = "-"
                color = .systemRed
                background = UIColor.systemRed.withAlphaComponent(0.12)
            default:
                marker = " "
                color = .secondaryLabel
                background = .clear
            }
            rendered.append(
                NSAttributedString(
                    string: marker + line.text + "\n",
                    attributes: [.font: font, .foregroundColor: color, .backgroundColor: background]))
        }
        if hidden > 0 {
            rendered.append(
                NSAttributedString(
                    string: localized("+\(hidden) more lines"),
                    attributes: [
                        .font: UIFont.preferredFont(forTextStyle: .caption2),
                        .foregroundColor: UIColor.tertiaryLabel,
                    ]))
        }
        return rendered
    }
}

/// The agent's plan as a real checklist. In the terminal this is a box the TUI
/// redraws in place, which on a phone means it scrolls past as a dozen stale
/// copies; here the same event upserts onto one row.
private final class ChatPlanCell: UITableViewCell {
    static let reuseID = "plan"

    private let card = UIView()
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = .tertiarySystemFill
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(card)
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    func configure(items: [AgentEvent.PlanItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .firstBaseline

            let mark = UIImageView()
            mark.contentMode = .scaleAspectFit
            switch item.status {
            case .completed:
                mark.image = UIImage(systemName: "checkmark.circle.fill")
                mark.tintColor = .systemGreen
            case .inProgress:
                mark.image = UIImage(systemName: "circle.dashed.inset.filled")
                mark.tintColor = .systemBlue
            case .pending:
                mark.image = UIImage(systemName: "circle")
                mark.tintColor = .tertiaryLabel
            }
            mark.setContentHuggingPriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                mark.widthAnchor.constraint(equalToConstant: 14),
                mark.heightAnchor.constraint(equalToConstant: 14),
            ])

            let label = UILabel()
            label.text = item.text
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.textColor = item.status == .completed ? .secondaryLabel : .label

            row.addArrangedSubview(mark)
            row.addArrangedSubview(label)
            stack.addArrangedSubview(row)
        }
    }
}

// MARK: - Composer

/// The input bar. What you type here is bracketed-pasted into the session's
/// PTY and submitted — the same bytes the Mac sends when you type at the
/// terminal, because there is no second way in: the agent is a program on a
/// terminal, not an API.
///
/// Return inserts a newline and the button sends, which is the iOS messenger
/// convention and the right one here: agent prompts are routinely several
/// lines, and a Return that submitted would cut most of them in half.
final class ChatComposerView: UIView, UITextViewDelegate {
    var onSend: ((String) -> Void)?

    private let pill = UIView()
    private let field = UITextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let maximumHeight: CGFloat = 132
    private let restingHeight: CGFloat = 44
    private var fieldHeight = NSLayoutConstraint()
    /// Text inset inside the pill. The placeholder is a sibling of the field
    /// rather than its text, so it has to be positioned to the same origin.
    private static let textInset = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 6)

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The page's own color and no rule across the top: the bar reads as the
        // bottom of the page with a control resting on it, rather than a slab
        // announced by a hairline. It has to be opaque — the transcript scrolls
        // behind it, and a transparent bar lets half a line of code show through
        // the gaps around the pill.
        backgroundColor = .systemBackground

        pill.backgroundColor = .tertiarySystemFill
        pill.layer.cornerCurve = .continuous
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)

        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.isScrollEnabled = false
        field.backgroundColor = .clear
        field.textContainerInset = Self.textInset
        field.textContainer.lineFragmentPadding = 0
        field.delegate = self
        field.accessibilityIdentifier = "chat.composer"
        field.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(field)

        placeholder.text = localized("Message")
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .tertiaryLabel
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(placeholder)

        // A plain filled circle, not a glass button: this one rides inside the
        // pill, and glass is for controls floating free over content.
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "arrow.up")
        config.preferredSymbolConfigurationForImage = .init(pointSize: 15, weight: .semibold)
        config.background.cornerRadius = 16
        sendButton.configuration = config
        sendButton.configurationUpdateHandler = { button in
            // Neutral, never accent-filled: enablement shows in the glyph and
            // the chip, the way the rest of the app's controls read.
            button.configuration?.background.backgroundColor =
                button.isEnabled ? .tertiarySystemFill : .clear
            button.configuration?.baseForegroundColor =
                button.isEnabled ? .label : .quaternaryLabel
        }
        sendButton.accessibilityIdentifier = "chat.send"
        sendButton.accessibilityLabel = localized("Send")
        sendButton.isEnabled = false
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(sendButton)

        fieldHeight = field.heightAnchor.constraint(equalToConstant: restingHeight)
        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            field.topAnchor.constraint(equalTo: pill.topAnchor),
            field.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor),
            fieldHeight,

            placeholder.leadingAnchor.constraint(
                equalTo: field.leadingAnchor, constant: Self.textInset.left),
            placeholder.topAnchor.constraint(
                equalTo: field.topAnchor, constant: Self.textInset.top),

            // Pinned to the bottom, so a prompt that grows to several lines
            // keeps its send key under the thumb instead of drifting upward.
            sendButton.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
            sendButton.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -6),
            sendButton.widthAnchor.constraint(equalToConstant: 32),
            sendButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The pill's bottom edge. The owner rides this on the keyboard while the
    /// bar's fill runs all the way to the screen edge — without that split, the
    /// transcript shows through the home-indicator strip under the pill.
    var pillBottomAnchor: NSLayoutYAxisAnchor { pill.bottomAnchor }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A capsule while it holds one line; once the prompt grows past two, a
        // half-height radius would bow the sides into a lozenge, so it settles
        // into a rounded rectangle instead.
        pill.layer.cornerRadius = min(pill.bounds.height / 2, 24)
    }

    private func send() {
        let text = field.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        field.text = ""
        textViewDidChange(field)
        onSend?(text)
    }

    func textViewDidChange(_ textView: UITextView) {
        let empty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !textView.text.isEmpty
        sendButton.isEnabled = !empty
        // Grow with the text up to a few lines, then scroll inside the field.
        let fitted = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        let clamped = min(max(fitted, restingHeight), maximumHeight)
        guard abs(clamped - fieldHeight.constant) > 0.5 else { return }
        fieldHeight.constant = clamped
        textView.isScrollEnabled = fitted > maximumHeight
    }
}


/// The day pill between two days of conversation. Centered, capsule, dimmed —
/// the shape every messenger converged on, because it has to be legible while
/// being ignorable.
private final class ChatDayCell: UITableViewCell {
    static let reuseID = "day"

    private let pill = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        pill.font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .systemFont(ofSize: 11, weight: .semibold))
        pill.adjustsFontForContentSizeCategory = true
        pill.textColor = .secondaryLabel
        pill.textAlignment = .center
        pill.backgroundColor = .tertiarySystemFill
        pill.layer.cornerRadius = 11
        pill.layer.cornerCurve = .continuous
        pill.clipsToBounds = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pill)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            pill.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            pill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            pill.heightAnchor.constraint(equalToConstant: 22),
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 74),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ label: String) {
        pill.text = "  \(label)  "
        accessibilityLabel = label
    }
}
