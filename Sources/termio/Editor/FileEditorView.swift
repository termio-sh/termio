import AppKit
import SwiftUI

/// The editor that covers the terminal pane: a soft-wrapped, monospaced `NSTextView` whose text is
/// syntax-highlighted by Highlightr (highlight.js), with a slim fixed header (the file name, pinned
/// like the inspector panes' headers) over the scrolling content. The
/// file is read once on open and **auto-saved** — a short idle after the last keystroke flushes it to
/// disk, and closing flushes any pending write — so there is no Save button (⌘S still forces an
/// immediate flush for muscle memory). It closes three ways: the toolbar close button, a right-click
/// "Close" (terminal-style), or Escape — all dismiss back to the terminal.
/// Non-text files that can't be decoded as UTF-8 show a short notice rather than a wall of mojibake.
struct FileEditorView: View {
    let url: URL
    @ObservedObject var settings: AppSettings
    /// When true the buffer is shown but cannot be edited or saved — the cmd-click-from-terminal
    /// "peek at the source" path, so a stray click on a file link can't change it. The inspector's
    /// own opens leave this false (fully editable).
    let readOnly: Bool
    /// The 1-based line to scroll to and flash on open — a content-search hit. `nil` opens at the
    /// top as always. Changing it while the same file is open re-scrolls (clicking another hit).
    let jumpLine: Int?
    /// The original remote name when `url` is a randomized staged copy.
    let displayName: String?
    /// Where the buffer belongs when it belongs on another machine — `url` is
    /// then a staged copy on this Mac, and a save has to travel back. `nil` for
    /// a local file, where writing `url` *is* the save.
    ///
    /// A save over the network is not free the way a local write is, so a remote
    /// document is not auto-saved on the idle timer: ⌘S and closing are what
    /// send it. That difference is deliberate and is the one place the two kinds
    /// of document behave differently.
    let remote: RemoteDocument?
    /// Records the version a save produced, so the next one claims it rather
    /// than the version the file was opened at.
    let onRemoteSave: ((RemoteDocument) -> Void)?
    /// Reports whether the buffer has edits that are not on disk yet.
    ///
    /// Read by the remote open path: a device file shown from the cache is
    /// re-read behind it, and a reply that disagrees replaces the buffer — which
    /// it must never do to one somebody has started typing into. `isDirty` flips
    /// on the keystroke itself, well before the debounced write, so this closes
    /// the window the file's own bytes on disk cannot.
    let onDirtyChange: ((Bool) -> Void)?
    /// Dismisses the overlay (clears `store.openFileURL`) and hands focus back to the terminal.
    let onClose: () -> Void

    /// The right-click "Add to Chat" on both faces (editor and Markdown reader), supplied by the
    /// host rather than read out of the environment — the editor also opens from the Settings
    /// window, whose SwiftUI root is a separate `NSHostingView` with no store in scope. The
    /// argument is the selected text, `nil` for the whole document (Cursor's split: selection →
    /// snippet, file → reference). Left nil where there is no session to send to; the menu item
    /// then never appears.
    let addToChat: ((String?) -> Void)?
    let canAddToChat: (() -> Bool)?

    /// Whether the header carries the inspector's window controls (hide list / maximize / close).
    /// A sheet has no list column to collapse and no inspector to fill, so it hosts the editor
    /// without them and supplies its own way out.
    let showsInspectorChrome: Bool

    @Environment(\.colorScheme) private var colorScheme

    /// Edit shows the Highlightr source editor; Preview renders the Markdown as a themed
    /// reading view. Only offered for Markdown files — everything else is edit-only.
    private enum Mode: Hashable { case edit, preview }
    /// Markdown opens in Preview (a doc you mostly read); source stays one click away.
    @State private var mode: Mode
    /// Slides the mode toggle's glass pill between Edit and Preview.
    @Namespace private var modePillNamespace

