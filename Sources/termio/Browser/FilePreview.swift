import AppKit
import PDFKit
import SwiftUI
import WebKit

/// Read-only preview that covers the terminal pane for previewable files (image, PDF, HTML) — the
/// visual counterpart of `FileEditorView`. Double-clicking such a file opens it in place over the
/// terminal (the surface keeps running underneath) instead of a detached Quick Look window, so a
/// previewed image/PDF/page reads as part of the same workspace as the editor. Escape or the close
/// button dismisses it back to the terminal.
struct FilePreviewView: View {
    let url: URL
    @ObservedObject var settings: AppSettings
    /// Dismisses the overlay (clears `store.openFileURL`) and hands focus back to the terminal.
    let onClose: () -> Void

    private enum Kind { case image, pdf, web }

    private var kind: Kind {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "html", "htm": return .web
        default: return .image
        }
    }

    var body: some View {
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
            Image(systemName: kind == .pdf ? "doc.richtext" : (kind == .web ? "globe" : "photo"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(url.lastPathComponent)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            // The content-area window controls (hide list / maximize / close) ride the header's
            // trailing edge, matching the editor and every other inspector detail — so a previewed
            // image/PDF/page has the same visible exit as a diff, not just Escape.
            InspectorDetailChromeButtons()
        }
        .padding(.horizontal, 12)
        .frame(height: GitChangesView.topBarHeight)
        .background(Color(nsColor: settings.terminalBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .pdf:
            PDFPreview(url: url)
        case .web:
            WebPreview(url: url)
        case .image:
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
                        Button("Copy Image") {
                            // The NSImage goes on the pasteboard as bitmap data, so it pastes
                            // into chat and design apps as the picture, not a file path.
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([image])
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
            } else {
                WebPreview(url: url)
            }
        }
    }
}

/// A `PDFView` over a file URL, scaled to fit on the terminal background.
private struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

/// A `WKWebView` rendering a local file (HTML pages, and SVGs that `NSImage` can't decode).
private struct WebPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
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
