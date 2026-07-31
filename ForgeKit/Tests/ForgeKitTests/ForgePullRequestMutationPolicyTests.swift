@testable import ForgeKit
import XCTest

final class ForgePullRequestMutationPolicyTests: XCTestCase {
    func testContextRejectsCrossForgeHeadAndCrossRepositoryBase() throws {
        let fixture = try MutationFixture()
        XCTAssertThrowsError(try fixture.context(head: fixture.crossForgeHead)) {
            XCTAssertEqual($0 as? ForgePullRequestMutationError, .mismatchedForge)
        }
        XCTAssertThrowsError(try fixture.context(base: fixture.otherBase)) {
            XCTAssertEqual($0 as? ForgePullRequestMutationError, .mismatchedRepository)
        }
        XCTAssertThrowsError(try fixture.context(account: fixture.crossForgeAccount)) {
            XCTAssertEqual($0 as? ForgePullRequestMutationError, .mismatchedForge)
        }
    }

    func testEveryLifecycleActionProducesExactHeadBoundRequest() throws {
        let fixture = try MutationFixture()
        let cases: [(ForgePullRequestLifecycleAction, ForgePullRequestMutationContext, Bool)] = try [
            (.markReady, fixture.context(isDraft: true), false),
            (.convertToDraft, fixture.context(), false),
            (.close, fixture.context(), false),
            (.reopen, fixture.context(state: .closed), false),
            (.updateBranch, fixture.context(), true),
        ]
        for (action, context, canUpdate) in cases {
            guard case let .available(request) = ForgePullRequestLifecyclePolicy.decision(
                context: context,
                action: action,
                canUpdateBranch: canUpdate
            ) else {
                return XCTFail("Expected \(action) to be available")
            }
            XCTAssertEqual(request.accountID, fixture.account)
            XCTAssertEqual(request.repository, fixture.repository)
            XCTAssertEqual(request.number, fixture.number)
            XCTAssertEqual(request.action, action)
            XCTAssertEqual(request.expectedHead, fixture.head.commit)
            XCTAssertEqual(action.operation, fixture.operation(for: action))
        }
        XCTAssertEqual(Set(ForgePullRequestLifecycleAction.allCases).count, 5)
    }

    func testLifecycleRejectsEveryInvalidState() throws {
        let fixture = try MutationFixture()
        XCTAssertEqual(
            try ForgePullRequestLifecyclePolicy.decision(context: fixture.context(), action: .markReady),
            .unavailable(.pullRequestIsReady)
        )
        XCTAssertEqual(
            try ForgePullRequestLifecyclePolicy.decision(context: fixture.context(isDraft: true), action: .convertToDraft),
            .unavailable(.pullRequestIsDraft)
        )
        XCTAssertEqual(
            try ForgePullRequestLifecyclePolicy.decision(context: fixture.context(state: .closed), action: .close),
            .unavailable(.pullRequestNotOpen)
        )
        XCTAssertEqual(
            try ForgePullRequestLifecyclePolicy.decision(context: fixture.context(), action: .reopen),
            .unavailable(.pullRequestNotClosed)
        )
        XCTAssertEqual(
            try ForgePullRequestLifecyclePolicy.decision(context: fixture.context(state: .merged), action: .reopen),
            .unavailable(.pullRequestAlreadyMerged)
        )
        XCTAssertEqual(
            try ForgePullRequestLifecyclePolicy.decision(context: fixture.context(), action: .updateBranch),
            .unavailable(.updateBranchUnavailable)
        )
    }