    @State private var text = ""
    /// The text last written to disk, so auto-save only writes on a genuine change.
    @State private var savedText = ""
    /// False until the async load lands — the editor mounts only then, so the
    /// highlighter and the jump-to-line both see the real document, never the
    /// empty placeholder.
    @State private var loaded = false
    @State private var loadFailed = false
    /// Which faces have been visited. Both stay mounted afterwards (see `editorContent`), but
    /// neither is built before it is first asked for.
    @State private var mountedEditor = false
    @State private var mountedReader = false
    /// What the rendered face was last given — the buffer as of the flip into it, not the
    /// live one. While that face is visible it writes this and `text` together.
    @State private var previewSource = ""
    /// Reaches the rendered face's page so the flip out of it can pull the document
    /// before changing face. Filled in by the view when it mounts.
    @State private var readerBridge = MarkdownEditorHandle()
    /// A document the rendered face was handed, and the page's own serialization of that
    /// same document. The pair is the base an edit coming back out of that face is merged
    /// against, so the file keeps its own formatting — see `adoptRenderedFace`. Both are
    /// written together, by the page, because merging against a mismatched pair would
    /// rewrite lines nobody touched.
    @State private var renderedFaceOrigin = ""
    @State private var renderedFaceCanonical: String?
    /// Set when the file is too large for syntax highlighting (see `highlightByteLimit`).
    @State private var highlightDisabled = false
    @State private var saveError: String?
    /// The pending debounced write, cancelled and rescheduled on each keystroke.
    @State private var saveTask: Task<Void, Never>?
    /// The in-flight save to the device, so a second ⌘S doesn't start a race
    /// with the first.
    @State private var pushTask: Task<Void, Never>?
    @State private var pushing = false
    /// The device's own sentence when it refused a save because the file changed
    /// under us. Non-nil raises the overwrite question.
    @State private var conflict: String?
    @State private var findBarVisible = false
    @State private var findQuery = ""
    @State private var findOptions = FindOptions()
    @State private var findFocusedIndex = 0
    @State private var findMatchCount = 0
    /// The query at the last Return press. A second Return on the same query advances to the
    /// next match (VS Code / Safari convention).
    @State private var findLastSubmittedQuery = ""
    /// Bumped on every ⌘F so the find bar re-focuses even when already on screen.
    @State private var findFocusTrigger = 0
    /// What Replace puts in a match's place. Empty deletes the match, which is what an empty
    /// replacement field means everywhere else too.
    @State private var findReplacement = ""
    /// Replace edits the text view, not the `text` binding — see `FindReplaceController`.
    @State private var findReplace = FindReplaceController()

    /// Past this size the file renders as plain text: highlight.js parses off-main, but
    /// *applying* its result is thousands of main-thread `setAttributes` calls plus a
    /// whole-document relayout — seconds of beachball on a generated 600 KB YAML.
    private static let highlightByteLimit = 256 * 1024

    /// The highlight.js language id, sniffed once from the file extension. `nil` renders the file
    /// as plain text — the storage skips highlighting entirely without a language (there is no
    /// auto-detect pass). Stable for the lifetime of the open file.
    private let language: String?
    /// A synthetic URL carrying the original remote name for icons and
    /// extension/name-based language detection. File I/O always uses `url`.
    private let displayURL: URL
    /// The file's path relative to its git root — shown next to the name like the diff header
    /// (`GitDiffView`), so the two overlays read the same. `nil` outside a repo. Resolved in
    /// `load()` alongside the file read: the walk-up-for-`.git` is filesystem work, and this
    /// init re-runs on every parent render.
    @State private var relativePath: String?

    init(url: URL, settings: AppSettings, readOnly: Bool = false, jumpLine: Int? = nil,
         displayName: String? = nil,
         remote: RemoteDocument? = nil,
         onRemoteSave: ((RemoteDocument) -> Void)? = nil,
         onDirtyChange: ((Bool) -> Void)? = nil,
         addToChat: ((String?) -> Void)? = nil, canAddToChat: (() -> Bool)? = nil,
         showsInspectorChrome: Bool = true, onClose: @escaping () -> Void) {
        self.url = url
        self.settings = settings
        self.readOnly = readOnly
        self.jumpLine = jumpLine
        self.displayName = displayName
        self.remote = remote
        self.onRemoteSave = onRemoteSave
        self.onDirtyChange = onDirtyChange
        self.addToChat = addToChat
        self.canAddToChat = canAddToChat
        self.showsInspectorChrome = showsInspectorChrome
        self.onClose = onClose
        let displayURL = displayName.map {
            URL(fileURLWithPath: "/", isDirectory: true).appendingPathComponent($0)
        } ?? url
        self.displayURL = displayURL
        // No I/O here: SwiftUI re-runs this init on every parent render (the store's
        // session churn), and only the first init per `.id(url)` identity keeps its
        // state — filesystem work would hit the disk over and over just to be discarded.
        // The actual load (and the git-root walk) happens once, in `.task`.
        // A jump-to-line open (content-search hit, cmd-click) targets the *source*, so it
        // must land in Edit — Preview has no lines to jump to and would swallow the scroll.
        _mode = State(initialValue: Self.isMarkdown(displayURL) && jumpLine == nil ? .preview : .edit)
        self.language = Self.highlightLanguage(for: displayURL)
    }
    private var fileName: String { displayName ?? url.lastPathComponent }

