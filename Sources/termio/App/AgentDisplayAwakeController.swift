import Combine
import Foundation
import IOKit.pwr_mgt
import TermioShared
import os

@MainActor
final class AgentDisplayAwakeController {
    private let store: TermioStore
    private let createAssertion: @MainActor () -> IOPMAssertionID?
    private let releaseAssertion: @MainActor (IOPMAssertionID) -> Bool
    private var assertionID: IOPMAssertionID?
    private var cancellables: Set<AnyCancellable> = []
    private var stopped = false

    init(
        store: TermioStore,
        createAssertion: @escaping @MainActor () -> IOPMAssertionID? = AgentDisplayAwakeController.createDisplayAssertion,
        releaseAssertion: @escaping @MainActor (IOPMAssertionID) -> Bool = AgentDisplayAwakeController.releaseDisplayAssertion
    ) {
        self.store = store
        self.createAssertion = createAssertion
        self.releaseAssertion = releaseAssertion
        // Read settled values: both the settings and structural publishers fire before mutation.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        store.sessionRuntimeDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        store.settings.$keepDisplayAwakeWhileWorking
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    func refresh() {
        guard !stopped else { return }
        let hasWorkingAgent = store.allSessions.contains { session in
            // A remote agent can still have a terminal identity; its reported status is the evidence.
            // A lost or ended link must not leave an old working status holding the display on.
            store.termiodLinks[session.id] != nil
                && store.connectionNotice(for: session.id) == nil
                && store.runtimes[session.id]?.isAgentWorking == true
        }
        if store.settings.keepDisplayAwakeWhileWorking && hasWorkingAgent {
            if assertionID == nil { assertionID = createAssertion() }
        } else {
            release()
        }
    }

    func stop() {
        stopped = true
        cancellables.removeAll()
        release()
    }

    private func release() {
        guard let assertionID else { return }
        if releaseAssertion(assertionID) { self.assertionID = nil }
    }

    private static func createDisplayAssertion() -> IOPMAssertionID? {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Termio agent is working" as CFString,
            &assertionID)
        guard result == kIOReturnSuccess else {
            Log.app.error("Could not prevent display sleep: \(result)")
            return nil
        }
        return assertionID
    }

    private static func releaseDisplayAssertion(_ assertionID: IOPMAssertionID) -> Bool {
        let result = IOPMAssertionRelease(assertionID)
        guard result == kIOReturnSuccess else {
            Log.app.error("Could not release display sleep assertion: \(result)")
            return false
        }
        return true
    }
}
