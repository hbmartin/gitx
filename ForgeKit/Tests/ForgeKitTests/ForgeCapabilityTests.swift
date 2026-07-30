@testable import ForgeKit
import Foundation
import XCTest

final class ForgeCapabilityTests: XCTestCase {
    func testMilestone3EnvelopeIsExactAndDoesNotContainNotificationsPermission() throws {
        let levels = Dictionary(uniqueKeysWithValues: ForgePermissionEnvelope.milestone3.grants.map {
            ($0.permission, $0.authority)
        })
        XCTAssertEqual(Set(levels.keys), Set(ForgeRepositoryPermission.allCases))
        XCTAssertEqual(levels[.metadata], .known(.read))
        XCTAssertEqual(levels[.contents], .known(.write))
        XCTAssertEqual(levels[.pullRequests], .known(.write))
        XCTAssertEqual(levels[.issues], .known(.write))
        XCTAssertEqual(levels[.checks], .known(.read))
        XCTAssertEqual(levels[.commitStatuses], .known(.read))
        XCTAssertFalse(String(describing: ForgePermissionEnvelope.milestone3).localizedCaseInsensitiveContains("notification"))
        XCTAssertEqual(
            try JSONDecoder().decode(
                ForgePermissionEnvelope.self,
                from: JSONEncoder().encode(ForgePermissionEnvelope.milestone3)
            ),
            ForgePermissionEnvelope.milestone3
        )
    }

