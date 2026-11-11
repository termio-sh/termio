import SwiftUI
import TermioShared

/// The sidebar's column: sessions under their groups in the vertical layout, the groups alone in
/// the horizontal one — where the selected group's sessions are tabs above the cards
/// (`SessionTabStrip`). Each list is on screen once either way.
struct SidebarColumn: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        switch settings.tabLayout {
        case .vertical: SidebarView()
        case .horizontal: SidebarGroupList()
        }
    }
}

/// The horizontal layout's sidebar: one row per group — Terminals, Chats, each project — the
/// way Safari lists its tab groups. Clicking a group opens it on the session last left in it.
struct SidebarGroupList: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var window: WindowContext
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let selected = window.selectedSessionID.flatMap(store.group(of:))
        let chrome = settings.chromeTheme(for: colorScheme)
        List {
            ForEach(store.sessionGroups, id: \.self) { group in
                SidebarGroupRow(group: group, isSelected: group == selected, chrome: chrome)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
    }
}

private struct SidebarGroupRow: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    let group: TabGroup
    let isSelected: Bool
    let chrome: ChromeTheme?
    @State private var isHovering = false
    /// True while this row's right-click menu is open, so the row lifts as the menu's target.
    @State private var isMenuOpen = false

    var body: some View {
        let members = store.sessions(in: group)
        let status = store.combinedStatus(of: members.map(\.id))
        HStack(spacing: 8) {
            Group {
                if status == .working {
                    WorkingIndicator(tint: .sidebarWorkingInk)
                } else {
                    HugeIconView(icon: icon, size: 15, color: .secondary)
                }
            }
            .frame(width: 16)
            .overlay { StatusDot(status: status) }
            Text(store.title(of: group))
                .font(settings.interfaceFont)
                .foregroundStyle(chrome.map { AnyShapeStyle($0.foreground) } ?? AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if !members.isEmpty {
                Text("\(members.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { store.open(group) }
        .onHover { isHovering = $0 }
        // The same menu the vertical layout's section or project header carries.
        .background(SidebarRowContextMenu(items: { menuItems }) { isMenuOpen = $0 })
        .background(OutlineViewFixups())
        .listRowBackground(SidebarRowHighlight(isSelected: isSelected, isHovering: isHovering || isMenuOpen,
                                               chrome: chrome, isGlass: true))
        .help(store.title(of: group))
    }

    private var menuItems: [SidebarMenuItem] {
        switch group {
        case .project(let id):
            guard let project = store.projects.first(where: { $0.id == id }) else { return [] }
            return projectMenuItems(store: store, settings: settings, project: project)
        case .terminals: return terminalsMenuItems(store: store, workspace: store.currentWorkspace.id)
        case .chats: return chatsMenuItems(store: store, workspace: store.currentWorkspace.id)
        }
    }

    private var icon: HugeIcon {
        switch group {
        case .project: .folder
        case .terminals: .terminal
        case .chats: .bubbleChat
        }
    }
}