    func testEnvironmentAndCapabilityStopEveryMutationBeforeStateEvaluation() throws {
        let fixture = try MutationFixture()
        let rateLimit = Date(timeIntervalSince1970: 500)
        XCTAssertEqual(
            try ForgePullRequestLifecyclePolicy.decision(
                context: fixture.context(environment: .offline),
                action: .close
            ),
            .unavailable(.offline)
        )
        XCTAssertEqual(
            try ForgePullRequestLifecyclePolicy.decision(
                context: fixture.context(environment: .rateLimited(until: rateLimit)),
                action: .close
            ),
            .unavailable(.rateLimited(until: rateLimit))
        )
        XCTAssertEqual(
            try ForgePullRequestLifecyclePolicy.decision(
                context: fixture.context(allowed: []),
                action: .close
            ),
            .unavailable(.capabilityUnavailable(.closePullRequest))
        )
        XCTAssertEqual(
            try ForgePullRequestMergePolicy.confirmationDecision(
                snapshot: fixture.mergeSnapshot(allowed: []),
                method: .merge
            ),
            .unavailable(.capabilityUnavailable(.mergePullRequest))
        )
        XCTAssertEqual(
            try ForgePullRequestMergeQueuePolicy.decision(
                snapshot: fixture.mergeSnapshot(environment: .offline),
                action: .enter
            ),
            .unavailable(.offline)
        )
        XCTAssertEqual(
            try ForgeHeadBranchDeletionPolicy.decision(
                snapshot: fixture.deletionSnapshot(allowed: []),
                mergeWasQueued: false
            ),
            .unavailable(.capabilityUnavailable(.deleteHeadBranch))
        )
    }

    func testMergeConfirmationCarriesFreshIdentityAndWarnings() throws {
        let fixture = try MutationFixture()
        let warnings = Set(ForgePullRequestMergeWarning.allCases)
        let snapshot = try fixture.mergeSnapshot(warnings: warnings)
        guard case let .available(confirmation) = ForgePullRequestMergePolicy.confirmationDecision(
            snapshot: snapshot,
            method: .squash
        ) else {
            return XCTFail("Expected merge confirmation")
        }
        XCTAssertEqual(confirmation.accountID, fixture.account)
        XCTAssertEqual(confirmation.repository, fixture.repository)
        XCTAssertEqual(confirmation.number, fixture.number)
        XCTAssertEqual(confirmation.headReference, fixture.head)
        XCTAssertEqual(confirmation.baseReference, fixture.base)
        XCTAssertEqual(confirmation.head, fixture.head.commit)
        XCTAssertEqual(confirmation.base, fixture.base.commit)
        XCTAssertEqual(confirmation.updatedAt, fixture.updatedAt)
        XCTAssertEqual(confirmation.method, .squash)
        XCTAssertEqual(confirmation.warnings, warnings)
        XCTAssertNil(confirmation.rebaseSummary)
        XCTAssertEqual(Set(ForgePullRequestMergeMethod.allCases), [.merge, .squash, .rebase])
    }

    func testRebaseSummaryCarriesExactPullRequestAndBranchReferencesWithoutEditableFields() throws {
        let fixture = try MutationFixture()
        guard case let .available(confirmation) = try ForgePullRequestMergePolicy.confirmationDecision(
            snapshot: fixture.mergeSnapshot(),
            method: .rebase
        ) else {
            return XCTFail("Expected rebase confirmation")
        }

        let summary = try XCTUnwrap(confirmation.rebaseSummary)
        XCTAssertEqual(summary.repository, fixture.repository)
        XCTAssertEqual(summary.number, fixture.number)
        XCTAssertEqual(summary.head, fixture.head)
        XCTAssertEqual(summary.base, fixture.base)
    }

    func testMergeTreatsBlockersAsWarningsButEnforcesHardEligibility() throws {
        let fixture = try MutationFixture()
        for warning in ForgePullRequestMergeWarning.allCases {
            XCTAssertAvailable(try ForgePullRequestMergePolicy.confirmationDecision(
                snapshot: fixture.mergeSnapshot(warnings: [warning]),
                method: .merge
            ))
        }
        XCTAssertEqual(
            try ForgePullRequestMergePolicy.confirmationDecision(
                snapshot: fixture.mergeSnapshot(state: .closed), method: .merge
            ),
            .unavailable(.pullRequestNotOpen)
        )
        XCTAssertEqual(
            try ForgePullRequestMergePolicy.confirmationDecision(
                snapshot: fixture.mergeSnapshot(isDraft: true), method: .merge
            ),
            .unavailable(.pullRequestIsDraft)
        )
        XCTAssertEqual(
            try ForgePullRequestMergePolicy.confirmationDecision(
                snapshot: fixture.mergeSnapshot(viewerCanMerge: false), method: .merge
            ),
            .unavailable(.viewerCannotMerge)
        )
        XCTAssertEqual(
            try ForgePullRequestMergePolicy.confirmationDecision(
                snapshot: fixture.mergeSnapshot(enabledMethods: [.squash]), method: .merge
            ),
            .unavailable(.mergeMethodDisabled)
        )
    }

