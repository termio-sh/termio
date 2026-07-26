// Brand vectors shared by the macOS sidebar and the iOS session list, so both
// platforms render the same marks from the same SVG data: agent logos (filled
// vendor marks), Hugeicons stroke glyphs, and the SVG path parser under them.
// Ported from the desktop app's BrandIcons.swift; the desktop still carries
// its own copy until it migrates onto this package.

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Icon reference

/// The data-shaped icon description shared by manifests and the companion wire.
/// Every field is optional so older peers decode additions and an empty reference
/// naturally falls back to the terminal glyph.
public struct IconRef: Codable, Sendable, Equatable {
    public var vector: String?
    public var asset: String?
    public var png: String?
    public var symbol: String?

    public init(
        vector: String? = nil,
        asset: String? = nil,
        png: String? = nil,
        symbol: String? = nil
    ) {
        self.vector = vector
        self.asset = asset
        self.png = png
        self.symbol = symbol
    }
}

public extension Color {
    /// Pure black in light mode, pure white in dark mode, at full opacity —
    /// keeps a monochrome brand mark at original strength (unlike `.primary`,
    /// the ~85%-opacity label color).
    static let monochromeInk: Color = {
        #if canImport(UIKit)
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? .white : .black
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
        })
        #endif
    }()
}

// MARK: - Agent icon

/// A session's leading mark at rest: the vendor logo (the working spinner is
/// composed by the row, not here).
public struct AgentIconView: View {
    let ref: IconRef
    let size: CGFloat
    let tint: Color

    public init(ref: IconRef, size: CGFloat = 13, tint: Color = .monochromeInk) {
        self.ref = ref
        self.size = size
        self.tint = tint
    }

    @ViewBuilder
    public var body: some View {
        if let png = ref.png, let image = Self.image(base64: png) {
            imageTile(image)
        } else if let vector = ref.vector, let logo = BrandLogo(reference: vector) {
            BrandLogoShape(logo: logo)
                .fill(logo.tint, style: FillStyle(eoFill: logo.usesEvenOddFill))
                .frame(width: size, height: size)
        } else if let asset = ref.asset, !asset.isEmpty {
            BrandImageView(resourceName: asset, size: size)
        } else if let symbol = ref.symbol, !symbol.isEmpty {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(tint)
        } else {
            HugeIconView(icon: .terminal, size: size, color: .monochromeInk)
        }
    }

    private func imageTile(_ image: Image) -> some View {
        image
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private static func image(base64: String) -> Image? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }
}

// MARK: - Brand favicon tiles

/// A vendor brand mark carried as its real favicon image (the marks whose
/// detail — Pi's monochrome glyph, OpenCode's two-tone box, Cursor's shaded
/// cube — a single-fill vector path can't reproduce), bundled under this
/// package's `Resources`. The resource name arrives as data instead of an enum,
/// so adding an agent never adds an icon switch.
public struct BrandImageView: View {
    let resourceName: String
    let size: CGFloat

    public init(resourceName: String, size: CGFloat) {
        self.resourceName = resourceName
        self.size = size
    }

    public var body: some View {
        if let image = loadImage() {
            image
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            // The name arrived over the wire from a peer whose bundle may not
            // match ours (an older Mac naming an asset this build dropped) —
            // degrade to the terminal glyph, visibly, never an invisible tile.
            HugeIconView(icon: .terminal, size: size, color: .monochromeInk)
        }
    }

    /// Loads the bundled favicon, or `nil` if it is missing.
    ///
    /// iOS-ONLY on purpose: `Bundle.module` is safe there because the app is
    /// built by Xcode, whose generated accessor resolves the resource bundle
    /// correctly. The macOS app is built with plain `swift build`, where the
    /// generated accessor checks only the .app root plus a hardcoded
    /// build-machine path and fatalErrors in a packaged release (the v0.2.4
    /// crash) — so the desktop must never reach this and keeps loading its own
    /// favicon copies from `Bundle.termioResources`.
    private func loadImage() -> Image? {
        #if canImport(UIKit)
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path)
        else { return nil }
        return Image(uiImage: image)
        #else
        return nil
        #endif
    }
}

// MARK: - Vector data

/// A Hugeicons stroke glyph, stored as its source SVG path data on a 24×24
/// viewBox, drawn as a rounded *stroke* by `HugeIconShape` (Hugeicons' 1.5px
/// line style). Multiple `<path>` elements are concatenated into one data
/// string — each starts with `M`, so the parser treats them as subpaths.
public enum HugeIcon: Hashable, Sendable {
    case terminal
    case folder
    case folderOpen
    case chevronRight
    case edit
    case view
    case settings
    case paintBrush
    case sidebarLeft
    case serverStack
    case keyboard
    case bot
    case dashboardSpeed
    case smartPhone
    case network
    case gitBranch
    case key
    case fileDoc
    case download
    case infoCircle
    case search
    case wireless
    case listBullet
    case copy
    case clock
    case bubbleChatAdd
    case listView
    case fileQuestion
    case checkCircle
    case layoutColumns
    case layoutRows
    case expand
    case square
    case plusSquare
    case sidebarRight
    case refresh
    case cursorDisabled
    case arrowsLeftRight
    case textFont
    case image
    case filePdf
    case fileText
    case fileAudio
    case fileVideo
    case bubbleChat
    case add
    case link
    case qrCode
    case devicePair
    case wifiError
    case inbox

    /// Side length of the source SVG's square viewBox (Hugeicons uses 24).
    public var viewBox: CGFloat { 24 }

