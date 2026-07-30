import ForgeKit
@testable import GitHubForgeAdapter
import XCTest

final class GitHubReadAdapterTests: XCTestCase {
    override func tearDown() {
        GitHubStubURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testEveryCheckedInOperationExecutesThroughApolloAndReturnsMetadata() async throws {
        let capture = GitHubRequestCapture()
        GitHubStubURLProtocol.setHandler { request in
            let index = capture.record(request)
            return try StubResponse(
                status: 200,
                headers: Self.successHeaders,
                body: Self.response(operation: Self.operationOrder[index])
            )
        }
        let adapter = try makeAdapter()
        let repository = try makeRepository()
        let number = try ForgeItemNumber(7)
        let cursor = try ForgePageCursor("after")

        let facts = try await adapter.repositoryFacts(repository: repository)
        XCTAssertEqual(facts.completeness, .complete)
        XCTAssertEqual(facts.response.statusCode, 200)
        XCTAssertEqual(facts.response.requestID, "request-id")
        XCTAssertEqual(facts.response.rateLimit.remaining, 4999)
        XCTAssertNotNil(facts.response.rateLimit.retryAt)
        XCTAssertEqual(facts.ownership.credential, try makeAuthentication().credential.reference)
        XCTAssertEqual(facts.ownership.repository, repository)
        XCTAssertEqual(facts.ownership.cachePartition, try .account(makeAuthentication().account.id))
        XCTAssertEqual(facts.response.rateLimit.resource, "graphql")
        XCTAssertEqual(facts.accessEvidence?.repository, repository)
        XCTAssertEqual(facts.accessEvidence?.status, .granted)
        XCTAssertEqual(facts.accessEvidence?.role, .known(.write))
        XCTAssertEqual(facts.value.viewerCapabilities.availableValue?.role, .known(.write))
        XCTAssertEqual(facts.value.viewerCapabilities.availableValue?.canCreateIssues, true)
        let pullRequests = try await adapter.pullRequests(
            repository: repository,
            pageSize: 1,
            after: cursor,
            states: [.open, .closed, .merged]
        )
        XCTAssertEqual(pullRequests.value.items.count, 1)
        let issues = try await adapter.issues(
            repository: repository,
            pageSize: 100,
            states: [.open, .closed]
        )
        XCTAssertEqual(issues.value.items.count, 1)
        let pullRequestDetails = try await adapter.pullRequestDetails(
            repository: repository,
            number: number,
            timelinePageSize: 1,
            timelineAfter: cursor,
            checkPageSize: 1,
            checkAfter: cursor
        )
        XCTAssertEqual(pullRequestDetails.value.details.summary.number, number)
        let issueDetails = try await adapter.issueDetails(
            repository: repository,
            number: number,
            timelinePageSize: 1,
            timelineAfter: cursor
        )
        XCTAssertEqual(issueDetails.value.summary.number, number)
        let overlay = try await adapter.historyOverlay(
            repository: repository,
            commit: ForgeCommitID("abcdef12"),
            pullRequestPageSize: 1,
            pullRequestAfter: cursor
        )
        XCTAssertEqual(overlay.value.commit.value, "abcdef12")
        let search = try await adapter.searchRepositoryItems(
            repository: repository,
            text: "adapter",
            pageSize: 1,
            after: cursor
        )
        XCTAssertEqual(search.value.items.count, 2)
        let attention = try await adapter.attentionCandidates(
            repository: repository,
            searchText: "is:open",
            pageSize: 1,
            after: cursor,
            activityCount: 1,
            reviewThreadCount: 1
        )
        XCTAssertEqual(attention.value.candidates.items.count, 2)
        XCTAssertEqual(
            attention.value.candidates.items.map(\.subjectID.value),
            ["pr", "issue"]
        )
        let threads = try await adapter.reviewThreads(
            repository: repository,
            pullRequestNumber: number,
            pageSize: 1,
            after: cursor,
            initialCommentCount: 1
        )
        XCTAssertEqual(threads.value.items.count, 1)
        XCTAssertEqual(threads.value.items.first?.anchor.availableValue?.startSide, .right)
        let comments = try await adapter.reviewThreadComments(
            repository: repository,
            threadID: ForgeObjectID(forge: repository.forge, value: "thread"),
            pageSize: 1,
            after: cursor
        )
        XCTAssertEqual(comments.value.items.count, 1)

        let requests = capture.requests
        XCTAssertEqual(requests.count, 10)
        XCTAssertTrue(requests.allSatisfy { $0.url?.absoluteString == "https://api.github.com/graphql" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret-for-test" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "GitX-ForgeKit" })
        for (request, operation) in zip(requests, Self.operationOrder) {
            let payload = try Self.requestPayload(request)
            XCTAssertEqual(payload["operationName"] as? String, operation)
            XCTAssertTrue((payload["query"] as? String)?.contains("query \(operation)") == true)
            XCTAssertNotNil(payload["variables"] as? [String: Any])
        }
        let searchVariables = try XCTUnwrap(
            try Self.requestPayload(requests[6])["variables"] as? [String: Any]
        )
        XCTAssertEqual(searchVariables["query"] as? String, "repo:hbmartin/gitx \"adapter\"")
        let attentionVariables = try XCTUnwrap(
            try Self.requestPayload(requests[7])["variables"] as? [String: Any]
        )
        XCTAssertEqual(attentionVariables["query"] as? String, "repo:hbmartin/gitx \"is:open\"")
    }

    func testCurrentAttentionFetchUsesProviderControlledQueryAndBuildsRepositorySnapshot() async throws {
        let capture = GitHubRequestCapture()
        GitHubStubURLProtocol.setHandler { request in
            _ = capture.record(request)
            return try StubResponse(
                status: 200,
                headers: Self.successHeaders,
                body: Self.response(operation: "GitHubAttentionCandidates")
            )
        }
        let repository = try makeRepository()
        let authentication = try makeAuthentication()
        let watch = try ForgeWatchedRepository(
            key: ForgeWatchedRepositoryKey(
                accountID: authentication.account.id,
                repository: repository
            ),
            addedAt: Date(timeIntervalSince1970: 1),
            source: .preferences
        )
        let fetchedAt = Date(timeIntervalSince1970: 2)
        let snapshot = try await GitHubAttentionSnapshotFetcher(
            adapter: makeAdapter(),
            now: { fetchedAt }
        ).snapshot(for: watch)

        XCTAssertEqual(snapshot.watchedRepositoryKey, watch.key)
        XCTAssertEqual(snapshot.viewer.login, "octocat")
        XCTAssertEqual(snapshot.candidates.map(\.subjectID.value), ["pr", "issue"])
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
        XCTAssertEqual(snapshot.completeness, .complete)
        let request = try XCTUnwrap(capture.requests.first)
        let variables = try XCTUnwrap(
            try Self.requestPayload(request)["variables"] as? [String: Any]
        )
        XCTAssertEqual(
            variables["query"] as? String,
            "repo:hbmartin/gitx is:open involves:@me"
        )
        XCTAssertEqual(variables["first"] as? Int, 100)
        XCTAssertEqual(variables["activityLast"] as? Int, 100)
        XCTAssertEqual(variables["reviewThreadFirst"] as? Int, 100)
    }

    func testAttentionSnapshotFetcherPaginatesPartialDataAndRejectsAccountOrViewerChanges() async throws {
        func response(
            hasNextPage: Bool,
            viewer: [String: Any] = Self.actor,
            includesProblem: Bool = false
        ) throws -> Data {
            var root = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Self.response(operation: "GitHubAttentionCandidates")
                ) as? [String: Any]
            )
            var data = try XCTUnwrap(root["data"] as? [String: Any])
            var search = try XCTUnwrap(data["search"] as? [String: Any])
            search["pageInfo"] = Self.pageInfo(
                hasNextPage: hasNextPage,
                endCursor: hasNextPage ? "next-attention" : nil
            )
            data["viewer"] = viewer
            data["search"] = search
            root["data"] = data
            if includesProblem {
                root["errors"] = [[
                    "message": "redacted by adapter",
                    "path": ["search", "nodes", 0],
                    "extensions": ["type": "PARTIAL"],
                ]]
            }
            return try JSONSerialization.data(withJSONObject: root)
        }

        let repository = try makeRepository()
        let authentication = try makeAuthentication()
        let watch = try ForgeWatchedRepository(
            key: ForgeWatchedRepositoryKey(
                accountID: authentication.account.id,
                repository: repository
            ),
            addedAt: Date(timeIntervalSince1970: 1),
            source: .preferences
        )
        let capture = GitHubRequestCapture()
        let firstPage = try response(hasNextPage: true)
        let secondPage = try response(hasNextPage: false, includesProblem: true)
        GitHubStubURLProtocol.setHandler { request in
            let index = capture.record(request)
            return StubResponse(
                status: 200,
                headers: Self.successHeaders,
                body: index == 0 ? firstPage : secondPage
            )
        }
        let partial = try await GitHubAttentionSnapshotFetcher(
            adapter: makeAdapter()
        ).snapshot(for: watch)
        XCTAssertEqual(partial.candidates.count, 4)
        XCTAssertEqual(partial.completeness, .partial(unavailableSections: []))
        XCTAssertEqual(capture.requests.count, 2)
        let secondVariables = try XCTUnwrap(
            try Self.requestPayload(capture.requests[1])["variables"] as? [String: Any]
        )
        XCTAssertEqual(secondVariables["after"] as? String, "next-attention")

        let otherAccountID = try ForgeAccountID(forge: repository.forge, value: "other-account")
        let otherWatch = try ForgeWatchedRepository(
            key: ForgeWatchedRepositoryKey(accountID: otherAccountID, repository: repository),
            addedAt: Date(timeIntervalSince1970: 1),
            source: .preferences
        )
        let singlePage = try response(hasNextPage: false)
        GitHubStubURLProtocol.setHandler { _ in
            StubResponse(
                status: 200,
                headers: Self.successHeaders,
                body: singlePage
            )
        }
        await XCTAssertThrowsGitHubError(.authenticationRequired) {
            try await GitHubAttentionSnapshotFetcher(adapter: self.makeAdapter())
                .snapshot(for: otherWatch)
        }

        let viewerChangeCapture = GitHubRequestCapture()
        var changedViewer = Self.actor
        changedViewer["id"] = "different-viewer"
        changedViewer["login"] = "different"
        let changedViewerPage = try response(hasNextPage: false, viewer: changedViewer)
        GitHubStubURLProtocol.setHandler { request in
            let index = viewerChangeCapture.record(request)
            return StubResponse(
                status: 200,
                headers: Self.successHeaders,
                body: index == 0 ? firstPage : changedViewerPage
            )
        }
        await XCTAssertThrowsGitHubError(.malformedResponse) {
            try await GitHubAttentionSnapshotFetcher(adapter: self.makeAdapter())
                .snapshot(for: watch)
        }
    }

    func testHTTPFailuresClassifyRateLimitSAMLPermissionAuthenticationAndTransport() async throws {
        let cases: [(Int, [String: String], GitHubReadError)] = [
            (401, [:], .authenticationRequired),
            (403, ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso?request=1"],
             .samlAuthorizationRequired(metadata(status: 403, saml: true))),
            (403, ["X-RateLimit-Remaining": "0"], .rateLimited(metadata(status: 403, remaining: 0))),
            (403, [:], .permissionDenied(metadata(status: 403))),
            (429, [:], .rateLimited(metadata(status: 429))),
            (500, [:], .transportFailure),
        ]
        for (status, headers, expected) in cases {
            GitHubStubURLProtocol.setHandler { _ in
                StubResponse(status: status, headers: headers, body: Data(#"{"message":"failure"}"#.utf8))
            }
            let adapter = try makeAdapter()
            do {
                _ = try await adapter.repositoryFacts(repository: makeRepository())
                XCTFail("Expected status \(status) to fail")
            } catch let error as GitHubReadError {
                if case .samlAuthorizationRequired = expected {
                    guard case let .samlAuthorizationRequired(value) = error else {
                        return XCTFail("Unexpected \(error)")
                    }
                    XCTAssertEqual(value.saml?.authorizationURL?.host, "github.com")
                } else {
                    XCTAssertEqual(error, expected)
                }
            }
        }
    }

    func testGraphQLErrorsPartialAndMalformedResponsesRemainDistinct() async throws {
        let repository = try makeRepository()
        GitHubStubURLProtocol.setHandler { request in
            _ = request
            let body = try JSONSerialization.data(withJSONObject: [
                "data": ["repository": Self.repositoryFactsObject],
                "errors": [
                    [
                        "message": "topics unavailable",
                        "path": ["repository", 0],
                        "extensions": ["code": "PARTIAL"],
                    ],
                    [:],
                ],
            ])
            return StubResponse(status: 200, headers: [:], body: body)
        }
        let partial = try await makeAdapter().repositoryFacts(repository: repository)
        XCTAssertEqual(partial.completeness, .partial)
        XCTAssertEqual(partial.problems.first?.message, "GitHub could not complete part of this request.")
        XCTAssertEqual(partial.problems.first?.path, ["repository", "0"])
        XCTAssertEqual(partial.problems.first?.classification, "PARTIAL")
        XCTAssertEqual(partial.problems.last?.message, "GitHub could not complete part of this request.")

        GitHubStubURLProtocol.setHandler { _ in
            StubResponse(
                status: 200,
                headers: [:],
                body: Data(#"{"errors":[{"message":"denied"}]}"#.utf8)
            )
        }
        do {
            _ = try await makeAdapter().repositoryFacts(repository: repository)
            XCTFail("Expected GraphQL failure")
        } catch let error as GitHubReadError {
            guard case let .graphQL(problems, response) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertEqual(problems.first?.message, "GitHub could not complete part of this request.")
            XCTAssertEqual(response.statusCode, 200)
        }

        GitHubStubURLProtocol.setHandler { _ in
            StubResponse(status: 200, headers: [:], body: Data(#"{"data":"wrong"}"#.utf8))
        }
        await XCTAssertThrowsGitHubError(.malformedResponse) {
            try await self.makeAdapter().repositoryFacts(repository: repository)
        }
    }

    func testInputValidationStopsBeforeNetworkAndCoversAllErrorDescriptions() async throws {
        let repository = try makeRepository()
        let gitLab = try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com")),
            owner: "owner",
            name: "repo"
        )
        let adapter = try makeAdapter()
        await XCTAssertThrowsGitHubError(.githubDotComRequired) {
            try await adapter.repositoryFacts(repository: gitLab)
        }
        await XCTAssertThrowsGitHubError(.invalidPageSize) {
            try await adapter.pullRequests(repository: repository, pageSize: 0)
        }
        await XCTAssertThrowsGitHubError(.invalidPageSize) {
            try await adapter.issues(repository: repository, pageSize: 101)
        }
        await XCTAssertThrowsGitHubError(.invalidSearchQuery) {
            try await adapter.searchRepositoryItems(repository: repository, text: " \n")
        }
        await XCTAssertThrowsGitHubError(.invalidSearchQuery) {
            try await adapter.attentionCandidates(repository: repository, searchText: String(repeating: "x", count: 257))
        }
        let otherForgeID = try ForgeObjectID(forge: gitLab.forge, value: "thread")
        await XCTAssertThrowsGitHubError(.githubDotComRequired) {
            try await adapter.reviewThreadComments(repository: repository, threadID: otherForgeID)
        }
        await XCTAssertThrowsGitHubError(.malformedResponse) {
            try await adapter.pullRequestDetails(
                repository: repository,
                number: ForgeItemNumber(Int.max)
            )
        }

        let errors: [GitHubReadError] = [
            .githubDotComRequired, .invalidPageSize, .invalidSearchQuery,
            .repositoryNotFound, .objectNotFound, .authenticationRequired,
            .permissionDenied(metadata(status: 403)), .rateLimited(metadata(status: 429)),
            .samlAuthorizationRequired(metadata(status: 403, saml: true)),
            .graphQL([], metadata(status: 200)), .malformedResponse, .transportFailure,
        ]
        XCTAssertEqual(Set(errors.compactMap(\.errorDescription)).count, errors.count)
    }

    func testHTTPMetadataParserRejectsMalformedValuesAndAcceptsOnlyExactGitHubSAMLURL() throws {
        let response = try XCTUnwrap(try HTTPURLResponse(
            url: XCTUnwrap(URL(string: "https://api.github.com/graphql")),
            statusCode: 403,
            httpVersion: "HTTP/2",
            headerFields: [
                "X-RateLimit-Limit": "-1",
                "X-RateLimit-Remaining": "no",
                "X-RateLimit-Used": "  ",
                "X-RateLimit-Reset": "nan",
                "Retry-After": "-2",
                "X-RateLimit-Resource": " ",
                "X-GitHub-Request-Id": " ",
                "X-GitHub-SSO": "required; url=https://evil.example/sso",
            ]
        ))
        let receivedAt = Date(timeIntervalSince1970: 1000)
        let parsed = GitHubHTTPMetadataParser.metadata(from: response, receivedAt: receivedAt)
        XCTAssertNil(parsed.rateLimit.limit)
        XCTAssertNil(parsed.rateLimit.remaining)
        XCTAssertNil(parsed.rateLimit.used)
        XCTAssertNil(parsed.rateLimit.resetAt)
        XCTAssertNil(parsed.rateLimit.retryAt)
        XCTAssertNil(parsed.rateLimit.resource)
        XCTAssertNil(parsed.requestID)
        XCTAssertNil(parsed.saml)

        let noSAML = try XCTUnwrap(try HTTPURLResponse(
            url: XCTUnwrap(URL(string: "https://api.github.com/graphql")),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["X-GitHub-SSO": "granted"]
        ))
        XCTAssertNil(GitHubHTTPMetadataParser.metadata(from: noSAML, receivedAt: receivedAt).saml)

        let box = GitHubResponseMetadataBox()
        XCTAssertNil(box.take())
        box.record(noSAML)
        XCTAssertEqual(box.take()?.statusCode, 200)
    }

    func testPublicResultValuesInitializeAndRedactSensitiveMetadata() throws {
        let authentication = try makeAuthentication(accessToken: "authentication-secret")
        let rate = GitHubRateLimitMetadata(
            limit: 5000,
            remaining: 4999,
            used: 1,
            resetAt: Date(timeIntervalSince1970: 1_785_328_496),
            retryAt: Date(timeIntervalSince1970: 2),
            resource: "graphql"
        )
        let saml = GitHubSAMLMetadata(authorizationURL: URL(string: "https://github.com/orgs/acme/sso"))
        let response = GitHubResponseMetadata(
            statusCode: 200,
            requestID: "request",
            rateLimit: rate,
            saml: saml
        )
        let problem = GitHubGraphQLProblem(message: "partial")
        let ownership = try GitHubReadOwnership(
            credential: makeAuthentication().credential.reference,
            repository: makeRepository()
        )
        let result = GitHubReadResult(
            value: 7,
            completeness: .partial,
            problems: [problem],
            response: response,
            ownership: ownership
        )
        XCTAssertEqual(result.value, 7)
        XCTAssertEqual(result.completeness, .partial)
        XCTAssertEqual(Set(GitHubReadCompleteness.allCases), [.complete, .partial])
        XCTAssertFalse(String(describing: saml).contains("acme"))
        XCTAssertFalse(String(reflecting: saml).contains("acme"))
        XCTAssertFalse(String(describing: response).contains("acme"))
        XCTAssertFalse(String(reflecting: response).contains("acme"))
        XCTAssertEqual(String(describing: problem), "GitHub GraphQL problem (server message redacted)")
        XCTAssertEqual(String(reflecting: problem), "GitHub GraphQL problem (server message redacted)")
        XCTAssertTrue(Mirror(reflecting: problem).children.isEmpty)
        XCTAssertTrue(Mirror(reflecting: saml).children.isEmpty)
        XCTAssertTrue(Mirror(reflecting: response).children.isEmpty)
        XCTAssertFalse(String(describing: authentication).contains("authentication-secret"))
        XCTAssertFalse(String(reflecting: authentication).contains("authentication-secret"))
        XCTAssertTrue(Mirror(reflecting: authentication).children.isEmpty)

        let gitLab = try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com")),
            owner: "owner",
            name: "repo"
        )
        XCTAssertThrowsError(try GitHubReadOwnership(
            credential: makeAuthentication().credential.reference,
            repository: gitLab
        )) {
            XCTAssertEqual($0 as? GitHubReadError, .githubDotComRequired)
        }
    }

    func testAuthenticationFailsClosedAndRejectsStaleCredentialGeneration() async throws {
        let unauthenticated = GitHubReadAdapter(sessionConfiguration: stubConfiguration())
        await XCTAssertThrowsGitHubError(.authenticationRequired) {
            try await unauthenticated.repositoryFacts(repository: self.makeRepository())
        }
        XCTAssertThrowsError(try makeAuthentication(generation: 1, currentGeneration: 2)) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .mismatchedCredentialAuthority)
        }
    }

    func testCredentialReplacementRevokesBoundAdapterBeforeAnotherNetworkRequest() async throws {
        let capture = GitHubRequestCapture()
        GitHubStubURLProtocol.setHandler { request in
            _ = capture.record(request)
            return try StubResponse(
                status: 200,
                headers: Self.successHeaders,
                body: Self.response(operation: "GitHubRepositoryFacts")
            )
        }
        let generationOne = try makeAuthentication(
            generation: 1,
            accessToken: "generation-one-token"
        )
        let authority = TestGitHubReadCredentialAuthority(authentication: generationOne)
        let adapter = GitHubReadAdapter(
            expectedCredential: generationOne.credential.reference,
            credentialAuthority: authority,
            sessionConfiguration: stubConfiguration()
        )

        let first = try await adapter.repositoryFacts(repository: makeRepository())
        XCTAssertEqual(first.ownership.credential, generationOne.credential.reference)
        XCTAssertEqual(capture.requests.count, 1)
        XCTAssertEqual(
            capture.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer generation-one-token"
        )

        let generationTwo = try makeAuthentication(
            generation: 2,
            accessToken: "generation-two-token"
        )
        await authority.replace(with: generationTwo)
        await XCTAssertThrowsGitHubError(.authenticationRequired) {
            try await adapter.repositoryFacts(repository: self.makeRepository())
        }
        XCTAssertEqual(capture.requests.count, 1, "stale generation must fail before transport creation")
        let requestedCredentials = await authority.requestedCredentials
        XCTAssertEqual(requestedCredentials, [
            generationOne.credential.reference,
            generationOne.credential.reference,
        ])
    }

    func testCredentialRemovalRevokesBoundAdapterBeforeAnotherNetworkRequest() async throws {
        let capture = GitHubRequestCapture()
        GitHubStubURLProtocol.setHandler { request in
            _ = capture.record(request)
            return try StubResponse(
                status: 200,
                headers: Self.successHeaders,
                body: Self.response(operation: "GitHubRepositoryFacts")
            )
        }
        let authentication = try makeAuthentication(accessToken: "removed-token")
        let authority = TestGitHubReadCredentialAuthority(authentication: authentication)
        let adapter = GitHubReadAdapter(
            expectedCredential: authentication.credential.reference,
            credentialAuthority: authority,
            sessionConfiguration: stubConfiguration()
        )

        _ = try await adapter.repositoryFacts(repository: makeRepository())
        XCTAssertEqual(capture.requests.count, 1)
        await authority.replace(with: nil)
        await XCTAssertThrowsGitHubError(.authenticationRequired) {
            try await adapter.repositoryFacts(repository: self.makeRepository())
        }
        XCTAssertEqual(capture.requests.count, 1, "removed Credential must fail before transport creation")
    }

    func testSameGenerationRefreshUsesNewlyLoadedTokenForNextRequest() async throws {
        let capture = GitHubRequestCapture()
        GitHubStubURLProtocol.setHandler { request in
            _ = capture.record(request)
            return try StubResponse(
                status: 200,
                headers: Self.successHeaders,
                body: Self.response(operation: "GitHubRepositoryFacts")
            )
        }
        let original = try makeAuthentication(accessToken: "original-token")
        let authority = TestGitHubReadCredentialAuthority(authentication: original)
        let adapter = GitHubReadAdapter(
            expectedCredential: original.credential.reference,
            credentialAuthority: authority,
            sessionConfiguration: stubConfiguration()
        )

        _ = try await adapter.repositoryFacts(repository: makeRepository())
        let refreshed = try makeAuthentication(accessToken: "refreshed-token")
        await authority.replace(with: refreshed)
        _ = try await adapter.repositoryFacts(repository: makeRepository())

        XCTAssertEqual(
            capture.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer original-token", "Bearer refreshed-token"]
        )
    }

    func testSearchQuotesPlainTextAndRejectsRepositoryRetaggingWithResponseContext() async throws {
        let capture = GitHubRequestCapture()
        GitHubStubURLProtocol.setHandler { request in
            _ = capture.record(request)
            var wrongRepository = Self.repositoryIdentity
            wrongRepository["name"] = "other"
            wrongRepository["nameWithOwner"] = "attacker/other"
            wrongRepository["owner"] = ["__typename": "User", "login": "attacker"]
            var issue = Self.issue
            issue["repository"] = wrongRepository
            let body = try JSONSerialization.data(withJSONObject: [
                "data": ["search": Self.connection("SearchResultItemConnection", nodes: [issue])],
                "errors": [[
                    "message": "secret server detail",
                    "path": ["search", "nodes", 0],
                    "extensions": ["type": "PARTIAL"],
                ]],
            ])
            return StubResponse(
                status: 200,
                headers: ["X-GitHub-Request-Id": "mapping-request"],
                body: body
            )
        }
        do {
            _ = try await makeAdapter().searchRepositoryItems(
                repository: makeRepository(),
                text: #"repo:attacker/other OR is:pr "quoted" \ escape"#
            )
            XCTFail("Expected repository identity mismatch")
        } catch let error as GitHubReadError {
            guard case let .mapping(reason, problems, response) = error else {
                return XCTFail("Unexpected \(error)")
            }
            XCTAssertEqual(reason, .malformedResponse)
            XCTAssertEqual(response.requestID, "mapping-request")
            XCTAssertEqual(problems.first?.classification, "PARTIAL")
            XCTAssertFalse(String(describing: error).contains("secret server detail"))
            XCTAssertFalse(String(reflecting: error).contains("secret server detail"))
            XCTAssertTrue(Mirror(reflecting: error).children.isEmpty)
        }
        let payload = try Self.requestPayload(XCTUnwrap(capture.requests.first))
        let variables = try XCTUnwrap(payload["variables"] as? [String: Any])
        XCTAssertEqual(
            variables["query"] as? String,
            #"repo:hbmartin/gitx "repo:attacker/other OR is:pr \"quoted\" \\ escape""#
        )
    }

    func testGraphQLRateLimitAtHTTP200UsesRateLimitClassification() async throws {
        GitHubStubURLProtocol.setHandler { _ in
            StubResponse(
                status: 200,
                headers: ["X-RateLimit-Remaining": "0"],
                body: Data(#"{"errors":[{"message":"limit detail","extensions":{"type":"RATE_LIMITED"}}]}"#.utf8)
            )
        }
        do {
            _ = try await makeAdapter().repositoryFacts(repository: makeRepository())
            XCTFail("Expected GraphQL rate limit")
        } catch let error as GitHubReadError {
            guard case let .rateLimited(response) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.rateLimit.remaining, 0)
        }
    }

    func testConcurrentRequestsKeepResponseMetadataIsolated() async throws {
        GitHubStubURLProtocol.setHandler { request in
            let operation = try Self.operationName(request)
            if operation == "GitHubRepositoryFacts" {
                return try StubResponse(
                    status: 200,
                    headers: ["X-GitHub-Request-Id": "facts-request"],
                    body: Self.response(operation: operation)
                )
            }
            return try StubResponse(
                status: 200,
                headers: ["X-GitHub-Request-Id": "list-request"],
                body: Self.response(operation: operation)
            )
        }
        let adapter = try makeAdapter()
        let repository = try makeRepository()
        async let factsResult = adapter.repositoryFacts(repository: repository)
        async let pullRequestResult = adapter.pullRequests(repository: repository)
        let (facts, pullRequests) = try await(factsResult, pullRequestResult)
        XCTAssertEqual(pullRequests.response.requestID, "list-request")
        XCTAssertEqual(facts.response.requestID, "facts-request")
    }

    func testCancellationRemainsCancellationError() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request cancelled")
        GitHubCancellationURLProtocol.configure(started: started, stopped: stopped)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubCancellationURLProtocol.self]
        let authentication = try makeAuthentication()
        let adapter = GitHubReadAdapter(
            expectedCredential: authentication.credential.reference,
            credentialAuthority: TestGitHubReadCredentialAuthority(authentication: authentication),
            sessionConfiguration: configuration
        )
        let repository = try makeRepository()
        let task = Task { try await adapter.repositoryFacts(repository: repository) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation is not reclassified as a transport failure.
        } catch {
            XCTFail("Unexpected \(error)")
        }
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testRepositoryFactsHistorySearchAndPaginationPreservePartialEvidence() async throws {
        let adapter = try makeAdapter()
        let repository = try makeRepository()

        var fork = Self.repositoryFactsObject
        fork["isFork"] = true
        fork["parent"] = Self.repositoryIdentity
        fork["repositoryTopics"] = Self.connection("RepositoryTopicConnection", nodes: [[
            "__typename": "RepositoryTopic",
            "topic": ["__typename": "Topic", "name": "swift"],
        ]])
        try installGraphQLData(["repository": fork])
        let forkFacts = try await adapter.repositoryFacts(repository: repository)
        XCTAssertEqual(forkFacts.completeness, .complete)
        XCTAssertEqual(forkFacts.value.topics.availableValue, ["swift"])

        var incompleteFork = Self.repositoryFactsObject
        incompleteFork["isFork"] = true
        incompleteFork["parent"] = NSNull()
        var incompleteTopics = Self.emptyConnection("RepositoryTopicConnection")
        incompleteTopics["totalCount"] = 1
        incompleteTopics["pageInfo"] = Self.pageInfo(hasPreviousPage: true)
        incompleteFork["repositoryTopics"] = incompleteTopics
        try installGraphQLData(["repository": incompleteFork])
        let incompleteFacts = try await adapter.repositoryFacts(repository: repository)
        XCTAssertEqual(incompleteFacts.completeness, .partial)
        XCTAssertTrue(incompleteFacts.value.forkRelationship.isUnavailable)
        XCTAssertTrue(incompleteFacts.value.topics.isUnavailable)

        var nextConnection = Self.connection("PullRequestConnection", nodes: [Self.pullRequest])
        nextConnection["pageInfo"] = Self.pageInfo(hasNextPage: true, endCursor: "next")
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "pullRequests": nextConnection,
        ]])
        let nextPage = try await adapter.pullRequests(repository: repository)
        XCTAssertEqual(nextPage.value.nextCursor?.value, "next")

        var bot = Self.actor
        bot["__typename"] = "Bot"
        bot["login"] = "dependabot"
        bot.removeValue(forKey: "name")
        var botPullRequest = Self.pullRequest
        botPullRequest["author"] = bot
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository",
            "pullRequests": Self.connection("PullRequestConnection", nodes: [botPullRequest]),
        ]])
        let botResult = try await adapter.pullRequests(repository: repository)
        XCTAssertEqual(botResult.value.items.first?.author.availableValue?.actorValue?.kind, .bot)

        var enterpriseAccount = Self.actor
        enterpriseAccount["__typename"] = "EnterpriseUserAccount"
        enterpriseAccount["login"] = "managed-user"
        var enterprisePullRequest = Self.pullRequest
        enterprisePullRequest["author"] = enterpriseAccount
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository",
            "pullRequests": Self.connection(
                "PullRequestConnection",
                nodes: [enterprisePullRequest]
            ),
        ]])
        let enterpriseResult = try await adapter.pullRequests(repository: repository)
        XCTAssertEqual(
            enterpriseResult.value.items.first?.author.availableValue?.actorValue?.kind,
            .unknown
        )

        let droppedConnection: [String: Any] = [
            "__typename": "PullRequestConnection", "totalCount": 1,
            "pageInfo": Self.pageInfo, "nodes": [NSNull()],
        ]
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "pullRequests": droppedConnection,
        ]])
        let droppedPage = try await adapter.pullRequests(repository: repository)
        XCTAssertEqual(droppedPage.completeness, .partial)

        var historyPullRequest = Self.pullRequest
        historyPullRequest["pullRequestState"] = "MERGED"
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "object": [
                "__typename": "Commit", "oid": "abcdef12", "statusCheckRollup": NSNull(),
                "associatedPullRequests": Self.connection(
                    "PullRequestConnection",
                    nodes: [historyPullRequest]
                ),
            ],
        ]])
        let related = try await adapter.historyOverlay(
            repository: repository,
            commit: ForgeCommitID("abcdef12")
        )
        XCTAssertEqual(related.value.pullRequests.availableValue?.items.count, 1)
        XCTAssertEqual(related.completeness, .partial)

        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "object": [
                "__typename": "Commit", "oid": "abcdef12",
                "statusCheckRollup": ["__typename": "StatusCheckRollup", "state": "PENDING"],
                "associatedPullRequests": NSNull(),
            ],
        ]])
        let noAssociations = try await adapter.historyOverlay(
            repository: repository,
            commit: ForgeCommitID("abcdef12")
        )
        XCTAssertTrue(noAssociations.value.pullRequests.isUnavailable)

        try installGraphQLData(["search": Self.connection(
            "SearchResultItemConnection",
            nodes: [["__typename": "Repository"]]
        )])
        let unknownSearchItem = try await adapter.searchRepositoryItems(
            repository: repository,
            text: "unknown"
        )
        XCTAssertEqual(unknownSearchItem.value.items, [])
        XCTAssertEqual(unknownSearchItem.completeness, .partial)

        try installGraphQLData(["repository": NSNull()])
        await XCTAssertThrowsMappingError(.repositoryNotFound) {
            try await adapter.repositoryFacts(repository: repository)
        }
    }

    func testDetailConnectionsFailClosedAndMapEveryConcreteActorShape() async throws {
        let adapter = try makeAdapter()
        let repository = try makeRepository()
        let number = try ForgeItemNumber(7)

        var organization = Self.actor
        organization["__typename"] = "Organization"
        organization["name"] = "GitX Org"
        var details = Self.pullRequest
        details["author"] = organization
        details["headRepository"] = NSNull()
        details["baseRepository"] = NSNull()
        details["labels"] = NSNull()
        details["reviewDecision"] = "CHANGES_REQUESTED"
        var missingSubmittedReview = Self.timelineEvent(
            "PullRequestReview",
            id: "missing-submitted"
        )
        missingSubmittedReview.merge([
            "body": "must not guess createdAt", "state": "APPROVED",
            "submittedAt": NSNull(), "author": Self.actor,
            "commit": ["__typename": "Commit", "oid": "abcdef12"],
        ]) { _, new in new }
        details.merge([
            "body": "body", "mergeable": "UNKNOWN",
            "assignedActors": [
                "__typename": "AssigneeConnection", "totalCount": 2,
                "pageInfo": Self.pageInfo, "nodes": [Self.mannequin, ["__typename": "Milestone"]],
            ],
            "milestone": Self.closedMilestone,
            "participants": Self.emptyConnection("UserConnection"),
            "reviewRequests": NSNull(), "latestReviews": NSNull(),
            "closingIssuesReferences": NSNull(), "statusCheckRollup": NSNull(),
            "timelineItems": Self.connection(
                "PullRequestTimelineItemsConnection",
                nodes: [
                    Self.issueComment,
                    missingSubmittedReview,
                    [
                        "__typename": "CrossReferencedEvent", "id": "unknown-cross-reference",
                        "createdAt": "2026-07-29T12:34:56Z", "actor": Self.actor,
                        "source": ["__typename": "Repository"],
                    ],
                ]
            ),
        ]) { _, new in new }
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "pullRequest": details,
        ]])
        let partial = try await adapter.pullRequestDetails(repository: repository, number: number)
        XCTAssertEqual(partial.completeness, .partial)
        XCTAssertTrue(partial.value.details.summary.head.isUnavailable)
        XCTAssertTrue(partial.value.details.summary.base.isUnavailable)
        XCTAssertTrue(partial.value.details.summary.labels.isUnavailable)
        XCTAssertTrue(partial.value.details.assignees.isUnavailable)
        XCTAssertTrue(partial.value.details.reviewers.isUnavailable)
        XCTAssertTrue(partial.value.details.linkedIssues.isUnavailable)
        XCTAssertTrue(partial.value.details.checks.isUnavailable)
        XCTAssertEqual(partial.value.details.timeline.availableValue?.items.count, 1)
        XCTAssertEqual(
            partial.value.details.timeline.availableValue?.items.first?.id.value,
            "issue-comment"
        )

        var matching = Self.completePullRequestDetails
        matching["reviewRequests"] = Self.connection("ReviewRequestConnection", nodes: [
            ["__typename": "ReviewRequest", "id": "actor-request", "requestedReviewer": Self.actor],
            ["__typename": "ReviewRequest", "id": "mannequin-request", "requestedReviewer": Self.mannequin],
        ])
        matching["latestReviews"] = Self.connection("PullRequestReviewConnection", nodes: [[
            "__typename": "PullRequestReview", "id": "latest", "state": "DISMISSED",
            "submittedAt": "2026-07-29T12:34:56Z", "author": Self.actor,
        ]])
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "pullRequest": matching,
        ]])
        let mergedReviewers = try await adapter.pullRequestDetails(repository: repository, number: number)
        XCTAssertEqual(mergedReviewers.value.details.reviewers.availableValue?.count, 2)
        XCTAssertEqual(
            mergedReviewers.value.details.reviewers.availableValue?.first?.latestReviewState,
            .dismissed
        )
        XCTAssertEqual(
            mergedReviewers.value.details.reviewers.availableValue?[1].participant.actorValue?.kind,
            .unknown
        )

        var incompleteReviewers = Self.completePullRequestDetails
        var requests = Self.connection("ReviewRequestConnection", nodes: [
            ["__typename": "ReviewRequest", "id": "request", "requestedReviewer": Self.team],
            [
                "__typename": "ReviewRequest", "id": "unknown-request",
                "requestedReviewer": ["__typename": "Repository"],
            ],
        ])
        requests["pageInfo"] = Self.pageInfo(hasNextPage: true, endCursor: "more-reviewers")
        incompleteReviewers["reviewRequests"] = requests
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "pullRequest": incompleteReviewers,
        ]])
        let incompleteReviewerResult = try await adapter.pullRequestDetails(
            repository: repository,
            number: number
        )
        XCTAssertTrue(incompleteReviewerResult.value.details.reviewers.isUnavailable)

        var unknownChecks = Self.completePullRequestDetails
        var contexts = Self.connection(
            "StatusCheckRollupContextConnection",
            nodes: [["__typename": "Deployment"]]
        )
        contexts["pageInfo"] = Self.pageInfo(hasNextPage: true, endCursor: "more-checks")
        unknownChecks["statusCheckRollup"] = [
            "__typename": "StatusCheckRollup", "state": "EXPECTED", "contexts": contexts,
        ]
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "pullRequest": unknownChecks,
        ]])
        let checks = try await adapter.pullRequestDetails(repository: repository, number: number)
        XCTAssertTrue(checks.value.details.checks.isUnavailable)
        XCTAssertEqual(checks.value.nextCheckCursor?.value, "more-checks")

        var issue = Self.issue
        issue["labels"] = NSNull()
        issue.merge([
            "body": "body",
            "assignedActors": Self.emptyConnection("AssigneeConnection"),
            "milestone": Self.closedMilestone,
            "participants": Self.emptyConnection("UserConnection"),
            "timelineItems": Self.connection(
                "IssueTimelineItemsConnection",
                nodes: [
                    Self.issueComment,
                    [
                        "__typename": "CrossReferencedEvent", "id": "unknown-issue-cross-reference",
                        "createdAt": "2026-07-29T12:34:56Z", "actor": Self.actor,
                        "source": ["__typename": "Repository"],
                    ],
                ]
            ),
        ]) { _, new in new }
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "issue": issue,
        ]])
        let issueResult = try await adapter.issueDetails(repository: repository, number: number)
        XCTAssertEqual(issueResult.completeness, .partial)
        XCTAssertTrue(issueResult.value.summary.labels.isUnavailable)
        guard case let .available(issueMilestone) = issueResult.value.milestone else {
            return XCTFail("Expected mapped milestone")
        }
        XCTAssertNotNil(issueMilestone)
        XCTAssertEqual(issueResult.value.timeline.availableValue?.items.count, 1)
    }

    func testReviewAndAttentionConnectionsExposeUnknownAndTruncatedDataAsUnavailable() async throws {
        let adapter = try makeAdapter()
        let repository = try makeRepository()
        let number = try ForgeItemNumber(7)

        let droppedComments: [String: Any] = [
            "__typename": "PullRequestReviewCommentConnection", "totalCount": 1,
            "pageInfo": Self.pageInfo, "nodes": [NSNull()],
        ]
        let unknownThread: [String: Any] = [
            "__typename": "PullRequestReviewThread", "id": "unknown-thread",
            "isResolved": false, "isOutdated": false, "path": "Sources/App.swift",
            "subjectType": "FUTURE_SUBJECT", "diffSide": "FUTURE_SIDE",
            "startLine": NSNull(), "line": NSNull(), "startDiffSide": "FUTURE_SIDE",
            "originalStartLine": NSNull(), "originalLine": NSNull(),
            "comments": droppedComments,
        ]
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "pullRequest": [
                "__typename": "PullRequest", "id": "pr",
                "reviewThreads": Self.connection(
                    "PullRequestReviewThreadConnection",
                    nodes: [unknownThread]
                ),
            ],
        ]])
        let threads = try await adapter.reviewThreads(repository: repository, pullRequestNumber: number)
        XCTAssertEqual(threads.completeness, .partial)
        XCTAssertTrue(threads.value.items[0].anchor.isUnavailable)
        XCTAssertEqual(threads.value.items[0].comments.availableValue?.items, [])
        XCTAssertEqual(threads.value.items[0].comments.availableValue?.totalCount, 1)

        try installGraphQLData(["node": ["__typename": "Issue", "id": "issue"]])
        await XCTAssertThrowsMappingError(.objectNotFound) {
            try await adapter.reviewThreadComments(
                repository: repository,
                threadID: ForgeObjectID(forge: repository.forge, value: "thread")
            )
        }

        var candidate = Self.pullRequest
        candidate.merge([
            "repository": Self.repositoryIdentity, "body": "body",
            "assignedActors": Self.emptyConnection("AssigneeConnection"),
            "participants": Self.emptyConnection("UserConnection"),
            "reviewRequests": NSNull(),
            "comments": Self.emptyConnection("IssueCommentConnection"),
            "latestReviews": NSNull(),
            "reviewThreads": Self.emptyConnection("PullRequestReviewThreadConnection"),
        ]) { _, new in new }
        try installGraphQLData([
            "viewer": Self.actor,
            "search": Self.connection("SearchResultItemConnection", nodes: [candidate]),
        ])
        let absentConnections = try await adapter.attentionCandidates(
            repository: repository,
            searchText: "is:open"
        )
        XCTAssertEqual(absentConnections.completeness, .partial)
        XCTAssertTrue(absentConnections.value.candidates.items[0].requestedReviewers.isUnavailable)
        XCTAssertTrue(absentConnections.value.candidates.items[0].activities.isUnavailable)

        var incompleteActivityComments = Self.emptyConnection("IssueCommentConnection")
        incompleteActivityComments["pageInfo"] = Self.pageInfo(
            hasPreviousPage: true,
            startCursor: "older-activity"
        )
        candidate["reviewRequests"] = Self.emptyConnection("ReviewRequestConnection")
        candidate["comments"] = incompleteActivityComments
        candidate["latestReviews"] = Self.emptyConnection("PullRequestReviewConnection")
        try installGraphQLData([
            "viewer": Self.actor,
            "search": Self.connection("SearchResultItemConnection", nodes: [candidate]),
        ])
        let incompleteActivities = try await adapter.attentionCandidates(
            repository: repository,
            searchText: "is:open"
        )
        XCTAssertTrue(incompleteActivities.value.candidates.items[0].activities.isUnavailable)

        var truncatedThread = unknownThread
        var priorComments = Self.connection("PullRequestReviewCommentConnection", nodes: [Self.reviewComment])
        priorComments["pageInfo"] = Self.pageInfo(hasPreviousPage: true, startCursor: "prior")
        truncatedThread["comments"] = priorComments
        candidate["reviewRequests"] = Self.emptyConnection("ReviewRequestConnection")
        candidate["latestReviews"] = Self.emptyConnection("PullRequestReviewConnection")
        candidate["reviewThreads"] = Self.connection(
            "PullRequestReviewThreadConnection",
            nodes: [truncatedThread]
        )
        try installGraphQLData([
            "viewer": Self.actor,
            "search": Self.connection("SearchResultItemConnection", nodes: [candidate]),
        ])
        let truncatedComments = try await adapter.attentionCandidates(
            repository: repository,
            searchText: "is:open"
        )
        XCTAssertEqual(truncatedComments.completeness, .partial)
        XCTAssertTrue(
            truncatedComments.value.candidates.items[0]
                .reviewThreads.availableValue?.first?.comments.isUnavailable == true
        )

        var incompleteThreadConnection = Self.connection(
            "PullRequestReviewThreadConnection",
            nodes: [unknownThread]
        )
        incompleteThreadConnection["pageInfo"] = Self.pageInfo(hasNextPage: true, endCursor: "more-threads")
        candidate["reviewThreads"] = incompleteThreadConnection
        try installGraphQLData([
            "viewer": Self.actor,
            "search": Self.connection("SearchResultItemConnection", nodes: [candidate]),
        ])
        let incompleteThreads = try await adapter.attentionCandidates(
            repository: repository,
            searchText: "is:open"
        )
        XCTAssertTrue(incompleteThreads.value.candidates.items[0].reviewThreads.isUnavailable)

        try installGraphQLData([
            "viewer": ["__typename": "Mannequin", "login": "retired", "avatarUrl": ""],
            "search": Self.emptyConnection("SearchResultItemConnection"),
        ])
        await XCTAssertThrowsGitHubError(.malformedResponse) {
            try await adapter.attentionCandidates(repository: repository, searchText: "is:open")
        }

        try installGraphQLData([
            "viewer": Self.actor,
            "search": Self.connection(
                "SearchResultItemConnection",
                nodes: [["__typename": "Repository"]]
            ),
        ])
        let unknownCandidateResult = try await adapter.attentionCandidates(
            repository: repository,
            searchText: "is:open"
        )
        XCTAssertEqual(unknownCandidateResult.completeness, .partial)
    }

    func testReviewThreadCommentsRejectCrossRepositoryRetagWithResponseContext() async throws {
        var wrongRepository = Self.repositoryIdentity
        wrongRepository["name"] = "other"
        wrongRepository["nameWithOwner"] = "attacker/other"
        wrongRepository["owner"] = ["__typename": "User", "login": "attacker"]
        let body = try JSONSerialization.data(withJSONObject: [
            "data": ["node": [
                "__typename": "PullRequestReviewThread", "id": "retagged-thread",
                "pullRequest": [
                    "__typename": "PullRequest", "repository": wrongRepository,
                ],
                "comments": Self.connection(
                    "PullRequestReviewCommentConnection",
                    nodes: [Self.reviewComment]
                ),
            ]],
            "errors": [[
                "message": "partial server detail",
                "path": ["node", "comments"],
                "extensions": ["type": "PARTIAL"],
            ]],
        ])
        GitHubStubURLProtocol.setHandler { _ in
            StubResponse(
                status: 200,
                headers: ["X-GitHub-Request-Id": "thread-retag-request"],
                body: body
            )
        }

        do {
            let repository = try makeRepository()
            _ = try await makeAdapter().reviewThreadComments(
                repository: repository,
                threadID: ForgeObjectID(forge: repository.forge, value: "retagged-thread")
            )
            XCTFail("Expected repository identity mismatch")
        } catch let error as GitHubReadError {
            guard case let .mapping(reason, problems, response) = error else {
                return XCTFail("Unexpected \(error)")
            }
            XCTAssertEqual(reason, .malformedResponse)
            XCTAssertEqual(problems.first?.classification, "PARTIAL")
            XCTAssertEqual(response.requestID, "thread-retag-request")
            XCTAssertFalse(String(describing: error).contains("partial server detail"))
        }
    }

    func testUnknownCheckEnumsBecomeUnavailableWithoutGuessingKnownStates() async throws {
        let adapter = try makeAdapter()
        let repository = try makeRepository()
        let number = try ForgeItemNumber(7)

        var unknownSummary = Self.pullRequest
        unknownSummary["statusCheckRollup"] = [
            "__typename": "StatusCheckRollup", "state": "FUTURE_STATE",
        ]
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository",
            "pullRequests": Self.connection("PullRequestConnection", nodes: [unknownSummary]),
        ]])
        let unknownList = try await adapter.pullRequests(repository: repository)
        XCTAssertEqual(unknownList.completeness, .partial)
        XCTAssertTrue(unknownList.value.items[0].checkRollup.isUnavailable)

        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "object": [
                "__typename": "Commit", "oid": "abcdef12",
                "statusCheckRollup": [
                    "__typename": "StatusCheckRollup", "state": "FUTURE_STATE",
                ],
                "associatedPullRequests": Self.emptyConnection("PullRequestConnection"),
            ],
        ]])
        let unknownHistory = try await adapter.historyOverlay(
            repository: repository,
            commit: ForgeCommitID("abcdef12")
        )
        XCTAssertEqual(unknownHistory.completeness, .partial)
        XCTAssertTrue(unknownHistory.value.checkRollup.isUnavailable)

        var unknownDetails = Self.completePullRequestDetails
        unknownDetails["statusCheckRollup"] = [
            "__typename": "StatusCheckRollup", "state": "SUCCESS",
            "contexts": Self.connection("StatusCheckRollupContextConnection", nodes: [
                Self.checkRun(id: "unknown-status", status: "FUTURE_STATUS", conclusion: "SUCCESS"),
                Self.checkRun(id: "unknown-conclusion", status: "COMPLETED", conclusion: "FUTURE_RESULT"),
                Self.statusContext(id: "unknown-context", state: "FUTURE_STATE"),
            ]),
        ]
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "pullRequest": unknownDetails,
        ]])
        let unknownChecks = try await adapter.pullRequestDetails(
            repository: repository,
            number: number
        )
        XCTAssertEqual(unknownChecks.completeness, .partial)
        XCTAssertTrue(unknownChecks.value.details.checks.isUnavailable)

        var knownDetails = Self.completePullRequestDetails
        knownDetails["statusCheckRollup"] = [
            "__typename": "StatusCheckRollup", "state": "EXPECTED",
            "contexts": Self.connection("StatusCheckRollupContextConnection", nodes: [
                Self.checkRun(
                    id: "action-required",
                    status: "COMPLETED",
                    conclusion: "ACTION_REQUIRED"
                ),
                Self.checkRun(id: "active", status: "IN_PROGRESS", conclusion: nil),
                Self.statusContext(id: "expected", state: "EXPECTED"),
            ]),
        ]
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "pullRequest": knownDetails,
        ]])
        let knownChecks = try await adapter.pullRequestDetails(
            repository: repository,
            number: number
        )
        XCTAssertEqual(knownChecks.completeness, .complete)
        XCTAssertEqual(knownChecks.value.details.summary.checkRollup.availableValue, .running)
        XCTAssertEqual(
            knownChecks.value.details.checks.availableValue?.map(\.state),
            [.attentionRequired, .running, .running]
        )
    }

    func testConnectionCountMismatchAndNestedCommentContinuationRemainVisibleAndPartial() async throws {
        let adapter = try makeAdapter()
        let repository = try makeRepository()
        let number = try ForgeItemNumber(7)

        var mismatchedPullRequests = Self.connection(
            "PullRequestConnection",
            nodes: [Self.pullRequest]
        )
        mismatchedPullRequests["totalCount"] = 2
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository",
            "pullRequests": mismatchedPullRequests,
        ]])
        let pullRequests = try await adapter.pullRequests(repository: repository)
        XCTAssertEqual(pullRequests.completeness, .partial)
        XCTAssertEqual(pullRequests.value.items.count, 1)
        XCTAssertEqual(pullRequests.value.totalCount, 2)

        var incompleteIssue = Self.issue
        incompleteIssue["labels"] = NSNull()
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository",
            "issues": Self.connection("IssueConnection", nodes: [incompleteIssue]),
        ]])
        let issues = try await adapter.issues(repository: repository)
        XCTAssertEqual(issues.completeness, .partial)
        XCTAssertTrue(issues.value.items[0].labels.isUnavailable)

        var issueDetails = incompleteIssue
        issueDetails.merge([
            "body": "body",
            "assignedActors": Self.emptyConnection("AssigneeConnection"),
            "milestone": NSNull(),
            "participants": Self.emptyConnection("UserConnection"),
            "timelineItems": Self.emptyConnection("IssueTimelineItemsConnection"),
        ]) { _, new in new }
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "issue": issueDetails,
        ]])
        let details = try await adapter.issueDetails(repository: repository, number: number)
        XCTAssertEqual(details.completeness, .partial)
        XCTAssertTrue(details.value.summary.labels.isUnavailable)

        var nestedComments = Self.connection(
            "PullRequestReviewCommentConnection",
            nodes: [Self.reviewComment]
        )
        nestedComments["totalCount"] = 2
        nestedComments["pageInfo"] = Self.pageInfo(hasNextPage: true, endCursor: "more-comments")
        let thread: [String: Any] = [
            "__typename": "PullRequestReviewThread", "id": "paginated-thread",
            "isResolved": false, "isOutdated": false, "path": "Sources/App.swift",
            "subjectType": "LINE", "diffSide": "RIGHT", "startLine": 7,
            "line": 8, "startDiffSide": "RIGHT", "originalStartLine": 6,
            "originalLine": 7, "comments": nestedComments,
        ]
        try installGraphQLData(["repository": [
            "__typename": "Repository", "id": "repository", "pullRequest": [
                "__typename": "PullRequest", "id": "pr",
                "reviewThreads": Self.connection(
                    "PullRequestReviewThreadConnection",
                    nodes: [thread]
                ),
            ],
        ]])
        let threads = try await adapter.reviewThreads(
            repository: repository,
            pullRequestNumber: number
        )
        XCTAssertEqual(threads.completeness, .partial)
        XCTAssertEqual(threads.value.items[0].comments.availableValue?.items.count, 1)
        XCTAssertEqual(threads.value.items[0].comments.availableValue?.totalCount, 2)
        XCTAssertEqual(
            threads.value.items[0].comments.availableValue?.nextCursor?.value,
            "more-comments"
        )

        var mismatchedComments = Self.connection(
            "PullRequestReviewCommentConnection",
            nodes: [Self.reviewComment]
        )
        mismatchedComments["totalCount"] = 2
        try installGraphQLData(["node": [
            "__typename": "PullRequestReviewThread", "id": "mismatched-comments",
            "pullRequest": [
                "__typename": "PullRequest", "repository": Self.repositoryIdentity,
            ],
            "comments": mismatchedComments,
        ]])
        let comments = try await adapter.reviewThreadComments(
            repository: repository,
            threadID: ForgeObjectID(forge: repository.forge, value: "mismatched-comments")
        )
        XCTAssertEqual(comments.completeness, .partial)
        XCTAssertEqual(comments.value.items.count, 1)
        XCTAssertEqual(comments.value.totalCount, 2)
    }
}

