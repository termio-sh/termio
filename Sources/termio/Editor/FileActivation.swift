import Foundation

/// Routing for a double-clicked file in the inspector: a previewable file (image, video, PDF) opens in
/// `FilePreviewView`, and everything else opens in the editor that covers the terminal
/// (`FileEditorView`, driven by `TermioStore.openFileURL`). An HTML page is previewable but
/// opens in the editor, whose Preview face renders it — so its source is one click away, as
/// Markdown's is.
enum FileActivation {
    /// File kinds Quick Look renders well on its own, so a double-click previews them rather than
    /// dropping into the text editor. Everything else is treated as editable text.
    static func isPreviewable(_ url: URL) -> Bool {
        previewExtensions.contains(url.pathExtension.lowercased())
    }

    /// Movies AVFoundation can decode. WebM and MKV are absent because it can't.
    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// HTML pages: rendered by the editor's Preview face rather than by `FilePreviewView`.
    static func isWebPage(_ url: URL) -> Bool {
        ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    /// Formats whose preview path executes a web document rather than decoding
    /// inert media. Remote copies are rendered as read-only source instead.
    static func isActiveWebContent(_ url: URL) -> Bool {
        ["html", "htm", "svg"].contains(url.pathExtension.lowercased())
    }

    /// Previewable files whose git diff isn't useful: image rasters, SVG art, video, and PDFs are
    /// binary or opaque, so the Changes pane opens the file itself rather than a "binary files
    /// differ" / empty diff. HTML keeps its (meaningful) text diff.
    static func previewsRatherThanDiff(_ url: URL) -> Bool {
        guard isPreviewable(url) else { return false }
        return !isWebPage(url)
    }

    /// Files the in-app preview can't render, but Quick Look can — the video AVFoundation
    /// can't decode, audio, and the office formats Finder's spacebar already plays. Cmd-clicking one of these in the terminal
    /// pops the shared Quick Look panel instead of dropping the bytes into the text editor.
    static func quickLooks(_ url: URL) -> Bool {
        quickLookExtensions.contains(url.pathExtension.lowercased())
    }

    private static let previewExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp", "icns", "svg",
        "pdf", "html", "htm", "mp4", "mov", "m4v",
    ]

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    private static let quickLookExtensions: Set<String> = [
        "webm", "mkv", "avi",
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac",
        "doc", "docx", "ppt", "pptx", "xls", "xlsx", "key", "pages", "numbers",
        "rtf", "rtfd", "ttf", "otf", "woff", "woff2",
    ]
}

