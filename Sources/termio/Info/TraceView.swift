import AppKit
import SwiftUI
import WebKit

/// A request to show an agent session's rendered trace over the terminal — the trace
/// counterpart of `openFileURL` / `openDiff`. Carries the transcript path and a
/// display title; the theme is resolved live in `TraceView` from the active settings.
struct TraceRequest: Hashable {
    let jsonlPath: String
    let title: String
}

/// The colors `SessionTraceRenderer` injects into the trace HTML so the page matches
/// termio's active theme. Resolved from the chosen chrome theme, or termio's built-in
/// light/dark defaults when no Ghostty theme is selected (mirrors
/// `ChromeTheme.terminalBackgroundColor`'s fallbacks).
struct TraceTheme {
    let background: String
    let panel: String
    let foreground: String
    let secondary: String
    let accent: String
    let isDark: Bool

    @MainActor
    static func resolve(settings: AppSettings, colorScheme: ColorScheme) -> TraceTheme {
        if let chrome = settings.chromeTheme(for: colorScheme) { return from(chrome) }
        return builtin(dark: colorScheme == .dark)
    }

    /// `resolve` for the Markdown reader: the same chrome-theme path, but the no-theme
    /// fallback is the reader palette rather than the trace's `builtin`.
    @MainActor
    static func resolveReader(settings: AppSettings, colorScheme: ColorScheme) -> TraceTheme {
        if let chrome = settings.chromeTheme(for: colorScheme) { return from(chrome) }
        return reader(dark: colorScheme == .dark)
    }

    private static func from(_ chrome: ChromeTheme) -> TraceTheme {
        TraceTheme(
            background: hex(chrome.background),
            panel: hex(chrome.panelBackground),
            foreground: hex(chrome.foreground),
            secondary: hex(chrome.secondaryForeground),
            accent: hex(chrome.accent),
            isDark: chrome.isDark
        )
    }

    /// termio's built-in light/dark defaults with no `AppSettings` dependency —
    /// used to render a trace for the phone, which sends only its light/dark
    /// trait (not the Mac's chrome theme) over the companion wire. These values
    /// are the trace's — tune the Markdown reader in `reader(dark:)` instead.
    static func builtin(dark: Bool) -> TraceTheme {
        dark
            ? TraceTheme(background: "#212121", panel: "#2a2a2c", foreground: "#e6e6e8",
                         secondary: "#8a8a90", accent: "#7d8cff", isDark: true)
            : TraceTheme(background: "#ffffff", panel: "#f2f2f4", foreground: "#1d1d1f",
                         secondary: "#6e6e73", accent: "#2f6fed", isDark: false)
    }

    /// The Markdown reader's fallback palette, deliberately decoupled from `builtin`.
    /// Backgrounds mirror `terminalBackgroundColor`'s fallbacks (pure white in light,
    /// Afterglow #212121 in dark) so the reading view matches the terminal it overlays
    /// and the editor you flip from — seamless, not a differently-tinted page. The
    /// accents are muted, print-like tints tuned for reading; warmth and beauty come
    /// from typography, not a coloured canvas.
    static func reader(dark: Bool) -> TraceTheme {
        dark
            ? TraceTheme(background: "#212121", panel: "#2a2a2c", foreground: "#e6e6e8",
                         secondary: "#8a8a90", accent: "#6f9bd8", isDark: true)
            : TraceTheme(background: "#ffffff", panel: "#f7f6f3", foreground: "#1d1d1f",
                         secondary: "#6e6e73", accent: "#205ea6", isDark: false)
    }

    private static func hex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

/// Full-pane overlay that renders an agent session's transcript as an in-app HTML
/// trace (dashboard + collapsible conversation), painted in the live termio theme.
/// Presented the same way as the file editor and git diff overlays: it covers the
/// terminal, and Escape or the toolbar close button dismisses it.
struct TraceView: View {
    let request: TraceRequest
    @ObservedObject var settings: AppSettings
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var html: String?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let html {
                TraceWebView(html: html, background: settings.terminalBackgroundColor)
            } else if let loadError {
                ContentUnavailableView("Couldn't build the trace", huge: .bot, description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Match the editor/diff overlays: opaque terminal background bleeding under the titlebar.
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        // The trace has no header row, so the content-area controls float in the top-trailing corner.
        .overlay(alignment: .topTrailing) {
            InspectorDetailChromeButtons()
                .padding(.top, 4)
                .padding(.trailing, 8)
        }
        .onExitCommand(perform: onClose)
        .task(id: request) { await build() }
        // Re-render if the user flips light/dark while the trace is open.
        .onChange(of: colorScheme) { Task { await build() } }
    }

    private func build() async {
        let theme = TraceTheme.resolve(settings: settings, colorScheme: colorScheme)
        do {
            html = try SessionTraceRenderer.html(jsonlPath: request.jsonlPath, title: request.title, theme: theme)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// A minimal `WKWebView` host that renders a self-contained HTML string. Its own
/// background is cleared so the SwiftUI terminal-background behind it shows through
/// during load, avoiding a white flash before the themed page paints.
private struct TraceWebView: NSViewRepresentable {
    let html: String
    let background: NSColor

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(lastHTML: html) }

    /// Markdown in agent messages can contain links; open them in the browser
    /// instead of letting them navigate the trace page away.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String
        init(lastHTML: String) { self.lastHTML = lastHTML }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