private extension GitHubReadAdapterTests {
    static let successHeaders = [
        "Content-Type": "application/json",
        "X-GitHub-Request-Id": "request-id",
        "X-RateLimit-Limit": "5000",
        "X-RateLimit-Remaining": "4999",
        "X-RateLimit-Used": "1",
        "X-RateLimit-Reset": "1785328496",
        "Retry-After": "12",
        "X-RateLimit-Resource": "graphql",
    ]

    static let operationOrder = [
        "GitHubRepositoryFacts", "GitHubPullRequestList", "GitHubIssueList",
        "GitHubPullRequestDetails", "GitHubIssueDetails", "GitHubHistoryOverlay",
        "GitHubRepositoryItemSearch", "GitHubAttentionCandidates",
        "GitHubPullRequestReviewThreads", "GitHubPullRequestReviewThreadComments",
    ]

    static var pageInfo: [String: Any] {
        [
            "hasPreviousPage": false,
            "__typename": "PageInfo",
            "startCursor": NSNull(),
            "hasNextPage": false,
            "endCursor": NSNull(),
        ]
    }

    static func pageInfo(
        hasPreviousPage: Bool = false,
        startCursor: String? = nil,
        hasNextPage: Bool = false,
        endCursor: String? = nil
    ) -> [String: Any] {
        [
            "hasPreviousPage": hasPreviousPage,
            "__typename": "PageInfo",
            "startCursor": startCursor ?? NSNull(),
            "hasNextPage": hasNextPage,
            "endCursor": endCursor ?? NSNull(),
        ]
    }

