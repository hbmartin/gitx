import XCTest

final class RepositoryPushEventGateTests: XCTestCase {
    func testCancellationBeforeBeginFinishesWithoutAcceptingALateAction() {
        var gate = RepositoryPushEventGate()
        XCTAssertFalse(gate.isActive)
        XCTAssertTrue(gate.accept(.cancelled))
        XCTAssertFalse(gate.isActive)
        XCTAssertFalse(gate.accept(.began(createPullRequestSelected: true)))
        XCTAssertFalse(gate.accept(.failed))
    }

    func testACompletedPushIgnoresEveryLateCallback() {
        for terminal in [RepositoryPushEvent.succeeded, .failed] {
            var gate = RepositoryPushEventGate()
            XCTAssertTrue(gate.accept(.began(createPullRequestSelected: false)))
            XCTAssertTrue(gate.isActive)
            XCTAssertTrue(gate.accept(terminal))
            XCTAssertFalse(gate.isActive)
            for late in [RepositoryPushEvent.began(createPullRequestSelected: true), .cancelled, .succeeded, .failed] {
                XCTAssertFalse(gate.accept(late), "\(terminal) followed by \(late)")
            }
        }
    }

    func testDuplicateBeginDoesNotStartASecondPushOrReplaceItsChoice() {
        var gate = RepositoryPushEventGate()
        var accepted: [RepositoryPushEvent] = []
        for event in [RepositoryPushEvent.began(createPullRequestSelected: false), .began(createPullRequestSelected: true), .succeeded] {
            if gate.accept(event) {
                accepted.append(event)
            }
        }
        XCTAssertEqual(accepted, [.began(createPullRequestSelected: false), .succeeded])
    }

    func testCancellationAfterBeginKeepsThePushActiveUntilItsActualFailure() {
        var gate = RepositoryPushEventGate()
        XCTAssertTrue(gate.accept(.began(createPullRequestSelected: true)))
        XCTAssertTrue(gate.isActive)
        XCTAssertFalse(gate.accept(.cancelled))
        XCTAssertTrue(gate.isActive)
        XCTAssertTrue(gate.accept(.failed), "Declining rejected-push recovery completes the failed active push")
        XCTAssertFalse(gate.isActive)
        XCTAssertFalse(gate.accept(.failed))
    }
}
