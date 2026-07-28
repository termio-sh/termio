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
            countLabel
            iconButton("chevron.up", disabled: totalMatches == 0, tooltip: "Previous Match", action: onPrevious)
            iconButton("chevron.down", disabled: totalMatches == 0, tooltip: "Next Match", action: onNext)
            iconButton("xmark", disabled: false, tooltip: "Close (Esc)", action: onClose)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
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
            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit(onSubmit)
                .frame(minWidth: 140, maxWidth: 260)
            optionToggle(label: .symbol("textformat"), active: options.caseSensitive, tooltip: "Match Case") {
                options.caseSensitive.toggle()
            }
            optionToggle(label: .text("ab", underline: true), active: options.wholeWord, tooltip: "Match Whole Word") {
                options.wholeWord.toggle()
            }
            optionToggle(label: .text(".*", underline: false), active: options.regex, tooltip: "Use Regular Expression") {
                options.regex.toggle()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
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
            .foregroundStyle(active ? Color.accentColor : .secondary)
            .frame(width: 20, height: 18)
            .background(
                active ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 3)
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
            Text("No results")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Text("\(currentMatch) of \(totalMatches)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
