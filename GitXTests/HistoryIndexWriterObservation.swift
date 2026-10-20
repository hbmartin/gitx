@testable import GitX
import Foundation
import XCTest

/// Observe the real shared writer without constructing a mutation service or scheduling work.
// swift6-safety-justification: The lock protects observer lifetime; the writer owns thread-safe state and main-actor delivery.
final nonisolated class HistoryIndexWriterObservation: @unchecked Sendable {
    private let writer: GitX.IndexWriterCoordinator
    private let lock = NSLock()
    private var token: UUID?
    private var closed = false

    init(repository: PBGitRepository) {
        writer = GitX.IndexWriterCoordinator.coordinator(for: repository)
    }

    var isWriterBusy: Bool { writer.isBusy }

    func observe(_ changed: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, token == nil else { return }
        token = writer.observe { [weak self] _ in
            guard let self else { return }
            lock.lock()
            let active = !closed
            lock.unlock()
            if active { changed() }
        }
    }

    func close() {
        lock.lock()
        closed = true
        let previous = token
        token = nil
        lock.unlock()
        if let previous { writer.removeObserver(previous) }
    }

    deinit { close() }
}

@MainActor
// swift6-safety-justification: XCTest owns the test instance; mutable test state is confined to the main actor.
final class HistoryIndexWriterObservationTests: XCTestCase, @unchecked Sendable {
    func testObservationItselfDoesNotEnqueueAWriterAndCloseRevokesQueuedDelivery() async {
        let repository = PBGitRepository()
        let observation = HistoryIndexWriterObservation(repository: repository)
        var delivered = false
        observation.observe { delivered = true }
        XCTAssertFalse(observation.isWriterBusy)
        observation.close()
        observation.close()
        let drained = expectation(description: "initial writer notification drains after close")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertFalse(delivered)
        XCTAssertFalse(observation.isWriterBusy)
    }

    func testObservationWaitsForTheExistingWriterToBecomeQuiescent() async {
        let repository = PBGitRepository()
        let observation = HistoryIndexWriterObservation(repository: repository)
        defer { observation.close() }
        let writer = GitX.IndexWriterCoordinator.coordinator(for: repository)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let entered = expectation(description: "shared writer is busy")
        let finished = expectation(description: "shared writer becomes quiescent")
        var sawBusy = false
        var sawFinished = false
        observation.observe {
            if observation.isWriterBusy, !sawBusy {
                sawBusy = true
                entered.fulfill()
            } else if sawBusy, !observation.isWriterBusy, !sawFinished {
                sawFinished = true
                finished.fulfill()
            }
        }
        writer.schedule("observation fixture") { _ = release.wait(timeout: .now() + 3) }
        await fulfillment(of: [entered], timeout: 3)
        release.signal()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertFalse(observation.isWriterBusy)
    }
}
