import SwiftUI

/// The file icon used throughout macOS: a semantic Hugeicons glyph in the same stroke
/// language and theme foreground as the Files sidebar's folder icons.
struct FileIconView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let url: URL
    /// Point size of the square icon box.
    var size: CGFloat = 16

    var body: some View {
        HugeIconView(
            icon: ThemedFileIcon.icon(for: url),
            size: size,
            color: settings.chromeTheme(for: colorScheme)?.foreground ?? .primary
        )
    }
}
