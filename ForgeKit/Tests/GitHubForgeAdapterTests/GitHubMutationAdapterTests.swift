import ForgeKit
@testable import GitHubForgeAdapter
import XCTest

final class GitHubMutationAdapterTests: XCTestCase {
    override func tearDown() {
        GitHubMutationURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testCreateUsesPaginatedExactDuplicateDetectionAndGeneratedMutation() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication(source: .fineGrainedPersonalAccessToken)
        let repository = try makeRepository()
        let form = try creationForm(repository: repository)
        let createdQueue = MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", fixtures.creationPreflight()),
            .graphQL("GitHubCreatePullRequest", fixtures.mutation("GitHubCreatePullRequest")),
        ])
        install(createdQueue)
        let created = try await makeAdapter(authentication: authentication).createPullRequest(
            accountID: authentication.account.id,
            form: form,
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .createPullRequest
            )
        )
        guard case let .created(snapshot) = created.value else {
            return XCTFail("Expected created Pull Request")
        }
        XCTAssertEqual(snapshot.number.rawValue, 7)
        XCTAssertEqual(snapshot.repository, repository)
        XCTAssertEqual(created.ownership.operation, .createPullRequest)
        XCTAssertEqual(created.response.requestID, "mutation-fixture")
        XCTAssertEqual(createdQueue.remainingCount, 0)
        let creationVariables = try XCTUnwrap(createdQueue.payloads.last?["variables"] as? [String: Any])
        let input = try XCTUnwrap(creationVariables["input"] as? [String: Any])
        XCTAssertEqual(input["baseRefName"] as? String, "master")
        XCTAssertEqual(input["headRefName"] as? String, "feature/github-mutations")
        XCTAssertEqual(input["headRepositoryId"] as? String, "repo-node")
        XCTAssertEqual(input["draft"] as? Bool, false)

        var firstPage = fixtures.creationPreflight()
        var firstRepository = try XCTUnwrap(firstPage["repository"] as? [String: Any])
        var firstConnection = try XCTUnwrap(firstRepository["pullRequests"] as? [String: Any])
        firstConnection["totalCount"] = 1
        firstConnection["nodes"] = [fixtures.pullRequest(headName: "another-branch")]
        firstConnection["pageInfo"] = MutationFixtures.pageInfo(hasNextPage: true, endCursor: "next")
        firstRepository["pullRequests"] = firstConnection
        firstPage["repository"] = firstRepository
        var secondPage = fixtures.creationPreflight()
        var secondRepository = try XCTUnwrap(secondPage["repository"] as? [String: Any])
        var secondConnection = try XCTUnwrap(secondRepository["pullRequests"] as? [String: Any])
        secondConnection["totalCount"] = 1
        secondConnection["nodes"] = [fixtures.pullRequest()]
        secondRepository["pullRequests"] = secondConnection
        secondPage["repository"] = secondRepository
        let duplicateQueue = MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", firstPage),
            .graphQL("GitHubPullRequestCreationPreflight", secondPage),
        ])
        install(duplicateQueue)
        let duplicate = try await makeAdapter(authentication: authentication).createPullRequest(
            accountID: authentication.account.id,
            form: form,
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .createPullRequest
            )
        )
        guard case let .existing(existing) = duplicate.value else {
            return XCTFail("Expected existing Pull Request")
        }
        XCTAssertEqual(existing.number.rawValue, 7)
        XCTAssertEqual(duplicateQueue.remainingCount, 0)
        let pageTwoVariables = try XCTUnwrap(duplicateQueue.payloads.last?["variables"] as? [String: Any])
        XCTAssertEqual(pageTwoVariables["after"] as? String, "next")
    }

    func testCreateRejectsRepeatedAndMultiCursorPreflightPaginationCycles() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let form = try creationForm(repository: repository)
        let createAuthorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .createPullRequest
        )
        let scenarios = [
            (name: "repeated cursor", nextCursors: ["repeat", "repeat"]),
            (name: "multi-cursor cycle", nextCursors: ["first", "second", "first"]),
        ]

        for scenario in scenarios {
            let responses = try scenario.nextCursors.map { nextCursor in
                var page = fixtures.creationPreflight()
                var repository = try XCTUnwrap(page["repository"] as? [String: Any])
                var connection = try XCTUnwrap(repository["pullRequests"] as? [String: Any])
                connection["pageInfo"] = MutationFixtures.pageInfo(
                    hasNextPage: true,
                    endCursor: nextCursor
                )
                repository["pullRequests"] = connection
                page["repository"] = repository
                return MutationStubResponse.graphQL(
                    "GitHubPullRequestCreationPreflight",
                    page
                )
            }
            let queue = MutationResponseQueue(responses)
            install(queue)

            await XCTAssertThrowsMutationError(.malformedResponse) {
                try await self.makeAdapter(authentication: authentication).createPullRequest(
                    accountID: authentication.account.id,
                    form: form,
                    authorization: createAuthorization
                )
            }
            let requestedCursors = try queue.payloads.compactMap { payload in
                let variables = try XCTUnwrap(payload["variables"] as? [String: Any])
                return variables["after"] as? String
            }
            XCTAssertEqual(
                requestedCursors,
                Array(scenario.nextCursors.dropLast()),
                scenario.name
            )
        }
    }

    func testEditAndEveryLifecycleMutationUseFreshPreflightAndExactInputs() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let adapter = makeAdapter(authentication: authentication)

        var editResponse = fixtures.mutation("GitHubEditPullRequest")
        try fixtures.updatePullRequest(in: &editResponse) {
            $0["title"] = "Edited title"
            $0["body"] = "Edited body"
            $0["updatedAt"] = "2026-07-29T12:31:00Z"
        }
        let editQueue = MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            .graphQL("GitHubEditPullRequest", editResponse),
        ])
        install(editQueue)
        let current = try editableSnapshot(repository: repository)
        let edit = try ForgePullRequestEdit(snapshot: current, title: "Edited title", bodyMarkdown: "Edited body")
        let edited = try await adapter.editPullRequest(
            accountID: authentication.account.id,
            edit: edit,
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .editPullRequest
            )
        )
        XCTAssertEqual(edited.value.title, "Edited title")
        XCTAssertEqual(edited.value.bodyMarkdown, "Edited body")

        let cases: [(ForgePullRequestLifecycleAction, ForgePullRequestState, Bool, String)] = [
            (.markReady, .open, true, "GitHubMarkPullRequestReady"),
            (.convertToDraft, .open, false, "GitHubConvertPullRequestToDraft"),
            (.close, .open, false, "GitHubClosePullRequest"),
            (.reopen, .closed, false, "GitHubReopenPullRequest"),
            (.updateBranch, .open, false, "GitHubUpdatePullRequestBranch"),
        ]
        for (action, state, isDraft, operationName) in cases {
            let preflightData = fixtures.pullRequestPreflight(
                state: state,
                isDraft: isDraft
            )
            var mutationData = fixtures.mutation(operationName)
            try fixtures.updatePullRequest(in: &mutationData) { pullRequest in
                switch action {
                case .markReady: pullRequest["isDraft"] = false
                case .convertToDraft: pullRequest["isDraft"] = true
                case .close: pullRequest["state"] = "CLOSED"
                case .reopen: pullRequest["state"] = "OPEN"
                case .updateBranch: pullRequest["headRefOid"] = "abcdef13"
                }
            }
            let queue = MutationResponseQueue([
                .graphQL("GitHubPullRequestMutationPreflight", preflightData),
                .graphQL(operationName, mutationData),
            ])
            install(queue)
            let request = try lifecycleRequest(
                accountID: authentication.account.id,
                repository: repository,
                action: action,
                state: state,
                isDraft: isDraft
            )
            let result = try await adapter.performLifecycle(
                request,
                authorization: authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: action.operation
                )
            )
            XCTAssertEqual(result.ownership.operation, action.operation)
            XCTAssertEqual(queue.remainingCount, 0)
        }
    }

    func testImmediateReviewReplyFormalReviewAndResolutionMutationsStayHeadAndThreadBound() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let inlineRESTClient = try MutationRESTClient(responses: [
            GitHubMutationHTTPResponse(
                statusCode: 201,
                headers: ["X-GitHub-Request-Id": "inline-request"],
                data: JSONSerialization.data(withJSONObject: [
                    "node_id": "thread-node",
                    "commit_id": "abcdef12",
                    "path": "Sources/App.swift",
                ])
            ),
        ])
        let adapter = makeAdapter(authentication: authentication, restClient: inlineRESTClient)
        let number = try ForgeItemNumber(7)
        let head = try ForgeCommitID("abcdef12")
        let threadID = try ForgeObjectID(forge: repository.forge, value: "thread-node")

        let inlineQueue = MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
        ])
        install(inlineQueue)
        let inline = try ForgeInlineReviewPublication(
            accountID: authentication.account.id,
            repository: repository,
            pullRequest: number,
            displayedHead: head,
            anchor: ForgeReviewAnchor(
                path: ForgeFilePath("Sources/App.swift"),
                subject: .line,
                side: .right,
                startSide: .right,
                startLine: 4,
                line: 6
            ),
            bodyMarkdown: "Please simplify."
        )
        let inlineResult = try await adapter.publishInlineReview(
            inline,
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .publishInlineReviewComment
            )
        )
        XCTAssertEqual(inlineResult.value.objectID, threadID)
        let inlineRequests = await inlineRESTClient.requests
        let inlineRequest = try XCTUnwrap(inlineRequests.first)
        XCTAssertEqual(
            inlineRequest.url?.absoluteString,
            "https://api.github.com/repos/hbmartin/gitx/pulls/7/comments"
        )
        XCTAssertEqual(inlineRequest.httpMethod, "POST")
        XCTAssertEqual(inlineRequest.value(forHTTPHeaderField: "Authorization"), "Bearer mutation-secret")
        let inlineBody = try XCTUnwrap(inlineRequest.httpBody)
        let inlineInput = try XCTUnwrap(JSONSerialization.jsonObject(with: inlineBody) as? [String: Any])
        XCTAssertEqual(inlineInput["body"] as? String, "Please simplify.")
        XCTAssertEqual(inlineInput["commit_id"] as? String, "abcdef12")
        XCTAssertEqual(inlineInput["path"] as? String, "Sources/App.swift")
        XCTAssertEqual(inlineInput["subject_type"] as? String, "line")
        XCTAssertEqual(inlineInput["start_line"] as? Int, 4)
        XCTAssertEqual(inlineInput["line"] as? Int, 6)
        XCTAssertEqual(inlineInput["start_side"] as? String, "RIGHT")
        XCTAssertEqual(inlineInput["side"] as? String, "RIGHT")

        let replyQueue = MutationResponseQueue([
            .graphQL("GitHubReviewThreadMutationPreflight", fixtures.threadPreflight()),
            .graphQL("GitHubReplyToReviewThread", fixtures.mutation("GitHubReplyToReviewThread")),
        ])
        install(replyQueue)
        let reply = try ForgeReviewThreadReplyPublication(
            accountID: authentication.account.id,
            repository: repository,
            pullRequest: number,
            threadID: threadID,
            bodyMarkdown: "Done."
        )
        let replyResult = try await adapter.replyToReviewThread(
            reply,
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .replyToReviewThread
            )
        )
        XCTAssertEqual(replyResult.value.objectID.value, "reply-node")

        let formalCases: [(ForgeFormalReviewKind, ForgeOperation, String)] = [
            (.approve, .submitApproveReview, "APPROVED"),
            (.comment, .submitCommentReview, "COMMENTED"),
            (.requestChanges, .submitRequestChangesReview, "CHANGES_REQUESTED"),
        ]
        for (kind, operation, responseState) in formalCases {
            var response = fixtures.mutation("GitHubSubmitFormalReview")
            try fixtures.updateFormalReview(in: &response) { $0["state"] = responseState }
            let queue = MutationResponseQueue([
                .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
                .graphQL("GitHubSubmitFormalReview", response),
            ])
            install(queue)
            let submission = try ForgeFormalReviewSubmission(
                accountID: authentication.account.id,
                repository: repository,
                pullRequest: number,
                displayedHead: head,
                kind: kind,
                bodyMarkdown: kind == .requestChanges ? "Please revise." : "Looks good."
            )
            let result = try await adapter.submitFormalReview(
                submission,
                authorization: authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: operation
                )
            )
            XCTAssertEqual(result.value.displayedHead, head)
        }

        let resolveQueue = MutationResponseQueue([
            .graphQL("GitHubReviewThreadMutationPreflight", fixtures.threadPreflight(isResolved: false)),
            .graphQL("GitHubResolveReviewThread", fixtures.mutation("GitHubResolveReviewThread")),
            .graphQL("GitHubReviewThreadMutationPreflight", fixtures.threadPreflight(isResolved: true)),
            .graphQL("GitHubUnresolveReviewThread", fixtures.mutation("GitHubUnresolveReviewThread")),
        ])
        install(resolveQueue)
        let resolved = try await adapter.setReviewThreadResolution(
            accountID: authentication.account.id,
            repository: repository,
            pullRequest: number,
            threadID: threadID,
            mutation: .resolve,
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .resolveReviewThread
            )
        )
        XCTAssertEqual(resolved.value.isResolved, true)
        let unresolved = try await adapter.setReviewThreadResolution(
            accountID: authentication.account.id,
            repository: repository,
            pullRequest: number,
            threadID: threadID,
            mutation: .unresolve,
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .unresolveReviewThread
            )
        )
        XCTAssertEqual(unresolved.value.isResolved, false)
    }

    func testFreshMergeQueueAndDeleteBranchMutationsCarryExpectedHead() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let adapter = makeAdapter(authentication: authentication)
        let mergeRequest = try makeMergeRequest(accountID: authentication.account.id, repository: repository)
        var mergeResponse = fixtures.mutation("GitHubMergePullRequest")
        try fixtures.updatePullRequest(in: &mergeResponse) {
            $0["state"] = "MERGED"
            $0["mergedAt"] = "2026-07-29T12:45:00Z"
        }
        let mergeQueue = MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            .graphQL("GitHubMergePullRequest", mergeResponse),
        ])
        install(mergeQueue)
        let merged = try await adapter.mergePullRequest(
            mergeRequest,
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .mergePullRequest
            )
        )
        XCTAssertEqual(merged.value.state, .merged)
        let mergeInput = try XCTUnwrap(
            try XCTUnwrap(mergeQueue.payloads.last?["variables"] as? [String: Any])["input"] as? [String: Any]
        )
        XCTAssertEqual(mergeInput["expectedHeadOid"] as? String, "abcdef12")
        XCTAssertEqual(mergeInput["mergeMethod"] as? String, "SQUASH")

        let enterRequest = try queueRequest(
            accountID: authentication.account.id,
            repository: repository,
            action: .enter,
            queued: false
        )
        let enterQueue = MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            .graphQL("GitHubEnterMergeQueue", fixtures.mutation("GitHubEnterMergeQueue")),
        ])
        install(enterQueue)
        let entered = try await adapter.changeMergeQueue(
            enterRequest,
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .enterMergeQueue
            )
        )
        XCTAssertEqual(entered.value.action, .enter)

        let leaveRequest = try queueRequest(
            accountID: authentication.account.id,
            repository: repository,
            action: .leave,
            queued: true
        )
        let leaveQueue = MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight(queueEntry: true)),
            .graphQL("GitHubLeaveMergeQueue", fixtures.mutation("GitHubLeaveMergeQueue")),
        ])
        install(leaveQueue)
        let left = try await adapter.changeMergeQueue(
            leaveRequest,
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .leaveMergeQueue
            )
        )
        XCTAssertEqual(left.value.action, .leave)
        let leaveInput = try XCTUnwrap(
            try XCTUnwrap(leaveQueue.payloads.last?["variables"] as? [String: Any])["input"] as? [String: Any]
        )
        XCTAssertEqual(leaveInput["id"] as? String, "pr-node")

        let deletionRequest = try headBranchDeletionRequest(
            accountID: authentication.account.id,
            repository: repository
        )
        let deleteQueue = MutationResponseQueue([
            .graphQL(
                "GitHubPullRequestMutationPreflight",
                fixtures.pullRequestPreflight(state: .merged)
            ),
            .graphQL("GitHubHeadBranchDeletionPreflight", fixtures.headBranchPreflight()),
            .graphQL("GitHubDeleteHeadBranch", fixtures.mutation("GitHubDeleteHeadBranch")),
        ])
        install(deleteQueue)
        let deleted = try await adapter.deleteHeadBranch(
            deletionRequest,
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .deleteHeadBranch
            )
        )
        XCTAssertEqual(deleted.value.branch.value, "feature/github-mutations")
    }

    func testSyncForkUsesExactGraphQLParentThenFocusedRESTEndpoint() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let parent = try ForgeRepositoryIdentity(
            forge: repository.forge,
            owner: "gitx",
            name: "gitx"
        )
        let plan = try ForgeSyncForkPlan(
            fork: repository,
            parent: parent,
            branch: ForgeRefName("master"),
            localFetchRemoteName: "origin"
        )
        let graphQLQueue = MutationResponseQueue([
            .graphQL("GitHubSyncForkPreflight", fixtures.syncPreflight()),
        ])
        install(graphQLQueue)
        let restClient = try MutationRESTClient(responses: [
            GitHubMutationHTTPResponse(
                statusCode: 200,
                headers: ["X-GitHub-Request-Id": "sync-request"],
                data: fixtures.restSyncData()
            ),
        ])
        let result = try await makeAdapter(
            authentication: authentication,
            restClient: restClient
        ).syncFork(
            accountID: authentication.account.id,
            plan: plan,
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .syncFork
            )
        )
        XCTAssertEqual(result.value.mergeType, .fastForward)
        XCTAssertEqual(result.value.parent, parent)
        let requests = await restClient.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/hbmartin/gitx/merge-upstream")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mutation-secret")
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["branch"] as? String, "master")
    }

    func testAuthorizationRequiresExactCapabilityAndExplicitUnverifiedConfirmation() throws {
        let authentication = try makeAuthentication(source: .fineGrainedPersonalAccessToken)
        let repository = try makeRepository()
        let key = ForgeCapabilityKey(
            credential: authentication.credential.reference,
            repository: repository,
            operation: .createPullRequest
        )
        XCTAssertNoThrow(try GitHubMutationAuthorization(
            key: key,
            capability: .verified(.knownAuthority)
        ))
        XCTAssertThrowsError(try GitHubMutationAuthorization(
            key: key,
            capability: .verified(.knownAuthority),
            explicitConfirmation: ForgeExplicitCapabilityConfirmation(
                attempt: XCTUnwrap(unverifiedAttempt(
                    authentication: authentication,
                    repository: repository,
                    operation: .createPullRequest
                ))
            )
        )) { XCTAssertEqual($0 as? GitHubMutationError, .authorizationMismatch) }
        XCTAssertThrowsError(try GitHubMutationAuthorization(
            key: key,
            capability: .unavailable(.knownOperationRestriction)
        )) { XCTAssertEqual($0 as? GitHubMutationError, .capabilityUnavailable) }

        let capability = try unverifiedCapability(
            authentication: authentication,
            repository: repository,
            operation: .createPullRequest
        )
        guard case let .unverifiedWrite(attempt) = capability else {
            return XCTFail("Expected Unverified Write")
        }
        XCTAssertThrowsError(try GitHubMutationAuthorization(
            key: key,
            capability: .unverifiedWrite(attempt)
        )) { XCTAssertEqual($0 as? GitHubMutationError, .explicitConfirmationRequired) }
        let confirmation = ForgeExplicitCapabilityConfirmation(attempt: attempt)
        XCTAssertNoThrow(try GitHubMutationAuthorization(
            key: key,
            capability: .unverifiedWrite(attempt),
            explicitConfirmation: confirmation
        ))

        let otherCapability = try unverifiedCapability(
            authentication: authentication,
            repository: repository,
            operation: .editPullRequest
        )
        guard case let .unverifiedWrite(otherAttempt) = otherCapability else {
            return XCTFail("Expected other Unverified Write")
        }
        XCTAssertThrowsError(try GitHubMutationAuthorization(
            key: key,
            capability: .unverifiedWrite(attempt),
            explicitConfirmation: ForgeExplicitCapabilityConfirmation(attempt: otherAttempt)
        )) { XCTAssertEqual($0 as? GitHubMutationError, .explicitConfirmationRequired) }
    }

    func testAdapterRejectsMismatchedAuthorizationAndNonGitHubDotComRepositoryBeforeNetwork() async throws {
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let form = try creationForm(repository: repository)
        let wrongAuthorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .editPullRequest
        )
        await XCTAssertThrowsMutationError(.authorizationMismatch) {
            try await self.makeAdapter(authentication: authentication).createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: wrongAuthorization
            )
        }

        let enterprise = try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.example.com")),
            owner: "hbmartin",
            name: "gitx"
        )
        let enterpriseForm = try creationForm(repository: enterprise)
        let enterpriseAuthorization = try authorization(
            authentication: authentication,
            repository: enterprise,
            operation: .createPullRequest
        )
        await XCTAssertThrowsMutationError(.githubDotComRequired) {
            try await self.makeAdapter(authentication: authentication).createPullRequest(
                accountID: authentication.account.id,
                form: enterpriseForm,
                authorization: enterpriseAuthorization
            )
        }
    }

    func testMissingCurrentAuthenticationFailsBeforeNetwork() async throws {
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let adapter = makeAdapter(
            expectedCredential: authentication.credential.reference,
            authentication: nil
        )
        await XCTAssertThrowsMutationError(.authenticationRequired) {
            try await adapter.createPullRequest(
                accountID: authentication.account.id,
                form: self.creationForm(repository: repository),
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .createPullRequest
                )
            )
        }
    }

    func testSharedExactCredentialSessionGateBlocksEveryMutationPathOfflineAndDuringCooldown() async throws {
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let gate = GitHubMutationSessionGate()
        let adapter = makeAdapter(authentication: authentication, sessionGate: gate)
        await gate.setOffline(true)
        await XCTAssertThrowsMutationError(.offline) {
            try await adapter.createPullRequest(
                accountID: authentication.account.id,
                form: self.creationForm(repository: repository),
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .createPullRequest
                )
            )
        }
        await XCTAssertThrowsMutationError(.offline) {
            try await adapter.publishInlineReview(
                ForgeInlineReviewPublication(
                    accountID: authentication.account.id,
                    repository: repository,
                    pullRequest: ForgeItemNumber(7),
                    displayedHead: ForgeCommitID("abcdef12"),
                    anchor: ForgeReviewAnchor(
                        path: ForgeFilePath("A.swift"),
                        subject: .line,
                        side: .right,
                        line: 1
                    ),
                    bodyMarkdown: "Review"
                ),
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .publishInlineReviewComment
                )
            )
        }

        await gate.setOffline(false)
        let deadline = Date(timeIntervalSince1970: 4_100_000_000)
        await gate.recordCooldown(for: authentication.credential.reference, until: deadline)
        await XCTAssertThrowsMutationError(.cooldown(until: deadline)) {
            try await adapter.createPullRequest(
                accountID: authentication.account.id,
                form: self.creationForm(repository: repository),
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .createPullRequest
                )
            )
        }
        let otherCredential = try ForgeCredentialReference(
            accountID: authentication.account.id,
            credentialID: ForgeCredentialID("other"),
            generation: ForgeCredentialGeneration(1)
        )
        let otherEnvironment = await gate.environment(
            for: otherCredential,
            at: Date(timeIntervalSince1970: 1_775_000_000)
        )
        XCTAssertEqual(otherEnvironment, .available)
        await gate.recordCooldown(for: otherCredential, until: nil)
        await gate.recordCooldown(
            for: otherCredential,
            until: Date(timeIntervalSince1970: 100)
        )
        let expiredEnvironment = await gate.environment(
            for: otherCredential,
            at: Date(timeIntervalSince1970: 101)
        )
        XCTAssertEqual(expiredEnvironment, .available)
    }

    func testCredentialSessionGateClearsOnlyAfterSuccessfulRetryFromCurrentCooldownGeneration() async throws {
        let credential = try makeAuthentication().credential.reference
        let otherCredential = try ForgeCredentialReference(
            accountID: credential.accountID,
            credentialID: ForgeCredentialID("other-cooldown"),
            generation: ForgeCredentialGeneration(1)
        )
        let gate = GitHubMutationSessionGate()
        let firstDeadline = Date(timeIntervalSince1970: 100)
        let initialState = await gate.retainedCooldownState(for: credential, at: firstDeadline)
        XCTAssertEqual(initialState, .none)
        await gate.recordCooldown(for: credential, until: firstDeadline)
        let waitingState = await gate.retainedCooldownState(
            for: credential,
            at: Date(timeIntervalSince1970: 99)
        )
        XCTAssertEqual(waitingState, .waiting(until: firstDeadline))
        let otherState = await gate.retainedCooldownState(for: otherCredential, at: firstDeadline)
        XCTAssertEqual(otherState, .none)

        guard case let .allowed(firstRetry) = await gate.admitRequest(
            for: credential,
            at: firstDeadline
        ) else {
            return XCTFail("the supplied reset deadline should admit a retry")
        }
        let retainedEnvironment = await gate.environment(for: credential, at: firstDeadline)
        XCTAssertEqual(
            retainedEnvironment,
            .available,
            "deadline expiry admits traffic without discarding retry state"
        )
        let retainedDeadline = await gate.retainedCooldownDeadline(for: credential)
        XCTAssertEqual(
            retainedDeadline,
            firstDeadline,
            "account rebinding remains gated until the admitted retry succeeds"
        )
        let retryPendingState = await gate.retainedCooldownState(for: credential, at: firstDeadline)
        XCTAssertEqual(retryPendingState, .retryPending(deadline: firstDeadline))

        let extendedDeadline = Date(timeIntervalSince1970: 200)
        await gate.recordCooldown(for: credential, until: extendedDeadline)
        await gate.recordCooldown(
            for: credential,
            until: Date(timeIntervalSince1970: 175)
        )
        await gate.recordSuccessfulRequest(firstRetry)
        let extendedEnvironment = await gate.environment(
            for: credential,
            at: Date(timeIntervalSince1970: 150)
        )
        XCTAssertEqual(
            extendedEnvironment,
            .rateLimited(until: extendedDeadline),
            "an older in-flight success must not clear a newer throttle"
        )
        let extendedState = await gate.retainedCooldownState(
            for: credential,
            at: Date(timeIntervalSince1970: 150)
        )
        XCTAssertEqual(extendedState, .waiting(until: extendedDeadline))

        guard case let .allowed(currentRetry) = await gate.admitRequest(
            for: credential,
            at: extendedDeadline
        ) else {
            return XCTFail("the extended deadline should admit its own retry")
        }
        await gate.recordSuccessfulRequest(currentRetry)
        let clearedDeadline = await gate.retainedCooldownDeadline(for: credential)
        XCTAssertNil(clearedDeadline)
        let clearedEnvironment = await gate.environment(
            for: credential,
            at: Date(timeIntervalSince1970: 150)
        )
        XCTAssertEqual(
            clearedEnvironment,
            .available,
            "only a successful retry that observed the current cooldown resets it"
        )
    }

    func testCredentialSessionGatePublishesExactCredentialCooldownTransitions() async throws {
        let credential = try makeAuthentication().credential.reference
        let gate = GitHubMutationSessionGate()
        let changes = await gate.cooldownChanges()
        let received = Task { () -> [ForgeCredentialReference] in
            var iterator = changes.makeAsyncIterator()
            var values: [ForgeCredentialReference] = []
            while values.count < 2, let value = await iterator.next() {
                values.append(value)
            }
            return values
        }

        await gate.recordCooldown(
            for: credential,
            until: Date(timeIntervalSince1970: 100)
        )
        await gate.recordCooldown(for: credential, until: nil)

        let values = await received.value
        XCTAssertEqual(values, [credential, credential])
    }

    func testCredentialSessionGateTerminatesCancelledCooldownObserver() async throws {
        let credential = try makeAuthentication().credential.reference
        let gate = GitHubMutationSessionGate()
        let cancelledChanges = await gate.cooldownChanges()
        let cancelledObserver = Task { () -> ForgeCredentialReference? in
            var iterator = cancelledChanges.makeAsyncIterator()
            return await iterator.next()
        }

        await Task.yield()
        cancelledObserver.cancel()
        let cancelledValue = await cancelledObserver.value
        XCTAssertNil(cancelledValue)

        let activeChanges = await gate.cooldownChanges()
        let activeObserver = Task { () -> ForgeCredentialReference? in
            var iterator = activeChanges.makeAsyncIterator()
            return await iterator.next()
        }
        await gate.recordCooldown(
            for: credential,
            until: Date(timeIntervalSince1970: 100)
        )

        let activeValue = await activeObserver.value
        XCTAssertEqual(activeValue, credential)
    }

    func testFreshMergeSnapshotCarriesCheckWarningsAndMergeRefetchesConfirmation() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        var pending = fixtures.pullRequestPreflight()
        try fixtures.updatePullRequest(in: &pending) {
            $0["statusCheckRollup"] = [
                "__typename": "StatusCheckRollup",
                "state": "PENDING",
            ]
        }
        var mergedResponse = fixtures.mutation("GitHubMergePullRequest")
        try fixtures.updatePullRequest(in: &mergedResponse) { $0["state"] = "MERGED" }
        let queue = MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", pending),
            .graphQL("GitHubPullRequestMutationPreflight", pending),
            .graphQL("GitHubMergePullRequest", mergedResponse),
        ])
        install(queue)
        let adapter = makeAdapter(authentication: authentication)
        let authorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .mergePullRequest
        )
        let fresh = try await adapter.freshMergeSnapshot(
            accountID: authentication.account.id,
            repository: repository,
            pullRequest: ForgeItemNumber(7),
            authorization: authorization
        )
        XCTAssertEqual(fresh.warnings, [.checksPending])
        guard case let .available(confirmation) = ForgePullRequestMergePolicy.confirmationDecision(
            snapshot: fresh,
            method: .squash
        ) else {
            return XCTFail("Expected merge confirmation")
        }
        _ = try await adapter.mergePullRequest(
            ForgePullRequestMergeRequest(confirmation: confirmation),
            authorization: authorization
        )
        XCTAssertEqual(queue.remainingCount, 0)
        XCTAssertEqual(
            queue.payloads.filter { $0["operationName"] as? String == "GitHubPullRequestMutationPreflight" }.count,
            2
        )

        var failing = fixtures.pullRequestPreflight()
        try fixtures.updatePullRequest(in: &failing) {
            $0["statusCheckRollup"] = [
                "__typename": "StatusCheckRollup",
                "state": "FAILURE",
            ]
        }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", failing),
        ]))
        let failingSnapshot = try await adapter.freshMergeSnapshot(
            accountID: authentication.account.id,
            repository: repository,
            pullRequest: ForgeItemNumber(7),
            authorization: authorization
        )
        XCTAssertEqual(failingSnapshot.warnings, [.checksFailing])
    }

    func testFreshHeadDeletionSnapshotCarriesAllAuthoritativeServerSafetyFacts() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let queue = MutationResponseQueue([
            .graphQL(
                "GitHubPullRequestMutationPreflight",
                fixtures.pullRequestPreflight(state: .merged)
            ),
            .graphQL("GitHubHeadBranchDeletionPreflight", fixtures.headBranchPreflight()),
        ])
        install(queue)
        let snapshot = try await makeAdapter(authentication: authentication)
            .freshHeadBranchDeletionSnapshot(
                accountID: authentication.account.id,
                repository: repository,
                pullRequest: ForgeItemNumber(7),
                branch: ForgeRefName("feature/github-mutations"),
                expectedHead: ForgeCommitID("abcdef12"),
                hasCheckedOutSafetyConflict: true,
                authorization: authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .deleteHeadBranch
                )
            )
        XCTAssertEqual(snapshot.mergeSnapshot.context.state, .merged)
        XCTAssertTrue(snapshot.isSameRepository)
        XCTAssertFalse(snapshot.isDefaultBranch)
        XCTAssertFalse(snapshot.isProtected)
        XCTAssertTrue(snapshot.viewerCanDelete)
        XCTAssertTrue(snapshot.hasCheckedOutSafetyConflict)
        XCTAssertEqual(queue.remainingCount, 0)
    }

    func testResolutionTransitionGateSerializesGenerationsForOneThread() async throws {
        let authentication = try makeAuthentication()
        let adapter = makeAdapter(authentication: authentication)
        let threadID = try ForgeObjectID(forge: makeRepository().forge, value: "thread-node")
        let first = await adapter.acquireResolutionTransition(for: threadID)
        XCTAssertEqual(first, 1)
        let waiting = Task { await adapter.acquireResolutionTransition(for: threadID) }
        var isQueued = false
        for _ in 0 ..< 1000 {
            isQueued = await adapter.hasQueuedResolutionTransition(for: threadID)
            if isQueued {
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(isQueued)
        await adapter.releaseResolutionTransition(for: threadID, generation: first)
        let second = await waiting.value
        XCTAssertEqual(second, 2)
        await adapter.releaseResolutionTransition(for: threadID, generation: second)
        let remainsQueued = await adapter.hasQueuedResolutionTransition(for: threadID)
        XCTAssertFalse(remainsQueued)
    }

    func testProviderNeutralUIMapperPreservesAuthoritativeAndUnknownOutcomes() throws {
        let metadata = GitHubResponseMetadata(
            statusCode: 422,
            rateLimit: GitHubRateLimitMetadata(
                limit: nil,
                remaining: nil,
                used: nil,
                resetAt: nil,
                retryAt: nil,
                resource: nil
            )
        )
        let authoritative: Result<GitHubMutationResult<Int>, Error> = .failure(
            GitHubMutationError.authoritative([
                GitHubMutationProblem(authoritativeMessage: "Branch policy denied the merge."),
            ], metadata)
        )
        guard case let .authoritativeFailure(message) = GitHubMutationUIMapper.outcome(authoritative) else {
            return XCTFail("Expected authoritative provider-neutral result")
        }
        XCTAssertEqual(message, "Branch policy denied the merge.")
        let emptyAuthoritative: Result<GitHubMutationResult<Int>, Error> = .failure(
            GitHubMutationError.authoritative([], metadata)
        )
        guard case let .authoritativeFailure(fallback) = GitHubMutationUIMapper.outcome(emptyAuthoritative) else {
            return XCTFail("Expected authoritative fallback")
        }
        XCTAssertEqual(fallback, "GitHub rejected this operation.")
        let unknown: Result<GitHubMutationResult<Int>, Error> = .failure(
            GitHubMutationError.outcomeUnknown(metadata)
        )
        guard case .outcomeUnknown = GitHubMutationUIMapper.outcome(unknown) else {
            return XCTFail("Expected provider-neutral unknown outcome")
        }
        let repository = try makeRepository()
        let authentication = try makeAuthentication()
        let success = GitHubMutationResult(
            value: 7,
            response: metadata,
            ownership: GitHubMutationOwnership(
                credential: authentication.credential.reference,
                repository: repository,
                operation: .mergePullRequest
            )
        )
        guard case let .succeeded(value) = GitHubMutationUIMapper.outcome(.success(success)), value == 7 else {
            return XCTFail("Expected provider-neutral success")
        }
        let deadline = Date(timeIntervalSince1970: 4_100_000_000)
        let cases: [(GitHubMutationError, String)] = [
            (.offline, "offline"),
            (.cooldown(until: deadline), "cooldown"),
            (.rateLimited(metadata), "cooldown"),
            (.capabilityUnavailable, "capability"),
            (.permissionDenied(metadata), "permission"),
            (.samlAuthorizationRequired(metadata), "permission"),
            (.authenticationRequired, "authentication"),
            (.authorizationMismatch, "authentication"),
            (.explicitConfirmationRequired, "authentication"),
            (.githubDotComRequired, "authentication"),
            (.stalePullRequest, "stale"),
            (.objectNotFound, "stale"),
            (.invalidRequest, "stale"),
            (.malformedResponse, "stale"),
            (.transportFailure, "stale"),
        ]
        for (error, expected) in cases {
            let mapped: ForgeMutationPresentationOutcome<Int> = GitHubMutationUIMapper.outcome(.failure(error))
            let actual = switch mapped {
            case .offline: "offline"
            case .cooldown: "cooldown"
            case .capabilityUnavailable: "capability"
            case .permissionDenied: "permission"
            case .authenticationRequired: "authentication"
            case .stale: "stale"
            default: "unexpected"
            }
            XCTAssertEqual(actual, expected)
        }
        enum UnrelatedError: Error { case failed }
        guard case .stale = GitHubMutationUIMapper.outcome(
            Result<GitHubMutationResult<Int>, Error>.failure(UnrelatedError.failed)
        ) else {
            return XCTFail("Expected unrelated errors to fail closed")
        }
    }

    func testAuthoritativeGraphQLErrorIsSafeAndRateLimitIsClassified() async throws {
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let form = try creationForm(repository: repository)
        let deniedQueue = MutationResponseQueue([
            .graphQLPayload(
                "GitHubPullRequestCreationPreflight",
                [
                    "errors": [[
                        "message": "Branch rule blocks update",
                        "path": ["repository"],
                        "extensions": ["type": "FORBIDDEN"],
                    ]],
                ]
            ),
        ])
        install(deniedQueue)
        do {
            _ = try await makeAdapter(authentication: authentication).createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .createPullRequest
                )
            )
            XCTFail("Expected authoritative failure")
        } catch let error as GitHubMutationError {
            guard case let .authoritative(problems, metadata) = error else {
                return XCTFail("Unexpected \(error)")
            }
            XCTAssertEqual(error.errorDescription, "Branch rule blocks update")
            XCTAssertFalse(String(describing: error).contains("Branch rule blocks update"))
            XCTAssertEqual(problems.first?.path, ["repository"])
            XCTAssertEqual(problems.first?.classification, "FORBIDDEN")
            XCTAssertEqual(metadata.requestID, "mutation-fixture")
        }

        let rateQueue = MutationResponseQueue([
            .graphQLPayload(
                "GitHubPullRequestCreationPreflight",
                [
                    "errors": [[
                        "message": "API rate limit exceeded",
                        "extensions": ["type": "RATE_LIMITED"],
                    ]],
                ]
            ),
        ])
        install(rateQueue)
        do {
            _ = try await makeAdapter(authentication: authentication).createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .createPullRequest
                )
            )
            XCTFail("Expected rate limit")
        } catch let error as GitHubMutationError {
            guard case let .rateLimited(metadata) = error else {
                return XCTFail("Unexpected \(error)")
            }
            XCTAssertEqual(metadata.statusCode, 200)
        }
    }

    func testMutationResponseErrorsTransportAndUnexpectedStateBecomeUnknown() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let form = try creationForm(repository: repository)
        let authorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .createPullRequest
        )
        let adapter = makeAdapter(authentication: authentication)

        let partialQueue = MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", fixtures.creationPreflight()),
            .graphQLPayload(
                "GitHubCreatePullRequest",
                [
                    "data": fixtures.mutation("GitHubCreatePullRequest"),
                    "errors": [["message": "Server reported a partial mutation"]],
                ]
            ),
        ])
        install(partialQueue)
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: authorization
            )
        }

        for code in [URLError.Code.cancelled, .notConnectedToInternet] {
            let queue = MutationResponseQueue([
                .graphQL("GitHubPullRequestCreationPreflight", fixtures.creationPreflight()),
                .failure("GitHubCreatePullRequest", code: code),
            ])
            install(queue)
            await XCTAssertThrowsUnknownOutcome {
                try await self.makeAdapter(authentication: authentication).createPullRequest(
                    accountID: authentication.account.id,
                    form: form,
                    authorization: authorization
                )
            }
        }

        let cancelledQueue = MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", fixtures.creationPreflight()),
            .cancellation("GitHubCreatePullRequest"),
        ])
        install(cancelledQueue)
        await XCTAssertThrowsUnknownOutcome {
            try await self.makeAdapter(authentication: authentication).createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: authorization
            )
        }

        let transportQueue = MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", fixtures.creationPreflight()),
            .failure("GitHubCreatePullRequest", code: .timedOut),
        ])
        install(transportQueue)
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: authorization
            )
        }

        var wrongState = fixtures.mutation("GitHubCreatePullRequest")
        try fixtures.updatePullRequest(in: &wrongState) { $0["title"] = "Unexpected title" }
        let reconciliationQueue = MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", fixtures.creationPreflight()),
            .graphQL("GitHubCreatePullRequest", wrongState),
        ])
        install(reconciliationQueue)
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: authorization
            )
        }
    }

    func testStaleLifecycleStopsAfterFreshPreflight() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        var stale = fixtures.pullRequestPreflight(isDraft: true)
        try fixtures.updatePullRequest(in: &stale) { $0["headRefOid"] = "abcdef99" }
        let queue = MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", stale),
        ])
        install(queue)
        let request = try lifecycleRequest(
            accountID: authentication.account.id,
            repository: repository,
            action: .markReady,
            state: .open,
            isDraft: true
        )
        await XCTAssertThrowsMutationError(.stalePullRequest) {
            try await self.makeAdapter(authentication: authentication).performLifecycle(
                request,
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .markPullRequestReady
                )
            )
        }
        XCTAssertEqual(queue.remainingCount, 0)
    }

    func testRESTAuthoritativeRateLimitUnknownAndMalformedResponsesAreClassified() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let parent = try ForgeRepositoryIdentity(
            forge: repository.forge,
            owner: "gitx",
            name: "gitx"
        )
        let plan = try ForgeSyncForkPlan(
            fork: repository,
            parent: parent,
            branch: ForgeRefName("master"),
            localFetchRemoteName: "origin"
        )
        let authorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .syncFork
        )
        let cases: [(GitHubMutationHTTPResponse, RESTExpectation)] = [
            (
                GitHubMutationHTTPResponse(
                    statusCode: 403,
                    headers: ["X-RateLimit-Remaining": "0", "Retry-After": "60"],
                    data: Data()
                ),
                .rateLimited
            ),
            (
                GitHubMutationHTTPResponse(
                    statusCode: 409,
                    headers: ["X-GitHub-Request-Id": "rest-denied"],
                    data: Data(#"{"message":"Fork cannot be synced"}"#.utf8)
                ),
                .authoritative("Fork cannot be synced")
            ),
            (
                GitHubMutationHTTPResponse(
                    statusCode: 429,
                    headers: ["Retry-After": "60"],
                    data: Data()
                ),
                .rateLimited
            ),
            (
                GitHubMutationHTTPResponse(
                    statusCode: 429,
                    headers: ["Retry-After": "Thu, 30 Jul 2099 15:00:00 GMT"],
                    data: Data()
                ),
                .rateLimited
            ),
            (
                GitHubMutationHTTPResponse(statusCode: 408, headers: [:], data: Data()),
                .unknown
            ),
            (
                GitHubMutationHTTPResponse(statusCode: 503, headers: [:], data: Data()),
                .unknown
            ),
            (
                GitHubMutationHTTPResponse(statusCode: 200, headers: [:], data: Data("{}".utf8)),
                .unknown
            ),
        ]
        for (response, expectation) in cases {
            let queue = MutationResponseQueue([
                .graphQL("GitHubSyncForkPreflight", fixtures.syncPreflight()),
            ])
            install(queue)
            let adapter = makeAdapter(
                authentication: authentication,
                restClient: MutationRESTClient(responses: [response])
            )
            do {
                _ = try await adapter.syncFork(
                    accountID: authentication.account.id,
                    plan: plan,
                    authorization: authorization
                )
                XCTFail("Expected REST classification")
            } catch let error as GitHubMutationError {
                switch (expectation, error) {
                case let (.authoritative(message), .authoritative(problems, _)):
                    XCTAssertEqual(problems.first?.authoritativeMessage, message)
                    XCTAssertFalse(String(describing: error).contains(message))
                case (.rateLimited, .rateLimited), (.unknown, .outcomeUnknown):
                    break
                default:
                    XCTFail("Unexpected \(error) for \(expectation)")
                }
            }
        }
    }

    func testEveryMutationErrorAndProblemTextualSurfaceIsSafe() {
        let metadata = GitHubResponseMetadata(
            statusCode: 403,
            requestID: "safe-request",
            rateLimit: GitHubRateLimitMetadata(
                limit: 5000,
                remaining: 0,
                used: 5000,
                resetAt: nil,
                retryAt: nil,
                resource: "graphql"
            ),
            saml: nil
        )
        let problem = GitHubMutationProblem(
            authoritativeMessage: "Sensitive authoritative detail",
            path: ["repository", "pullRequest"],
            classification: "FORBIDDEN"
        )
        XCTAssertFalse(problem.description.contains(problem.authoritativeMessage))
        XCTAssertEqual(problem.debugDescription, problem.description)
        XCTAssertEqual(problem.customMirror.children.count, 0)
        let errors: [GitHubMutationError] = [
            .githubDotComRequired,
            .authenticationRequired,
            .authorizationMismatch,
            .capabilityUnavailable,
            .explicitConfirmationRequired,
            .invalidRequest,
            .objectNotFound,
            .stalePullRequest,
            .offline,
            .cooldown(until: Date(timeIntervalSince1970: 1_775_000_000)),
            .rateLimited(metadata),
            .samlAuthorizationRequired(metadata),
            .permissionDenied(metadata),
            .authoritative([], metadata),
            .authoritative([problem], metadata),
            .malformedResponse,
            .transportFailure,
            .outcomeUnknown(nil),
        ]
        for error in errors {
            XCTAssertFalse(error.description.contains(problem.authoritativeMessage))
            XCTAssertEqual(error.debugDescription, error.description)
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
            XCTAssertEqual(error.customMirror.children.count, 0)
        }
    }

    func testConcreteRESTTransportCapsBodiesRejectsNonHTTPAndPreservesHeaders() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMutationURLProtocol.self]
        let client = GitHubMutationURLSessionClient(configuration: configuration)
        let request = try URLRequest(url: XCTUnwrap(URL(string: "https://api.github.com/repos/o/r/merge-upstream")))

        GitHubMutationURLProtocol.setHandler { _ in
            MutationStubResponse(
                operationName: "",
                statusCode: 200,
                headers: ["Content-Length": "2", "X-GitHub-Request-Id": "rest-small"],
                body: Data("{}".utf8),
                failureCode: nil,
                cancellationFailure: false
            )
        }
        let response = try await client.execute(request)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["X-GitHub-Request-Id"], "rest-small")
        XCTAssertEqual(response.data, Data("{}".utf8))

        GitHubMutationURLProtocol.setHandler { _ in
            MutationStubResponse(
                operationName: "",
                statusCode: 200,
                headers: ["X-GitHub-Request-Id": "rest-large"],
                body: Data(repeating: 0x61, count: GitHubMutationURLSessionClient.maximumResponseBytes + 1),
                failureCode: nil,
                cancellationFailure: false
            )
        }
        await XCTAssertThrowsUnknownOutcome {
            try await client.execute(request)
        }

        let nonHTTPConfiguration = URLSessionConfiguration.ephemeral
        nonHTTPConfiguration.protocolClasses = [MutationNonHTTPURLProtocol.self]
        let nonHTTPClient = GitHubMutationURLSessionClient(configuration: nonHTTPConfiguration)
        await XCTAssertThrowsMutationError(.transportFailure) {
            try await nonHTTPClient.execute(request)
        }
    }

    func testMapperFailureAndWarningBranchesStayFailClosed() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let request = try makeMergeRequest(
            accountID: authentication.account.id,
            repository: repository
        )
        let authorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .mergePullRequest
        )
        for (mergeable, reviewDecision) in [
            ("CONFLICTING", "CHANGES_REQUESTED"),
            ("UNKNOWN", "REVIEW_REQUIRED"),
        ] {
            var preflight = fixtures.pullRequestPreflight()
            try fixtures.updatePullRequest(in: &preflight) {
                $0["mergeable"] = mergeable
                $0["reviewDecision"] = reviewDecision
            }
            var repositoryData = try XCTUnwrap(preflight["repository"] as? [String: Any])
            repositoryData["viewerPermission"] = "READ"
            repositoryData["mergeCommitAllowed"] = false
            repositoryData["squashMergeAllowed"] = false
            repositoryData["rebaseMergeAllowed"] = false
            preflight["repository"] = repositoryData
            install(MutationResponseQueue([
                .graphQL("GitHubPullRequestMutationPreflight", preflight),
            ]))
            await XCTAssertThrowsMutationError(.stalePullRequest) {
                try await self.makeAdapter(authentication: authentication).mergePullRequest(
                    request,
                    authorization: authorization
                )
            }
        }

        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", ["repository": NSNull()]),
        ]))
        await XCTAssertThrowsMutationError(.objectNotFound) {
            try await self.makeAdapter(authentication: authentication).mergePullRequest(
                request,
                authorization: authorization
            )
        }
    }

    func testCreationMapperRejectsMissingObjectsIncompletePaginationAndMalformedSnapshots() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let form = try creationForm(repository: repository)
        let authorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .createPullRequest
        )
        let adapter = makeAdapter(authentication: authentication)

        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", [
                "repository": NSNull(),
                "headRepository": NSNull(),
            ]),
        ]))
        await XCTAssertThrowsMutationError(.objectNotFound) {
            try await adapter.createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: authorization
            )
        }

        var incompletePage = fixtures.creationPreflight()
        var incompleteRepository = try XCTUnwrap(incompletePage["repository"] as? [String: Any])
        var incompleteConnection = try XCTUnwrap(incompleteRepository["pullRequests"] as? [String: Any])
        incompleteConnection["pageInfo"] = MutationFixtures.pageInfo(hasNextPage: true, endCursor: nil)
        incompleteRepository["pullRequests"] = incompleteConnection
        incompletePage["repository"] = incompleteRepository
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", incompletePage),
        ]))
        await XCTAssertThrowsMutationError(.malformedResponse) {
            try await adapter.createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: authorization
            )
        }

        var malformedSnapshotPage = fixtures.creationPreflight()
        var malformedRepository = try XCTUnwrap(malformedSnapshotPage["repository"] as? [String: Any])
        var malformedConnection = try XCTUnwrap(malformedRepository["pullRequests"] as? [String: Any])
        var malformedPullRequest = fixtures.pullRequest()
        var wrongBase = try XCTUnwrap(malformedPullRequest["baseRepository"] as? [String: Any])
        wrongBase["nameWithOwner"] = "other/gitx"
        var wrongOwner = try XCTUnwrap(wrongBase["owner"] as? [String: Any])
        wrongOwner["login"] = "other"
        wrongBase["owner"] = wrongOwner
        malformedPullRequest["baseRepository"] = wrongBase
        malformedConnection["nodes"] = [malformedPullRequest]
        malformedRepository["pullRequests"] = malformedConnection
        malformedSnapshotPage["repository"] = malformedRepository
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", malformedSnapshotPage),
        ]))
        await XCTAssertThrowsMutationError(.malformedResponse) {
            try await adapter.createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: authorization
            )
        }

        var malformedMutation = fixtures.mutation("GitHubCreatePullRequest")
        try fixtures.updatePullRequest(in: &malformedMutation) { $0["updatedAt"] = "not-a-date" }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", fixtures.creationPreflight()),
            .graphQL("GitHubCreatePullRequest", malformedMutation),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: authorization
            )
        }
    }

    func testEditConflictsCapabilityAndMutationReconciliationFailClosed() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let adapter = makeAdapter(authentication: authentication)
        let authorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .editPullRequest
        )
        let edit = try ForgePullRequestEdit(
            snapshot: editableSnapshot(repository: repository),
            title: "Edited title",
            bodyMarkdown: "Edited body"
        )

        var conflicting = fixtures.pullRequestPreflight()
        try fixtures.updatePullRequest(in: &conflicting) { $0["updatedAt"] = "2026-07-29T12:31:00Z" }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", conflicting),
        ]))
        await XCTAssertThrowsMutationError(.stalePullRequest) {
            try await adapter.editPullRequest(
                accountID: authentication.account.id,
                edit: edit,
                authorization: authorization
            )
        }

        var denied = fixtures.pullRequestPreflight()
        try fixtures.updatePullRequest(in: &denied) { $0["viewerCanUpdate"] = false }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", denied),
        ]))
        await XCTAssertThrowsMutationError(.capabilityUnavailable) {
            try await adapter.editPullRequest(
                accountID: authentication.account.id,
                edit: edit,
                authorization: authorization
            )
        }

        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            .graphQL("GitHubEditPullRequest", ["updatePullRequest": NSNull()]),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.editPullRequest(
                accountID: authentication.account.id,
                edit: edit,
                authorization: authorization
            )
        }
    }

    func testLifecycleAndMergeUnexpectedServerStatesRequireReconciliation() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let adapter = makeAdapter(authentication: authentication)
        let lifecycleCases: [(ForgePullRequestLifecycleAction, ForgePullRequestState, Bool, String)] = [
            (.markReady, .open, true, "GitHubMarkPullRequestReady"),
            (.convertToDraft, .open, false, "GitHubConvertPullRequestToDraft"),
            (.close, .open, false, "GitHubClosePullRequest"),
            (.reopen, .closed, false, "GitHubReopenPullRequest"),
        ]
        for (action, state, isDraft, operationName) in lifecycleCases {
            var response = fixtures.mutation(operationName)
            try fixtures.updatePullRequest(in: &response) {
                switch action {
                case .markReady: $0["isDraft"] = true
                case .convertToDraft: $0["isDraft"] = false
                case .close: $0["state"] = "OPEN"
                case .reopen: $0["state"] = "CLOSED"
                case .updateBranch: break
                }
            }
            install(MutationResponseQueue([
                .graphQL(
                    "GitHubPullRequestMutationPreflight",
                    fixtures.pullRequestPreflight(state: state, isDraft: isDraft)
                ),
                .graphQL(operationName, response),
            ]))
            await XCTAssertThrowsUnknownOutcome {
                try await adapter.performLifecycle(
                    self.lifecycleRequest(
                        accountID: authentication.account.id,
                        repository: repository,
                        action: action,
                        state: state,
                        isDraft: isDraft
                    ),
                    authorization: self.authorization(
                        authentication: authentication,
                        repository: repository,
                        operation: action.operation
                    )
                )
            }
        }

        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            .graphQL("GitHubMergePullRequest", fixtures.mutation("GitHubMergePullRequest")),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.mergePullRequest(
                self.makeMergeRequest(
                    accountID: authentication.account.id,
                    repository: repository
                ),
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .mergePullRequest
                )
            )
        }
    }

    func testQueueBranchAndReviewMutationResponseMismatchesBecomeUnknown() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let adapter = makeAdapter(authentication: authentication)

        let enter = try queueRequest(
            accountID: authentication.account.id,
            repository: repository,
            action: .enter,
            queued: false
        )
        let enterAuthorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .enterMergeQueue
        )
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            .graphQL("GitHubEnterMergeQueue", ["enqueuePullRequest": NSNull()]),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.changeMergeQueue(enter, authorization: enterAuthorization)
        }

        var wrongHead = fixtures.mutation("GitHubEnterMergeQueue")
        try fixtures.updatePullRequest(in: &wrongHead) { $0["headRefOid"] = "abcdef99" }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            .graphQL("GitHubEnterMergeQueue", wrongHead),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.changeMergeQueue(enter, authorization: enterAuthorization)
        }

        let leave = try queueRequest(
            accountID: authentication.account.id,
            repository: repository,
            action: .leave,
            queued: true
        )
        let leaveAuthorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .leaveMergeQueue
        )
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
        ]))
        await XCTAssertThrowsMutationError(.stalePullRequest) {
            try await adapter.changeMergeQueue(leave, authorization: leaveAuthorization)
        }

        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight(queueEntry: true)),
            .graphQL("GitHubLeaveMergeQueue", ["dequeuePullRequest": NSNull()]),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.changeMergeQueue(leave, authorization: leaveAuthorization)
        }

        var wrongEntry = fixtures.mutation("GitHubLeaveMergeQueue")
        try fixtures.updateDictionary(named: "mergeQueueEntry", in: &wrongEntry) { $0["id"] = "other-entry" }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight(queueEntry: true)),
            .graphQL("GitHubLeaveMergeQueue", wrongEntry),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.changeMergeQueue(leave, authorization: leaveAuthorization)
        }

        var wrongRepository = fixtures.mutation("GitHubLeaveMergeQueue")
        try fixtures.updatePullRequest(in: &wrongRepository) { pullRequest in
            var repository = pullRequest["repository"] as! [String: Any]
            var owner = repository["owner"] as! [String: Any]
            owner["login"] = "other"
            repository["owner"] = owner
            repository["nameWithOwner"] = "other/gitx"
            pullRequest["repository"] = repository
        }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight(queueEntry: true)),
            .graphQL("GitHubLeaveMergeQueue", wrongRepository),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.changeMergeQueue(leave, authorization: leaveAuthorization)
        }

        let deletion = try headBranchDeletionRequest(
            accountID: authentication.account.id,
            repository: repository
        )
        install(MutationResponseQueue([
            .graphQL(
                "GitHubPullRequestMutationPreflight",
                fixtures.pullRequestPreflight(state: .merged)
            ),
            .graphQL("GitHubHeadBranchDeletionPreflight", fixtures.headBranchPreflight()),
            .graphQL("GitHubDeleteHeadBranch", ["deleteRef": NSNull()]),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.deleteHeadBranch(
                deletion,
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .deleteHeadBranch
                )
            )
        }

        var defaultBranch = fixtures.headBranchPreflight()
        try fixtures.updateDictionary(named: "defaultBranchRef", in: &defaultBranch) {
            $0["name"] = "feature/github-mutations"
        }
        install(MutationResponseQueue([
            .graphQL(
                "GitHubPullRequestMutationPreflight",
                fixtures.pullRequestPreflight(state: .merged)
            ),
            .graphQL("GitHubHeadBranchDeletionPreflight", defaultBranch),
        ]))
        await XCTAssertThrowsMutationError(.stalePullRequest) {
            try await adapter.deleteHeadBranch(
                deletion,
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .deleteHeadBranch
                )
            )
        }

        let number = try ForgeItemNumber(7)
        let head = try ForgeCommitID("abcdef12")
        let inline = try ForgeInlineReviewPublication(
            accountID: authentication.account.id,
            repository: repository,
            pullRequest: number,
            displayedHead: head,
            anchor: ForgeReviewAnchor(
                path: ForgeFilePath("Sources/App.swift"),
                subject: .line,
                side: .right,
                line: 6
            ),
            bodyMarkdown: "Please simplify."
        )
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            .graphQL("GitHubPublishInlineReview", ["addPullRequestReviewThread": NSNull()]),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.publishInlineReview(
                inline,
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .publishInlineReviewComment
                )
            )
        }

        let reply = try ForgeReviewThreadReplyPublication(
            accountID: authentication.account.id,
            repository: repository,
            pullRequest: number,
            threadID: ForgeObjectID(forge: repository.forge, value: "thread-node"),
            bodyMarkdown: "Done."
        )
        install(MutationResponseQueue([
            .graphQL("GitHubReviewThreadMutationPreflight", fixtures.threadPreflight()),
            .graphQL("GitHubReplyToReviewThread", ["addPullRequestReviewThreadReply": NSNull()]),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.replyToReviewThread(
                reply,
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .replyToReviewThread
                )
            )
        }
    }

    func testSyncTransportAndRemainingRESTClassificationsAreExplicit() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let plan = try syncPlan(repository: repository)
        let authorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .syncFork
        )

        for failure in [MutationRESTFailure.cancelled, .known, .unknown, .offline, .timedOut] {
            install(MutationResponseQueue([
                .graphQL("GitHubSyncForkPreflight", fixtures.syncPreflight()),
            ]))
            let adapter = makeAdapter(
                authentication: authentication,
                restClient: MutationThrowingRESTClient(failure: failure)
            )
            do {
                _ = try await adapter.syncFork(
                    accountID: authentication.account.id,
                    plan: plan,
                    authorization: authorization
                )
                XCTFail("Expected transport failure")
            } catch let error as GitHubMutationError {
                switch error {
                case .outcomeUnknown:
                    break
                default:
                    XCTFail("Unexpected \(error) for \(failure)")
                }
            }
        }

        let cases: [(GitHubMutationHTTPResponse, GitHubMutationError)] = [
            (
                GitHubMutationHTTPResponse(statusCode: 401, headers: [:], data: Data()),
                .authenticationRequired
            ),
            (
                GitHubMutationHTTPResponse(statusCode: 403, headers: [:], data: Data()),
                .permissionDenied(GitHubResponseMetadata(
                    statusCode: 403,
                    rateLimit: GitHubRateLimitMetadata(
                        limit: nil,
                        remaining: nil,
                        used: nil,
                        resetAt: nil,
                        retryAt: nil,
                        resource: nil
                    )
                ))
            ),
            (
                GitHubMutationHTTPResponse(statusCode: 404, headers: [:], data: Data()),
                .permissionDenied(GitHubResponseMetadata(
                    statusCode: 404,
                    rateLimit: GitHubRateLimitMetadata(
                        limit: nil,
                        remaining: nil,
                        used: nil,
                        resetAt: nil,
                        retryAt: nil,
                        resource: nil
                    )
                ))
            ),
        ]
        for (response, expected) in cases {
            install(MutationResponseQueue([
                .graphQL("GitHubSyncForkPreflight", fixtures.syncPreflight()),
            ]))
            await XCTAssertThrowsMutationError(expected) {
                try await self.makeAdapter(
                    authentication: authentication,
                    restClient: MutationRESTClient(responses: [response])
                ).syncFork(
                    accountID: authentication.account.id,
                    plan: plan,
                    authorization: authorization
                )
            }
        }

        install(MutationResponseQueue([
            .graphQL("GitHubSyncForkPreflight", fixtures.syncPreflight()),
        ]))
        do {
            _ = try await makeAdapter(
                authentication: authentication,
                restClient: MutationRESTClient(responses: [
                    GitHubMutationHTTPResponse(
                        statusCode: 403,
                        headers: [
                            "X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso?request=1",
                        ],
                        data: Data()
                    ),
                ])
            ).syncFork(
                accountID: authentication.account.id,
                plan: plan,
                authorization: authorization
            )
            XCTFail("Expected SAML recovery")
        } catch let error as GitHubMutationError {
            guard case let .samlAuthorizationRequired(metadata) = error else {
                return XCTFail("Unexpected \(error)")
            }
            XCTAssertEqual(metadata.saml?.authorizationURL?.host, "github.com")
        }

        for body in [Data(), Data(#"{"message":"\n"}"#.utf8)] {
            install(MutationResponseQueue([
                .graphQL("GitHubSyncForkPreflight", fixtures.syncPreflight()),
            ]))
            do {
                _ = try await makeAdapter(
                    authentication: authentication,
                    restClient: MutationRESTClient(responses: [
                        GitHubMutationHTTPResponse(statusCode: 409, headers: [:], data: body),
                    ])
                ).syncFork(
                    accountID: authentication.account.id,
                    plan: plan,
                    authorization: authorization
                )
                XCTFail("Expected authoritative failure")
            } catch let error as GitHubMutationError {
                guard case let .authoritative(problems, _) = error else {
                    return XCTFail("Unexpected \(error)")
                }
                XCTAssertEqual(problems.first?.authoritativeMessage, "GitHub rejected this operation.")
            }
        }
    }

    func testRemainingAuthorizationCreationAndEditGuardsFailClosed() async throws {
        let fixtures = try MutationFixtures()
        let repository = try makeRepository()
        let authentication = try makeAuthentication()
        let form = try creationForm(repository: repository)
        let createAuthorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .createPullRequest
        )
        let expired = try makeAuthentication(expiresAt: Date(timeIntervalSince1970: 1))
        await XCTAssertThrowsMutationError(.authenticationRequired) {
            try await self.makeAdapter(authentication: expired).createPullRequest(
                accountID: expired.account.id,
                form: form,
                authorization: self.authorization(
                    authentication: expired,
                    repository: repository,
                    operation: .createPullRequest
                )
            )
        }

        var firstPage = fixtures.creationPreflight()
        var firstRepository = try XCTUnwrap(firstPage["repository"] as? [String: Any])
        var firstConnection = try XCTUnwrap(firstRepository["pullRequests"] as? [String: Any])
        firstConnection["pageInfo"] = MutationFixtures.pageInfo(hasNextPage: true, endCursor: "next")
        firstRepository["pullRequests"] = firstConnection
        firstPage["repository"] = firstRepository
        var secondPage = fixtures.creationPreflight()
        var secondRepository = try XCTUnwrap(secondPage["repository"] as? [String: Any])
        secondRepository["id"] = "other-repository-node"
        secondPage["repository"] = secondRepository
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", firstPage),
            .graphQL("GitHubPullRequestCreationPreflight", secondPage),
        ]))
        await XCTAssertThrowsMutationError(.authorizationMismatch) {
            try await self.makeAdapter(authentication: authentication).createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: createAuthorization
            )
        }

        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", fixtures.creationPreflight()),
            .graphQL("GitHubCreatePullRequest", ["createPullRequest": NSNull()]),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await self.makeAdapter(authentication: authentication).createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: createAuthorization
            )
        }

        let editAuthorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .editPullRequest
        )
        let edit = try ForgePullRequestEdit(
            snapshot: editableSnapshot(repository: repository),
            title: "Edited title",
            bodyMarkdown: "Edited body"
        )
        var invalidCurrent = fixtures.pullRequestPreflight()
        try fixtures.updatePullRequest(in: &invalidCurrent) { $0["title"] = "\n" }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", invalidCurrent),
        ]))
        await XCTAssertThrowsMutationError(.invalidRequest) {
            try await self.makeAdapter(authentication: authentication).editPullRequest(
                accountID: authentication.account.id,
                edit: edit,
                authorization: editAuthorization
            )
        }

        var wrongEdit = fixtures.mutation("GitHubEditPullRequest")
        try fixtures.updatePullRequest(in: &wrongEdit) {
            $0["title"] = "Different title"
            $0["body"] = "Different body"
        }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            .graphQL("GitHubEditPullRequest", wrongEdit),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await self.makeAdapter(authentication: authentication).editPullRequest(
                accountID: authentication.account.id,
                edit: edit,
                authorization: editAuthorization
            )
        }

        var wrongNumber = fixtures.mutation("GitHubEditPullRequest")
        try fixtures.updatePullRequest(in: &wrongNumber) {
            $0["number"] = 8
            $0["title"] = "Edited title"
            $0["body"] = "Edited body"
        }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            .graphQL("GitHubEditPullRequest", wrongNumber),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await self.makeAdapter(authentication: authentication).editPullRequest(
                accountID: authentication.account.id,
                edit: edit,
                authorization: editAuthorization
            )
        }
    }

    func testLifecycleMergeAndQueueDefensiveInputsStopOrReconcile() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let adapter = makeAdapter(authentication: authentication)

        let ready = try lifecycleRequest(
            accountID: authentication.account.id,
            repository: repository,
            action: .markReady,
            state: .open,
            isDraft: true
        )
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
        ]))
        await XCTAssertThrowsMutationError(.stalePullRequest) {
            try await adapter.performLifecycle(
                ready,
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .markPullRequestReady
                )
            )
        }

        for (action, state, flag) in [
            (ForgePullRequestLifecycleAction.close, ForgePullRequestState.open, "viewerCanClose"),
            (.reopen, .closed, "viewerCanReopen"),
        ] {
            var preflight = fixtures.pullRequestPreflight(state: state)
            try fixtures.updatePullRequest(in: &preflight) { $0[flag] = false }
            install(MutationResponseQueue([
                .graphQL("GitHubPullRequestMutationPreflight", preflight),
            ]))
            await XCTAssertThrowsMutationError(.capabilityUnavailable) {
                try await adapter.performLifecycle(
                    self.lifecycleRequest(
                        accountID: authentication.account.id,
                        repository: repository,
                        action: action,
                        state: state,
                        isDraft: false
                    ),
                    authorization: self.authorization(
                        authentication: authentication,
                        repository: repository,
                        operation: action.operation
                    )
                )
            }
        }

        for method in [ForgePullRequestMergeMethod.merge, .rebase] {
            var response = fixtures.mutation("GitHubMergePullRequest")
            try fixtures.updatePullRequest(in: &response) { $0["state"] = "MERGED" }
            install(MutationResponseQueue([
                .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
                .graphQL("GitHubMergePullRequest", response),
            ]))
            _ = try await adapter.mergePullRequest(
                makeMergeRequest(
                    accountID: authentication.account.id,
                    repository: repository,
                    method: method
                ),
                authorization: authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .mergePullRequest
                )
            )
        }

        var staleQueuePreflight = fixtures.pullRequestPreflight()
        try fixtures.updatePullRequest(in: &staleQueuePreflight) { $0["headRefOid"] = "abcdef99" }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", staleQueuePreflight),
        ]))
        await XCTAssertThrowsMutationError(.stalePullRequest) {
            try await adapter.changeMergeQueue(
                self.queueRequest(
                    accountID: authentication.account.id,
                    repository: repository,
                    action: .enter,
                    queued: false
                ),
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .enterMergeQueue
                )
            )
        }

        let hugeContext = try mutationContext(
            accountID: authentication.account.id,
            repository: repository,
            number: ForgeItemNumber(Int(Int32.max) + 1),
            allowedOperations: [.closePullRequest]
        )
        let hugeRequest = ForgePullRequestLifecycleRequest(context: hugeContext, action: .close)
        await XCTAssertThrowsMutationError(.invalidRequest) {
            try await adapter.performLifecycle(
                hugeRequest,
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .closePullRequest
                )
            )
        }
    }

    func testGraphQLTransportAndErrorShapeBranchesAreExplicit() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let form = try creationForm(repository: repository)
        let authorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .createPullRequest
        )
        let adapter = makeAdapter(authentication: authentication)

        install(MutationResponseQueue([
            .graphQLPayload("GitHubPullRequestCreationPreflight", [:]),
        ]))
        await XCTAssertThrowsMutationError(.malformedResponse) {
            try await adapter.createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: authorization
            )
        }

        for (code, expected) in [
            (URLError.Code.notConnectedToInternet, GitHubMutationError.offline),
            (.timedOut, .transportFailure),
        ] {
            install(MutationResponseQueue([
                .failure("GitHubPullRequestCreationPreflight", code: code),
            ]))
            await XCTAssertThrowsMutationError(expected) {
                try await adapter.createPullRequest(
                    accountID: authentication.account.id,
                    form: form,
                    authorization: authorization
                )
            }
        }

        let mutationPayloads: [[String: Any]] = [
            [
                "errors": [[
                    "message": "Mutation rate limit",
                    "extensions": ["type": "RATE_LIMITED"],
                ]],
            ],
            [
                "errors": [[
                    "message": "Mutation forbidden",
                    "extensions": ["type": "FORBIDDEN"],
                ]],
            ],
            [:],
        ]
        for (index, payload) in mutationPayloads.enumerated() {
            let scenarioAdapter = makeAdapter(authentication: authentication)
            install(MutationResponseQueue([
                .graphQL("GitHubPullRequestCreationPreflight", fixtures.creationPreflight()),
                .graphQLPayload("GitHubCreatePullRequest", payload),
            ]))
            do {
                _ = try await scenarioAdapter.createPullRequest(
                    accountID: authentication.account.id,
                    form: form,
                    authorization: authorization
                )
                XCTFail("Expected mutation failure")
            } catch let error as GitHubMutationError {
                switch (index, error) {
                case (0, .rateLimited), (1, .authoritative), (2, .outcomeUnknown): break
                default: XCTFail("Unexpected \(error)")
                }
            }
        }

        install(MutationResponseQueue([
            .graphQLPayload("GitHubPullRequestCreationPreflight", [
                "errors": [[
                    "message": "\n",
                    "path": [0],
                    "extensions": ["code": "UNRECOGNIZED"],
                ]],
            ]),
        ]))
        let sanitizingAdapter = makeAdapter(authentication: authentication)
        do {
            _ = try await sanitizingAdapter.createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: authorization
            )
            XCTFail("Expected sanitized error")
        } catch let error as GitHubMutationError {
            guard case let .authoritative(problems, _) = error else {
                return XCTFail("Unexpected \(error)")
            }
            XCTAssertEqual(problems.first?.authoritativeMessage, "GitHub rejected this operation.")
            XCTAssertEqual(problems.first?.path, ["0"])
            XCTAssertNil(problems.first?.classification)
        }
    }

    func testReviewAnchorAndResponseDefensesNeverGuess() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let restClient = try MutationRESTClient(responses: [
            inlineCommentResponse(path: "README.md"),
            inlineCommentResponse(path: "Sources/App.swift"),
            inlineCommentResponse(path: "A.swift", commitID: "abcdef99"),
        ])
        let adapter = makeAdapter(authentication: authentication, restClient: restClient)
        let number = try ForgeItemNumber(7)
        let head = try ForgeCommitID("abcdef12")
        let operation = ForgeOperation.publishInlineReviewComment
        let authorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: operation
        )

        for anchor in try [
            ForgeReviewAnchor(path: ForgeFilePath("README.md"), subject: .file),
            ForgeReviewAnchor(
                path: ForgeFilePath("Sources/App.swift"),
                subject: .line,
                side: .left,
                line: 4
            ),
        ] {
            install(MutationResponseQueue([
                .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            ]))
            _ = try await adapter.publishInlineReview(
                ForgeInlineReviewPublication(
                    accountID: authentication.account.id,
                    repository: repository,
                    pullRequest: number,
                    displayedHead: head,
                    anchor: anchor,
                    bodyMarkdown: "Review note"
                ),
                authorization: authorization
            )
        }
        let requests = await restClient.requests
        XCTAssertEqual(requests.count, 2)
        let fileBody = try XCTUnwrap(requests[0].httpBody)
        let filePayload = try XCTUnwrap(JSONSerialization.jsonObject(with: fileBody) as? [String: Any])
        XCTAssertEqual(filePayload["subject_type"] as? String, "file")
        XCTAssertNil(filePayload["line"])
        XCTAssertNil(filePayload["side"])
        let lineBody = try XCTUnwrap(requests[1].httpBody)
        let linePayload = try XCTUnwrap(JSONSerialization.jsonObject(with: lineBody) as? [String: Any])
        XCTAssertEqual(linePayload["subject_type"] as? String, "line")
        XCTAssertEqual(linePayload["line"] as? Int, 4)
        XCTAssertEqual(linePayload["side"] as? String, "LEFT")

        let invalidAnchors = try [
            ForgeReviewAnchor(
                path: ForgeFilePath("README.md"),
                subject: .file,
                side: .right
            ),
            ForgeReviewAnchor(path: ForgeFilePath("A.swift"), subject: .line),
            ForgeReviewAnchor(
                path: ForgeFilePath("A.swift"),
                subject: .line,
                side: .right,
                startSide: .left,
                startLine: 5,
                line: 4
            ),
            ForgeReviewAnchor(
                path: ForgeFilePath("A.swift"),
                subject: .line,
                side: .right,
                startLine: 3,
                line: 4
            ),
        ]
        for anchor in invalidAnchors {
            install(MutationResponseQueue([
                .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            ]))
            await XCTAssertThrowsMutationError(.invalidRequest) {
                try await adapter.publishInlineReview(
                    ForgeInlineReviewPublication(
                        accountID: authentication.account.id,
                        repository: repository,
                        pullRequest: number,
                        displayedHead: head,
                        anchor: anchor,
                        bodyMarkdown: "Review note"
                    ),
                    authorization: authorization
                )
            }
        }

        var stale = fixtures.pullRequestPreflight()
        try fixtures.updatePullRequest(in: &stale) { $0["headRefOid"] = "abcdef99" }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", stale),
        ]))
        await XCTAssertThrowsMutationError(.stalePullRequest) {
            try await adapter.publishInlineReview(
                ForgeInlineReviewPublication(
                    accountID: authentication.account.id,
                    repository: repository,
                    pullRequest: number,
                    displayedHead: head,
                    anchor: ForgeReviewAnchor(
                        path: ForgeFilePath("A.swift"),
                        subject: .line,
                        side: .right,
                        line: 4
                    ),
                    bodyMarkdown: "Review note"
                ),
                authorization: authorization
            )
        }

        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.publishInlineReview(
                ForgeInlineReviewPublication(
                    accountID: authentication.account.id,
                    repository: repository,
                    pullRequest: number,
                    displayedHead: head,
                    anchor: ForgeReviewAnchor(
                        path: ForgeFilePath("A.swift"),
                        subject: .line,
                        side: .right,
                        line: 4
                    ),
                    bodyMarkdown: "Review note"
                ),
                authorization: authorization
            )
        }
    }

    func testInlinePostDispatchFailuresAndRateLimitNeverBecomeSafeAutomaticRetries() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let publication = try ForgeInlineReviewPublication(
            accountID: authentication.account.id,
            repository: repository,
            pullRequest: ForgeItemNumber(7),
            displayedHead: ForgeCommitID("abcdef12"),
            anchor: ForgeReviewAnchor(
                path: ForgeFilePath("A.swift"),
                subject: .line,
                side: .right,
                line: 1
            ),
            bodyMarkdown: "Review"
        )
        let authorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .publishInlineReviewComment
        )
        for failure in [MutationRESTFailure.cancelled, .known, .unknown, .offline, .timedOut] {
            install(MutationResponseQueue([
                .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            ]))
            await XCTAssertThrowsUnknownOutcome {
                try await self.makeAdapter(
                    authentication: authentication,
                    restClient: MutationThrowingRESTClient(failure: failure)
                ).publishInlineReview(publication, authorization: authorization)
            }
        }

        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
        ]))
        let retryAt = "60"
        do {
            _ = try await makeAdapter(
                authentication: authentication,
                restClient: MutationRESTClient(responses: [
                    GitHubMutationHTTPResponse(
                        statusCode: 429,
                        headers: ["Retry-After": retryAt],
                        data: Data()
                    ),
                ])
            ).publishInlineReview(publication, authorization: authorization)
            XCTFail("Expected rate limit")
        } catch let error as GitHubMutationError {
            guard case .rateLimited = error else {
                return XCTFail("Unexpected \(error)")
            }
        }
    }

    func testFormalReviewAndResolutionResponseDefensesRequireExactIdentityAndState() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let adapter = makeAdapter(authentication: authentication)
        let number = try ForgeItemNumber(7)
        let head = try ForgeCommitID("abcdef12")
        let submission = try ForgeFormalReviewSubmission(
            accountID: authentication.account.id,
            repository: repository,
            pullRequest: number,
            displayedHead: head,
            kind: .approve,
            bodyMarkdown: "Approved"
        )
        let reviewAuthorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .submitApproveReview
        )

        var stale = fixtures.pullRequestPreflight()
        try fixtures.updatePullRequest(in: &stale) { $0["headRefOid"] = "abcdef99" }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", stale),
        ]))
        await XCTAssertThrowsMutationError(.stalePullRequest) {
            try await adapter.submitFormalReview(submission, authorization: reviewAuthorization)
        }

        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            .graphQL("GitHubSubmitFormalReview", ["addPullRequestReview": NSNull()]),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.submitFormalReview(submission, authorization: reviewAuthorization)
        }

        var wrongState = fixtures.mutation("GitHubSubmitFormalReview")
        try fixtures.updateFormalReview(in: &wrongState) { $0["state"] = "COMMENTED" }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", fixtures.pullRequestPreflight()),
            .graphQL("GitHubSubmitFormalReview", wrongState),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.submitFormalReview(submission, authorization: reviewAuthorization)
        }

        let threadID = try ForgeObjectID(forge: repository.forge, value: "thread-node")
        let resolveAuthorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .resolveReviewThread
        )
        install(MutationResponseQueue([
            .graphQL("GitHubReviewThreadMutationPreflight", fixtures.threadPreflight(isResolved: true)),
        ]))
        await XCTAssertThrowsMutationError(.stalePullRequest) {
            try await adapter.setReviewThreadResolution(
                accountID: authentication.account.id,
                repository: repository,
                pullRequest: number,
                threadID: threadID,
                mutation: .resolve,
                authorization: resolveAuthorization
            )
        }

        install(MutationResponseQueue([
            .graphQL("GitHubReviewThreadMutationPreflight", fixtures.threadPreflight()),
            .graphQL("GitHubResolveReviewThread", ["resolveReviewThread": NSNull()]),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.setReviewThreadResolution(
                accountID: authentication.account.id,
                repository: repository,
                pullRequest: number,
                threadID: threadID,
                mutation: .resolve,
                authorization: resolveAuthorization
            )
        }

        var wrongResolution = fixtures.mutation("GitHubResolveReviewThread")
        try fixtures.updateDictionary(named: "thread", in: &wrongResolution) { $0["isResolved"] = false }
        install(MutationResponseQueue([
            .graphQL("GitHubReviewThreadMutationPreflight", fixtures.threadPreflight()),
            .graphQL("GitHubResolveReviewThread", wrongResolution),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.setReviewThreadResolution(
                accountID: authentication.account.id,
                repository: repository,
                pullRequest: number,
                threadID: threadID,
                mutation: .resolve,
                authorization: resolveAuthorization
            )
        }

        let unresolveAuthorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .unresolveReviewThread
        )
        install(MutationResponseQueue([
            .graphQL("GitHubReviewThreadMutationPreflight", fixtures.threadPreflight(isResolved: true)),
            .graphQL("GitHubUnresolveReviewThread", ["unresolveReviewThread": NSNull()]),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.setReviewThreadResolution(
                accountID: authentication.account.id,
                repository: repository,
                pullRequest: number,
                threadID: threadID,
                mutation: .unresolve,
                authorization: unresolveAuthorization
            )
        }

        let gitLab = try ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com"))
        await XCTAssertThrowsMutationError(.authorizationMismatch) {
            try await adapter.setReviewThreadResolution(
                accountID: authentication.account.id,
                repository: repository,
                pullRequest: number,
                threadID: ForgeObjectID(forge: gitLab, value: "thread-node"),
                mutation: .resolve,
                authorization: resolveAuthorization
            )
        }
    }

    func testUnknownForkSyncMergeTypeIsPreservedForReconciliation() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        install(MutationResponseQueue([
            .graphQL("GitHubSyncForkPreflight", fixtures.syncPreflight()),
        ]))
        let result = try await makeAdapter(
            authentication: authentication,
            restClient: MutationRESTClient(responses: [
                GitHubMutationHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    data: Data(#"{"merge_type":"future-type"}"#.utf8)
                ),
            ])
        ).syncFork(
            accountID: authentication.account.id,
            plan: syncPlan(repository: repository),
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .syncFork
            )
        )
        XCTAssertEqual(result.value.mergeType, .unknown)
    }

    func testMapperRejectsEveryMissingOrMismatchedPreflightIdentity() async throws {
        let fixtures = try MutationFixtures()
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let adapter = makeAdapter(authentication: authentication)
        let edit = try ForgePullRequestEdit(
            snapshot: editableSnapshot(repository: repository),
            title: "Edited title",
            bodyMarkdown: "Edited body"
        )
        var missingPullRequest = fixtures.pullRequestPreflight()
        var missingRepository = try XCTUnwrap(missingPullRequest["repository"] as? [String: Any])
        missingRepository["pullRequest"] = NSNull()
        missingPullRequest["repository"] = missingRepository
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestMutationPreflight", missingPullRequest),
        ]))
        await XCTAssertThrowsMutationError(.objectNotFound) {
            try await adapter.editPullRequest(
                accountID: authentication.account.id,
                edit: edit,
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .editPullRequest
                )
            )
        }

        var nullableNodes = fixtures.creationPreflight()
        var nullableRepository = try XCTUnwrap(nullableNodes["repository"] as? [String: Any])
        var nullableConnection = try XCTUnwrap(nullableRepository["pullRequests"] as? [String: Any])
        nullableConnection["nodes"] = [NSNull()]
        nullableRepository["pullRequests"] = nullableConnection
        nullableNodes["repository"] = nullableRepository
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", nullableNodes),
            .graphQL("GitHubCreatePullRequest", fixtures.mutation("GitHubCreatePullRequest")),
        ]))
        _ = try await adapter.createPullRequest(
            accountID: authentication.account.id,
            form: creationForm(repository: repository),
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .createPullRequest
            )
        )

        let number = try ForgeItemNumber(7)
        let threadID = try ForgeObjectID(forge: repository.forge, value: "thread-node")
        let reply = try ForgeReviewThreadReplyPublication(
            accountID: authentication.account.id,
            repository: repository,
            pullRequest: number,
            threadID: threadID,
            bodyMarkdown: "Reply"
        )
        install(MutationResponseQueue([
            .graphQL("GitHubReviewThreadMutationPreflight", ["node": NSNull()]),
        ]))
        await XCTAssertThrowsMutationError(.objectNotFound) {
            try await adapter.replyToReviewThread(
                reply,
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .replyToReviewThread
                )
            )
        }
        var wrongThread = fixtures.threadPreflight()
        try fixtures.updatePullRequest(in: &wrongThread) { $0["number"] = 8 }
        install(MutationResponseQueue([
            .graphQL("GitHubReviewThreadMutationPreflight", wrongThread),
        ]))
        await XCTAssertThrowsMutationError(.authorizationMismatch) {
            try await adapter.replyToReviewThread(
                reply,
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .replyToReviewThread
                )
            )
        }

        let deletion = try headBranchDeletionRequest(
            accountID: authentication.account.id,
            repository: repository
        )
        let deletionAuthorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .deleteHeadBranch
        )
        install(MutationResponseQueue([
            .graphQL(
                "GitHubPullRequestMutationPreflight",
                fixtures.pullRequestPreflight(state: .merged)
            ),
            .graphQL("GitHubHeadBranchDeletionPreflight", ["repository": NSNull()]),
        ]))
        await XCTAssertThrowsMutationError(.objectNotFound) {
            try await adapter.deleteHeadBranch(deletion, authorization: deletionAuthorization)
        }
        var staleRef = fixtures.headBranchPreflight()
        try fixtures.updateDictionary(named: "ref", in: &staleRef) { $0["name"] = "another-branch" }
        install(MutationResponseQueue([
            .graphQL(
                "GitHubPullRequestMutationPreflight",
                fixtures.pullRequestPreflight(state: .merged)
            ),
            .graphQL("GitHubHeadBranchDeletionPreflight", staleRef),
        ]))
        await XCTAssertThrowsMutationError(.stalePullRequest) {
            try await adapter.deleteHeadBranch(deletion, authorization: deletionAuthorization)
        }

        let plan = try syncPlan(repository: repository)
        let syncAuthorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .syncFork
        )
        install(MutationResponseQueue([
            .graphQL("GitHubSyncForkPreflight", ["repository": NSNull()]),
        ]))
        await XCTAssertThrowsMutationError(.objectNotFound) {
            try await adapter.syncFork(
                accountID: authentication.account.id,
                plan: plan,
                authorization: syncAuthorization
            )
        }
        var notFork = fixtures.syncPreflight()
        try fixtures.updateDictionary(named: "repository", in: &notFork) { $0["isFork"] = false }
        install(MutationResponseQueue([
            .graphQL("GitHubSyncForkPreflight", notFork),
        ]))
        await XCTAssertThrowsMutationError(.invalidRequest) {
            try await adapter.syncFork(
                accountID: authentication.account.id,
                plan: plan,
                authorization: syncAuthorization
            )
        }
        var wrongParent = fixtures.syncPreflight()
        try fixtures.updateDictionary(named: "parent", in: &wrongParent) {
            $0["nameWithOwner"] = "other/gitx"
            var owner = $0["owner"] as! [String: Any]
            owner["login"] = "other"
            $0["owner"] = owner
        }
        install(MutationResponseQueue([
            .graphQL("GitHubSyncForkPreflight", wrongParent),
        ]))
        await XCTAssertThrowsMutationError(.authorizationMismatch) {
            try await adapter.syncFork(
                accountID: authentication.account.id,
                plan: plan,
                authorization: syncAuthorization
            )
        }

        for key in ["headRepository", "baseRepository"] {
            var malformed = fixtures.mutation("GitHubCreatePullRequest")
            try fixtures.updatePullRequest(in: &malformed) { $0[key] = NSNull() }
            install(MutationResponseQueue([
                .graphQL("GitHubPullRequestCreationPreflight", fixtures.creationPreflight()),
                .graphQL("GitHubCreatePullRequest", malformed),
            ]))
            await XCTAssertThrowsUnknownOutcome {
                try await adapter.createPullRequest(
                    accountID: authentication.account.id,
                    form: self.creationForm(repository: repository),
                    authorization: self.authorization(
                        authentication: authentication,
                        repository: repository,
                        operation: .createPullRequest
                    )
                )
            }
        }

        var unknownState = fixtures.mutation("GitHubCreatePullRequest")
        try fixtures.updatePullRequest(in: &unknownState) { $0["state"] = "FUTURE_STATE" }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", fixtures.creationPreflight()),
            .graphQL("GitHubCreatePullRequest", unknownState),
        ]))
        await XCTAssertThrowsUnknownOutcome {
            try await adapter.createPullRequest(
                accountID: authentication.account.id,
                form: self.creationForm(repository: repository),
                authorization: self.authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .createPullRequest
                )
            )
        }

        var fractional = fixtures.mutation("GitHubCreatePullRequest")
        try fixtures.updatePullRequest(in: &fractional) {
            $0["createdAt"] = "2026-07-29T12:00:00.123Z"
            $0["updatedAt"] = "2026-07-29T12:30:00.456Z"
        }
        install(MutationResponseQueue([
            .graphQL("GitHubPullRequestCreationPreflight", fixtures.creationPreflight()),
            .graphQL("GitHubCreatePullRequest", fractional),
        ]))
        _ = try await adapter.createPullRequest(
            accountID: authentication.account.id,
            form: creationForm(repository: repository),
            authorization: authorization(
                authentication: authentication,
                repository: repository,
                operation: .createPullRequest
            )
        )
    }

    func testGraphQLHTTPFailuresUseAuthoritativeResponseMetadata() async throws {
        let authentication = try makeAuthentication()
        let repository = try makeRepository()
        let form = try creationForm(repository: repository)
        let authorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .createPullRequest
        )
        let cases: [(Int, [String: String], GraphQLHTTPExpectation)] = [
            (401, [:], .authentication),
            (403, ["X-RateLimit-Remaining": "0"], .rateLimited),
            (403, [:], .permission),
            (429, [:], .rateLimited),
            (503, [:], .transport),
            (418, [:], .transport),
            (
                403,
                ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso?request=1"],
                .saml
            ),
        ]
        for (status, extraHeaders, expectation) in cases {
            var headers = ["Content-Type": "application/json"]
            headers.merge(extraHeaders) { _, new in new }
            let queue = MutationResponseQueue([
                .graphQLPayload(
                    "GitHubPullRequestCreationPreflight",
                    ["message": "HTTP failure"],
                    statusCode: status,
                    headers: headers
                ),
            ])
            install(queue)
            do {
                _ = try await makeAdapter(authentication: authentication).createPullRequest(
                    accountID: authentication.account.id,
                    form: form,
                    authorization: authorization
                )
                XCTFail("Expected HTTP classification")
            } catch let error as GitHubMutationError {
                switch (expectation, error) {
                case (.authentication, .authenticationRequired),
                     (.rateLimited, .rateLimited),
                     (.permission, .permissionDenied),
                     (.transport, .transportFailure),
                     (.saml, .samlAuthorizationRequired):
                    break
                default:
                    XCTFail("Unexpected \(error) for HTTP \(status)")
                }
            }
        }
    }
}