    /// Markdown files get the Edit/Preview toggle; sniffed from the extension only (matching
    /// the `markdown` grammar in `highlightLanguage`).
    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdx"].contains(url.pathExtension.lowercased())
    }
    private var isMarkdown: Bool { Self.isMarkdown(displayURL) }

    private var isDirty: Bool { text != savedText }

    /// The editor font, borrowed from the terminal so an opened file reads in the same face the
    /// agent's output does. Falls back to the system monospace when no family is pinned.
    private var editorFont: NSFont {
        settings.resolvedTerminalFont()
    }

    /// Foreground/caret fall back to the terminal theme's colors (the rest of the chrome's source of
    /// truth) so plain text and the insertion point sit on the terminal background cleanly.
    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }
    /// Ink for text the highlighter has not colored, resolved like the gutter rather than through
    /// a system catalog color: `NSColor.textColor` tracks the *system* appearance, which is not
    /// the same thing as the terminal theme's foreground (a warm cream, a tinted grey) — the
    /// editor's plain text has to sit in the palette the pane behind it is drawn from.
    private var textColor: NSColor { settings.editorInk(for: colorScheme) }
    private var caretColor: NSColor { chrome.map { NSColor($0.accent) } ?? .textColor }
    /// Whether the editor sits on a dark background — the theme's own luminance signal, falling
    /// back to the system appearance when no theme is picked.
    private var onDarkBackground: Bool { chrome?.isDark ?? (colorScheme == .dark) }
    /// Muted line-number ink, shared with the diff gutter through `AppSettings.gutterInk`
    /// (background-contrast white/black, not theme-foreground-derived).
    private var lineNumberColor: NSColor { settings.gutterInk(for: colorScheme) }
    /// A whisper of ink under the caret's line — enough to anchor the eye, faint enough not to
    /// fight the syntax colors.
    private var currentLineColor: NSColor {
        ChromeTheme.overlayInk(onDark: onDarkBackground, alpha: onDarkBackground ? 0.06 : 0.05)
    }
    /// The wash on other occurrences of the word under the caret. A step above the current-line
    /// band so it reads as a mark, well below the find bar's yellow so a passive hint never looks
    /// like a result you searched for. Neutral ink rather than a tint, for the same reason the
    /// gutter is: a themed color sinks into some backgrounds at any alpha.
    private var occurrenceHighlightColor: NSColor {
        ChromeTheme.overlayInk(onDark: onDarkBackground, alpha: onDarkBackground ? 0.14 : 0.11)
    }
    /// The rules at each indent level, from the same overlay ink at the same weight as the
    /// occurrence wash: a one-point rule has a fraction of either wash's area to read from, so at
    /// the current-line band's alpha it would disappear into the background entirely.
    private var indentGuideColor: NSColor {
        ChromeTheme.overlayInk(onDark: onDarkBackground, alpha: onDarkBackground ? 0.14 : 0.11)
    }

    var body: some View {
        // The editor's chrome (header, gutter) already sits in the safe content area below the
        // toolbar — only the *background* bleeds up under the transparent titlebar, for a seamless
        // fill with the terminal. (No manual titlebar inset: the overlay's content top is already at
        // the safe-area top; padding it again just opened a dead band above the header.)
        Group {
            if loadFailed {
                PaneEmptyState(
                    localized("Can’t open as text"),
                    icon: .fileQuestion,
                    message: localized("\(fileName) isn’t a UTF-8 text file.")
                )
            } else if !loaded {
                // The bare background while the async read runs — small files land
                // within a frame or two, so a spinner would only flash.
                Color.clear
            } else {
                // A fixed header over the content (no divider, no footer), matching the inspector
                // panes' pinned headers (File Explorer's "TERMIO", Issues, Git) — the file name
                // stays put while you scroll rather than sliding away and leaving you place-blind.
                VStack(spacing: 0) {
                    header
                    editorContent
                }
            }
        }
        // Match the diff overlay (`GitDiffView`): a plain VStack whose background bleeds under the
        // titlebar — no outer `.frame`, which was reserving an empty band above the header.
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        .task { await load() }
        // Keyed to the load as well as the mode, because the mode is chosen in `init` — before
        // there is any text to render.
        .onChange(of: mode, initial: true) { activateMode() }
        .onChange(of: loaded) { activateMode() }
        .onReceive(NotificationCenter.default.publisher(for: .termioShowFindBar)) { _ in
            openFindBar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .termioFindNext)) { _ in
            guard findBarVisible else { return }
            advanceFind(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .termioFindPrevious)) { _ in
            guard findBarVisible else { return }
            advanceFind(by: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .termioUseSelectionForFind)) { _ in
            useSelectionForFind()
        }
        // Auto-save: debounce a write after each edit; Escape closes (flushing first). A read-only
        // peek never writes, so neither the debounce nor the exit flush is armed.
        .onChange(of: text) {
            if !readOnly { scheduleSave() }
        }
        // Both directions, and from the first render: a save clears the flag as
        // surely as a keystroke sets it, and the mount is what resets whatever
        // the previously open file left behind.
        .onChange(of: isDirty, initial: true) { onDirtyChange?(isDirty) }
        // A fresh jump target while a Markdown file sits in Preview (clicking another
        // content-search hit): the jump needs the source editor's lines, so flip to Edit
        // first — Preview has no text view to scroll and would swallow it.
        .onChange(of: jumpLine) {
            if jumpLine != nil, mode == .preview { requestModeChange(to: .edit) }
        }
        // Escape has two claimants once the rendered face can go full screen. The page's
        // overlay gets it first when it is up — its own listener has already closed it by
        // the time this runs, and consuming the claim here is what stops the same
        // keystroke also closing the whole editor.
        .onExitCommand {
            if readerBridge.consumeViewerEscape() { return }
            close()
        }
        .alert(
            localized("\(fileName) changed on \(remote?.host ?? "")"),
            isPresented: Binding(get: { conflict != nil },
                                 set: { if !$0 { conflict = nil } }),
            actions: { conflictAlert },
            message: {
                Text(localized(
                    "Somebody else wrote this file after you opened it. Overwriting replaces their version."))
            })
        // A safety flush if the overlay goes away without the close button (file switch, app quit).
        .onDisappear {
            // No flush here: the view is already going away, so the page may be gone
            // too and an async pull would answer into nothing. `close()` is the path
            // that settles the rendered face; this is the safety net behind it for the
            // ways the overlay disappears without it (a file switch, app quit).
            if !readOnly { saveTask?.cancel(); writeIfNeeded() }
        }
    }

    /// The scrolling body — the Markdown reader in Preview, else the Highlightr source editor. It
    /// scrolls below the fixed header; the source editor also carries the right-click "Close".
    ///
    /// Both faces stay mounted once visited; the flip only changes which one shows. An `if`/`else`
    /// here is a structural branch, so SwiftUI rebuilt one side on every flip — a fresh `WKWebView`
    /// and page load one way, a whole-document re-highlight and TextKit re-layout the other.
    @ViewBuilder private var editorContent: some View {
        let showsReader = isMarkdown && mode == .preview
        ZStack {
            if mountedReader {
                // `previewSource`, not `text`: while the source face owns the buffer this
                // one must not be handed every keystroke, which would reset its caret. The
                // flip is what exchanges the document — see `activateMode` and `requestModeChange`.
                MarkdownEditorView(
                    source: previewSource,
                    fileURL: url,
                    theme: DocumentTheme.resolveReader(settings: settings, colorScheme: colorScheme),
                    fontFamily: settings.fontFamily,
                    isEditable: !readOnly,
                    isActive: showsReader,
                    handle: readerBridge,
                    onEdit: { markdown in
                        // The rendered face owns the buffer while it is the visible one, so
                        // its edits go straight in — auto-save and the dirty flag then behave
                        // exactly as they do for the source face.
                        guard isMarkdown, mode == .preview, !readOnly else { return }
                        adoptRenderedFace(markdown)
                    },
                    onCanonical: { document, canonical in
                        renderedFaceOrigin = document
                        renderedFaceCanonical = canonical
                    },
                    onFailure: { message in saveError = message }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(showsReader)
            }
            if mountedEditor {
                sourceEditor(isActive: !showsReader)
                    .allowsHitTesting(!showsReader)
            }
        }
    }

    /// Mounts the face the mode names and hands it the current buffer. Only the flip
    /// refreshes it, so typing in one face never re-renders a document nobody is looking at.
    ///
    /// Both faces can write `text`, so the flip is also where ownership changes hands.
    /// Entering the rendered face is the easy direction — the buffer is current, push it.
    /// Leaving it is the one with an ordering hazard, and `requestModeChange` handles that
    /// before `mode` ever moves.
    private func activateMode() {
        guard loaded else { return }
        if isMarkdown && mode == .preview {
            previewSource = text
            // The pair an edit is merged against arrives from the page (`onCanonical`),
            // which answers for the document it was actually handed. The baseline is
            // dropped here so a stale pair can never be merged against while the new one
            // is in flight — until it lands an edit is adopted as-is — and the document
            // side is seeded with what is about to be pushed, so the two are never
            // half-set even if the page never answers.
            renderedFaceOrigin = text
            renderedFaceCanonical = nil
            mountedReader = true
        } else {
            mountedEditor = true
        }
    }

    /// Takes a document reported by the rendered face into the buffer, in the file's own
    /// formatting rather than the kernel's.
    ///
    /// The page's document is canonical Markdown: re-padded tables, blank lines around
    /// blocks, a `0.` list renumbered. Adopting it whole would turn one typed character
    /// into a whole-file rewrite, so only what changed is carried across — see
    /// `MarkdownWriteBack`. `previewSource` still takes the page's own text, because it
    /// is what the page holds and pushing anything else back would reset the caret.
    private func adoptRenderedFace(_ markdown: String) {
        previewSource = markdown
        guard let canonical = renderedFaceCanonical else {
            text = markdown
            return
        }
        text = MarkdownWriteBack.merge(edited: markdown, canonical: canonical,
                                       original: renderedFaceOrigin)
    }

    /// The only way the mode changes from the UI.
    ///
    /// Leaving the rendered face pulls the document out of it **first** and only then
    /// flips, because that face is the buffer's owner right up to the moment it stops
    /// being visible and its reporting is debounced. Flipping first and reading second is
    /// how the last keystrokes before a flip get silently eaten.
    ///
    /// If the page cannot answer, the flip still happens and the buffer keeps the last
    /// value the page reported — never a guess, and never an empty document.
    private func requestModeChange(to next: Mode) {
        guard next != mode else { return }
        guard mode == .preview, isMarkdown, !readOnly else {
            mode = next
            return
        }
        readerBridge.flush { markdown in
            if let markdown { adoptRenderedFace(markdown) }
            mode = next
        }
    }

    /// The Highlightr source editor with its find bar. Split out so `editorContent` reads as the
    /// two faces it switches between.
    private func sourceEditor(isActive: Bool) -> some View {
        HighlightedTextView(
                text: $text,
                language: highlightDisabled ? nil : language,
                theme: colorScheme == .dark ? "xcode-dark" : "xcode",
                font: editorFont,
                lineSpacing: settings.codeLineSpacing(for: editorFont),
                backgroundColor: settings.terminalBackgroundColor,
                textColor: textColor,
                caretColor: caretColor,
                lineNumberColor: lineNumberColor,
                currentLineColor: currentLineColor,
                occurrenceHighlightColor: occurrenceHighlightColor,
                indentGuideColor: indentGuideColor,
                isEditable: !readOnly,
                jumpToLine: jumpLine,
                findQuery: findBarVisible ? findQuery : "",
                findOptions: findOptions,
                findFocusedIndex: findFocusedIndex,
                onMatchesChanged: { count in
                    findMatchCount = count
                    if count > 0, findFocusedIndex >= count { findFocusedIndex = 0 }
                },
                findReplace: findReplace,
            showsCloseMenuItem: true,
            addToChat: addToChat,
            canAddToChat: canAddToChat,
            isActive: isActive,
            onSave: saveNow
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            // Gated on `isActive` too: a dormant editor must not leave a bar floating over Preview.
            if findBarVisible, isActive {
                FileFindBar(
                    query: $findQuery,
                    options: $findOptions,
                    currentMatch: findMatchCount == 0 ? 0 : findFocusedIndex + 1,
                    totalMatches: findMatchCount,
                    onSubmit: submitFind,
                    onNext: { advanceFind(by: 1) },
                    onPrevious: { advanceFind(by: -1) },
                    onClose: closeFindBar,
                    focusTrigger: findFocusTrigger,
                    // No replace row over a read-only peek — there is nothing to write back.
                    replace: readOnly ? nil : .init(
                        text: $findReplacement,
                        current: replaceCurrentMatch,
                        all: replaceAllMatches
                    )
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The file's real language/tool logo (a Devicon mark) when bundled, else a
            // tinted SF Symbol — sized to match the diff header's leading status badge
            // (12–13pt in a 16-wide slot) so the editor and diff headers are the same height.
            FileIconView(url: displayURL, size: 15, symbolSize: 13)
                .frame(width: 16)
            // The repo-relative path already ends in the file name, so showing the bare name
            // alongside it just repeats the same word — keep only the path as the header label.
            if let relativePath {
                Text(relativePath)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                Text(fileName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // A faint dot while an auto-save is pending — quieter than a word, no button to click.
            // On a device document the dot means something stronger: the bytes are
            // still on this Mac only, and it clears when the machine has taken
            // them. The spinner beside it is the crossing itself.
            if pushing {
                ProgressView()
                    .controlSize(.mini)
                    .help(localized("Saving to \(remote?.host ?? "")…"))
            } else if isDirty {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .help(remote == nil
                          ? localized("Unsaved changes — saving…")
                          : localized("Unsaved changes — press ⌘S to save to \(remote?.host ?? "")"))
                    .transition(.opacity)
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer()
            // Markdown reads as a document by default; the toggle keeps the source one click away.
            if isMarkdown {
                modeToggle
            }
            // The content-area window controls (hide list / maximize / close) ride the header's
            // trailing edge, after the file's own controls.
            if showsInspectorChrome {
                InspectorDetailChromeButtons()
            }
        }
        // Leading edge matches the Markdown reader's body padding (20) so the file name lines up
        // with the document text beneath it.
        .padding(.leading, 20)
        .padding(.trailing, 12)
        // One explicit height for every file type: the mode pill is taller than the text row, so
        // without the clamp a markdown header outgrows plain files'.
        .frame(height: Self.headerHeight)
        .modifier(DetailHeaderTitlebarInset())
        .background(Color(nsColor: settings.terminalBackgroundColor))
        .animation(.easeOut(duration: 0.15), value: isDirty)
    }

    /// Uniform header height across file types; the toggle's 26pt outer track sits
    /// centered inside it with breathing room.
    private static let headerHeight: CGFloat = 32

    /// The Edit/Preview switch in the app's glass-pill language — the same construction
    /// as `InspectorTabsToolbar` (own capsule track, Liquid Glass selection pill sliding
    /// between segments via `matchedGeometryEffect`, flat fills pre-Tahoe), scaled to the
    /// slim header. Hand-drawn for the same reason: a native segmented control has no
    /// track to sit on over termio's transparent chrome.
    private var modeToggle: some View {
        HStack(spacing: 0) {
            modeSegment(.edit, icon: .edit, help: localized("Edit source"))
            modeSegment(.preview, icon: .view, help: localized("Preview"))
        }
        .background { modePill }
        .padding(2)
        .background { modeTrack }
        // The pill's slide is animated locally here; the mode is set WITHOUT
        // `withAnimation` so the editor/preview content swaps instantly instead of
        // cross-fading for the pill's whole duration (the InspectorTabsToolbar lesson).
        .animation(.snappy(duration: 0.25), value: mode)
    }

    private func modeSegment(_ segment: Mode, icon: HugeIcon, help: String) -> some View {
        let selected = mode == segment
        return HugeIconView(icon: icon, size: 13, color: selected ? .primary : .secondary,
                            lineWidthOverride: 1.4)
            .frame(width: 30, height: 22)
            .matchedGeometryEffect(id: segment, in: modePillNamespace)
            // A filled hit shape so the whole segment — not just the icon's thin
            // stroke — takes the click.
            .contentShape(.capsule)
            .onTapGesture { requestModeChange(to: segment) }
            .help(help)
    }

    // The selected pill: a flat fill, no glass and no drop shadow — the raised/glass pill cast a
    // shadow that read as heavy chrome over the document. The fill alone (brighter than the track)
    // is enough to show which segment is active.
    private var modePill: some View {
        Capsule(style: .continuous)
            .fill(Color.primary.opacity(0.14))
            .matchedGeometryEffect(id: mode, in: modePillNamespace, isSource: false)
    }

    private var modeTrack: some View {
        Capsule(style: .continuous).fill(Color.primary.opacity(0.06))
    }

    /// An explicit save (⌘S): cancels the pending debounce and flushes the buffer to disk right
    /// now, rather than waiting out the idle delay. The auto-save still runs on its own; this just
    /// lets the muscle-memory ⌘S commit immediately (and the unsaved dot clears at once).
    private func saveNow() {
        saveTask?.cancel()
        withRenderedFaceSettled { writeIfNeeded() }
    }

    /// Runs `body` once the buffer is certain to hold what the user last typed.
    ///
    /// The rendered face reports its edits on a debounce, so at any instant the buffer
    /// may be up to that debounce behind the page. Anything that commits the buffer —
    /// ⌘S, closing, the overlay going away — has to pull from the page first, or it
    /// writes a document that is missing the last keystrokes. When that face is not the
    /// one in use there is nothing to wait for and `body` runs immediately.
    private func withRenderedFaceSettled(_ body: @escaping () -> Void) {
        guard isMarkdown, mode == .preview, !readOnly, loaded else {
            body()
            return
        }
        readerBridge.flush { markdown in
            if let markdown { adoptRenderedFace(markdown) }
            body()
        }
    }

    /// (Re)arms the debounced write — the previous pending save is cancelled so only a quiet pause
    /// after the last keystroke actually hits the disk.
    private func scheduleSave() {
        saveTask?.cancel()
        // A device document saves on ⌘S and on close only — every save is a
        // round trip to another machine, and arming one on each quiet pause
        // would send the file over and over as you type.
        guard remote == nil else { return }
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            writeIfNeeded()
        }
    }

    /// Closes the overlay, flushing any pending edit first so nothing is lost on the way out.
    private func close() {
        saveTask?.cancel()
        withRenderedFaceSettled {
            writeIfNeeded()
            onClose()
        }
    }

    /// The device refused the save: the file changed after it was read. Overwrite
    /// re-sends claiming nothing, which is the one case where "I know, do it
    /// anyway" is the right answer — the alternative, deciding it silently, is
    /// what loses an agent's work.
    private var conflictAlert: some View {
        Group {
            Button(localized("Overwrite"), role: .destructive) {
                conflict = nil
                pushToDevice(text, overwriting: true)
            }
            Button(localized("Cancel"), role: .cancel) { conflict = nil }
        }
    }

    /// ⌘F: show the find bar. Skipped in Markdown Preview mode — there's no NSTextView to
    /// search underneath.
    private func openFindBar() {
        guard mode == .edit else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { findBarVisible = true }
        // NSTextView keeps first responder otherwise, and SwiftUI's @FocusState can't wrestle
        // it away — drop it explicitly so the find field can claim the keyboard.
        NSApp.keyWindow?.makeFirstResponder(nil)
        findFocusTrigger &+= 1
    }

    private func closeFindBar() {
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { findBarVisible = false }
        findQuery = ""
        findLastSubmittedQuery = ""
        findReplacement = ""
        findMatchCount = 0
        findFocusedIndex = 0
        findOptions = FindOptions()
    }

    /// ⌘E: the editor's selection becomes the find query. Only when this editor's own text view
    /// holds the keyboard — the verb is broadcast the way ⌘F is, and a diff overlay mounted behind
    /// this one must not take its query from a buffer the user isn't in. Read before the bar
    /// opens, since opening it takes first responder away from the text view.
    ///
    /// The query counts as already submitted, so the very next Return — or ⌘G — advances to the
    /// second match instead of re-running the search that just ran.
    private func useSelectionForFind() {
        guard mode == .edit, let selection = findReplace.focusedSelection() else { return }
        openFindBar()
        findQuery = selection
        findLastSubmittedQuery = selection
        findFocusedIndex = 0
    }

    /// Replace: the focused match becomes the replacement, and the focus steps to the next match
    /// past it. The match list and the "n of m" counter refresh on their own — the edit fires
    /// `textDidChange`, which is where the find engine already recomputes.
    private func replaceCurrentMatch() {
        guard !readOnly, findMatchCount > 0 else { return }
        guard let next = findReplace.replaceCurrent(
            at: findFocusedIndex, query: findQuery, options: findOptions, template: findReplacement)
        else { return }
        findFocusedIndex = next
    }

    /// Replace All: every match at once, as a single edit — so ⌘Z takes the whole document back
    /// in one step rather than one step per match.
    private func replaceAllMatches() {
        guard !readOnly, findMatchCount > 0 else { return }
        findReplace.replaceAll(query: findQuery, options: findOptions, template: findReplacement)
        findFocusedIndex = 0
    }

    /// Return: fresh query → jump to match 1; same query → next match.
    private func submitFind() {
        guard !findQuery.isEmpty else { return }
        if findQuery == findLastSubmittedQuery, findMatchCount > 0 {
            advanceFind(by: 1)
        } else {
            findLastSubmittedQuery = findQuery
            findFocusedIndex = 0
        }
    }

    private func advanceFind(by offset: Int) {
        guard findMatchCount > 0 else { return }
        findFocusedIndex = ((findFocusedIndex + offset) % findMatchCount + findMatchCount) % findMatchCount
    }

    /// Reads the file once per opened identity (`.id(url)` on the overlay), off the main
    /// thread — a large file must not beachball the click that opened it. Oversized files
    /// also flip `highlightDisabled` so the editor renders them as plain text.
    private func load() async {
        let url = url
        let result: (text: String?, bytes: Int, relativePath: String?) =
            await Task.detached(priority: .userInitiated) {
                // The repo-relative header path rides the same background hop as the read:
                // GitRoot walks ancestors with filesystem checks, which stalls on network mounts.
                let file = url.standardizedFileURL
                let relative = GitRoot.find(for: file).map {
                    String(file.path.dropFirst($0.path.count + 1))
                }
                guard let data = try? Data(contentsOf: url) else { return (nil, 0, relative) }
                return (String(data: data, encoding: .utf8), data.count, relative)
            }.value
        relativePath = result.relativePath
        guard let contents = result.text else {
            loadFailed = true
            return
        }
        highlightDisabled = result.bytes >= Self.highlightByteLimit
        text = contents
        savedText = contents
        loaded = true
    }

    /// Writes the buffer to disk if it differs from what's already there. The single place a save
    /// happens, shared by the debounce, the close button, and the disappear safety net.
    private func writeIfNeeded() {
        guard !readOnly, loaded, text != savedText else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            saveError = nil
            // A local file is saved the moment its bytes are on disk. A staged
            // copy is not: the file the user thinks they saved is on another
            // machine, so `savedText` — which is what the unsaved dot reads —
            // only advances once the device has taken it.
            if remote == nil {
                savedText = text
            } else {
                pushToDevice(text)
            }
        } catch {
            saveError = localized("Save failed: \(error.localizedDescription)")
        }
    }

    /// Sends the buffer to the machine it came from, claiming the version it was
    /// read at. A refusal means somebody else — most likely an agent with a
    /// shell in the same checkout — wrote the file first, and that is asked
    /// about rather than decided here.
    private func pushToDevice(_ contents: String, overwriting: Bool = false) {
        guard let remote else { return }
        pushTask?.cancel()
        pushing = true
        pushTask = Task { @MainActor in
            do {
                let landed = try await remote.provider.write(
                    remote.path, data: Data(contents.utf8),
                    ifUnmodifiedSince: overwriting ? nil : versionToClaim(remote))
                guard !Task.isCancelled else { return }
                savedText = contents
                saveError = nil
                conflict = nil
                onRemoteSave?(remote.read(at: landed))
            } catch let error as DeviceFileError {
                guard !Task.isCancelled else { return }
                if case .conflict(let message) = error {
                    conflict = message
                } else {
                    saveError = localized("Save failed: \(error.localizedDescription)")
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard !(error is CancellationError) else { return }
                saveError = localized("Save failed: \(error.localizedDescription)")
            }
            pushing = false
        }
    }

    /// The version a save claims, and `nil` when there is none to claim: a host
    /// too old to report an mtime answers 0, and sending 0 would fail every
    /// save against a file whose real mtime is anything else. No version means
    /// no check — the same bargain every other absent field in this protocol
    /// makes.
    private func versionToClaim(_ document: RemoteDocument) -> UInt64? {
        document.mtime == 0 ? nil : document.mtime
    }

    /// Maps a file to a highlight.js language id, matched against grammars the bundled highlight.js
    /// actually ships (e.g. it has no `toml`/`jsonc` — those fold into `ini`/`json`). The whole file
    /// name is checked first (so `Dockerfile`, `Cargo.lock`, `yarn.lock`, … resolve by name, not
    /// extension), then the extension. Unknown files return `nil` and render as plain text — the
    /// storage treats a missing language as "don't highlight", not as an auto-detect request.
    /// Shared with `GitDiffView`, which colors diff lines through the same grammar set.
    static func highlightLanguage(for url: URL) -> String? {
        // Extension-less or specially-named files, keyed by the whole (lowercased) name.
        switch url.lastPathComponent.lowercased() {
        case "dockerfile", "containerfile": return "dockerfile"
        case "makefile", "gnumakefile": return "makefile"
        case "cmakelists.txt": return "cmake"
        case "gemfile", "podfile", "rakefile", "gemfile.lock": return "ruby"
        case "cargo.lock", "poetry.lock", "pipfile": return "ini" // TOML-ish (no toml grammar)
        case "yarn.lock": return "yaml"
        // highlight.js ships no ssh_config grammar; `properties` is the closest fit — an
        // ssh_config line *is* `Directive value`, which it colors as key + rest-of-line value
        // (`ini` needs `=` or `[section]` and would leave the whole file grey). The bare name
        // `config` only qualifies inside `.ssh`, since it's also git's ini-style config.
        case "ssh_config", "sshd_config": return "properties"
        case "config" where url.deletingLastPathComponent().lastPathComponent == ".ssh":
            return "properties"
        case ".gitignore", ".dockerignore", ".npmignore": return "bash"
        case ".env", ".editorconfig", ".npmrc": return "ini"
        case "nginx.conf": return "nginx"
        default: break
        }

        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "tsx", "mts", "cts": return "typescript"
        case "py", "pyw", "pyi": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx": return "cpp"
        case "m", "mm": return "objectivec"
        case "cs": return "csharp"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "php": return "php"
        case "dart": return "dart"
        case "lua": return "lua"
        case "r": return "r"
        case "scala", "sc": return "scala"
        case "hs": return "haskell"
        case "ex", "exs": return "elixir"
        case "erl", "hrl": return "erlang"
        case "clj", "cljs", "edn": return "clojure"
        case "pl", "pm": return "perl"
        // JSON family — highlight.js has no jsonc/json5 grammar, so they fold into json. Most
        // `.lock` files (deno.lock, flake.lock, composer.lock, Pipfile.lock) are JSON too.
        case "json", "jsonc", "json5", "lock": return "json"
        case "yml", "yaml": return "yaml"
        case "toml", "ini", "conf", "cfg", "properties": return "ini"
        case "md", "markdown", "mdx": return "markdown"
        case "sh", "bash", "zsh", "fish", "ksh": return "bash"
        case "ps1", "psm1": return "powershell"
        case "bat", "cmd": return "dos"
        case "html", "htm", "xml", "plist", "svg", "xhtml": return "xml"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "less": return "less"
        case "sql": return "sql"
        case "graphql", "gql": return "graphql"
        case "proto": return "protobuf"
        case "cmake": return "cmake"
        case "mk", "mak": return "makefile"
        case "diff", "patch": return "diff"
        default: return nil
        }
    }
}
