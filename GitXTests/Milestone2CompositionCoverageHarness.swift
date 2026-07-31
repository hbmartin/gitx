#if DEBUG
    import ForgeKit
    import Foundation
    import GitHubForgeAdapter

    /// App-target coverage bridge for deterministic Milestone 2 composition
    /// branches which do not require a GitHub Credential or network request.
    @MainActor
    @objc(PBMilestone2CompositionCoverageHarness)
    // swiftlint:disable:next type_body_length unused_declaration
    final class Milestone2CompositionCoverageHarness: NSObject {
        @objc static func synchronousProof() -> UInt64 {
            do {
                let fixture = try CompositionCoverageFixture()
                return try bitProof([
                    errorDescriptionProof(),
                    authorizationProof(fixture),
                    classicScopeProof(),
                ])
            } catch {
                return 0
            }
        }

        /// Objective-C's generated completion-handler bridge creates the task
        /// which executes this app-target proof, preserving Swift task-stack
        /// ownership through the asynchronous XCTest boundary.
        @objc
        static func asynchronousProof() async -> UInt64 {
            do {
                let fixture = try CompositionCoverageFixture()
                let environment = try await CompositionCoverageEnvironment.make(fixture: fixture)
                let state = await loggedProof("mutation-state") {
                    try await mutationStateProof(fixture)
                }
                let provider = await loggedProof("pull-request-provider") {
                    try await dependencyProviderProof(fixture, environment: environment)
                }
                let loader = await loggedProof("clone-loader") {
                    try await cloneLoaderProof(fixture, environment: environment)
                }
                let service = await loggedProof("clone-service") {
                    try await cloneServiceProof(fixture, environment: environment)
                }
                await environment.cleanup()
                return bitProof([state, provider, loader, service])
            } catch {
                NSLog("[M2CompositionCoverage] setup failed: %@", error.localizedDescription)
                return 0
            }
        }

        /// Runs the Milestone 3 read context in its own task frame. Xcode's
        /// optimized async code generator requires returned existential
        /// contexts to be released before the mutation-context proof begins.
        @objc
        static func reviewReadProof() async -> UInt64 {
            do {
                let fixture = try CompositionCoverageFixture()
                let environment = try await CompositionCoverageEnvironment.make(fixture: fixture)
                let provider: any ForgeGitHubPullRequestReviewDependencyProviding =
                    ForgeGitHubPullRequestDependencyProvider(
                        loader: environment.loader,
                        now: { fixture.now },
                        sessionConfiguration: { CompositionCoverageURLProtocol.configuration() }
                    )
                let read = await loggedProof("pull-request-review-read-provider") {
                    try await reviewReadDependencyProviderProof(fixture, provider: provider)
                }
                await environment.cleanup()
                return read ? 1 : 0
            } catch {
                NSLog("[M3CompositionCoverage] read setup failed: %@", error.localizedDescription)
                return 0
            }
        }

        @objc(reviewApplicationProofWithRepository:)
        static func reviewApplicationProof(repository: PBGitRepository) -> Bool {
            do {
                return try reviewApplicationFactoryProof(
                    CompositionCoverageFixture(),
                    repository: repository
                )
            } catch {
                NSLog("[M3CompositionCoverage] application setup failed: %@", error.localizedDescription)
                return false
            }
        }

        /// Proves that the shipped remote review service revalidates the
        /// repository binding before resolving any network dependencies.
        @objc
        static func reviewApplicationRemoteBindingProof(repository: PBGitRepository) async -> UInt64 {
            do {
                let fixture = try CompositionCoverageFixture()
                let suiteName = "GitX-M3-RemoteReviewBinding-\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: suiteName) else {
                    throw CompositionCoverageError.expected
                }
                defer { defaults.removePersistentDomain(forName: suiteName) }
                let composition = ApplicationComposition(
                    userDefaults: defaults,
                    automaticallyStartsForgeServices: false
                )
                let settings = RepositoryUISettings(
                    repository: repository,
                    preferences: composition.applicationPreferences
                )
                settings.forgeRepositoryBinding = try ForgeRepositoryBinding(
                    localRemoteName: "origin",
                    primaryRepository: fixture.repository,
                    preferredAccount: fixture.accountID
                )
                let service: any RepositoryPullRequestReviewMutationServing = composition
                    .forgePullRequestReviewServices.session(for: repository).service
                let identity = try RepositoryPullRequestReviewIdentity(
                    accountID: fixture.accountID,
                    repository: fixture.repository,
                    number: ForgeItemNumber(42)
                )

                settings.forgeRepositoryBinding = nil
                do {
                    _ = try await service.loadWorkspace(identity: identity)
                    return 0
                } catch {
                    return error as? RepositoryPullRequestReviewServiceError == .invalidWorkspace ? 1 : 0
                }
            } catch {
                NSLog("[M3CompositionCoverage] remote-binding setup failed: %@", error.localizedDescription)
                return 0
            }
        }

        /// Runs the local review service's binding check in a distinct task
        /// frame from the remote service proof. This mirrors the shipped
        /// services' independent asynchronous I/O boundaries.
        @objc
        static func reviewApplicationLocalBindingProof(repository: PBGitRepository) async -> UInt64 {
            do {
                let fixture = try CompositionCoverageFixture()
                let suiteName = "GitX-M3-LocalReviewBinding-\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: suiteName) else {
                    throw CompositionCoverageError.expected
                }
                defer { defaults.removePersistentDomain(forName: suiteName) }
                let composition = ApplicationComposition(
                    userDefaults: defaults,
                    automaticallyStartsForgeServices: false
                )
                let settings = RepositoryUISettings(
                    repository: repository,
                    preferences: composition.applicationPreferences
                )
                settings.forgeRepositoryBinding = try ForgeRepositoryBinding(
                    localRemoteName: "origin",
                    primaryRepository: fixture.repository,
                    preferredAccount: fixture.accountID
                )
                let service: any RepositoryPullRequestLocalReviewServing = composition
                    .forgePullRequestReviewServices.session(for: repository).localService
                let base = try ForgeBranchReference(
                    repository: fixture.repository,
                    name: ForgeRefName("main"),
                    commit: ForgeCommitID(String(repeating: "b", count: 40))
                )

                settings.forgeRepositoryBinding = nil
                do {
                    try await service.fetchBase(base)
                    return 0
                } catch {
                    return error as? RepositoryPullRequestReviewServiceError == .invalidWorkspace ? 1 : 0
                }
            } catch {
                NSLog("[M3CompositionCoverage] local-binding setup failed: %@", error.localizedDescription)
                return 0
            }
        }

        /// Runs the Milestone 3 mutation context and authorization feedback in
        /// a distinct task frame from the read-context proof.
        @objc
        static func reviewMutationProof() async -> UInt64 {
            do {
                let fixture = try CompositionCoverageFixture()
                let environment = try await CompositionCoverageEnvironment.make(fixture: fixture)
                let provider: any ForgeGitHubPullRequestReviewDependencyProviding =
                    ForgeGitHubPullRequestDependencyProvider(
                        loader: environment.loader,
                        now: { fixture.now },
                        sessionConfiguration: { CompositionCoverageURLProtocol.configuration() }
                    )
                let mutation = await loggedProof("pull-request-review-mutation-provider") {
                    try await reviewMutationDependencyProviderProof(
                        fixture,
                        services: environment.services,
                        provider: provider
                    )
                }
                await environment.cleanup()
                return mutation ? 1 : 0
            } catch {
                NSLog("[M3CompositionCoverage] mutation setup failed: %@", error.localizedDescription)
                return 0
            }
        }

        private static func loggedProof(
            _ name: String,
            operation: () async throws -> Bool
        ) async -> Bool {
            do {
                let result = try await operation()
                NSLog("[M2CompositionCoverage] %@=%d", name, result)
                return result
            } catch {
                NSLog("[M2CompositionCoverage] %@ failed: %@", name, error.localizedDescription)
                return false
            }
        }

        // MARK: Synchronous policy and diagnostics

        private static func errorDescriptionProof() -> Bool {
            let until = Date(timeIntervalSince1970: 2000)
            let errors: [ForgeGitHubPullRequestCompositionError] = [
                .exactAccountRequired,
                .accountMismatch,
                .currentCredentialRequired,
                .authorizationEvidenceUnavailable,
                .capabilityUnavailable(.createPullRequest),
                .explicitConfirmationRequired(.editPullRequest),
                .offline,
                .rateLimited(until: until),
                .authoritative("Authoritative rejection"),
                .outcomeUnknown,
                .malformedCloneCatalog,
            ]
            return errors.allSatisfy { !($0.errorDescription ?? "").isEmpty }
                && ForgeGitHubPullRequestCompositionError.authoritative("Authoritative rejection")
                .errorDescription == "Authoritative rejection"
        }

        private static func authorizationProof(_ fixture: CompositionCoverageFixture) throws -> Bool {
            let (key, capability, attempt) = try fixture.unverifiedCapability(operation: .createPullRequest)
            let confirmationRequired = throwsComposition(
                .explicitConfirmationRequired(.createPullRequest)
            ) {
                _ = try ForgeGitHubPullRequestDependencyProvider.authorization(
                    key: key,
                    capability: capability,
                    operationWasConfirmed: false
                )
            }
            let confirmed = try ForgeGitHubPullRequestDependencyProvider.authorization(
                key: key,
                capability: capability,
                operationWasConfirmed: true
            )
            let verified = try ForgeGitHubPullRequestDependencyProvider.authorization(
                key: key,
                capability: .verified(.knownAuthority),
                operationWasConfirmed: false
            )
            let unavailable = throwsComposition(.capabilityUnavailable(.createPullRequest)) {
                _ = try ForgeGitHubPullRequestDependencyProvider.authorization(
                    key: key,
                    capability: .unavailable(.credentialUnavailable),
                    operationWasConfirmed: true
                )
            }
            return confirmationRequired
                && confirmed.explicitConfirmation?.attempt == attempt
                && verified.explicitConfirmation == nil
                && unavailable
        }

        private static func classicScopeProof() -> Bool {
            let repoAuthorities = ForgeRepositoryPermission.allCases.map {
                ForgeGitHubPullRequestDependencyProvider.classicAuthority(
                    permission: $0,
                    scopes: ["RePo"],
                    repositoryIsPublic: false
                )
            }
            let publicWrite = ForgeGitHubPullRequestDependencyProvider.classicAuthority(
                permission: .contents,
                scopes: ["PUBLIC_REPO"],
                repositoryIsPublic: true
            ) == .known(.write)
            let statuses = ForgeGitHubPullRequestDependencyProvider.classicAuthority(
                permission: .commitStatuses,
                scopes: ["repo:status"],
                repositoryIsPublic: false
            ) == .known(.write)
            let publicRead = ForgeGitHubPullRequestDependencyProvider.classicAuthority(
                permission: .checks,
                scopes: [],
                repositoryIsPublic: true
            ) == .known(.read)
            let privateUnknown = ForgeGitHubPullRequestDependencyProvider.classicAuthority(
                permission: .contents,
                scopes: ["public_repo"],
                repositoryIsPublic: false
            ) == .unknown
            return repoAuthorities == [
                .known(.read),
                .known(.write),
                .known(.write),
                .known(.write),
                .known(.read),
                .known(.write),
            ] && publicWrite && statuses && publicRead && privateUnknown
        }

        // MARK: Mutation state

        // swiftlint:disable:next function_body_length
        private static func mutationStateProof(_ fixture: CompositionCoverageFixture) async throws -> Bool {
            let store = ForgeGitHubMutationStateStore()
            let now = fixture.now
            let availableInitially = await store.environment(for: fixture.credential, now: now) == .available

            await store.sessionGate.setOffline(true)
            let offline = await store.environment(for: fixture.credential, now: now) == .offline
            await store.sessionGate.setOffline(false)

            let deadline = now.addingTimeInterval(60)
            let throttled = metadata(
                statusCode: 429,
                headers: ["retry-after": "60"],
                receivedAt: now
            )
            await store.record(response: throttled, credential: fixture.credential, now: now)
            let rateLimited = await store.environment(for: fixture.credential, now: now)
                == .rateLimited(until: deadline)
            let cooldownExpired = await store.environment(for: fixture.credential, now: deadline) == .available

            let (_, _, attempt) = try fixture.unverifiedCapability(operation: .createPullRequest)
            let confirmation = ForgeExplicitCapabilityConfirmation(
                attempt: attempt,
                identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            )
            let authorization = try GitHubMutationAuthorization(
                key: attempt.key,
                capability: .unverifiedWrite(attempt),
                explicitConfirmation: confirmation
            )
            let success = metadata(statusCode: 200, receivedAt: now)
            await store.recordSuccess(
                response: success,
                credential: fixture.credential,
                confirmation: confirmation,
                now: now
            )
            let promoted = await store.promotionLedger(for: fixture.account).contains(attempt.key)

            await store.recordFailure(
                .outcomeUnknown(nil),
                credential: fixture.credential,
                authorization: authorization,
                now: now
            )
            let unknownRetained = await store.promotionLedger(for: fixture.account).contains(attempt.key)
            await store.recordFailure(
                .transportFailure,
                credential: fixture.credential,
                authorization: authorization,
                now: now
            )
            let transportRetained = await store.promotionLedger(for: fixture.account).contains(attempt.key)
            await store.recordFailure(
                .permissionDenied(success),
                credential: fixture.credential,
                authorization: authorization,
                now: now
            )
            let permissionDenied = !(await store.promotionLedger(for: fixture.account).contains(attempt.key))

            await store.recordSuccess(
                response: success,
                credential: fixture.credential,
                confirmation: confirmation,
                now: now
            )
            await store.recordFailure(
                .capabilityUnavailable,
                credential: fixture.credential,
                authorization: authorization,
                now: now
            )
            let unavailableDenied = !(await store.promotionLedger(for: fixture.account).contains(attempt.key))

            await store.recordSuccess(
                response: success,
                credential: fixture.credential,
                confirmation: confirmation,
                now: now
            )
            await store.recordAuthoritativeDenial(for: attempt.key)
            let explicitDenial = !(await store.promotionLedger(for: fixture.account).contains(attempt.key))

            await store.recordSuccess(
                response: success,
                credential: fixture.credential,
                confirmation: confirmation,
                now: now
            )
            let rotated = try fixture.account(generation: 2)
            let oldCredentialPruned = !(await store.promotionLedger(for: rotated).contains(attempt.key))

            await store.recordFailure(
                .outcomeUnknown(throttled),
                credential: fixture.credential,
                authorization: authorization,
                now: now
            )
            let unknownResponseRecorded = await store.environment(for: fixture.credential, now: now)
                == .rateLimited(until: deadline)

            return availableInitially && offline && rateLimited && cooldownExpired
                && promoted && unknownRetained && transportRetained && permissionDenied
                && unavailableDenied && explicitDenial && oldCredentialPruned && unknownResponseRecorded
        }

        // MARK: Pull Request dependency provider

        // swiftlint:disable:next function_body_length
        private static func dependencyProviderProof(
            _ fixture: CompositionCoverageFixture,
            environment: CompositionCoverageEnvironment
        ) async throws -> Bool {
            let services = environment.services
            let provider = ForgeGitHubPullRequestDependencyProvider(
                loader: environment.loader,
                now: { fixture.now },
                sessionConfiguration: { CompositionCoverageURLProtocol.configuration() }
            )
            let missingAccount = try ForgeAccountID(
                forge: fixture.repository.forge,
                value: "missing-composition-account"
            )
            let missing = await throwsCompositionAsync(.currentCredentialRequired) {
                _ = try await provider.mutationContext(
                    accountID: missingAccount,
                    repository: fixture.repository,
                    operation: .createPullRequest
                )
            }
            let otherForge = try ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.example"))
            let otherRepository = try ForgeRepositoryIdentity(
                forge: otherForge,
                owner: "gitx",
                name: "gitx"
            )
            let mismatch = await throwsCompositionAsync(.accountMismatch) {
                _ = try await provider.preparationContext(
                    accountID: fixture.accountID,
                    repository: otherRepository
                )
            }

            try CompositionCoverageURLProtocol.setHTTP(
                statusCode: 200,
                headers: ["x-github-request-id": "capability-proof"],
                body: repositoryFactsBody()
            )
            let requestedOperations: Set<ForgeOperation> = [.createPullRequest, .syncFork]
            let rawCapabilities = try await provider.operationCapabilities(
                accountID: fixture.accountID,
                repository: fixture.repository,
                operations: requestedOperations
            )
            guard case let .unverifiedWrite(createAttempt) = rawCapabilities[.createPullRequest],
                  case let .unverifiedWrite(syncAttempt) = rawCapabilities[.syncFork]
            else {
                return false
            }
            let capabilityIdentity = rawCapabilities.count == requestedOperations.count
                && createAttempt.key.credential == fixture.credential
                && createAttempt.key.repository == fixture.repository
                && createAttempt.key.operation == .createPullRequest
                && syncAttempt.key.credential == fixture.credential
                && syncAttempt.key.repository == fixture.repository
                && syncAttempt.key.operation == .syncFork
            let eligibilityLedger = await services.githubMutationState
                .promotionLedger(for: fixture.account)
            let eligibilityDidNotPromote = !eligibilityLedger.contains(createAttempt.key)
                && !eligibilityLedger.contains(syncAttempt.key)
            let submittedContext = try await provider.mutationContext(
                accountID: fixture.accountID,
                repository: fixture.repository,
                operation: .createPullRequest
            )
            let submittedAuthorization = submittedContext.authorization.key.operation == .createPullRequest
                && submittedContext.authorization.explicitConfirmation?.attempt == createAttempt

            let rotationRejected = try await credentialRotationFreshnessProof(
                fixture,
                services: services,
                provider: provider
            )
            let removalRejected = try await credentialRemovalFreshnessProof(
                fixture,
                services: services,
                provider: provider
            )

            await services.githubMutationState.sessionGate.setOffline(true)
            let offline = await throwsCompositionAsync(.offline) {
                _ = try await provider.mutationContext(
                    accountID: fixture.accountID,
                    repository: fixture.repository,
                    operation: .createPullRequest
                )
            }
            await services.githubMutationState.sessionGate.setOffline(false)

            let deadline = fixture.now.addingTimeInterval(60)
            await services.githubMutationState.record(
                response: metadata(
                    statusCode: 429,
                    headers: ["retry-after": "60"],
                    receivedAt: fixture.now
                ),
                credential: fixture.credential,
                now: fixture.now
            )
            let limited = await throwsCompositionAsync(.rateLimited(until: deadline)) {
                _ = try await provider.mutationContext(
                    accountID: fixture.accountID,
                    repository: fixture.repository,
                    operation: .editPullRequest
                )
            }
            await services.githubMutationState.sessionGate.recordCooldown(
                for: fixture.credential,
                until: nil
            )

            let (_, capability, _) = try fixture.unverifiedCapability(operation: .createPullRequest)
            let authorization = try ForgeGitHubPullRequestDependencyProvider.authorization(
                key: ForgeCapabilityKey(
                    credential: fixture.credential,
                    repository: fixture.repository,
                    operation: .createPullRequest
                ),
                capability: capability,
                operationWasConfirmed: true
            )
            let readAdapter = try services.githubReadAdapterFactory.makeAdapter(
                for: fixture.credential,
                sessionConfiguration: CompositionCoverageURLProtocol.configuration()
            )
            let mutationAdapter = try services.githubReadAdapterFactory.makeMutationAdapter(
                for: fixture.credential,
                sessionGate: services.githubMutationState.sessionGate,
                sessionConfiguration: CompositionCoverageURLProtocol.configuration()
            )
            let context = ForgeGitHubPullRequestMutationContext(
                account: fixture.account,
                credential: fixture.credential,
                authorization: authorization,
                readAdapter: readAdapter,
                mutationAdapter: mutationAdapter
            )
            let success = metadata(statusCode: 200, receivedAt: fixture.now)
            await provider.recordSuccess(success, context: context)
            let promoted = await services.githubMutationState
                .promotionLedger(for: fixture.account)
                .contains(authorization.key)
            await provider.recordFailure(.transportFailure, context: context)
            let nonAuthorizationFailureRetained = await services.githubMutationState
                .promotionLedger(for: fixture.account)
                .contains(authorization.key)
            await provider.recordFailure(.permissionDenied(success), context: context)
            let denied = !(await services.githubMutationState
                .promotionLedger(for: fixture.account)
                .contains(authorization.key))
            let evidenceCleared = try await services.accountStore
                .credential(for: fixture.accountID)?.authorizationEvidence == nil
            let wrongReference = try ForgeCredentialReference(
                accountID: fixture.accountID,
                credentialID: ForgeCredentialID("wrong-composition-credential"),
                generation: fixture.credential.generation
            )
            let evidenceMismatch = await throwsAnyAsync {
                try await services.accountStore.updateAuthorizationEvidence(
                    .githubFineGrainedNotIntrospectable,
                    for: wrongReference
                )
            }
            let clearEvidenceMismatch = await throwsAnyAsync {
                try await services.accountStore.clearAuthorizationEvidence(for: wrongReference)
            }

            let failedLoader = ForgeApplicationServiceLoader {
                throw CompositionCoverageError.expected
            }
            let failedProvider = ForgeGitHubPullRequestDependencyProvider(loader: failedLoader)
            let loaderFailure = await throwsAnyAsync {
                _ = try await failedProvider.preparationContext(
                    accountID: fixture.accountID,
                    repository: fixture.repository
                )
            }

            var preauthorized = URLRequest(url: URL(string: "https://api.github.com/user")!)
            preauthorized.setValue("Bearer existing", forHTTPHeaderField: "Authorization")
            let rejectedRequest = await throwsAnyAsync {
                _ = try await services.githubReadAdapterFactory.authorizedRequest(
                    preauthorized,
                    for: fixture.credential
                )
            }
            let gitLab = try ForgeIdentity(
                kind: .gitLab,
                origin: ForgeOrigin(host: "gitlab.example")
            )
            let gitLabCredential = try ForgeCredentialReference(
                accountID: ForgeAccountID(forge: gitLab, value: "m2-gitlab"),
                credentialID: ForgeCredentialID("m2-gitlab-token"),
                generation: ForgeCredentialGeneration(1)
            )
            let rejectedMutationAdapter = throwsAny {
                _ = try services.githubReadAdapterFactory.makeMutationAdapter(
                    for: gitLabCredential,
                    sessionGate: services.githubMutationState.sessionGate
                )
            }

            return missing && mismatch && capabilityIdentity && eligibilityDidNotPromote
                && submittedAuthorization && rotationRejected && removalRejected
                && offline && limited && promoted
                && nonAuthorizationFailureRetained && denied && evidenceCleared && loaderFailure
                && rejectedRequest && rejectedMutationAdapter && evidenceMismatch && clearEvidenceMismatch
        }

        private static func reviewApplicationFactoryProof(
            _ fixture: CompositionCoverageFixture,
            repository: PBGitRepository
        ) throws -> Bool {
            let suiteName = "GitX-M3-ReviewComposition-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw CompositionCoverageError.expected
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            NSLog("[M3CompositionCoverage] application factory composition begin")
            let composition = ApplicationComposition(
                userDefaults: defaults,
                automaticallyStartsForgeServices: false
            )
            NSLog("[M3CompositionCoverage] application factory composition end")
            let settings = RepositoryUISettings(
                repository: repository,
                preferences: composition.applicationPreferences
            )
            NSLog("[M3CompositionCoverage] application factory settings created")
            let unbound = composition.forgePullRequestReviewServices.session(for: repository)
            NSLog("[M3CompositionCoverage] application factory unbound session created")
            let unboundProof = unbound.service is UnavailableRepositoryPullRequestReviewMutationService
                && unbound.localService is UnavailableRepositoryPullRequestLocalReviewService
                && unbound.drafts is ForgeLazySQLitePullRequestDraftStore
                && unbound.preferences is NullRepositoryPullRequestMutationPreferenceStore

            let gitLab = try ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.example"))
            settings.forgeRepositoryBinding = try ForgeRepositoryBinding(
                localRemoteName: "origin",
                primaryRepository: ForgeRepositoryIdentity(forge: gitLab, owner: "gitx", name: "gitx")
            )
            let unsupported = composition.forgePullRequestReviewServices.session(for: repository)
            let unsupportedProof = unsupported.service is UnavailableRepositoryPullRequestReviewMutationService
                && unsupported.localService is UnavailableRepositoryPullRequestLocalReviewService
                && unsupported.preferences is NullRepositoryPullRequestMutationPreferenceStore

            settings.forgeRepositoryBinding = try ForgeRepositoryBinding(
                localRemoteName: "origin",
                primaryRepository: fixture.repository,
                preferredAccount: fixture.accountID
            )
            let bound = composition.forgePullRequestReviewServices.session(for: repository)
            let boundProof = bound.service is RepositoryPullRequestReviewProductionService
                && bound.localService is RepositoryPullRequestLocalReviewService
                && bound.drafts is ForgeLazySQLitePullRequestDraftStore
                && bound.preferences is RepositoryPullRequestMutationPreferenceStore
            return unboundProof && unsupportedProof && boundProof
        }

        private static func reviewReadDependencyProviderProof(
            _ fixture: CompositionCoverageFixture,
            provider: any ForgeGitHubPullRequestReviewDependencyProviding
        ) async throws -> Bool {
            try CompositionCoverageURLProtocol.setHTTP(
                statusCode: 200,
                headers: ["x-github-request-id": "review-read-proof"],
                body: repositoryFactsBody()
            )
            let requestedOperations: Set<ForgeOperation> = [
                .publishInlineReviewComment,
                .submitApproveReview,
                .mergePullRequest,
            ]
            let readContext = try await provider.reviewReadContext(
                accountID: fixture.accountID,
                repository: fixture.repository,
                operations: requestedOperations
            )
            return readContext.account.id == fixture.accountID
                && readContext.credential == fixture.credential
                && readContext.environment == .available
                && readContext.allowedOperations == requestedOperations
                && readContext.readAdapter is GitHubReadAdapter
        }

        private static func reviewMutationDependencyProviderProof(
            _ fixture: CompositionCoverageFixture,
            services: ForgeApplicationServices,
            provider: any ForgeGitHubPullRequestReviewDependencyProviding
        ) async throws -> Bool {
            try CompositionCoverageURLProtocol.setHTTP(
                statusCode: 200,
                headers: ["x-github-request-id": "review-mutation-proof"],
                body: repositoryFactsBody()
            )
            let mutationContext = try await provider.reviewMutationContext(
                accountID: fixture.accountID,
                repository: fixture.repository,
                operation: .publishInlineReviewComment
            )
            let authorization = mutationContext.authorization
            let mutationContextIsExact = mutationContext.account.id == fixture.accountID
                && mutationContext.credential == fixture.credential
                && authorization.key.credential == fixture.credential
                && authorization.key.repository == fixture.repository
                && authorization.key.operation == .publishInlineReviewComment
                && authorization.explicitConfirmation != nil
                && mutationContext.readAdapter is GitHubReadAdapter
                && mutationContext.mutationAdapter is GitHubMutationAdapter

            let success = metadata(statusCode: 200, receivedAt: fixture.now)
            await provider.recordSuccess(success, context: mutationContext)
            let promotionLedger = await services.githubMutationState
                .promotionLedger(for: fixture.account)
            let promoted = promotionLedger.contains(authorization.key)
            await provider.recordFailure(.transportFailure, context: mutationContext)
            let retainedLedger = await services.githubMutationState
                .promotionLedger(for: fixture.account)
            let nonAuthorizationFailureRetained = retainedLedger.contains(authorization.key)
            await provider.recordFailure(.permissionDenied(success), context: mutationContext)
            let deniedLedger = await services.githubMutationState
                .promotionLedger(for: fixture.account)
            let denied = !deniedLedger.contains(authorization.key)
            let currentCredential = try await services.accountStore
                .credential(for: fixture.accountID)
            let evidenceCleared = currentCredential?.authorizationEvidence == nil

            return mutationContextIsExact && promoted
                && nonAuthorizationFailureRetained && denied && evidenceCleared
        }

        private static func credentialRotationFreshnessProof(
            _ fixture: CompositionCoverageFixture,
            services: ForgeApplicationServices,
            provider: ForgeGitHubPullRequestDependencyProvider
        ) async throws -> Bool {
            let accountID = try ForgeAccountID(
                forge: fixture.repository.forge,
                value: "composition-rotation"
            )
            let account = try await services.accountStore.addPersonalAccessToken(
                accountID: accountID,
                login: "rotation",
                credentialID: ForgeCredentialID("composition-rotation-original"),
                kind: .fineGrained,
                token: Data("composition-rotation-token".utf8),
                expiresAt: nil,
                authorizationEvidence: .githubFineGrainedNotIntrospectable
            )
            let responseGate = try CompositionCoverageHTTPResponseGate(body: repositoryFactsBody())
            CompositionCoverageURLProtocol.setHandler { request in
                try responseGate.response(for: request)
            }
            let capabilityTask = Task {
                await throwsCompositionAsync(.currentCredentialRequired) {
                    _ = try await provider.operationCapabilities(
                        accountID: accountID,
                        repository: fixture.repository,
                        operations: [.createPullRequest]
                    )
                }
            }
            guard await responseGate.waitUntilStarted() else {
                responseGate.release()
                capabilityTask.cancel()
                return false
            }
            _ = try await services.accountStore.replaceCredential(
                expectedReference: account.currentCredential.reference,
                credentialID: ForgeCredentialID("composition-rotation-replacement"),
                source: .fineGrainedPersonalAccessToken,
                expiresAt: nil,
                secrets: ForgeCredentialSecretMaterial(
                    accessToken: Data("composition-replacement-token".utf8)
                ),
                authorizationEvidence: .githubFineGrainedNotIntrospectable
            )
            responseGate.release()
            let rejected = await capabilityTask.value
            try await services.accountStore.removeAccount(accountID)
            return rejected
        }

        private static func credentialRemovalFreshnessProof(
            _ fixture: CompositionCoverageFixture,
            services: ForgeApplicationServices,
            provider: ForgeGitHubPullRequestDependencyProvider
        ) async throws -> Bool {
            let accountID = try ForgeAccountID(
                forge: fixture.repository.forge,
                value: "composition-removal"
            )
            _ = try await services.accountStore.addPersonalAccessToken(
                accountID: accountID,
                login: "removal",
                credentialID: ForgeCredentialID("composition-removal-original"),
                kind: .fineGrained,
                token: Data("composition-removal-token".utf8),
                expiresAt: nil,
                authorizationEvidence: .githubFineGrainedNotIntrospectable
            )
            let responseGate = try CompositionCoverageHTTPResponseGate(body: repositoryFactsBody())
            CompositionCoverageURLProtocol.setHandler { request in
                try responseGate.response(for: request)
            }
            let mutationTask = Task {
                await throwsCompositionAsync(.currentCredentialRequired) {
                    _ = try await provider.mutationContext(
                        accountID: accountID,
                        repository: fixture.repository,
                        operation: .editPullRequest
                    )
                }
            }
            guard await responseGate.waitUntilStarted() else {
                responseGate.release()
                mutationTask.cancel()
                return false
            }
            try await services.accountStore.removeAccount(accountID)
            responseGate.release()
            return await mutationTask.value
        }

        // MARK: Clone catalog loader and production service

        // swiftlint:disable:next function_body_length
        private static func cloneLoaderProof(
            _ fixture: CompositionCoverageFixture,
            environment: CompositionCoverageEnvironment
        ) async throws -> Bool {
            let factory = environment.services.githubReadAdapterFactory
            CompositionCoverageURLProtocol.setHTTP(
                statusCode: 200,
                headers: [
                    "x-github-request-id": "composition-proof",
                    "x-ratelimit-limit": "5000",
                    "x-ratelimit-remaining": "4999",
                ],
                body: Data("""
                [
                  {"name":"gitx","owner":{"login":"hbmartin","type":"User"}},
                  {"name":"infra","owner":{"login":"acme","type":"Organization"}},
                  {"name":"gitx","owner":{"login":"hbmartin","type":"User"}}
                ]
                """.utf8)
            )
            let normal = try await ForgeGitHubCloneCatalogLoader(
                adapterFactory: factory,
                sessionConfiguration: CompositionCoverageURLProtocol.configuration()
            ).repositories(account: fixture.account, credential: fixture.credential)
            let relationships = Set(normal.entries.map(\.relationship))
            let metadataMapped = normal.responses.count == 1
                && normal.responses[0].requestID == "composition-proof"
                && normal.responses[0].statusCode == 200

            let replacement = try ForgeCredentialReference(
                accountID: fixture.accountID,
                credentialID: ForgeCredentialID("replacement"),
                generation: ForgeCredentialGeneration(2)
            )
            let wrongCredential = await throwsCompositionAsync(.currentCredentialRequired) {
                _ = try await ForgeGitHubCloneCatalogLoader(
                    adapterFactory: factory,
                    sessionConfiguration: CompositionCoverageURLProtocol.configuration()
                ).repositories(account: fixture.account, credential: replacement)
            }

            CompositionCoverageURLProtocol.setHTTP(statusCode: 503, body: Data("[]".utf8))
            let unavailable = await throwsCompositionAsync(.capabilityUnavailable(.listCloneRepositories)) {
                _ = try await ForgeGitHubCloneCatalogLoader(
                    adapterFactory: factory,
                    sessionConfiguration: CompositionCoverageURLProtocol.configuration()
                ).repositories(account: fixture.account, credential: fixture.credential)
            }

            CompositionCoverageURLProtocol.setHTTP(
                statusCode: 200,
                body: Data("[{\"name\":\"bad\",\"owner\":{\"login\":\"bot\",\"type\":\"Bot\"}}]".utf8)
            )
            let badOwner = await throwsCompositionAsync(.malformedCloneCatalog) {
                _ = try await ForgeGitHubCloneCatalogLoader(
                    adapterFactory: factory,
                    sessionConfiguration: CompositionCoverageURLProtocol.configuration()
                ).repositories(account: fixture.account, credential: fixture.credential)
            }

            CompositionCoverageURLProtocol.setNonHTTP(body: Data("[]".utf8))
            let nonHTTP = await throwsCompositionAsync(.malformedCloneCatalog) {
                _ = try await ForgeGitHubCloneCatalogLoader(
                    adapterFactory: factory,
                    sessionConfiguration: CompositionCoverageURLProtocol.configuration()
                ).repositories(account: fixture.account, credential: fixture.credential)
            }

            CompositionCoverageURLProtocol.setHTTP(
                statusCode: 429,
                headers: ["retry-after": "60"],
                body: Data("[]".utf8)
            )
            let rateLimited = await throwsReadRateLimit {
                _ = try await ForgeGitHubCloneCatalogLoader(
                    adapterFactory: factory,
                    sessionConfiguration: CompositionCoverageURLProtocol.configuration()
                ).repositories(account: fixture.account, credential: fixture.credential)
            }
            return normal.entries.count == 2 && relationships == [.owned, .organization]
                && metadataMapped && wrongCredential && unavailable && badOwner && nonHTTP && rateLimited
        }

        // swiftlint:disable:next function_body_length
        private static func cloneServiceProof(
            _ fixture: CompositionCoverageFixture,
            environment: CompositionCoverageEnvironment
        ) async throws -> Bool {
            let services = environment.services
            await services.githubMutationState.sessionGate.setOffline(false)
            await services.githubMutationState.sessionGate.recordCooldown(for: fixture.credential, until: nil)
            CompositionCoverageURLProtocol.setHTTP(
                statusCode: 200,
                headers: ["x-github-request-id": "service-proof"],
                body: Data("[{\"name\":\"gitx\",\"owner\":{\"login\":\"hbmartin\",\"type\":\"User\"}}]".utf8)
            )
            let normalService = RepositoryForgeCloneProductionService(
                loader: environment.loader,
                loaderFactory: { services in
                    ForgeGitHubCloneCatalogLoader(
                        adapterFactory: services.githubReadAdapterFactory,
                        sessionConfiguration: CompositionCoverageURLProtocol.configuration()
                    )
                }
            )
            let catalogs = try await normalService.cloneCatalogs()
            let normal = catalogs.count == 1
                && catalogs[0].accountID == fixture.accountID
                && catalogs[0].repositories.map(\.relationship) == [.owned]
            NSLog(
                "[M2CompositionCoverage] clone-service catalogs=%llu accounts=%@ relationships=%@",
                catalogs.count,
                catalogs.map { String(describing: $0.accountID) }.joined(separator: ","),
                catalogs.flatMap { $0.repositories.map { String(describing: $0.relationship) } }.joined(separator: ",")
            )

            let noDeadline = metadata(statusCode: 403, receivedAt: fixture.now)
            let fallbackService = RepositoryForgeCloneProductionService(
                loader: environment.loader,
                loaderFactory: { _ in CompositionCoverageRateLimitLoader(response: noDeadline) }
            )
            let fallback = await throwsCompositionAsync(.capabilityUnavailable(.listCloneRepositories)) {
                _ = try await fallbackService.cloneCatalogs()
            }

            CompositionCoverageURLProtocol.setHTTP(
                statusCode: 429,
                headers: ["retry-after": "60"],
                body: Data("[]".utf8)
            )
            let rateService = RepositoryForgeCloneProductionService(
                loader: environment.loader,
                loaderFactory: { services in
                    ForgeGitHubCloneCatalogLoader(
                        adapterFactory: services.githubReadAdapterFactory,
                        sessionConfiguration: CompositionCoverageURLProtocol.configuration()
                    )
                }
            )
            let rateFailure = await throwsRateLimitedComposition {
                _ = try await rateService.cloneCatalogs()
            }
            let preflightRateLimit = await throwsRateLimitedComposition {
                _ = try await rateService.cloneCatalogs()
            }

            await services.githubMutationState.sessionGate.recordCooldown(for: fixture.credential, until: nil)
            await services.githubMutationState.sessionGate.setOffline(true)
            let offline = await throwsCompositionAsync(.offline) {
                _ = try await normalService.cloneCatalogs()
            }
            await services.githubMutationState.sessionGate.setOffline(false)
            CompositionCoverageURLProtocol.setHandler(nil)
            NSLog(
                "[M2CompositionCoverage] clone-service normal=%d fallback=%d rateFailure=%d preflight=%d offline=%d",
                normal,
                fallback,
                rateFailure,
                preflightRateLimit,
                offline
            )
            return normal && fallback && rateFailure && preflightRateLimit && offline
        }

        // MARK: Proof helpers

        private static func metadata(
            statusCode: Int,
            headers: [String: String] = [:],
            receivedAt: Date
        ) -> GitHubResponseMetadata {
            GitHubResponseMetadata(
                statusCode: statusCode,
                requestID: headers["x-github-request-id"],
                rateLimit: GitHubRateLimitParser.parse(
                    statusCode: statusCode,
                    headers: headers,
                    receivedAt: receivedAt
                )
            )
        }

        private static func repositoryFactsBody() throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "data": [
                    "repository": [
                        "__typename": "Repository",
                        "id": "composition-repository",
                        "name": "gitx",
                        "nameWithOwner": "hbmartin/gitx",
                        "owner": ["__typename": "User", "login": "hbmartin"],
                        "defaultBranchRef": ["__typename": "Ref", "name": "main"],
                        "description": "GitX",
                        "repositoryTopics": [
                            "__typename": "RepositoryTopicConnection",
                            "totalCount": 0,
                            "pageInfo": [
                                "__typename": "PageInfo",
                                "hasPreviousPage": false,
                                "startCursor": NSNull(),
                                "hasNextPage": false,
                                "endCursor": NSNull(),
                            ],
                            "nodes": [],
                        ],
                        "visibility": "PUBLIC",
                        "isArchived": false,
                        "isFork": false,
                        "viewerPermission": "WRITE",
                        "viewerCanAdminister": false,
                        "viewerCanCreateIssues": true,
                        "viewerCanUpdateTopics": false,
                        "parent": NSNull(),
                    ],
                ],
            ])
        }

        private static func bitProof(_ conditions: [Bool]) -> UInt64 {
            conditions.enumerated().reduce(into: UInt64(0)) { proof, condition in
                if condition.element {
                    proof |= UInt64(1) << UInt64(condition.offset)
                }
            }
        }

        private static func throwsComposition(
            _ expected: ForgeGitHubPullRequestCompositionError,
            operation: () throws -> Void
        ) -> Bool {
            do {
                try operation()
                return false
            } catch {
                return error as? ForgeGitHubPullRequestCompositionError == expected
            }
        }

        private static func throwsCompositionAsync(
            _ expected: ForgeGitHubPullRequestCompositionError,
            operation: () async throws -> Void
        ) async -> Bool {
            do {
                try await operation()
                return false
            } catch {
                return error as? ForgeGitHubPullRequestCompositionError == expected
            }
        }

        private static func throwsRateLimitedComposition(
            operation: () async throws -> Void
        ) async -> Bool {
            do {
                try await operation()
                return false
            } catch ForgeGitHubPullRequestCompositionError.rateLimited {
                return true
            } catch {
                return false
            }
        }

        private static func throwsReadRateLimit(
            operation: () async throws -> Void
        ) async -> Bool {
            do {
                try await operation()
                return false
            } catch GitHubReadError.rateLimited {
                return true
            } catch {
                return false
            }
        }

        private static func throwsAnyAsync(operation: () async throws -> Void) async -> Bool {
            do {
                try await operation()
                return false
            } catch {
                return true
            }
        }

        private static func throwsAny(operation: () throws -> Void) -> Bool {
            do {
                try operation()
                return false
            } catch {
                return true
            }
        }
    }

    private nonisolated struct CompositionCoverageFixture: Sendable {
        let now = Date(timeIntervalSince1970: 1000)
        let repository: ForgeRepositoryIdentity
        let accountID: ForgeAccountID
        let credential: ForgeCredentialReference
        let account: ForgeAccount

        init() throws {
            let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
            repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
            accountID = try ForgeAccountID(forge: forge, value: "composition-coverage")
            credential = try ForgeCredentialReference(
                accountID: accountID,
                credentialID: ForgeCredentialID("composition-fine-grained"),
                generation: ForgeCredentialGeneration(1)
            )
            account = try ForgeAccount(
                id: accountID,
                login: "octocat",
                currentCredential: ForgeCredentialMetadata(
                    reference: credential,
                    source: .fineGrainedPersonalAccessToken
                )
            )
        }

        func account(generation: UInt64) throws -> ForgeAccount {
            let reference = try ForgeCredentialReference(
                accountID: accountID,
                credentialID: ForgeCredentialID("composition-rotated"),
                generation: ForgeCredentialGeneration(generation)
            )
            return try ForgeAccount(
                id: accountID,
                login: account.login,
                currentCredential: ForgeCredentialMetadata(
                    reference: reference,
                    source: .fineGrainedPersonalAccessToken
                )
            )
        }

        func unverifiedCapability(
            operation: ForgeOperation
        ) throws -> (ForgeCapabilityKey, ForgeOperationCapability, ForgeUnverifiedWriteAttempt) {
            let permissions = try ForgePermissionEvidence(
                credential: credential,
                repository: repository,
                freshness: .current,
                grants: ForgeRepositoryPermission.allCases.map {
                    ForgePermissionGrant(permission: $0, authority: .unknown)
                }
            )
            let access = ForgeRepositoryAccessEvidence(
                credential: credential,
                repository: repository,
                freshness: .current,
                status: .granted,
                role: .known(.write)
            )
            let capability = ForgeCapabilityEvaluator.capability(
                account: account,
                repository: repository,
                operation: operation,
                operationSupported: true,
                credentialAvailability: .available,
                now: now,
                permissionEvidence: permissions,
                accessEvidence: access,
                promotions: ForgeCapabilityPromotionLedger()
            )
            guard case let .unverifiedWrite(attempt) = capability else {
                throw CompositionCoverageError.expected
            }
            return (attempt.key, capability, attempt)
        }
    }

    private struct CompositionCoverageEnvironment {
        let services: ForgeApplicationServices
        let loader: ForgeApplicationServiceLoader
        let root: URL
        let defaultsSuite: String

        static func make(fixture: CompositionCoverageFixture) async throws -> Self {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitX-M2-Composition-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let defaultsSuite = "GitX-M2-Composition-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
                throw CompositionCoverageError.expected
            }
            let keychain = CompositionCoverageKeychain()
            let accountStore = ForgeAccountStore(keychain: keychain)
            _ = try await accountStore.addPersonalAccessToken(
                accountID: fixture.accountID,
                login: fixture.account.login,
                credentialID: fixture.credential.credentialID,
                kind: .fineGrained,
                token: Data("local-composition-token".utf8),
                expiresAt: nil,
                authorizationEvidence: .githubFineGrainedNotIntrospectable
            )
            let otherForge = try ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.example"))
            let otherAccount = try ForgeAccountID(forge: otherForge, value: "filtered-account")
            _ = try await accountStore.addPersonalAccessToken(
                accountID: otherAccount,
                login: "filtered",
                credentialID: ForgeCredentialID("filtered-token"),
                kind: .fineGrained,
                token: Data("filtered-local-token".utf8),
                expiresAt: nil
            )
            let removedAccount = try ForgeAccountID(forge: otherForge, value: "removed-account")
            _ = try await accountStore.addPersonalAccessToken(
                accountID: removedAccount,
                login: "removed",
                credentialID: ForgeCredentialID("removed-token"),
                kind: .fineGrained,
                token: Data("removed-local-token".utf8),
                expiresAt: nil
            )
            try await accountStore.removeAccount(removedAccount)

            let database = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
                databaseURL: root.appendingPathComponent("Forge.sqlite3"),
                recoveryDirectoryURL: root.appendingPathComponent("Recovery", isDirectory: true)
            ))
            let cleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)
            let deferred = ForgeDeferredAccountCleanupStore(forgeDirectory: root)
            let add = ForgeAddAccountCoordinator(
                accountStore: accountStore,
                cliBroker: GitHubCLIAccountBroker(runner: SystemForgeCLICommandRunner())
            )
            let removal = ForgeAccountRemovalCoordinator(
                accountStore: accountStore,
                persistenceCleaner: database,
                bindingCleaner: cleaner,
                avatarCleaner: PreservingSharedForgeAvatarCleaner()
            )
            let adapterFactory = ForgeGitHubReadAdapterFactory(
                credentialAuthority: ForgeGitHubReadCredentialAuthority(
                    accountStore: accountStore,
                    now: { fixture.now }
                )
            )
            let services = ForgeApplicationServices(
                dataAvailability: .available(database),
                accountStore: accountStore,
                addAccountCoordinator: add,
                removalCoordinator: removal,
                githubReadAdapterFactory: adapterFactory,
                githubMutationState: ForgeGitHubMutationStateStore(),
                githubMutationNetworkMonitor: nil,
                refreshCoordinator: nil,
                deferredAccountCleanup: deferred
            )
            return Self(
                services: services,
                loader: ForgeApplicationServiceLoader { services },
                root: root,
                defaultsSuite: defaultsSuite
            )
        }

        func cleanup() async {
            await services.database?.close()
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: root)
            CompositionCoverageURLProtocol.setHandler(nil)
        }
    }

    private nonisolated enum CompositionCoverageError: Error {
        case expected
    }

    private nonisolated struct CompositionCoverageRateLimitLoader: ForgeGitHubCloneCatalogLoading {
        let response: GitHubResponseMetadata

        func repositories(
            account _: ForgeAccount,
            credential _: ForgeCredentialReference
        ) async throws -> ForgeGitHubCloneCatalogLoad {
            throw GitHubReadError.rateLimited(response)
        }
    }

    // swift6-safety-justification: The lock serializes every in-memory fake Keychain operation.
    private final nonisolated class CompositionCoverageKeychain: ForgeCredentialKeychain, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Data] = [:]

        func data(for accountKey: String) throws -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return storage[accountKey]
        }

        func allItems() throws -> [ForgeKeychainItem] {
            lock.lock()
            defer { lock.unlock() }
            return storage.map(ForgeKeychainItem.init(accountKey:data:))
        }

        func replace(_ data: Data, for accountKey: String) throws {
            lock.lock()
            defer { lock.unlock() }
            storage[accountKey] = data
        }

        func remove(accountKey: String) throws {
            lock.lock()
            defer { lock.unlock() }
            storage[accountKey] = nil
        }
    }

    // swift6-safety-justification: URLProtocol callbacks read one handler protected by the static lock.
    private final nonisolated class CompositionCoverageURLProtocol: URLProtocol, @unchecked Sendable {
        typealias Handler = @Sendable (URLRequest) throws -> (Data, URLResponse)

        private static let lock = NSLock()
        // swift6-safety-justification: Every read and write of the shared handler is serialized by lock.
        private nonisolated(unsafe) static var handler: Handler?

        static func configuration() -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CompositionCoverageURLProtocol.self]
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            return configuration
        }

        static func setHTTP(
            statusCode: Int,
            headers: [String: String] = [:],
            body: Data
        ) {
            setHandler { request in
                guard let url = request.url,
                      let response = HTTPURLResponse(
                          url: url,
                          statusCode: statusCode,
                          httpVersion: "HTTP/1.1",
                          headerFields: headers
                      )
                else {
                    throw CompositionCoverageError.expected
                }
                return (body, response)
            }
        }

        static func setNonHTTP(body: Data) {
            setHandler { request in
                guard let url = request.url else {
                    throw CompositionCoverageError.expected
                }
                return (body, URLResponse(
                    url: url,
                    mimeType: "application/json",
                    expectedContentLength: body.count,
                    textEncodingName: "utf-8"
                ))
            }
        }

        static func setHandler(_ value: Handler?) {
            lock.lock()
            defer { lock.unlock() }
            handler = value
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host?.lowercased() == "api.github.com"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            Self.lock.lock()
            let handler = Self.handler
            Self.lock.unlock()
            guard let handler else {
                client?.urlProtocol(self, didFailWithError: CompositionCoverageError.expected)
                return
            }
            do {
                let (data, response) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    // swift6-safety-justification: The semaphores serialize the deterministic request rendezvous.
    private final nonisolated class CompositionCoverageHTTPResponseGate: @unchecked Sendable {
        private let body: Data
        private let started = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)

        init(body: Data) {
            self.body = body
        }

        func waitUntilStarted() async -> Bool {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [started] in
                    continuation.resume(returning: started.wait(timeout: .now() + 5) == .success)
                }
            }
        }

        func release() {
            released.signal()
        }

        func response(for request: URLRequest) throws -> (Data, URLResponse) {
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: "HTTP/1.1",
                      headerFields: ["x-github-request-id": "credential-freshness-proof"]
                  )
            else {
                throw CompositionCoverageError.expected
            }
            started.signal()
            guard released.wait(timeout: .now() + 5) == .success else {
                throw CompositionCoverageError.expected
            }
            return (body, response)
        }
    }
#endif