private struct MutationFixtures {
    private let root: [String: Any]

    init() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "mutation-fixtures",
                withExtension: "json",
                subdirectory: "Mutations"
            ) ?? Bundle.module.url(forResource: "mutation-fixtures", withExtension: "json")
        )
        root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func pullRequest(headName: String = "feature/github-mutations") -> [String: Any] {
        var result = resolved(dictionary: dictionary("pullRequest"))
        result["headRefName"] = headName
        return result
    }

    func pullRequestPreflight(
        state: ForgePullRequestState = .open,
        isDraft: Bool = false,
        queueEntry: Bool = false
    ) -> [String: Any] {
        var repository = resolved(dictionary: dictionary("pullRequestPreflight"))
        var pullRequest = repository["pullRequest"] as! [String: Any]
        pullRequest["state"] = state.rawValue.uppercased()
        pullRequest["isDraft"] = isDraft
        pullRequest["mergeQueueEntry"] = queueEntry
            ? ["__typename": "MergeQueueEntry", "id": "queue-node"]
            : NSNull()
        repository["pullRequest"] = pullRequest
        return ["repository": repository]
    }

    func creationPreflight() -> [String: Any] {
        resolved(dictionary: dictionary("creationPreflight"))
    }

    func threadPreflight(isResolved: Bool = false) -> [String: Any] {
        var result = resolved(dictionary: dictionary("threadPreflight"))
        var node = result["node"] as! [String: Any]
        node["isResolved"] = isResolved
        result["node"] = node
        return result
    }

    func syncPreflight() -> [String: Any] {
        resolved(dictionary: dictionary("syncPreflight"))
    }

    func headBranchPreflight() -> [String: Any] {
        resolved(dictionary: dictionary("headBranchPreflight"))
    }

    func mutation(_ operation: String) -> [String: Any] {
        let mutations = dictionary("mutationData")
        return resolved(dictionary: mutations[operation] as! [String: Any])
    }

    func restSyncData() throws -> Data {
        try JSONSerialization.data(withJSONObject: resolved(dictionary: dictionary("restSync")))
    }

    func updatePullRequest(
        in value: inout [String: Any],
        _ update: (inout [String: Any]) -> Void
    ) throws {
        guard updateFirstDictionary(named: "pullRequest", in: &value, update) else {
            throw FixtureError.missingValue("pullRequest")
        }
    }

    func updateFormalReview(
        in value: inout [String: Any],
        _ update: (inout [String: Any]) -> Void
    ) throws {
        guard updateFirstDictionary(named: "pullRequestReview", in: &value, update) else {
            throw FixtureError.missingValue("pullRequestReview")
        }
    }

    func updateDictionary(
        named name: String,
        in value: inout [String: Any],
        _ update: (inout [String: Any]) -> Void
    ) throws {
        guard updateFirstDictionary(named: name, in: &value, update) else {
            throw FixtureError.missingValue(name)
        }
    }

    static func pageInfo(hasNextPage: Bool, endCursor: String?) -> [String: Any] {
        [
            "__typename": "PageInfo",
            "hasPreviousPage": false,
            "startCursor": NSNull(),
            "hasNextPage": hasNextPage,
            "endCursor": endCursor ?? NSNull(),
        ]
    }

    private func dictionary(_ key: String) -> [String: Any] {
        root[key] as! [String: Any]
    }

    private func resolved(dictionary: [String: Any]) -> [String: Any] {
        resolve(dictionary) as! [String: Any]
    }

    private func resolve(_ value: Any) -> Any {
        if let string = value as? String {
            switch string {
            case "$pullRequest": return resolve(dictionary("pullRequest"))
            case "$repositoryIdentity": return resolve(dictionary("repositoryIdentity"))
            default: return string
            }
        }
        if let array = value as? [Any] {
            return array.map(resolve)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(resolve)
        }
        return value
    }

    private func updateFirstDictionary(
        named name: String,
        in dictionary: inout [String: Any],
        _ update: (inout [String: Any]) -> Void
    ) -> Bool {
        if var target = dictionary[name] as? [String: Any] {
            update(&target)
            dictionary[name] = target
            return true
        }
        for key in dictionary.keys.sorted() {
            guard var nested = dictionary[key] as? [String: Any] else { continue }
            if updateFirstDictionary(named: name, in: &nested, update) {
                dictionary[key] = nested
                return true
            }
        }
        return false
    }

    private enum FixtureError: Error {
        case missingValue(String)
    }
}