    func testPermissionContainersRejectDuplicateEvidenceAndTreatMissingAsUnknown() throws {
        let context = try makeContext()
        let duplicate = [
            ForgePermissionGrant(permission: .metadata, authority: .known(.read)),
            ForgePermissionGrant(permission: .metadata, authority: .unknown),
        ]
        XCTAssertThrowsError(try ForgePermissionEnvelope(grants: duplicate)) {
            XCTAssertEqual($0 as? ForgeCapabilityModelError, .duplicatePermission(.metadata))
        }
        struct UnvalidatedEnvelope: Encodable { let grants: [ForgePermissionGrant] }
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ForgePermissionEnvelope.self,
                from: JSONEncoder().encode(UnvalidatedEnvelope(grants: duplicate))
            )
        ) {
            XCTAssertEqual($0 as? ForgeCapabilityModelError, .duplicatePermission(.metadata))
        }
        XCTAssertThrowsError(
            try ForgePermissionEvidence(
                credential: context.credential,
                repository: context.repository,
                freshness: .current,
                grants: duplicate
            )
        ) {
            XCTAssertEqual($0 as? ForgeCapabilityModelError, .duplicatePermission(.metadata))
        }

        let evidence = try ForgePermissionEvidence(
            credential: context.credential,
            repository: context.repository,
            freshness: .current,
            grants: [.init(permission: .metadata, authority: .known(.read))]
        )
        XCTAssertEqual(evidence.authority(for: .metadata), .known(.read))
        XCTAssertEqual(evidence.authority(for: .contents), .unknown)
        XCTAssertNotNil(ForgeCapabilityModelError.duplicatePermission(.issues).errorDescription)
    }

    func testEveryOperationHasTheAcceptedPermissionAndRoleContract() {
        let readOperations: Set<ForgeOperation> = [
            .readRepositoryMetadata, .listCloneRepositories, .readRepositoryContents,
            .readPullRequests, .readIssues, .readChecks, .readCommitStatuses,
        ]
        XCTAssertEqual(Set(ForgeOperation.allCases.filter { !$0.isWrite }), readOperations)
        XCTAssertEqual(Set(ForgeOperation.allCases.filter(\.isWrite)).count, 19)
        XCTAssertEqual(
            ForgeOperation.allCases.filter { $0.rawValue.localizedCaseInsensitiveContains("issue") },
            [.readIssues]
        )

        XCTAssertEqual(requirements(.readRepositoryMetadata), [.metadata: .read])
        XCTAssertEqual(requirements(.listCloneRepositories), [.metadata: .read])
        XCTAssertEqual(requirements(.readRepositoryContents), [.contents: .read])
        XCTAssertEqual(requirements(.readPullRequests), [.pullRequests: .read])
        XCTAssertEqual(requirements(.readIssues), [.issues: .read])
        XCTAssertEqual(requirements(.readChecks), [.checks: .read])
        XCTAssertEqual(requirements(.readCommitStatuses), [.commitStatuses: .read])
        XCTAssertEqual(requirements(.syncFork), [.contents: .write])
        XCTAssertEqual(requirements(.deleteHeadBranch), [.contents: .write])
        XCTAssertEqual(requirements(.updatePullRequestBranch), [.contents: .write, .pullRequests: .write])
        XCTAssertEqual(requirements(.mergePullRequest), [.contents: .write, .pullRequests: .write])

        let pullRequestWrites = ForgeOperation.allCases.filter {
            $0.isWrite && ![.syncFork, .deleteHeadBranch, .updatePullRequestBranch, .mergePullRequest].contains($0)
        }
        XCTAssertTrue(pullRequestWrites.allSatisfy { requirements($0) == [.pullRequests: .write] })
        XCTAssertEqual(
            Set(ForgeOperation.allCases.filter { $0.minimumRole == .write }),
            [.syncFork, .updatePullRequestBranch, .mergePullRequest, .deleteHeadBranch, .enterMergeQueue, .leaveMergeQueue]
        )
    }

    func testKnownSufficientEvidenceVerifiesReadsAndWrites() throws {
        let context = try makeContext()
        XCTAssertEqual(
            try capability(context: context, operation: .readPullRequests),
            .verified(.knownAuthority)
        )
        XCTAssertEqual(
            try capability(context: context, operation: .createPullRequest),
            .verified(.knownAuthority)
        )
        XCTAssertEqual(
            try capability(context: context, operation: .mergePullRequest, role: .known(.write)),
            .verified(.knownAuthority)
        )
    }

    func testStaleOrCachedEvidenceCanSupportReadsButNeverAuthorizesWrites() throws {
        let context = try makeContext(source: .fineGrainedPersonalAccessToken)
        XCTAssertEqual(
            try capability(
                context: context,
                operation: .readPullRequests,
                permissionFreshness: .stale,
                accessFreshness: .cached
            ),
            .verified(.knownAuthority)
        )
        XCTAssertEqual(
            try capability(
                context: context,
                operation: .createPullRequest,
                permissionFreshness: .stale
            ),
            .unavailable(.authorizationEvidenceNotCurrent)
        )

        var promotions = ForgeCapabilityPromotionLedger()
        try promotions.record(.success, for: unverifiedConfirmation(context, .createPullRequest))
        let staleUnknown = try evidence(
            context,
            permission: .pullRequests,
            authority: .unknown,
            freshness: .stale
        )
        XCTAssertEqual(
            try capability(
                context: context,
                operation: .createPullRequest,
                permissionEvidence: staleUnknown,
                promotions: promotions
            ),
            .unavailable(.authorizationEvidenceNotCurrent)
        )
    }

    func testCredentialAvailabilityAndExpiryAreMandatoryAndDeterministic() throws {
        let expiring = try makeContext(expiresAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(
            try capability(
                context: expiring,
                operation: .createPullRequest,
                now: Date(timeIntervalSince1970: 99.999)
            ),
            .verified(.knownAuthority)
        )
        XCTAssertEqual(
            try capability(
                context: expiring,
                operation: .createPullRequest,
                now: Date(timeIntervalSince1970: 100)
            ),
            .unavailable(.credentialExpired)
        )
        XCTAssertEqual(
            try capability(
                context: expiring,
                operation: .readRepositoryMetadata,
                credentialAvailability: .unavailable,
                now: Date(timeIntervalSince1970: 50)
            ),
            .unavailable(.credentialUnavailable)
        )
    }

    func testMergeQueueRequiresWriteRole() throws {
        let context = try makeContext()
        for operation in [ForgeOperation.enterMergeQueue, .leaveMergeQueue] {
            XCTAssertEqual(
                try capability(context: context, operation: operation, role: .known(.read)),
                .unavailable(.inadequateRepositoryRole(required: .write, actual: .read))
            )
        }
    }

    func testKnownInsufficiencyOverridesUnverifiedWriteAndStoredPromotion() throws {
        let context = try makeContext(source: .fineGrainedPersonalAccessToken)
        let operation: ForgeOperation = .createPullRequest
        var promotions = ForgeCapabilityPromotionLedger()
        try promotions.record(.success, for: unverifiedConfirmation(context, operation))
        let missing = try evidence(
            context,
            permission: .pullRequests,
            authority: .known(.read)
        )

        XCTAssertEqual(
            try capability(
                context: context,
                operation: operation,
                permissionEvidence: missing,
                promotions: promotions
            ),
            .unavailable(.missingPermission(.pullRequests))
        )
        XCTAssertEqual(
            try capability(context: context, operation: operation, accessStatus: .denied, promotions: promotions),
            .unavailable(.repositoryAccessDenied)
        )
        XCTAssertEqual(
            try capability(context: context, operation: operation, role: .known(.none), promotions: promotions),
            .unavailable(.inadequateRepositoryRole(required: .read, actual: .none))
        )
        XCTAssertEqual(
            try capability(context: context, operation: operation, restrictedOperations: [operation], promotions: promotions),
            .unavailable(.knownOperationRestriction)
        )
    }

    func testAccessRecoveryReasonsRemainDistinct() throws {
        let context = try makeContext()
        XCTAssertEqual(
            try capability(context: context, operation: .readIssues, accessStatus: .samlAuthorizationRequired),
            .unavailable(.samlAuthorizationRequired)
        )
        XCTAssertEqual(
            try capability(context: context, operation: .readIssues, accessStatus: .installationConfigurationRequired),
            .unavailable(.installationConfigurationRequired)
        )
    }

    func testOnlyFineGrainedUnknownWritesBecomeUnverified() throws {
        let fineGrained = try makeContext(source: .fineGrainedPersonalAccessToken)
        let classic = try makeContext(source: .classicPersonalAccessToken)
        let unknownFineGrained = try evidence(fineGrained, permission: .pullRequests, authority: .unknown)
        let unknownClassic = try evidence(classic, permission: .pullRequests, authority: .unknown)

        XCTAssertEqual(
            try capability(context: fineGrained, operation: .createPullRequest, permissionEvidence: unknownFineGrained),
            .unverifiedWrite(ForgeUnverifiedWriteAttempt(key: key(fineGrained, .createPullRequest)))
        )
        XCTAssertEqual(
            try capability(context: classic, operation: .createPullRequest, permissionEvidence: unknownClassic),
            .unavailable(.authorizationEvidenceUnavailable)
        )
        XCTAssertEqual(
            try capability(context: fineGrained, operation: .readPullRequests, permissionEvidence: unknownFineGrained),
            .unavailable(.authorizationEvidenceUnavailable)
        )
    }

    func testPromotionIsExactToCredentialGenerationRepositoryAndOperation() throws {
        let context = try makeContext(source: .fineGrainedPersonalAccessToken)
        let unknown = try evidence(context, permission: .pullRequests, authority: .unknown)
        var promotions = ForgeCapabilityPromotionLedger()
        try promotions.record(.success, for: unverifiedConfirmation(context, .createPullRequest))

        XCTAssertEqual(
            try capability(context: context, operation: .createPullRequest, permissionEvidence: unknown, promotions: promotions),
            .verified(.successfulConfirmedOperation)
        )
        XCTAssertEqual(
            try capability(context: context, operation: .editPullRequest, permissionEvidence: unknown, promotions: promotions),
            .unverifiedWrite(ForgeUnverifiedWriteAttempt(key: key(context, .editPullRequest)))
        )

        let otherRepository = try TestSupport.repository(owner: "other", name: "widgets")
        let otherPermission = try ForgePermissionEvidence(
            credential: context.credential,
            repository: otherRepository,
            freshness: .current,
            grants: [.init(permission: .pullRequests, authority: .unknown)]
        )
        let otherAccess = ForgeRepositoryAccessEvidence(
            credential: context.credential,
            repository: otherRepository,
            freshness: .current,
            status: .unknown,
            role: .unknown
        )
        XCTAssertEqual(
            ForgeCapabilityEvaluator.capability(
                account: context.account,
                repository: otherRepository,
                operation: .createPullRequest,
                operationSupported: true,
                credentialAvailability: .available,
                now: Date(timeIntervalSince1970: 100),
                permissionEvidence: otherPermission,
                accessEvidence: otherAccess,
                promotions: promotions
            ),
            .unverifiedWrite(
                ForgeUnverifiedWriteAttempt(
                    key: ForgeCapabilityKey(
                        credential: context.credential,
                        repository: otherRepository,
                        operation: .createPullRequest
                    )
                )
            )
        )

        let replacement = try makeContext(source: .fineGrainedPersonalAccessToken, generation: 2)
        let replacementUnknown = try evidence(replacement, permission: .pullRequests, authority: .unknown)
        XCTAssertEqual(
            try capability(
                context: replacement,
                operation: .createPullRequest,
                permissionEvidence: replacementUnknown,
                promotions: promotions
            ),
            .unverifiedWrite(ForgeUnverifiedWriteAttempt(key: key(replacement, .createPullRequest)))
        )
    }

    func testPromotionOutcomeAndInvalidationTransitions() throws {
        let context = try makeContext(source: .fineGrainedPersonalAccessToken)
        let key = ForgeCapabilityKey(
            credential: context.credential,
            repository: context.repository,
            operation: .mergePullRequest
        )
        let confirmation = try unverifiedConfirmation(context, .mergePullRequest)
        var ledger = ForgeCapabilityPromotionLedger()
        for outcome in [
            ForgeCapabilityAttemptOutcome.nonAuthorizationFailure,
            .cancelled,
            .unknownOutcome,
        ] {
            ledger.record(outcome, for: confirmation)
            XCTAssertFalse(ledger.contains(key))
        }
        ledger.record(.success, for: confirmation)
        XCTAssertTrue(ledger.contains(key))
        ledger.record(.nonAuthorizationFailure, for: confirmation)
        XCTAssertTrue(ledger.contains(key))
        ledger.record(.authorizationDenied, for: confirmation)
        XCTAssertFalse(ledger.contains(key))

        ledger.record(.success, for: confirmation)
        ledger.recordAuthoritativeDenial(for: key)
        XCTAssertFalse(ledger.contains(key))
        ledger.record(.success, for: confirmation)
        ledger.invalidate(credential: context.credential)
        XCTAssertFalse(ledger.contains(key))
    }

    func testRetainingCurrentCredentialInvalidatesOnlyReplacedAccountGeneration() throws {
        let old = try makeContext(source: .fineGrainedPersonalAccessToken, generation: 1)
        let replacement = try makeContext(source: .fineGrainedPersonalAccessToken, generation: 2)
        let other = try makeContext(
            source: .fineGrainedPersonalAccessToken,
            accountValue: "other",
            credentialValue: "other-credential"
        )
        let oldKey = key(old, .createPullRequest)
        let replacementKey = key(replacement, .createPullRequest)
        let otherKey = key(other, .createPullRequest)
        var ledger = ForgeCapabilityPromotionLedger()
        try ledger.record(.success, for: unverifiedConfirmation(old, .createPullRequest))
        try ledger.record(.success, for: unverifiedConfirmation(replacement, .createPullRequest))
        try ledger.record(.success, for: unverifiedConfirmation(other, .createPullRequest))

        ledger.retainOnlyCurrentCredential(for: replacement.account)
        XCTAssertFalse(ledger.contains(oldKey))
        XCTAssertTrue(ledger.contains(replacementKey))
        XCTAssertTrue(ledger.contains(otherKey))
    }

    func testIdentityAndEvidenceBoundariesCannotCross() throws {
        let context = try makeContext()
        let otherAccount = try makeContext(accountValue: "other", credentialValue: "other-credential")
        let otherRepository = try TestSupport.repository(owner: "other")
        let gitLabRepository = try TestSupport.repository(kind: .gitLab)

        XCTAssertEqual(
            try ForgeCapabilityEvaluator.capability(
                account: nil,
                repository: context.repository,
                operation: .readRepositoryMetadata,
                operationSupported: true,
                credentialAvailability: .available,
                now: Date(timeIntervalSince1970: 100),
                permissionEvidence: fullEvidence(context),
                accessEvidence: access(context),
                promotions: .init()
            ),
            .unavailable(.noCurrentCredential)
        )
        XCTAssertEqual(
            try ForgeCapabilityEvaluator.capability(
                account: context.account,
                repository: gitLabRepository,
                operation: .readRepositoryMetadata,
                operationSupported: true,
                credentialAvailability: .available,
                now: Date(timeIntervalSince1970: 100),
                permissionEvidence: fullEvidence(context),
                accessEvidence: access(context),
                promotions: .init()
            ),
            .unavailable(.mismatchedForge)
        )
        XCTAssertEqual(
            try ForgeCapabilityEvaluator.capability(
                account: context.account,
                repository: context.repository,
                operation: .readRepositoryMetadata,
                operationSupported: true,
                credentialAvailability: .available,
                now: Date(timeIntervalSince1970: 100),
                permissionEvidence: fullEvidence(otherAccount),
                accessEvidence: access(context),
                promotions: .init()
            ),
            .unavailable(.mismatchedCredentialEvidence)
        )
        let otherRepositoryEvidence = try ForgePermissionEvidence(
            credential: context.credential,
            repository: otherRepository,
            freshness: .current,
            grants: ForgePermissionEnvelope.milestone3.grants
        )
        XCTAssertEqual(
            ForgeCapabilityEvaluator.capability(
                account: context.account,
                repository: context.repository,
                operation: .readRepositoryMetadata,
                operationSupported: true,
                credentialAvailability: .available,
                now: Date(timeIntervalSince1970: 100),
                permissionEvidence: otherRepositoryEvidence,
                accessEvidence: access(context),
                promotions: .init()
            ),
            .unavailable(.mismatchedRepositoryEvidence)
        )
    }

    func testUnknownAccessOrRoleRequiresPromotionOrFineGrainedUnknownWrite() throws {
        let context = try makeContext()
        XCTAssertEqual(
            try capability(context: context, operation: .readRepositoryMetadata, accessStatus: .unknown),
            .unavailable(.authorizationEvidenceUnavailable)
        )
        XCTAssertEqual(
            try capability(context: context, operation: .readRepositoryMetadata, role: .unknown),
            .unavailable(.authorizationEvidenceUnavailable)
        )
    }

    func testAdapterSupportMustExplicitlyPermitAnOperation() throws {
        let context = try makeContext()
        XCTAssertEqual(
            try capability(
                context: context,
                operation: .readRepositoryMetadata,
                operationSupported: false
            ),
            .unavailable(.unsupportedProviderOperation)
        )
    }

    private struct Context {
        let account: ForgeAccount
        let repository: ForgeRepositoryIdentity

        var credential: ForgeCredentialReference {
            account.currentCredential.reference
        }
    }

    private func makeContext(
        source: ForgeCredentialSource = .forgeApplicationDeviceFlow,
        generation: UInt64 = 1,
        accountValue: String = "account",
        credentialValue: String = "credential",
        expiresAt: Date? = nil
    ) throws -> Context {
        let repository = try TestSupport.repository()
        let accountID = try ForgeAccountID(forge: repository.forge, value: accountValue)
        let reference = try ForgeCredentialReference(
            accountID: accountID,
            credentialID: ForgeCredentialID(credentialValue),
            generation: ForgeCredentialGeneration(generation)
        )
        let credential = ForgeCredentialMetadata(reference: reference, source: source, expiresAt: expiresAt)
        return try Context(
            account: ForgeAccount(id: accountID, login: "octocat", currentCredential: credential),
            repository: repository
        )
    }

    private func requirements(_ operation: ForgeOperation) -> [ForgeRepositoryPermission: ForgePermissionLevel] {
        Dictionary(uniqueKeysWithValues: operation.permissionRequirements.map { ($0.permission, $0.level) })
    }

    private func key(_ context: Context, _ operation: ForgeOperation) -> ForgeCapabilityKey {
        ForgeCapabilityKey(
            credential: context.credential,
            repository: context.repository,
            operation: operation
        )
    }

    private func fullEvidence(
        _ context: Context,
        freshness: ForgeAuthorizationEvidenceFreshness = .current
    ) throws -> ForgePermissionEvidence {
        try ForgePermissionEvidence(
            credential: context.credential,
            repository: context.repository,
            freshness: freshness,
            grants: ForgePermissionEnvelope.milestone3.grants
        )
    }

    private func evidence(
        _ context: Context,
        permission: ForgeRepositoryPermission,
        authority: ForgePermissionAuthority,
        freshness: ForgeAuthorizationEvidenceFreshness = .current
    ) throws -> ForgePermissionEvidence {
        try ForgePermissionEvidence(
            credential: context.credential,
            repository: context.repository,
            freshness: freshness,
            grants: [ForgePermissionGrant(permission: permission, authority: authority)]
        )
    }

    private func access(
        _ context: Context,
        freshness: ForgeAuthorizationEvidenceFreshness = .current,
        status: ForgeRepositoryAccessStatus = .granted,
        role: ForgeRepositoryRoleEvidence = .known(.admin),
        restrictedOperations: Set<ForgeOperation> = []
    ) -> ForgeRepositoryAccessEvidence {
        ForgeRepositoryAccessEvidence(
            credential: context.credential,
            repository: context.repository,
            freshness: freshness,
            status: status,
            role: role,
            restrictedOperations: restrictedOperations
        )
    }

    private func capability(
        context: Context,
        operation: ForgeOperation,
        operationSupported: Bool = true,
        credentialAvailability: ForgeCredentialAvailability = .available,
        now: Date = Date(timeIntervalSince1970: 100),
        permissionFreshness: ForgeAuthorizationEvidenceFreshness = .current,
        accessFreshness: ForgeAuthorizationEvidenceFreshness = .current,
        permissionEvidence: ForgePermissionEvidence? = nil,
        accessStatus: ForgeRepositoryAccessStatus = .granted,
        role: ForgeRepositoryRoleEvidence = .known(.admin),
        restrictedOperations: Set<ForgeOperation> = [],
        promotions: ForgeCapabilityPromotionLedger = .init()
    ) throws -> ForgeOperationCapability {
        try ForgeCapabilityEvaluator.capability(
            account: context.account,
            repository: context.repository,
            operation: operation,
            operationSupported: operationSupported,
            credentialAvailability: credentialAvailability,
            now: now,
            permissionEvidence: permissionEvidence ?? fullEvidence(context, freshness: permissionFreshness),
            accessEvidence: access(
                context,
                freshness: accessFreshness,
                status: accessStatus,
                role: role,
                restrictedOperations: restrictedOperations
            ),
            promotions: promotions
        )
    }

    private func unverifiedConfirmation(
        _ context: Context,
        _ operation: ForgeOperation
    ) throws -> ForgeExplicitCapabilityConfirmation {
        let grants = operation.permissionRequirements.map {
            ForgePermissionGrant(permission: $0.permission, authority: .unknown)
        }
        let permissionEvidence = try ForgePermissionEvidence(
            credential: context.credential,
            repository: context.repository,
            freshness: .current,
            grants: grants
        )
        let evaluated = try capability(
            context: context,
            operation: operation,
            permissionEvidence: permissionEvidence
        )
        let attempt: ForgeUnverifiedWriteAttempt? = if case let .unverifiedWrite(value) = evaluated {
            value
        } else {
            nil
        }
        return try ForgeExplicitCapabilityConfirmation(
            attempt: XCTUnwrap(attempt, "Expected an evaluator-issued Unverified Write attempt, got \(evaluated)")
        )
    }
}
