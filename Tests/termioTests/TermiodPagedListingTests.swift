import XCTest
import TermioShared
@testable import termio

/// How several `fs.list` requests become one directory listing — pinned without
/// a device, because both rules that were wrong here are decided by the merge
/// and not by the asking.
///
/// A directory larger than one page (`files.rs` `LIST_PAGE_SIZE`) takes more
/// than one request, and the directory is very likely being written while it is
/// read: an agent works in these.
final class TermiodPagedListingTests: XCTestCase {
    /// One `fs_listed` reply, built the way the daemon serializes it and
    /// decoded the way the client does — so the field names are covered too.
    private func reply(
        seq: UInt64,
        _ listings: [(path: String, names: [String], nextAfter: String?)],
        legacyNextPage: UInt64? = nil
    ) throws -> Termiod.FsListedPayload {
        let payload: [String: Any] = [
            "ev": "fs_listed",
            "seq": seq,
            "listings": listings.map { listing -> [String: Any] in
                var one: [String: Any] = [
                    "path": listing.path,
                    "entries": listing.names.map { ["name": $0, "kind": "file"] },
                ]
                if let next = listing.nextAfter { one["next_after"] = next }
                if let page = legacyNextPage { one["next_page"] = page }
                return one
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Termiod.FsListedPayload.self, from: data)
    }

    private func names(_ listings: Termiod.DirectoryListings, at path: String) -> [String] {
        listings.listings.first { $0.path == path }?.entries.map(\.name) ?? []
    }

    /// The whole listing carries its **first** request's stamp.
    ///
    /// Every `fs.list` is stamped with the resource cursor as the host read it,
    /// so a listing assembled from several is only as fresh as its earliest
    /// read. Claiming the newest is worse than merely optimistic: the tree
    /// hands that stamp to the watch as "already reflected", so the batch the
    /// mid-listing write raised — the one batch that would repair the torn
    /// read — is discarded as old news, and the wrong rows stay on screen for
    /// good.
    func testTheListingCarriesTheOldestStampNotTheNewest() throws {
        var paged = Termiod.PagedListings()
        paged.absorb(try reply(seq: 4, [("/r", ["a", "b"], "b")]))
        paged.absorb(try reply(seq: 9, [("/r", ["c"], nil)]), continuing: "/r")

        XCTAssertEqual(
            paged.listings.seq, 4,
            "a listing is only as fresh as its earliest read")
        XCTAssertEqual(names(paged.listings, at: "/r"), ["a", "b", "c"])
    }

    func testASinglePageListingKeepsItsOwnStamp() throws {
        var paged = Termiod.PagedListings()
        paged.absorb(try reply(seq: 12, [("/r", ["a"], nil)]))
        XCTAssertEqual(paged.listings.seq, 12)
        XCTAssertNil(paged.resumePoint(of: "/r"), "nothing to continue")
    }

    /// A host that answers a cursor with a page it has already served — one too
    /// old to understand `after`, so it keeps re-serving the first — must not
    /// put a row in the tree twice, and must not spin.
    func testAHostRepeatingAPageAddsNothingAndReportsNoProgress() throws {
        var paged = Termiod.PagedListings()
        paged.absorb(try reply(seq: 1, [("/r", ["a", "b"], "b")]))
        let progressed = paged.absorb(
            try reply(seq: 1, [("/r", ["a", "b"], "b")]), continuing: "/r")

        XCTAssertFalse(progressed, "the loop has to end rather than ask again forever")
        XCTAssertEqual(
            names(paged.listings, at: "/r"), ["a", "b"],
            "an entry served twice is still one row")
    }

    /// A host too old to continue a listing sends the offset it would page by
    /// and no cursor. The listing stops there — following an offset is the bug
    /// the cursor replaced — but it must be *known* to have stopped short.
    ///
    /// This is the field a client is tempted to drop once it no longer follows
    /// it, and dropping it makes the two replies that matter identical: "here
    /// is the directory" and "here are its first two thousand entries".
    func testAnOldHostsFirstPageIsRecordedAsShortRatherThanComplete() throws {
        var paged = Termiod.PagedListings()
        paged.absorb(try reply(seq: 1, [("/r", ["a", "b"], nil)], legacyNextPage: 1))

        XCTAssertNil(paged.resumePoint(of: "/r"), "there is no cursor to continue from")
        XCTAssertEqual(paged.shortened, ["/r"], "and the listing knows it stopped short")
        XCTAssertEqual(paged.count(of: "/r"), 2, "which is how far it got")
    }

    /// The ordinary complete listing, which must not be reported as short: no
    /// cursor *and* no offset means the host said everything it had.
    func testACompleteListingIsNotReportedAsShort() throws {
        var paged = Termiod.PagedListings()
        paged.absorb(try reply(seq: 1, [("/r", ["a", "b"], nil)]))
        XCTAssertNil(paged.resumePoint(of: "/r"))
        XCTAssertEqual(paged.shortened, [])
    }

    /// A host that pages by name is never reported as short, even though it
    /// also has more to give: it handed back a cursor, so the listing continues.
    func testAContinuableListingIsNotReportedAsShort() throws {
        var paged = Termiod.PagedListings()
        paged.absorb(try reply(seq: 1, [("/r", ["a", "b"], "b")]))
        XCTAssertEqual(paged.resumePoint(of: "/r"), "b")
        XCTAssertEqual(paged.shortened, [])
    }

    /// Continuations are per directory; the batched first request is what
    /// establishes the order, and a continuation never disturbs it.
    func testContinuingOneDirectoryLeavesTheOthersAlone() throws {
        var paged = Termiod.PagedListings()
        paged.absorb(try reply(seq: 3, [
            ("/r", ["big", "small"], nil),
            ("/r/big", ["a", "b"], "b"),
            ("/r/small", ["only"], nil),
        ]))
        paged.absorb(try reply(seq: 8, [("/r/big", ["c"], nil)]), continuing: "/r/big")

        XCTAssertEqual(paged.paths, ["/r", "/r/big", "/r/small"], "asked-for order is kept")
        XCTAssertEqual(names(paged.listings, at: "/r/big"), ["a", "b", "c"])
        XCTAssertEqual(names(paged.listings, at: "/r/small"), ["only"])
        XCTAssertEqual(paged.listings.seq, 3)
    }

    /// A directory that failed keeps the host's own reason, and one failing
    /// path never sinks the batch around it.
    func testAPathsErrorSurvivesTheMerge() throws {
        let payload: [String: Any] = [
            "ev": "fs_listed",
            "seq": 2,
            "listings": [
                ["path": "/r/gone", "entries": [], "error": "no such directory"],
                ["path": "/r", "entries": [["name": "a", "kind": "file"]]],
            ],
        ]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var paged = Termiod.PagedListings()
        paged.absorb(try decoder.decode(
            Termiod.FsListedPayload.self,
            from: try JSONSerialization.data(withJSONObject: payload)))

        let listings = paged.listings.listings
        XCTAssertEqual(listings.first { $0.path == "/r/gone" }?.error, "no such directory")
        XCTAssertNil(listings.first { $0.path == "/r" }?.error)
    }
}