private struct MutationStubResponse: Sendable {
    let operationName: String
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    let failureCode: URLError.Code?
    let cancellationFailure: Bool

    static func graphQL(
        _ operationName: String,
        _ data: [String: Any],
        statusCode: Int = 200,
        headers: [String: String] = MutationResponseQueue.successHeaders
    ) -> Self {
        Self(
            operationName: operationName,
            statusCode: statusCode,
            headers: headers,
            body: try! JSONSerialization.data(withJSONObject: ["data": data]),
            failureCode: nil,
            cancellationFailure: false
        )
    }

    static func graphQLPayload(
        _ operationName: String,
        _ payload: [String: Any],
        statusCode: Int = 200,
        headers: [String: String] = MutationResponseQueue.successHeaders
    ) -> Self {
        Self(
            operationName: operationName,
            statusCode: statusCode,
            headers: headers,
            body: try! JSONSerialization.data(withJSONObject: payload),
            failureCode: nil,
            cancellationFailure: false
        )
    }

    static func failure(_ operationName: String, code: URLError.Code) -> Self {
        Self(
            operationName: operationName,
            statusCode: 0,
            headers: [:],
            body: Data(),
            failureCode: code,
            cancellationFailure: false
        )
    }

    static func cancellation(_ operationName: String) -> Self {
        Self(
            operationName: operationName,
            statusCode: 0,
            headers: [:],
            body: Data(),
            failureCode: nil,
            cancellationFailure: true
        )
    }
}