    public var pathData: String {
        switch self {
        case .terminal:
            return "M7.5 7.5L8.72654 8.55719C9.24218 9.00163 9.5 9.22386 9.5 9.5C9.5 9.77614 9.24218 9.99836 8.72654 10.4428L7.5 11.5 M11.5 12.5H15.5 M12 21C15.7497 21 17.6246 21 18.9389 20.0451C19.3634 19.7367 19.7367 19.3634 20.0451 18.9389C21 17.6246 21 15.7497 21 12C21 8.25027 21 6.3754 20.0451 5.06107C19.7367 4.6366 19.3634 4.26331 18.9389 3.95491C17.6246 3 15.7497 3 12 3C8.25027 3 6.3754 3 5.06107 3.95491C4.6366 4.26331 4.26331 4.6366 3.95491 5.06107C3 6.3754 3 8.25027 3 12C3 15.7497 3 17.6246 3.95491 18.9389C4.26331 19.3634 4.6366 19.7367 5.06107 20.0451C6.3754 21 8.25027 21 12 21Z"
        case .folder:
            return "M8 7H16.75C18.8567 7 19.91 7 20.6667 7.50559C20.9943 7.72447 21.2755 8.00572 21.4944 8.33329C22 9.08996 22 10.1433 22 12.25C22 15.7612 22 17.5167 21.1573 18.7779C20.7926 19.3238 20.3238 19.7926 19.7779 20.1573C18.5167 21 16.7612 21 13.25 21H12C7.28595 21 4.92893 21 3.46447 19.5355C2 18.0711 2 15.714 2 11V7.94427C2 6.1278 2 5.21956 2.38032 4.53806C2.65142 4.05227 3.05227 3.65142 3.53806 3.38032C4.21956 3 5.1278 3 6.94427 3C8.10802 3 8.6899 3 9.19926 3.19101C10.3622 3.62712 10.8418 4.68358 11.3666 5.73313L12 7"
        case .folderOpen:
            // Hugeicons "folder-03": a single smooth rounded tray (the open body)
            // plus a simple tabbed back flap. Chosen over "folder-open" — whose two
            // stacked, flared trapezoids turn muddy at the sidebar's small size —
            // because the one rounded body reads cleanly there and still pairs with
            // folder-01's angled tab for the closed state.
            return "M2.36064 15.1788C1.98502 13.2956 1.79721 12.354 2.33084 11.7159C2.36642 11.6734 2.40405 11.6323 2.44361 11.5927C3.03686 11 4.08674 11 6.1865 11H17.8135C19.9133 11 20.9631 11 21.5564 11.5927C21.5959 11.6323 21.6336 11.6734 21.6692 11.7159C22.2028 12.354 22.015 13.2956 21.6394 15.1788C21.0993 17.8865 20.8292 19.2404 19.8109 20.0721C19.7414 20.1288 19.6698 20.1833 19.5961 20.2354C18.5163 21 17.0068 21 13.9876 21H10.0124C6.99323 21 5.48367 21 4.40387 20.2354C4.33022 20.1833 4.2586 20.1288 4.18914 20.0721C3.17075 19.2404 2.90072 17.8865 2.36064 15.1788Z M4 11V5.5C4 4.11929 5.11929 3 6.5 3H8.92963C9.59834 3 10.2228 3.3342 10.5937 3.8906L12 6M12 6H8.5M12 6H17.5C18.8807 6 20 7.11929 20 8.5V11"
        case .chevronRight:
            // A plain two-segment chevron (not the bulged Hugeicons arrow) — round
            // linejoin softens the tip. The section disclosure arrow: points right when
            // collapsed, rotated a quarter-turn down when open.
            return "M10 6L16 12L10 18"
        case .edit:
            // Hugeicons "edit-02": a pencil over a baseline — the file editor's Edit
            // mode. Two subpaths (nib+body, then the underline).
            return "M14.074 3.885c.745-.807 1.117-1.21 1.513-1.446a3.1 3.1 0 0 1 3.103-.047c.403.224.787.616 1.555 1.4c.768.785 1.152 1.178 1.37 1.589a3.29 3.29 0 0 1-.045 3.17c-.23.404-.625.785-1.416 1.546l-9.403 9.057c-1.498 1.443-2.247 2.164-3.183 2.53s-1.965.338-4.023.285l-.28-.008c-.626-.016-.94-.024-1.121-.231c-.183-.207-.158-.526-.108-1.164l.027-.346c.14-1.796.21-2.694.56-3.502s.956-1.463 2.166-2.774zM13 4l7 7 M14 22h8"
        case .view:
            // Hugeicons "view": an eye (outline + pupil) — the Markdown Preview mode.
            return "M21.544 11.045c.304.426.456.64.456.955c0 .316-.152.529-.456.955C20.178 14.871 16.689 19 12 19c-4.69 0-8.178-4.13-9.544-6.045C2.152 12.529 2 12.315 2 12c0-.316.152-.529.456-.955C3.822 9.129 7.311 5 12 5c4.69 0 8.178 4.13 9.544 6.045Z M15 12a3 3 0 1 0-6 0a3 3 0 0 0 6 0Z"
        case .settings:
            // Hugeicons "settings-02": a gear with a center circle — the General tab.
            return "M15.5 12C15.5 13.933 13.933 15.5 12 15.5C10.067 15.5 8.5 13.933 8.5 12C8.5 10.067 10.067 8.5 12 8.5C13.933 8.5 15.5 10.067 15.5 12Z M21.011 14.0965C21.5329 13.9558 21.7939 13.8854 21.8969 13.7508C22 13.6163 22 13.3998 22 12.9669V11.0332C22 10.6003 22 10.3838 21.8969 10.2493C21.7938 10.1147 21.5329 10.0443 21.011 9.90358C19.0606 9.37759 17.8399 7.33851 18.3433 5.40087C18.4817 4.86799 18.5509 4.60156 18.4848 4.44529C18.4187 4.28902 18.2291 4.18134 17.8497 3.96596L16.125 2.98673C15.7528 2.77539 15.5667 2.66972 15.3997 2.69222C15.2326 2.71472 15.0442 2.90273 14.6672 3.27873C13.208 4.73448 10.7936 4.73442 9.33434 3.27864C8.95743 2.90263 8.76898 2.71463 8.60193 2.69212C8.43489 2.66962 8.24877 2.77529 7.87653 2.98663L6.15184 3.96587C5.77253 4.18123 5.58287 4.28891 5.51678 4.44515C5.45068 4.6014 5.51987 4.86787 5.65825 5.4008C6.16137 7.3385 4.93972 9.37763 2.98902 9.9036C2.46712 10.0443 2.20617 10.1147 2.10308 10.2492C2 10.3838 2 10.6003 2 11.0332V12.9669C2 13.3998 2 13.6163 2.10308 13.7508C2.20615 13.8854 2.46711 13.9558 2.98902 14.0965C4.9394 14.6225 6.16008 16.6616 5.65672 18.5992C5.51829 19.1321 5.44907 19.3985 5.51516 19.5548C5.58126 19.7111 5.77092 19.8188 6.15025 20.0341L7.87495 21.0134C8.24721 21.2247 8.43334 21.3304 8.6004 21.3079C8.76746 21.2854 8.95588 21.0973 9.33271 20.7213C10.7927 19.2644 13.2088 19.2643 14.6689 20.7212C15.0457 21.0973 15.2341 21.2853 15.4012 21.3078C15.5682 21.3303 15.7544 21.2246 16.1266 21.0133L17.8513 20.034C18.2307 19.8187 18.4204 19.711 18.4864 19.5547C18.5525 19.3984 18.4833 19.132 18.3448 18.5991C17.8412 16.6616 19.0609 14.6226 21.011 14.0965Z"
        case .paintBrush:
            // Hugeicons "paint-brush-01": an angled brush with two bristle ticks —
            // the Appearance tab.
            return "M3.89089 20.8727L3 21L3.12727 20.1091C3.32086 18.754 3.41765 18.0764 3.71832 17.4751C4.01899 16.8738 4.50296 16.3898 5.47091 15.4218L16.9827 3.91009C17.4062 3.48654 17.618 3.27476 17.8464 3.16155C18.2811 2.94615 18.7914 2.94615 19.2261 3.16155C19.4546 3.27476 19.6663 3.48654 20.0899 3.91009C20.5135 4.33365 20.7252 4.54543 20.8385 4.77389C21.0539 5.20856 21.0539 5.71889 20.8385 6.15356C20.7252 6.38201 20.5135 6.59379 20.0899 7.01735L8.57816 18.5291C7.61022 19.497 7.12625 19.981 6.52491 20.2817C5.92357 20.5823 5.246 20.6791 3.89089 20.8727Z M6 15L9 18M8.5 12.5L11.5 15.5"
        case .sidebarLeft:
            // Hugeicons "sidebar-left": a window with a left rail and two rail rows —
            // the Interface tab.
            return "M2 12C2 8.31087 2 6.4663 2.81382 5.15877C3.1149 4.67502 3.48891 4.25427 3.91891 3.91554C5.08116 3 6.72077 3 10 3H14C17.2792 3 18.9188 3 20.0811 3.91554C20.5111 4.25427 20.8851 4.67502 21.1862 5.15877C22 6.4663 22 8.31087 22 12C22 15.6891 22 17.5337 21.1862 18.8412C20.8851 19.325 20.5111 19.7457 20.0811 20.0845C18.9188 21 17.2792 21 14 21H10C6.72077 21 5.08116 21 3.91891 20.0845C3.48891 19.7457 3.1149 19.325 2.81382 18.8412C2 17.5337 2 15.6891 2 12Z M9.5 3L9.5 21 M5 7H6M5 10H6"
        case .serverStack:
            // Hugeicons "server-stack-01": two rack units with indicator dots — the
            // SSH tab (stands in for SF's "server.rack").
            return "M19 4H5C4.06812 4 3.60218 4 3.23463 4.15224C2.74458 4.35523 2.35523 4.74458 2.15224 5.23463C2 5.60218 2 6.06812 2 7C2 7.93188 2 8.39782 2.15224 8.76537C2.35523 9.25542 2.74458 9.64477 3.23463 9.84776C3.60218 10 4.06812 10 5 10H19C19.9319 10 20.3978 10 20.7654 9.84776C21.2554 9.64477 21.6448 9.25542 21.8478 8.76537C22 8.39782 22 7.93188 22 7C22 6.06812 22 5.60218 21.8478 5.23463C21.6448 4.74458 21.2554 4.35523 20.7654 4.15224C20.3978 4 19.9319 4 19 4Z M19 14H5C4.06812 14 3.60218 14 3.23463 14.1522C2.74458 14.3552 2.35523 14.7446 2.15224 15.2346C2 15.6022 2 16.0681 2 17C2 17.9319 2 18.3978 2.15224 18.7654C2.35523 19.2554 2.74458 19.6448 3.23463 19.8478C3.60218 20 4.06812 20 5 20H19C19.9319 20 20.3978 20 20.7654 19.8478C21.2554 19.6448 21.6448 19.2554 21.8478 18.7654C22 18.3978 22 17.9319 22 17C22 16.0681 22 15.6022 21.8478 15.2346C21.6448 14.7446 21.2554 14.3552 20.7654 14.1522C20.3978 14 19.9319 14 19 14Z M6.125 7H6 M10.125 7H10 M6.125 17H6 M10.125 17H10"
        case .keyboard:
            // Hugeicons "keyboard": a keyboard with key ticks, a space bar, and a
            // cable stub — the Keyboard tab.
            return "M14.5 7H9.5C6.21252 7 4.56878 7 3.46243 7.90796C3.25989 8.07418 3.07418 8.25989 2.90796 8.46243C2 9.56878 2 11.2125 2 14.5C2 17.7875 2 19.4312 2.90796 20.5376C3.07418 20.7401 3.25989 20.9258 3.46243 21.092C4.56878 22 6.21252 22 9.5 22H14.5C17.7875 22 19.4312 22 20.5376 21.092C20.7401 20.9258 20.9258 20.7401 21.092 20.5376C22 19.4312 22 17.7875 22 14.5C22 11.2125 22 9.56878 21.092 8.46243C20.9258 8.25989 20.7401 8.07418 20.5376 7.90796C19.4312 7 17.7875 7 14.5 7Z M12 7V5C12 4.44772 12.4477 4 13 4C13.5523 4 14 3.55228 14 3V2 M7 12L8 12 M11.5 12L12.5 12 M16 12L17 12 M7 17L17 17"
        case .bot:
            // Hugeicons "bot": a robot head with antenna, ears, eyes, and mouth —
            // the Agents tab.
            return "M13 7H11C8.19108 7 6.78661 7 5.77772 7.67412C5.34096 7.96596 4.96596 8.34096 4.67412 8.77772C4 9.78661 4 11.1911 4 14C4 16.8089 4 18.2134 4.67412 19.2223C4.96596 19.659 5.34096 20.034 5.77772 20.3259C6.78661 21 8.19108 21 11 21H13C15.8089 21 17.2134 21 18.2223 20.3259C18.659 20.034 19.034 19.659 19.3259 19.2223C20 18.2134 20 16.8089 20 14C20 11.1911 20 9.78661 19.3259 8.77772C19.034 8.34096 18.659 7.96596 18.2223 7.67412C17.2134 7 15.8089 7 13 7Z M4 14H2 M10 17H14 M22 14H20 M15 11V13 M9 11V13 M12 7C12 5.11438 12 4.17157 11.4142 3.58579C10.8284 3 9.88562 3 8 3"
        case .dashboardSpeed:
            // Hugeicons "dashboard-speed-02": an open gauge arc with a needle and
            // pivot circle (no enclosing box) — the Usage tab. The source's
            // `<circle>` element is transcribed as two arc subpath halves.
            return "M15 18a3 3 0 1 0-6 0a3 3 0 0 0 6 0Z M12 15V10 M22 13C22 7.47715 17.5228 3 12 3C6.47715 3 2 7.47715 2 13"
        case .smartPhone:
            // Hugeicons "smart-phone-01": a phone body with a home-indicator dot —
            // the Mobile tab.
            return "M13.5 2H10.5C8.14298 2 6.96447 2 6.23223 2.73223C5.5 3.46447 5.5 4.64298 5.5 7V17C5.5 19.357 5.5 20.5355 6.23223 21.2678C6.96447 22 8.14298 22 10.5 22H13.5C15.857 22 17.0355 22 17.7678 21.2678C18.5 20.5355 18.5 19.357 18.5 17V7C18.5 4.64298 18.5 3.46447 17.7678 2.73223C17.0355 2 15.857 2 13.5 2Z M12.125 19H12"
        case .network:
            // Hugeicons "internet": a line globe — a remote/SSH link.
            return "M22 12a10 10 0 1 0 -20 0a10 10 0 0 0 20 0Z M16 12a4 10 0 1 0 -8 0a4 10 0 0 0 8 0Z M2 12H22"
        case .gitBranch:
            // Hugeicons "git-branch": commit dots on a branching lane — worktrees, session control, and the Changes segment.
            return "M7 19H13C15.8284 19 17.2426 19 18.1213 18.1213C19 17.2426 19 15.8284 19 13V10M19 10C19.7002 10 21.0085 11.9943 21.5 12.5M19 10C18.2998 10 16.9915 11.9943 16.5 12.5 M5 7L5 17 M7 5a2 2 0 1 0 -4 0a2 2 0 0 0 4 0Z M21 5a2 2 0 1 0 -4 0a2 2 0 0 0 4 0Z M7 19a2 2 0 1 0 -4 0a2 2 0 0 0 4 0Z"
        case .key:
            // Hugeicons "key-01": a round-bow key — SSH public keys and identity hints.
            return "M15.5 14.5C18.8137 14.5 21.5 11.8137 21.5 8.5C21.5 5.18629 18.8137 2.5 15.5 2.5C12.1863 2.5 9.5 5.18629 9.5 8.5C9.5 9.38041 9.68962 10.2165 10.0303 10.9697L2.5 18.5V21.5H5.5V19.5H7.5V17.5H9.5L13.0303 13.9697C13.7835 14.3104 14.6196 14.5 15.5 14.5Z M17.5 6.5L16.5 7.5"
        case .fileDoc:
            // Hugeicons "file-02": a dog-eared document — config files, file rows, and text-diff empty states.
            return "M8 17H16 M8 13H12 M13 2.5V3C13 5.82843 13 7.24264 13.8787 8.12132C14.7574 9 16.1716 9 19 9H19.5M20 10.6569V14C20 17.7712 20 19.6569 18.8284 20.8284C17.6569 22 15.7712 22 12 22C8.22876 22 6.34315 22 5.17157 20.8284C4 19.6569 4 17.7712 4 14V9.45584C4 6.21082 4 4.58831 4.88607 3.48933C5.06508 3.26731 5.26731 3.06508 5.48933 2.88607C6.58831 2 8.21082 2 11.4558 2C12.1614 2 12.5141 2 12.8372 2.11401C12.9044 2.13772 12.9702 2.165 13.0345 2.19575C13.3436 2.34355 13.593 2.593 14.0919 3.09188L18.8284 7.82843C19.4065 8.40649 19.6955 8.69552 19.8478 9.06306C20 9.4306 20 9.83935 20 10.6569Z"
        case .download:
            // Hugeicons "download-01": a down arrow into a tray — agent install links.
            return "M2.99969 17.0002C2.99969 17.9302 2.99969 18.3952 3.10192 18.7767C3.37932 19.8119 4.18796 20.6206 5.22324 20.898C5.60474 21.0002 6.06972 21.0002 6.99969 21.0002L16.9997 21.0002C17.9297 21.0002 18.3947 21.0002 18.7762 20.898C19.8114 20.6206 20.6201 19.8119 20.8975 18.7767C20.9997 18.3952 20.9997 17.9302 20.9997 17.0002 M16.4998 11.5002C16.4998 11.5002 13.1856 16.0002 11.9997 16.0002C10.8139 16.0002 7.49976 11.5002 7.49976 11.5002M11.9997 15.0002V3.00016"
        case .infoCircle:
            // Hugeicons "information-circle": the inspector Info segment and its empty state.
            return "M22 12a10 10 0 1 0 -20 0a10 10 0 0 0 20 0Z M12 16V12 M12.125 8.25H12M12.25 8.25C12.25 8.11193 12.1381 8 12 8C11.8619 8 11.75 8.11193 11.75 8.25C11.75 8.38807 11.8619 8.5 12 8.5C12.1381 8.5 12.25 8.38807 12.25 8.25Z"
        case .search:
            // Hugeicons "search-01": a magnifier — the inspector Search segment.
            return "M17 17L21 21 M19 11C19 6.58172 15.4183 3 11 3C6.58172 3 3 6.58172 3 11C3 15.4183 6.58172 19 11 19C15.4183 19 19 15.4183 19 11Z"
        case .wireless:
            // Hugeicons "wireless": radio waves over a base — live agent status hooks.
            return "M14.5 11H9.5C7.6341 11 6.70115 11 5.98141 11.3466C5.26703 11.6906 4.69063 12.267 4.34661 12.9814C4 13.7011 4 14.6341 4 16.5C4 18.3659 4 19.2989 4.34661 20.0186C4.69063 20.733 5.26703 21.3094 5.98141 21.6534C6.70115 22 7.6341 22 9.5 22H14.5C16.3659 22 17.2989 22 18.0186 21.6534C18.733 21.3094 19.3094 20.733 19.6534 20.0186C20 19.2989 20 18.3659 20 16.5C20 14.6341 20 13.7011 19.6534 12.9814C19.3094 12.267 18.733 11.6906 18.0186 11.3466C17.2989 11 16.3659 11 14.5 11Z M13 15H16 M9.5 6.99002C10.2106 6.42455 11.0929 6.11744 12.0018 6.11926C12.9106 6.12107 13.7917 6.4317 14.5 7M7 3.7515C8.4189 2.61774 10.1824 2 12 2C13.8176 2 15.5811 2.61774 17 3.7515"
        case .listBullet:
            // Hugeicons "left-to-right-list-bullet": a bulleted list — the inspector Files segment.
            return "M8 5.5L20 5.5 M8 12.5L20 12.5 M8 19.5L20 19.5 M4.375 5.5H4.25M4.5 5.5C4.5 5.63807 4.38807 5.75 4.25 5.75C4.11193 5.75 4 5.63807 4 5.5C4 5.36193 4.11193 5.25 4.25 5.25C4.38807 5.25 4.5 5.36193 4.5 5.5Z M4.375 12.5H4.25M4.5 12.5C4.5 12.6381 4.38807 12.75 4.25 12.75C4.11193 12.75 4 12.6381 4 12.5C4 12.3619 4.11193 12.25 4.25 12.25C4.38807 12.25 4.5 12.3619 4.5 12.5Z M4.375 19.5H4.25M4.5 19.5C4.5 19.6381 4.38807 19.75 4.25 19.75C4.11193 19.75 4 19.6381 4 19.5C4 19.3619 4.11193 19.25 4.25 19.25C4.38807 19.25 4.5 19.3619 4.5 19.5Z"
        case .copy:
            // Hugeicons "copy-01": stacked sheets — Copy Path rows.
            return "M9 15C9 12.1716 9 10.7574 9.87868 9.87868C10.7574 9 12.1716 9 15 9L16 9C18.8284 9 20.2426 9 21.1213 9.87868C22 10.7574 22 12.1716 22 15V16C22 18.8284 22 20.2426 21.1213 21.1213C20.2426 22 18.8284 22 16 22H15C12.1716 22 10.7574 22 9.87868 21.1213C9 20.2426 9 18.8284 9 16L9 15Z M16.9999 9C16.9975 6.04291 16.9528 4.51121 16.092 3.46243C15.9258 3.25989 15.7401 3.07418 15.5376 2.90796C14.4312 2 12.7875 2 9.5 2C6.21252 2 4.56878 2 3.46243 2.90796C3.25989 3.07417 3.07418 3.25989 2.90796 3.46243C2 4.56878 2 6.21252 2 9.5C2 12.7875 2 14.4312 2.90796 15.5376C3.07417 15.7401 3.25989 15.9258 3.46243 16.092C4.51121 16.9528 6.04291 16.9975 9 16.9999"
        case .clock:
            // Hugeicons "clock-01": history empty state and recent-project palette rows.
            return "M22 12a10 10 0 1 0 -20 0a10 10 0 0 0 20 0Z M12 8V12L14 14"
        case .bubbleChatAdd:
            // Hugeicons "bubble-chat-add": a chat bubble with a plus — New Chat.
            return "M21.5 12C21.5 17.2467 17.2467 21.5 12 21.5C10.3719 21.5 8.8394 21.0904 7.5 20.3687C5.63177 19.362 4.37462 20.2979 3.26592 20.4658C3.09774 20.4913 2.93024 20.4302 2.80997 20.31C2.62741 20.1274 2.59266 19.8451 2.6935 19.6074C3.12865 18.5818 3.5282 16.6382 2.98341 15C2.6698 14.057 2.5 13.0483 2.5 12C2.5 6.75329 6.75329 2.5 12 2.5C17.2467 2.5 21.5 6.75329 21.5 12Z M15.5 12H8.5M12 8.5V15.5"
        case .listView:
            // Hugeicons "list-view": stacked full-width rows — View Trace.
            return "M2 11.4C2 10.2417 2.24173 10 3.4 10H20.6C21.7583 10 22 10.2417 22 11.4V12.6C22 13.7583 21.7583 14 20.6 14H3.4C2.24173 14 2 13.7583 2 12.6V11.4Z M2 3.4C2 2.24173 2.24173 2 3.4 2H20.6C21.7583 2 22 2.24173 22 3.4V4.6C22 5.75827 21.7583 6 20.6 6H3.4C2.24173 6 2 5.75827 2 4.6V3.4Z M2 19.4C2 18.2417 2.24173 18 3.4 18H20.6C21.7583 18 22 18.2417 22 19.4V20.6C22 21.7583 21.7583 22 20.6 22H3.4C2.24173 22 2 21.7583 2 20.6V19.4Z"
        case .fileQuestion:
            // Hugeicons "file-unknown": a document with a question mark — the not-text editor state.
            return "M7 11V11.5M5 4C5 2.89543 5.89543 2 7 2C8.07458 2 9 2.80976 9 3.91898C9 4.29783 8.88786 4.66821 8.67771 4.98344L7.5547 6.66795C7.19301 7.21049 7 7.84795 7 8.5 M4 12L4 14.5442C4 17.7892 4 19.4117 4.88607 20.5107C5.06508 20.7327 5.26731 20.9349 5.48933 21.1139C6.58831 22 8.21082 22 11.4558 22C12.1614 22 12.5141 22 12.8372 21.886C12.9044 21.8623 12.9702 21.835 13.0345 21.8043C13.3436 21.6564 13.593 21.407 14.0919 20.9081L18.8284 16.1716C19.4065 15.5935 19.6955 15.3045 19.8478 14.9369C20 14.5694 20 14.1606 20 13.3431V10C20 6.22876 20 4.34315 18.8284 3.17157C17.6569 2 15.7712 2 12 2M13 21.5V21C13 18.1716 13 16.7574 13.8787 15.8787C14.7574 15 16.1716 15 19 15H19.5"
        case .checkCircle:
            // Hugeicons "checkmark-circle-02": clean-working-tree empty state.
            return "M22 12C22 6.47715 17.5228 2 12 2C6.47715 2 2 6.47715 2 12C2 17.5228 6.47715 22 12 22C17.5228 22 22 17.5228 22 12Z M8 12.5L10.5 15L16 9"
        case .layoutColumns:
            // Hugeicons "layout-2-column": a box split into two columns — Split Right.
            return "M3.89124 3.89124C5.28249 2.5 7.52166 2.5 12 2.5C16.4783 2.5 18.7175 2.5 20.1088 3.89124C21.5 5.28249 21.5 7.52166 21.5 12C21.5 16.4783 21.5 18.7175 20.1088 20.1088C18.7175 21.5 16.4783 21.5 12 21.5C7.52166 21.5 5.28249 21.5 3.89124 20.1088C2.5 18.7175 2.5 16.4783 2.5 12C2.5 7.52166 2.5 5.28249 3.89124 3.89124Z M12 2.5V21.5"
        case .layoutRows:
            // Hugeicons "layout-2-row": a box split into two rows — Split Down.
            return "M20.1088 3.89124C21.5 5.28249 21.5 7.52166 21.5 12C21.5 16.4783 21.5 18.7175 20.1088 20.1088C18.7175 21.5 16.4783 21.5 12 21.5C7.52166 21.5 5.28249 21.5 3.89124 20.1088C2.5 18.7175 2.5 16.4783 2.5 12C2.5 7.52166 2.5 5.28249 3.89124 3.89124C5.28249 2.5 7.52166 2.5 12 2.5C16.4783 2.5 18.7175 2.5 20.1088 3.89124Z M21.5 12L2.50078 12"
        case .expand:
            // Hugeicons "arrow-expand-01": diagonal out-arrows — Zoom Split.
            return "M16.4999 3.26621C17.3443 3.25421 20.1408 2.67328 20.7337 3.26621C21.3266 3.85913 20.7457 6.65559 20.7337 7.5M20.5059 3.49097L13.5021 10.4961 M3.26636 16.5001C3.25436 17.3445 2.67343 20.141 3.26636 20.7339C3.85928 21.3268 6.65574 20.7459 7.50015 20.7339M10.502 13.4976L3.49824 20.5027"
        case .square:
            // Hugeicons "square": a bare rounded pane — Close Pane.
            return "M2.5 12C2.5 7.52166 2.5 5.28249 3.89124 3.89124C5.28249 2.5 7.52166 2.5 12 2.5C16.4783 2.5 18.7175 2.5 20.1088 3.89124C21.5 5.28249 21.5 7.52166 21.5 12C21.5 16.4783 21.5 18.7175 20.1088 20.1088C18.7175 21.5 16.4783 21.5 12 21.5C7.52166 21.5 5.28249 21.5 3.89124 20.1088C2.5 18.7175 2.5 16.4783 2.5 12Z"
        case .plusSquare:
            // Hugeicons "plus-sign-square": a plus in a rounded box — New Terminal.
            return "M2.5 12C2.5 7.52166 2.5 5.28249 3.89124 3.89124C5.28249 2.5 7.52166 2.5 12 2.5C16.4783 2.5 18.7175 2.5 20.1088 3.89124C21.5 5.28249 21.5 7.52166 21.5 12C21.5 16.4783 21.5 18.7175 20.1088 20.1088C18.7175 21.5 16.4783 21.5 12 21.5C7.52166 21.5 5.28249 21.5 3.89124 20.1088C2.5 18.7175 2.5 16.4783 2.5 12Z M12 8V16M16 12H8"
        case .sidebarRight:
            // Hugeicons "sidebar-right": the trailing-inspector twin of sidebar-left — Toggle Project Files.
            return "M2 12C2 8.3109 2 6.46633 2.81382 5.1588C3.1149 4.67505 3.48891 4.2543 3.91891 3.91557C5.08116 3.00003 6.72077 3.00003 10 3.00003H14C17.2792 3.00003 18.9188 3.00003 20.0811 3.91557C20.5111 4.2543 20.8851 4.67505 21.1862 5.1588C22 6.46633 22 8.3109 22 12C22 15.6892 22 17.5337 21.1862 18.8413C20.8851 19.325 20.5111 19.7458 20.0811 20.0845C18.9188 21 17.2792 21 14 21H10C6.72077 21 5.08116 21 3.91891 20.0845C3.48891 19.7458 3.1149 19.325 2.81382 18.8413C2 17.5337 2 15.6892 2 12Z M14.5 3.00003L14.5 21 M18 7.00006H19M18 10.0001H19"
        case .refresh:
            // Hugeicons "refresh": a circular arrow — Check for Updates.
            return "M20.0092 2V5.13219C20.0092 5.42605 19.6418 5.55908 19.4537 5.33333C17.6226 3.2875 14.9617 2 12 2C6.47715 2 2 6.47715 2 12C2 17.5228 6.47715 22 12 22C17.5228 22 22 17.5228 22 12"
        case .cursorDisabled:
            // Hugeicons "cursor-disabled-02": the dev-only focus fault injector.
            return "M8.0469 3.44865L13.4101 5.54728L13.4101 5.54728C16.5034 6.75771 18.05 7.36293 17.9988 8.32296C17.9475 9.28299 16.3334 9.7232 13.1051 10.6036C12.1439 10.8658 11.6633 10.9969 11.3301 11.3301C10.9969 11.6633 10.8658 12.1439 10.6036 13.1051C9.7232 16.3334 9.28299 17.9475 8.32296 17.9988C7.36293 18.05 6.75771 16.5034 5.54728 13.4101L5.54728 13.4101L3.44865 8.0469C2.18138 4.80831 1.54774 3.18901 2.36837 2.36837C3.18901 1.54774 4.80831 2.18138 8.0469 3.44865Z M14.318 20.682C16.0754 22.4393 18.9246 22.4393 20.682 20.682C22.4393 18.9246 22.4393 16.0754 20.682 14.318M14.318 20.682C12.5607 18.9246 12.5607 16.0754 14.318 14.318C16.0754 12.5607 18.9246 12.5607 20.682 14.318M14.318 20.682L20.682 14.318"
        case .arrowsLeftRight:
            // Hugeicons "arrow-data-transfer-horizontal": opposing arrows — the pane-focus verbs.
            return "M19 9H6.65856C5.65277 9 5.14987 9 5.02472 8.69134C4.89957 8.38268 5.25517 8.01942 5.96637 7.29289L8.21091 5 M5 15H17.3414C18.3472 15 18.8501 15 18.9753 15.3087C19.1004 15.6173 18.7448 15.9806 18.0336 16.7071L15.7891 19"
        case .textFont:
            // Hugeicons "text-font": an Aa specimen — the font-size verbs.
            return "M14 19L11.1069 10.7479C9.76348 6.91597 9.09177 5 8 5C6.90823 5 6.23652 6.91597 4.89309 10.7479L2 19M4.5 12H11.5 M21.9692 13.9392V18.4392M21.9692 13.9392C22.0164 13.1161 22.0182 12.4891 21.9194 11.9773C21.6864 10.7709 20.4258 10.0439 19.206 9.89599C18.0385 9.75447 17.1015 10.055 16.1535 11.4363M21.9692 13.9392L19.1256 13.9392C18.6887 13.9392 18.2481 13.9603 17.8272 14.0773C15.2545 14.7925 15.4431 18.4003 18.0233 18.845C18.3099 18.8944 18.6025 18.9156 18.8927 18.9026C19.5703 18.8724 20.1955 18.545 20.7321 18.1301C21.3605 17.644 21.9692 16.9655 21.9692 15.9392V13.9392Z"
        case .image:
            // Hugeicons "image-02": a framed landscape — raster image files.
            return "M3 16L7.46967 11.5303C7.80923 11.1908 8.26978 11 8.75 11C9.23022 11 9.69077 11.1908 10.0303 11.5303L14 15.5M15.5 17L14 15.5M21 16L18.5303 13.5303C18.1908 13.1908 17.7302 13 17.25 13C16.7698 13 16.3092 13.1908 15.9697 13.5303L14 15.5 M15.5 8C15.7761 8 16 7.77614 16 7.5C16 7.22386 15.7761 7 15.5 7M15.5 8C15.2239 8 15 7.77614 15 7.5C15 7.22386 15.2239 7 15.5 7M15.5 8V7 M3.69797 19.7472C2.5 18.3446 2.5 16.2297 2.5 12C2.5 7.77027 2.5 5.6554 3.69797 4.25276C3.86808 4.05358 4.05358 3.86808 4.25276 3.69797C5.6554 2.5 7.77027 2.5 12 2.5C16.2297 2.5 18.3446 2.5 19.7472 3.69797C19.9464 3.86808 20.1319 4.05358 20.302 4.25276C21.5 5.6554 21.5 7.77027 21.5 12C21.5 16.2297 21.5 18.3446 20.302 19.7472C20.1319 19.9464 19.9464 20.1319 19.7472 20.302C18.3446 21.5 16.2297 21.5 12 21.5C7.77027 21.5 5.6554 21.5 4.25276 20.302C4.05358 20.1319 3.86808 19.9464 3.69797 19.7472Z"
        case .filePdf:
            // Hugeicons "pdf-01": a dog-eared file with a PDF label.
            return "M20 13V10.6569C20 9.83935 20 9.4306 19.8478 9.06306C19.6955 8.69552 19.4065 8.40649 18.8284 7.82843L14.0919 3.09188C13.593 2.593 13.3436 2.34355 13.0345 2.19575C12.9702 2.165 12.9044 2.13772 12.8372 2.11401C12.5141 2 12.1614 2 11.4558 2C8.21082 2 6.58831 2 5.48933 2.88607C5.26731 3.06508 5.06508 3.26731 4.88607 3.48933C4 4.58831 4 6.21082 4 9.45584V13M13 2.5V3C13 5.82843 13 7.24264 13.8787 8.12132C14.7574 9 16.1716 9 19 9H19.5 M19.75 16H17.25C16.6977 16 16.25 16.4477 16.25 17V19M16.25 19V22M16.25 19H19.25M4.25 22V19.5M4.25 19.5V16H6C6.9665 16 7.75 16.7835 7.75 17.75C7.75 18.7165 6.9665 19.5 6 19.5H4.25ZM10.25 16H11.75C12.8546 16 13.75 16.8954 13.75 18V20C13.75 21.1046 12.8546 22 11.75 22H10.25V16Z"
        case .fileText:
            // Hugeicons "txt-01": a dog-eared file with a TXT label — plain-text files.
            return "M20 13V10.6569C20 9.83935 20 9.4306 19.8478 9.06306C19.6955 8.69552 19.4065 8.40649 18.8284 7.82843L14.0919 3.09188C13.593 2.593 13.3436 2.34355 13.0345 2.19575C12.9702 2.165 12.9044 2.13772 12.8372 2.11401C12.5141 2 12.1614 2 11.4558 2C8.21082 2 6.58831 2 5.48933 2.88607C5.26731 3.06508 5.06508 3.26731 4.88607 3.48933C4 4.58831 4 6.21082 4 9.45584V13M13 2.5V3C13 5.82843 13 7.24264 13.8787 8.12132C14.7574 9 16.1716 9 19 9H19.5 M10 16L12 19M12 19L14 22M12 19L14 16M12 19L10 22M16.5 16H18.2499M18.2499 16H19.9999M18.2499 16V22M4 16H5.74997M5.74997 16H7.49993M5.74997 16V22"
        case .fileAudio:
            // Hugeicons "file-audio": a file with a speaker — audio files.
            return "M20 11C20 11 20 9.4306 19.8478 9.06306C19.6955 8.69552 19.4065 8.40649 18.8284 7.82843L14.0919 3.09188C13.593 2.593 13.3436 2.34355 13.0345 2.19575C12.9702 2.165 12.9044 2.13772 12.8372 2.11401C12.5141 2 12.1614 2 11.4558 2C8.21082 2 6.58831 2 5.48933 2.88607C5.26731 3.06508 5.06508 3.26731 4.88607 3.48933C4 4.58831 4 6.21082 4 9.45584V14C4 17.7712 4 19.6569 5.17157 20.8284C6.34315 22 8.22876 22 12 22M13 2.5V3C13 5.82843 13 7.24264 13.8787 8.12132C14.7574 9 16.1716 9 19 9H19.5 M19.9998 19.4068V16.5932C19.9998 15.0206 19.9998 14.2343 19.46 14.0386C18.9201 13.843 18.2848 14.399 17.0141 15.511L16.5 16H15.0039C14.0611 16 13.5897 16 13.2968 16.2929C13.0039 16.5858 13.0039 17.0572 13.0039 18C13.0039 18.9428 13.0039 19.4142 13.2968 19.7071C13.5897 20 14.0611 20 15.0039 20H16.5L17.0141 20.489C18.2848 21.601 18.9201 22.157 19.46 21.9614C19.9998 21.7657 19.9998 20.9794 19.9998 19.4068Z"
        case .fileVideo:
            // Hugeicons "file-video": a file with a camera — video files.
            return "M19 14.0052V10.6606C19 9.84276 19 9.43383 18.8478 9.06613C18.6955 8.69843 18.4065 8.40927 17.8284 7.83096L13.0919 3.09236C12.593 2.59325 12.3436 2.3437 12.0345 2.19583C11.9702 2.16508 11.9044 2.13778 11.8372 2.11406C11.5141 2 11.1614 2 10.4558 2C7.21082 2 5.58831 2 4.48933 2.88646C4.26731 3.06554 4.06508 3.26787 3.88607 3.48998C3 4.58943 3 6.21265 3 9.45908V14.0052C3 17.7781 3 19.6645 4.17157 20.8366C5.11466 21.7801 6.52043 21.9641 9 22M12 2.50022V3.00043C12 5.83009 12 7.24492 12.8787 8.12398C13.7574 9.00304 15.1716 9.00304 18 9.00304H18.5 M18 19.5L19.4453 20.4635C20.1297 20.9198 20.4719 21.1479 20.7359 21.0066C21 20.8653 21 20.454 21 19.6315V18.3685C21 17.546 21 17.1347 20.7359 16.9934C20.4719 16.8521 20.1297 17.0802 19.4453 17.5365L18 18.5M18 19.5V18.5M18 19.5C18 20.4346 18 20.9019 17.799 21.25C17.6674 21.478 17.478 21.6674 17.25 21.799C16.9019 22 16.4346 22 15.5 22H15C13.5858 22 12.8787 22 12.4393 21.5607C12 21.1213 12 20.4142 12 19C12 17.5858 12 16.8787 12.4393 16.4393C12.8787 16 13.5858 16 15 16H15.5C16.4346 16 16.9019 16 17.25 16.201C17.478 16.3326 17.6674 16.522 17.799 16.75C18 17.0981 18 17.5654 18 18.5"
        case .bubbleChat:
            // Hugeicons "bubble-chat": a round chat bubble with three dots — the
            // iOS Chats tab.
            return "M21.5 12C21.5 17.2467 17.2467 21.5 12 21.5C10.3719 21.5 8.8394 21.0904 7.5 20.3687C5.63177 19.362 4.37462 20.2979 3.26592 20.4658C3.09774 20.4913 2.93024 20.4302 2.80997 20.31C2.62741 20.1274 2.59266 19.8451 2.6935 19.6074C3.12865 18.5818 3.5282 16.6382 2.98341 15C2.6698 14.057 2.5 13.0483 2.5 12C2.5 6.75329 6.75329 2.5 12 2.5C17.2467 2.5 21.5 6.75329 21.5 12Z M12.1257 12H12.0007M8.125 12H8M16.125 12H16"
        case .add:
            // Hugeicons PlusSign: a centered plus, same stroke family as the
            // tab pill and sidebar glyphs it sits beside.
            return "M12 4V20 M4 12H20"
        case .link:
            // Hugeicons "link-01": interlocked chain links — the iOS connection-status row.
            return "M9.14339 10.691L9.35031 10.4841C11.329 8.50532 14.5372 8.50532 16.5159 10.4841C18.4947 12.4628 18.4947 15.671 16.5159 17.6497L13.6497 20.5159C11.671 22.4947 8.46279 22.4947 6.48405 20.5159C4.50532 18.5372 4.50532 15.329 6.48405 13.3503L6.9484 12.886 M17.0516 11.114L17.5159 10.6497C19.4947 8.67095 19.4947 5.46279 17.5159 3.48405C15.5372 1.50532 12.329 1.50532 10.3503 3.48405L7.48405 6.35031C5.50532 8.32904 5.50532 11.5372 7.48405 13.5159C9.46279 15.4947 12.671 15.4947 14.6497 13.5159L14.8566 13.309"
        case .qrCode:
            // Hugeicons "qr-code": the iOS pairing scanner row.
            return "M3 6C3 4.58579 3 3.87868 3.43934 3.43934C3.87868 3 4.58579 3 6 3C7.41421 3 8.12132 3 8.56066 3.43934C9 3.87868 9 4.58579 9 6C9 7.41421 9 8.12132 8.56066 8.56066C8.12132 9 7.41421 9 6 9C4.58579 9 3.87868 9 3.43934 8.56066C3 8.12132 3 7.41421 3 6Z M3 18C3 16.5858 3 15.8787 3.43934 15.4393C3.87868 15 4.58579 15 6 15C7.41421 15 8.12132 15 8.56066 15.4393C9 15.8787 9 16.5858 9 18C9 19.4142 9 20.1213 8.56066 20.5607C8.12132 21 7.41421 21 6 21C4.58579 21 3.87868 21 3.43934 20.5607C3 20.1213 3 19.4142 3 18Z M3 12L9 12 M12 3V8 M15 6C15 4.58579 15 3.87868 15.4393 3.43934C15.8787 3 16.5858 3 18 3C19.4142 3 20.1213 3 20.5607 3.43934C21 3.87868 21 4.58579 21 6C21 7.41421 21 8.12132 20.5607 8.56066C20.1213 9 19.4142 9 18 9C16.5858 9 15.8787 9 15.4393 8.56066C15 8.12132 15 7.41421 15 6Z M21 12H15C13.5858 12 12.8787 12 12.4393 12.4393C12 12.8787 12 13.5858 12 15M12 17.7692V20.5385M15 15V16.5C15 17.9464 15.7837 18 17 18C17.5523 18 18 18.4477 18 19M16 21H15M18 15C19.4142 15 20.1213 15 20.5607 15.44C21 15.8799 21 16.5881 21 18.0043C21 19.4206 21 20.1287 20.5607 20.5687C20.24 20.8898 19.7767 20.9766 19 21"
        case .devicePair:
            // Hugeicons "computer-phone-sync": a screen and phone — the iOS not-paired empty state.
            return "M12 17H8C5.17157 17 3.75736 17 2.87868 16.1213C2 15.2426 2 13.8284 2 11V9C2 6.17157 2 4.75736 2.87868 3.87868C3.75736 3 5.17157 3 8 3H16C18.8284 3 20.2426 3 21.1213 3.87868C21.9466 4.70398 21.9968 6.00173 21.9998 8.5 M16 14V18C16 19.4142 16 20.1213 16.4393 20.5607C16.8787 21 17.5858 21 19 21C20.4142 21 21.1213 21 21.5607 20.5607C22 20.1213 22 19.4142 22 18V14C22 12.5858 22 11.8787 21.5607 11.4393C21.1213 11 20.4142 11 19 11C17.5858 11 16.8787 11 16.4393 11.4393C16 11.8787 16 12.5858 16 14Z M10 21H8M10 21C10.8284 21 11.5 20.3284 11.5 19.5V17L12 17M10 21H12.5V17L12 17M12 17V21"
        case .wifiError:
            // Hugeicons "wifi-error-01": radio waves with a warning — the iOS unreachable empty state.
            return "M18.5 9.99761C14.7324 6.66535 9.5 6.66535 5.5 9.99761 M2 6.9986C8.31579 1.66699 15.6842 1.66698 22 6.99849 M11.9933 14.9853V16.4964M11.9933 18.4673V18.4984M12.1444 12.0075C12.4933 11.9942 13.375 12.163 14.2349 13.6825L16.3884 17.3742C17.2109 18.5922 17.6154 20.7778 14.5873 20.9418L12 21.0002L9.3841 20.926C6.35606 20.7621 6.82207 18.5938 7.58302 17.3585L9.73652 13.6667C10.5964 12.1473 11.4781 11.9784 11.8271 11.9918L12.1444 12.0075Z"
        case .inbox:
            // Hugeicons "inbox": a rounded tray — the iOS no-sessions empty state.
            return "M2.5 12C2.5 7.52166 2.5 5.28249 3.89124 3.89124C5.28249 2.5 7.52166 2.5 12 2.5C16.4783 2.5 18.7175 2.5 20.1088 3.89124C21.5 5.28249 21.5 7.52166 21.5 12C21.5 16.4783 21.5 18.7175 20.1088 20.1088C18.7175 21.5 16.4783 21.5 12 21.5C7.52166 21.5 5.28249 21.5 3.89124 20.1088C2.5 18.7175 2.5 16.4783 2.5 12Z M21.5 13.5H16.5743C15.7322 13.5 15.0706 14.2036 14.6995 14.9472C14.2963 15.7551 13.4889 16.5 12 16.5C10.5111 16.5 9.70373 15.7551 9.30054 14.9472C8.92942 14.2036 8.26777 13.5 7.42566 13.5H2.5"
        }
    }
}