    static func emptyConnection(_ type: String) -> [String: Any] {
        ["__typename": type, "totalCount": 0, "pageInfo": pageInfo, "nodes": []]
    }

    static var actor: [String: Any] {
        [
            "__typename": "User", "id": "actor", "login": "octocat",
            "name": "Octo", "avatarUrl": "https://avatars.githubusercontent.com/u/1",
        ]
    }

    static var repositoryIdentity: [String: Any] {
        [
            "__typename": "Repository", "id": "repository", "name": "gitx",
            "nameWithOwner": "hbmartin/gitx", "owner": ["__typename": "User", "login": "hbmartin"],
        ]
    }

    static var labelConnection: [String: Any] {
        connection("LabelConnection", nodes: [label])
    }

    static var label: [String: Any] {
        [
            "__typename": "Label", "id": "label", "name": "enhancement",
            "description": "New feature", "color": "a0b1c2",
        ]
    }

    static var mannequin: [String: Any] {
        [
            "__typename": "Mannequin", "mannequinID": "mannequin",
            "mannequinLogin": "retired",
            "mannequinAvatarURL": "https://avatars.githubusercontent.com/u/2",
            "id": "mannequin", "login": "retired",
            "avatarUrl": "https://avatars.githubusercontent.com/u/2",
        ]
    }