    func testMergeRefetchValidationStopsAllFreshnessRaces() throws {
        let fixture = try MutationFixture()
        let snapshot = try fixture.mergeSnapshot()
        guard case let .available(confirmation) = ForgePullRequestMergePolicy.confirmationDecision(
            snapshot: snapshot,
            method: .merge
        ) else {
            return XCTFail("Expected merge confirmation")
        }
        let validated = try ForgePullRequestMergePolicy.validate(confirmation: confirmation, fresh: snapshot)
        XCTAssertEqual(validated.confirmation, confirmation)

        let staleSnapshots = try [
            fixture.mergeSnapshot(account: fixture.otherAccount),
            fixture.mergeSnapshot(repository: fixture.otherRepository),
            fixture.mergeSnapshot(number: ForgeItemNumber(99)),
            fixture.mergeSnapshot(head: fixture.changedHead),
            fixture.mergeSnapshot(base: fixture.changedBase),
            fixture.mergeSnapshot(updatedAt: fixture.updatedAt.addingTimeInterval(1)),
            fixture.mergeSnapshot(viewerCanMerge: false),
            fixture.mergeSnapshot(head: ForgeBranchReference(
                repository: fixture.head.repository,
                name: ForgeRefName("feature/renamed"),
                commit: fixture.head.commit
            )),
            fixture.mergeSnapshot(base: ForgeBranchReference(
                repository: fixture.base.repository,
                name: ForgeRefName("release"),
                commit: fixture.base.commit
            )),
        ]
        for stale in staleSnapshots {
            XCTAssertThrowsError(try ForgePullRequestMergePolicy.validate(confirmation: confirmation, fresh: stale)) {
                XCTAssertEqual($0 as? ForgePullRequestMutationError, .staleConfirmation)
            }
        }
    }

    func testMergeRequestEditingMatchesMethodContract() throws {
        let fixture = try MutationFixture()
        let snapshot = try fixture.mergeSnapshot()
        for method in [ForgePullRequestMergeMethod.merge, .squash] {
            guard case let .available(confirmation) = ForgePullRequestMergePolicy.confirmationDecision(
                snapshot: snapshot,
                method: method
            ) else { return XCTFail("Expected method") }
            let request = try ForgePullRequestMergeRequest(
                confirmation: confirmation,
                title: "Merge title",
                message: "Merge message"
            )
            XCTAssertEqual(request.title, "Merge title")
            XCTAssertEqual(request.message, "Merge message")
            XCTAssertThrowsError(try ForgePullRequestMergeRequest(confirmation: confirmation, title: "\n")) {
                XCTAssertEqual($0 as? ForgePullRequestMutationError, .invalidMessage)
            }
            XCTAssertThrowsError(try ForgePullRequestMergeRequest(confirmation: confirmation, message: "\t")) {
                XCTAssertEqual($0 as? ForgePullRequestMutationError, .invalidMessage)
            }
        }
        guard case let .available(rebase) = ForgePullRequestMergePolicy.confirmationDecision(
            snapshot: snapshot, method: .rebase
        ) else { return XCTFail("Expected rebase") }
        XCTAssertNoThrow(try ForgePullRequestMergeRequest(confirmation: rebase))
        XCTAssertThrowsError(try ForgePullRequestMergeRequest(confirmation: rebase, title: "No edits")) {
            XCTAssertEqual($0 as? ForgePullRequestMutationError, .invalidMessage)
        }
    }

    func testMergePreferenceRecordsOnlySuccessfulRepositoryScopedMethod() throws {
        let fixture = try MutationFixture()
        var ledger = ForgePullRequestMergePreferenceLedger()
        XCTAssertNil(ledger.preferredMethod(for: fixture.repository, enabledMethods: Set(ForgePullRequestMergeMethod.allCases)))
        ledger.recordSuccessfulMerge(repository: fixture.repository, method: .squash)
        XCTAssertEqual(ledger.preferredMethod(for: fixture.repository, enabledMethods: [.squash]), .squash)
        XCTAssertNil(ledger.preferredMethod(for: fixture.repository, enabledMethods: [.merge]))
        XCTAssertNil(ledger.preferredMethod(for: fixture.otherRepository, enabledMethods: [.squash]))
        XCTAssertEqual(try roundTrip(ledger), ledger)
    }

