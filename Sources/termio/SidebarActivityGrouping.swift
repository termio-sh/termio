import Foundation

/// The fixed, scannable time windows used when the sidebar is grouped by recent
/// activity. A missing timestamp intentionally lands in the oldest bucket: an
/// unlaunched session must remain visible, but should not look recently active.
enum SidebarActivityBucket: CaseIterable, Hashable, Identifiable {
    case withinOneDay
    case withinSevenDays
    case olderSessions

    var id: Self { self }

    var title: String {
        switch self {
        case .withinOneDay: return "WITHIN 1 DAY"
        case .withinSevenDays: return "WITHIN 7 DAYS"
        case .olderSessions: return "OLDER SESSIONS"
        }
    }

    static func bucket(for timestamp: Date?, now: Date = Date()) -> Self {
        guard let timestamp else { return .olderSessions }
        if timestamp >= now.addingTimeInterval(-24 * 60 * 60) {
            return .withinOneDay
        }
        if timestamp >= now.addingTimeInterval(-7 * 24 * 60 * 60) {
            return .withinSevenDays
        }
        return .olderSessions
    }
}
