import AppKit
import SwiftUI
import TermioShared

/// The icon shown beside a file. Recognized languages and development tools keep their
/// original Devicon marks; files without a dedicated mark use the Hugeicons theme.
struct FileIconView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let url: URL
    var size: CGFloat = 16

    var body: some View {
        if let resource = LangIconCatalog.resource(forFileName: url.lastPathComponent),
           let image = LangIconLoader.shared.image(named: resource.name) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .renderingMode(resource.monochrome ? .template : .original)
                .foregroundStyle(resource.monochrome ? Color.monochromeInk : .primary)
                .frame(width: size, height: size)
        } else {
            HugeIconView(
                icon: ThemedFileIcon.icon(for: url),
                size: size,
                color: settings.chromeTheme(for: colorScheme)?.foreground ?? .primary
            )
        }
    }
}

/// Loads and caches the bundled Devicon SVGs as `NSImage`s. `NSImage` decodes SVG
/// natively, so recognized language marks stay crisp at every sidebar size.
@MainActor
final class LangIconLoader {
    static let shared = LangIconLoader()
    private var cache: [String: NSImage] = [:]

    func image(named name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.termioResources.url(
            forResource: name, withExtension: "svg", subdirectory: "LangIcons"
        ), let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }
}