    func testMergeQueueIsExplicitHeadBoundAndNeverAutomatic() throws {
        let fixture = try MutationFixture()
        guard case let .available(enter) = try ForgePullRequestMergeQueuePolicy.decision(
            snapshot: fixture.mergeSnapshot(queueState: .notQueued), action: .enter
        ) else { return XCTFail("Expected enter") }
        XCTAssertEqual(enter.action, .enter)
        XCTAssertEqual(enter.expectedHead, fixture.head.commit)
        XCTAssertEqual(enter.action.operation, .enterMergeQueue)

        guard case let .available(leave) = try ForgePullRequestMergeQueuePolicy.decision(
            snapshot: fixture.mergeSnapshot(queueState: .queued), action: .leave
        ) else { return XCTFail("Expected leave") }
        XCTAssertEqual(leave.action, .leave)
        XCTAssertEqual(leave.action.operation, .leaveMergeQueue)
        XCTAssertEqual(
            try ForgePullRequestMergeQueuePolicy.decision(
                snapshot: fixture.mergeSnapshot(queueState: .queued), action: .enter
            ),
            .unavailable(.mergeQueueAlreadyEntered)
        )
        XCTAssertEqual(
            try ForgePullRequestMergeQueuePolicy.decision(
                snapshot: fixture.mergeSnapshot(queueState: .notQueued), action: .leave
            ),
            .unavailable(.mergeQueueNotEntered)
        )
        XCTAssertEqual(
            try ForgePullRequestMergeQueuePolicy.decision(
                snapshot: fixture.mergeSnapshot(isDraft: true), action: .enter
            ),
            .unavailable(.pullRequestIsDraft)
        )
        XCTAssertEqual(
            try ForgePullRequestMergeQueuePolicy.decision(
                snapshot: fixture.mergeSnapshot(state: .closed), action: .enter
            ),
            .unavailable(.pullRequestNotOpen)
        )
    }

    func testHeadDeletionRequiresMergedSafeSameRepositoryBranch() throws {
        let fixture = try MutationFixture()
        guard case let .available(request) = try ForgeHeadBranchDeletionPolicy.decision(
            snapshot: fixture.deletionSnapshot(), mergeWasQueued: false
        ) else { return XCTFail("Expected deletion") }
        XCTAssertEqual(request.accountID, fixture.account)
        XCTAssertEqual(request.repository, fixture.repository)
        XCTAssertEqual(request.branch, fixture.head.name)
        XCTAssertEqual(request.expectedHead, fixture.head.commit)

        let cases: [(ForgeHeadBranchDeletionSnapshot, Bool, ForgePullRequestMutationUnavailableReason)] = try [
            (fixture.deletionSnapshot(state: .open), false, .branchDeletionUnavailable),
            (fixture.deletionSnapshot(), true, .branchDeletionUnavailable),
            (fixture.deletionSnapshot(sameRepository: false), false, .forkHeadBranch),
            (fixture.deletionSnapshot(defaultBranch: true), false, .defaultBranch),
            (fixture.deletionSnapshot(protected: true), false, .protectedBranch),
            (fixture.deletionSnapshot(canDelete: false), false, .branchDeletionUnavailable),
            (fixture.deletionSnapshot(safetyConflict: true), false, .checkedOutBranch),
        ]
        for (snapshot, queued, reason) in cases {
            XCTAssertEqual(
                ForgeHeadBranchDeletionPolicy.decision(snapshot: snapshot, mergeWasQueued: queued),
                .unavailable(reason)
            )
        }
    }

    func testDeletionPreferenceDefaultsOffAndIsRepositoryScoped() throws {
        let fixture = try MutationFixture()
        var ledger = ForgeHeadBranchDeletionPreferenceLedger()
        XCTAssertFalse(ledger.rememberedChoice(for: fixture.repository))
        ledger.recordSuccessfulChoice(repository: fixture.repository, selected: true)
        XCTAssertTrue(ledger.rememberedChoice(for: fixture.repository))
        XCTAssertFalse(ledger.rememberedChoice(for: fixture.otherRepository))
        ledger.recordSuccessfulChoice(repository: fixture.repository, selected: false)
        XCTAssertFalse(ledger.rememberedChoice(for: fixture.repository))
        XCTAssertEqual(try roundTrip(ledger), ledger)
    }