/// A vendor brand mark, stored as its official SVG path so it renders crisp
/// at any size without shipping binary image assets.
public enum BrandLogo: Hashable, Sendable {
    case claude
    case codex
    case grok

    public init?(reference: String) {
        switch reference.lowercased() {
        case "claude": self = .claude
        case "codex": self = .codex
        case "grok": self = .grok
        default: return nil
        }
    }

    /// Side length of the source SVG's square viewBox (the marks use 24).
    public var viewBox: CGFloat { 24 }

    public var tint: Color {
        switch self {
        case .claude: Color(red: 0.851, green: 0.467, blue: 0.341) // #D97757
        case .codex, .grok: .monochromeInk
        }
    }

    /// Whether the mark's holes are cut with the even-odd fill rule. Codex's
    /// mark and Grok's slashed ring declare `fill-rule="evenodd"` to carve their
    /// glyphs out of the blob; Claude's single outline needs nonzero.
    public var usesEvenOddFill: Bool {
        switch self {
        case .codex, .grok: true
        case .claude: false
        }
    }

    public var pathData: String {
        switch self {
        case .claude:
            return "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
        case .codex:
            return "M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z"
        case .grok:
            // xAI Grok mark (x.ai): a slashed ring, two subpaths cut with even-odd
            // fill. Source viewBox 24, `currentColor` (monochrome).
            return "M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272.98 2.369.542 5.215-1.41 7.169-1.951 1.954-4.667 2.382-7.149 1.406l-2.711 1.257c3.889 2.661 8.611 2.003 11.562-.953 2.341-2.344 3.066-5.539 2.388-8.42l.006.007c-.983-4.232.242-5.924 2.75-9.383.06-.082.12-.164.179-.248l-3.301 3.305v-.01L9.267 15.292M7.623 16.723c-2.792-2.67-2.31-6.801.071-9.184 1.761-1.763 4.647-2.483 7.166-1.425l2.705-1.25a7.808 7.808 0 00-1.829-1A8.975 8.975 0 005.984 5.83c-2.533 2.536-3.33 6.436-1.962 9.764 1.022 2.487-.653 4.246-2.34 6.022-.599.63-1.199 1.259-1.682 1.925l7.62-6.815"
        }
    }
}

