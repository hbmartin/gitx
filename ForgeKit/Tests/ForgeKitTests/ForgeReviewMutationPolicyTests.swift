@testable import ForgeKit
import XCTest

final class ForgeReviewMutationPolicyTests: XCTestCase {
    func testReviewContextValidatesAndRoundTrips() throws {
        let fixture = try ReviewFixture()
        let context = try fixture.context()
        XCTAssertEqual(try roundTrip(context), context)
        XCTAssertThrowsError(try fixture.context(lines: [])) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .invalidContext)
        }
        XCTAssertThrowsError(try fixture.context(lines: ["bad\nline"])) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .invalidContext)
        }
    }

    func testReanchorCandidateValidatesAndRoundTrips() throws {
        let fixture = try ReviewFixture()
        let candidate = try fixture.candidate()
        XCTAssertEqual(try roundTrip(candidate), candidate)
        XCTAssertThrowsError(try fixture.candidate(lines: [])) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .invalidContext)
        }
        XCTAssertThrowsError(try fixture.candidate(lines: ["bad\tline"])) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .invalidContext)
        }
    }

    func testReanchorPolicyPreservesSameHeadAndRejectsTruncatedContext() throws {
        let fixture = try ReviewFixture()
        let context = try fixture.context()
        XCTAssertEqual(
            ForgeReviewReanchorPolicy.decision(
                original: context,
                currentHead: fixture.oldHead,
                candidates: []
            ),
            .unchanged
        )
        let truncated = try fixture.context(isTruncated: true)
        XCTAssertEqual(
            try ForgeReviewReanchorPolicy.decision(
                original: truncated,
                currentHead: fixture.newHead,
                candidates: [fixture.candidate()]
            ),
            .unavailable(.truncatedAnchor)
        )
    }

    func testReanchorRequiresOneExactCandidateAndNeverGuesses() throws {
        let fixture = try ReviewFixture()
        let context = try fixture.context()
        let exact = try fixture.candidate()
        let decision = ForgeReviewReanchorPolicy.decision(
            original: context,
            currentHead: fixture.newHead,
            candidates: [exact]
        )
        guard case let .requiresConfirmation(confirmation) = decision else {
            return XCTFail("Expected validated reanchor confirmation")
        }
        XCTAssertEqual(confirmation.anchor, exact.anchor)
        let original = try ForgeInlineReviewPublication(
            accountID: fixture.accountID,
            repository: fixture.repository,
            pullRequest: fixture.pullRequest,
            displayedHead: fixture.oldHead,
            anchor: fixture.anchor,
            bodyMarkdown: "Please change this."
        )
        let reanchored = try confirmation.publication(replacing: original)
        XCTAssertEqual(reanchored.displayedHead, fixture.newHead)
        XCTAssertEqual(reanchored.anchor, exact.anchor)
        XCTAssertEqual(reanchored.bodyMarkdown, original.bodyMarkdown)
        let mismatched = try ForgeInlineReviewPublication(
            accountID: fixture.accountID,
            repository: fixture.repository,
            pullRequest: ForgeItemNumber(8),
            displayedHead: fixture.oldHead,
            anchor: fixture.anchor,
            bodyMarkdown: "Please change this."
        )
        XCTAssertThrowsError(try confirmation.publication(replacing: mismatched)) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .contextMismatch)
        }
        XCTAssertEqual(
            ForgeReviewReanchorPolicy.decision(
                original: context,
                currentHead: fixture.newHead,
                candidates: []
            ),
            .unavailable(.anchorUnavailable)
        )
        let second = try fixture.candidate(line: 30)
        XCTAssertEqual(
            ForgeReviewReanchorPolicy.decision(
                original: context,
                currentHead: fixture.newHead,
                candidates: [exact, second]
            ),
            .unavailable(.ambiguousAnchor)
        )
    }

    func testReanchorFiltersEveryIdentityAndContextBoundary() throws {
        let fixture = try ReviewFixture()
        let context = try fixture.context()
        let candidates = try [
            fixture.candidate(repository: fixture.otherRepository),
            fixture.candidate(pullRequest: ForgeItemNumber(8)),
            fixture.candidate(head: fixture.oldHead),
            fixture.candidate(path: ForgeFilePath("Other.swift")),
            fixture.candidate(lines: ["different"]),
        ]
        XCTAssertEqual(
            ForgeReviewReanchorPolicy.decision(
                original: context,
                currentHead: fixture.newHead,
                candidates: candidates
            ),
            .unavailable(.anchorUnavailable)
        )
    }

    func testInlinePublicationIsImmediateHeadBoundAndRoundTrips() throws {
        let fixture = try ReviewFixture()
        let publication = try ForgeInlineReviewPublication(
            accountID: fixture.accountID,
            repository: fixture.repository,
            pullRequest: fixture.pullRequest,
            displayedHead: fixture.oldHead,
            anchor: fixture.anchor,
            bodyMarkdown: "Please change this."
        )
        XCTAssertEqual(try publication.validating(currentHead: fixture.oldHead), publication)
        XCTAssertEqual(try roundTrip(publication), publication)
        XCTAssertThrowsError(try publication.validating(currentHead: fixture.newHead)) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .displayedHeadChanged)
        }
        XCTAssertThrowsError(try ForgeInlineReviewPublication(
            accountID: fixture.otherAccountID,
            repository: fixture.repository,
            pullRequest: fixture.pullRequest,
            displayedHead: fixture.oldHead,
            anchor: fixture.anchor,
            bodyMarkdown: "Body"
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .mismatchedForge)
        }
        XCTAssertThrowsError(try ForgeInlineReviewPublication(
            accountID: fixture.accountID,
            repository: fixture.repository,
            pullRequest: fixture.pullRequest,
            displayedHead: fixture.oldHead,
            anchor: fixture.anchor,
            bodyMarkdown: " "
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .invalidBody)
        }
    }

    func testThreadReplyRequiresExactForgeAndPrintableBody() throws {
        let fixture = try ReviewFixture()
        let reply = try ForgeReviewThreadReplyPublication(
            accountID: fixture.accountID,
            repository: fixture.repository,
            pullRequest: fixture.pullRequest,
            threadID: fixture.threadID,
            bodyMarkdown: "Reply now"
        )
        XCTAssertEqual(try roundTrip(reply), reply)
        XCTAssertThrowsError(try ForgeReviewThreadReplyPublication(
            accountID: fixture.accountID,
            repository: fixture.repository,
            pullRequest: fixture.pullRequest,
            threadID: fixture.otherThreadID,
            bodyMarkdown: "Reply"
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .mismatchedForge)
        }
        XCTAssertThrowsError(try ForgeReviewThreadReplyPublication(
            accountID: fixture.accountID,
            repository: fixture.repository,
            pullRequest: fixture.pullRequest,
            threadID: fixture.threadID,
            bodyMarkdown: "\n"
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .invalidBody)
        }
    }

    func testThreadPresentationPreservesOutdatedMinimizedDeletedAndUnavailableState() throws {
        let fixture = try ReviewFixture()
        let commentIDs = try (1 ... 4).map {
            try ForgeObjectID(forge: fixture.repository.forge, value: "comment-\($0)")
        }
        let thread = ForgeReviewThread(
            repository: fixture.repository,
            id: fixture.threadID,
            isResolved: false,
            isOutdated: true,
            anchor: .available(fixture.anchor),
            comments: .unavailable(.partialResponse)
        )
        let reactions = try [
            ForgeReviewReactionSummary(kind: .thumbsUp, count: 2, viewerReacted: true),
            ForgeReviewReactionSummary(kind: .eyes, count: 1, viewerReacted: false),
        ]
        let presentation = try ForgeReviewThreadPresentation(
            thread: thread,
            expansion: .collapsed,
            commentVisibility: [
                commentIDs[0]: .ordinary,
                commentIDs[1]: .minimized(reason: "Off-topic"),
                commentIDs[2]: .deleted,
                commentIDs[3]: .unavailable,
            ],
            commentReactions: [commentIDs[0]: reactions]
        )
        XCTAssertTrue(presentation.remainsVisiblyOutdated)
        XCTAssertEqual(presentation.expansion, .collapsed)
        XCTAssertEqual(presentation.commentReactions[commentIDs[0]], reactions)
        XCTAssertEqual(Set(ForgeReviewReactionKind.allCases).count, 8)
        XCTAssertEqual(try roundTrip(presentation), presentation)
        XCTAssertThrowsError(try ForgeReviewThreadPresentation(
            thread: thread,
            commentVisibility: [fixture.otherThreadID: .ordinary]
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .mismatchedForge)
        }
        XCTAssertThrowsError(try ForgeReviewThreadPresentation(
            thread: thread,
            commentVisibility: [:],
            commentReactions: [fixture.otherThreadID: reactions]
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .mismatchedForge)
        }
        XCTAssertThrowsError(try ForgeReviewThreadPresentation(
            thread: thread,
            commentVisibility: [:],
            commentReactions: [commentIDs[0]: [reactions[0], reactions[0]]]
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .invalidContext)
        }
        XCTAssertThrowsError(try ForgeReviewReactionSummary(kind: .heart, count: -1, viewerReacted: false)) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .invalidContext)
        }
    }

    func testFormalReviewSupportsExactKindsAndHeadBinding() throws {
        let fixture = try ReviewFixture()
        XCTAssertEqual(Set(ForgeFormalReviewKind.allCases), [.approve, .comment, .requestChanges])
        for kind in ForgeFormalReviewKind.allCases {
            let body = kind == .requestChanges ? "Please revise" : ""
            let review = try ForgeFormalReviewSubmission(
                accountID: fixture.accountID,
                repository: fixture.repository,
                pullRequest: fixture.pullRequest,
                displayedHead: fixture.oldHead,
                kind: kind,
                bodyMarkdown: body
            )
            XCTAssertEqual(try review.validating(currentHead: fixture.oldHead), review)
            XCTAssertEqual(try roundTrip(review), review)
            XCTAssertThrowsError(try review.validating(currentHead: fixture.newHead)) {
                XCTAssertEqual($0 as? ForgeReviewMutationError, .displayedHeadChanged)
            }
        }
        XCTAssertThrowsError(try ForgeFormalReviewSubmission(
            accountID: fixture.accountID,
            repository: fixture.repository,
            pullRequest: fixture.pullRequest,
            displayedHead: fixture.oldHead,
            kind: .requestChanges,
            bodyMarkdown: ""
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .invalidBody)
        }
        XCTAssertThrowsError(try ForgeFormalReviewSubmission(
            accountID: fixture.otherAccountID,
            repository: fixture.repository,
            pullRequest: fixture.pullRequest,
            displayedHead: fixture.oldHead,
            kind: .approve,
            bodyMarkdown: ""
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .mismatchedForge)
        }
    }

    func testResolutionOptimismSuccessFailureAndReconciliation() throws {
        let now = Date(timeIntervalSince1970: 100)
        var state = ForgeReviewThreadResolutionState.confirmed(isResolved: false)
        state = try state.applying(.begin(.resolve, now: now, undoInterval: 5))
        XCTAssertEqual(state, .optimistic(
            mutation: .resolve,
            priorValue: false,
            undoDeadline: now.addingTimeInterval(5)
        ))
        XCTAssertEqual(try state.applying(.succeeded), .confirmed(isResolved: true))
        XCTAssertEqual(try state.applying(.failed), .confirmed(isResolved: false))
        XCTAssertEqual(try state.applying(.outcomeUnknown), .unknownOutcome(lastKnownValue: false))
        XCTAssertEqual(
            try ForgeReviewThreadResolutionState.unknownOutcome(lastKnownValue: false).applying(.reconciled(isResolved: true)),
            .confirmed(isResolved: true)
        )
        XCTAssertEqual(
            try ForgeReviewThreadResolutionState.confirmed(isResolved: true).applying(.reconciled(isResolved: false)),
            .confirmed(isResolved: false)
        )
    }

    func testResolutionUndoIsShortExplicitAndReversesOptimisticValue() throws {
        let now = Date(timeIntervalSince1970: 100)
        let resolving = try ForgeReviewThreadResolutionState.confirmed(isResolved: false).applying(
            .begin(.resolve, now: now, undoInterval: 5)
        )
        let undoing = try resolving.applying(.undo(now: now.addingTimeInterval(5)))
        XCTAssertEqual(undoing, .optimistic(
            mutation: .unresolve,
            priorValue: true,
            undoDeadline: now.addingTimeInterval(5)
        ))
        XCTAssertEqual(try undoing.applying(.succeeded), .confirmed(isResolved: false))
        XCTAssertEqual(try undoing.applying(.failed), .confirmed(isResolved: true))
        XCTAssertThrowsError(try resolving.applying(.undo(now: now.addingTimeInterval(5.001)))) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .undoExpired)
        }
    }

    func testResolutionRejectsInvalidDirectionsIntervalsAndEvents() throws {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertThrowsError(try ForgeReviewThreadResolutionState.confirmed(isResolved: false).applying(
            .begin(.unresolve, now: now, undoInterval: 5)
        ))
        XCTAssertThrowsError(try ForgeReviewThreadResolutionState.confirmed(isResolved: true).applying(
            .begin(.resolve, now: now, undoInterval: 5)
        ))
        XCTAssertThrowsError(try ForgeReviewThreadResolutionState.confirmed(isResolved: false).applying(
            .begin(.resolve, now: now, undoInterval: 0)
        ))
        XCTAssertThrowsError(try ForgeReviewThreadResolutionState.confirmed(isResolved: false).applying(.succeeded)) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .invalidTransition)
        }
        XCTAssertEqual(ForgeReviewThreadResolutionMutation.resolve.opposite, .unresolve)
        XCTAssertEqual(ForgeReviewThreadResolutionMutation.unresolve.opposite, .resolve)
    }

    func testSuggestedChangeValidatesAndRoundTrips() throws {
        let fixture = try ReviewFixture()
        let change = try fixture.suggestedChange()
        XCTAssertEqual(try roundTrip(change), change)
        XCTAssertThrowsError(try fixture.suggestedChange(original: "")) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .invalidContext)
        }
    }

    func testSuggestedChangeAppliesOneExactUneditedCheckedOutContext() throws {
        let fixture = try ReviewFixture()
        let change = try fixture.suggestedChange()
        XCTAssertEqual(
            ForgeSuggestedChangePolicy.decision(
                change: change,
                checkedOutHead: fixture.oldHead,
                filesWithUncommittedEdits: [],
                currentContents: "before\nlet old = true\nafter\n"
            ),
            .apply(updatedContents: "before\nlet new = true\nafter\n")
        )
    }

    func testSuggestedChangeRejectsEveryUnsafeBoundary() throws {
        let fixture = try ReviewFixture()
        let change = try fixture.suggestedChange()
        XCTAssertEqual(
            ForgeSuggestedChangePolicy.decision(
                change: change,
                checkedOutHead: nil,
                filesWithUncommittedEdits: [],
                currentContents: change.originalText
            ),
            .unavailable(.checkedOutHeadRequired)
        )
        XCTAssertEqual(
            ForgeSuggestedChangePolicy.decision(
                change: change,
                checkedOutHead: fixture.newHead,
                filesWithUncommittedEdits: [],
                currentContents: change.originalText
            ),
            .unavailable(.checkedOutHeadRequired)
        )
        XCTAssertEqual(
            ForgeSuggestedChangePolicy.decision(
                change: change,
                checkedOutHead: fixture.oldHead,
                filesWithUncommittedEdits: [change.path],
                currentContents: change.originalText
            ),
            .unavailable(.uncommittedTargetFile)
        )
        let truncated = try fixture.suggestedChange(isTruncated: true)
        XCTAssertEqual(
            ForgeSuggestedChangePolicy.decision(
                change: truncated,
                checkedOutHead: fixture.oldHead,
                filesWithUncommittedEdits: [],
                currentContents: change.originalText
            ),
            .unavailable(.truncatedAnchor)
        )
        XCTAssertEqual(
            ForgeSuggestedChangePolicy.decision(
                change: change,
                checkedOutHead: fixture.oldHead,
                filesWithUncommittedEdits: [],
                currentContents: "no match"
            ),
            .unavailable(.contextMismatch)
        )
        XCTAssertEqual(
            ForgeSuggestedChangePolicy.decision(
                change: change,
                checkedOutHead: fixture.oldHead,
                filesWithUncommittedEdits: [],
                currentContents: "\(change.originalText)\n\(change.originalText)"
            ),
            .unavailable(.ambiguousAnchor)
        )
    }

    func testErrorsHaveStableDescriptions() {
        let errors: [ForgeReviewMutationError] = [
            .invalidBody, .invalidContext, .mismatchedForge, .mismatchedRepository,
            .mismatchedPullRequest, .displayedHeadChanged, .truncatedAnchor,
            .anchorUnavailable, .ambiguousAnchor, .invalidTransition, .undoExpired,
            .checkedOutHeadRequired, .uncommittedTargetFile, .contextMismatch,
        ]
        XCTAssertTrue(errors.allSatisfy { !($0.errorDescription ?? "").isEmpty })
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}

