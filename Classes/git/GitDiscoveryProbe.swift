import Foundation
import Synchronization

/// Monotonic deadlines are independent of probe launch, process drainage and UI delivery.
nonisolated struct GitDiscoveryTiming: Sendable {
    let now: @Sendable () -> TimeInterval
    let schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    static let live = GitDiscoveryTiming(now: { ProcessInfo.processInfo.systemUptime }, schedule: { delay, action in
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, delay), execute: action)
    })
}

nonisolated enum GitDiscoveryProbeResult: Sendable {
    case output(String?)
    case timedOut(started: Bool)
    case cancelled(started: Bool)
    case busy

    var executionBegan: Bool {
        switch self {
        case .output: true
        case let .timedOut(started), let .cancelled(started): started
        case .busy: false
        }
    }
}

/// The two slots also bound uninterruptible launches and their cancellation workers.
/// A timed-out launch keeps its slot until the underlying operation actually returns.
final nonisolated class GitDiscoveryProbeRunner: Sendable {
    private enum Admission { case start, wait, busy }
    struct Operation: Sendable {
        let output: @Sendable () -> String?
        let cancel: @Sendable () -> Void
    }

    typealias Factory = @Sendable (String, [String], TimeInterval) -> Operation

    final class Request: Sendable {
        private struct State {
            var operation: Operation?
            var finished = false
            var executionBegan = false
        }

        let id = UUID()
        private let state = Mutex(State())
        private let cancellation = DispatchGroup()
        private let timing: GitDiscoveryTiming
        private let deadline: TimeInterval
        private let factory: @Sendable (TimeInterval) -> Operation
        private let completion: @Sendable (GitDiscoveryProbeResult) -> Void
        private let finished: @Sendable (UUID) -> Void

        init(timing: GitDiscoveryTiming, deadline: TimeInterval, factory: @escaping @Sendable (TimeInterval) -> Operation,
             finished: @escaping @Sendable (UUID) -> Void, completion: @escaping @Sendable (GitDiscoveryProbeResult) -> Void)
        {
            self.timing = timing
            self.deadline = deadline
            self.factory = factory
            self.finished = finished
            self.completion = completion
        }

        func execute() {
            guard !isFinished else { return }
            guard timing.now() < deadline else { cancel(timedOut: true); return }
            // Factory work and launch both belong to the owned worker slot.
            let operation = factory(max(0, deadline - timing.now()))
            guard timing.now() < deadline else { cancel(timedOut: true); return }
            let shouldStart = state.withLock { state in
                guard !state.finished else { return false }
                state.operation = operation
                state.executionBegan = true
                return true
            }
            if shouldStart {
                let output = operation.output()
                if timing.now() >= deadline {
                    cancel(timedOut: true)
                } else {
                    finish(.output(output))
                }
            }
        }

        func finish(_ result: GitDiscoveryProbeResult) {
            let accepted = state.withLock { state in
                guard !state.finished else { return false }
                state.finished = true
                return true
            }
            if accepted {
                finished(id)
                completion(result)
            }
        }

        func cancel(timedOut: Bool = false) {
            let decision = state.withLock { state -> (Bool, Operation?, Bool) in
                guard !state.finished else { return (false, nil, state.executionBegan) }
                state.finished = true
                if state.operation != nil {
                    cancellation.enter()
                }
                return (true, state.operation, state.executionBegan)
            }
            guard decision.0 else { return }
            finished(id)
            completion(timedOut ? .timedOut(started: decision.2) : .cancelled(started: decision.2))
            if let operation = decision.1 {
                // PBTask cancellation can wait for a stalled launch lock. Never put
                // that wait on the deadline queue or the main actor.
                DispatchQueue.global(qos: .utility).async { [cancellation] in
                    operation.cancel()
                    cancellation.leave()
                }
            }
        }

        func finishOwnedCancellation() {
            cancellation.wait()
        }

        var isFinished: Bool {
            state.withLock { $0.finished }
        }
    }

    private struct State {
        var active: Set<UUID> = []
        var pending: [Request] = []
    }

    private let state = Mutex(State())
    private let factory: Factory
    private let timing: GitDiscoveryTiming
    private let admissionObserver: @Sendable (Request) -> Void
    static let pendingCapacity = 16

    init(timing: GitDiscoveryTiming = .live, factory: @escaping Factory = liveOperation,
         admissionObserver: @escaping @Sendable (Request) -> Void = { _ in })
    {
        self.timing = timing
        self.factory = factory
        self.admissionObserver = admissionObserver
    }

    @discardableResult
    func run(path: String, arguments: [String], timeout: TimeInterval, deadline: TimeInterval? = nil,
             completion: @escaping @Sendable (GitDiscoveryProbeResult) -> Void) -> Request
    {
        let absoluteDeadline = min(timing.now() + timeout, deadline ?? .infinity)
        let request = Request(timing: timing, deadline: absoluteDeadline, factory: { [factory] remaining in factory(path, arguments, remaining) },
                              finished: { [weak self] id in self?.removeQueuedRequest(id) }, completion: completion)
        let admission = state.withLock { state -> Admission in
            state.pending.removeAll { $0.isFinished }
            if state.active.count < 2, state.pending.isEmpty {
                state.active.insert(request.id)
                return .start
            }
            guard state.pending.count < Self.pendingCapacity else { return .busy }
            state.pending.append(request)
            return .wait
        }
        guard admission != .busy else {
            NSLog("[GitDiscovery] Refused probe admission: both workers and %ld waiting slots are occupied", Self.pendingCapacity)
            request.finish(.busy)
            return request
        }
        timing.schedule(max(0, absoluteDeadline - timing.now())) { request.cancel(timedOut: true) }
        admissionObserver(request)
        if admission == .start {
            execute(request)
        }
        return request
    }

    private func removeQueuedRequest(_ id: UUID) {
        state.withLock { $0.pending.removeAll { $0.id == id } }
    }

    private func execute(_ request: Request) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            request.execute()
            // Keep the slot until both launch/output and any cancellation have returned.
            request.finishOwnedCancellation()
            let next = state.withLock { state -> Request? in
                state.active.remove(request.id)
                while !state.pending.isEmpty {
                    let next = state.pending.removeFirst()
                    guard !next.isFinished else { continue }
                    state.active.insert(next.id)
                    return next
                }
                return nil
            }
            if let next {
                execute(next)
            }
        }
    }

    // swift6-safety-justification: Configuration is frozen before publication; PBTask serializes launch and cancellation internally.
    private final class OwnedTask: @unchecked Sendable {
        private let task: PBTask
        init(path: String, arguments: [String], timeout: TimeInterval) {
            task = PBTask(launchPath: path, arguments: arguments, inDirectory: nil)
            task.timeout = timeout
        }

        func output() -> String? {
            do {
                try task.launch()
                return task.standardOutputString()
            } catch {
                NSLog("[GitDiscovery] Probe failed: %@", String(describing: error))
                return nil
            }
        }

        func cancel() {
            task.terminate(afterGracePeriod: 0, forceKillAfter: 0.25)
        }
    }

    private static func liveOperation(path: String, arguments: [String], timeout: TimeInterval) -> Operation {
        let task = OwnedTask(path: path, arguments: arguments, timeout: timeout)
        return Operation(output: { task.output() }, cancel: { task.cancel() })
    }
}
