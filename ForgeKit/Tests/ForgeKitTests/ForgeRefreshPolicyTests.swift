@testable import ForgeKit
import Foundation
import XCTest

final class ForgeRefreshPolicyTests: XCTestCase {
    func testOverlayAndAttentionIntervalsMatchAcceptedTargets() {
        XCTAssertEqual(ForgeRefreshPolicy.interval(for: .affectedViewActive), 60)
        XCTAssertEqual(ForgeRefreshPolicy.interval(for: .otherOpenRepository), 300)
        XCTAssertEqual(ForgeRefreshPolicy.interval(for: .otherBoundRepository), 900)

        XCTAssertEqual(ForgeAttentionPollingPreset.defaultValue, .balanced)
        XCTAssertEqual(ForgeAttentionPollingPreset.frequent.activeInterval, 120)
        XCTAssertEqual(ForgeAttentionPollingPreset.frequent.backgroundInterval, 300)
        XCTAssertEqual(ForgeAttentionPollingPreset.balanced.activeInterval, 300)
        XCTAssertEqual(ForgeAttentionPollingPreset.balanced.backgroundInterval, 900)
        XCTAssertEqual(ForgeAttentionPollingPreset.conservative.activeInterval, 900)
        XCTAssertEqual(ForgeAttentionPollingPreset.conservative.backgroundInterval, 1800)
        XCTAssertNil(ForgeAttentionPollingPreset.manual.activeInterval)
        XCTAssertNil(ForgeAttentionPollingPreset.manual.backgroundInterval)
    }

    func testRequestCoalescingUnionsNeedsReasonsAndPreservesEarliestDate() throws {
        let target = try makeTarget(account: "one", repositoryOwner: "acme")
        let first = try ForgeRefreshRequest(
            target: target,
            reasons: [.repositoryOpened],
            recordKinds: [.repositoryFacts, .pullRequestPage],
            sequence: ForgeRefreshRequestSequence(1),
            requestedAt: Date(timeIntervalSince1970: 20)
        )
        let second = try ForgeRefreshRequest(
            target: target,
            reasons: [.manual, .mutationCompleted],
            recordKinds: [.pullRequestDetail],
            sequence: ForgeRefreshRequestSequence(2),
            requestedAt: Date(timeIntervalSince1970: 10)
        )
        let combined = try XCTUnwrap(first.coalesced(with: second))
        XCTAssertEqual(combined.reasons, [.repositoryOpened, .manual, .mutationCompleted])
        XCTAssertEqual(combined.recordKinds, [.repositoryFacts, .pullRequestPage, .pullRequestDetail])
        XCTAssertEqual(combined.sequence, second.sequence)
        XCTAssertEqual(combined.requestedAt, Date(timeIntervalSince1970: 10))
        XCTAssertTrue(combined.satisfies(first))
        XCTAssertTrue(combined.satisfies(second))
        XCTAssertFalse(first.satisfies(second))
    }

    func testRequestsNeverCoalesceAcrossAccountRepositoryOrPublicPartitions() throws {
        let first = try request(account: "one", owner: "acme")
        let otherAccount = try request(account: "two", owner: "acme")
        let otherRepository = try request(account: "one", owner: "other")
        let publicRequest = try ForgeRefreshRequest(
            target: ForgeRefreshTarget(
                authentication: .publicAccess,
                repository: first.target.repository
            ),
            reasons: [.manual],
            recordKinds: [.repositoryFacts],
            sequence: ForgeRefreshRequestSequence(2),
            requestedAt: .distantPast
        )
        XCTAssertNil(first.coalesced(with: otherAccount))
        XCTAssertNil(first.coalesced(with: otherRepository))
        XCTAssertNil(first.coalesced(with: publicRequest))
        XCTAssertEqual(first.target.repositoryPartition.cachePartition, first.target.authentication.cachePartition)
        XCTAssertEqual(publicRequest.target.repositoryPartition.cachePartition, .publicAccess)
    }

