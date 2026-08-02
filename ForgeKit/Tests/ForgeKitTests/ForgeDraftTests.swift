@testable import ForgeKit
import Foundation
import XCTest

final class ForgeDraftTests: XCTestCase {
    func testDraftIdentityIsExactToAccountDestinationAndDisplayedHead() throws {
        let context = try makeContext()
        let otherAccount = try ForgeAccountID(forge: context.repository.forge, value: "other")
        let otherDestination = try ForgeDraftDestination.createPullRequest(
            repository: context.repository,
            base: ForgeRefName("release"),
            head: TestSupport.feature
        )
        let otherHead = try ForgeCommitID("def5678")
        let inlineDestination = try ForgeDraftDestination.inlineReview(
            repository: context.repository,
            pullRequest: ForgeItemNumber(1),
            path: ForgeFilePath("Sources/File.swift"),
            selection: ForgeLineSelection(line: 2)
        )
        let identities = try Set([
            context.identity,
            ForgeDraftIdentity(accountID: otherAccount, destination: context.destination),
            ForgeDraftIdentity(accountID: context.accountID, destination: otherDestination),
            ForgeDraftIdentity(
                accountID: context.accountID,
                destination: inlineDestination,
                displayedPullRequestHead: TestSupport.commit
            ),
            ForgeDraftIdentity(
                accountID: context.accountID,
                destination: inlineDestination,
                displayedPullRequestHead: otherHead
            ),
        ])
        XCTAssertEqual(identities.count, 5)
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeDraftIdentity.self, from: JSONEncoder().encode(context.identity)),
            context.identity
        )
    }

    func testDisplayedHeadIsRequiredOnlyForInlineAndFormalReviewDrafts() throws {
        let context = try makeContext()
        let number = try ForgeItemNumber(1)
        let identifier = try ForgeDraftDestinationIdentifier("thread-1")
        let noHeadDestinations: [ForgeDraftDestination] = [
            context.destination,
            .pullRequest(repository: context.repository, number: number),
            .reviewThread(repository: context.repository, pullRequest: number, thread: identifier),
        ]
        let headDestinations: [ForgeDraftDestination] = try [
            .inlineReview(
                repository: context.repository,
                pullRequest: number,
                path: ForgeFilePath("File.swift"),
                selection: ForgeLineSelection(line: 1)
            ),
            .formalReview(repository: context.repository, pullRequest: number),
        ]

        for destination in noHeadDestinations {
            XCTAssertFalse(destination.requiresDisplayedPullRequestHead)
            XCTAssertEqual(destination.repository, context.repository)
            XCTAssertNoThrow(try ForgeDraftIdentity(accountID: context.accountID, destination: destination))
            XCTAssertThrowsError(
                try ForgeDraftIdentity(
                    accountID: context.accountID,
                    destination: destination,
                    displayedPullRequestHead: TestSupport.commit
                )
            ) {
                XCTAssertEqual($0 as? ForgeDraftError, .displayedHeadNotAllowed)
            }
        }
        for destination in headDestinations {
            XCTAssertTrue(destination.requiresDisplayedPullRequestHead)
            XCTAssertEqual(destination.repository, context.repository)
            XCTAssertThrowsError(
                try ForgeDraftIdentity(accountID: context.accountID, destination: destination)
            ) {
                XCTAssertEqual($0 as? ForgeDraftError, .displayedHeadRequired)
            }
            XCTAssertNoThrow(
                try ForgeDraftIdentity(
                    accountID: context.accountID,
                    destination: destination,
                    displayedPullRequestHead: TestSupport.commit
                )
            )
        }
        XCTAssertEqual(
            try JSONDecoder().decode(
                ForgeDraftDestinationIdentifier.self,
                from: JSONEncoder().encode(identifier)
            ),
            identifier
        )
    }

    func testDraftRejectsCrossForgeAccountAndInvalidOpaqueDestination() throws {
        let context = try makeContext()
        let gitLab = try TestSupport.repository(kind: .gitLab)
        let wrongAccount = try ForgeAccountID(forge: gitLab.forge, value: "wrong")
        XCTAssertThrowsError(
            try ForgeDraftIdentity(accountID: wrongAccount, destination: context.destination)
        ) {
            XCTAssertEqual($0 as? ForgeDraftError, .mismatchedAccountForge)
        }
        for value in ["", " ", "\n"] {
            XCTAssertThrowsError(try ForgeDraftDestinationIdentifier(value)) {
                XCTAssertEqual($0 as? ForgeDraftError, .invalidDestinationIdentifier)
            }
        }
    }

    func testEditingAndActivityAutosaveWithoutMovingTimeBackward() throws {
        let draft = try makeDraft(createdAt: 10, activityAt: 20)
        let editedContent = ForgeDraftContent(title: "Updated", body: "Body")
        let edited = try draft.editing(editedContent, at: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(edited.content, editedContent)
        XCTAssertEqual(edited.lastActivityAt, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(
            try edited.recordingActivity(at: Date(timeIntervalSince1970: 40)).lastActivityAt,
            Date(timeIntervalSince1970: 40)
        )
        XCTAssertThrowsError(try edited.editing(editedContent, at: Date(timeIntervalSince1970: 29))) {
            XCTAssertEqual($0 as? ForgeDraftError, .staleEdit)
        }
        XCTAssertThrowsError(try edited.recordingActivity(at: Date(timeIntervalSince1970: 29))) {
            XCTAssertEqual($0 as? ForgeDraftError, .staleEdit)
        }
        XCTAssertThrowsError(
            try ForgeDraft(
                identity: draft.identity,
                content: draft.content,
                createdAt: Date(timeIntervalSince1970: 20),
                lastActivityAt: Date(timeIntervalSince1970: 10)
            )
        ) {
            XCTAssertEqual($0 as? ForgeDraftError, .invalidTimestampOrder)
        }
    }

    func testDraftDecodingRejectsInvalidTimestampOrder() throws {
        struct UnvalidatedDraft: Encodable {
            let identity: ForgeDraftIdentity
            let content: ForgeDraftContent
            let createdAt: Date
            let lastActivityAt: Date
        }

        let draft = try makeDraft(createdAt: 10, activityAt: 20)
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeDraft.self, from: JSONEncoder().encode(draft)),
            draft
        )
        let data = try JSONEncoder().encode(
            UnvalidatedDraft(
                identity: draft.identity,
                content: draft.content,
                createdAt: Date(timeIntervalSince1970: 20),
                lastActivityAt: Date(timeIntervalSince1970: 10)
            )
        )
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeDraft.self, from: data)) {
            XCTAssertEqual($0 as? ForgeDraftError, .invalidTimestampOrder)
        }
    }

    func testDraftExpiresAtThirtyDaysOfInactivity() throws {
        let draft = try makeDraft(createdAt: 0, activityAt: 10)
        XCTAssertFalse(
            draft.isExpired(
                at: Date(timeIntervalSince1970: 10 + ForgePolicyConstants.durableRecordExpiration - 0.001)
            )
        )
        XCTAssertTrue(
            draft.isExpired(
                at: Date(timeIntervalSince1970: 10 + ForgePolicyConstants.durableRecordExpiration)
            )
        )
    }

    func testPublishingDiscardAccountRemovalAndExpirationAreTheOnlyDeletionTransitions() throws {
        let draft = try makeDraft()
        let state = ForgeDraftState.active(draft)
        XCTAssertEqual(try state.applying(.publishSucceeded), .deleted(.published))
        XCTAssertEqual(try state.applying(.discard), .deleted(.explicitlyDiscarded))
        XCTAssertEqual(try state.applying(.accountRemoved(draft.identity.accountID)), .deleted(.accountRemoved))
        XCTAssertEqual(
            try state.applying(
                .expirationSweep(
                    at: draft.lastActivityAt.addingTimeInterval(ForgePolicyConstants.durableRecordExpiration)
                )
            ),
            .deleted(.inactive)
        )

        let other = try ForgeAccountID(forge: draft.identity.accountID.forge, value: "other")
        XCTAssertEqual(try state.applying(.accountRemoved(other)), state)
        XCTAssertEqual(
            try state.applying(
                .expirationSweep(
                    at: draft.lastActivityAt.addingTimeInterval(ForgePolicyConstants.durableRecordExpiration - 1)
                )
            ),
            state
        )
    }

    func testDraftStateRejectsStaleEditEventsAndAppliesCurrentEditAndActivity() throws {
        let draft = try makeDraft(createdAt: 0, activityAt: 10)
        let state = ForgeDraftState.active(draft)
        XCTAssertThrowsError(
            try state.applying(
                .edit(.init(title: "Stale", body: "Stale"), at: Date(timeIntervalSince1970: 9))
            )
        ) {
            XCTAssertEqual($0 as? ForgeDraftError, .staleEdit)
        }
        let edited = try state.applying(
            .edit(.init(title: "Current", body: "Body"), at: Date(timeIntervalSince1970: 11))
        )
        guard case let .active(editedDraft) = edited else { return XCTFail("Expected active draft") }
        XCTAssertEqual(editedDraft.content.title, "Current")
        let active = try edited.applying(.activity(at: Date(timeIntervalSince1970: 12)))
        guard case let .active(activeDraft) = active else { return XCTFail("Expected active draft") }
        XCTAssertEqual(activeDraft.lastActivityAt, Date(timeIntervalSince1970: 12))
    }

    func testEveryFailureCancellationAndHeadChangePreservesDraft() throws {
        let state = try ForgeDraftState.active(makeDraft())
        for reason in [
            ForgeDraftPreservationReason.cancelled,
            .offline,
            .rateLimited,
            .authorizationFailure,
            .conflict,
            .transportFailure,
            .unknownOutcome,
            .displayedHeadChanged,
        ] {
            XCTAssertEqual(try state.applying(.preserve(reason)), state, "Unexpected deletion for \(reason)")
        }
    }

    func testDeletedStateIsTerminal() throws {
        let draft = try makeDraft()
        let deleted = ForgeDraftState.deleted(.published)
        XCTAssertEqual(
            try deleted.applying(.edit(.init(title: "Ignored", body: "Ignored"), at: Date())),
            deleted
        )
        XCTAssertEqual(try deleted.applying(.expirationSweep(at: .distantFuture)), deleted)
        XCTAssertNotEqual(ForgeDraftState.active(draft), deleted)
    }

    func testDraftErrorsHaveSafeDescriptions() {
        for error in [
            ForgeDraftError.invalidDestinationIdentifier,
            .mismatchedAccountForge,
            .displayedHeadRequired,
            .displayedHeadNotAllowed,
            .invalidTimestampOrder,
            .staleEdit,
        ] {
            XCTAssertNotNil(error.errorDescription)
        }
    }

    private struct Context {
        let accountID: ForgeAccountID
        let repository: ForgeRepositoryIdentity
        let destination: ForgeDraftDestination
        let identity: ForgeDraftIdentity
    }

    private func makeContext() throws -> Context {
        let repository = try TestSupport.repository()
        let accountID = try ForgeAccountID(forge: repository.forge, value: "account")
        let destination = ForgeDraftDestination.createPullRequest(
            repository: repository,
            base: TestSupport.main,
            head: TestSupport.feature
        )
        return try Context(
            accountID: accountID,
            repository: repository,
            destination: destination,
            identity: ForgeDraftIdentity(
                accountID: accountID,
                destination: destination
            )
        )
    }

    private func makeDraft(createdAt: TimeInterval = 0, activityAt: TimeInterval = 0) throws -> ForgeDraft {
        try ForgeDraft(
            identity: makeContext().identity,
            content: ForgeDraftContent(title: "Title", body: "Body"),
            createdAt: Date(timeIntervalSince1970: createdAt),
            lastActivityAt: Date(timeIntervalSince1970: activityAt)
        )
    }
}
