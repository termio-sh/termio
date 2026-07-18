import Foundation

/// Semantic file categories rendered with the same Hugeicons stroke language as the
/// Files sidebar. This deliberately favors a small, calm set of recognizable document
/// shapes over per-language vendor logos, which compete with termio's terminal theme.
enum ThemedFileIcon {
    static func icon(for url: URL) -> HugeIcon {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()

        if [".gitignore", ".gitattributes", ".gitmodules", ".env", ".editorconfig", ".npmrc",
            "dockerfile", "containerfile", "makefile", "gnumakefile", "cmakelists.txt"].contains(name) {
            return .settings
        }

        switch ext {
        case "swift", "js", "mjs", "cjs", "ts", "mts", "cts", "jsx", "tsx", "py", "pyw", "pyi",
             "rb", "go", "rs", "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "hxx", "m", "mm",
             "java", "kt", "kts", "cs", "php", "dart", "vue", "svelte", "html", "htm", "xhtml",
             "css", "scss", "sass", "less", "lua", "pl", "pm", "r", "scala", "hs", "lhs", "ex",
             "exs", "erl", "hrl", "clj", "cljs", "elm", "ml", "mli", "fs", "fsx", "groovy", "jl",
             "nim", "cr", "zig", "sol", "coffee", "purs", "hx", "f", "f90", "f95", "cob", "cbl",
             "tex", "ltx", "mat", "vb", "vbs", "pug", "hbs", "wasm", "wat", "graphql", "gql":
            return .documentCode
        case "sh", "bash", "zsh", "fish", "ksh", "ps1", "bat", "cmd":
            return .terminal
        case "json", "jsonc", "json5", "yml", "yaml", "toml", "ini", "conf", "cfg", "properties",
             "env", "xcconfig", "plist", "lock", "xml", "xsl", "xslt", "xsd", "entitlements":
            return .settings
        case "sql", "sqlite", "sqlite3", "db":
            return .database
        case "md", "markdown", "mdx", "txt", "rst", "rtf", "strings":
            return .file
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp", "ico", "icns", "svg":
            return .image
        case "zip", "tar", "gz", "bz2", "xz", "rar", "7z", "dmg", "iso":
            return .archive
        case "mp3", "wav", "aif", "aiff", "m4a", "flac", "mid":
            return .audio
        case "mp4", "mov", "avi", "mkv", "webm":
            return .video
        default:
            return .file
        }
    }
}