// MARK: - Shapes

/// A `Shape` that draws a `BrandLogo` from its embedded SVG path, scaled to
/// fit the available rect (preserving the source 24×24 aspect, centered).
public struct BrandLogoShape: Shape {
    let logo: BrandLogo

    public init(logo: BrandLogo) {
        self.logo = logo
    }

    public func path(in rect: CGRect) -> Path {
        scaledVectorPath(SVGPath(logo.pathData).cgPath, viewBox: logo.viewBox, in: rect)
    }
}

/// Renders a `HugeIcon` as a rounded stroke in the given color. The stroke
/// width tracks the source's 1.5px-on-24 ratio with a small floor so the
/// line never thins to a hairline at list sizes.
public struct HugeIconView: View {
    let icon: HugeIcon
    let size: CGFloat
    let color: Color
    /// Overrides the size-derived stroke width. Used where a mark reads too thin
    /// at a small size (e.g. the Mac sidebar's disclosure chevron), so it can be
    /// bumped heavier without also growing the glyph.
    let lineWidthOverride: CGFloat?

    public init(icon: HugeIcon, size: CGFloat, color: Color, lineWidthOverride: CGFloat? = nil) {
        self.icon = icon
        self.size = size
        self.color = color
        self.lineWidthOverride = lineWidthOverride
    }