    static var team: [String: Any] {
        [
            "__typename": "Team", "teamID": "team", "teamName": "Core",
            "teamSlug": "core", "teamAvatarURL": "https://avatars.githubusercontent.com/t/1",
        ]
    }

    static var milestone: [String: Any] {
        [
            "__typename": "Milestone", "id": "milestone", "number": 1,
            "title": "v1", "description": "First", "state": "OPEN",
            "dueOn": "2026-07-29T12:34:56Z",
        ]
    }

    static var closedMilestone: [String: Any] {
        var value = milestone
        value["state"] = "CLOSED"
        return value
    }

    static var reviewComment: [String: Any] {
        [
            "__typename": "PullRequestReviewComment", "id": "review-comment",
            "body": "reply", "createdAt": "2026-07-29T12:34:56Z",
            "updatedAt": "2026-07-29T12:34:56Z", "author": actor,
            "replyTo": ["__typename": "PullRequestReviewComment", "id": "root-comment"],
        ]
    }

    static var issueComment: [String: Any] {
        [
            "__typename": "IssueComment", "id": "issue-comment", "body": "comment",
            "createdAt": "2026-07-29T12:34:56Z", "updatedAt": "2026-07-29T12:34:56Z",
            "author": actor,
        ]
    }

    static func checkRun(
        id: String,
        status: String,
        conclusion: String?
    ) -> [String: Any] {
        [
            "__typename": "CheckRun", "id": id, "name": id,
            "summary": NSNull(), "status": status,
            "conclusion": conclusion ?? NSNull(), "detailsUrl": NSNull(),
            "startedAt": NSNull(), "completedAt": NSNull(),
        ]
    }