    func testCredentialCooldownBlocksEveryMatchingRepositoryButNoOtherCredential() throws {
        let first = try makeTarget(account: "one", repositoryOwner: "acme")
        let sameCredentialOtherRepository = try ForgeRefreshTarget(
            authentication: first.authentication,
            repository: TestSupport.repository(owner: "other")
        )
        let otherCredential = try makeTarget(account: "two", repositoryOwner: "acme")
        guard case let .credential(reference) = first.authentication else {
            return XCTFail("Expected credential target")
        }
        let cooldown = ForgeCredentialCooldown(
            credential: reference,
            deadline: Date(timeIntervalSince1970: 100)
        )
        XCTAssertTrue(cooldown.blocks(first, at: Date(timeIntervalSince1970: 99)))
        XCTAssertTrue(cooldown.blocks(sameCredentialOtherRepository, at: Date(timeIntervalSince1970: 99)))
        XCTAssertFalse(cooldown.blocks(otherCredential, at: Date(timeIntervalSince1970: 99)))
        XCTAssertFalse(cooldown.blocks(first, at: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(
            try cooldown.blocks(
                ForgeRefreshTarget(authentication: .publicAccess, repository: first.repository),
                at: Date(timeIntervalSince1970: 99)
            )
        )
    }

    func testRefreshTargetRejectsCrossForgeCredentialDirectlyAndWhenDecoded() throws {
        struct UnvalidatedTarget: Encodable {
            let authentication: ForgeRefreshAuthentication
            let repository: ForgeRepositoryIdentity
        }

        let repository = try TestSupport.repository()
        let gitLab = try TestSupport.repository(kind: .gitLab)
        let accountID = try ForgeAccountID(forge: gitLab.forge, value: "account")
        let credential = try ForgeCredentialReference(
            accountID: accountID,
            credentialID: ForgeCredentialID("credential"),
            generation: ForgeCredentialGeneration(1)
        )
        XCTAssertThrowsError(
            try ForgeRefreshTarget(authentication: .credential(credential), repository: repository)
        ) {
            XCTAssertEqual($0 as? ForgeRefreshPolicyError, .mismatchedCredentialForge)
        }
        let data = try JSONEncoder().encode(
            UnvalidatedTarget(authentication: .credential(credential), repository: repository)
        )
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeRefreshTarget.self, from: data)) {
            XCTAssertEqual($0 as? ForgeRefreshPolicyError, .mismatchedCredentialForge)
        }
    }