    public var body: some View {
        HugeIconShape(icon: icon)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }

    private var lineWidth: CGFloat {
        lineWidthOverride ?? max(1.1, size * 1.5 / icon.viewBox)
    }
}

/// A `Shape` that draws a `HugeIcon`'s SVG path scaled to fit the rect, to be
/// stroked (not filled) by `HugeIconView`.
public struct HugeIconShape: Shape {
    let icon: HugeIcon

    public init(icon: HugeIcon) {
        self.icon = icon
    }

    public func path(in rect: CGRect) -> Path {
        // Fit by the mark's actual ink box, not the nominal 24 viewBox: Hugeicons'
        // marks fill their viewBox by different amounts (the terminal glyph spans
        // 18 of 24, a folder 20), so plain viewBox-fitting left them visibly
        // unequal in width in a shared icon column. Normalizing every mark's ink
        // width to a fixed fraction of the box — the terminal mark's own 18/24
        // fill — keeps the terminal identical while pulling wider marks in to
        // match it, so same-`size` HugeIcons line up.
        let glyph = SVGPath(icon.pathData).cgPath
        let ink = glyph.boundingBoxOfPath
        guard ink.width > 0, ink.height > 0 else { return Path(glyph) }
        let targetWidth = rect.width * (18.0 / 24.0)
        let scale = min(targetWidth / ink.width, rect.height / ink.height)
        var transform = CGAffineTransform(
            translationX: rect.midX - scale * ink.midX,
            y: rect.midY - scale * ink.midY
        )
        .scaledBy(x: scale, y: scale)
        return Path(glyph.copy(using: &transform) ?? glyph)
    }
}

