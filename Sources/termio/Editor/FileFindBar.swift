import AppKit
import SwiftUI

/// In-editor find bar. Return re-runs a fresh query or advances on the same query; Esc closes.
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

    @FocusState private var focused: Bool

    var body: some View {
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
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        // One Liquid Glass capsule — the same recipe as `FileSearchView`/`InspectorTabsToolbar`,
        // with a flat-material fallback below macOS 26. A single sheet, never glass-on-glass.
        .findBarGlass()
        .fixedSize()
        .padding(.trailing, 12)
        .padding(.top, 6)
        .onExitCommand(perform: onClose)
        .onAppear { requestFocus() }
        .onChange(of: focusTrigger) { _, _ in requestFocus() }
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
            optionToggle(label: .text("ab", underline: true), active: options.wholeWord, tooltip: localized("Match Whole Word")) {
                options.wholeWord.toggle()
            }
            optionToggle(label: .text(".*", underline: false), active: options.regex, tooltip: localized("Use Regular Expression")) {
                options.regex.toggle()
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

private extension View {
    /// The floating find bar's Liquid Glass shell: a single `.regular` glass capsule on
    /// macOS 26 (matching `FileSearchView`'s field and the inspector toolbar's track), and a
    /// plain material capsule with a hairline on macOS 14/15 where the effect doesn't exist.
    @ViewBuilder
    func findBarGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }
}