    func testPostMergeNeverChangesCheckoutAutomatically() {
        XCTAssertEqual(ForgePostMergePolicy.explicitActions, [.fetch, .checkOutBase])
    }

    func testMutationResultPreservesAuthoritativeFailuresAndUnknownOutcomes() throws {
        let executing = try ForgeMutationResultState.idle.applying(.begin)
        XCTAssertEqual(executing, .executing)
        XCTAssertEqual(try executing.applying(.succeeded), .succeeded)
        XCTAssertEqual(
            try executing.applying(.failed(authoritativeMessage: "GitHub rejected the merge.")),
            .failed(authoritativeMessage: "GitHub rejected the merge.")
        )
        let unknown = try executing.applying(.outcomeUnknown)
        XCTAssertEqual(unknown, .outcomeUnknown)
        XCTAssertThrowsError(try unknown.applying(.retry)) {
            XCTAssertEqual($0 as? ForgePullRequestMutationError, .invalidTransition)
        }
        XCTAssertEqual(try unknown.applying(.reconciled(succeeded: true)), .reconciled(succeeded: true))
        XCTAssertEqual(
            try unknown.applying(.reconciled(succeeded: false)).applying(.retry),
            .executing
        )
        let retry = try ForgeMutationResultState.failed(authoritativeMessage: "Denied").applying(.retry)
        XCTAssertEqual(retry, .executing)
        XCTAssertThrowsError(try executing.applying(.failed(authoritativeMessage: "\n"))) {
            XCTAssertEqual($0 as? ForgePullRequestMutationError, .invalidMessage)
        }
        XCTAssertThrowsError(try ForgeMutationResultState.succeeded.applying(.retry)) {
            XCTAssertEqual($0 as? ForgePullRequestMutationError, .invalidTransition)
        }
    }

    func testErrorsHaveStableDescriptions() {
        let errors: [ForgePullRequestMutationError] = [
            .mismatchedForge, .mismatchedRepository, .invalidMutation,
            .invalidMessage, .staleConfirmation, .invalidTransition,
        ]
        XCTAssertTrue(errors.allSatisfy { !($0.errorDescription ?? "").isEmpty })
    }

    private func XCTAssertAvailable<Value>(
        _ decision: ForgePullRequestMutationDecision<Value>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .available = decision else {
            return XCTFail("Expected available decision", file: file, line: line)
        }
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}

private struct MutationFixture {
    let account: ForgeAccountID
    let otherAccount: ForgeAccountID
    let crossForgeAccount: ForgeAccountID
    let repository: ForgeRepositoryIdentity
    let otherRepository: ForgeRepositoryIdentity
    let number = try! ForgeItemNumber(12)
    let head: ForgeBranchReference
    let changedHead: ForgeBranchReference
    let crossForgeHead: ForgeBranchReference
    let base: ForgeBranchReference
    let changedBase: ForgeBranchReference
    let otherBase: ForgeBranchReference
    let updatedAt = Date(timeIntervalSince1970: 100)

    init() throws {
        let github = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let gitlab = try ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com"))
        repository = try ForgeRepositoryIdentity(forge: github, owner: "gitx", name: "gitx")
        otherRepository = try ForgeRepositoryIdentity(forge: github, owner: "other", name: "gitx")
        let gitlabRepository = try ForgeRepositoryIdentity(forge: gitlab, owner: "gitx", name: "gitx")
        account = try ForgeAccountID(forge: github, value: "account")
        otherAccount = try ForgeAccountID(forge: github, value: "other-account")
        crossForgeAccount = try ForgeAccountID(forge: gitlab, value: "gitlab-account")
        head = try ForgeBranchReference(
            repository: repository,
            name: ForgeRefName("feature/review"),
            commit: ForgeCommitID(String(repeating: "a", count: 40))
        )
        changedHead = try ForgeBranchReference(
            repository: repository,
            name: head.name,
            commit: ForgeCommitID(String(repeating: "b", count: 40))
        )
        crossForgeHead = ForgeBranchReference(
            repository: gitlabRepository,
            name: head.name,
            commit: head.commit
        )
        base = try ForgeBranchReference(
            repository: repository,
            name: ForgeRefName("main"),
            commit: ForgeCommitID(String(repeating: "c", count: 40))
        )
        changedBase = try ForgeBranchReference(
            repository: repository,
            name: base.name,
            commit: ForgeCommitID(String(repeating: "d", count: 40))
        )
        otherBase = ForgeBranchReference(repository: otherRepository, name: base.name, commit: base.commit)
    }

