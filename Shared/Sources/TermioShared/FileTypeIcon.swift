import SwiftUI

/// A file-type icon: an SF Symbol plus a tint, chosen by file extension. The per-language tints are
/// ported from CodeEdit's `FileIcon` (https://github.com/CodeEditApp/CodeEdit, MIT). Every symbol here
/// must be a real SF Symbol — CodeEdit's `doc.json`/`doc.javascript`/`doc.python`/`doc.ruby` are its own
/// asset-catalog glyphs, not system symbols, so they render blank via `Image(systemName:)`. Most files
/// draw a bundled Devicon instead (see `FileIconView`); this fallback shows only when none is bundled,
/// e.g. `Package.resolved`. Extended with a few extensions CodeEdit doesn't list. Shared so both the
/// editor header and the file tree show the same icon.
public enum FileTypeIcon {
    /// The SF Symbol + tint for a file, keyed by its lowercased extension (special names like
    /// `Dockerfile`/`Makefile`/`LICENSE` are matched too). Falls back to a plain doc in steel.
    public static func icon(for url: URL) -> (symbol: String, color: Color) {
        // Whole-name matches first, for files that carry meaning without an extension.
        switch url.lastPathComponent.lowercased() {
        case "license", "license.md", "license.txt": return ("key.fill", amber)
        case "dockerfile", "containerfile": return ("shippingbox", steel)
        case "makefile", "gnumakefile": return ("terminal", makefileRed)
        case ".gitignore", ".dockerignore", ".npmignore": return ("arrow.triangle.branch", steel)
        case ".env", ".editorconfig", ".npmrc": return ("gearshape.fill", amber)
        default: break
        }

        switch url.pathExtension.lowercased() {
        case "swift": return ("swift", .orange)
        case "js", "mjs", "cjs": return ("j.square", amber)
        case "ts", "mts", "cts": return ("j.square", .blue)
        case "jsx", "tsx": return ("atom", .cyan)
        case "json", "jsonc", "json5", "resolved": return ("curlybraces", scarlet)
        case "yml", "yaml": return ("curlybraces", scarlet)
        case "lock": return ("lock.doc", steel)
        case "py", "pyw", "pyi": return ("p.square", amber)
        case "rb": return ("diamond", scarlet)
        case "go": return ("g.square", goCyan)
        case "rs": return ("r.square", .orange)
        case "c": return ("c.square", .purple)
        case "h": return ("h.square", headerRed)
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx": return ("c.square", .blue)
        case "m", "mm": return ("m.square", objcPurple)
        case "java": return ("cup.and.saucer", .blue)
        case "kt", "kts": return ("k.square", .purple)
        case "cs": return ("number.square", .green)
        case "php": return ("p.square", .indigo)
        case "dart": return ("d.square", goCyan)
        case "vue": return ("v.square", vueGreen)
        case "html", "htm", "xhtml": return ("chevron.left.forwardslash.chevron.right", .orange)
        case "xml", "plist", "svg": return ("chevron.left.forwardslash.chevron.right", steel)
        case "css": return ("curlybraces", .teal)
        case "scss", "sass", "less": return ("curlybraces", .pink)
        case "md", "markdown", "mdx", "txt", "rst": return ("doc.plaintext", steel)
        case "rtf": return ("doc.richtext", steel)
        case "sql": return ("cylinder", .blue)
        case "graphql", "gql": return ("circle.hexagongrid", .pink)
        case "sh", "bash", "zsh", "fish", "ksh", "ps1", "bat", "cmd": return ("terminal", steel)
        case "toml", "ini", "conf", "cfg", "properties", "env", "xcconfig": return ("gearshape.2", steel)
        case "strings": return ("text.quote", scarlet)
        case "entitlements": return ("checkmark.seal", amber)
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp", "ico", "icns":
            return ("photo", .blue)
        case "pdf": return ("doc.richtext", .red)
        case "mp3", "wav", "aif", "aiff", "m4a", "flac", "mid": return ("speaker.wave.2", .pink)
        case "mp4", "mov", "avi", "mkv", "webm": return ("film", .purple)
        default: return ("doc", steel)
        }
    }

    /// The non-code resource categories, for hosts that draw these in their own
    /// icon language instead of the tinted SF Symbol (the Mac file tree renders
    /// them as Hugeicons line glyphs; iOS keeps the symbols). `nil` means the file
    /// is code-shaped and should use `icon(for:)`. Extension sets mirror
    /// `icon(for:)` — keep the two switches in sync.
    public enum ResourceKind {
        case image, pdf, audio, video, plainText, generic
    }

    public static func resourceKind(for url: URL) -> ResourceKind? {
        switch url.lastPathComponent.lowercased() {
        case "license", "license.md", "license.txt", "dockerfile", "containerfile",
             "makefile", "gnumakefile", ".gitignore", ".dockerignore", ".npmignore",
             ".env", ".editorconfig", ".npmrc":
            return nil
        default: break
        }
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp", "ico", "icns":
            return .image
        case "pdf": return .pdf
        case "mp3", "wav", "aif", "aiff", "m4a", "flac", "mid": return .audio
        case "mp4", "mov", "avi", "mkv", "webm": return .video
        case "md", "markdown", "mdx", "txt", "rst", "rtf": return .plainText
        case "swift", "js", "mjs", "cjs", "ts", "mts", "cts", "jsx", "tsx",
             "json", "jsonc", "json5", "resolved", "yml", "yaml", "lock",
             "py", "pyw", "pyi", "rb", "go", "rs", "c", "h",
             "cpp", "cc", "cxx", "hpp", "hh", "hxx", "m", "mm",
             "java", "kt", "kts", "cs", "php", "dart", "vue",
             "html", "htm", "xhtml", "xml", "plist", "svg",
             "css", "scss", "sass", "less", "sql", "graphql", "gql",
             "sh", "bash", "zsh", "fish", "ksh", "ps1", "bat", "cmd",
             "toml", "ini", "conf", "cfg", "properties", "env", "xcconfig",
             "strings", "entitlements":
            return nil
        default: return .generic
        }
    }

    // CodeEdit's named tints (its asset-catalog colors), as close sRGB equivalents.
    private static let amber = Color(.sRGB, red: 0.95, green: 0.66, blue: 0.13)
    private static let scarlet = Color(.sRGB, red: 0.88, green: 0.22, blue: 0.17)
    private static let steel = Color(.sRGB, red: 0.42, green: 0.49, blue: 0.56)
    private static let goCyan = Color(.sRGB, red: 0.02, green: 0.675, blue: 0.757)
    private static let vueGreen = Color(.sRGB, red: 0.255, green: 0.722, blue: 0.514)
    private static let headerRed = Color(.sRGB, red: 0.667, green: 0.031, blue: 0.133)
    private static let objcPurple = Color(.sRGB, red: 0.271, green: 0.106, blue: 0.525)
    private static let makefileRed = Color(.sRGB, red: 0.937, green: 0.325, blue: 0.314)
}