    static func statusContext(id: String, state: String) -> [String: Any] {
        [
            "__typename": "StatusContext", "id": id, "context": id,
            "description": NSNull(), "state": state, "targetUrl": NSNull(),
            "createdAt": "2026-07-29T12:34:56Z",
            "updatedAt": "2026-07-29T12:34:56Z",
        ]
    }

    static var secondIssueComment: [String: Any] {
        var value = issueComment
        value["id"] = "issue-comment-2"
        return value
    }

    static func timelineEvent(_ type: String, id: String) -> [String: Any] {
        [
            "__typename": type, "id": id, "createdAt": "2026-07-29T12:34:56Z",
            "actor": actor,
        ]
    }

    static var timelineItems: [[String: Any]] {
        var review = timelineEvent("PullRequestReview", id: "review")
        review.merge([
            "body": "approved", "state": "APPROVED",
            "submittedAt": "2026-07-29T12:34:57Z", "author": actor,
            "commit": ["__typename": "Commit", "oid": "abcdef12"],
        ]) { _, new in new }
        var merged = timelineEvent("MergedEvent", id: "merged")
        merged["commit"] = ["__typename": "Commit", "oid": "abcdef12"]
        var assigned = timelineEvent("AssignedEvent", id: "assigned")
        assigned["assignee"] = actor
        var unassigned = timelineEvent("UnassignedEvent", id: "unassigned")
        unassigned["assignee"] = mannequin
        var labeled = timelineEvent("LabeledEvent", id: "labeled")
        labeled["label"] = label
        var unlabeled = timelineEvent("UnlabeledEvent", id: "unlabeled")
        unlabeled["label"] = label
        var milestoned = timelineEvent("MilestonedEvent", id: "milestoned")
        milestoned["milestoneTitle"] = "v1"
        var demilestoned = timelineEvent("DemilestonedEvent", id: "demilestoned")
        demilestoned["milestoneTitle"] = "v1"
        var renamed = timelineEvent("RenamedTitleEvent", id: "renamed")
        renamed["previousTitle"] = "Old"
        renamed["currentTitle"] = "New"
        var issueCross = timelineEvent("CrossReferencedEvent", id: "cross-issue")
        issueCross["source"] = [
            "__typename": "Issue", "number": 9, "issueState": "OPEN", "title": "Cross issue",
            "repository": repositoryIdentity,
        ]
        var pullCross = timelineEvent("CrossReferencedEvent", id: "cross-pr")
        pullCross["source"] = [
            "__typename": "PullRequest", "number": 10, "pullRequestState": "OPEN",
            "title": "Cross pull", "repository": repositoryIdentity,
        ]
        return [
            issueComment, review, timelineEvent("ClosedEvent", id: "closed"),
            timelineEvent("ReopenedEvent", id: "reopened"), merged, assigned, unassigned,
            labeled, unlabeled, milestoned, demilestoned, renamed, issueCross, pullCross,
        ]
    }

