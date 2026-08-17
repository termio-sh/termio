import SwiftUI

/// The coding-plan usage limits for the agents termio runs, reusing the OAuth
/// credentials the `claude`, `codex`, `kimi`, and `grok` CLIs already leave on
/// disk — the same approach as steipete's CodexBar, scoped to the agents with a
/// clean local-cred endpoint. A reference view, not an ambient one: it pulls
/// fresh on open and on Refresh, so a glance here tells you whether to start
/// that long run.
struct UsageSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usage: UsageMonitor
    /// The agent whose statistics are shown. Held loosely (optional) so a disabled
    /// agent falling out of the list resolves back to the first available one
    /// rather than stranding on an empty pane.
    @State private var selected: AgentPreset?

    /// The supported agents the user has left enabled — one sub-tab each.
    private var agents: [AgentPreset] {
        UsageMonitor.supportedAgents.filter(settings.isAgentEnabled)
    }

    /// The resolved selection: the held one if still enabled, else the first agent.
    private var current: AgentPreset {
        if let selected, agents.contains(selected) { return selected }
        return agents.first ?? .claudeCode
    }

    var body: some View {
        Group {
            if agents.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    UsageAgentPicker(
                        agents: agents,
                        selection: Binding(get: { current }, set: { selected = $0 })
                    )
                    Divider()
                    UsageAgentDetail(agent: current, usage: usage, settings: settings)
                }
            }
        }
        .onAppear(perform: usage.refresh)
    }

    private var emptyState: some View {
        Form {
            Section {
                Text(localized("Enable Claude Code, Codex, Kimi, or Grok in the Agents tab to see their usage here."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeaderLabel(title: localized("Usage"))
            }
        }
        .formStyle(.grouped)
    }
}

/// The Usage pane's secondary tab strip: one selectable pill per agent (brand mark
/// + name), CodexBar's provider-switcher pattern. The selected pill tints accent
/// over a soft capsule; the rest stay flat with a hover lift.
private struct UsageAgentPicker: View {
    let agents: [AgentPreset]
    @Binding var selection: AgentPreset

    var body: some View {
        HStack(spacing: 6) {
            ForEach(agents) { agent in
                pill(for: agent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func pill(for agent: AgentPreset) -> some View {
        let isSelected = agent == selection
        return Button {
            selection = agent
        } label: {
            HStack(spacing: 6) {
                AgentIconView(agent: agent, size: 14)
                Text(agent.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.accentColor.opacity(isSelected ? 0.14 : 0))
            )
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}

/// One agent's statistics: the local token totals (today / week / month, with the
/// API-rate cost estimate where termio can price it) and the live plan-limit lanes.
/// Everything is behind a per-agent Allow: until the user grants it, none of the
/// agent's data — logs or sign-in — is read, and the pane says only that.
private struct UsageAgentDetail: View {
    let agent: AgentPreset
    @ObservedObject var usage: UsageMonitor
    @ObservedObject var settings: AppSettings

    /// Yesterday's totals out of the per-day buckets — the one recent day the
    /// rolling week/month rows can't answer at a glance (and, at a week or month
    /// boundary, don't contain at all).
    private func yesterdayStats(_ tokens: AgentTokenUsage) -> TokenWindowStats {
        let calendar = Calendar.current
        guard let yesterday = calendar.date(
            byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))
        else { return TokenWindowStats() }
        return tokens.daily[yesterday] ?? TokenWindowStats()
    }

    var body: some View {
        if settings.isUsageAuthorized(agent) {
            statistics
        } else {
            authorizationOffer
        }
    }

    /// The pre-grant pane: what would be read, and a single Allow button. The
    /// Keychain prompt (Claude only) can then appear as the direct consequence of
    /// this click — never from merely opening the tab.
    private var authorizationOffer: some View {
        Form {
            Section {
                Text(agent == .claudeCode
                    ? localized("Termio can show \(agent.displayName)'s token usage and plan limits by reading its local session logs and its sign-in from your login Keychain. Nothing is read until you allow it; macOS will ask once about the Keychain.")
                    : agent == .kimi
                    ? localized("Termio can show \(agent.displayName)'s token usage and plan limits by reading its local session logs and its `credentials/kimi-code.json` sign-in. Nothing is read until you allow it.")
                    : localized("Termio can show \(agent.displayName)'s token usage and plan limits by reading its local session logs and its `auth.json` sign-in. Nothing is read until you allow it."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(localized("Allow Usage Access")) {
                    settings.setUsageAuthorized(agent, enabled: true)
                    if agent == .claudeCode { settings.claudeKeychainDeclined = false }
                    usage.forceRefresh()
                }
            } header: {
                SectionHeaderLabel(title: localized("Usage"))
            }
        }
        .formStyle(.grouped)
    }

    private var statistics: some View {
        Form {
            Section {
                if let tokens = usage.tokenUsage[agent] {
                    TokenUsageRow(label: localized("Today"), stats: tokens.today, hasCost: tokens.hasCost)
                    TokenUsageRow(label: localized("Yesterday"), stats: yesterdayStats(tokens), hasCost: tokens.hasCost)
                    TokenUsageRow(label: localized("This week"), stats: tokens.week, hasCost: tokens.hasCost)
                    TokenUsageRow(label: localized("This month"), stats: tokens.month, hasCost: tokens.hasCost)
                } else {
                    Text(.init(localized("No local usage yet — run `\(agent.command ?? agent.rawValue)` once, then Refresh.")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                SectionHeaderLabel(title: localized("Token usage"))
            } footer: {
                Text(localized("Tallied from \(agent.displayName)'s own local session logs across every terminal and editor on this Mac — your actual usage, regardless of how the plan bills.\(usage.tokenUsage[agent]?.hasCost == true ? localized(" Cost is estimated at API rates.") : "")"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let tokens = usage.tokenUsage[agent], !tokens.daily.isEmpty {
                Section {
                    UsageActivityChart(daily: tokens.daily, hasCost: tokens.hasCost)
                } header: {
                    SectionHeaderLabel(title: localized("Activity"))
                }
            }

            if let reading = usage.usage[agent], !reading.windows.isEmpty {
                Section {
                    ForEach(reading.windows) { window in
                        UsageWindowRow(window: window)
                    }
                } header: {
                    SectionHeaderLabel(title: localized("Plan limits"))
                }
            } else if agent == .claudeCode, settings.claudeKeychainDeclined {
                Section {
                    Button(localized("Allow Keychain Access…")) {
                        settings.claudeKeychainDeclined = false
                        usage.refresh()
                    }
                } header: {
                    SectionHeaderLabel(title: localized("Plan limits"))
                } footer: {
                    Text(localized("Keychain access was declined, so plan limits stay hidden. Allowing again re-shows the macOS prompt."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(localized("Refresh"), action: usage.forceRefresh)
                Button(localized("Revoke Access")) {
                    settings.setUsageAuthorized(agent, enabled: false)
                    usage.forceRefresh()
                }
                .foregroundStyle(.secondary)
            } footer: {
                Text(localized("Plan limits come from \(agent.displayName)'s OAuth login; no passwords are stored. Revoking stops all reading of \(agent.displayName)'s data."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One token-usage window: the period, the token throughput, and (for agents
/// termio can price) the API-rate dollar estimate. This is the "what did I
/// actually burn" line — independent of plan billing.
private struct TokenUsageRow: View {
    let label: String
    let stats: TokenWindowStats
    let hasCost: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
            Spacer()
            Text(localized("\(stats.tokenSummary) tokens"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            if hasCost, !stats.costSummary.isEmpty {
                Text("· \(stats.costSummary)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
    }
}

/// The activity chart's spans — one bar per day in either.
private enum UsageChartRange: String, CaseIterable, Identifiable {
    case week = "7D"
    case month = "30D"

    var id: String { rawValue }
    var dayCount: Int { self == .week ? 7 : 30 }

    var summaryLabel: String {
        self == .week ? localized("Last 7 days") : localized("Last 30 days")
    }
}

/// One bar of the activity chart plus the day phrase ("Jul 3") the summary line
/// shows while it is hovered.
private struct UsageChartBar: Identifiable, Equatable {
    let id: Int
    let label: String
    let stats: TokenWindowStats
}

/// The per-day activity chart: a range picker (7 or 30 days) over a row of bars
/// scaled to the busiest day in view. Hovering a bar swaps the summary line from
/// the range total to that day's own numbers — no tooltip chrome, the same quiet
/// register as the rest of the pane.
private struct UsageActivityChart: View {
    let daily: [Date: TokenWindowStats]
    let hasCost: Bool
    @State private var range: UsageChartRange = .month
    @State private var hoveredID: Int?

    var body: some View {
        let bars = bars(for: range)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary(for: bars))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(localized("Range"), selection: $range) {
                    ForEach(UsageChartRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
            }
            barsView(bars)
            HStack {
                Text(bars.first?.label ?? "")
                Spacer()
                Text(localized("Today"))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .onChange(of: range) { hoveredID = nil }
    }

    /// The bars for the chosen range, oldest first, one per day, with empty days
    /// kept so the time axis stays honest.
    private func bars(for range: UsageChartRange) -> [UsageChartBar] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let count = range.dayCount
        return (0..<count).compactMap { index in
            guard let day = calendar.date(byAdding: .day, value: index - count + 1, to: today)
            else { return nil }
            return UsageChartBar(
                id: index,
                label: day.formatted(.dateTime.month(.abbreviated).day()),
                stats: daily[day] ?? TokenWindowStats())
        }
    }

    /// The hovered day's numbers, or the whole range's total when nothing is.
    private func summary(for bars: [UsageChartBar]) -> String {
        if let hoveredID, let bar = bars.first(where: { $0.id == hoveredID }) {
            return phrase(bar.label, bar.stats)
        }
        var total = TokenWindowStats()
        for bar in bars { total.add(bar.stats) }
        return phrase(range.summaryLabel, total)
    }

    private func phrase(_ label: String, _ stats: TokenWindowStats) -> String {
        var text = localized("\(label) · \(stats.tokenSummary) tokens")
        if hasCost, !stats.costSummary.isEmpty { text += " · \(stats.costSummary)" }
        return text
    }

    private func barsView(_ bars: [UsageChartBar]) -> some View {
        let peak = max(bars.map(\.stats.total).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: bars.count > 7 ? 2 : 4) {
            ForEach(bars) { bar in
                let fraction = Double(bar.stats.total) / Double(peak)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color(for: bar))
                        .frame(height: bar.stats.total == 0 ? 2 : max(3, fraction * 56))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        hoveredID = bar.id
                    } else if hoveredID == bar.id {
                        hoveredID = nil
                    }
                }
            }
        }
        .frame(height: 56)
    }

    private func color(for bar: UsageChartBar) -> Color {
        if bar.stats.total == 0 { return Color.primary.opacity(0.08) }
        return Color.accentColor.opacity(hoveredID == bar.id ? 1 : 0.55)
    }
}

/// One quota lane: its period and a filled bar with the percent and reset time.
/// The bar tints amber past 75% and red past 90%, so a near-exhausted window
/// reads at a glance without a number-by-number scan.
private struct UsageWindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label)
                    .font(.callout)
                Spacer()
                Text("\(window.usedPercent)%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !window.resetSummary.isEmpty {
                    Text(localized("· resets \(window.resetSummary)"))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(fill)
                        .frame(width: max(0, min(1, Double(window.usedPercent) / 100)) * geometry.size.width)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
    }

    private var fill: Color {
        switch window.usedPercent {
        case 90...: return .red
        case 75...: return .orange
        default: return .accentColor
        }
    }
}