/// Scales a parsed glyph from its square `viewBox` to fit `rect`, centered,
/// preserving aspect. Shared by the filled brand marks and stroked Hugeicons.
private func scaledVectorPath(_ glyph: CGPath, viewBox: CGFloat, in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / viewBox
    var transform = CGAffineTransform(
        translationX: rect.midX - viewBox * scale / 2,
        y: rect.midY - viewBox * scale / 2
    )
    .scaledBy(x: scale, y: scale)
    let scaled = glyph.copy(using: &transform) ?? glyph
    return Path(scaled)
}

// MARK: - SVG path parser

/// A small parser for the subset of SVG path syntax used by the embedded
/// brand marks — moveto/lineto/horizontal/vertical, cubic and quadratic
/// curves (with smooth variants), elliptical arcs, and close. SVG and Core
/// Graphics coordinate spaces both run y-downward, so no axis flip.
private struct SVGPath {
    let pathData: String

    init(_ pathData: String) { self.pathData = pathData }

    var cgPath: CGPath {
        let path = CGMutablePath()
        var scanner = Scanner(pathData)

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var previousCommand: Character = " "

        func reflectedCubic() -> CGPoint {
            guard let last = lastCubicControl, "CcSs".contains(previousCommand) else { return current }
            return CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
        }
        func reflectedQuad() -> CGPoint {
            guard let last = lastQuadControl, "QqTt".contains(previousCommand) else { return current }
            return CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
        }

        while !scanner.isAtEnd {
            // A bare number means "repeat the previous command"; after a moveto
            // the implicit repeat is a lineto, per the SVG spec.
            var command: Character
            if let explicit = scanner.readCommand() {
                command = explicit
            } else if previousCommand != " " {
                command = previousCommand
                if command == "M" { command = "L" }
                if command == "m" { command = "l" }
            } else {
                break
            }

            let relative = command.isLowercase
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch command.uppercased() {
            case "M":
                current = point(scanner.readNumber(), scanner.readNumber())
                path.move(to: current)
                subpathStart = current
            case "L":
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addLine(to: current)
            case "H":
                let x = scanner.readNumber()
                current = relative ? CGPoint(x: current.x + x, y: current.y) : CGPoint(x: x, y: current.y)
                path.addLine(to: current)
            case "V":
                let y = scanner.readNumber()
                current = relative ? CGPoint(x: current.x, y: current.y + y) : CGPoint(x: current.x, y: y)
                path.addLine(to: current)
            case "C":
                let c1 = point(scanner.readNumber(), scanner.readNumber())
                let c2 = point(scanner.readNumber(), scanner.readNumber())
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2
            case "S":
                let c1 = reflectedCubic()
                let c2 = point(scanner.readNumber(), scanner.readNumber())
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2
            case "Q":
                let c = point(scanner.readNumber(), scanner.readNumber())
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c
            case "T":
                let c = reflectedQuad()
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c
            case "A":
                let rx = scanner.readNumber()
                let ry = scanner.readNumber()
                let rotation = scanner.readNumber()
                let largeArc = scanner.readFlag()
                let sweep = scanner.readFlag()
                let end = point(scanner.readNumber(), scanner.readNumber())
                addArc(to: path, from: current, to: end, rx: rx, ry: ry,
                       rotationDegrees: rotation, largeArc: largeArc, sweep: sweep)
                current = end
            case "Z":
                path.closeSubpath()
                current = subpathStart
            default:
                break
            }

            if command.uppercased() != "C" && command.uppercased() != "S" { lastCubicControl = nil }
            if command.uppercased() != "Q" && command.uppercased() != "T" { lastQuadControl = nil }
            previousCommand = command
        }
        return path
    }

