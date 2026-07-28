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
    /// Dismisses the overlay (clears `store.openFileURL`) and hands focus back to the terminal.
    let onClose: () -> Void

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
    /// Set when the file is too large for syntax highlighting (see `highlightByteLimit`).
    @State private var highlightDisabled = false
    @State private var saveError: String?
    @State private var cursor: EditorCursor?
    /// The pending debounced write, cancelled and rescheduled on each keystroke.
    @State private var saveTask: Task<Void, Never>?

    /// Past this size the file renders as plain text: highlight.js parses off-main, but
    /// *applying* its result is thousands of main-thread `setAttributes` calls plus a
    /// whole-document relayout — seconds of beachball on a generated 600 KB YAML.
    private static let highlightByteLimit = 256 * 1024

    /// The highlight.js language id, sniffed once from the file extension (`nil` lets highlight.js
    /// auto-detect). Stable for the lifetime of the open file.
    private let language: String?
    /// The file's path relative to its git root — shown next to the name like the diff header
    /// (`GitDiffView`), so the two overlays read the same. `nil` outside a repo.
    private let relativePath: String?

    init(url: URL, settings: AppSettings, readOnly: Bool = false, jumpLine: Int? = nil,
         onClose: @escaping () -> Void) {
        self.url = url
        self.settings = settings
        self.readOnly = readOnly
        self.jumpLine = jumpLine
        self.onClose = onClose
        // No I/O here: SwiftUI re-runs this init on every parent render (the store's
        // session churn), and only the first init per `.id(url)` identity keeps its
        // state — a sync read would hit the disk over and over just to be discarded.
        // The actual load happens once, in `.task`.
        // A jump-to-line open (content-search hit, cmd-click) targets the *source*, so it
        // must land in Edit — Preview has no lines to jump to and would swallow the scroll.
        _mode = State(initialValue: Self.isMarkdown(url) && jumpLine == nil ? .preview : .edit)
        self.language = Self.highlightLanguage(for: url)
        self.relativePath = Self.repoRelativePath(for: url)
    }

    /// Markdown files get the Edit/Preview toggle; sniffed from the extension only (matching
    /// the `markdown` grammar in `highlightLanguage`).
    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdx"].contains(url.pathExtension.lowercased())
    }
    private var isMarkdown: Bool { Self.isMarkdown(url) }

    /// The file's path relative to its git root (the form the diff header shows, e.g.
    /// `core 2/lib/fs.ts`). `nil` when the file isn't inside a git work tree.
    private static func repoRelativePath(for url: URL) -> String? {
        let file = url.standardizedFileURL
        guard let root = GitRoot.find(for: file) else { return nil }
        return String(file.path.dropFirst(root.path.count + 1))
    }

    private var isDirty: Bool { text != savedText }

    /// The editor font, borrowed from the terminal so an opened file reads in the same face the
    /// agent's output does. Falls back to the system monospace when no family is pinned.
    private var editorFont: NSFont {
        settings.resolvedTerminalFont()
    }

    /// Foreground/caret fall back to the terminal theme's colors (the rest of the chrome's source of
    /// truth) so plain text and the insertion point sit on the terminal background cleanly.
    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }
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

    var body: some View {
        // The editor's chrome (header, gutter) already sits in the safe content area below the
        // toolbar — only the *background* bleeds up under the transparent titlebar, for a seamless
        // fill with the terminal. (No manual titlebar inset: the overlay's content top is already at
        // the safe-area top; padding it again just opened a dead band above the header.)
        Group {
            if loadFailed {
                ContentUnavailableView(
                    "Can't Open as Text",
                    huge: .fileQuestion,
                    description: Text("\(url.lastPathComponent) isn't a UTF-8 text file.")
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
        // Auto-save: debounce a write after each edit; Escape closes (flushing first). A read-only
        // peek never writes, so neither the debounce nor the exit flush is armed.
        .onChange(of: text) {
            if !readOnly { scheduleSave() }
        }
        .onExitCommand { close() }
        // A safety flush if the overlay goes away without the close button (file switch, app quit).
        .onDisappear {
            if !readOnly { saveTask?.cancel(); writeIfNeeded() }
        }
    }

    /// The scrolling body — the Markdown reader in Preview, else the Highlightr source editor. It
    /// scrolls below the fixed header; the source editor also carries the right-click "Close".
    @ViewBuilder private var editorContent: some View {
        if isMarkdown && mode == .preview {
            // Render the *live* buffer, so flipping over from Edit shows unsaved keystrokes
            // without a round-trip through disk.
            MarkdownReaderView(
                source: text,
                fileURL: url,
                settings: settings,
                colorScheme: colorScheme
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HighlightedTextView(
                text: $text,
                cursor: $cursor,
                language: highlightDisabled ? nil : language,
                theme: colorScheme == .dark ? "xcode-dark" : "xcode",
                font: editorFont,
                backgroundColor: settings.terminalBackgroundColor,
                caretColor: caretColor,
                lineNumberColor: lineNumberColor,
                currentLineColor: currentLineColor,
                isEditable: !readOnly,
                jumpToLine: jumpLine,
                showsCloseMenuItem: true,
                onSave: saveNow
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The file's real language/tool logo (a Devicon mark) when bundled, else a
            // tinted SF Symbol — sized to match the diff header's leading status badge
            // (12–13pt in a 16-wide slot) so the editor and diff headers are the same height.
            FileIconView(url: url, size: 15, symbolSize: 13)
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
                Text(url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // A faint dot while an auto-save is pending — quieter than a word, no button to click.
            if isDirty {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .help("Unsaved changes — saving…")
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
        }
        // Leading edge matches the Markdown reader's body padding (20) so the file name lines up
        // with the document text beneath it.
        .padding(.leading, 20)
        .padding(.trailing, 12)
        // One explicit height for every file type: the mode pill is taller than the text row, so
        // without the clamp a markdown header outgrows plain files'.
        .frame(height: Self.headerHeight)
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
            modeSegment(.edit, icon: .edit, help: "Edit source")
            modeSegment(.preview, icon: .view, help: "Preview")
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
            .onTapGesture { mode = segment }
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
        writeIfNeeded()
    }

    /// (Re)arms the debounced write — the previous pending save is cancelled so only a quiet pause
    /// after the last keystroke actually hits the disk.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            writeIfNeeded()
        }
    }

    /// Closes the overlay, flushing any pending edit first so nothing is lost on the way out.
    private func close() {
        saveTask?.cancel()
        writeIfNeeded()
        onClose()
    }

    /// Reads the file once per opened identity (`.id(url)` on the overlay), off the main
    /// thread — a large file must not beachball the click that opened it. Oversized files
    /// also flip `highlightDisabled` so the editor renders them as plain text.
    private func load() async {
        let url = url
        let result: (text: String?, bytes: Int) = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return (nil, 0) }
            return (String(data: data, encoding: .utf8), data.count)
        }.value
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
            savedText = text
            saveError = nil
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Maps a file to a highlight.js language id, matched against grammars the bundled highlight.js
    /// actually ships (e.g. it has no `toml`/`jsonc` — those fold into `ini`/`json`). The whole file
    /// name is checked first (so `Dockerfile`, `Cargo.lock`, `yarn.lock`, … resolve by name, not
    /// extension), then the extension. Unknown files return `nil` to let highlight.js auto-detect.
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
