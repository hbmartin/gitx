import Foundation

nonisolated enum RepositoryLocalMutationError: Error, Equatable, LocalizedError {
    case terminationPending
    var errorDescription: String? {
        "Half Dark is waiting to quit. Cancel Quit before starting another repository mutation."
    }
}

/// A started writer owns a ticket until its synchronous work has drained.
/// Internal continuations remain countable after admission has been sealed.
// swift6-safety-justification: The lock protects tickets, admission and thread nesting; callbacks run outside the lock.
final nonisolated class RepositoryLocalMutationRegistry: @unchecked Sendable {
    static let shared = RepositoryLocalMutationRegistry()
    struct Ticket: Sendable {
        fileprivate let identity: UUID
        fileprivate let thread: ObjectIdentifier?
        fileprivate let joins: Bool
    }

    struct FetchReservation: Sendable {
        fileprivate let identity: UUID
    }

    private let lock = NSLock()
    private var active: Set<UUID> = []
    private var reservedFetches: [UUID: Bool] = [:]
    private var threads: [ObjectIdentifier: Int] = [:]
    private var sealed = false
    private var observers: [UUID: @Sendable () -> Void] = [:]

    var hasActivity: Bool {
        lock.withLock { !active.isEmpty }
    }

    func hasActivity(includingReservedFetches: Bool) -> Bool {
        lock.withLock { !active.isEmpty || (includingReservedFetches && reservedFetches.values.contains(true)) }
    }

    func reserveFetch() throws -> FetchReservation {
        try lock.withLock {
            guard !sealed else { throw RepositoryLocalMutationError.terminationPending }
            let id = UUID()
            reservedFetches[id] = false
            return FetchReservation(identity: id)
        }
    }

    func activateFetchReservation(_ reservation: FetchReservation) {
        lock.withLock {
            if reservedFetches[reservation.identity] != nil {
                reservedFetches[reservation.identity] = true
            }
        }
    }

    func beginReservedFetch(_ reservation: FetchReservation) throws -> Ticket {
        try lock.withLock {
            guard reservedFetches.removeValue(forKey: reservation.identity) == true else {
                throw RepositoryLocalMutationError.terminationPending
            }
            return register(thread: nil, joins: true)
        }
    }

    func releaseFetchReservation(_ reservation: FetchReservation) {
        let notify = lock.withLock { () -> [@Sendable () -> Void] in
            guard reservedFetches.removeValue(forKey: reservation.identity) != nil else { return [] }
            return Array(observers.values)
        }
        notify.forEach { $0() }
    }

    func abandonReservedFetchesForQuit() {
        let notify = lock.withLock {
            reservedFetches.removeAll()
            return Array(observers.values)
        }
        notify.forEach { $0() }
    }

    @discardableResult
    func observe(_ change: @escaping @Sendable () -> Void) -> UUID {
        lock.withLock {
            let id = UUID()
            observers[id] = change
            return id
        }
    }

    func removeObserver(_ id: UUID) {
        lock.withLock { _ = observers.removeValue(forKey: id) }
    }

    func sealAdmission() {
        lock.withLock { sealed = true }
    }

    func reopenAdmission() {
        lock.withLock { sealed = false }
    }

    func admit() throws -> Ticket {
        try lock.withLock {
            let thread = ObjectIdentifier(Thread.current)
            guard !sealed || threads[thread, default: 0] > 0 else { throw RepositoryLocalMutationError.terminationPending }
            return register(thread: thread, joins: true)
        }
    }

    func admitContinuation(requiresOpenAdmission: Bool = false) throws -> Ticket {
        try lock.withLock {
            let thread = ObjectIdentifier(Thread.current)
            guard !sealed || (!requiresOpenAdmission && threads[thread, default: 0] > 0) else { throw RepositoryLocalMutationError.terminationPending }
            return register(thread: nil, joins: true)
        }
    }

    func trackContinuation() -> Ticket {
        lock.withLock {
            let thread = ObjectIdentifier(Thread.current)
            return register(thread: nil, joins: !sealed || threads[thread, default: 0] > 0)
        }
    }

    private func register(thread: ObjectIdentifier?, joins: Bool) -> Ticket {
        let identity = UUID()
        active.insert(identity)
        if joins, let thread {
            threads[thread, default: 0] += 1
        }
        return Ticket(identity: identity, thread: thread, joins: joins)
    }

    func withStartedActivity<Value>(_ ticket: Ticket, _ work: () throws -> Value) rethrows -> Value {
        let thread = ObjectIdentifier(Thread.current)
        if ticket.joins {
            lock.withLock { threads[thread, default: 0] += 1 }
        }
        defer {
            if ticket.joins {
                lock.withLock { releaseThread(thread) }
            }
        }
        return try work()
    }

    func finish(_ ticket: Ticket) {
        let notify = lock.withLock { () -> [@Sendable () -> Void] in
            guard active.remove(ticket.identity) != nil else { return [] }
            if ticket.joins, let thread = ticket.thread {
                releaseThread(thread)
            }
            return Array(observers.values)
        }
        for observer in notify {
            observer()
        }
    }

    private func releaseThread(_ thread: ObjectIdentifier) {
        let count = threads[thread, default: 0] - 1
        if count > 0 {
            threads[thread] = count
        } else {
            threads[thread] = nil
        }
    }
}
