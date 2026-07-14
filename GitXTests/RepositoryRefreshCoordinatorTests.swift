@testable import GitX
import XCTest

private final class TestRepositoryRefreshAction: RepositoryRefreshScheduledAction {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

private final class TestRepositoryRefreshScheduler: RepositoryRefreshScheduling {
    private struct Entry {
        let deadline: TimeInterval
        let order: Int
        let token: TestRepositoryRefreshAction
        let action: () -> Void
    }

    private var entries: [Entry] = []
    private var nextOrder = 0
    private(set) var now: TimeInterval = 0

    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> RepositoryRefreshScheduledAction {
        let token = TestRepositoryRefreshAction()
        entries.append(Entry(deadline: now + delay, order: nextOrder, token: token, action: action))
        nextOrder += 1
        return token
    }

    func advance(by interval: TimeInterval, includingCancelledActions: Bool = false) {
        let target = now + interval

        while let nextIndex = entries.indices
            .filter({ entries[$0].deadline <= target })
            .min(by: {
                let lhs = entries[$0]
                let rhs = entries[$1]
                return lhs.deadline == rhs.deadline ? lhs.order < rhs.order : lhs.deadline < rhs.deadline
            })
        {
            let entry = entries.remove(at: nextIndex)
            now = entry.deadline
            if includingCancelledActions || !entry.token.isCancelled {
                entry.action()
            }
        }

        now = target
    }
}

private final class TestRepositoryRefreshCallbackExecutor {
    private var actions: [() -> Void] = []

    func enqueue(_ action: @escaping () -> Void) {
        actions.append(action)
    }

    func runAll() {
        let pendingActions = actions
        actions.removeAll()
        pendingActions.forEach { $0() }
    }
}

final class RepositoryRefreshCoordinatorTests: XCTestCase {
    func testProductionSchedulerDeliversLatestBatchOnMainThread() {
        let delivered = expectation(description: "Refresh batch delivered")
        var delivery: (eventType: UInt, paths: [String])?
        let coordinator = RepositoryRefreshCoordinator(delay: 0.01) { eventType, paths in
            XCTAssertTrue(Thread.isMainThread)
            delivery = (eventType, paths)
            delivered.fulfill()
        }

        coordinator.record(eventType: 2, paths: ["/repo/.git/HEAD"])
        coordinator.record(eventType: 4, paths: ["/repo/work.swift"])

        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(delivery?.eventType, 6)
        XCTAssertEqual(delivery?.paths, ["/repo/.git/HEAD", "/repo/work.swift"])
        withExtendedLifetime(coordinator) {}
    }

    func testTrailingEdgeDeliveryUnionsEventTypesAndDeduplicatesPaths() {
        let scheduler = TestRepositoryRefreshScheduler()
        var deliveries: [(eventType: UInt, paths: [String])] = []
        let coordinator = makeCoordinator(scheduler: scheduler) { eventType, paths in
            deliveries.append((eventType, paths))
        }

        coordinator.record(eventType: 2, paths: ["/repo/.git/HEAD", "/repo/shared"])
        scheduler.advance(by: 0.3)
        coordinator.record(eventType: 4, paths: ["/repo/work.swift", "/repo/shared"])
        scheduler.advance(by: 0.49)

        XCTAssertTrue(deliveries.isEmpty)

        scheduler.advance(by: 0.01)

        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries[0].eventType, 6)
        XCTAssertEqual(deliveries[0].paths, ["/repo/.git/HEAD", "/repo/shared", "/repo/work.swift"])
    }

    func testCancellationDropsPendingBatch() {
        let scheduler = TestRepositoryRefreshScheduler()
        var deliveries = 0
        let coordinator = makeCoordinator(scheduler: scheduler) { _, _ in
            deliveries += 1
        }

        coordinator.record(eventType: 4, paths: ["/repo/work.swift"])
        coordinator.cancel()
        scheduler.advance(by: 1)

        XCTAssertEqual(deliveries, 0)
    }

    func testCancellationDropsBatchAwaitingCallbackExecution() {
        let scheduler = TestRepositoryRefreshScheduler()
        let callbackExecutor = TestRepositoryRefreshCallbackExecutor()
        var deliveries = 0
        let coordinator = RepositoryRefreshCoordinator(
            delay: 0.5,
            scheduler: scheduler,
            callbackExecutor: callbackExecutor.enqueue
        ) { _, _ in
            deliveries += 1
        }

        coordinator.record(eventType: 4, paths: ["/repo/work.swift"])
        scheduler.advance(by: 0.5)
        coordinator.cancel()
        callbackExecutor.runAll()

        XCTAssertEqual(deliveries, 0)
    }

    func testEventsRecordedDuringDeliveryProduceOneTrailingReplay() {
        let scheduler = TestRepositoryRefreshScheduler()
        var deliveries: [(eventType: UInt, paths: [String])] = []
        var coordinator: RepositoryRefreshCoordinator!
        coordinator = makeCoordinator(scheduler: scheduler) { eventType, paths in
            deliveries.append((eventType, paths))
            if deliveries.count == 1 {
                coordinator.record(eventType: 4, paths: ["/repo/a"])
                coordinator.record(eventType: 8, paths: ["/repo/a", "/repo/b"])
            }
        }

        coordinator.record(eventType: 2, paths: ["/repo/.git/HEAD"])
        scheduler.advance(by: 0.5)

        XCTAssertEqual(deliveries.count, 1)

        scheduler.advance(by: 0.5)

        XCTAssertEqual(deliveries.count, 2)
        XCTAssertEqual(deliveries[1].eventType, 12)
        XCTAssertEqual(deliveries[1].paths, ["/repo/a", "/repo/b"])
        coordinator = nil
    }

    func testEmptyEventTypeDoesNotScheduleDelivery() {
        let scheduler = TestRepositoryRefreshScheduler()
        var deliveries = 0
        let coordinator = makeCoordinator(scheduler: scheduler) { _, _ in
            deliveries += 1
        }

        coordinator.record(eventType: 0, paths: ["/repo/ignored"])
        scheduler.advance(by: 1)

        XCTAssertEqual(deliveries, 0)
    }

    func testObsoleteSchedulerCallbackCannotDeliverCurrentBatchEarly() {
        let scheduler = TestRepositoryRefreshScheduler()
        var deliveries: [(eventType: UInt, paths: [String])] = []
        let coordinator = makeCoordinator(scheduler: scheduler) { eventType, paths in
            deliveries.append((eventType, paths))
        }

        coordinator.record(eventType: 2, paths: ["/repo/.git/HEAD"])
        scheduler.advance(by: 0.25)
        coordinator.record(eventType: 4, paths: ["/repo/work.swift"])
        scheduler.advance(by: 0.25, includingCancelledActions: true)

        XCTAssertTrue(deliveries.isEmpty)

        scheduler.advance(by: 0.25, includingCancelledActions: true)

        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries[0].eventType, 6)
    }

    private func makeCoordinator(
        scheduler: TestRepositoryRefreshScheduler,
        deliveryHandler: @escaping RepositoryRefreshCoordinator.DeliveryHandler
    ) -> RepositoryRefreshCoordinator {
        RepositoryRefreshCoordinator(
            delay: 0.5,
            scheduler: scheduler,
            callbackExecutor: { action in action() },
            deliveryHandler: deliveryHandler
        )
    }
}