    static var issueTimelineItems: [[String: Any]] {
        timelineItems.filter {
            !["PullRequestReview", "MergedEvent"].contains($0["__typename"] as? String)
        }
    }

    static var pullRequest: [String: Any] {
        [
            "__typename": "PullRequest", "id": "pr", "number": 7,
            "pullRequestState": "OPEN", "isDraft": false, "title": "Adapter",
            "createdAt": "2026-07-29T12:34:56.123Z", "updatedAt": "2026-07-29T12:34:56Z",
            "closedAt": NSNull(), "mergedAt": NSNull(), "author": actor,
            "headRefName": "feature", "headRefOid": "abcdef12", "headRepository": repositoryIdentity,
            "baseRefName": "main", "baseRefOid": "1234abcd", "baseRepository": repositoryIdentity,
            "labels": labelConnection,
            "statusCheckRollup": ["__typename": "StatusCheckRollup", "state": "SUCCESS"],
            "reviewDecision": NSNull(),
        ]
    }

    static var issue: [String: Any] {
        [
            "__typename": "Issue", "id": "issue", "number": 7,
            "issueState": "OPEN", "title": "Issue", "createdAt": "2026-07-29T12:34:56Z",
            "updatedAt": "2026-07-29T12:34:56Z", "closedAt": NSNull(),
            "author": actor, "labels": labelConnection,
        ]
    }