private final class MutationResponseQueue: @unchecked Sendable {
    static let successHeaders = [
        "Content-Type": "application/json",
        "X-GitHub-Request-Id": "mutation-fixture",
        "X-RateLimit-Limit": "5000",
        "X-RateLimit-Remaining": "4999",
    ]

    private let lock = NSLock()
    private var responses: [MutationStubResponse]
    private var recordedPayloads: [[String: Any]] = []

    init(_ responses: [MutationStubResponse]) {
        self.responses = responses
    }

    var payloads: [[String: Any]] {
        lock.withLock { recordedPayloads }
    }

    var remainingCount: Int {
        lock.withLock { responses.count }
    }

    func response(for request: URLRequest) throws -> MutationStubResponse {
        let body = try requestBody(request)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try lock.withLock {
            guard !responses.isEmpty else { throw QueueError.unexpectedRequest }
            let response = responses.removeFirst()
            guard payload["operationName"] as? String == response.operationName else {
                throw QueueError.unexpectedOperation
            }
            recordedPayloads.append(payload)
            if let failureCode = response.failureCode {
                throw URLError(failureCode)
            }
            if response.cancellationFailure {
                throw CancellationError()
            }
            return response
        }
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { throw QueueError.missingBody }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? QueueError.missingBody }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private enum QueueError: Error {
        case missingBody
        case unexpectedRequest
        case unexpectedOperation
    }
}

