import ForgeKit
import Foundation
@testable import GitHubForgeAdapter
import XCTest

final class GitHubAnonymousRESTAdapterTests: XCTestCase {
    override func tearDown() {
        GitHubAnonymousURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testBudgetRequiresExplicitIntentProtectsReserveAndHonorsCooldownHeaders() async throws {
        let now = Date(timeIntervalSince1970: 1000)
        let budget = GitHubAnonymousRESTBudget(initialRemainingRequestCount: 12)

        await XCTAssertThrowsErrorAsync(try await budget.reserve(reason: .scheduledOverlay, at: now)) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .explicitRequestRequired)
        }
        _ = try await budget.reserve(reason: .repositoryOpened, at: now)
        var snapshot = await budget.current()
        XCTAssertEqual(snapshot.remainingRequestCount, 11)
        _ = try await budget.reserve(reason: .manual, at: now)
        snapshot = await budget.current()
        XCTAssertEqual(snapshot.remainingRequestCount, 10)
        await XCTAssertThrowsErrorAsync(try await budget.reserve(reason: .manual, at: now)) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .reserveProtected)
        }

        let cooldownBudget = GitHubAnonymousRESTBudget(initialRemainingRequestCount: 50)
        let firstReservation = try await cooldownBudget.reserve(reason: .repositoryOpened, at: now)
        let secondReservation = try await cooldownBudget.reserve(reason: .manual, at: now)
        await cooldownBudget.update(
            reservation: secondReservation,
            status: 429,
            headers: ["X-RateLimit-Remaining": "42", "Retry-After": "30"],
            at: now
        )
        snapshot = await cooldownBudget.current()
        XCTAssertEqual(snapshot.remainingRequestCount, 42)
        await XCTAssertThrowsErrorAsync(try await cooldownBudget.reserve(reason: .manual, at: now)) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .cooldown(until: now.addingTimeInterval(30)))
        }
        let thirdReservation = try await cooldownBudget.reserve(
            reason: .manual,
            at: now.addingTimeInterval(30)
        )

        await cooldownBudget.update(
            reservation: thirdReservation,
            status: 403,
            headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1100"],
            at: now
        )
        snapshot = await cooldownBudget.current()
        XCTAssertEqual(snapshot.cooldownDeadline, Date(timeIntervalSince1970: 1100))
        await cooldownBudget.update(
            reservation: firstReservation,
            status: 200,
            headers: ["x-ratelimit-remaining": "bad"],
            at: now.addingTimeInterval(31)
        )
        snapshot = await cooldownBudget.current()
        XCTAssertEqual(snapshot.cooldownDeadline, Date(timeIntervalSince1970: 1100))
        let resetReservation = try await cooldownBudget.reserve(
            reason: .manual,
            at: Date(timeIntervalSince1970: 1100)
        )
        await cooldownBudget.update(
            reservation: resetReservation,
            status: 200,
            headers: ["x-ratelimit-remaining": "11"],
            at: Date(timeIntervalSince1970: 1100)
        )
        snapshot = await cooldownBudget.current()
        XCTAssertEqual(snapshot.remainingRequestCount, 11)
        XCTAssertNil(snapshot.cooldownDeadline)

        await cooldownBudget.update(
            reservation: firstReservation,
            status: 200,
            headers: ["x-ratelimit-remaining": "50"],
            at: Date(timeIntervalSince1970: 1101)
        )
        let staleResponseSnapshot = await cooldownBudget.current()
        XCTAssertEqual(
            staleResponseSnapshot,
            snapshot,
            "a reservation from the prior rate window cannot mutate the current budget"
        )

        let retryOnlyBudget = GitHubAnonymousRESTBudget(initialRemainingRequestCount: 50)
        let throttledReservation = try await retryOnlyBudget.reserve(reason: .repositoryOpened, at: now)
        await retryOnlyBudget.update(
            reservation: throttledReservation,
            status: 429,
            headers: ["retry-after": "30"],
            at: now
        )
        let resumedReservation = try await retryOnlyBudget.reserve(
            reason: .manual,
            at: now.addingTimeInterval(30)
        )
        await retryOnlyBudget.update(
            reservation: resumedReservation,
            status: 200,
            headers: ["x-ratelimit-remaining": "49"],
            at: now.addingTimeInterval(30)
        )
        let resumedSnapshot = await retryOnlyBudget.current()
        XCTAssertEqual(resumedSnapshot.remainingRequestCount, 48)
        XCTAssertNil(resumedSnapshot.cooldownDeadline)
    }

    func testTwoAdapterReservationResponsesCannotRaiseBudgetOrClearActiveCooldownOutOfOrder() async throws {
        let now = Date(timeIntervalSince1970: 2000)
        let budget = GitHubAnonymousRESTBudget(initialRemainingRequestCount: 20)
        let firstAdapterReservation = try await budget.reserve(reason: .repositoryOpened, at: now)
        let secondAdapterReservation = try await budget.reserve(reason: .manual, at: now)

        await budget.update(
            reservation: secondAdapterReservation,
            status: 429,
            headers: ["x-ratelimit-remaining": "18", "retry-after": "60"],
            at: now
        )
        await budget.update(
            reservation: firstAdapterReservation,
            status: 200,
            headers: ["x-ratelimit-remaining": "19"],
            at: now.addingTimeInterval(1)
        )

        let snapshot = await budget.current()
        XCTAssertEqual(snapshot.remainingRequestCount, 18)
        XCTAssertEqual(snapshot.cooldownDeadline, now.addingTimeInterval(60))
        await XCTAssertThrowsErrorAsync(
            try await budget.reserve(reason: .manual, at: now.addingTimeInterval(1))
        ) { error in
            XCTAssertEqual(
                error as? GitHubAnonymousRESTError,
                .cooldown(until: now.addingTimeInterval(60))
            )
        }
    }

    func testRateWindowResetDoesNotClearLongerRetryCooldown() async throws {
        let now = Date(timeIntervalSince1970: 3000)
        let budget = GitHubAnonymousRESTBudget(initialRemainingRequestCount: 50)
        let reservation = try await budget.reserve(reason: .repositoryOpened, at: now)

        await budget.update(
            reservation: reservation,
            status: 429,
            headers: [
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": "3050",
                "retry-after": "120",
            ],
            at: now
        )

        await XCTAssertThrowsErrorAsync(
            try await budget.reserve(reason: .manual, at: Date(timeIntervalSince1970: 3050))
        ) { error in
            XCTAssertEqual(
                error as? GitHubAnonymousRESTError,
                .cooldown(until: Date(timeIntervalSince1970: 3120))
            )
        }
        let snapshot = await budget.current()
        XCTAssertEqual(snapshot.remainingRequestCount, 50)
        XCTAssertEqual(snapshot.cooldownDeadline, Date(timeIntervalSince1970: 3120))

        _ = try await budget.reserve(reason: .manual, at: Date(timeIntervalSince1970: 3120))
        let resumed = await budget.current()
        XCTAssertEqual(resumed.remainingRequestCount, 49)
    }

    func testRepositoryFactsUseExactCredentialFreeRequestAndPublicPartition() async throws {
        let response = response(json: [
            "default_branch": "main",
            "description": "Native Git client",
            "topics": ["git", "macos"],
            "visibility": "public",
            "archived": false,
            "parent": ["full_name": "upstream/GitX"],
        ], headers: rateHeaders.merging(["Retry-After": "15"]) { _, new in new })
        let client = QueueAnonymousClient([.success(response)])
        let clock = TestClock(Date(timeIntervalSince1970: 2000))
        let adapter = GitHubAnonymousRESTAdapter(
            client: client,
            budget: GitHubAnonymousRESTBudget(),
            now: clock.now
        )

        let result = try await adapter.repositoryFacts(repository: repository, reason: .repositoryOpened)
        XCTAssertEqual(result.completeness, .partial)
        XCTAssertEqual(result.partition.cachePartition, .publicAccess)
        XCTAssertEqual(result.partition.repository, repository)
        XCTAssertEqual(result.fetchedAt, clock.value)
        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(result.response.requestID, "request-1")
        XCTAssertEqual(result.response.rateLimit.remaining, 58)
        XCTAssertEqual(result.response.rateLimit.resetAt, Date(timeIntervalSince1970: 3000))
        XCTAssertEqual(result.response.rateLimit.retryAt, clock.value.addingTimeInterval(15))
        XCTAssertEqual(result.response.rateLimit.resource, "core")
        XCTAssertEqual(result.value.defaultBranch, try .available(ForgeRefName("main")))
        XCTAssertEqual(result.value.description, .available("Native Git client"))
        XCTAssertEqual(result.value.topics, .available(["git", "macos"]))
        XCTAssertEqual(result.value.visibility, .available(.public))
        XCTAssertEqual(result.value.isArchived, .available(false))
        XCTAssertEqual(
            result.value.forkRelationship,
            try .available(.fork(parent: ForgeRepositoryIdentity(
                forge: repository.forge,
                owner: "upstream",
                name: "GitX"
            )))
        )
        XCTAssertEqual(result.value.viewerCapabilities, .unavailable(.authenticationRequired))

        let capturedRequests = await client.requests()
        let request = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/hbmartin/gitx")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
    }

    func testRepositoryFactsRejectMultiSegmentGitHubOwnerBeforeConstructingRequest() async throws {
        let client = QueueAnonymousClient([])
        let adapter = GitHubAnonymousRESTAdapter(client: client, budget: GitHubAnonymousRESTBudget())
        let nestedOwner = try ForgeRepositoryIdentity(
            forge: repository.forge,
            owner: "organization/team",
            name: "gitx"
        )

        await XCTAssertThrowsErrorAsync(
            try await adapter.repositoryFacts(repository: nestedOwner, reason: .manual)
        ) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .invalidResponse)
        }
        let requests = await client.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testRepositoryFactsMapStandaloneUnknownVisibilityAndRejectInvalidParent() async throws {
        let standalone = response(json: [
            "default_branch": "trunk",
            "description": NSNull(),
            "archived": true,
            "visibility": "future",
        ])
        let invalidParent = response(json: [
            "default_branch": "main",
            "description": NSNull(),
            "topics": [],
            "archived": false,
            "parent": ["full_name": "not-a-pair"],
        ])
        let missingVisibility = response(json: [
            "default_branch": "main",
            "description": NSNull(),
            "archived": false,
        ])
        let client = QueueAnonymousClient([
            .success(standalone),
            .success(invalidParent),
            .success(missingVisibility),
        ])
        let adapter = makeAdapter(client: client)

        let result = try await adapter.repositoryFacts(repository: repository, reason: .manual)
        XCTAssertEqual(result.value.description, .available(nil))
        XCTAssertEqual(result.value.topics, .available([]))
        XCTAssertEqual(result.value.visibility, .available(.unknown))
        XCTAssertEqual(result.value.isArchived, .available(true))
        XCTAssertEqual(result.value.forkRelationship, .available(.standalone))

        await XCTAssertThrowsErrorAsync(
            try await adapter.repositoryFacts(repository: repository, reason: .manual)
        ) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .invalidResponse)
        }

        let missingVisibilityResult = try await adapter.repositoryFacts(repository: repository, reason: .manual)
        XCTAssertEqual(missingVisibilityResult.value.visibility, .available(.unknown))
    }

    func testPullRequestListMapsProviderNeutralValuesFiltersAndPaginates() async throws {
        var userBot = pullRequest(number: 10, state: "open", draft: false)
        userBot["user"] = user(type: "User", login: "renovate[bot]")
        let payload = [
            pullRequest(number: 7, state: "open", draft: true, userType: "Bot", link: "feature/one"),
            pullRequest(number: 8, state: "closed", draft: false, mergedAt: "2026-07-29T12:00:00.123Z"),
            userBot,
        ]
        let response = response(
            json: payload,
            headers: rateHeaders.merging(["Link": "<https://api.github.com/example?page=2>; rel=\"next\""]) { _, new in new }
        )
        let client = QueueAnonymousClient([.success(response), .success(response), .success(response)])
        let adapter = makeAdapter(client: client)

        let first = try await adapter.pullRequests(
            repository: repository,
            states: [.open, .merged],
            reason: .manual
        )
        XCTAssertEqual(first.value.items.map(\.number.rawValue), [7, 8, 10])
        XCTAssertEqual(first.value.items.map(\.state), [.open, .merged, .open])
        XCTAssertEqual(first.value.items[0].isDraft, true)
        XCTAssertEqual(first.value.items[0].title, "Pull 7")
        XCTAssertEqual(first.value.items[0].checkRollup, .unavailable(.authenticationRequired))
        XCTAssertEqual(first.value.items[0].reviewRollup, .unavailable(.authenticationRequired))
        XCTAssertEqual(first.value.items[0].labels.count, 1)
        guard case let .available(.actor(author)) = first.value.items[0].author else {
            return XCTFail("Expected actor author")
        }
        XCTAssertEqual(author.kind, .bot)
        guard case let .available(head) = first.value.items[0].head else {
            return XCTFail("Expected head")
        }
        XCTAssertEqual(head.name.value, "feature/one")
        XCTAssertEqual(head.repository?.owner, "contributor")

        let second = try await adapter.pullRequests(
            repository: repository,
            page: ForgePageCursor("rest-page:2"),
            states: [.open],
            reason: .manual
        )
        XCTAssertEqual(second.value.items.map(\.number.rawValue), [7, 10])
        let unfiltered = try await adapter.pullRequests(
            repository: repository,
            states: nil,
            reason: .manual
        )
        XCTAssertEqual(unfiltered.value.items.map(\.number.rawValue), [7, 8, 10])
        let requests = await client.requests()
        XCTAssertTrue(requests[0].url?.query?.contains("state=all") == true)
        XCTAssertTrue(requests[1].url?.query?.contains("page=2") == true)
        XCTAssertTrue(requests[1].url?.query?.contains("state=open") == true)
    }

    func testFullPullRequestPageProducesNextCursorAndClosedStateUsesClosedEndpointFilter() async throws {
        let payload = (1 ... 100).map { pullRequest(number: $0, state: "closed", draft: nil) }
        let client = QueueAnonymousClient([.success(response(json: payload))])
        let adapter = makeAdapter(client: client)

        let result = try await adapter.pullRequests(
            repository: repository,
            states: [.closed],
            reason: .repositoryOpened
        )
        XCTAssertEqual(result.value.items.count, 100)
        XCTAssertEqual(result.value.nextCursor, try ForgePageCursor("rest-page:2"))
        let capturedRequests = await client.requests()
        XCTAssertTrue(try XCTUnwrap(capturedRequests.first?.url?.query).contains("state=closed"))
    }

    func testIssuesExcludePullRequestsMapDeletedAuthorAndRespectStateCursor() async throws {
        var issue = issuePayload(number: 4, state: "closed", user: nil)
        issue["closed_at"] = "2026-07-29T12:00:00Z"
        var pull = issuePayload(number: 5, state: "open", user: user())
        pull["pull_request"] = ["url": "https://api.github.com/pulls/5"]
        let client = QueueAnonymousClient([
            .success(response(json: [issue, pull])),
            .success(response(json: [issue, pull])),
            .success(response(json: [issue, pull])),
            .success(response(json: [issue, pull])),
        ])
        let adapter = makeAdapter(client: client)

        let first = try await adapter.issues(repository: repository, states: [.closed], reason: .manual)
        XCTAssertEqual(first.value.items.map(\.number.rawValue), [4])
        XCTAssertEqual(first.value.items[0].state, .closed)
        XCTAssertEqual(first.value.items[0].author, .available(.deleted))
        XCTAssertEqual(first.value.items[0].labels.count, 1)

        _ = try await adapter.issues(
            repository: repository,
            page: ForgePageCursor("rest-page:3"),
            states: [.open, .closed],
            reason: .manual
        )
        let unfiltered = try await adapter.issues(repository: repository, states: nil, reason: .manual)
        XCTAssertEqual(unfiltered.value.items.map(\.number.rawValue), [4])
        let open = try await adapter.issues(repository: repository, states: [.open], reason: .manual)
        XCTAssertTrue(open.value.items.isEmpty)
        let requests = await client.requests()
        XCTAssertTrue(requests[0].url?.query?.contains("state=closed") == true)
        XCTAssertTrue(requests[1].url?.query?.contains("state=all") == true)
        XCTAssertTrue(requests[1].url?.query?.contains("page=3") == true)
    }

    func testPullRequestDetailsExposeAvailablePublicFieldsAndExplicitUnavailableSections() async throws {
        let payload = pullRequest(number: 9, state: "open", draft: false, mergeable: false)
        let client = QueueAnonymousClient([.success(response(json: payload))])
        let adapter = makeAdapter(client: client)

        let result = try await adapter.pullRequestDetails(
            repository: repository,
            number: ForgeItemNumber(9),
            reason: .manual
        )
        let details = result.value.details
        XCTAssertEqual(details.bodyMarkdown, .available("Body 9"))
        XCTAssertEqual(details.assignees.count, 1)
        XCTAssertEqual(details.milestone.value.flatMap { $0 }?.title, "M1")
        XCTAssertEqual(details.mergeability, .available(.conflicting))
        XCTAssertEqual(details.reviewers, .unavailable(.authenticationRequired))
        XCTAssertEqual(details.linkedIssues, .unavailable(.notRequested))
        XCTAssertEqual(details.checks, .unavailable(.authenticationRequired))
        XCTAssertEqual(details.timeline, .unavailable(.notRequested))
        XCTAssertNil(result.value.nextCheckCursor)
        let capturedRequests = await client.requests()
        XCTAssertEqual(capturedRequests.first?.url?.path, "/repos/hbmartin/gitx/pulls/9")
    }

    func testIssueDetailsExposePublicFieldsAndRejectPullRequestMarker() async throws {
        let issue = issuePayload(number: 11, state: "open", user: user(type: "Organization"))
        var pull = issue
        pull["pull_request"] = ["url": "https://api.github.com/pulls/11"]
        let client = QueueAnonymousClient([
            .success(response(json: issue)),
            .success(response(json: pull)),
        ])
        let adapter = makeAdapter(client: client)

        let result = try await adapter.issueDetails(
            repository: repository,
            number: ForgeItemNumber(11),
            reason: .repositoryOpened
        )
        XCTAssertEqual(result.value.bodyMarkdown, .available("Issue body 11"))
        XCTAssertEqual(result.value.assignees.count, 1)
        XCTAssertEqual(result.value.milestone.value.flatMap { $0 }?.number, 1)
        XCTAssertEqual(result.value.timeline, .unavailable(.notRequested))
        guard case let .available(.actor(author)) = result.value.summary.author else {
            return XCTFail("Expected organization author")
        }
        XCTAssertEqual(author.kind, .organization)

        await XCTAssertThrowsErrorAsync(
            try await adapter.issueDetails(
                repository: repository,
                number: ForgeItemNumber(11),
                reason: .manual
            )
        ) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .invalidResponse)
        }
    }

    func testStatusMalformedPayloadCursorAndRepositoryFailuresAreSafe() async throws {
        let reset = Date(timeIntervalSince1970: 4000)
        let client = QueueAnonymousClient([
            .success(response(status: 429, json: [:], headers: ["Retry-After": "5"])),
            .success(response(status: 403, json: [:], headers: [
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": "4000",
            ])),
            .success(response(status: 404, json: [:])),
            .success(response(status: 502, json: [:])),
            .success(GitHubAnonymousRESTHTTPResponse(statusCode: 200, headers: [:], data: Data("{".utf8))),
        ])
        let adapter = GitHubAnonymousRESTAdapter(
            client: client,
            budget: GitHubAnonymousRESTBudget(initialRemainingRequestCount: 100),
            now: { Date(timeIntervalSince1970: 3995) }
        )

        await XCTAssertThrowsErrorAsync(
            try await adapter.repositoryFacts(repository: repository, reason: .manual)
        ) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .rateLimited(until: reset))
        }
        // Use fresh budgets because the server cooldown deliberately gates the next request.
        let statusAdapter = makeAdapter(client: client, remaining: 100)
        await XCTAssertThrowsErrorAsync(
            try await statusAdapter.repositoryFacts(repository: repository, reason: .manual)
        ) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .rateLimited(until: reset))
        }
        let notFoundAdapter = makeAdapter(client: client, remaining: 100)
        await XCTAssertThrowsErrorAsync(
            try await notFoundAdapter.repositoryFacts(repository: repository, reason: .manual)
        ) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .notFound)
        }
        let serverAdapter = makeAdapter(client: client, remaining: 100)
        await XCTAssertThrowsErrorAsync(
            try await serverAdapter.repositoryFacts(repository: repository, reason: .manual)
        ) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .serverFailure(status: 502))
        }
        let malformedAdapter = makeAdapter(client: client, remaining: 100)
        await XCTAssertThrowsErrorAsync(
            try await malformedAdapter.repositoryFacts(repository: repository, reason: .manual)
        ) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .invalidResponse)
        }

        let empty = QueueAnonymousClient([])
        let cursorAdapter = makeAdapter(client: empty)
        await XCTAssertThrowsErrorAsync(
            try await cursorAdapter.issues(
                repository: repository,
                page: ForgePageCursor("graphql-cursor"),
                reason: .manual
            )
        ) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .invalidPageCursor)
        }
        await XCTAssertThrowsErrorAsync(
            try await cursorAdapter.repositoryFacts(repository: gitLabRepository, reason: .manual)
        ) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .githubDotComRepositoryRequired)
        }
    }

    func testTransportFailureConsumesConservativeBudgetAndOversizedResponseIsRejected() async throws {
        let budget = GitHubAnonymousRESTBudget(initialRemainingRequestCount: 12)
        let failure = QueueAnonymousClient([.failure(TestFailure.network)])
        let adapter = GitHubAnonymousRESTAdapter(client: failure, budget: budget)
        await XCTAssertThrowsErrorAsync(
            try await adapter.repositoryFacts(repository: repository, reason: .manual)
        ) { error in
            XCTAssertEqual(error as? TestFailure, .network)
        }
        let snapshot = await budget.current()
        XCTAssertEqual(snapshot.remainingRequestCount, 11)

        let oversized = GitHubAnonymousRESTHTTPResponse(
            statusCode: 200,
            headers: [:],
            data: Data(repeating: 0x20, count: GitHubAnonymousRESTAdapter.maximumResponseBytes + 1)
        )
        let oversizedAdapter = makeAdapter(client: QueueAnonymousClient([.success(oversized)]))
        await XCTAssertThrowsErrorAsync(
            try await oversizedAdapter.repositoryFacts(repository: repository, reason: .manual)
        ) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .responseTooLarge)
        }
    }

    func testConcreteTransportIsEphemeralRejectsRedirectsAndValidatesResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "Authorization": "Bearer ambient-secret",
            "Cookie": "session=ambient-secret",
        ]
        configuration.protocolClasses = [GitHubAnonymousURLProtocol.self]
        let responseURL = try XCTUnwrap(URL(string: "https://api.github.com/repos/hbmartin/gitx"))
        GitHubAnonymousURLProtocol.setHandler { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return try (
                XCTUnwrap(HTTPURLResponse(
                    url: responseURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["X-RateLimit-Remaining": "59"]
                )),
                Data("{}".utf8)
            )
        }
        let client = GitHubAnonymousURLSessionClient(configuration: configuration)
        let request = URLRequest(url: responseURL)
        let success = try await client.execute(request)
        XCTAssertEqual(success.statusCode, 200)
        XCTAssertEqual(success.headers["X-RateLimit-Remaining"], "59")
        XCTAssertEqual(success.data, Data("{}".utf8))

        GitHubAnonymousURLProtocol.setHandler { _ in
            let unexpectedURL = try XCTUnwrap(URL(string: "https://example.com/capture"))
            return try (
                XCTUnwrap(HTTPURLResponse(
                    url: unexpectedURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )),
                Data()
            )
        }
        await XCTAssertThrowsErrorAsync(try await client.execute(request)) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .invalidResponse)
        }

        GitHubAnonymousURLProtocol.setHandler { _ in
            try (
                XCTUnwrap(HTTPURLResponse(
                    url: responseURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )),
                Data(repeating: 0x20, count: GitHubAnonymousRESTAdapter.maximumResponseBytes + 1)
            )
        }
        await XCTAssertThrowsErrorAsync(try await client.execute(request)) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .responseTooLarge)
        }

        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: request)
        let redirectResponse = try XCTUnwrap(HTTPURLResponse(
            url: responseURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://example.com/capture"]
        ))
        var followedRequest: URLRequest? = request
        GitHubAnonymousRedirectRejector().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirectResponse,
            newRequest: request
        ) { followedRequest = $0 }
        XCTAssertNil(followedRequest)
        task.cancel()
        session.invalidateAndCancel()

        let publicAdapter = GitHubAnonymousRESTAdapter(budget: GitHubAnonymousRESTBudget())
        await XCTAssertThrowsErrorAsync(
            try await publicAdapter.repositoryFacts(
                repository: repository,
                reason: .scheduledOverlay
            )
        ) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .explicitRequestRequired)
        }
        XCTAssertGreaterThan(GitHubAnonymousRESTAdapter.currentDate().timeIntervalSince1970, 0)
    }

    func testFallbackMappingsNilBodiesMergeabilityAndMalformedDates() async throws {
        var pull = pullRequest(number: 21, state: "open", draft: nil, mergeable: true)
        pull["body"] = NSNull()
        var unknownUser = user(type: "FutureActor", login: "future")
        unknownUser.removeValue(forKey: "node_id")
        pull["user"] = unknownUser
        var head = try XCTUnwrap(pull["head"] as? [String: Any])
        head.removeValue(forKey: "repo")
        pull["head"] = head
        var base = try XCTUnwrap(pull["base"] as? [String: Any])
        base.removeValue(forKey: "repo")
        pull["base"] = base
        var fallbackLabel = label()
        fallbackLabel.removeValue(forKey: "node_id")
        pull["labels"] = [fallbackLabel]
        var closedMilestone = milestone()
        closedMilestone.removeValue(forKey: "node_id")
        closedMilestone["state"] = "closed"
        pull["milestone"] = closedMilestone
        var unknownMergeability = pull
        unknownMergeability["mergeable"] = NSNull()

        var nilBodyIssue = issuePayload(number: 22, state: "open", user: user())
        nilBodyIssue["body"] = NSNull()
        var malformedDateIssue = nilBodyIssue
        malformedDateIssue["updated_at"] = "not-a-date"

        let client = QueueAnonymousClient([
            .success(response(json: pull)),
            .success(response(json: unknownMergeability)),
            .success(response(json: nilBodyIssue)),
            .success(response(json: malformedDateIssue)),
        ])
        let adapter = makeAdapter(client: client)

        let pullResult = try await adapter.pullRequestDetails(
            repository: repository,
            number: ForgeItemNumber(21),
            reason: .manual
        )
        XCTAssertEqual(pullResult.value.details.bodyMarkdown, .available(""))
        XCTAssertEqual(pullResult.value.details.mergeability, .available(.mergeable))
        guard case let .available(.actor(author)) = pullResult.value.details.summary.author else {
            return XCTFail("Expected actor author")
        }
        XCTAssertEqual(author.id.value, "rest-user:1")
        XCTAssertEqual(author.kind, .unknown)
        XCTAssertNil(pullResult.value.details.summary.head.value?.repository)
        XCTAssertEqual(pullResult.value.details.summary.head.value?.name.value, "feature")
        XCTAssertEqual(pullResult.value.details.summary.head.value?.commit.value, "abcdef1234567890")
        XCTAssertEqual(pullResult.value.details.summary.base.value?.repository, repository)
        XCTAssertEqual(pullResult.value.details.summary.labels.value?.first?.id.value, "rest-label:2")
        XCTAssertEqual(pullResult.value.details.milestone.value.flatMap { $0 }?.id.value, "rest-milestone:3")
        XCTAssertEqual(pullResult.value.details.milestone.value.flatMap { $0 }?.state, .closed)

        let unknownResult = try await adapter.pullRequestDetails(
            repository: repository,
            number: ForgeItemNumber(21),
            reason: .manual
        )
        XCTAssertEqual(unknownResult.value.details.mergeability, .available(.unknown))

        let issueResult = try await adapter.issueDetails(
            repository: repository,
            number: ForgeItemNumber(22),
            reason: .manual
        )
        XCTAssertEqual(issueResult.value.bodyMarkdown, .available(""))

        await XCTAssertThrowsErrorAsync(
            try await adapter.issueDetails(
                repository: repository,
                number: ForgeItemNumber(22),
                reason: .manual
            )
        ) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .invalidResponse)
        }
    }

    func testMaximumPageCannotOverflowNextCursor() async throws {
        let payload = (1 ... 100).map { pullRequest(number: $0, state: "open", draft: false) }
        let adapter = makeAdapter(client: QueueAnonymousClient([.success(response(json: payload))]))

        await XCTAssertThrowsErrorAsync(
            try await adapter.pullRequests(
                repository: repository,
                page: ForgePageCursor("rest-page:\(Int.max)"),
                reason: .manual
            )
        ) { error in
            XCTAssertEqual(error as? GitHubAnonymousRESTError, .invalidPageCursor)
        }
    }

    func testEveryAnonymousErrorHasSafeDescription() {
        let errors: [GitHubAnonymousRESTError] = [
            .explicitRequestRequired,
            .reserveProtected,
            .cooldown(until: .distantFuture),
            .githubDotComRepositoryRequired,
            .invalidPageCursor,
            .invalidResponse,
            .responseTooLarge,
            .notFound,
            .rateLimited(until: nil),
            .rateLimited(until: .distantFuture),
            .serverFailure(status: 500),
        ]
        for error in errors {
            XCTAssertFalse(error.localizedDescription.isEmpty)
            XCTAssertFalse(error.localizedDescription.contains("token"))
        }
    }

    private var repository: ForgeRepositoryIdentity {
        try! ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            owner: "hbmartin",
            name: "gitx"
        )
    }

    private var gitLabRepository: ForgeRepositoryIdentity {
        try! ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com")),
            owner: "hbmartin",
            name: "gitx"
        )
    }

    private var rateHeaders: [String: String] {
        [
            "X-RateLimit-Limit": "60",
            "X-RateLimit-Remaining": "58",
            "X-RateLimit-Used": "2",
            "X-RateLimit-Reset": "3000",
            "X-RateLimit-Resource": "core",
            "x-github-request-id": "request-1",
        ]
    }

    private func makeAdapter(
        client: QueueAnonymousClient,
        remaining: Int = 60
    ) -> GitHubAnonymousRESTAdapter {
        GitHubAnonymousRESTAdapter(
            client: client,
            budget: GitHubAnonymousRESTBudget(initialRemainingRequestCount: remaining),
            now: { Date(timeIntervalSince1970: 2000) }
        )
    }

    private func response(
        status: Int = 200,
        json: Any,
        headers: [String: String] = [:]
    ) -> GitHubAnonymousRESTHTTPResponse {
        GitHubAnonymousRESTHTTPResponse(
            statusCode: status,
            headers: headers,
            data: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        )
    }

    private func user(type: String = "User", login: String = "octocat") -> [String: Any] {
        [
            "id": 1,
            "node_id": "U_1",
            "login": login,
            "avatar_url": "https://avatars.githubusercontent.com/u/1?v=4",
            "type": type,
        ]
    }

    private func label() -> [String: Any] {
        [
            "id": 2,
            "node_id": "L_2",
            "name": "bug",
            "description": "Something is wrong",
            "color": "ff0000",
        ]
    }

    private func milestone() -> [String: Any] {
        [
            "id": 3,
            "node_id": "M_3",
            "number": 1,
            "title": "M1",
            "description": "First milestone",
            "state": "open",
            "due_on": "2026-08-01T00:00:00Z",
        ]
    }

    private func pullRequest(
        number: Int,
        state: String,
        draft: Bool?,
        mergedAt: String? = nil,
        userType: String = "User",
        link: String = "feature",
        mergeable: Bool? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "number": number,
            "state": state,
            "title": "Pull \(number)",
            "body": "Body \(number)",
            "user": user(type: userType, login: userType == "Bot" ? "build[bot]" : "octocat"),
            "head": [
                "ref": link,
                "sha": "abcdef1234567890",
                "repo": ["full_name": "contributor/gitx"],
            ],
            "base": [
                "ref": "main",
                "sha": "1234567890abcdef",
                "repo": ["full_name": "hbmartin/gitx"],
            ],
            "created_at": "2026-07-28T12:00:00Z",
            "updated_at": "2026-07-29T12:00:00Z",
            "closed_at": state == "closed" ? "2026-07-29T12:00:00Z" : NSNull(),
            "merged_at": mergedAt ?? NSNull(),
            "labels": [label()],
            "assignees": [user()],
            "milestone": milestone(),
            "mergeable": mergeable ?? NSNull(),
        ]
        if let draft {
            value["draft"] = draft
        }
        return value
    }

    private func issuePayload(
        number: Int,
        state: String,
        user: [String: Any]?
    ) -> [String: Any] {
        [
            "number": number,
            "state": state,
            "title": "Issue \(number)",
            "body": "Issue body \(number)",
            "user": user ?? NSNull(),
            "created_at": "2026-07-28T12:00:00Z",
            "updated_at": "2026-07-29T12:00:00Z",
            "closed_at": NSNull(),
            "labels": [label()],
            "assignees": [self.user()],
            "milestone": milestone(),
        ]
    }
}

