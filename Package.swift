// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "termio",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        // libghostty (Ghostty's terminal core), via our termio-sh/libghostty-swift
        // fork of Lakr233/libghostty-spm (ships the `GhosttyTerminal` Swift wrapper —
        // incl. the host-managed `.inMemory` backend PTYProcess drives — plus a prebuilt
        // GhosttyKit.xcframework, so no zig toolchain here). Same package the iOS app
        // uses, so both platforms track one dependency. The 2026-07 "fork regressed
        // live resize" suspicion that briefly rolled this back to Lakr233 was a
        // misdiagnosis — the real bug was termio's own PTY spawn shape (see
        // docs/bug/terminal-resize-no-reflow-HANDOFF.md §0).
        .package(url: "https://github.com/termio-sh/libghostty-swift", from: "1.0.16"),
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
            exclude: [
                "Editor/Highlightr/README.md",
                // The String Catalog is the *editing* source for UI strings, not a
                // shippable resource: `swift build` can't compile .xcstrings
                // (swiftlang/swift-package-manager#6993), so scripts/compile-strings.sh
                // compiles it into Resources/Localization, which ships instead.
                "Resources/Localizable.xcstrings",
            ],
            resources: [
                // Process app assets into the resource-bundle root so existing
                // name-based lookups stay stable. Agent manifests are copied as a
                // directory because the catalog intentionally enumerates only it —
                // and that directory is coding agents only. The plain shell is a
                // session kind, not a manageable agent, so its manifest sits apart at
                // the bundle root, loaded by name (see AgentCatalog.loadBundledShell).
                .process("Resources/assets"),
                // The Markdown reader's prose face (iA Writer Quattro V, variable
                // wght 400–700), embedded into the reader HTML as base64 @font-face
                // by `MarkdownReaderRenderer`. `.process` flattens the woff2s to the
                // bundle root, where the name-based lookup expects them.
                .process("Resources/Fonts"),
                .copy("Resources/agents"),
                .copy("Resources/terminal.json"),
                // UI strings: per-language .lproj folders generated from the String
                // Catalog by scripts/compile-strings.sh. Every lookup must pass
                // `Bundle.termioResources` explicitly — `String(localized:)`'s
                // default of `Bundle.main` holds no strings in a packaged .app.
                // Each .lproj is a verbatim `.copy`, one entry per language:
                // `.process` lowercases the folder to `zh-hans.lproj`, and
                // CFBundle's language matching is case-sensitive about the script
                // subtag, so a processed zh-Hans silently resolves to English.
                .copy("Resources/Localization/en.lproj"),
                .copy("Resources/Localization/zh-Hans.lproj"),
                // Agent skills installed into ~/.claude/skills and ~/.codex/skills
                // by SessionSkillInstaller, kept as real markdown files. Folder copy
                // so the skill-folder layout survives into the bundle.
                .copy("Resources/skills"),
                // Devicon language/tool logos (one SVG per file type), loaded by name
                // for the file tree; see LangIconCatalog / LangIconView. Kept as a
                // folder copy (not `.process`) so the lookup subdirectory survives.
                .copy("LangIcons"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "termioTests",
            dependencies: [
                "termio",
                // The shared diff model the iOS reader parses with — pure logic,
                // so it is tested here rather than in an Xcode-only test bundle.
                .product(name: "TermioShared", package: "Shared"),
            ],
            path: "Tests/termioTests",
            // The Markdown feature sheet is both the end-to-end fixture
            // `MarkdownFeatureSheetTests` renders and the document to open in the
            // reader when judging the result by eye.
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
