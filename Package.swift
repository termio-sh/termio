// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "termio",
    platforms: [.macOS(.v14)],
    dependencies: [
        // libghostty (Ghostty's terminal core), via our jiweiyuan/libghostty-swift
        // fork of Lakr233/libghostty-spm (ships the `GhosttyTerminal` Swift wrapper —
        // incl. the host-managed `.inMemory` backend PTYProcess drives — plus a prebuilt
        // GhosttyKit.xcframework, so no zig toolchain here). Same package the iOS app
        // uses, so both platforms track one dependency. The 2026-07 "fork regressed
        // live resize" suspicion that briefly rolled this back to Lakr233 was a
        // misdiagnosis — the real bug was termio's own PTY spawn shape (see
        // docs/bug/terminal-resize-no-reflow-HANDOFF.md §0).
        .package(url: "https://github.com/jiweiyuan/libghostty-swift", from: "1.0.12"),
        // Sparkle powers in-app auto-update (the "Check for Updates…" menu item and
        // background update checks). It reads the appcast published with each GitHub
        // release; the matching EdDSA public key is embedded in packaging/Info.plist.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        // Highlightr (the highlight.js wrapper powering the file editor) is VENDORED
        // at Sources/termio/Editor/Highlightr, not a dependency: `swift build` bakes a
        // dependency's `Bundle.module` accessor with only the .app root + a build-machine
        // path, so CI-built releases crashed on `Highlightr.init` (v0.2.4). See the
        // vendor README.
        // swift-markdown — Apple's cmark-gfm wrapper (the parser behind DocC). Parses
        // agent messages for the session trace; `TraceMarkdown` walks the AST and emits
        // escaped HTML. Apache-2.0.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
        // Code shared with the iOS companion app — the companion wire protocol
        // (roster + control messages) lives here so both ends stay in sync.
        .package(path: "Shared"),
    ],
    targets: [
        .executableTarget(
            name: "termio",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-swift"),
                // The raw libghostty C API. Used by session control to deliver a real
                // Return key event (`ghostty_surface_key`) when driving a sibling.
                .product(name: "GhosttyKit", package: "libghostty-swift"),
                // Bundled color-scheme catalog (Ghostty's built-in themes), used by
                // the appearance settings to offer a theme picker.
                .product(name: "GhosttyTheme", package: "libghostty-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "TermioShared", package: "Shared"),
            ],
            path: "Sources/termio",
            // The vendored Highlightr copy ships its own README; it's documentation, not
            // a build input, so exclude it rather than let SwiftPM flag it as unhandled.
            exclude: ["Editor/Highlightr/README.md"],
            resources: [
                // Vendor favicons resolved by resource name into `AgentIcon.image`.
                .process("Resources"),
                // Devicon language/tool logos (one SVG per file type), loaded by name
                // for the file tree; see LangIconCatalog / LangIconView. Kept as a
                // folder copy (not `.process`) so the lookup subdirectory survives.
                .copy("LangIcons"),
            ],
            swiftSettings: [
                // Relax strict concurrency for the AppKit/SwiftUI glue; the app is
                // single-window and main-actor bound in practice.
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