private final class GitHubMutationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> MutationStubResponse)?

    static func setHandler(_ value: (@Sendable (URLRequest) throws -> MutationStubResponse)?) {
        lock.withLock { handler = value }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let current = Self.lock.withLock { Self.handler }
        guard let current else {
            client?.urlProtocol(self, didFailWithError: GitHubMutationError.transportFailure)
            return
        }
        do {
            let stub = try current(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/2",
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class MutationNonHTTPURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = URLResponse(
            url: request.url!,
            mimeType: "application/json",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor MutationRESTClient: GitHubMutationHTTPClient {
    private var responses: [GitHubMutationHTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [GitHubMutationHTTPResponse]) {
        self.responses = responses
    }

    func execute(_ request: URLRequest) throws -> GitHubMutationHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw GitHubMutationError.transportFailure }
        return responses.removeFirst()
    }
}

private enum MutationRESTFailure: CaseIterable, Equatable, Sendable {
    case cancelled
    case known
    case unknown
    case offline
    case timedOut
}

private struct MutationThrowingRESTClient: GitHubMutationHTTPClient {
    let failure: MutationRESTFailure

    func execute(_: URLRequest) throws -> GitHubMutationHTTPResponse {
        switch failure {
        case .cancelled: throw CancellationError()
        case .known: throw GitHubMutationError.transportFailure
        case .unknown: throw GitHubMutationError.outcomeUnknown(nil)
        case .offline: throw URLError(.notConnectedToInternet)
        case .timedOut: throw URLError(.timedOut)
        }
    }
}

private actor MutationCredentialAuthority: GitHubReadCredentialAuthority {
    let authentication: GitHubReadAuthentication?

    init(authentication: GitHubReadAuthentication?) {
        self.authentication = authentication
    }

    func currentAuthentication(for _: ForgeCredentialReference) -> GitHubReadAuthentication? {
        authentication
    }
}

private enum RESTExpectation {
    case authoritative(String)
    case rateLimited
    case unknown
}

private enum GraphQLHTTPExpectation {
    case authentication
    case permission
    case rateLimited
    case saml
    case transport
}

private extension GitHubMutationAdapterTests {
    func install(_ queue: MutationResponseQueue) {
        GitHubMutationURLProtocol.setHandler { try queue.response(for: $0) }
    }

    func makeRepository() throws -> ForgeRepositoryIdentity {
        try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            owner: "hbmartin",
            name: "gitx"
        )
    }

    func makeAuthentication(
        source: ForgeCredentialSource = .classicPersonalAccessToken,
        expiresAt: Date? = nil
    ) throws -> GitHubReadAuthentication {
        let accountID = try ForgeAccountID(forge: makeRepository().forge, value: "octocat")
        let credential = try ForgeCredentialMetadata(
            reference: ForgeCredentialReference(
                accountID: accountID,
                credentialID: ForgeCredentialID("github-mutation"),
                generation: ForgeCredentialGeneration(1)
            ),
            source: source,
            expiresAt: expiresAt
        )
        return try GitHubReadAuthentication(
            account: ForgeAccount(id: accountID, login: "octocat", currentCredential: credential),
            credential: credential,
            accessToken: GitHubSecret("mutation-secret")
        )
    }

    func makeAdapter(
        authentication: GitHubReadAuthentication,
        restClient: (any GitHubMutationHTTPClient)? = nil,
        sessionGate: GitHubMutationSessionGate = GitHubMutationSessionGate()
    ) -> GitHubMutationAdapter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMutationURLProtocol.self]
        let authority = MutationCredentialAuthority(authentication: authentication)
        if let restClient {
            return GitHubMutationAdapter(
                expectedCredential: authentication.credential.reference,
                credentialAuthority: authority,
                sessionConfiguration: configuration,
                restClient: restClient,
                sessionGate: sessionGate,
                now: { Date(timeIntervalSince1970: 1_775_000_000) }
            )
        }
        return GitHubMutationAdapter(
            expectedCredential: authentication.credential.reference,
            credentialAuthority: authority,
            sessionConfiguration: configuration,
            sessionGate: sessionGate
        )
    }

    func makeAdapter(
        expectedCredential: ForgeCredentialReference,
        authentication: GitHubReadAuthentication?
    ) -> GitHubMutationAdapter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMutationURLProtocol.self]
        return GitHubMutationAdapter(
            expectedCredential: expectedCredential,
            credentialAuthority: MutationCredentialAuthority(authentication: authentication),
            sessionConfiguration: configuration
        )
    }

    func authorization(
        authentication: GitHubReadAuthentication,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) throws -> GitHubMutationAuthorization {
        let key = ForgeCapabilityKey(
            credential: authentication.credential.reference,
            repository: repository,
            operation: operation
        )
        return try GitHubMutationAuthorization(key: key, capability: .verified(.knownAuthority))
    }

    func unverifiedCapability(
        authentication: GitHubReadAuthentication,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) throws -> ForgeOperationCapability {
        try ForgeCapabilityEvaluator.capability(
            account: authentication.account,
            repository: repository,
            operation: operation,
            operationSupported: true,
            credentialAvailability: .available,
            now: Date(timeIntervalSince1970: 1_775_000_000),
            permissionEvidence: ForgePermissionEvidence(
                credential: authentication.credential.reference,
                repository: repository,
                freshness: .current,
                grants: [ForgePermissionGrant(permission: .pullRequests, authority: .unknown)]
            ),
            accessEvidence: ForgeRepositoryAccessEvidence(
                credential: authentication.credential.reference,
                repository: repository,
                freshness: .current,
                status: .granted,
                role: .known(.admin)
            ),
            promotions: ForgeCapabilityPromotionLedger()
        )
    }

    func unverifiedAttempt(
        authentication: GitHubReadAuthentication,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) throws -> ForgeUnverifiedWriteAttempt? {
        guard case let .unverifiedWrite(attempt) = try unverifiedCapability(
            authentication: authentication,
            repository: repository,
            operation: operation
        ) else {
            return nil
        }
        return attempt
    }

    func creationForm(repository: ForgeRepositoryIdentity) throws -> ForgePullRequestCreationForm {
        try ForgePullRequestCreationForm(
            repository: repository,
            base: ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("master"),
                commit: ForgeCommitID("12345678")
            ),
            head: ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("feature/github-mutations"),
                commit: ForgeCommitID("abcdef12")
            ),
            title: "Mutation adapter",
            bodyMarkdown: "Provider-neutral body"
        )
    }

    func editableSnapshot(repository: ForgeRepositoryIdentity) throws -> ForgePullRequestEditableSnapshot {
        try ForgePullRequestEditableSnapshot(
            repository: repository,
            number: ForgeItemNumber(7),
            title: "Mutation adapter",
            bodyMarkdown: "Provider-neutral body",
            updatedAt: fixtureDate
        )
    }

    func mutationContext(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        state: ForgePullRequestState = .open,
        isDraft: Bool = false,
        number: ForgeItemNumber = try! ForgeItemNumber(7),
        allowedOperations: Set<ForgeOperation>
    ) throws -> ForgePullRequestMutationContext {
        try ForgePullRequestMutationContext(
            accountID: accountID,
            repository: repository,
            number: number,
            state: state,
            isDraft: isDraft,
            head: ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("feature/github-mutations"),
                commit: ForgeCommitID("abcdef12")
            ),
            base: ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("master"),
                commit: ForgeCommitID("12345678")
            ),
            updatedAt: fixtureDate,
            allowedOperations: allowedOperations
        )
    }

    func lifecycleRequest(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        action: ForgePullRequestLifecycleAction,
        state: ForgePullRequestState,
        isDraft: Bool
    ) throws -> ForgePullRequestLifecycleRequest {
        let decision = try ForgePullRequestLifecyclePolicy.decision(
            context: mutationContext(
                accountID: accountID,
                repository: repository,
                state: state,
                isDraft: isDraft,
                allowedOperations: [action.operation]
            ),
            action: action,
            canUpdateBranch: true
        )
        guard case let .available(request) = decision else {
            throw HelperError.unavailable
        }
        return request
    }

    func makeMergeRequest(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        method: ForgePullRequestMergeMethod = .squash
    ) throws -> ForgePullRequestMergeRequest {
        let snapshot = try ForgePullRequestMergeSnapshot(
            context: mutationContext(
                accountID: accountID,
                repository: repository,
                allowedOperations: [.mergePullRequest]
            ),
            viewerCanMerge: true,
            enabledMethods: [method]
        )
        guard case let .available(confirmation) = ForgePullRequestMergePolicy.confirmationDecision(
            snapshot: snapshot,
            method: method
        ) else {
            throw HelperError.unavailable
        }
        return try ForgePullRequestMergeRequest(
            confirmation: confirmation,
            title: method == .rebase ? nil : "Merged mutation adapter",
            message: method == .rebase ? nil : "Verified fixture merge"
        )
    }

    func queueRequest(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        action: ForgePullRequestMergeQueueAction,
        queued: Bool
    ) throws -> ForgePullRequestMergeQueueRequest {
        let snapshot = try ForgePullRequestMergeSnapshot(
            context: mutationContext(
                accountID: accountID,
                repository: repository,
                allowedOperations: [action.operation]
            ),
            viewerCanMerge: true,
            enabledMethods: [.merge],
            queueState: queued ? .queued : .notQueued
        )
        guard case let .available(request) = ForgePullRequestMergeQueuePolicy.decision(
            snapshot: snapshot,
            action: action
        ) else {
            throw HelperError.unavailable
        }
        return request
    }

    func headBranchDeletionRequest(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeHeadBranchDeletionRequest {
        let mergeSnapshot = try ForgePullRequestMergeSnapshot(
            context: mutationContext(
                accountID: accountID,
                repository: repository,
                state: .merged,
                allowedOperations: [.deleteHeadBranch]
            ),
            viewerCanMerge: true,
            enabledMethods: [.merge]
        )
        let snapshot = ForgeHeadBranchDeletionSnapshot(
            mergeSnapshot: mergeSnapshot,
            isSameRepository: true,
            isDefaultBranch: false,
            isProtected: false,
            viewerCanDelete: true,
            hasCheckedOutSafetyConflict: false
        )
        guard case let .available(request) = ForgeHeadBranchDeletionPolicy.decision(
            snapshot: snapshot,
            mergeWasQueued: false
        ) else {
            throw HelperError.unavailable
        }
        return request
    }

    func syncPlan(repository: ForgeRepositoryIdentity) throws -> ForgeSyncForkPlan {
        try ForgeSyncForkPlan(
            fork: repository,
            parent: ForgeRepositoryIdentity(
                forge: repository.forge,
                owner: "gitx",
                name: "gitx"
            ),
            branch: ForgeRefName("master"),
            localFetchRemoteName: "origin"
        )
    }

    func inlineCommentResponse(
        path: String,
        commitID: String = "abcdef12"
    ) throws -> GitHubMutationHTTPResponse {
        try GitHubMutationHTTPResponse(
            statusCode: 201,
            headers: ["X-GitHub-Request-Id": "inline-request"],
            data: JSONSerialization.data(withJSONObject: [
                "node_id": "thread-node",
                "commit_id": commitID,
                "path": path,
            ])
        )
    }

    var fixtureDate: Date {
        ISO8601DateFormatter().date(from: "2026-07-29T12:30:00Z")!
    }

    enum HelperError: Error {
        case unavailable
    }

    func XCTAssertThrowsMutationError<Value>(
        _ expected: GitHubMutationError,
        operation: () async throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as GitHubMutationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
        }
    }

    func XCTAssertThrowsUnknownOutcome<Value>(
        operation: () async throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected unknown mutation outcome", file: file, line: line)
        } catch let error as GitHubMutationError {
            guard case .outcomeUnknown = error else {
                return XCTFail("Unexpected \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
        }
    }
}
