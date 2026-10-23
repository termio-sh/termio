import AppKit
import AVKit
import SwiftUI
import WebKit

/// Read-only preview that covers the terminal pane for previewable files (image, video, PDF) — the
/// visual counterpart of `FileEditorView`. Double-clicking such a file opens it in place over the
/// terminal (the surface keeps running underneath) instead of a detached Quick Look window, so a
/// previewed image/PDF reads as part of the same workspace as the editor. Escape or the close
/// button dismisses it back to the terminal.
struct FilePreviewView: View {
    let url: URL
    @ObservedObject var settings: AppSettings
    let displayName: String?
    /// False for content copied from an SSH host. A failed raster decode must
    /// stay inert instead of handing attacker-controlled bytes to WebKit.
    let allowsWebFallback: Bool
    /// "Add to Chat" for the PDF reader — the same contract as the editor's: a passage
    /// goes over as a snippet, `nil` means send the document's path.
    let addToChat: ((String?) -> Void)?
    let canAddToChat: (() -> Bool)?
    /// Dismisses the overlay (clears `store.openFileURL`) and hands focus back to the terminal.
    let onClose: () -> Void

    init(
        url: URL,
        settings: AppSettings,
        displayName: String? = nil,
        allowsWebFallback: Bool = true,
        addToChat: ((String?) -> Void)? = nil,
        canAddToChat: (() -> Bool)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.url = url
        self.settings = settings
        self.displayName = displayName
        self.allowsWebFallback = allowsWebFallback
        self.addToChat = addToChat
        self.canAddToChat = canAddToChat
        self.onClose = onClose
    }

    private var fileName: String { displayName ?? url.lastPathComponent }

    /// PDFs never reach the preview body below — they open in the reader instead.
    private var isDocument: Bool { url.pathExtension.lowercased() == "pdf" }

    var body: some View {
        // A PDF is read, not glanced at: it gets its own reader (contents, pages,
        // highlights) rather than this view's single-shot preview chrome.
        if isDocument {
            PDFReaderView(url: url, settings: settings, displayName: displayName,
                          addToChat: addToChat, canAddToChat: canAddToChat, onClose: onClose)
        } else {
            preview
        }
    }

    private var preview: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // Opaque terminal-colored fill so the overlay fully covers the terminal, running up under
        // the toolbar like the terminal itself.
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 8) {
            DetailListColumnToggle()
            Image(systemName: FileActivation.isVideo(url) ? "film" : "photo")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(fileName)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            // The content-area window controls (hide list / maximize / close) ride the header's
            // trailing edge, matching the editor and every other inspector detail — so a previewed
            // image/PDF has the same visible exit as a diff, not just Escape.
            InspectorDetailChromeButtons()
        }
        .padding(.horizontal, 12)
        .frame(height: GitChangesView.topBarHeight)
        .modifier(DetailHeaderTitlebarInset())
        .background(Color(nsColor: settings.terminalBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if FileActivation.isVideo(url) {
            VideoPreview(url: url)
        } else {
            image
        }
    }

    @ViewBuilder
    private var image: some View {
        // NSImage decodes the raster formats; anything it can't (e.g. some SVGs) falls back to
        // the web view, which renders vector art reliably. The image fits the pane by default —
        // large images scale down to fit rather than overflow, small ones center.
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .contextMenu {
                    Button(localized("Copy Image")) {
                        // The NSImage goes on the pasteboard as bitmap data, so it pastes
                        // into chat and design apps as the picture, not a file path.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    }
                    Button(localized("Reveal in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
        } else if Self.usesWebFallback(
            imageDecoded: false, allowsWebFallback: allowsWebFallback
        ) {
            WebPreview(url: url)
        } else {
            PaneEmptyState(
                localized("Can’t preview"),
                icon: .fileQuestion,
                message: localized("“\(fileName)” isn’t a supported image.")
            )
        }
    }

    /// Internal so the security boundary has a direct regression test.
    static func usesWebFallback(
        imageDecoded: Bool,
        allowsWebFallback: Bool
    ) -> Bool {
        !imageDecoded && allowsWebFallback
    }
}

/// AVKit's own player for a local movie: the system transport controls, scrubbing, and
/// full screen, with nothing of termio's to keep in step with the OS. It never plays on its
/// own — opening a file to look at it shouldn't start sound.
struct VideoPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard (view.player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        view.player?.pause()
        view.player = AVPlayer(url: url)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// A `WKWebView` rendering a local file (HTML pages in the editor's Preview, and SVGs that
/// `NSImage` can't decode).
struct WebPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        // PreviewWebView: right-click stripped to Copy, like the Markdown reader —
        // a read-only preview has no use for WebKit's default menu.
        let view = PreviewWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}
