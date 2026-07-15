import Dispatch
import Foundation
import Synchronization

protocol RepositoryRefreshScheduledAction: AnyObject, Sendable {
    func cancel()
}

protocol RepositoryRefreshScheduling: AnyObject, Sendable {
    /// Implementations enqueue `action`; they must not execute it synchronously.
    func schedule(
        after delay: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> any RepositoryRefreshScheduledAction
}

private final class DispatchRepositoryRefreshAction: RepositoryRefreshScheduledAction, Sendable {
    private let isCancelled = Mutex(false)

    func cancel() {
        isCancelled.withLock { $0 = true }
    }

    func perform(_ action: @Sendable () -> Void) {
        let shouldPerform = isCancelled.withLock { !$0 }

        if shouldPerform {
            action()
        }
    }
}

private final class DispatchRepositoryRefreshScheduler: RepositoryRefreshScheduling, Sendable {
    private let queue = DispatchQueue(label: "org.gitx.repositoryRefreshCoordinator")

    func schedule(
        after delay: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> any RepositoryRefreshScheduledAction {
        let scheduledAction = DispatchRepositoryRefreshAction()
        queue.asyncAfter(deadline: .now() + delay) {
            scheduledAction.perform(action)
        }
        return scheduledAction
    }
}

/// Coalesces duplicate controller invalidations into one refresh on the next main-loop turn.
@MainActor
@objc(PBRefreshCoalescer)
final class RefreshCoalescer: NSObject { // swiftlint:disable:this unused_declaration
    private let deliveryHandler: () -> Void
    private var generation: UInt64 = 0
    private var scheduledGeneration: UInt64?

    @objc(initWithDeliveryHandler:)
    init(deliveryHandler: @escaping () -> Void) {
        self.deliveryHandler = deliveryHandler
    }

    @objc
    func requestRefresh() {
        guard scheduledGeneration == nil else {
            NSLog("[GitX] Coalesced a duplicate stage-diff refresh request")
            return
        }

        generation &+= 1
        let requestedGeneration = generation
        scheduledGeneration = requestedGeneration

        NSLog("[GitX] Scheduled a stage-diff refresh for the next main-loop turn")

        DispatchQueue.main.async { [weak self] in
            self?.deliver(generation: requestedGeneration)
        }
    }

    @objc
    func cancel() {
        generation &+= 1
        scheduledGeneration = nil
        NSLog("[GitX] Cancelled the pending stage-diff refresh")
    }

    private func deliver(generation requestedGeneration: UInt64) {
        guard scheduledGeneration == requestedGeneration else {
            return
        }
        scheduledGeneration = nil

        NSLog("[GitX] Delivering one coalesced stage-diff refresh")
        deliveryHandler()
    }
}

/// Debounces repository events for the Objective-C repository watcher.
@objc(PBRepositoryRefreshCoordinator)
final class RepositoryRefreshCoordinator: NSObject, Sendable { // swiftlint:disable:this unused_declaration
    typealias DeliveryHandler = @Sendable (UInt, [String]) -> Void
    typealias CallbackExecutor = @Sendable (@escaping @Sendable () -> Void) -> Void

    private struct State {
        var accumulatedEventType: UInt = 0
        var accumulatedPaths = Set<String>()
        var generation: UInt64 = 0
        var cancellationGeneration: UInt64 = 0
        var scheduledAction: (any RepositoryRefreshScheduledAction)?
    }

    private let delay: TimeInterval
    private let scheduler: any RepositoryRefreshScheduling
    private let callbackExecutor: CallbackExecutor
    private let deliveryHandler: DeliveryHandler
    private let state = Mutex(State())

    @objc(initWithDelay:deliveryHandler:)
    convenience init(delay: TimeInterval, deliveryHandler: @escaping DeliveryHandler) {
        self.init(
            delay: delay,
            scheduler: DispatchRepositoryRefreshScheduler(),
            callbackExecutor: { action in
                DispatchQueue.main.async(execute: action)
            },
            deliveryHandler: deliveryHandler
        )
    }

    init(
        delay: TimeInterval,
        scheduler: any RepositoryRefreshScheduling,
        callbackExecutor: @escaping CallbackExecutor,
        deliveryHandler: @escaping DeliveryHandler
    ) {
        self.delay = delay
        self.scheduler = scheduler
        self.callbackExecutor = callbackExecutor
        self.deliveryHandler = deliveryHandler
    }

    deinit {
        cancel()
    }

    @objc(recordEventType:paths:)
    func record(eventType: UInt, paths: [String]) { // swiftlint:disable:this unused_declaration
        guard eventType != 0 else { return }

        state.withLock { state in
            state.accumulatedEventType |= eventType
            state.accumulatedPaths.formUnion(paths)
            state.generation &+= 1
            let scheduledGeneration = state.generation
            state.scheduledAction?.cancel()
            state.scheduledAction = scheduler.schedule(after: delay) { [weak self] in
                self?.deliver(generation: scheduledGeneration)
            }
        }
    }

    @objc
    func cancel() {
        state.withLock { state in
            state.generation &+= 1
            state.cancellationGeneration &+= 1
            state.scheduledAction?.cancel()
            state.scheduledAction = nil
            state.accumulatedEventType = 0
            state.accumulatedPaths.removeAll(keepingCapacity: false)
        }
    }

    private func deliver(generation scheduledGeneration: UInt64) {
        let delivery: (eventType: UInt, paths: [String], cancellationGeneration: UInt64)? = state.withLock { state in
            guard scheduledGeneration == state.generation else {
                return nil
            }

            let delivery = (
                eventType: state.accumulatedEventType,
                paths: state.accumulatedPaths.sorted(),
                cancellationGeneration: state.cancellationGeneration
            )
            state.scheduledAction = nil
            state.accumulatedEventType = 0
            state.accumulatedPaths.removeAll(keepingCapacity: true)
            return delivery
        }

        guard let delivery else { return }

        callbackExecutor { [weak self] in
            self?.deliverIfNotCancelled(
                eventType: delivery.eventType,
                paths: delivery.paths,
                cancellationGeneration: delivery.cancellationGeneration
            )
        }
    }

    private func deliverIfNotCancelled(
        eventType: UInt,
        paths: [String],
        cancellationGeneration scheduledCancellationGeneration: UInt64
    ) {
        let wasCancelled = state.withLock {
            scheduledCancellationGeneration != $0.cancellationGeneration
        }

        if !wasCancelled {
            deliveryHandler(eventType, paths)
        }
    }
}