    func testRefreshTargetAndGenerationRoundTripWithValidatedValues() throws {
        let target = try makeTarget(account: "account", repositoryOwner: "acme")
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeRefreshTarget.self, from: JSONEncoder().encode(target)),
            target
        )

        let first = try ForgeRefreshGeneration(1)
        let second = try ForgeRefreshGeneration(2)
        XCTAssertLessThan(first, second)
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeRefreshGeneration.self, from: JSONEncoder().encode(second)),
            second
        )

        let firstRequest = try ForgeRefreshRequestSequence(1)
        let secondRequest = try ForgeRefreshRequestSequence(2)
        XCTAssertLessThan(firstRequest, secondRequest)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ForgeRefreshRequestSequence.self,
                from: JSONEncoder().encode(secondRequest)
            ),
            secondRequest
        )
    }

    func testSingleFlightAndReverseCompletionsCannotApplyAnOlderSnapshot() throws {
        let initial = try request(account: "one", owner: "acme")
        let newer = try ForgeRefreshRequest(
            target: initial.target,
            reasons: [.manual],
            recordKinds: [.pullRequestDetail],
            sequence: ForgeRefreshRequestSequence(2),
            requestedAt: Date(timeIntervalSince1970: 20)
        )
        var state = ForgeCausalRefreshState(target: initial.target)
        let firstExecution = try state.start(initial, at: Date(timeIntervalSince1970: 10))
        XCTAssertThrowsError(try state.start(newer, at: Date(timeIntervalSince1970: 20))) {
            XCTAssertEqual($0 as? ForgeRefreshPolicyError, .refreshAlreadyInFlight)
        }
        XCTAssertEqual(state.inFlight, firstExecution)

        var snapshot = ForgeSnapshotState<String>.unavailable.startingRefresh(firstExecution)
        guard case let .apply(firstApplication) = state.complete(
            firstExecution,
            with: .success(record: "old", fetchedAt: .distantPast, completeness: .complete)
        ) else {
            return XCTFail("Expected the current result to be authorized")
        }
        let secondExecution = try state.start(newer, at: Date(timeIntervalSince1970: 20))
        snapshot = snapshot.startingRefresh(secondExecution)

        XCTAssertEqual(firstExecution.generation.value, 1)
        XCTAssertEqual(secondExecution.generation.value, 2)
        XCTAssertEqual(state.latestStartedGeneration, secondExecution.generation)
        let staleCompletion: ForgeRefreshCompletionDisposition<String> = state.complete(
            firstExecution,
            with: .success(record: "late old", fetchedAt: .distantPast, completeness: .complete)
        )
        XCTAssertEqual(staleCompletion, .discardStale)
        XCTAssertThrowsError(try snapshot.applying(firstApplication)) {
            XCTAssertEqual($0 as? ForgeCachePolicyError, .staleRefreshGeneration)
        }

        let newestFetchedAt = Date(timeIntervalSince1970: 30)
        guard case let .apply(secondApplication) = state.complete(
            secondExecution,
            with: .success(record: "new", fetchedAt: newestFetchedAt, completeness: .complete)
        ) else {
            return XCTFail("Expected the newest result to be authorized")
        }
        XCTAssertEqual(
            try snapshot.applying(secondApplication),
            .fresh(record: "new", fetchedAt: newestFetchedAt, completeness: .complete)
        )
    }

    func testEqualAndReversedClockEventsUseSequencesAndQueueACausalFollowUp() throws {
        let initial = try request(account: "one", owner: "acme", sequence: 2)
        var state = ForgeCausalRefreshState(target: initial.target)
        let execution = try state.start(initial, at: Date(timeIntervalSince1970: 10))
        let alreadyCovered = try ForgeRefreshRequest(
            target: initial.target,
            reasons: [.repositoryOpened],
            recordKinds: [.repositoryFacts],
            sequence: ForgeRefreshRequestSequence(1),
            requestedAt: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(
            try state.receive(alreadyCovered),
            .satisfiedByInFlight(execution.generation)
        )

        let mutation = try ForgeRefreshRequest(
            target: initial.target,
            reasons: [.mutationCompleted],
            recordKinds: [.pullRequestDetail],
            sequence: ForgeRefreshRequestSequence(3),
            requestedAt: Date(timeIntervalSince1970: 10)
        )
        let selection = try ForgeRefreshRequest(
            target: initial.target,
            reasons: [.selectedPullRequestChanged],
            recordKinds: [.pullRequestTimeline],
            sequence: ForgeRefreshRequestSequence(4),
            requestedAt: Date(timeIntervalSince1970: 5)
        )
        XCTAssertEqual(try state.receive(selection), .queuedAfterInFlight)
        XCTAssertEqual(state.highestAcceptedRequestSequence, selection.sequence)
        let pendingSelection = state.pendingRequest
        XCTAssertThrowsError(try state.start(mutation, at: Date(timeIntervalSince1970: 5))) {
            XCTAssertEqual($0 as? ForgeRefreshPolicyError, .refreshAlreadyInFlight)
        }
        XCTAssertEqual(state.inFlight, execution)
        XCTAssertEqual(state.pendingRequest, pendingSelection)
        XCTAssertEqual(
            try state.receive(mutation),
            .retainedStaleSequenceForFollowUp(selection.sequence)
        )
        XCTAssertEqual(state.highestAcceptedRequestSequence, selection.sequence)
        guard case let .apply(application) = state.complete(
            execution,
            with: .success(record: "snapshot", fetchedAt: .distantPast, completeness: .complete)
        ), let nextRequest = application.nextRequest else {
            return XCTFail("Expected the current result to apply with a causal follow-up")
        }
        XCTAssertEqual(nextRequest.reasons, [.mutationCompleted, .selectedPullRequestChanged])
        XCTAssertEqual(nextRequest.recordKinds, [.pullRequestDetail, .pullRequestTimeline])
        XCTAssertEqual(nextRequest.sequence, selection.sequence)
        XCTAssertEqual(nextRequest.requestedAt, selection.requestedAt)
        let followUp = try state.start(nextRequest, at: Date(timeIntervalSince1970: 13))
        XCTAssertEqual(followUp.generation.value, 2)
        XCTAssertEqual(followUp.request.sequence, selection.sequence)

        let delayedAcrossExecutions = try ForgeRefreshRequest(
            target: initial.target,
            reasons: [.networkRestored],
            recordKinds: [.issueDetail],
            sequence: ForgeRefreshRequestSequence(3),
            requestedAt: Date(timeIntervalSince1970: 4)
        )
        XCTAssertEqual(
            try state.receive(delayedAcrossExecutions),
            .retainedStaleSequenceForFollowUp(selection.sequence)
        )
        XCTAssertEqual(state.pendingRequest?.sequence, selection.sequence)
        XCTAssertEqual(state.pendingRequest?.recordKinds, [.issueDetail])
        guard case let .apply(followUpApplication) = state.complete(
            followUp,
            with: .success(record: "follow-up", fetchedAt: .distantPast, completeness: .complete)
        ), let retainedRequest = followUpApplication.nextRequest else {
            return XCTFail("Expected delayed required work to remain queued")
        }
        XCTAssertEqual(retainedRequest.sequence, selection.sequence)
        let retainedExecution = try state.start(retainedRequest, at: Date(timeIntervalSince1970: 14))
        XCTAssertEqual(retainedExecution.generation.value, 3)
        XCTAssertEqual(retainedExecution.request.recordKinds, [.issueDetail])
        let retainedCompletion: ForgeRefreshCompletionDisposition<String> = state.complete(
            retainedExecution,
            with: .success(record: "retained", fetchedAt: .distantPast, completeness: .complete)
        )
        guard case let .apply(retainedApplication) = retainedCompletion else {
            return XCTFail("Expected retained work to complete")
        }
        XCTAssertNil(retainedApplication.nextRequest)

        XCTAssertThrowsError(try state.start(selection, at: Date(timeIntervalSince1970: 15))) {
            XCTAssertEqual($0 as? ForgeRefreshPolicyError, .staleRequestSequence)
        }
        XCTAssertThrowsError(try state.start(delayedAcrossExecutions, at: Date(timeIntervalSince1970: 15))) {
            XCTAssertEqual($0 as? ForgeRefreshPolicyError, .staleRequestSequence)
        }

        let delayedAfterExecutions = try ForgeRefreshRequest(
            target: initial.target,
            reasons: [.unknownOutcomeReconciliation],
            recordKinds: [.checks],
            sequence: ForgeRefreshRequestSequence(2),
            requestedAt: Date(timeIntervalSince1970: 3)
        )
        XCTAssertEqual(
            try state.receive(delayedAfterExecutions),
            .retainedStaleSequenceForFollowUp(selection.sequence)
        )
        let afterExecutionRequest = try XCTUnwrap(state.pendingRequest)
        XCTAssertEqual(afterExecutionRequest.sequence, selection.sequence)
        XCTAssertEqual(afterExecutionRequest.recordKinds, [.checks])
        let afterExecution = try state.start(afterExecutionRequest, at: Date(timeIntervalSince1970: 16))
        XCTAssertEqual(afterExecution.generation.value, 4)
        XCTAssertEqual(afterExecution.request.sequence, selection.sequence)
    }

    func testCausalStateRejectsMismatchedTargetsAndInvalidOrExhaustedGeneration() throws {
        let request = try request(account: "one", owner: "acme")
        let other = try self.request(account: "two", owner: "acme")
        var state = ForgeCausalRefreshState(target: request.target)
        XCTAssertThrowsError(try state.start(other, at: .distantPast)) {
            XCTAssertEqual($0 as? ForgeRefreshPolicyError, .mismatchedRequestTarget)
        }
        XCTAssertThrowsError(try state.receive(other)) {
            XCTAssertEqual($0 as? ForgeRefreshPolicyError, .mismatchedRequestTarget)
        }
        XCTAssertEqual(try state.receive(request), .readyToStart)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeRefreshGeneration.self, from: Data("0".utf8))) {
            XCTAssertEqual($0 as? ForgeRefreshPolicyError, .invalidGeneration)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeRefreshRequestSequence.self, from: Data("0".utf8))) {
            XCTAssertEqual($0 as? ForgeRefreshPolicyError, .invalidRequestSequence)
        }

        var exhausted = try ForgeCausalRefreshState(
            target: request.target,
            latestStartedGeneration: ForgeRefreshGeneration(UInt64.max)
        )
        XCTAssertThrowsError(try exhausted.start(request, at: .distantPast)) {
            XCTAssertEqual($0 as? ForgeRefreshPolicyError, .generationExhausted)
        }
        for error in [
            ForgeRefreshPolicyError.mismatchedCredentialForge,
            .mismatchedRequestTarget,
            .refreshAlreadyInFlight,
            .staleRequestSequence,
            .invalidRequestSequence,
            .invalidGeneration,
            .generationExhausted,
        ] {
            XCTAssertNotNil(error.errorDescription)
        }
    }

    func testAnonymousBudgetProtectsTenRequestsAndHonorsOneCooldown() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(ForgeAnonymousRateBudget(remainingRequestCount: 11).decision(at: now), .allowed)
        XCTAssertEqual(ForgeAnonymousRateBudget(remainingRequestCount: 10).decision(at: now), .reserveProtected)
        XCTAssertEqual(
            ForgeAnonymousRateBudget(remainingRequestCount: 12).decision(plannedRequestCost: 2, at: now),
            .allowed
        )
        XCTAssertEqual(
            ForgeAnonymousRateBudget(remainingRequestCount: 11).decision(plannedRequestCost: 2, at: now),
            .reserveProtected
        )
        let deadline = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(
            ForgeAnonymousRateBudget(remainingRequestCount: 100, cooldownDeadline: deadline).decision(at: now),
            .cooldown(until: deadline)
        )
        XCTAssertEqual(
            ForgeAnonymousRateBudget(remainingRequestCount: 100, cooldownDeadline: deadline).decision(at: deadline),
            .allowed
        )
    }

    func testAnonymousModeHasOnlyExplicitOpenOrManualRefreshAndNoTimer() {
        XCTAssertFalse(ForgeRefreshPolicy.mayScheduleAutomatically(authentication: .publicAccess))
        XCTAssertTrue(ForgeRefreshPolicy.anonymousRequestIsExplicitlyAllowed(for: .repositoryOpened))
        XCTAssertTrue(ForgeRefreshPolicy.anonymousRequestIsExplicitlyAllowed(for: .manual))
        for reason in ForgeRefreshReason.allCases where ![.repositoryOpened, .manual].contains(reason) {
            XCTAssertFalse(ForgeRefreshPolicy.anonymousRequestIsExplicitlyAllowed(for: reason), "Unexpected \(reason)")
        }
    }

    func testCredentialModeMayScheduleAutomatically() throws {
        XCTAssertTrue(
            try ForgeRefreshPolicy.mayScheduleAutomatically(
                authentication: makeTarget(account: "account", repositoryOwner: "acme").authentication
            )
        )
    }

    func testRefreshStateDistinguishesPartialStaleOfflineCooldownAndCancellation() throws {
        let request = try request(account: "one", owner: "acme")
        let date = Date(timeIntervalSince1970: 100)
        XCTAssertNotEqual(
            ForgeRefreshState.succeeded(at: date, completeness: .partial(unavailableSections: [.checks])),
            .succeeded(at: date, completeness: .complete)
        )
        XCTAssertNotEqual(
            ForgeRefreshState.failed(at: date, retainedStaleSnapshot: true),
            .failed(at: date, retainedStaleSnapshot: false)
        )
        XCTAssertNotEqual(ForgeRefreshState.suspendedOffline(request), .cancelled)
        XCTAssertNotEqual(ForgeRefreshState.suspendedCooldown(request, until: date), .cancelled)
    }

    private func request(account: String, owner: String, sequence: UInt64 = 1) throws -> ForgeRefreshRequest {
        try ForgeRefreshRequest(
            target: makeTarget(account: account, repositoryOwner: owner),
            reasons: [.manual],
            recordKinds: [.repositoryFacts],
            sequence: ForgeRefreshRequestSequence(sequence),
            requestedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeTarget(account: String, repositoryOwner: String) throws -> ForgeRefreshTarget {
        let repository = try TestSupport.repository(owner: repositoryOwner)
        let accountID = try ForgeAccountID(forge: repository.forge, value: account)
        let reference = try ForgeCredentialReference(
            accountID: accountID,
            credentialID: ForgeCredentialID("credential-\(account)"),
            generation: ForgeCredentialGeneration(1)
        )
        return try ForgeRefreshTarget(authentication: .credential(reference), repository: repository)
    }
}
