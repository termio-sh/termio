import XCTest
@testable import termio

final class SidebarActivityGroupingTests: XCTestCase {
    func testClassifiesSessionsIntoTheThreeRecentActivityBuckets() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        XCTAssertEqual(
            SidebarActivityBucket.bucket(for: now.addingTimeInterval(-23 * 60 * 60), now: now),
            .withinOneDay
        )
        XCTAssertEqual(
            SidebarActivityBucket.bucket(for: now.addingTimeInterval(-24 * 60 * 60), now: now),
            .withinOneDay
        )
        XCTAssertEqual(
            SidebarActivityBucket.bucket(for: now.addingTimeInterval(-6 * 24 * 60 * 60), now: now),
            .withinSevenDays
        )
        XCTAssertEqual(
            SidebarActivityBucket.bucket(for: now.addingTimeInterval(-7 * 24 * 60 * 60), now: now),
            .withinSevenDays
        )
        XCTAssertEqual(
            SidebarActivityBucket.bucket(for: now.addingTimeInterval(-8 * 24 * 60 * 60), now: now),
            .olderSessions
        )
        XCTAssertEqual(SidebarActivityBucket.bucket(for: nil, now: now), .olderSessions)
    }
}
