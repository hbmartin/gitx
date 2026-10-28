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
    case timedOut
    case cancelled
}

/// The two slots also bound uninterruptible launches and their cancellation workers.
/// A timed-out launch keeps its slot until the underlying operation actually returns.
final nonisolated class GitDiscoveryProbeRunner: Sendable {
    struct Operation: Sendable {
        let output: @Sendable () -> String?
        let cancel: @Sendable () -> Void
    }

    typealias Factory = @Sendable (String, [String], TimeInterval) -> Operation

    final class Request: Sendable {
        private struct State {
            var operation: Operation?
            var finished = false
        }

        let id = UUID()
        private let state = Mutex(State())
        private let cancellation = DispatchGroup()
        private let timing: GitDiscoveryTiming
        private let deadline: TimeInterval
        private let factory: @Sendable () -> Operation
        private let completion: @Sendable (GitDiscoveryProbeResult) -> Void

        init(timing: GitDiscoveryTiming, deadline: TimeInterval, factory: @escaping @Sendable () -> Operation, completion: @escaping @Sendable (GitDiscoveryProbeResult) -> Void) {
            self.timing = timing
            self.deadline = deadline
            self.factory = factory
            self.completion = completion
        }

        func execute() {
            guard !isFinished else { return }
            guard timing.now() < deadline else { cancel(timedOut: true); return }
            // Factory work and launch both belong to the owned worker slot.
            let operation = factory()
            guard timing.now() < deadline else { cancel(timedOut: true); return }
            let shouldStart = state.withLock { state in
                guard !state.finished else { return false }
                state.operation = operation
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
                completion(result)
            }
        }

        func cancel(timedOut: Bool = false) {
            let decision = state.withLock { state -> (Bool, Operation?) in
                guard !state.finished else { return (false, nil) }
                state.finished = true
                if state.operation != nil {
                    cancellation.enter()
                }
                return (true, state.operation)
            }
            guard decision.0 else { return }
            completion(timedOut ? .timedOut : .cancelled)
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
        var pending: Request?
    }

    private let state = Mutex(State())
    private let factory: Factory
    private let timing: GitDiscoveryTiming

    init(timing: GitDiscoveryTiming = .live, factory: @escaping Factory = liveOperation) {
        self.timing = timing
        self.factory = factory
    }

    @discardableResult
    func run(path: String, arguments: [String], timeout: TimeInterval,
             completion: @escaping @Sendable (GitDiscoveryProbeResult) -> Void) -> Request
    {
        let request = Request(timing: timing, deadline: timing.now() + timeout, factory: { [factory] in factory(path, arguments, timeout) }, completion: completion)
        let admission = state.withLock { state -> (Bool, Request?) in
            if state.active.count < 2 {
                state.active.insert(request.id)
                return (true, nil)
            }
            let replaced = state.pending
            state.pending = request
            return (false, replaced)
        }
        admission.1?.cancel()
        timing.schedule(timeout) { request.cancel(timedOut: true) }
        if admission.0 {
            execute(request)
        }
        return request
    }

    private func execute(_ request: Request) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            request.execute()
            // Keep the slot until both launch/output and any cancellation have returned.
            request.finishOwnedCancellation()
            let next = state.withLock { state -> Request? in
                state.active.remove(request.id)
                guard let next = state.pending else { return nil }
                state.pending = nil
                guard !next.isFinished else { return nil }
                state.active.insert(next.id)
                return next
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
