@testable import ForgeKit
import Foundation
import XCTest

final class ForgeReadModelsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testEveryReadModelPreservesProviderNeutralStateAndRoundTrips() throws {
        let repository = try TestSupport.repository()
        let actor = try ForgeActor(
            id: ForgeObjectID(forge: repository.forge, value: "actor"),
            login: "octocat",
            kind: .person
        )
        let summary = try ForgePullRequestSummary(
            repository: repository,
            number: ForgeItemNumber(7),
            state: .open,
            isDraft: false,
            title: "Read adapter",
            author: .available(.actor(actor)),
            head: .unavailable(.partialResponse),
            base: .unavailable(.partialResponse),
            createdAt: now,
            updatedAt: now,
            labels: .available([]),
            checkRollup: .available(.succeeded),
            reviewRollup: .available(.approved)
        )
        let details = try ForgePullRequestDetails(
            summary: summary,
            bodyMarkdown: .available("body"),
            assignees: .available([actor]),
            milestone: .available(nil),
            reviewers: .available([]),
            linkedIssues: .available([]),
            mergeability: .available(.mergeable),
            checks: .available([]),
            timeline: .available(ForgePage(items: []))
        )
        let detailsPage = try ForgePullRequestDetailsPage(
            details: details,
            nextCheckCursor: ForgePageCursor("checks")
        )
        XCTAssertEqual(try roundTrip(detailsPage), detailsPage)

        let overlay = try ForgeHistoryOverlay(
            repository: repository,
            commit: TestSupport.commit,
            checkRollup: .available(.succeeded),
            pullRequests: .available(ForgePage(items: [summary], totalCount: 1))
        )
        XCTAssertEqual(try roundTrip(overlay), overlay)

        let issue = try ForgeIssueSummary(
            repository: repository,
            number: ForgeItemNumber(8),
            state: .closed,
            title: "Issue",
            author: .available(.actor(actor)),
            createdAt: now,
            updatedAt: now,
            labels: .available([])
        )
        let pullRequestItem = ForgeRepositoryItem.pullRequest(summary)
        let issueItem = ForgeRepositoryItem.issue(issue)
        XCTAssertEqual(pullRequestItem.repository, repository)
        XCTAssertEqual(issueItem.repository, repository)
        XCTAssertEqual(pullRequestItem.destination, .pullRequest(repository, summary.number))
        XCTAssertEqual(issueItem.destination, .issue(repository, issue.number))
        XCTAssertEqual(try roundTrip(pullRequestItem), pullRequestItem)
        XCTAssertEqual(try roundTrip(issueItem), issueItem)

        let anchor = try ForgeReviewAnchor(
            path: ForgeFilePath("Sources/App.swift"),
            subject: .line,
            side: .right,
            startLine: 4,
            line: 6,
            originalStartLine: 3,
            originalLine: 5
        )
        let fileAnchor = try ForgeReviewAnchor(path: ForgeFilePath("README.md"), subject: .file)
        XCTAssertEqual(Set(ForgeReviewDiffSide.allCases), [.left, .right])
        XCTAssertEqual(Set(ForgeReviewSubject.allCases), [.file, .line])
        XCTAssertEqual(try roundTrip(anchor), anchor)
        XCTAssertEqual(try roundTrip(fileAnchor), fileAnchor)

        let comment = try ForgeReviewComment(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: "comment"),
            bodyMarkdown: "nit",
            createdAt: now,
            updatedAt: now,
            author: .available(.actor(actor)),
            replyToID: ForgeObjectID(forge: repository.forge, value: "parent")
        )
        let rootComment = try ForgeReviewComment(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: "root"),
            bodyMarkdown: "root",
            createdAt: now,
            updatedAt: now,
            author: .available(.deleted)
        )
        let thread = try ForgeReviewThread(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: "thread"),
            isResolved: false,
            isOutdated: true,
            anchor: .available(anchor),
            comments: .available(ForgePage(items: [comment, rootComment], totalCount: 2))
        )
        XCTAssertEqual(try roundTrip(thread), thread)

        let activity = try ForgeAttentionActivity(
            id: ForgeObjectID(forge: repository.forge, value: "activity"),
            kind: .reviewReply,
            author: .available(.actor(actor)),
            bodyMarkdown: "@octocat",
            occurredAt: now
        )
        XCTAssertEqual(
            Set(ForgeAttentionActivityKind.allCases),
            [.conversationComment, .review, .reviewReply]
        )
        XCTAssertEqual(try roundTrip(activity), activity)
        let candidate = ForgeAttentionCandidate(
            item: pullRequestItem,
            bodyMarkdown: .available("body"),
            assignees: .available([actor]),
            participants: .available([actor]),
            requestedReviewers: .available([.actor(actor)]),
            activities: .available([activity]),
            reviewThreads: .available([thread])
        )
        XCTAssertEqual(try roundTrip(candidate), candidate)
        let page = try ForgeAttentionCandidatePage(
            viewer: actor,
            candidates: ForgePage(items: [candidate], totalCount: 1)
        )
        XCTAssertEqual(try roundTrip(page), page)
    }

    private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}