private struct ReviewFixture {
    let repository: ForgeRepositoryIdentity
    let otherRepository: ForgeRepositoryIdentity
    let accountID: ForgeAccountID
    let otherAccountID: ForgeAccountID
    let pullRequest = try! ForgeItemNumber(7)
    let oldHead = try! ForgeCommitID(String(repeating: "a", count: 40))
    let newHead = try! ForgeCommitID(String(repeating: "b", count: 40))
    let path = try! ForgeFilePath("Sources/File.swift")
    let anchor: ForgeReviewAnchor
    let threadID: ForgeObjectID
    let otherThreadID: ForgeObjectID

    init() throws {
        let github = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let gitlab = try ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com"))
        repository = try ForgeRepositoryIdentity(forge: github, owner: "gitx", name: "gitx")
        otherRepository = try ForgeRepositoryIdentity(forge: github, owner: "other", name: "gitx")
        accountID = try ForgeAccountID(forge: github, value: "account")
        otherAccountID = try ForgeAccountID(forge: gitlab, value: "other")
        anchor = ForgeReviewAnchor(
            path: path,
            subject: .line,
            side: .right,
            startSide: .right,
            startLine: 10,
            line: 12,
            originalStartLine: 8,
            originalLine: 10
        )
        threadID = try ForgeObjectID(forge: github, value: "thread")
        otherThreadID = try ForgeObjectID(forge: gitlab, value: "other-thread")
    }

