import ForgeKit
import Foundation
import GitHubForgeAdapter
import Network
import OSLog // swiftlint:disable:this unused_import

nonisolated enum ForgeGitHubPullRequestCompositionError: Error, Equatable, LocalizedError, Sendable {
    case exactAccountRequired
    case accountMismatch
    case currentCredentialRequired
    case authorizationEvidenceUnavailable
    case capabilityUnavailable(ForgeOperation)
    case explicitConfirmationRequired(ForgeOperation)
    case offline
    case rateLimited(until: Date)
    case authoritative(String)
    case outcomeUnknown
    case malformedCloneCatalog

    var errorDescription: String? {
        switch self {
        case .exactAccountRequired:
            "Choose and save the exact GitHub account for this repository first."
        case .accountMismatch:
            "The requested GitHub account does not match this repository binding."
        case .currentCredentialRequired:
            "The selected GitHub account no longer has a current Credential."
        case .authorizationEvidenceUnavailable:
            "GitX could not obtain current authorization evidence for this repository."
        case let .capabilityUnavailable(operation):
            "The current Credential cannot perform \(operation.rawValue)."
        case let .explicitConfirmationRequired(operation):
            "The current Credential requires explicit confirmation before \(operation.rawValue)."
        case .offline:
            "GitHub mutations are unavailable while offline."
        case let .rateLimited(until):
            "GitHub mutations are paused for this Credential until \(until)."
        case let .authoritative(message):
            message
        case .outcomeUnknown:
            "The GitHub mutation outcome remains unknown after authoritative reconciliation."
        case .malformedCloneCatalog:
            "GitHub returned an invalid repository clone catalog."
        }
    }
}

/// Per-Credential transient state is shared by every repository window. A
/// rate-limit response from one window therefore gates the same Credential in
/// every other window without crossing account boundaries.
actor ForgeGitHubMutationStateStore {
    let sessionGate: GitHubMutationSessionGate
    private var promotions = ForgeCapabilityPromotionLedger()

    init(sessionGate: GitHubMutationSessionGate = GitHubMutationSessionGate()) {
        self.sessionGate = sessionGate
    }

    func environment(for credential: ForgeCredentialReference, now: Date) async -> ForgeMutationEnvironment {
        await sessionGate.environment(for: credential, at: now)
    }

    func promotionLedger(for account: ForgeAccount) -> ForgeCapabilityPromotionLedger {
        promotions.retainOnlyCurrentCredential(for: account)
        return promotions
    }

    func recordAuthoritativeDenial(for key: ForgeCapabilityKey) {
        promotions.recordAuthoritativeDenial(for: key)
    }

    func recordSuccess(
        response: GitHubResponseMetadata,
        credential: ForgeCredentialReference,
        confirmation: ForgeExplicitCapabilityConfirmation?,
        now: Date
    ) async {
        await record(response: response, credential: credential, now: now)
        if let confirmation {
            promotions.record(.success, for: confirmation)
        }
    }

    func recordFailure(
        _ error: GitHubMutationError,
        credential: ForgeCredentialReference,
        authorization: GitHubMutationAuthorization,
        now: Date
    ) async {
        switch error {
        case let .rateLimited(response),
             let .samlAuthorizationRequired(response),
             let .permissionDenied(response),
             let .authoritative(_, response):
            await record(response: response, credential: credential, now: now)
        case let .outcomeUnknown(response):
            if let response {
                await record(response: response, credential: credential, now: now)
            }
        default:
            break
        }
        guard let confirmation = authorization.explicitConfirmation else { return }
        switch error {
        case .permissionDenied, .samlAuthorizationRequired, .capabilityUnavailable:
            promotions.record(.authorizationDenied, for: confirmation)
        case .outcomeUnknown:
            promotions.record(.unknownOutcome, for: confirmation)
        default:
            promotions.record(.nonAuthorizationFailure, for: confirmation)
        }
    }

    func record(
        response: GitHubResponseMetadata,
        credential: ForgeCredentialReference,
        now: Date
    ) async {
        let cooldown = response.rateLimit.credentialCooldown(
            statusCode: response.statusCode,
            credential: credential,
            now: now
        )
        await sessionGate.recordCooldown(for: credential, until: cooldown?.deadline)
    }
}