    /// Appends an SVG elliptical arc to `path` as a sequence of cubic Béziers,
    /// using the endpoint-to-center conversion from the SVG implementation notes.
    private func addArc(
        to path: CGMutablePath, from start: CGPoint, to end: CGPoint,
        rx rxIn: CGFloat, ry ryIn: CGFloat, rotationDegrees: CGFloat,
        largeArc: Bool, sweep: Bool
    ) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 { path.addLine(to: end); return }
        if start == end { return }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        let radiiCheck = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if radiiCheck > 1 {
            let scale = sqrt(radiiCheck)
            rx *= scale
            ry *= scale
        }

        let rx2 = rx * rx, ry2 = ry * ry, x1Sq = x1 * x1, y1Sq = y1 * y1
        let numerator = max(0, rx2 * ry2 - rx2 * y1Sq - ry2 * x1Sq)
        let denominator = rx2 * y1Sq + ry2 * x1Sq
        var coefficient = denominator == 0 ? 0 : sqrt(numerator / denominator)
        if largeArc == sweep { coefficient = -coefficient }

        let cxPrime = coefficient * (rx * y1 / ry)
        let cyPrime = coefficient * (-ry * x1 / rx)
        let centerX = cosPhi * cxPrime - sinPhi * cyPrime + (start.x + end.x) / 2
        let centerY = sinPhi * cxPrime + cosPhi * cyPrime + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let length = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            let clamped = max(-1, min(1, length == 0 ? 0 : dot / length))
            let result = acos(clamped)
            return ux * vy - uy * vx < 0 ? -result : result
        }

        let ux = (x1 - cxPrime) / rx, uy = (y1 - cyPrime) / ry
        let vx = (-x1 - cxPrime) / rx, vy = (-y1 - cyPrime) / ry
        let startAngle = angle(1, 0, ux, uy)
        var sweepAngle = angle(ux, uy, vx, vy)
        if !sweep && sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep && sweepAngle < 0 { sweepAngle += 2 * .pi }

        let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let delta = sweepAngle / CGFloat(segments)
        let controlScale = 4.0 / 3.0 * tan(delta / 4)

        func onEllipse(_ cosA: CGFloat, _ sinA: CGFloat) -> CGPoint {
            let ex = rx * cosA, ey = ry * sinA
            return CGPoint(x: cosPhi * ex - sinPhi * ey + centerX,
                           y: sinPhi * ex + cosPhi * ey + centerY)
        }
        func tangent(_ cosA: CGFloat, _ sinA: CGFloat) -> CGPoint {
            let ex = -rx * sinA, ey = ry * cosA
            return CGPoint(x: cosPhi * ex - sinPhi * ey,
                           y: sinPhi * ex + cosPhi * ey)
        }

        var a = startAngle
        for _ in 0..<segments {
            let cosA = cos(a), sinA = sin(a)
            let cosB = cos(a + delta), sinB = sin(a + delta)
            let p1 = onEllipse(cosA, sinA)
            let p2 = onEllipse(cosB, sinB)
            let t1 = tangent(cosA, sinA)
            let t2 = tangent(cosB, sinB)
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + controlScale * t1.x, y: p1.y + controlScale * t1.y),
                control2: CGPoint(x: p2.x - controlScale * t2.x, y: p2.y - controlScale * t2.y)
            )
            a += delta
        }
    }
}

