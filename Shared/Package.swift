// swift-tools-version: 5.9

// TermioShared: code both the macOS app and the iOS companion compile —
// brand vectors, status semantics, and (soon) the companion wire protocol.
// Keep this package UI-framework-light: SwiftUI is fine, AppKit/UIKit only
// behind canImport conditionals.

import PackageDescription

let package = Package(
    name: "TermioShared",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "TermioShared", targets: ["TermioShared"]),
    ],
    dependencies: [
        // Highlightr — the highlight.js wrapper the iOS file viewer uses, so a
        // file opened on the phone colors like the Mac editor. iOS-ONLY: the
        // macOS app vendors these classes instead (Sources/termio/Editor/
        // Highlightr), because with plain `swift build` the dependency's
        // generated `Bundle.module` only checks the .app root + a hardcoded
        // build-machine path and fatalErrors in a packaged release (the v0.2.4
        // open-a-file crash). Xcode-built iOS gets the safe accessor variant.
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
    ],
    targets: [
        .target(
            name: "TermioShared",
            dependencies: [
                .product(name: "Highlightr", package: "Highlightr", condition: .when(platforms: [.iOS])),
            ],
            // Vendor favicon tiles selected by `IconRef.asset`. All PNG: iOS's
            // UIImage can't decode SVG files, so Pi's and Cursor's vector favicons
            // are pre-rasterized at 256px.
            resources: [.process("Resources")]
        ),
    ]
)
