import TermioShared
import UIKit

/// The icon beside a file in the inspector tree — the iOS counterpart of the
/// Mac's `FileIconView`, driven by the same shared `LangIconCatalog`: the real
/// language/tool logo when termio bundles one (compiled here into
/// `LangIcons.xcassets`); resource files and unmatched extensions draw the
/// shared Hugeicons line glyphs; only the code-shaped fallbacks keep the tinted
/// SF Symbol from the shared `FileTypeIcon` map — so a `.ts` reads as the
/// TypeScript mark and a `.pdf` as the same line glyph on both platforms.
enum FileIcons {
    /// Image + tint for a file name. Colored logos carry their own colors
    /// (nil tint); monochrome marks and the Hugeicons resource glyphs are
    /// template images tinted with label ink so they stay visible in either
    /// appearance, matching the Mac's `monochromeInk` treatment.
    static func icon(forFileName name: String) -> (image: UIImage?, tint: UIColor?) {
        if let resource = LangIconCatalog.resource(forFileName: name),
           let image = UIImage(named: resource.name) {
            return (image, resource.monochrome ? .label : nil)
        }
        let url = URL(fileURLWithPath: name)
        if let kind = FileTypeIcon.resourceKind(for: url) {
            return (hugeIcon(for: kind).strokeImage(boxSize: 16), .label)
        }
        let fallback = FileTypeIcon.icon(for: url)
        return (UIImage(systemName: fallback.symbol), UIColor(fallback.color))
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