private actor QueueAnonymousClient: GitHubAnonymousRESTHTTPClient {
    private var queue: [Result<GitHubAnonymousRESTHTTPResponse, Error>]
    private var capturedRequests: [URLRequest] = []

    init(_ queue: [Result<GitHubAnonymousRESTHTTPResponse, Error>]) {
        self.queue = queue
    }

    func execute(_ request: URLRequest) async throws -> GitHubAnonymousRESTHTTPResponse {
        capturedRequests.append(request)
        guard !queue.isEmpty else { throw TestFailure.exhausted }
        return try queue.removeFirst().get()
    }

    func requests() -> [URLRequest] {
        capturedRequests
    }
}

private final class TestClock: @unchecked Sendable {
    let value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        value
    }
}

private enum TestFailure: Error, Equatable {
    case network
    case exhausted
}

private final class GitHubAnonymousURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (URLResponse, Data)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?

    static func setHandler(_ handler: Handler?) {
        lock.withLock {
            self.handler = handler
        }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let handler = Self.lock.withLock { Self.handler }
            let (response, data) = try XCTUnwrap(handler)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension ForgeReadSection where Value: Collection {
    var count: Int? {
        guard case let .available(value) = self else { return nil }
        return value.count
    }
}

private extension ForgeReadSection {
    var value: Value? {
        guard case let .available(value) = self else { return nil }
        return value
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