/// Feeds the provider-owned session gate from Network.framework. The adapter
/// still classifies transport failures authoritatively, while this monitor
/// prevents a mutation from starting once the system reports an offline path.
// swift6-safety-justification: NWPathMonitor callbacks mutate only the Sendable actor gate; lifecycle is confined to this immutable owner.
final nonisolated class ForgeGitHubMutationNetworkMonitor: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.gitx.gitx.github-mutation-network")

    init(sessionGate: GitHubMutationSessionGate, monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { path in
            Task { await sessionGate.setOffline(path.status != .satisfied) }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

nonisolated struct ForgeGitHubPullRequestPreparationContext: Sendable {
    let account: ForgeAccount
    let facts: ForgeRepositoryFacts
}

/// Narrow adapter boundaries keep the production service independently
/// verifiable while the concrete GitHub adapters remain the shipping defaults.
nonisolated protocol ForgeGitHubPullRequestReading: Sendable {
    func pullRequests(
        repository: ForgeRepositoryIdentity,
        pageSize: Int,
        after: ForgePageCursor?,
        states: Set<ForgePullRequestState>?
    ) async throws -> GitHubReadResult<ForgePage<ForgePullRequestSummary>>

    func pullRequestDetails(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        timelinePageSize: Int,
        timelineAfter: ForgePageCursor?,
        checkPageSize: Int,
        checkAfter: ForgePageCursor?
    ) async throws -> GitHubReadResult<ForgePullRequestDetailsPage>
}

extension GitHubReadAdapter: ForgeGitHubPullRequestReading {}

nonisolated protocol ForgeGitHubPullRequestMutationExecuting: Sendable {
    func createPullRequest(
        accountID: ForgeAccountID,
        form: ForgePullRequestCreationForm,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubPullRequestCreationOutcome>

    func editPullRequest(
        accountID: ForgeAccountID,
        edit: ForgePullRequestEdit,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubPullRequestMutationValue>

    func syncFork(
        accountID: ForgeAccountID,
        plan: ForgeSyncForkPlan,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubForkSyncReceipt>
}

extension GitHubMutationAdapter: ForgeGitHubPullRequestMutationExecuting {}

nonisolated struct ForgeGitHubPullRequestMutationContext: Sendable {
    let account: ForgeAccount
    let credential: ForgeCredentialReference
    let authorization: GitHubMutationAuthorization
    let readAdapter: any ForgeGitHubPullRequestReading
    let mutationAdapter: any ForgeGitHubPullRequestMutationExecuting
}

nonisolated protocol ForgeGitHubPullRequestDependencyProviding: Sendable {
    func preparationContext(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity
    ) async throws -> ForgeGitHubPullRequestPreparationContext

    func operationCapabilities(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operations: Set<ForgeOperation>
    ) async throws -> [ForgeOperation: ForgeOperationCapability]

    func mutationContext(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) async throws -> ForgeGitHubPullRequestMutationContext

    func recordSuccess(
        _ result: GitHubResponseMetadata,
        context: ForgeGitHubPullRequestMutationContext
    ) async

    func recordFailure(
        _ error: GitHubMutationError,
        context: ForgeGitHubPullRequestMutationContext
    ) async
}

/// Resolves every operation from the current Keychain account, a fresh
/// repository-facts response, and the exact Credential-bound adapters. Cached
/// Forge models are deliberately unable to produce a mutation authorization.
final nonisolated class ForgeGitHubPullRequestDependencyProvider:
    ForgeGitHubPullRequestDependencyProviding, Sendable
{
    private let loader: ForgeApplicationServiceLoader
    private let now: @Sendable () -> Date
    private let sessionConfiguration: @Sendable () -> URLSessionConfiguration
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "GitHubPullRequestComposition")

    init(
        loader: ForgeApplicationServiceLoader,
        now: @escaping @Sendable () -> Date = { Date() },
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
    ) {
        self.loader = loader
        self.now = now
        self.sessionConfiguration = sessionConfiguration
    }

    func preparationContext(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity
    ) async throws -> ForgeGitHubPullRequestPreparationContext {
        let resolved = try await resolve(accountID: accountID, repository: repository)
        return ForgeGitHubPullRequestPreparationContext(account: resolved.account, facts: resolved.facts)
    }

    func operationCapabilities(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operations: Set<ForgeOperation>
    ) async throws -> [ForgeOperation: ForgeOperationCapability] {
        try await evaluateOperationCapabilities(
            accountID: accountID,
            repository: repository,
            operations: operations
        ).capabilities
    }

    func mutationContext(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) async throws -> ForgeGitHubPullRequestMutationContext {
        let evaluation = try await evaluateOperationCapabilities(
            accountID: accountID,
            repository: repository,
            operations: [operation]
        )
        guard let capability = evaluation.capabilities[operation] else {
            throw ForgeGitHubPullRequestCompositionError.capabilityUnavailable(operation)
        }
        let key = ForgeCapabilityKey(
            credential: evaluation.resolution.account.currentCredential.reference,
            repository: repository,
            operation: operation
        )
        let authorization = try Self.authorization(
            key: key,
            capability: capability,
            operationWasConfirmed: true
        )
        logger.debug("Authorized exact-account GitHub mutation operation=\(operation.rawValue, privacy: .public)")
        return try ForgeGitHubPullRequestMutationContext(
            account: evaluation.resolution.account,
            credential: evaluation.resolution.account.currentCredential.reference,
            authorization: authorization,
            readAdapter: evaluation.resolution.readAdapter,
            mutationAdapter: evaluation.services.githubReadAdapterFactory.makeMutationAdapter(
                for: evaluation.resolution.account.currentCredential.reference,
                sessionGate: evaluation.services.githubMutationState.sessionGate
            )
        )
    }

    private func evaluateOperationCapabilities(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operations: Set<ForgeOperation>
    ) async throws -> CapabilityEvaluation {
        let services = try await loader.services()
        guard let currentEnvelope = try await services.accountStore.credential(for: accountID),
              currentEnvelope.account.id == accountID,
              currentEnvelope.account.id.forge == repository.forge
        else {
            throw ForgeGitHubPullRequestCompositionError.currentCredentialRequired
        }
        switch await services.githubMutationState.environment(
            for: currentEnvelope.account.currentCredential.reference,
            now: now()
        ) {
        case .available:
            break
        case .offline:
            throw ForgeGitHubPullRequestCompositionError.offline
        case let .rateLimited(until):
            throw ForgeGitHubPullRequestCompositionError.rateLimited(until: until)
        }
        let resolved = try await resolve(
            services: services,
            accountID: accountID,
            repository: repository
        )
        guard resolved.account.currentCredential.reference == currentEnvelope.account.currentCredential.reference else {
            throw ForgeGitHubPullRequestCompositionError.currentCredentialRequired
        }
        switch await services.githubMutationState.environment(for: resolved.account.currentCredential.reference, now: now()) {
        case .available:
            break
        case .offline:
            throw ForgeGitHubPullRequestCompositionError.offline
        case let .rateLimited(until):
            throw ForgeGitHubPullRequestCompositionError.rateLimited(until: until)
        }
        let permissionResolution = try await permissionEvidence(
            services: services,
            account: resolved.account,
            repository: repository,
            facts: resolved.facts,
            storedEvidence: resolved.authorizationEvidence
        )
        guard let accessEvidence = resolved.result.accessEvidence else {
            throw ForgeGitHubPullRequestCompositionError.authorizationEvidenceUnavailable
        }
        let evaluationDate = now()
        let promotions = await services.githubMutationState.promotionLedger(for: resolved.account)
        guard let currentEnvelope = try await services.accountStore.credential(for: accountID),
              currentEnvelope.account.id == resolved.account.id,
              currentEnvelope.account.currentCredential.reference == resolved.account.currentCredential.reference,
              currentEnvelope.authorizationEvidence == permissionResolution.storedEvidence
        else {
            logger.notice("Rejected GitHub capability result because its exact Credential or evidence is no longer current")
            throw ForgeGitHubPullRequestCompositionError.currentCredentialRequired
        }
        let currentResolution = Resolution(
            account: currentEnvelope.account,
            facts: resolved.facts,
            result: resolved.result,
            readAdapter: resolved.readAdapter,
            authorizationEvidence: currentEnvelope.authorizationEvidence
        )
        let capabilities = Dictionary(uniqueKeysWithValues: operations.map { operation in
            (
                operation,
                ForgeCapabilityEvaluator.capability(
                    account: currentEnvelope.account,
                    repository: repository,
                    operation: operation,
                    operationSupported: true,
                    credentialAvailability: .available,
                    now: evaluationDate,
                    permissionEvidence: permissionResolution.evidence,
                    accessEvidence: accessEvidence,
                    promotions: promotions
                )
            )
        })
        logger.debug("Evaluated fresh exact-account GitHub capabilities count=\(capabilities.count, privacy: .public)")
        return CapabilityEvaluation(
            services: services,
            resolution: currentResolution,
            capabilities: capabilities
        )
    }

    func recordSuccess(
        _ result: GitHubResponseMetadata,
        context: ForgeGitHubPullRequestMutationContext
    ) async {
        guard let services = try? await loader.services() else { return }
        await services.githubMutationState.recordSuccess(
            response: result,
            credential: context.credential,
            confirmation: context.authorization.explicitConfirmation,
            now: now()
        )
    }

    func recordFailure(
        _ error: GitHubMutationError,
        context: ForgeGitHubPullRequestMutationContext
    ) async {
        guard let services = try? await loader.services() else { return }
        await services.githubMutationState.recordFailure(
            error,
            credential: context.credential,
            authorization: context.authorization,
            now: now()
        )
        switch error {
        case .permissionDenied, .samlAuthorizationRequired, .capabilityUnavailable:
            try? await services.accountStore.clearAuthorizationEvidence(for: context.credential)
            await services.githubMutationState.recordAuthoritativeDenial(
                for: context.authorization.key
            )
        default:
            break
        }
    }

    private struct Resolution {
        let account: ForgeAccount
        let facts: ForgeRepositoryFacts
        let result: GitHubReadResult<ForgeRepositoryFacts>
        let readAdapter: GitHubReadAdapter
        let authorizationEvidence: ForgeStoredCredentialAuthorizationEvidence?
    }

    private struct CapabilityEvaluation {
        let services: ForgeApplicationServices
        let resolution: Resolution
        let capabilities: [ForgeOperation: ForgeOperationCapability]
    }

    private struct PermissionResolution {
        let evidence: ForgePermissionEvidence
        let storedEvidence: ForgeStoredCredentialAuthorizationEvidence
    }

    private func resolve(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity
    ) async throws -> Resolution {
        let services = try await loader.services()
        return try await resolve(
            services: services,
            accountID: accountID,
            repository: repository
        )
    }

    private func resolve(
        services: ForgeApplicationServices,
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity
    ) async throws -> Resolution {
        guard accountID.forge == repository.forge else {
            throw ForgeGitHubPullRequestCompositionError.accountMismatch
        }
        guard let envelope = try await services.accountStore.credential(for: accountID) else {
            throw ForgeGitHubPullRequestCompositionError.currentCredentialRequired
        }
        let account = envelope.account
        guard account.id == accountID,
              account.currentCredential.reference.accountID == accountID
        else {
            throw ForgeGitHubPullRequestCompositionError.accountMismatch
        }
        let adapter = try services.githubReadAdapterFactory.makeAdapter(
            for: account.currentCredential.reference,
            sessionConfiguration: sessionConfiguration()
        )
        let result = try await adapter.repositoryFacts(repository: repository)
        guard result.ownership.credential == account.currentCredential.reference,
              result.ownership.repository == repository,
              result.value.repository == repository
        else {
            throw ForgeGitHubPullRequestCompositionError.authorizationEvidenceUnavailable
        }
        await services.githubMutationState.record(
            response: result.response,
            credential: account.currentCredential.reference,
            now: now()
        )
        guard let currentEnvelope = try await services.accountStore.credential(for: accountID),
              currentEnvelope.account.id == account.id,
              currentEnvelope.account.currentCredential.reference == account.currentCredential.reference
        else {
            logger.notice("Rejected GitHub repository facts because their exact Credential is no longer current")
            throw ForgeGitHubPullRequestCompositionError.currentCredentialRequired
        }
        return Resolution(
            account: currentEnvelope.account,
            facts: result.value,
            result: result,
            readAdapter: adapter,
            authorizationEvidence: currentEnvelope.authorizationEvidence
        )
    }

    private func permissionEvidence(
        services: ForgeApplicationServices,
        account: ForgeAccount,
        repository: ForgeRepositoryIdentity,
        facts: ForgeRepositoryFacts,
        storedEvidence: ForgeStoredCredentialAuthorizationEvidence?
    ) async throws -> PermissionResolution {
        let credential = account.currentCredential
        let effectiveEvidence: ForgeStoredCredentialAuthorizationEvidence
        switch (credential.source, storedEvidence) {
        case (.forgeApplicationDeviceFlow, .githubApplicationMilestone3):
            effectiveEvidence = .githubApplicationMilestone3
        case (.forgeApplicationDeviceFlow, nil):
            effectiveEvidence = .githubApplicationMilestone3
            try await services.accountStore.updateAuthorizationEvidence(
                effectiveEvidence,
                for: credential.reference
            )
        case (.fineGrainedPersonalAccessToken, .githubFineGrainedNotIntrospectable):
            effectiveEvidence = .githubFineGrainedNotIntrospectable
        case (.fineGrainedPersonalAccessToken, nil):
            effectiveEvidence = .githubFineGrainedNotIntrospectable
            try await services.accountStore.updateAuthorizationEvidence(
                effectiveEvidence,
                for: credential.reference
            )
        case let (.classicPersonalAccessToken, .githubClassicScopes(scopes)),
             let (.commandLineBroker, .githubClassicScopes(scopes)):
            effectiveEvidence = .githubClassicScopes(scopes)
        case (.classicPersonalAccessToken, nil), (.commandLineBroker, nil):
            let scopes = try await introspectClassicScopes(
                services: services,
                credential: credential.reference
            )
            effectiveEvidence = .githubClassicScopes(scopes)
            try await services.accountStore.updateAuthorizationEvidence(
                effectiveEvidence,
                for: credential.reference
            )
        default:
            throw ForgeGitHubPullRequestCompositionError.authorizationEvidenceUnavailable
        }
        let grants: [ForgePermissionGrant]
        switch effectiveEvidence {
        case .githubApplicationMilestone3:
            grants = ForgePermissionRequestEnvelope.milestone3.requirements.map {
                ForgePermissionGrant(permission: $0.permission, authority: .known($0.level))
            }
        case .githubFineGrainedNotIntrospectable:
            grants = ForgeRepositoryPermission.allCases.map {
                ForgePermissionGrant(permission: $0, authority: .unknown)
            }
        case let .githubClassicScopes(scopes):
            let repositoryIsPublic = if case .available(.public) = facts.visibility {
                true
            } else {
                false
            }
            grants = ForgeRepositoryPermission.allCases.map { permission in
                ForgePermissionGrant(
                    permission: permission,
                    authority: Self.classicAuthority(
                        permission: permission,
                        scopes: scopes,
                        repositoryIsPublic: repositoryIsPublic
                    )
                )
            }
        }
        return try PermissionResolution(
            evidence: ForgePermissionEvidence(
                credential: credential.reference,
                repository: repository,
                freshness: .current,
                grants: grants
            ),
            storedEvidence: effectiveEvidence
        )
    }

    private func introspectClassicScopes(
        services: ForgeApplicationServices,
        credential: ForgeCredentialReference
    ) async throws -> Set<String> {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitX-ForgeKit", forHTTPHeaderField: "User-Agent")
        request = try await services.githubReadAdapterFactory.authorizedRequest(request, for: credential)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ForgeGitHubPullRequestCompositionError.authorizationEvidenceUnavailable
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String, let value = pair.value as? String else { return }
            result[key] = value
        }
        let metadata = GitHubResponseMetadata(
            statusCode: http.statusCode,
            requestID: http.value(forHTTPHeaderField: "x-github-request-id"),
            rateLimit: GitHubRateLimitParser.parse(
                statusCode: http.statusCode,
                headers: headers,
                receivedAt: now()
            )
        )
        await services.githubMutationState.record(
            response: metadata,
            credential: credential,
            now: now()
        )
        if let until = metadata.rateLimit.cooldownDeadline(statusCode: http.statusCode, now: now()) {
            throw ForgeGitHubPullRequestCompositionError.rateLimited(until: until)
        }
        guard http.statusCode == 200 else {
            throw ForgeGitHubPullRequestCompositionError.authorizationEvidenceUnavailable
        }
        let value = http.value(forHTTPHeaderField: "x-oauth-scopes") ?? ""
        let scopes = Set(value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
        logger.notice("Refreshed safe classic/CLI scope evidence for the exact Credential")
        return scopes
    }

    static func authorization(
        key: ForgeCapabilityKey,
        capability: ForgeOperationCapability,
        operationWasConfirmed: Bool
    ) throws -> GitHubMutationAuthorization {
        switch capability {
        case .verified:
            return try GitHubMutationAuthorization(key: key, capability: capability)
        case let .unverifiedWrite(attempt):
            if !operationWasConfirmed {
                throw ForgeGitHubPullRequestCompositionError.explicitConfirmationRequired(key.operation)
            }
            // The normal native Create/Edit/Sync submission is the accepted
            // explicit confirmation. Bind it to the exact evaluator-issued
            // attempt so it cannot authorize another operation.
            return try GitHubMutationAuthorization(
                key: key,
                capability: capability,
                explicitConfirmation: ForgeExplicitCapabilityConfirmation(attempt: attempt)
            )
        case .unavailable:
            throw ForgeGitHubPullRequestCompositionError.capabilityUnavailable(key.operation)
        }
    }

    static func classicAuthority(
        permission: ForgeRepositoryPermission,
        scopes: Set<String>,
        repositoryIsPublic: Bool
    ) -> ForgePermissionAuthority {
        let scopes = Set(scopes.map { $0.lowercased() })
        if scopes.contains("repo") || (repositoryIsPublic && scopes.contains("public_repo")) {
            switch permission {
            case .metadata: return .known(.read)
            case .contents, .pullRequests, .issues: return .known(.write)
            case .checks: return .known(.read)
            case .commitStatuses: return .known(.write)
            }
        }
        if permission == .commitStatuses, scopes.contains("repo:status") {
            return .known(.write)
        }
        if repositoryIsPublic {
            return .known(.read)
        }
        return .unknown
    }
}

extension ForgeGitHubPullRequestDependencyProvider: ForgeGitHubPullRequestReviewDependencyProviding {
    func reviewReadContext(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operations: Set<ForgeOperation>
    ) async throws -> ForgeGitHubPullRequestReviewReadContext {
        let evaluation = try await evaluateOperationCapabilities(
            accountID: accountID,
            repository: repository,
            operations: operations
        )
        let account = evaluation.resolution.account
        let credential = account.currentCredential.reference
        let environment = await evaluation.services.githubMutationState.environment(
            for: credential,
            now: now()
        )
        let allowed: Set<ForgeOperation> = Set(evaluation.capabilities.compactMap { operation, capability in
            if case .unavailable = capability {
                return nil
            }
            return operation
        })
        return ForgeGitHubPullRequestReviewReadContext(
            account: account,
            credential: credential,
            environment: environment,
            allowedOperations: allowed,
            readAdapter: evaluation.resolution.readAdapter
        )
    }

    func reviewMutationContext(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) async throws -> ForgeGitHubPullRequestReviewMutationContext {
        let context = try await mutationContext(
            accountID: accountID,
            repository: repository,
            operation: operation
        )
        guard let readAdapter = context.readAdapter as? any ForgeGitHubPullRequestReviewReading,
              let mutationAdapter = context.mutationAdapter as? any ForgeGitHubPullRequestReviewMutationExecuting
        else {
            throw ForgeGitHubPullRequestCompositionError.capabilityUnavailable(operation)
        }
        return ForgeGitHubPullRequestReviewMutationContext(
            account: context.account,
            credential: context.credential,
            authorization: context.authorization,
            readAdapter: readAdapter,
            mutationAdapter: mutationAdapter
        )
    }

    func recordSuccess(
        _ result: GitHubResponseMetadata,
        context: ForgeGitHubPullRequestReviewMutationContext
    ) async {
        guard let services = try? await loader.services() else { return }
        await services.githubMutationState.recordSuccess(
            response: result,
            credential: context.credential,
            confirmation: context.authorization.explicitConfirmation,
            now: now()
        )
    }

    func recordFailure(
        _ error: GitHubMutationError,
        context: ForgeGitHubPullRequestReviewMutationContext
    ) async {
        guard let services = try? await loader.services() else { return }
        await services.githubMutationState.recordFailure(
            error,
            credential: context.credential,
            authorization: context.authorization,
            now: now()
        )
        switch error {
        case .permissionDenied, .samlAuthorizationRequired, .capabilityUnavailable:
            try? await services.accountStore.clearAuthorizationEvidence(for: context.credential)
            await services.githubMutationState.recordAuthoritativeDenial(
                for: context.authorization.key
            )
        default:
            break
        }
    }
}

nonisolated protocol RepositoryPullRequestLocalPreparationProviding: Sendable {
    func preparation(
        accountID: ForgeAccountID,
        binding: ForgeRepositoryBinding,
        localBranch: ForgeRefName,
        localHead: ForgeCommitID,
        defaultBranch: ForgeRefName
    ) async throws -> RepositoryPullRequestCreationPreparation
}

/// Provider-neutral application service. GitHub-specific authorization and
/// result mapping remain behind its dependency provider and never reach the UI.
actor RepositoryPullRequestProductionService: RepositoryPullRequestMutationServing {
    private let binding: ForgeRepositoryBinding
    private let dependencies: any ForgeGitHubPullRequestDependencyProviding
    private let localPreparation: any RepositoryPullRequestLocalPreparationProviding
    private let mutationLifecycle: (any ForgeMutationLifecycleCoordinating)?
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "PullRequestApplicationService")

    init(
        binding: ForgeRepositoryBinding,
        dependencies: any ForgeGitHubPullRequestDependencyProviding,
        localPreparation: any RepositoryPullRequestLocalPreparationProviding,
        mutationLifecycle: (any ForgeMutationLifecycleCoordinating)? = nil
    ) {
        self.binding = binding
        self.dependencies = dependencies
        self.localPreparation = localPreparation
        self.mutationLifecycle = mutationLifecycle
    }

    func prepareCreation(
        repository: ForgeRepositoryIdentity,
        localBranch: ForgeRefName,
        localHead: ForgeCommitID
    ) async throws -> RepositoryPullRequestCreationPreparation {
        let accountID = try exactAccountID(repository: repository)
        let capabilities = try await dependencies.operationCapabilities(
            accountID: accountID,
            repository: repository,
            operations: [.createPullRequest]
        )
        guard let capability = capabilities[.createPullRequest] else {
            throw RepositoryPullRequestServiceError.nativeCreationUnavailable
        }
        if case .unavailable = capability {
            throw RepositoryPullRequestServiceError.nativeCreationUnavailable
        }
        let context = try await dependencies.preparationContext(
            accountID: accountID,
            repository: repository
        )
        try Task.checkCancellation()
        guard case let .available(defaultBranch) = context.facts.defaultBranch else {
            throw RepositoryPullRequestServiceError.nativeCreationUnavailable
        }
        return try await localPreparation.preparation(
            accountID: context.account.id,
            binding: binding,
            localBranch: localBranch,
            localHead: localHead,
            defaultBranch: defaultBranch
        )
    }

    func capabilities(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operations: Set<ForgeOperation>
    ) async throws -> [ForgeOperation: ForgeOperationCapability] {
        try validate(accountID: accountID, repository: repository)
        return try await dependencies.operationCapabilities(
            accountID: accountID,
            repository: repository,
            operations: operations
        )
    }

    func createPullRequest(
        accountID: ForgeAccountID,
        form: ForgePullRequestCreationForm
    ) async throws -> RepositoryPullRequestCreationOutcome {
        try validate(accountID: accountID, repository: form.repository)
        let context = try await dependencies.mutationContext(
            accountID: accountID,
            repository: form.repository,
            operation: .createPullRequest
        )
        let registration = try mutationLifecycle?.register(
            accountID: accountID,
            repository: form.repository,
            operation: .createPullRequest,
            startedAt: Date()
        )
        defer {
            if let registration {
                _ = mutationLifecycle?.finish(registration)
            }
        }
        do {
            let result = try await context.mutationAdapter.createPullRequest(
                accountID: accountID,
                form: form,
                authorization: context.authorization
            )
            await dependencies.recordSuccess(result.response, context: context)
            let mapped = Self.creationOutcome(result.value)
            await refreshAfterKnownSuccess(destination: Self.destination(result.value), context: context)
            logger.notice("Completed exact-account Pull Request creation with authoritative result")
            return mapped
        } catch let error as GitHubMutationError {
            await dependencies.recordFailure(error, context: context)
            if let reconciled = try await reconcileCreate(form: form, error: error, context: context) {
                return reconciled
            }
            throw Self.map(error)
        }
    }

    func editPullRequest(
        accountID: ForgeAccountID,
        edit: ForgePullRequestEdit
    ) async throws -> RepositoryPullRequestEditOutcome {
        try validate(accountID: accountID, repository: edit.repository)
        let context = try await dependencies.mutationContext(
            accountID: accountID,
            repository: edit.repository,
            operation: .editPullRequest
        )
        let registration = try mutationLifecycle?.register(
            accountID: accountID,
            repository: edit.repository,
            operation: .editPullRequest,
            startedAt: Date()
        )
        defer {
            if let registration {
                _ = mutationLifecycle?.finish(registration)
            }
        }
        do {
            let result = try await context.mutationAdapter.editPullRequest(
                accountID: accountID,
                edit: edit,
                authorization: context.authorization
            )
            await dependencies.recordSuccess(result.response, context: context)
            logger.notice("Completed exact-account Pull Request edit with authoritative result")
            return try Self.editOutcome(result.value)
        } catch let error as GitHubMutationError {
            await dependencies.recordFailure(error, context: context)
            if case .outcomeUnknown = error,
               let reconciled = try await reconcileEdit(edit: edit, context: context)
            {
                return reconciled
            }
            throw Self.map(error)
        }
    }

    func syncFork(
        accountID: ForgeAccountID,
        plan: ForgeSyncForkPlan
    ) async throws -> RepositorySyncForkOutcome {
        try validate(accountID: accountID, repository: plan.fork)
        let context = try await dependencies.mutationContext(
            accountID: accountID,
            repository: plan.fork,
            operation: .syncFork
        )
        let registration = try mutationLifecycle?.register(
            accountID: accountID,
            repository: plan.fork,
            operation: .syncFork,
            startedAt: Date()
        )
        defer {
            if let registration {
                _ = mutationLifecycle?.finish(registration)
            }
        }
        do {
            let result = try await context.mutationAdapter.syncFork(
                accountID: accountID,
                plan: plan,
                authorization: context.authorization
            )
            await dependencies.recordSuccess(result.response, context: context)
            let summary = switch result.value.mergeType {
            case .fastForward: "GitHub fast-forwarded the fork."
            case .merge: "GitHub merged the upstream branch into the fork."
            case .none: "The fork was already up to date."
            case .unknown: "GitHub completed the fork synchronization."
            }
            logger.notice("Completed exact-account server-side fork synchronization")
            return RepositorySyncForkOutcome(plan: plan, serverSummary: summary)
        } catch let error as GitHubMutationError {
            await dependencies.recordFailure(error, context: context)
            throw Self.map(error)
        }
    }

    private func exactAccountID(repository: ForgeRepositoryIdentity) throws -> ForgeAccountID {
        guard repository == binding.primaryRepository else {
            throw RepositoryPullRequestServiceError.repositoryUnavailable
        }
        guard let accountID = binding.preferredAccount else {
            throw ForgeGitHubPullRequestCompositionError.exactAccountRequired
        }
        return accountID
    }

    private func validate(accountID: ForgeAccountID, repository: ForgeRepositoryIdentity) throws {
        guard try exactAccountID(repository: repository) == accountID else {
            throw ForgeGitHubPullRequestCompositionError.accountMismatch
        }
    }

    private func reconcileCreate(
        form: ForgePullRequestCreationForm,
        error: GitHubMutationError,
        context: ForgeGitHubPullRequestMutationContext
    ) async throws -> RepositoryPullRequestCreationOutcome? {
        let key = try ForgePullRequestComparisonKey(
            repository: form.repository,
            baseRepository: form.base.repository,
            base: form.base.name,
            headRepository: form.head.repository,
            head: form.head.name
        )
        if case let .authoritative(problems, _) = error {
            let message = problems.first?.authoritativeMessage ?? error.localizedDescription
            let rejection = try ForgeCreatePullRequestAuthoritativeRejection(
                comparison: key,
                message: message
            )
            let refreshed: [ForgePullRequestSummary]
            do {
                refreshed = try await openPullRequests(
                    repository: form.repository,
                    adapter: context.readAdapter
                )
            } catch {
                logger.error("Could not refresh Pull Requests after authoritative create rejection; preserving draft")
                throw ForgeGitHubPullRequestCompositionError.authoritative(message)
            }
            switch ForgeCreatePullRequestReconciliationPolicy.decision(
                rejection: rejection,
                refreshedPullRequests: refreshed
            ) {
            case let .openExisting(summary):
                logger.notice("Authoritative create reconciliation found the exact open Pull Request")
                return .existing(.pullRequest(summary.repository, summary.number))
            case let .preserveDraft(authoritativeMessage):
                throw ForgeGitHubPullRequestCompositionError.authoritative(authoritativeMessage)
            }
        }

        guard Self.isUnknown(error) else { return nil }
        let refreshed = try await openPullRequests(repository: form.repository, adapter: context.readAdapter)
        if case let .openExisting(summary) = ForgeDuplicatePullRequestPolicy.decision(for: key, among: refreshed) {
            logger.notice("Unknown create outcome reconciled to the exact open Pull Request")
            return .existing(.pullRequest(summary.repository, summary.number))
        }
        return nil
    }

    private func reconcileEdit(
        edit: ForgePullRequestEdit,
        context: ForgeGitHubPullRequestMutationContext
    ) async throws -> RepositoryPullRequestEditOutcome? {
        let result = try await context.readAdapter.pullRequestDetails(
            repository: edit.repository,
            number: edit.number,
            timelinePageSize: 50,
            timelineAfter: nil,
            checkPageSize: 50,
            checkAfter: nil
        )
        let details = result.value.details
        guard details.summary.title == edit.title,
              case let .available(body) = details.bodyMarkdown,
              body == edit.bodyMarkdown
        else { return nil }
        let snapshot = try ForgePullRequestEditableSnapshot(
            repository: edit.repository,
            number: edit.number,
            title: edit.title,
            bodyMarkdown: edit.bodyMarkdown,
            updatedAt: details.summary.updatedAt
        )
        logger.notice("Unknown edit outcome reconciled from a fresh exact Pull Request read")
        return RepositoryPullRequestEditOutcome(
            snapshot: snapshot,
            destination: .pullRequest(edit.repository, edit.number)
        )
    }

    private func openPullRequests(
        repository: ForgeRepositoryIdentity,
        adapter: any ForgeGitHubPullRequestReading
    ) async throws -> [ForgePullRequestSummary] {
        var items: [ForgePullRequestSummary] = []
        var cursor: ForgePageCursor?
        repeat {
            let page = try await adapter.pullRequests(
                repository: repository,
                pageSize: 100,
                after: cursor,
                states: [.open]
            ).value
            items.append(contentsOf: page.items)
            cursor = page.nextCursor
        } while cursor != nil
        return items
    }

    private func refreshAfterKnownSuccess(
        destination: ForgeDestination,
        context: ForgeGitHubPullRequestMutationContext
    ) async {
        guard case let .pullRequest(repository, number) = destination else { return }
        do {
            _ = try await context.readAdapter.pullRequestDetails(
                repository: repository,
                number: number,
                timelinePageSize: 50,
                timelineAfter: nil,
                checkPageSize: 50,
                checkAfter: nil
            )
            logger.debug("Refreshed Pull Request authoritatively after mutation success")
        } catch {
            logger.error("Post-mutation Pull Request reconciliation refresh failed")
        }
    }

    private static func creationOutcome(
        _ value: GitHubPullRequestCreationOutcome
    ) -> RepositoryPullRequestCreationOutcome {
        switch value {
        case let .created(snapshot): .created(.pullRequest(snapshot.repository, snapshot.number))
        case let .existing(snapshot): .existing(.pullRequest(snapshot.repository, snapshot.number))
        }
    }

    private static func destination(_ value: GitHubPullRequestCreationOutcome) -> ForgeDestination {
        switch value {
        case let .created(snapshot), let .existing(snapshot):
            .pullRequest(snapshot.repository, snapshot.number)
        }
    }

    private static func editOutcome(
        _ value: GitHubPullRequestMutationValue
    ) throws -> RepositoryPullRequestEditOutcome {
        try RepositoryPullRequestEditOutcome(
            snapshot: value.editableSnapshot,
            destination: .pullRequest(value.repository, value.number)
        )
    }

    private static func isUnknown(_ error: GitHubMutationError) -> Bool {
        if case .outcomeUnknown = error {
            return true
        }
        return false
    }

    private static func map(_ error: GitHubMutationError) -> Error {
        switch error {
        case .offline:
            ForgeGitHubPullRequestCompositionError.offline
        case let .rateLimited(response):
            response.rateLimit.cooldownDeadline(statusCode: response.statusCode, now: Date())
                .map(ForgeGitHubPullRequestCompositionError.rateLimited(until:))
                ?? error
        case let .authoritative(problems, _):
            ForgeGitHubPullRequestCompositionError.authoritative(
                problems.first?.authoritativeMessage ?? error.localizedDescription
            )
        case .outcomeUnknown:
            ForgeGitHubPullRequestCompositionError.outcomeUnknown
        default:
            error
        }
    }
}

/// Resolves the application database lazily so creating a repository window
/// does not eagerly initialize Forge services. Recovery-required mode fails
/// closed and never silently falls back to volatile drafts.
nonisolated struct ForgeLazySQLitePullRequestDraftStore: RepositoryPullRequestDraftPersisting {
    private let loader: ForgeApplicationServiceLoader

    init(loader: ForgeApplicationServiceLoader) {
        self.loader = loader
    }

    func load(identity: ForgeDraftIdentity) async throws -> ForgeDraft? {
        try await store().load(identity: identity)
    }

    func save(identity: ForgeDraftIdentity, content: ForgeDraftContent, at date: Date) async throws {
        try await store().save(identity: identity, content: content, at: date)
    }

    func delete(identity: ForgeDraftIdentity) async throws {
        try await store().delete(identity: identity)
    }

    private func store() async throws -> ForgeSQLitePullRequestDraftStore {
        guard let database = try await loader.services().database else {
            throw RepositoryPullRequestServiceError.draftUnavailable
        }
        return ForgeSQLitePullRequestDraftStore(database: database)
    }
}

// MARK: - Owned and organization clone catalogs

nonisolated protocol ForgeGitHubCloneCatalogLoading: Sendable {
    func repositories(
        account: ForgeAccount,
        credential: ForgeCredentialReference
    ) async throws -> ForgeGitHubCloneCatalogLoad
}

nonisolated struct ForgeGitHubCloneCatalogLoad: Sendable {
    let entries: [RepositoryForgeCloneCatalog.Entry]
    let responses: [GitHubResponseMetadata]
}

final nonisolated class ForgeGitHubCloneCatalogLoader: ForgeGitHubCloneCatalogLoading, Sendable {
    private struct RepositoryPayload: Decodable {
        struct Owner: Decodable {
            let login: String
            let type: String
        }

        let name: String
        let owner: Owner
    }

    private let adapterFactory: ForgeGitHubReadAdapterFactory
    private let session: URLSession

    init(
        adapterFactory: ForgeGitHubReadAdapterFactory,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.adapterFactory = adapterFactory
        session = URLSession(configuration: sessionConfiguration)
    }

    func repositories(
        account: ForgeAccount,
        credential: ForgeCredentialReference
    ) async throws -> ForgeGitHubCloneCatalogLoad {
        guard account.currentCredential.reference == credential else {
            throw ForgeGitHubPullRequestCompositionError.currentCredentialRequired
        }
        var entries: [RepositoryForgeCloneCatalog.Entry] = []
        var responses: [GitHubResponseMetadata] = []
        var page = 1
        while true {
            var components = URLComponents(string: "https://api.github.com/user/repos")!
            components.queryItems = [
                URLQueryItem(name: "affiliation", value: "owner,organization_member"),
                URLQueryItem(name: "direction", value: "asc"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "sort", value: "full_name"),
                URLQueryItem(name: "visibility", value: "all"),
            ]
            guard let url = components.url else {
                throw ForgeGitHubPullRequestCompositionError.malformedCloneCatalog
            }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("GitX-ForgeKit", forHTTPHeaderField: "User-Agent")
            request = try await adapterFactory.authorizedRequest(request, for: credential)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ForgeGitHubPullRequestCompositionError.malformedCloneCatalog
            }
            let metadata = Self.metadata(http)
            responses.append(metadata)
            if metadata.rateLimit.cooldownDeadline(statusCode: http.statusCode, now: Date()) != nil {
                throw GitHubReadError.rateLimited(metadata)
            }
            guard http.statusCode == 200 else {
                throw ForgeGitHubPullRequestCompositionError.capabilityUnavailable(.listCloneRepositories)
            }
            let payload = try JSONDecoder().decode([RepositoryPayload].self, from: data)
            for repository in payload {
                let identity = try ForgeRepositoryIdentity(
                    forge: account.id.forge,
                    owner: repository.owner.login,
                    name: repository.name
                )
                let relationship: ForgeCloneRepositoryRelationship
                switch repository.owner.type.lowercased() {
                case "user": relationship = .owned
                case "organization": relationship = .organization
                default: throw ForgeGitHubPullRequestCompositionError.malformedCloneCatalog
                }
                try entries.append(RepositoryForgeCloneCatalog.Entry(
                    repository: identity,
                    relationship: relationship
                ))
            }
            guard payload.count == 100 else { break }
            page += 1
        }
        return ForgeGitHubCloneCatalogLoad(entries: Array(Set(entries)), responses: responses)
    }

    private static func metadata(_ response: HTTPURLResponse) -> GitHubResponseMetadata {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String, let value = pair.value as? String else { return }
            result[key] = value
        }
        return GitHubResponseMetadata(
            statusCode: response.statusCode,
            requestID: headers.first { $0.key.caseInsensitiveCompare("x-github-request-id") == .orderedSame }?.value,
            rateLimit: GitHubRateLimitParser.parse(
                statusCode: response.statusCode,
                headers: headers,
                receivedAt: Date()
            )
        )
    }
}

actor RepositoryForgeCloneProductionService: RepositoryForgeCloneCatalogServing {
    private let loader: ForgeApplicationServiceLoader
    private let loaderFactory: @Sendable (ForgeApplicationServices) -> any ForgeGitHubCloneCatalogLoading
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeCloneCatalog")

    init(
        loader: ForgeApplicationServiceLoader,
        loaderFactory: @escaping @Sendable (ForgeApplicationServices) -> any ForgeGitHubCloneCatalogLoading = {
            ForgeGitHubCloneCatalogLoader(adapterFactory: $0.githubReadAdapterFactory)
        }
    ) {
        self.loader = loader
        self.loaderFactory = loaderFactory
    }

    func cloneCatalogs() async throws -> [RepositoryForgeCloneCatalog] {
        let services = try await loader.services()
        let accounts = try await services.accountStore.accounts().filter {
            ForgeGitHubReadCredentialAuthority.isGitHubDotCom($0.id.forge)
        }
        let catalogLoader = loaderFactory(services)
        var catalogs: [RepositoryForgeCloneCatalog] = []
        for account in accounts {
            try Task.checkCancellation()
            let credential = account.currentCredential.reference
            switch await services.githubMutationState.environment(for: credential, now: Date()) {
            case .available:
                break
            case .offline:
                throw ForgeGitHubPullRequestCompositionError.offline
            case let .rateLimited(until):
                throw ForgeGitHubPullRequestCompositionError.rateLimited(until: until)
            }
            do {
                let load = try await catalogLoader.repositories(account: account, credential: credential)
                for response in load.responses {
                    await services.githubMutationState.record(
                        response: response,
                        credential: credential,
                        now: Date()
                    )
                }
                try catalogs.append(RepositoryForgeCloneCatalog(
                    accountID: account.id,
                    accountDisplayName: account.login,
                    repositories: load.entries
                ))
            } catch let GitHubReadError.rateLimited(response) {
                await services.githubMutationState.record(
                    response: response,
                    credential: credential,
                    now: Date()
                )
                let until = response.rateLimit.cooldownDeadline(statusCode: response.statusCode, now: Date())
                throw until.map(ForgeGitHubPullRequestCompositionError.rateLimited(until:))
                    ?? ForgeGitHubPullRequestCompositionError.capabilityUnavailable(.listCloneRepositories)
            }
        }
        logger.notice("Loaded exact-account owned/organization clone catalogs accounts=\(catalogs.count, privacy: .public)")
        return catalogs
    }
}
