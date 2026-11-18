import AppKit
import Darwin
import Foundation
import TermioShared

/// One ready `ssh <host> termio stdio` per host, waiting for the next attach.
///
/// Opening that pipe is the largest cost of attaching on the SSH road, and the
/// host's distance does not excuse it: an SSH channel, a remote exec and the
/// bridge's start before the first frame. Measured against a VPS at 141 ms round
/// trip, connect → hello → attach → snapshot is **645 ms median on a fresh pipe
/// and 324 ms on a spare**.
///
/// A spare has not said hello, because each pane offers its own capabilities, so
/// the host sees no client and no attachment until a pane takes it. It stays its
/// own connection once taken: one attach per pipe, so no pane's output can queue
/// behind another's (§A).
extension Termiod {
    final class SpareSlots<Pipe: AnyObject>: @unchecked Sendable {
        private let open: @Sendable (String) throws -> Pipe
        private let isAlive: @Sendable (Pipe) -> Bool
        private let discard: @Sendable (Pipe) -> Void
        private let run: @Sendable (@escaping @Sendable () -> Void) -> Void
        private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
        private let lock = NSLock()
        private var spares: [String: Pipe] = [:]
        private var opening: Set<String> = []
        /// Moves on every attach, and only the newest timer may expire a spare.
        private var expiryGenerations: [String: UInt64] = [:]
        /// Moves on every drop. A pipe still opening across one was asked for by
        /// a state that no longer holds. Another attach succeeding does not move
        /// it: several panes attach at once at launch, and they share that pipe.
        private var dropGenerations: [String: UInt64] = [:]

        init(
            open: @escaping @Sendable (String) throws -> Pipe,
            isAlive: @escaping @Sendable (Pipe) -> Bool,
            discard: @escaping @Sendable (Pipe) -> Void,
            run: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
            schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
        ) {
            self.open = open
            self.isAlive = isAlive
            self.discard = discard
            self.run = run
            self.schedule = schedule
        }

        /// The host's spare if it is still alive. A dead one is closed here, so
        /// the caller opens a fresh pipe rather than failing on this one.
        func take(_ host: String) -> Pipe? {
            lock.lock()
            let taken = spares.removeValue(forKey: host)
            lock.unlock()
            guard let spare = taken else { return nil }
            if isAlive(spare) { return spare }
            discard(spare)
            return nil
        }

        /// Called after an attach succeeds, and only then, so a host that is down
        /// or refusing never has pipes opened against it in the background.
        func refill(_ host: String) {
            lock.lock()
            let expiryGeneration = (expiryGenerations[host] ?? 0) &+ 1
            expiryGenerations[host] = expiryGeneration
            let dropGeneration = dropGenerations[host] ?? 0
            let wanted = spares[host] == nil && opening.insert(host).inserted
            lock.unlock()
            armExpiry(host, generation: expiryGeneration)
            guard wanted else { return }
            run { [self] in
                do {
                    store(try open(host), for: host, dropGeneration: dropGeneration)
                } catch {
                    finishOpening(host)
                    Log.termiod.error("""
                    no spare pipe for \(host, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
                }
            }
        }

        func drop(_ host: String) {
            lock.lock()
            let spare = dropLocked(host)
            lock.unlock()
            if let spare { discard(spare) }
        }

        func dropAll() {
            lock.lock()
            let hosts = Array(Set(spares.keys).union(opening))
            lock.unlock()
            hosts.forEach(drop)
        }

        private func armExpiry(_ host: String, generation: UInt64) {
            schedule { [self] in
                // Checked and dropped under one lock, or an attach landing between
                // the two would see its fresh spare dropped by this stale timer.
                lock.lock()
                let spare = expiryGenerations[host] == generation ? dropLocked(host) : nil
                lock.unlock()
                if let spare { discard(spare) }
            }
        }

        private func dropLocked(_ host: String) -> Pipe? {
            dropGenerations[host] = (dropGenerations[host] ?? 0) &+ 1
            return spares.removeValue(forKey: host)
        }

        private func store(_ pipe: Pipe, for host: String, dropGeneration: UInt64) {
            lock.lock()
            opening.remove(host)
            let current = (dropGenerations[host] ?? 0) == dropGeneration && spares[host] == nil
            if current { spares[host] = pipe }
            lock.unlock()
            if !current { discard(pipe) }
        }

        private func finishOpening(_ host: String) {
            lock.lock()
            opening.remove(host)
            lock.unlock()
        }
    }
}

extension Termiod.Transport {
    /// Matches `ControlPersist`, so a spare never holds the shared connection open
    /// longer than the last attach would have by itself.
    private static let spareLifetime: DispatchTimeInterval = .seconds(10 * 60)

    private static let spares: Termiod.SpareSlots<Termiod.Transport> = {
        let slots = Termiod.SpareSlots<Termiod.Transport>(
            open: { try Termiod.Transport.ssh(host: $0) },
            isAlive: { $0.isQuietAndOpen },
            discard: { $0.close() },
            run: { DispatchQueue.global(qos: .utility).async(execute: $0) },
            schedule: { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + spareLifetime, execute: $0) }
        )
        // A laptop that slept has connections that look open and are not. Hello on
        // one would wait out ServerAlive while a fresh pipe answers at once.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in slots.dropAll() }
        return slots
    }()

    /// A host says nothing before hello, so anything to read on a spare is its
    /// end-of-file or a failure, and either way not a pipe to attach over.
    private var isQuietAndOpen: Bool { Self.isQuiet(readDescriptor) }

    static func isQuiet(_ fileDescriptor: Int32) -> Bool {
        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, 0) == 0
    }

    /// The pipe for an attach: the host's spare when there is one.
    static func openForAttach(_ route: TermiodRoute) throws -> Termiod.Transport {
        if case .ssh(let host) = route, let spare = spares.take(host) { return spare }
        return try open(route)
    }

    /// The pipe for reattaching after a lost connection. The spare went over the
    /// same road, so it is the one pipe known to be suspect.
    static func openAfterLostConnection(_ route: TermiodRoute) throws -> Termiod.Transport {
        if case .ssh(let host) = route { spares.drop(host) }
        return try open(route)
    }

    /// Only where this app's own `ControlPersist` forks the master into a process
    /// of its own. Without it the first ssh to connect is the master, and a spare
    /// that became one would take every other pane on the host down when it expires.
    static func prepareNextAttach(_ route: TermiodRoute) {
        guard case .ssh(let host) = route,
              Termiod.sshArguments(host: host).contains(Termiod.controlPersist)
        else { return }
        spares.refill(host)
    }
}
