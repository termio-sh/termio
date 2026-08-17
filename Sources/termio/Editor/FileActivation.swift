import Foundation

/// Routing for a double-clicked file in the inspector: a previewable file (image, PDF, HTML)
/// opens in Quick Look — handled in `FileBrowserHostingController` — and everything else opens in
/// the editor that covers the terminal (`FileEditorView`, driven by `TermioStore.openFileURL`).
enum FileActivation {
    /// File kinds Quick Look renders well on its own, so a double-click previews them rather than
    /// dropping into the text editor. Everything else is treated as editable text.
    static func isPreviewable(_ url: URL) -> Bool {
        previewExtensions.contains(url.pathExtension.lowercased())
    }

    /// Formats whose preview path executes a web document rather than decoding
    /// inert media. Remote copies are rendered as read-only source instead.
    static func isActiveWebContent(_ url: URL) -> Bool {
        ["html", "htm", "svg"].contains(url.pathExtension.lowercased())
    }

    /// Previewable files whose git diff isn't useful: image rasters, SVG art, and PDFs are
    /// binary or opaque, so the Changes pane opens the file itself rather than a "binary files
    /// differ" / empty diff. HTML keeps its (meaningful) text diff.
    static func previewsRatherThanDiff(_ url: URL) -> Bool {
        guard isPreviewable(url) else { return false }
        let ext = url.pathExtension.lowercased()
        return ext != "html" && ext != "htm"
    }

    private static let previewExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp", "icns", "svg",
        "pdf", "html", "htm",
    ]
}