    func context(
        account: ForgeAccountID? = nil,
        repository: ForgeRepositoryIdentity? = nil,
        number: ForgeItemNumber? = nil,
        state: ForgePullRequestState = .open,
        isDraft: Bool = false,
        head: ForgeBranchReference? = nil,
        base: ForgeBranchReference? = nil,
        updatedAt: Date? = nil,
        allowed: Set<ForgeOperation>? = nil,
        environment: ForgeMutationEnvironment = .available
    ) throws -> ForgePullRequestMutationContext {
        try ForgePullRequestMutationContext(
            accountID: account ?? self.account,
            repository: repository ?? self.repository,
            number: number ?? self.number,
            state: state,
            isDraft: isDraft,
            head: head ?? self.head,
            base: base ?? self.base,
            updatedAt: updatedAt ?? self.updatedAt,
            allowedOperations: allowed ?? Set(ForgeOperation.allCases),
            environment: environment
        )
    }

    func mergeSnapshot(
        account: ForgeAccountID? = nil,
        repository: ForgeRepositoryIdentity? = nil,
        number: ForgeItemNumber? = nil,
        state: ForgePullRequestState = .open,
        isDraft: Bool = false,
        head: ForgeBranchReference? = nil,
        base: ForgeBranchReference? = nil,
        updatedAt: Date? = nil,
        viewerCanMerge: Bool = true,
        enabledMethods: Set<ForgePullRequestMergeMethod> = Set(ForgePullRequestMergeMethod.allCases),
        warnings: Set<ForgePullRequestMergeWarning> = [],
        queueState: ForgePullRequestMergeQueueState = .notQueued,
        allowed: Set<ForgeOperation>? = nil,
        environment: ForgeMutationEnvironment = .available
    ) throws -> ForgePullRequestMergeSnapshot {
        let selectedRepository = repository ?? self.repository
        let selectedHead = head ?? (selectedRepository == self.repository ? self.head : ForgeBranchReference(
            repository: selectedRepository,
            name: self.head.name,
            commit: self.head.commit
        ))
        let selectedBase = base ?? (selectedRepository == self.repository ? self.base : ForgeBranchReference(
            repository: selectedRepository,
            name: self.base.name,
            commit: self.base.commit
        ))
        return try ForgePullRequestMergeSnapshot(
            context: context(
                account: account,
                repository: selectedRepository,
                number: number,
                state: state,
                isDraft: isDraft,
                head: selectedHead,
                base: selectedBase,
                updatedAt: updatedAt,
                allowed: allowed,
                environment: environment
            ),
            viewerCanMerge: viewerCanMerge,
            enabledMethods: enabledMethods,
            warnings: warnings,
            queueState: queueState
        )
    }

    func deletionSnapshot(
        state: ForgePullRequestState = .merged,
        sameRepository: Bool = true,
        defaultBranch: Bool = false,
        protected: Bool = false,
        canDelete: Bool = true,
        safetyConflict: Bool = false,
        allowed: Set<ForgeOperation>? = nil
    ) throws -> ForgeHeadBranchDeletionSnapshot {
        try ForgeHeadBranchDeletionSnapshot(
            mergeSnapshot: mergeSnapshot(state: state, allowed: allowed),
            isSameRepository: sameRepository,
            isDefaultBranch: defaultBranch,
            isProtected: protected,
            viewerCanDelete: canDelete,
            hasCheckedOutSafetyConflict: safetyConflict
        )
    }

    func operation(for action: ForgePullRequestLifecycleAction) -> ForgeOperation {
        switch action {
        case .markReady: .markPullRequestReady
        case .convertToDraft: .convertPullRequestToDraft
        case .close: .closePullRequest
        case .reopen: .reopenPullRequest
        case .updateBranch: .updatePullRequestBranch
        }
    }
}
