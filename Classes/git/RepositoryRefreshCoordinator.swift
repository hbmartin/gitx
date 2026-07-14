import Foundation

protocol RepositoryRefreshScheduledAction: AnyObject {
    func cancel()
}

protocol RepositoryRefreshScheduling: AnyObject {
    /// Implementations enqueue `action`; they must not execute it synchronously.
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> RepositoryRefreshScheduledAction
}

private final class DispatchRepositoryRefreshAction: RepositoryRefreshScheduledAction {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func perform(_ action: () -> Void) {
        lock.lock()
        let shouldPerform = !isCancelled
        lock.unlock()

        if shouldPerform {
            action()
        }
    }
}

private final class DispatchRepositoryRefreshScheduler: RepositoryRefreshScheduling {
    private let queue = DispatchQueue(label: "org.gitx.repositoryRefreshCoordinator")

    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> RepositoryRefreshScheduledAction {
        let scheduledAction = DispatchRepositoryRefreshAction()
        queue.asyncAfter(deadline: .now() + delay) {
            scheduledAction.perform(action)
        }
        return scheduledAction
    }
}

/// Debounces repository events for the Objective-C repository watcher.
@objc(PBRepositoryRefreshCoordinator)
final class RepositoryRefreshCoordinator: NSObject { // swiftlint:disable:this unused_declaration
    typealias DeliveryHandler = (UInt, [String]) -> Void

    private let delay: TimeInterval
    private let scheduler: RepositoryRefreshScheduling
    private let callbackExecutor: (@escaping () -> Void) -> Void
    private let deliveryHandler: DeliveryHandler
    private let lock = NSLock()

    private var accumulatedEventType: UInt = 0
    private var accumulatedPaths = Set<String>()
    private var generation: UInt64 = 0
    private var cancellationGeneration: UInt64 = 0
    private var scheduledAction: RepositoryRefreshScheduledAction?

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
        scheduler: RepositoryRefreshScheduling,
        callbackExecutor: @escaping (@escaping () -> Void) -> Void,
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

        lock.lock()
        accumulatedEventType |= eventType
        accumulatedPaths.formUnion(paths)
        generation &+= 1
        let scheduledGeneration = generation
        scheduledAction?.cancel()
        scheduledAction = scheduler.schedule(after: delay) { [weak self] in
            self?.deliver(generation: scheduledGeneration)
        }
        lock.unlock()
    }

    @objc
    func cancel() {
        lock.lock()
        generation &+= 1
        cancellationGeneration &+= 1
        scheduledAction?.cancel()
        scheduledAction = nil
        accumulatedEventType = 0
        accumulatedPaths.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func deliver(generation scheduledGeneration: UInt64) {
        lock.lock()
        guard scheduledGeneration == generation else {
            lock.unlock()
            return
        }

        let eventType = accumulatedEventType
        let paths = accumulatedPaths.sorted()
        let scheduledCancellationGeneration = cancellationGeneration
        scheduledAction = nil
        accumulatedEventType = 0
        accumulatedPaths.removeAll(keepingCapacity: true)
        lock.unlock()

        callbackExecutor { [weak self] in
            self?.deliverIfNotCancelled(
                eventType: eventType,
                paths: paths,
                cancellationGeneration: scheduledCancellationGeneration
            )
        }
    }

    private func deliverIfNotCancelled(
        eventType: UInt,
        paths: [String],
        cancellationGeneration scheduledCancellationGeneration: UInt64
    ) {
        lock.lock()
        let wasCancelled = scheduledCancellationGeneration != cancellationGeneration
        lock.unlock()

        if !wasCancelled {
            deliveryHandler(eventType, paths)
        }
    }
}