/// A forgiving number/command scanner for SVG path data. Handles the quirks
/// the brand marks rely on: implicit separators, signs that start a new
/// number, a second decimal point that ends one (`.686.0608` is two numbers),
/// and arc flags packed as single digits.
private struct Scanner {
    private let characters: [Character]
    private var index = 0

    init(_ string: String) { characters = Array(string) }

    var isAtEnd: Bool {
        var probe = index
        while probe < characters.count, isSeparator(characters[probe]) { probe += 1 }
        return probe >= characters.count
    }

    private func isSeparator(_ c: Character) -> Bool {
        c == " " || c == "," || c == "\n" || c == "\t" || c == "\r"
    }

    private mutating func skipSeparators() {
        while index < characters.count, isSeparator(characters[index]) { index += 1 }
    }

    mutating func readCommand() -> Character? {
        skipSeparators()
        guard index < characters.count, characters[index].isLetter else { return nil }
        defer { index += 1 }
        return characters[index]
    }

    mutating func readNumber() -> CGFloat {
        skipSeparators()
        var text = ""
        if index < characters.count, characters[index] == "+" || characters[index] == "-" {
            text.append(characters[index])
            index += 1
        }
        var seenDot = false
        var seenExponent = false
        while index < characters.count {
            let c = characters[index]
            if c.isNumber {
                text.append(c)
                index += 1
            } else if c == "." && !seenDot && !seenExponent {
                seenDot = true
                text.append(c)
                index += 1
            } else if (c == "e" || c == "E") && !seenExponent {
                seenExponent = true
                text.append(c)
                index += 1
                if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                    text.append(characters[index])
                    index += 1
                }
            } else {
                break
            }
        }
        return CGFloat(Double(text) ?? 0)
    }

    mutating func readFlag() -> Bool {
        skipSeparators()
        guard index < characters.count else { return false }
        let c = characters[index]
        if c == "0" || c == "1" {
            index += 1
            return c == "1"
        }
        return readNumber() != 0
    }
}