    func context(
        lines: [String] = ["let old = true"],
        isTruncated: Bool = false
    ) throws -> ForgeReviewContext {
        try ForgeReviewContext(
            repository: repository,
            pullRequest: pullRequest,
            displayedHead: oldHead,
            path: path,
            lines: lines,
            isTruncated: isTruncated
        )
    }

    func candidate(
        repository: ForgeRepositoryIdentity? = nil,
        pullRequest: ForgeItemNumber? = nil,
        head: ForgeCommitID? = nil,
        path: ForgeFilePath? = nil,
        line: Int = 20,
        lines: [String] = ["let old = true"]
    ) throws -> ForgeReviewReanchorCandidate {
        let candidateAnchor = ForgeReviewAnchor(
            path: path ?? self.path,
            subject: .line,
            side: .right,
            line: line,
            originalLine: 10
        )
        return try ForgeReviewReanchorCandidate(
            repository: repository ?? self.repository,
            pullRequest: pullRequest ?? self.pullRequest,
            displayedHead: head ?? newHead,
            anchor: candidateAnchor,
            contextLines: lines
        )
    }

    func suggestedChange(
        original: String = "let old = true",
        isTruncated: Bool = false
    ) throws -> ForgeSuggestedChange {
        try ForgeSuggestedChange(
            repository: repository,
            pullRequest: pullRequest,
            displayedHead: oldHead,
            path: path,
            originalText: original,
            replacementText: "let new = true",
            isTruncated: isTruncated
        )
    }
}
