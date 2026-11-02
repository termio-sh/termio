import Testing
import Darwin
import Foundation
import TermioShared
@testable import termio

@Suite struct TermiodSpareSlotsTests {
    final class Pipe: @unchecked Sendable {
        var alive = true
        var discarded = false
    }

    final class Harness: @unchecked Sendable {
        var opened: [Pipe] = []
        var failing = false
        var pendingRuns: [@Sendable () -> Void] = []
        var holdRuns = false
        var expiries: [@Sendable () -> Void] = []
        lazy var slots = Termiod.SpareSlots<Pipe>(
            open: { [self] _ in
                if failing { throw TermiodClientError.daemonUnreachable("down") }
                let pipe = Pipe()
                opened.append(pipe)
                return pipe
            },
            isAlive: { $0.alive },
            discard: { $0.discarded = true },
            run: { [self] work in
                if holdRuns { pendingRuns.append(work) } else { work() }
            },
            schedule: { [self] work in expiries.append(work) }
        )
    }

    @Test func nothingIsOpenedBeforeAnAttachSucceeds() {
        let harness = Harness()
        #expect(harness.slots.take("box") == nil)
        #expect(harness.opened.isEmpty)
    }

    @Test func aSpareIsHandedOutOnce() throws {
        let harness = Harness()
        harness.slots.refill("box")
        let spare = try #require(harness.slots.take("box"))
        #expect(spare === harness.opened[0])
        #expect(!spare.discarded)
        #expect(harness.slots.take("box") == nil)
    }

    @Test func oneSparePerHostHoweverManyAttachesSucceed() {
        let harness = Harness()
        harness.slots.refill("box")
        harness.slots.refill("box")
        #expect(harness.opened.count == 1)
        harness.slots.refill("other")
        #expect(harness.opened.count == 2)
    }

    @Test func aPipeStillOpeningIsNotOpenedTwice() {
        let harness = Harness()
        harness.holdRuns = true
        harness.slots.refill("box")
        harness.slots.refill("box")
        #expect(harness.pendingRuns.count == 1)
    }

    @Test func severalAttachesWhileOpeningStillLeaveTheSpare() throws {
        let harness = Harness()
        harness.holdRuns = true
        harness.slots.refill("box")
        harness.slots.refill("box")
        harness.pendingRuns[0]()
        #expect(!harness.opened[0].discarded)
        let spare = try #require(harness.slots.take("box"))
        #expect(spare === harness.opened[0])
    }

    @Test func anAttachTakingNothingKeepsThePipeStillOpening() throws {
        let harness = Harness()
        harness.holdRuns = true
        harness.slots.refill("box")
        #expect(harness.slots.take("box") == nil)
        harness.pendingRuns[0]()
        #expect(!harness.opened[0].discarded)
        #expect(harness.slots.take("box") != nil)
    }

    @Test func aPipeIsQuietUntilItsOtherEndSpeaksOrCloses() throws {
        var ends: [Int32] = [-1, -1]
        #expect(pipe(&ends) == 0)
        defer { close(ends[0]) }
        #expect(Termiod.Transport.isQuiet(ends[0]))
        close(ends[1])
        #expect(!Termiod.Transport.isQuiet(ends[0]))
    }

    @Test func aDeadSpareIsClosedAndNotHandedOut() {
        let harness = Harness()
        harness.slots.refill("box")
        harness.opened[0].alive = false
        #expect(harness.slots.take("box") == nil)
        #expect(harness.opened[0].discarded)
    }

    @Test func aSpareExpiresWhenNoAttachFollows() {
        let harness = Harness()
        harness.slots.refill("box")
        harness.expiries.last?()
        #expect(harness.opened[0].discarded)
        #expect(harness.slots.take("box") == nil)
    }

    @Test func aLaterAttachPostponesTheExpiry() throws {
        let harness = Harness()
        harness.slots.refill("box")
        let first = try #require(harness.expiries.last)
        harness.slots.refill("box")
        first()
        #expect(!harness.opened[0].discarded)
        #expect(harness.slots.take("box") != nil)
    }

    @Test func aPipeThatFinishesOpeningAfterADropIsClosed() {
        let harness = Harness()
        harness.holdRuns = true
        harness.slots.refill("box")
        harness.slots.drop("box")
        harness.pendingRuns[0]()
        #expect(harness.opened[0].discarded)
        #expect(harness.slots.take("box") == nil)
    }

    @Test func aPipeThatFinishesOpeningAfterDropAllIsClosed() {
        let harness = Harness()
        harness.holdRuns = true
        harness.slots.refill("box")
        harness.slots.dropAll()
        harness.pendingRuns[0]()
        #expect(harness.opened[0].discarded)
    }

    @Test func aFailedOpenLeavesTheNextAttachFreeToTryAgain() {
        let harness = Harness()
        harness.failing = true
        harness.slots.refill("box")
        harness.failing = false
        harness.slots.refill("box")
        #expect(harness.opened.count == 1)
    }
}
