import XCTest

final class RepositoryPushEventGateTests: XCTestCase {
    func testAllBoundedEventSequencesPreserveOneOperationLifetime() {
        let alphabet: [RepositoryPushEvent] = [.began(createPullRequestSelected: false), .began(createPullRequestSelected: true), .cancelled, .succeeded, .failed]
        var sequences: [[RepositoryPushEvent]] = [[]]
        var frontier: [[RepositoryPushEvent]] = [[]]
        for _ in 0 ..< 4 {
            frontier = frontier.flatMap { prefix in
                alphabet.map { prefix + [$0] }
            }
            sequences += frontier
        }
        XCTAssertEqual(sequences.count, 781)
        for sequence in sequences {
            var gate = RepositoryPushEventGate()
            var acceptedBegins = 0
            var acceptedTerminals = 0
            for event in sequence {
                let activeBefore = gate.isActive
                let accepted = gate.accept(event)
                if acceptedTerminals > 0 {
                    XCTAssertFalse(accepted, "Late callback in \(sequence)")
                }
                switch event {
                case .began:
                    if accepted {
                        acceptedBegins += 1
                    }
                    if acceptedBegins == 0 && acceptedTerminals == 0 {
                        XCTFail("A fresh operation must accept its first begin: \(sequence)")
                    }
                case .cancelled:
                    if activeBefore {
                        XCTAssertFalse(accepted, "An active push must settle through its actual result")
                    }
                    if accepted {
                        acceptedTerminals += 1
                    }
                case .succeeded, .failed:
                    if acceptedTerminals == 0 {
                        XCTAssertTrue(accepted, "The first actual result must settle the operation")
                    }
                    if accepted {
                        acceptedTerminals += 1
                    }
                }
                XCTAssertLessThanOrEqual(acceptedBegins, 1, "\(sequence)")
                XCTAssertLessThanOrEqual(acceptedTerminals, 1, "\(sequence)")
                XCTAssertEqual(gate.isActive, acceptedBegins == 1 && acceptedTerminals == 0, "\(sequence)")
            }
        }
    }

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