    static var repositoryFactsObject: [String: Any] {
        var value = repositoryIdentity
        value.merge([
            "defaultBranchRef": ["__typename": "Ref", "name": "main"], "description": "GitX",
            "repositoryTopics": emptyConnection("RepositoryTopicConnection"),
            "visibility": "PUBLIC", "isArchived": false,
            "isFork": false, "viewerPermission": "WRITE", "viewerCanAdminister": false,
            "viewerCanCreateIssues": true, "viewerCanUpdateTopics": false, "parent": NSNull(),
        ]) { _, new in new }
        return value
    }

    static var completePullRequestDetails: [String: Any] {
        var details = pullRequest
        details.merge([
            "body": "body", "mergeable": "CONFLICTING",
            "assignedActors": emptyConnection("AssigneeConnection"),
            "milestone": NSNull(),
            "participants": emptyConnection("UserConnection"),
            "reviewRequests": emptyConnection("ReviewRequestConnection"),
            "latestReviews": emptyConnection("PullRequestReviewConnection"),
            "closingIssuesReferences": emptyConnection("IssueConnection"),
            "statusCheckRollup": [
                "__typename": "StatusCheckRollup", "state": "SUCCESS",
                "contexts": emptyConnection("StatusCheckRollupContextConnection"),
            ],
            "timelineItems": emptyConnection("PullRequestTimelineItemsConnection"),
        ]) { _, new in new }
        return details
    }

