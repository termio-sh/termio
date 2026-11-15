import AppKit
import SwiftUI

/// In-editor find bar. Return re-runs a fresh query or advances on the same query; Esc closes.
/// Where the buffer can be written it also carries VS Code's replace disclosure on its leading
/// edge — closed by default, so a plain search is the bar it has always been.
struct FileFindBar: View {
    @Binding var query: String
    @Binding var options: FindOptions
    let currentMatch: Int
    let totalMatches: Int
    let onSubmit: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    var focusTrigger: Int = 0
    /// False where the search can only match text as written — a PDF's, which PDFKit
    /// searches itself. The bar then offers Match Case alone.
    var supportsWordAndRegex = true
    /// True while a search is still running, so the bar doesn't report "No results" for
    /// a document it hasn't finished reading.
    var searching = false
    /// The replace row's wiring, or nil where the text can't be written — the diff overlay
    /// searches a read-only document, so it gets no disclosure at all.
    var replace: Replace? = nil

    /// Everything the replace row needs, grouped so a caller can't wire half of it.
    struct Replace {
        @Binding var text: String
        /// Replace the focused match and step to the next one.
        let current: () -> Void
        let all: () -> Void
    }

    @FocusState private var focused: Bool
    /// VS Code's find widget opens collapsed: searching is the common case, and the replacement
    /// field is one click away. The bar is rebuilt on each open, so it always starts closed.
    @State private var showsReplace = false

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if replace != nil { disclosure }
            VStack(alignment: .leading, spacing: 6) {
                findRow
                if let replace, showsReplace { replaceRow(replace) }
            }
        }
        // The disclosure claims the leading room it needs; without one the bar keeps its original
        // inset, so the diff overlay's find bar is unchanged to the pixel.
        .padding(.leading, replace == nil ? 12 : 6)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        // One Liquid Glass shell — the same recipe as `FileSearchView`,
        // with a flat-material fallback below macOS 26. A single sheet, never glass-on-glass.
        .findBarGlass(expanded: showsReplace)
        .fixedSize()
        .padding(.trailing, 12)
        .padding(.top, 6)
        .onExitCommand(perform: onClose)
        .onAppear { requestFocus() }
        .onChange(of: focusTrigger) { _, _ in requestFocus() }
    }

    private var findRow: some View {
        HStack(spacing: 8) {
            searchFieldGroup
            // A vibrant hairline splits the query+modifiers from the count/nav cluster —
            // structure without a second material, so the bar stays one sheet of glass.
            Divider().frame(height: 16).opacity(0.6)
            countLabel
            iconButton("chevron.up", disabled: totalMatches == 0, tooltip: localized("Previous Match"), action: onPrevious)
            iconButton("chevron.down", disabled: totalMatches == 0, tooltip: localized("Next Match"), action: onNext)
            iconButton("xmark", disabled: false, tooltip: localized("Close (Esc)"), action: onClose)
        }
    }

    /// The one control that opens and closes the replace row, on the leading edge where VS Code
    /// puts it — a turning chevron rather than a labelled button, since the row it reveals says
    /// what it is.
    private var disclosure: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { showsReplace.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(showsReplace ? 90 : 0))
                .frame(width: 14, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(showsReplace ? localized("Hide Replace") : localized("Show Replace"))
    }

    /// The replacement field and its two verbs. Return in the field replaces the focused match,
    /// the way Return in the query field advances to it.
    private func replaceRow(_ replace: Replace) -> some View {
        HStack(spacing: 4) {
            // Lines the replacement field's leading edge up with the query field's, without
            // inventing an icon for a row that has nothing to say with one.
            Color.clear.frame(width: 11, height: 0)
            TextField(localized("Replace"), text: replace.$text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(replace.current)
                .frame(minWidth: 140, maxWidth: 260)
            replaceButton(localized("Replace"), action: replace.current)
            replaceButton(localized("Replace All"), action: replace.all)
        }
    }

    private func replaceButton(_ title: String, action: @escaping () -> Void) -> some View {
        let enabled = totalMatches > 0
        return Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                // The same neutral grey chip the option toggles wear, never an accent fill.
                .foregroundStyle(enabled ? Color.primary : .secondary)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(
                    Color.primary.opacity(enabled ? 0.12 : 0.06),
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(title)
    }

    /// Focus is deferred by a runloop tick so AppKit has time to place the field in the
    /// responder chain — otherwise the request lands before the view is attached and is dropped.
    private func requestFocus() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            focused = true
        }
    }

    private var searchFieldGroup: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(localized("Find"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit(onSubmit)
                .frame(minWidth: 140, maxWidth: 260)
            optionToggle(label: .symbol("textformat"), active: options.caseSensitive, tooltip: localized("Match Case")) {
                options.caseSensitive.toggle()
            }
            if supportsWordAndRegex {
                optionToggle(label: .text("ab", underline: true), active: options.wholeWord, tooltip: localized("Match Whole Word")) {
                    options.wholeWord.toggle()
                }
                optionToggle(label: .text(".*", underline: false), active: options.regex, tooltip: localized("Use Regular Expression")) {
                    options.regex.toggle()
                }
            }
        }
    }

    private enum ToggleLabel {
        case symbol(String)
        case text(String, underline: Bool)
    }

    private func optionToggle(label: ToggleLabel, active: Bool, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                switch label {
                case .symbol(let name):
                    Image(systemName: name)
                case .text(let glyphs, let underline):
                    underline ? AnyView(Text(glyphs).underline()) : AnyView(Text(glyphs))
                }
            }
            .font(.system(size: 11, weight: .medium))
            // Active reads as a neutral grey chip + full-strength label, not an accent-blue fill.
            .foregroundStyle(active ? Color.primary : .secondary)
            .frame(width: 20, height: 18)
            .background(
                active ? Color.primary.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.borderless)
        .help(tooltip)
    }

    private func iconButton(_ name: String, disabled: Bool, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(tooltip)
    }

    @ViewBuilder
    private var countLabel: some View {
        if query.isEmpty {
            EmptyView()
        } else if totalMatches == 0, searching {
            ProgressView().controlSize(.small).scaleEffect(0.7)
        } else if totalMatches == 0 {
            Text(localized("No results"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Text(localized("\(currentMatch) of \(totalMatches)"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// The expanded bar's corner, concentric with the capsule it grows out of.
private let expandedCornerRadius: CGFloat = 14

private extension View {
    /// The floating find bar's Liquid Glass shell: a single `.regular` glass capsule on
    /// macOS 26 (matching `FileSearchView`'s field and the inspector toolbar's track), and a
    /// plain material capsule with a hairline on macOS 14/15 where the effect doesn't exist.
    ///
    /// A capsule is right for one row. Two rows in one bow out at the ends, so the expanded bar
    /// takes a rounded rectangle instead — the shape changes, the material never does.
    @ViewBuilder
    func findBarGlass(expanded: Bool) -> some View {
        if #available(macOS 26.0, *) {
            if expanded {
                glassEffect(.regular, in: .rect(cornerRadius: expandedCornerRadius))
            } else {
                glassEffect(.regular, in: .capsule)
            }
        } else {
            if expanded {
                let shape = RoundedRectangle(cornerRadius: expandedCornerRadius, style: .continuous)
                background(.regularMaterial, in: shape)
                    .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            } else {
                background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
        }
    }
}
