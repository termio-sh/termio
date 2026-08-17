import AppKit
import SwiftUI
import TermioShared

/// The icon shown beside a file: its real language/tool logo when termio bundles one
/// (a Devicon SVG, keyed by extension or exact name via `LangIconCatalog`), otherwise
/// the tinted SF Symbol from `FileTypeIcon`. Both the file tree and the editor header
/// draw through this so a `.ts` reads as the TypeScript mark in either place.
///
/// Monochrome marks — the ones whose SVG is a single near-black silhouette (Rust, Deno,
/// Markdown, YAML, …) — are drawn as an adaptive template tinted with the label ink, so
/// they stay visible on a dark terminal background rather than disappearing into it.
struct FileIconView: View {
    let url: URL
    /// Point size of the square logo box.
    var size: CGFloat = 16
    /// Font size of the SF Symbol fallback (sized independently — a glyph sits inside
    /// its cap height, so it usually wants to run a touch larger than the logo box).
    var symbolSize: CGFloat = 13
    /// Ink for the Hugeicons resource glyphs, so the file tree can pass the same
    /// chrome foreground its folder rows use and the two read as one family.
    var ink: Color = .primary

    var body: some View {
        if let resource = LangIconCatalog.resource(forFileName: url.lastPathComponent),
           let image = LangIconLoader.shared.image(named: resource.name) {
            if resource.monochrome {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(.template)
                    .foregroundStyle(Color.monochromeInk)
                    .frame(width: size, height: size)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            }
        } else if let kind = FileTypeIcon.resourceKind(for: url) {
            // Resource files (images, PDF, media, plain text) and unmatched
            // extensions draw in the app's own Hugeicons line style, in the same
            // ink as the tree's folder glyphs — color in the tree stays reserved
            // for real language logos. Drawn a step above the Devicon box: those
            // marks fill their box edge-to-edge while Hugeicons ink only ~75% of
            // theirs, so equal nominal sizes would read a step smaller. 1.15 (not
            // the folder rows' full 12-vs-15 ratio) because these file-shaped
            // marks are height-dominant and overshoot the Devicon cap height at
            // 1.25. Only the code-shaped fallbacks below stay SF Symbols.
            HugeIconView(icon: Self.hugeIcon(for: kind), size: size * 1.15, color: ink)
                .frame(width: size)
        } else {
            let icon = FileTypeIcon.icon(for: url)
            Image(systemName: icon.symbol)
                .font(.system(size: symbolSize))
                .foregroundStyle(icon.color)
                .frame(width: size)
        }
    }

    private static func hugeIcon(for kind: FileTypeIcon.ResourceKind) -> HugeIcon {
        switch kind {
        case .image: return .image
        case .pdf: return .filePdf
        case .audio: return .fileAudio
        case .video: return .fileVideo
        case .plainText: return .fileText
        case .generic: return .fileDoc
        }
    }
}

/// Loads and caches the bundled Devicon SVGs as `NSImage`s. `NSImage` rasterizes SVG
/// natively, so each logo stays crisp at any size; the cache keeps a folder of ~100
/// marks from re-decoding on every list-row realization.
@MainActor
final class LangIconLoader {
    static let shared = LangIconLoader()
    /// `NSImage?`, not `NSImage`: an extension with no Devicon has to be remembered too.
    /// Caching only the hits left every `.jsonl`, `.lock` and `.plist` in the tree
    /// repeating a bundle resource lookup — filesystem work — on each row realization,
    /// and rows realize on every scroll and every layout pass.
    private var cache: [String: NSImage?] = [:]

    func image(named name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        let image = Bundle.termioResources.url(
            forResource: name, withExtension: "svg", subdirectory: "LangIcons"
        ).flatMap { NSImage(contentsOf: $0) }
        cache[name] = image
        return image
    }
}