    static func response(operation: String) throws -> Data {
        let data: [String: Any]
        switch operation {
        case "GitHubRepositoryFacts": data = ["repository": repositoryFactsObject]
        case "GitHubPullRequestList":
            data = ["repository": [
                "__typename": "Repository", "id": "repository",
                "pullRequests": connection("PullRequestConnection", nodes: [pullRequest]),
            ]]
        case "GitHubIssueList":
            data = ["repository": [
                "__typename": "Repository", "id": "repository",
                "issues": connection("IssueConnection", nodes: [issue]),
            ]]
        case "GitHubPullRequestDetails":
            var details = pullRequest
            details.merge([
                "body": "body", "mergeable": "MERGEABLE",
                "assignedActors": connection("AssigneeConnection", nodes: [actor, mannequin]),
                "milestone": milestone,
                "participants": connection("UserConnection", nodes: [actor]),
                "reviewRequests": connection("ReviewRequestConnection", nodes: [[
                    "__typename": "ReviewRequest", "id": "request", "requestedReviewer": team,
                ]]),
                "latestReviews": connection("PullRequestReviewConnection", nodes: [[
                    "__typename": "PullRequestReview", "id": "review-latest", "state": "APPROVED",
                    "submittedAt": "2026-07-29T12:34:56Z", "author": actor,
                ]]),
                "closingIssuesReferences": connection("IssueConnection", nodes: [[
                    "__typename": "Issue", "id": "linked", "number": 9, "state": "OPEN",
                    "title": "Linked", "repository": repositoryIdentity,
                ]]),
                "statusCheckRollup": [
                    "__typename": "StatusCheckRollup", "state": "SUCCESS",
                    "contexts": connection("StatusCheckRollupContextConnection", nodes: [
                        [
                            "__typename": "CheckRun", "id": "check", "name": "Tests",
                            "summary": "Passed", "status": "COMPLETED", "conclusion": "SUCCESS",
                            "detailsUrl": "https://github.com/hbmartin/gitx/actions/runs/1",
                            "startedAt": "2026-07-29T12:34:56Z",
                            "completedAt": "2026-07-29T12:34:56Z",
                        ],
                        [
                            "__typename": "StatusContext", "id": "status", "context": "build",
                            "description": "Building", "state": "PENDING",
                            "targetUrl": "https://example.test/build/1",
                            "createdAt": "2026-07-29T12:34:56Z",
                            "updatedAt": "2026-07-29T12:34:56Z",
                        ],
                    ]),
                ],
                "timelineItems": connection("PullRequestTimelineItemsConnection", nodes: timelineItems),
            ]) { _, new in new }
            data = ["repository": ["__typename": "Repository", "id": "repository", "pullRequest": details]]
        case "GitHubIssueDetails":
            var details = issue
            details.merge([
                "body": "body", "assignedActors": connection("AssigneeConnection", nodes: [actor]),
                "milestone": NSNull(), "participants": connection("UserConnection", nodes: [actor]),
                "timelineItems": connection("IssueTimelineItemsConnection", nodes: issueTimelineItems),
            ]) { _, new in new }
            data = ["repository": ["__typename": "Repository", "id": "repository", "issue": details]]
        case "GitHubHistoryOverlay":
            data = ["repository": ["__typename": "Repository", "id": "repository", "object": [
                "__typename": "Commit", "oid": "abcdef12",
                "statusCheckRollup": ["__typename": "StatusCheckRollup", "state": "SUCCESS"],
                "associatedPullRequests": emptyConnection("PullRequestConnection"),
            ]]]
        case "GitHubRepositoryItemSearch":
            var searchedPullRequest = pullRequest
            searchedPullRequest["repository"] = repositoryIdentity
            var searchedIssue = issue
            searchedIssue["repository"] = repositoryIdentity
            data = ["search": connection(
                "SearchResultItemConnection",
                nodes: [searchedPullRequest, searchedIssue]
            )]
        case "GitHubAttentionCandidates":
            var candidatePullRequest = pullRequest
            candidatePullRequest.merge([
                "repository": repositoryIdentity,
                "body": "@octocat please review",
                "assignedActors": connection("AssigneeConnection", nodes: [actor, mannequin]),
                "participants": connection("UserConnection", nodes: [actor]),
                "reviewRequests": connection("ReviewRequestConnection", nodes: [[
                    "__typename": "ReviewRequest", "id": "request",
                    "requestedReviewer": team,
                ]]),
                "comments": connection(
                    "IssueCommentConnection",
                    nodes: [issueComment, secondIssueComment]
                ),
                "latestReviews": connection("PullRequestReviewConnection", nodes: [[
                    "__typename": "PullRequestReview", "id": "latest", "body": "review",
                    "state": "APPROVED", "submittedAt": "2026-07-29T12:34:57Z",
                    "author": actor,
                ]]),
                "reviewThreads": connection("PullRequestReviewThreadConnection", nodes: [[
                    "__typename": "PullRequestReviewThread", "id": "attention-thread",
                    "isResolved": false, "isOutdated": false,
                    "comments": connection("PullRequestReviewCommentConnection", nodes: [reviewComment]),
                ]]),
            ]) { _, new in new }
            var candidateIssue = issue
            candidateIssue.merge([
                "repository": repositoryIdentity,
                "body": "issue body",
                "assignedActors": emptyConnection("AssigneeConnection"),
                "participants": connection("UserConnection", nodes: [actor]),
                "comments": connection("IssueCommentConnection", nodes: [issueComment]),
            ]) { _, new in new }
            data = [
                "viewer": actor,
                "search": connection(
                    "SearchResultItemConnection",
                    nodes: [candidatePullRequest, candidateIssue]
                ),
            ]
        case "GitHubPullRequestReviewThreads":
            data = ["repository": [
                "__typename": "Repository", "id": "repository",
                "pullRequest": [
                    "__typename": "PullRequest", "id": "pr",
                    "reviewThreads": connection("PullRequestReviewThreadConnection", nodes: [[
                        "__typename": "PullRequestReviewThread", "id": "thread",
                        "isResolved": false, "isOutdated": true, "path": "Sources/App.swift",
                        "subjectType": "LINE", "diffSide": "RIGHT", "startLine": 7,
                        "line": 8, "startDiffSide": "RIGHT", "originalStartLine": 6,
                        "originalLine": 7,
                        "comments": connection("PullRequestReviewCommentConnection", nodes: [reviewComment]),
                    ]]),
                ],
            ]]
        case "GitHubPullRequestReviewThreadComments":
            data = ["node": [
                "__typename": "PullRequestReviewThread", "id": "thread",
                "pullRequest": [
                    "__typename": "PullRequest", "repository": repositoryIdentity,
                ],
                "comments": connection("PullRequestReviewCommentConnection", nodes: [reviewComment]),
            ]]
        default: throw GitHubReadError.malformedResponse
        }
        return try JSONSerialization.data(withJSONObject: ["data": data])
    }

    static func connection(_ type: String, nodes: [[String: Any]]) -> [String: Any] {
        ["__typename": type, "totalCount": nodes.count, "pageInfo": pageInfo, "nodes": nodes]
    }

    static func operationName(_ request: URLRequest) throws -> String {
        let json = try requestPayload(request)
        guard let value = json["operationName"] as? String
        else {
            throw GitHubReadError.malformedResponse
        }
        return value
    }

    static func requestPayload(_ request: URLRequest) throws -> [String: Any] {
        guard let body = request.httpBody ?? readBodyStream(request.httpBodyStream),
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            throw GitHubReadError.malformedResponse
        }
        return json
    }

    static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 {
                break
            }
            result.append(buffer, count: count)
        }
        return result
    }

    func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubStubURLProtocol.self]
        return configuration
    }

    func installGraphQLData(_ data: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: ["data": data])
        GitHubStubURLProtocol.setHandler { _ in
            StubResponse(status: 200, headers: Self.successHeaders, body: body)
        }
    }

    func makeRepository() throws -> ForgeRepositoryIdentity {
        try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            owner: "hbmartin",
            name: "gitx"
        )
    }

    func makeAuthentication(
        generation: UInt64 = 1,
        currentGeneration: UInt64? = nil,
        accessToken: String = "secret-for-test"
    ) throws -> GitHubReadAuthentication {
        let forge = try makeRepository().forge
        let accountID = try ForgeAccountID(forge: forge, value: "octocat")
        let credential = try ForgeCredentialMetadata(
            reference: ForgeCredentialReference(
                accountID: accountID,
                credentialID: ForgeCredentialID("github-test"),
                generation: ForgeCredentialGeneration(generation)
            ),
            source: .classicPersonalAccessToken
        )
        let current = try ForgeCredentialMetadata(
            reference: ForgeCredentialReference(
                accountID: accountID,
                credentialID: ForgeCredentialID("github-test"),
                generation: ForgeCredentialGeneration(currentGeneration ?? generation)
            ),
            source: .classicPersonalAccessToken
        )
        let account = try ForgeAccount(id: accountID, login: "octocat", currentCredential: current)
        return try GitHubReadAuthentication(
            account: account,
            credential: credential,
            accessToken: GitHubSecret(accessToken)
        )
    }

    func makeAdapter() throws -> GitHubReadAdapter {
        let authentication = try makeAuthentication()
        return GitHubReadAdapter(
            expectedCredential: authentication.credential.reference,
            credentialAuthority: TestGitHubReadCredentialAuthority(authentication: authentication),
            sessionConfiguration: stubConfiguration()
        )
    }

    func metadata(status: Int, remaining: Int? = nil, saml: Bool = false) -> GitHubResponseMetadata {
        GitHubResponseMetadata(
            statusCode: status,
            rateLimit: GitHubRateLimitMetadata(
                limit: nil,
                remaining: remaining,
                used: nil,
                resetAt: nil,
                retryAt: nil,
                resource: nil
            ),
            saml: saml ? GitHubSAMLMetadata(authorizationURL: URL(string: "https://github.com/orgs/acme/sso?request=1")) : nil
        )
    }

    func XCTAssertThrowsGitHubError<Value>(
        _ expected: GitHubReadError,
        operation: () async throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as GitHubReadError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
        }
    }

    func XCTAssertThrowsMappingError<Value>(
        _ expected: GitHubReadMappingFailure,
        operation: () async throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected mapping failure \(expected)", file: file, line: line)
        } catch let error as GitHubReadError {
            guard case let .mapping(reason, _, _) = error else {
                return XCTFail("Unexpected \(error)", file: file, line: line)
            }
            XCTAssertEqual(reason, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
        }
    }
}

private struct StubResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

private final class GitHubRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func record(_ request: URLRequest) -> Int {
        lock.withLock {
            storage.append(request)
            return storage.count - 1
        }
    }

    var requests: [URLRequest] {
        lock.withLock { storage }
    }
}

private actor TestGitHubReadCredentialAuthority: GitHubReadCredentialAuthority {
    private var authentication: GitHubReadAuthentication?
    private(set) var requestedCredentials: [ForgeCredentialReference] = []

    init(authentication: GitHubReadAuthentication?) {
        self.authentication = authentication
    }

    func currentAuthentication(
        for expectedCredential: ForgeCredentialReference
    ) -> GitHubReadAuthentication? {
        requestedCredentials.append(expectedCredential)
        return authentication
    }

    func replace(with authentication: GitHubReadAuthentication?) {
        self.authentication = authentication
    }
}

private final class GitHubStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> StubResponse)?

    static func setHandler(_ value: (@Sendable (URLRequest) throws -> StubResponse)?) {
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
            client?.urlProtocol(self, didFailWithError: GitHubReadError.transportFailure)
            return
        }
        do {
            let stub = try current(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.status,
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

private final class GitHubCancellationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var started: XCTestExpectation?
    private nonisolated(unsafe) static var stopped: XCTestExpectation?

    static func configure(started: XCTestExpectation, stopped: XCTestExpectation) {
        lock.withLock {
            self.started = started
            self.stopped = stopped
        }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.started }?.fulfill()
    }

    override func stopLoading() {
        Self.lock.withLock { Self.stopped }?.fulfill()
    }
}

private extension ForgeReadSection {
    var availableValue: Value? {
        guard case let .available(value) = self else { return nil }
        return value
    }

    var isUnavailable: Bool {
        if case .unavailable = self {
            return true
        }
        return false
    }
}

private extension ForgeAuthor {
    var actorValue: ForgeActor? {
        guard case let .actor(actor) = self else { return nil }
        return actor
    }
}

private extension ForgeReviewParticipant {
    var actorValue: ForgeActor? {
        guard case let .actor(actor) = self else { return nil }
        return actor
    }
}
