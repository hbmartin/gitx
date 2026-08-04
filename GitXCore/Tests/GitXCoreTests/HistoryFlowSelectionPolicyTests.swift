import Foundation
@testable import GitXCore
import XCTest

final class HistoryFlowSelectionPolicyTests: XCTestCase {
    private let policy = HistoryFlowSelectionPolicy()
    private let repositoryURL = URL(fileURLWithPath: "/tmp/repository")

    func testLoadsOnlyOneCommittedRevisionWithAParent() {
        let commit = HistoryFlowCommitInput(sha: "target", firstParentSHA: "base", isWorkingState: false)

        XCTAssertEqual(
            policy.decision(selectedTabIndex: 0, repositoryURL: repositoryURL, commits: [commit]),
            .inactive
        )
        XCTAssertEqual(
            policy.decision(selectedTabIndex: 2, repositoryURL: repositoryURL, commits: [commit]),
            .load(HistoryFlowRevisionRequest(repositoryURL: repositoryURL, base: "base", target: "target"))
        )
    }

    func testExplainsUnsupportedSelectionStates() {
        let commit = HistoryFlowCommitInput(sha: "target", firstParentSHA: "base", isWorkingState: false)

        XCTAssertEqual(
            policy.decision(selectedTabIndex: 2, repositoryURL: repositoryURL, commits: []),
            .message("Select one commit to review its flow delta.")
        )
        XCTAssertEqual(
            policy.decision(selectedTabIndex: 2, repositoryURL: repositoryURL, commits: [commit, commit]),
            .message("Select one commit to review its flow delta.")
        )
        XCTAssertEqual(
            policy.decision(
                selectedTabIndex: 2,
                repositoryURL: repositoryURL,
                commits: [HistoryFlowCommitInput(sha: "working", firstParentSHA: "base", isWorkingState: true)]
            ),
            .message("Flow review is available for committed revisions.")
        )
        XCTAssertEqual(
            policy.decision(
                selectedTabIndex: 2,
                repositoryURL: repositoryURL,
                commits: [HistoryFlowCommitInput(sha: "root", firstParentSHA: nil, isWorkingState: false)]
            ),
            .message("This root commit has no parent revision to compare.")
        )
        XCTAssertEqual(
            policy.decision(selectedTabIndex: 2, repositoryURL: nil, commits: [commit]),
            .message("The repository working directory is unavailable.")
        )
    }
}
