import ForgeKit
@testable import GitHubForgeAdapter
import XCTest

final class GitHubGraphQLValueMapperTests: XCTestCase {
    func testRepositoryVisibilityMapsKnownAndFutureValues() {
        XCTAssertEqual(GitHubGraphQLValueMapper.repositoryVisibility(.public), .public)
        XCTAssertEqual(GitHubGraphQLValueMapper.repositoryVisibility(.private), .private)
        XCTAssertEqual(GitHubGraphQLValueMapper.repositoryVisibility(.internal), .internal)
        XCTAssertEqual(GitHubGraphQLValueMapper.repositoryVisibility(nil), .unknown)
    }

    func testPullRequestAndIssueStatesMapWithoutGuessingUnknownValues() {
        XCTAssertEqual(GitHubGraphQLValueMapper.pullRequestState(.open), .open)
        XCTAssertEqual(GitHubGraphQLValueMapper.pullRequestState(.closed), .closed)
        XCTAssertEqual(GitHubGraphQLValueMapper.pullRequestState(.merged), .merged)
        XCTAssertNil(GitHubGraphQLValueMapper.pullRequestState(nil))

        XCTAssertEqual(GitHubGraphQLValueMapper.issueState(.open), .open)
        XCTAssertEqual(GitHubGraphQLValueMapper.issueState(.closed), .closed)
        XCTAssertNil(GitHubGraphQLValueMapper.issueState(nil))
    }

    func testReviewAndMergeabilityPreserveUnavailableMeaning() {
        XCTAssertEqual(GitHubGraphQLValueMapper.reviewRollup(.approved), .approved)
        XCTAssertEqual(GitHubGraphQLValueMapper.reviewRollup(.changesRequested), .changesRequested)
        XCTAssertEqual(GitHubGraphQLValueMapper.reviewRollup(.reviewRequired), .reviewRequired)
        XCTAssertEqual(GitHubGraphQLValueMapper.reviewRollup(nil), .noDecision)

        XCTAssertEqual(GitHubGraphQLValueMapper.mergeability(.mergeable), .mergeable)
        XCTAssertEqual(GitHubGraphQLValueMapper.mergeability(.conflicting), .conflicting)
        XCTAssertEqual(GitHubGraphQLValueMapper.mergeability(.unknown), .unknown)
        XCTAssertEqual(GitHubGraphQLValueMapper.mergeability(nil), .unknown)
    }

    func testCheckRunStatesMapAllConclusionsConservatively() {
        XCTAssertEqual(GitHubGraphQLValueMapper.checkState(status: .inProgress, conclusion: nil), .running)
        XCTAssertEqual(GitHubGraphQLValueMapper.checkState(status: .pending, conclusion: nil), .running)
        XCTAssertEqual(GitHubGraphQLValueMapper.checkState(status: .queued, conclusion: nil), .running)
        XCTAssertEqual(GitHubGraphQLValueMapper.checkState(status: .requested, conclusion: nil), .running)
        XCTAssertEqual(GitHubGraphQLValueMapper.checkState(status: .waiting, conclusion: nil), .running)
        XCTAssertEqual(
            GitHubGraphQLValueMapper.checkState(status: nil, conclusion: nil),
            .attentionRequired
        )
        XCTAssertEqual(
            GitHubGraphQLValueMapper.checkState(status: .completed, conclusion: .success),
            .succeeded
        )
        XCTAssertEqual(
            GitHubGraphQLValueMapper.checkState(status: .completed, conclusion: .failure),
            .failed
        )
        XCTAssertEqual(
            GitHubGraphQLValueMapper.checkState(status: .completed, conclusion: .startupFailure),
            .failed
        )
        XCTAssertEqual(
            GitHubGraphQLValueMapper.checkState(status: .completed, conclusion: .timedOut),
            .failed
        )
        XCTAssertEqual(
            GitHubGraphQLValueMapper.checkState(status: .completed, conclusion: .actionRequired),
            .attentionRequired
        )
        XCTAssertEqual(
            GitHubGraphQLValueMapper.checkState(status: .completed, conclusion: nil),
            .attentionRequired
        )
        XCTAssertEqual(
            GitHubGraphQLValueMapper.checkState(status: .completed, conclusion: .cancelled),
            .neutral
        )
        XCTAssertEqual(
            GitHubGraphQLValueMapper.checkState(status: .completed, conclusion: .neutral),
            .neutral
        )
        XCTAssertEqual(
            GitHubGraphQLValueMapper.checkState(status: .completed, conclusion: .skipped),
            .neutral
        )
        XCTAssertEqual(
            GitHubGraphQLValueMapper.checkState(status: .completed, conclusion: .stale),
            .neutral
        )
    }

    func testCommitStatusStatesMapAllCasesConservatively() {
        XCTAssertEqual(GitHubGraphQLValueMapper.statusContextState(.success), .succeeded)
        XCTAssertEqual(GitHubGraphQLValueMapper.statusContextState(.error), .failed)
        XCTAssertEqual(GitHubGraphQLValueMapper.statusContextState(.failure), .failed)
        XCTAssertEqual(GitHubGraphQLValueMapper.statusContextState(.expected), .running)
        XCTAssertEqual(GitHubGraphQLValueMapper.statusContextState(.pending), .running)
        XCTAssertEqual(GitHubGraphQLValueMapper.statusContextState(nil), .attentionRequired)
    }
}
