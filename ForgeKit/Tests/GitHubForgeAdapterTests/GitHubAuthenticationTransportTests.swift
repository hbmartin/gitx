import ForgeKit
@testable import GitHubForgeAdapter
import XCTest

final class GitHubAuthenticationTransportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)

    override func tearDown() {
        GitHubAuthenticationURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testDeviceCoordinatorUsesExactRequestsAndHonorsPendingAndSlowDownSchedules() async throws {
        let client = GitHubAuthenticationHTTPClientStub(responses: [
            .success(response(
                endpoint: GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL,
                data: deviceAuthorizationJSON()
            )),
            .success(response(
                endpoint: GitHubAppDeviceFlowConfiguration.tokenURL,
                data: json(["error": "authorization_pending"])
            )),
            .success(response(
                endpoint: GitHubAppDeviceFlowConfiguration.tokenURL,
                data: json(["error": "slow_down"])
            )),
            .success(response(
                endpoint: GitHubAppDeviceFlowConfiguration.tokenURL,
                data: tokenJSON(access: "access-secret", refresh: "refresh-secret")
            )),
            .success(response(
                endpoint: GitHubAuthenticatedUserRequest.endpoint,
                headers: ["X-GitHub-Request-" + "I" + "D": "DEVICE:USER"],
                data: userJSON()
            )),
        ])
        let coordinator = try GitHubDeviceFlowCoordinator(
            configuration: configuration(),
            transport: GitHubAuthenticationTransport(httpClient: client)
        )

        let initialState = await coordinator.state
        XCTAssertEqual(initialState, .ready)
        let authorization = try await coordinator.begin(receivedAt: now)
        XCTAssertEqual(authorization.userCode, "ABCD-EFGH")
        let awaitingState = await coordinator.state
        XCTAssertEqual(
            awaitingState,
            .awaitingUserAuthorization(authorization, nextPollAt: now.addingTimeInterval(5))
        )
        XCTAssertFalse(String(describing: awaitingState).contains("device-secret"))
        XCTAssertFalse(String(reflecting: awaitingState).contains("device-secret"))
        XCTAssertTrue(awaitingState.customMirror.children.isEmpty)
        let earlyResult = try await coordinator.poll(receivedAt: now.addingTimeInterval(4))
        XCTAssertEqual(
            earlyResult,
            .notYetPollable(nextPollAt: now.addingTimeInterval(5))
        )
        let earlyRequestCount = await client.requestCount
        XCTAssertEqual(earlyRequestCount, 1)
        let pendingResult = try await coordinator.poll(receivedAt: now.addingTimeInterval(5))
        XCTAssertEqual(
            pendingResult,
            .pending(nextPollAt: now.addingTimeInterval(10))
        )
        let slowedResult = try await coordinator.poll(receivedAt: now.addingTimeInterval(10))
        XCTAssertEqual(
            slowedResult,
            .slowedDown(nextPollAt: now.addingTimeInterval(20))
        )
        let result = try await coordinator.poll(receivedAt: now.addingTimeInterval(20))
        guard case let .authorized(credential) = result else { return XCTFail("Expected authorization") }
        XCTAssertEqual(credential.accessTokenExpiresAt, now.addingTimeInterval(3620))
        let terminalState = await coordinator.state
        XCTAssertEqual(terminalState, .terminal(.authorized))
        let accountAuthorization = try await coordinator.completeAuthorization(
            receivedAt: now.addingTimeInterval(21)
        )
        XCTAssertEqual(accountAuthorization.credential, credential)
        XCTAssertEqual(accountAuthorization.identity.login, "octocat")
        XCTAssertEqual(accountAuthorization.identity.response.requestID, "DEVICE:USER")
        XCTAssertFalse(String(describing: accountAuthorization).contains("access-secret"))
        XCTAssertFalse(String(reflecting: accountAuthorization).contains("access-secret"))
        XCTAssertTrue(accountAuthorization.customMirror.children.isEmpty)
        let cachedAuthorization = try await coordinator.completeAuthorization(
            receivedAt: now.addingTimeInterval(22)
        )
        XCTAssertEqual(cachedAuthorization, accountAuthorization)

        let requests = await client.recordedRequests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests[0].url, GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL)
        XCTAssertEqual(form(requests[0]), "client_id=Iv1ABC123")
        for request in requests.dropFirst().prefix(3) {
            XCTAssertEqual(request.url, GitHubAppDeviceFlowConfiguration.tokenURL)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            XCTAssertEqual(
                form(request),
                "client_id=Iv1ABC123&device_code=device-secret&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
            )
        }
        XCTAssertEqual(requests[4].url, GitHubAuthenticatedUserRequest.endpoint)
        XCTAssertEqual(requests[4].value(forHTTPHeaderField: "Authorization"), "Bearer access-secret")
    }

    func testDeviceCoordinatorMakesExpiryAndDenialTerminalWithoutExtraRequests() async throws {
        let expiredClient = GitHubAuthenticationHTTPClientStub(responses: [
            .success(response(
                endpoint: GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL,
                data: deviceAuthorizationJSON()
            )),
        ])
        let expired = try GitHubDeviceFlowCoordinator(
            configuration: configuration(),
            transport: GitHubAuthenticationTransport(httpClient: expiredClient)
        )
        _ = try await expired.begin(receivedAt: now)
        let expiredResult = try await expired.poll(receivedAt: now.addingTimeInterval(900))
        XCTAssertEqual(expiredResult, .expired)
        let terminalExpiredResult = try await expired.poll(receivedAt: now.addingTimeInterval(901))
        XCTAssertEqual(terminalExpiredResult, .terminal(.expired))
        let expiredRequestCount = await expiredClient.requestCount
        XCTAssertEqual(expiredRequestCount, 1)

        let deniedClient = GitHubAuthenticationHTTPClientStub(responses: [
            .success(response(
                endpoint: GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL,
                data: deviceAuthorizationJSON()
            )),
            .success(response(
                endpoint: GitHubAppDeviceFlowConfiguration.tokenURL,
                data: json(["error": "access_denied"])
            )),
        ])
        let denied = try GitHubDeviceFlowCoordinator(
            configuration: configuration(),
            transport: GitHubAuthenticationTransport(httpClient: deniedClient)
        )
        _ = try await denied.begin(receivedAt: now)
        let deniedResult = try await denied.poll(receivedAt: now.addingTimeInterval(5))
        XCTAssertEqual(deniedResult, .denied)
        let terminalDeniedResult = try await denied.poll(receivedAt: now.addingTimeInterval(6))
        XCTAssertEqual(terminalDeniedResult, .terminal(.denied))
        let deniedRequestCount = await deniedClient.requestCount
        XCTAssertEqual(deniedRequestCount, 2)
    }

    func testDeviceCoordinatorPreservesItsScheduleWhenPollingReceivesAnHTTPFailure() async throws {
        let client = GitHubAuthenticationHTTPClientStub(responses: [
            .success(response(
                endpoint: GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL,
                data: deviceAuthorizationJSON()
            )),
            .success(response(
                endpoint: GitHubAppDeviceFlowConfiguration.tokenURL,
                statusCode: 503,
                data: json(["message": "unavailable"])
            )),
        ])
        let coordinator = try GitHubDeviceFlowCoordinator(
            configuration: configuration(),
            transport: GitHubAuthenticationTransport(httpClient: client)
        )
        let authorization = try await coordinator.begin(receivedAt: now)

        await XCTAssertThrowsErrorAsync(
            try await coordinator.poll(receivedAt: now.addingTimeInterval(5))
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .rejectedStatus(503))
        }
        let state = await coordinator.state
        XCTAssertEqual(
            state,
            .awaitingUserAuthorization(authorization, nextPollAt: now.addingTimeInterval(5))
        )
    }

    func testDeviceCoordinatorRetainsAuthorizedCredentialWhenIdentityIntrospectionCanBeRetried() async throws {
        let client = GitHubAuthenticationHTTPClientStub(responses: [
            .success(response(
                endpoint: GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL,
                data: deviceAuthorizationJSON()
            )),
            .success(response(
                endpoint: GitHubAppDeviceFlowConfiguration.tokenURL,
                data: tokenJSON(access: "access-secret", refresh: "refresh-secret")
            )),
            .failure(GitHubAuthenticationTransportError.transportFailure),
            .success(response(
                endpoint: GitHubAuthenticatedUserRequest.endpoint,
                data: userJSON()
            )),
        ])
        let coordinator = try GitHubDeviceFlowCoordinator(
            configuration: configuration(),
            transport: GitHubAuthenticationTransport(httpClient: client)
        )

        _ = try await coordinator.begin(receivedAt: now)
        _ = try await coordinator.poll(receivedAt: now.addingTimeInterval(5))
        await XCTAssertThrowsErrorAsync(
            try await coordinator.completeAuthorization(receivedAt: now.addingTimeInterval(6))
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .transportFailure)
        }
        let state = await coordinator.state
        XCTAssertEqual(state, .terminal(.authorized))
        let authorization = try await coordinator.completeAuthorization(
            receivedAt: now.addingTimeInterval(7)
        )
        XCTAssertEqual(authorization.identity.login, "octocat")
        let requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 4)
    }

    func testDeviceCoordinatorRejectsConcurrentIdentityCompletion() async throws {
        let gate = GitHubAuthenticationAsyncGate()
        let client = GitHubAuthenticationHTTPClientStub(
            responses: [
                .success(response(
                    endpoint: GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL,
                    data: deviceAuthorizationJSON()
                )),
                .success(response(
                    endpoint: GitHubAppDeviceFlowConfiguration.tokenURL,
                    data: tokenJSON(access: "access-secret", refresh: "refresh-secret")
                )),
                .success(response(
                    endpoint: GitHubAuthenticatedUserRequest.endpoint,
                    data: userJSON()
                )),
            ],
            gatedRequestIndex: 2,
            gate: gate
        )
        let coordinator = try GitHubDeviceFlowCoordinator(
            configuration: configuration(),
            transport: GitHubAuthenticationTransport(httpClient: client)
        )
        _ = try await coordinator.begin(receivedAt: now)
        _ = try await coordinator.poll(receivedAt: now.addingTimeInterval(5))

        let completionDate = now.addingTimeInterval(6)
        let first = Task {
            try await coordinator.completeAuthorization(receivedAt: completionDate)
        }
        await client.waitUntilRequestCount(3)
        await XCTAssertThrowsErrorAsync(
            try await coordinator.completeAuthorization(receivedAt: completionDate)
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .operationAlreadyInProgress)
        }
        await gate.open()
        let authorization = try await first.value
        XCTAssertEqual(authorization.identity.login, "octocat")
    }

    func testDeviceCoordinatorRequiresBeginAndRejectsConcurrentPolls() async throws {
        let gate = GitHubAuthenticationAsyncGate()
        let client = GitHubAuthenticationHTTPClientStub(
            responses: [
                .success(response(
                    endpoint: GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL,
                    data: deviceAuthorizationJSON()
                )),
                .success(response(
                    endpoint: GitHubAppDeviceFlowConfiguration.tokenURL,
                    data: json(["error": "authorization_pending"])
                )),
            ],
            gatedRequestIndex: 1,
            gate: gate
        )
        let coordinator = try GitHubDeviceFlowCoordinator(
            configuration: configuration(),
            transport: GitHubAuthenticationTransport(httpClient: client)
        )
        await XCTAssertThrowsErrorAsync(try await coordinator.poll(receivedAt: now)) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .deviceFlowNotStarted)
        }
        await XCTAssertThrowsErrorAsync(
            try await coordinator.poll(receivedAt: Date(timeIntervalSinceReferenceDate: .nan))
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .invalidTokenResponse)
        }
        await XCTAssertThrowsErrorAsync(try await coordinator.completeAuthorization(receivedAt: now)) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .deviceFlowNotAuthorized)
        }
        _ = try await coordinator.begin(receivedAt: now)
        let pollDate = now.addingTimeInterval(5)
        let first = Task { try await coordinator.poll(receivedAt: pollDate) }
        await client.waitUntilRequestCount(2)
        await XCTAssertThrowsErrorAsync(try await coordinator.poll(receivedAt: now.addingTimeInterval(5))) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .operationAlreadyInProgress)
        }
        await gate.open()
        let firstResult = try await first.value
        XCTAssertEqual(firstResult, .pending(nextPollAt: now.addingTimeInterval(10)))
    }

    func testDeviceCoordinatorRejectsConcurrentBeginAndInvalidClockBeforeNetwork() async throws {
        let gate = GitHubAuthenticationAsyncGate()
        let client = GitHubAuthenticationHTTPClientStub(
            responses: [
                .success(response(
                    endpoint: GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL,
                    data: deviceAuthorizationJSON()
                )),
            ],
            gatedRequestIndex: 0,
            gate: gate
        )
        let coordinator = try GitHubDeviceFlowCoordinator(
            configuration: configuration(),
            transport: GitHubAuthenticationTransport(httpClient: client)
        )
        await XCTAssertThrowsErrorAsync(
            try await coordinator.begin(receivedAt: Date(timeIntervalSinceReferenceDate: .nan))
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .invalidDeviceAuthorization)
        }
        let startDate = now
        let first = Task { try await coordinator.begin(receivedAt: startDate) }
        await client.waitUntilRequestCount(1)
        await XCTAssertThrowsErrorAsync(try await coordinator.begin(receivedAt: now)) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .operationAlreadyInProgress)
        }
        await gate.open()
        _ = try await first.value
        let requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testPublicCoordinatorsCanInitializeAndMakeNoNetworkRequestWhenRefreshIsNotDue() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [GitHubAuthenticationURLProtocol.self]
        GitHubAuthenticationURLProtocol.setHandler { _ in
            XCTFail("A current Credential must not trigger a network request")
            throw GitHubAuthenticationTransportError.transportFailure
        }
        let deviceCoordinator = try GitHubDeviceFlowCoordinator(
            configuration: configuration(),
            sessionConfiguration: sessionConfiguration
        )
        let deviceState = await deviceCoordinator.state
        XCTAssertEqual(deviceState, .ready)

        let refreshCoordinator = try GitHubCredentialRefreshCoordinator(
            configuration: configuration(),
            sessionConfiguration: sessionConfiguration
        )
        let credential = try rotatingCredential(accessExpiry: 2000, refreshExpiry: 3000)
        let result = try await refreshCoordinator.refreshIfNeeded(
            credential,
            at: now,
            minimumValidity: 300
        )
        XCTAssertEqual(result, .current(refreshAt: Date(timeIntervalSince1970: 1700)))
    }

    func testConcreteURLSessionTransportRemovesAmbientCredentialsCookiesAndCaching() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpAdditionalHeaders = [
            "Authorization": "Bearer ambient-secret",
            "Cookie": "session=ambient-secret",
        ]
        sessionConfiguration.protocolClasses = [GitHubAuthenticationURLProtocol.self]
        let deviceData = deviceAuthorizationJSON()
        GitHubAuthenticationURLProtocol.setHandler { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.url, GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL)
            return (
                200,
                ["X-GitHub-Request-" + "I" + "D": "DEVICE:BEGIN"],
                deviceData,
                GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL
            )
        }
        let transport = GitHubAuthenticationTransport(sessionConfiguration: sessionConfiguration)
        let authorization = try await transport.requestDeviceAuthorization(
            configuration: configuration(),
            receivedAt: now
        )
        XCTAssertEqual(authorization.userCode, "ABCD-EFGH")
    }

    func testConcreteURLSessionTransportMapsNetworkFailureAndCancellationWithoutLeakingDetails() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [GitHubAuthenticationURLProtocol.self]
        let transport = GitHubAuthenticationTransport(sessionConfiguration: sessionConfiguration)

        GitHubAuthenticationURLProtocol.setHandler { _ in
            throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "access-secret"])
        }
        await XCTAssertThrowsErrorAsync(
            try await transport.requestDeviceAuthorization(configuration: configuration(), receivedAt: now)
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .transportFailure)
            XCTAssertFalse($0.localizedDescription.contains("access-secret"))
        }

        GitHubAuthenticationURLProtocol.setHandler { _ in
            throw URLError(.cancelled)
        }
        await XCTAssertThrowsErrorAsync(
            try await transport.requestDeviceAuthorization(configuration: configuration(), receivedAt: now)
        ) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testConcreteURLSessionTransportRejectsNonHTTPResponsesAndRedirectDelegateNeverFollows() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [GitHubAuthenticationNonHTTPURLProtocol.self]
        let transport = GitHubAuthenticationTransport(sessionConfiguration: sessionConfiguration)
        await XCTAssertThrowsErrorAsync(
            try await transport.requestDeviceAuthorization(configuration: configuration(), receivedAt: now)
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .invalidHTTPResponse)
        }

        let session = URLSession(configuration: .ephemeral)
        let original = URLRequest(url: GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL)
        let task = session.dataTask(with: original)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://example.com/capture"]
        ))
        var redirected = try URLRequest(url: XCTUnwrap(URL(string: "https://example.com/capture")))
        redirected.setValue("Bearer access-secret", forHTTPHeaderField: "Authorization")
        var followedRequest: URLRequest? = redirected
        GitHubAuthenticationRedirectDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirected
        ) { request in
            followedRequest = request
        }
        XCTAssertNil(followedRequest)
        task.cancel()
        session.invalidateAndCancel()
    }

    func testTransportRejectsUnexpectedEndpointsOversizedBodiesAndStatuses() async throws {
        let cases: [(GitHubAuthenticationHTTPResponse, GitHubAuthenticationTransportError)] = try [
            (
                response(
                    endpoint: XCTUnwrap(URL(string: "https://github.com/login/device/code?redirected=1")),
                    data: deviceAuthorizationJSON()
                ),
                .unexpectedResponseEndpoint
            ),
            (
                response(
                    endpoint: GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL,
                    data: Data(repeating: 0, count: 1024 * 1024 + 1)
                ),
                .responseTooLarge
            ),
            (
                response(
                    endpoint: GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL,
                    statusCode: 503,
                    data: Data("access-secret".utf8)
                ),
                .rejectedStatus(503)
            ),
        ]
        for (response, expected) in cases {
            XCTAssertFalse(String(describing: response).contains("access-secret"))
            XCTAssertFalse(String(reflecting: response).contains("access-secret"))
            XCTAssertTrue(response.customMirror.children.isEmpty)
            let client = GitHubAuthenticationHTTPClientStub(responses: [.success(response)])
            let transport = GitHubAuthenticationTransport(httpClient: client)
            await XCTAssertThrowsErrorAsync(
                try await transport.requestDeviceAuthorization(configuration: configuration(), receivedAt: now)
            ) {
                XCTAssertEqual($0 as? GitHubAuthenticationTransportError, expected)
                XCTAssertFalse($0.localizedDescription.contains("access-secret"))
            }
        }
    }

    func testPATIntrospectionMapsIdentityClassicScopesAndSafeMetadata() async throws {
        let headers = [
            "X-OAuth-Scopes": " repo, Read:Org, repo:status, invalid scope, repo ",
            "X-GitHub-Request-" + "I" + "D": "ABC1:DEF2",
            "X-RateLimit-Limit": "5000",
            "X-RateLimit-Remaining": "4999",
            "X-RateLimit-Reset": "2000",
        ]
        let client = GitHubAuthenticationHTTPClientStub(responses: [
            .success(response(
                endpoint: GitHubAuthenticatedUserRequest.endpoint,
                headers: headers,
                data: userJSON()
            )),
        ])
        let token = try GitHubSecret("github_pat_super-secret")
        let entry = try GitHubPersonalAccessTokenEntry(token: token, kind: .classic, label: "Work")
        let result = try await GitHubAuthenticationTransport(httpClient: client)
            .introspectPersonalAccessToken(entry, receivedAt: now)

        XCTAssertEqual(result.accountID.value, "MDQ6VXNlcjE=")
        XCTAssertEqual(result.login, "octocat")
        XCTAssertEqual(result.databaseID, 1)
        XCTAssertEqual(result.scopeEvidence, .classic(scopes: ["repo", "read:org", "repo:status"]))
        XCTAssertEqual(result.response.requestID, "ABC1:DEF2")
        XCTAssertEqual(result.response.rateLimit.remaining, 4999)
        XCTAssertFalse(String(describing: result).contains("super-secret"))
        XCTAssertFalse(String(reflecting: result).contains("super-secret"))
        XCTAssertTrue(result.customMirror.children.isEmpty)
        XCTAssertFalse(String(describing: result.identity).contains("super-secret"))
        XCTAssertFalse(String(reflecting: result.identity).contains("super-secret"))
        XCTAssertTrue(result.identity.customMirror.children.isEmpty)

        let recordedRequests = await client.recordedRequests
        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/user")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "GitX")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer github_pat_super-secret")
        let presentation = GitHubAuthenticatedUserRequest(token: token)
        XCTAssertFalse(String(describing: presentation).contains("super-secret"))
        XCTAssertFalse(String(reflecting: presentation).contains("super-secret"))
        XCTAssertTrue(presentation.customMirror.children.isEmpty)
    }

    func testFineGrainedPATNeverTreatsOAuthScopeHeaderAsIntrospectable() async throws {
        let client = GitHubAuthenticationHTTPClientStub(responses: [
            .success(response(
                endpoint: GitHubAuthenticatedUserRequest.endpoint,
                headers: [
                    "X-OAuth-Scopes": "repo",
                    "X-RateLimit-Limit": "5000",
                    "X-RateLimit-Remaining": "0",
                    "X-RateLimit-Reset": "2000",
                ],
                data: userJSON()
            )),
            .success(response(
                endpoint: GitHubAuthenticatedUserRequest.endpoint,
                statusCode: 403,
                headers: ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso"],
                data: json(["message": "SAML authorization required"])
            )),
        ])
        let entry = try GitHubPersonalAccessTokenEntry(
            token: GitHubSecret("github_pat_secret"),
            kind: .fineGrained
        )
        let transport = GitHubAuthenticationTransport(httpClient: client)
        let result = try await transport.introspectPersonalAccessToken(entry, receivedAt: now)
        XCTAssertEqual(result.scopeEvidence, .fineGrainedNotIntrospectable)
        XCTAssertEqual(result.response.rateLimit.remaining, 0)
        await XCTAssertThrowsErrorAsync(try await transport.introspectPersonalAccessToken(entry, receivedAt: now)) {
            XCTAssertEqual(
                $0 as? GitHubAuthenticationTransportError,
                .authorizationFailure(.authorizationDenied)
            )
        }
    }

    func testGitHubAppUserCredentialNeverOffersClassicPATSAMLRecovery() async throws {
        let client = GitHubAuthenticationHTTPClientStub(responses: [
            .success(response(
                endpoint: GitHubAuthenticatedUserRequest.endpoint,
                statusCode: 403,
                headers: ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso"],
                data: json(["message": "SAML authorization required"])
            )),
        ])
        let credential = try rotatingCredential(accessExpiry: 2000, refreshExpiry: 3000)
        await XCTAssertThrowsErrorAsync(
            try await GitHubAuthenticationTransport(httpClient: client)
                .introspectUserAccessCredential(credential, receivedAt: now)
        ) {
            XCTAssertEqual(
                $0 as? GitHubAuthenticationTransportError,
                .authorizationFailure(.authorizationDenied)
            )
        }
    }

    func testPATIntrospectionMapsAuthenticationSAMLRateLimitAndMalformedIdentityFailures() async throws {
        let samlURL = "https://github.com/orgs/acme/sso?authorization_request=opaque"
        let cases: [(GitHubAuthenticationHTTPResponse, ErrorMatcher)] = try [
            (
                response(endpoint: GitHubAuthenticatedUserRequest.endpoint, statusCode: 401, data: json(["message": "Bad credentials"])),
                .transport(.authorizationFailure(.badCredentials))
            ),
            (
                response(
                    endpoint: GitHubAuthenticatedUserRequest.endpoint,
                    statusCode: 403,
                    headers: ["X-GitHub-SSO": "required; url=\(samlURL)"],
                    data: json(["message": "secret private response"])
                ),
                .transport(.authorizationFailure(.samlAuthorizationRequired(authorizeURL: XCTUnwrap(URL(string: samlURL)))))
            ),
            (
                response(
                    endpoint: GitHubAuthenticatedUserRequest.endpoint,
                    statusCode: 429,
                    headers: ["Retry-After": "60"],
                    data: json(["message": "secret rate limit"])
                ),
                .rateLimited
            ),
            (
                response(
                    endpoint: GitHubAuthenticatedUserRequest.endpoint,
                    data: json(["login": "octocat\n", "id": 1, "node_id": "node"])
                ),
                .authentication(.nonGitHubIdentity)
            ),
        ]
        for (response, expected) in cases {
            let client = GitHubAuthenticationHTTPClientStub(responses: [.success(response)])
            let transport = GitHubAuthenticationTransport(httpClient: client)
            let entry = try GitHubPersonalAccessTokenEntry(token: GitHubSecret("github_pat_secret"), kind: .classic)
            await XCTAssertThrowsErrorAsync(
                try await transport.introspectPersonalAccessToken(entry, receivedAt: now)
            ) { error in
                expected.assert(error)
                XCTAssertFalse(error.localizedDescription.contains("secret private"))
                XCTAssertFalse(error.localizedDescription.contains("secret rate"))
            }
        }
    }

    func testPATIntrospectionRejectsInvalidClockAndUnexpectedHTTPStatusWithoutNetworkFallback() async throws {
        let entry = try GitHubPersonalAccessTokenEntry(
            token: GitHubSecret("github_pat_secret"),
            kind: .classic
        )
        let invalidClockClient = GitHubAuthenticationHTTPClientStub(responses: [])
        await XCTAssertThrowsErrorAsync(
            try await GitHubAuthenticationTransport(httpClient: invalidClockClient)
                .introspectPersonalAccessToken(
                    entry,
                    receivedAt: Date(timeIntervalSinceReferenceDate: .nan)
                )
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .invalidHTTPResponse)
        }
        let invalidClockRequestCount = await invalidClockClient.requestCount
        XCTAssertEqual(invalidClockRequestCount, 0)

        let rejectedClient = GitHubAuthenticationHTTPClientStub(responses: [
            .success(response(
                endpoint: GitHubAuthenticatedUserRequest.endpoint,
                statusCode: 418,
                data: json(["message": "unexpected status"])
            )),
        ])
        await XCTAssertThrowsErrorAsync(
            try await GitHubAuthenticationTransport(httpClient: rejectedClient)
                .introspectPersonalAccessToken(entry, receivedAt: now)
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .rejectedStatus(418))
        }
    }

    func testRefreshSchedulerCoversUsableDueExpiredAndInvalidBoundaries() throws {
        let credential = try rotatingCredential(accessExpiry: 2000, refreshExpiry: 3000)
        XCTAssertEqual(
            try GitHubCredentialRefreshScheduler.decision(for: credential, at: now, minimumValidity: 300),
            .useCurrentCredential(refreshAt: Date(timeIntervalSince1970: 1700))
        )
        XCTAssertEqual(
            try GitHubCredentialRefreshScheduler.decision(
                for: credential,
                at: Date(timeIntervalSince1970: 1700),
                minimumValidity: 300
            ),
            .refreshNow
        )
        XCTAssertEqual(
            try GitHubCredentialRefreshScheduler.decision(
                for: credential,
                at: Date(timeIntervalSince1970: 3000),
                minimumValidity: 0
            ),
            .reauthorizationRequired
        )
        for invalid in [TimeInterval.nan, .infinity, -1] {
            XCTAssertThrowsError(
                try GitHubCredentialRefreshScheduler.decision(for: credential, at: now, minimumValidity: invalid)
            ) {
                XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .invalidRefreshSchedule)
            }
        }
        XCTAssertThrowsError(
            try GitHubCredentialRefreshScheduler.decision(
                for: credential,
                at: Date(timeIntervalSinceReferenceDate: .nan),
                minimumValidity: 0
            )
        )
        let extreme = try GitHubRotatingUserCredential(
            accessToken: GitHubSecret("old-access"),
            accessTokenExpiresAt: Date(timeIntervalSinceReferenceDate: -1e308),
            refreshToken: GitHubSecret("old-refresh"),
            refreshTokenExpiresAt: Date(timeIntervalSinceReferenceDate: -5e307)
        )
        XCTAssertThrowsError(
            try GitHubCredentialRefreshScheduler.decision(
                for: extreme,
                at: Date(timeIntervalSinceReferenceDate: -1.5e308),
                minimumValidity: 1e308
            )
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .invalidRefreshSchedule)
        }
    }

    func testRefreshTransportRotatesBothSecretsWithExactGrantAndNoFallback() async throws {
        let client = GitHubAuthenticationHTTPClientStub(responses: [
            .success(response(
                endpoint: GitHubAppDeviceFlowConfiguration.tokenURL,
                data: tokenJSON(access: "new-access", refresh: "new-refresh")
            )),
        ])
        let original = try rotatingCredential(accessExpiry: 1001, refreshExpiry: 5000)
        let transport = GitHubAuthenticationTransport(httpClient: client)
        let rotated = try await transport.refreshCredential(
            configuration: configuration(),
            credential: original,
            receivedAt: now
        )
        let recovered = rotated.accessToken.withUnsafeUTF8Bytes { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(recovered, "new-access")
        XCTAssertEqual(rotated.accessTokenExpiresAt, now.addingTimeInterval(3600))
        let recordedRequests = await client.recordedRequests
        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(
            form(request),
            "client_id=Iv1ABC123&grant_type=refresh_token&refresh_token=old-refresh"
        )

        let expiredClient = GitHubAuthenticationHTTPClientStub(responses: [])
        let expired = try rotatingCredential(accessExpiry: 900, refreshExpiry: 1000)
        await XCTAssertThrowsErrorAsync(
            try await GitHubAuthenticationTransport(httpClient: expiredClient).refreshCredential(
                configuration: configuration(),
                credential: expired,
                receivedAt: now
            )
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .refreshAuthorizationExpired)
        }
        let expiredRequestCount = await expiredClient.requestCount
        XCTAssertEqual(expiredRequestCount, 0)

        await XCTAssertThrowsErrorAsync(
            try await transport.refreshCredential(
                configuration: configuration(),
                credential: original,
                receivedAt: Date(timeIntervalSinceReferenceDate: .nan)
            )
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .invalidRefreshSchedule)
        }

        let rejectedClient = GitHubAuthenticationHTTPClientStub(responses: [
            .success(response(
                endpoint: GitHubAppDeviceFlowConfiguration.tokenURL,
                statusCode: 502,
                data: json(["message": "bad gateway"])
            )),
        ])
        await XCTAssertThrowsErrorAsync(
            try await GitHubAuthenticationTransport(httpClient: rejectedClient).refreshCredential(
                configuration: configuration(),
                credential: original,
                receivedAt: now
            )
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .rejectedStatus(502))
        }
    }

    func testRefreshCoordinatorCoalescesSameCredentialAndRejectsDifferentCredential() async throws {
        let gate = GitHubAuthenticationAsyncGate()
        let client = GitHubAuthenticationHTTPClientStub(
            responses: [
                .success(response(
                    endpoint: GitHubAppDeviceFlowConfiguration.tokenURL,
                    data: tokenJSON(access: "new-access", refresh: "new-refresh")
                )),
            ],
            gatedRequestIndex: 0,
            gate: gate
        )
        let coordinator = try GitHubCredentialRefreshCoordinator(
            configuration: configuration(),
            transport: GitHubAuthenticationTransport(httpClient: client)
        )
        let original = try rotatingCredential(accessExpiry: 1001, refreshExpiry: 5000)
        let refreshDate = now
        let first = Task {
            try await coordinator.refreshIfNeeded(original, at: refreshDate, minimumValidity: 60)
        }
        await client.waitUntilRequestCount(1)
        let second = Task {
            try await coordinator.refreshIfNeeded(original, at: refreshDate, minimumValidity: 60)
        }
        let different = try rotatingCredential(
            access: "different-access",
            refresh: "different-refresh",
            accessExpiry: 1001,
            refreshExpiry: 5000
        )
        await XCTAssertThrowsErrorAsync(
            try await coordinator.refreshIfNeeded(different, at: now, minimumValidity: 60)
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .operationAlreadyInProgress)
        }
        let inFlightRequestCount = await client.requestCount
        XCTAssertEqual(inFlightRequestCount, 1)
        await gate.open()
        let expected = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(secondResult, expected)
        let finalRequestCount = await client.requestCount
        XCTAssertEqual(finalRequestCount, 1)
    }

    func testRefreshCoordinatorFailsClosedBeforeSingleFlightIdentifierWouldOverflow() async throws {
        let client = GitHubAuthenticationHTTPClientStub(responses: [])
        let coordinator = try GitHubCredentialRefreshCoordinator(
            configuration: configuration(),
            transport: GitHubAuthenticationTransport(httpClient: client),
            nextID: .max
        )
        let credential = try rotatingCredential(accessExpiry: 1001, refreshExpiry: 5000)

        await XCTAssertThrowsErrorAsync(
            try await coordinator.refreshIfNeeded(credential, at: now, minimumValidity: 60)
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .operationAlreadyInProgress)
        }
        let requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testRefreshCoordinatorReturnsCurrentOrReauthorizationWithoutNetwork() async throws {
        let client = GitHubAuthenticationHTTPClientStub(responses: [])
        let coordinator = try GitHubCredentialRefreshCoordinator(
            configuration: configuration(),
            transport: GitHubAuthenticationTransport(httpClient: client)
        )
        let current = try rotatingCredential(accessExpiry: 2000, refreshExpiry: 3000)
        let currentResult = try await coordinator.refreshIfNeeded(current, at: now, minimumValidity: 300)
        XCTAssertEqual(currentResult, .current(refreshAt: Date(timeIntervalSince1970: 1700)))
        let expired = try rotatingCredential(accessExpiry: 900, refreshExpiry: 1000)
        let expiredResult = try await coordinator.refreshIfNeeded(expired, at: now, minimumValidity: 0)
        XCTAssertEqual(expiredResult, .reauthorizationRequired)
        let requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testRefreshCoordinatorRequiresReauthorizationForServerRejectedRefreshToken() async throws {
        let client = GitHubAuthenticationHTTPClientStub(responses: [
            .success(response(
                endpoint: GitHubAppDeviceFlowConfiguration.tokenURL,
                data: json([
                    "error": "bad_refresh_token",
                    "error_description": "refresh-secret must not escape",
                ])
            )),
        ])
        let coordinator = try GitHubCredentialRefreshCoordinator(
            configuration: configuration(),
            transport: GitHubAuthenticationTransport(httpClient: client)
        )
        let credential = try rotatingCredential(accessExpiry: 1001, refreshExpiry: 5000)
        let result = try await coordinator.refreshIfNeeded(credential, at: now, minimumValidity: 60)
        XCTAssertEqual(result, .reauthorizationRequired)
        let requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testSAMLCoordinatorOffersBrowserAndExplicitRetryWithoutAutomaticWork() async throws {
        let coordinator = GitHubSAMLRetryCoordinator()
        let counter = GitHubAuthenticationCounter()
        let url = try XCTUnwrap(URL(string: "https://github.com/orgs/acme/sso?authorization_request=opaque"))
        let offered = try await coordinator.offer(
            for: .samlAuthorizationRequired(authorizeURL: url),
            credentialSource: .classicPersonalAccessToken
        )
        XCTAssertEqual(offered, .authorizeInBrowserAndRetry(url))
        XCTAssertFalse(String(describing: offered).contains("authorization_request"))
        XCTAssertFalse(String(reflecting: offered).contains("authorization_request"))
        XCTAssertTrue(offered.customMirror.children.isEmpty)
        let initialCount = await counter.value
        XCTAssertEqual(initialCount, 0)
        let result = try await coordinator.retry {
            await counter.increment()
            return "recovered"
        }
        XCTAssertEqual(result, "recovered")
        let finalCount = await counter.value
        XCTAssertEqual(finalCount, 1)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testSAMLCoordinatorRejectsRetryAndDeclineWhileExplicitRetryIsInFlight() async throws {
        let coordinator = GitHubSAMLRetryCoordinator()
        let gate = GitHubAuthenticationAsyncGate()
        let url = try XCTUnwrap(URL(string: "https://github.com/orgs/acme/sso"))
        _ = try await coordinator.offer(
            for: .samlAuthorizationRequired(authorizeURL: url),
            credentialSource: .classicPersonalAccessToken
        )
        let first = Task {
            try await coordinator.retry {
                await gate.wait()
                return "recovered"
            }
        }
        await gate.waitUntilWaitStarts()
        let retryingState = await coordinator.state
        XCTAssertEqual(retryingState, .retrying(url))
        XCTAssertFalse(String(describing: retryingState).contains("github.com"))

        await XCTAssertThrowsErrorAsync(try await coordinator.retry { "unexpected" }) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .operationAlreadyInProgress)
        }
        await XCTAssertThrowsErrorAsync(try await coordinator.decline()) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .operationAlreadyInProgress)
        }
        await gate.open()
        let result = try await first.value
        XCTAssertEqual(result, "recovered")
    }

    func testSAMLCoordinatorRetainsOfferAfterFailedRetryAndDeclinePreservesCapabilities() async throws {
        let coordinator = GitHubSAMLRetryCoordinator()
        let url = try XCTUnwrap(URL(string: "https://github.com/orgs/acme/sso"))
        _ = try await coordinator.offer(
            for: GitHubSAMLMetadata(authorizationURL: url),
            credentialSource: .commandLineBroker
        )
        await XCTAssertThrowsErrorAsync(
            try await coordinator.retry { () async throws -> String in
                throw GitHubAuthenticationTransportError.transportFailure
            }
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .transportFailure)
        }
        let retryState = await coordinator.state
        XCTAssertEqual(retryState, .authorizeInBrowserAndRetry(url))
        let declined = try await coordinator.decline()
        XCTAssertEqual(declined, .declinedPreservingEffectiveCapabilities)
        XCTAssertTrue(String(describing: declined).contains("capabilities preserved"))
        await XCTAssertThrowsErrorAsync(try await coordinator.retry { "unexpected" }) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .samlRecoveryNotAvailable)
        }
    }

    func testSAMLCoordinatorRejectsNonSAMLAndUnsafeAuthorizationURLs() async throws {
        let coordinator = GitHubSAMLRetryCoordinator()
        await XCTAssertThrowsErrorAsync(
            try await coordinator.offer(for: .badCredentials, credentialSource: .classicPersonalAccessToken)
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .samlRecoveryNotAvailable)
        }
        await XCTAssertThrowsErrorAsync(
            try await coordinator.offer(
                for: GitHubSAMLMetadata(authorizationURL: nil),
                credentialSource: .classicPersonalAccessToken
            )
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .samlRecoveryNotAvailable)
        }
        await XCTAssertThrowsErrorAsync(try await coordinator.decline()) {
            XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .samlRecoveryNotAvailable)
        }
        let safeURL = try XCTUnwrap(URL(string: "https://github.com/orgs/acme/sso"))
        for source in [ForgeCredentialSource.fineGrainedPersonalAccessToken, .forgeApplicationDeviceFlow] {
            await XCTAssertThrowsErrorAsync(
                try await coordinator.offer(
                    for: .samlAuthorizationRequired(authorizeURL: safeURL),
                    credentialSource: source
                )
            ) {
                XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .samlRecoveryNotAvailable)
            }
        }
        for value in [
            "http://github.com/orgs/acme/sso",
            "https://github.com.evil/orgs/acme/sso",
            "https://user@github.com/orgs/acme/sso",
            "https://github.com:444/orgs/acme/sso",
            "https://github.com/orgs/acme/sso#secret",
            "https://github.com/orgs/acme/not-sso",
        ] {
            let url = try XCTUnwrap(URL(string: value))
            await XCTAssertThrowsErrorAsync(
                try await coordinator.offer(
                    for: .samlAuthorizationRequired(authorizeURL: url),
                    credentialSource: .classicPersonalAccessToken
                )
            ) {
                XCTAssertEqual($0 as? GitHubAuthenticationTransportError, .invalidSAMLAuthorizationURL)
            }
        }
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(String(describing: state), "GitHub SAML recovery idle.")
        let retrying = GitHubSAMLRetryState.retrying(safeURL)
        XCTAssertFalse(String(describing: retrying).contains("github.com"))
    }

    func testAuthenticationTransportErrorsHaveSafeDescriptions() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/orgs/acme/sso?secret=super-secret"))
        let rateLimit = GitHubRateLimitMetadata(
            limit: 10,
            remaining: 0,
            used: 10,
            resetAt: now,
            retryAt: now,
            resource: "core"
        )
        let errors: [GitHubAuthenticationTransportError] = [
            .invalidHTTPResponse,
            .unexpectedResponseEndpoint,
            .responseTooLarge,
            .rejectedStatus(500),
            .authorizationFailure(.samlAuthorizationRequired(authorizeURL: url)),
            .rateLimited(rateLimit),
            .transportFailure,
            .deviceFlowNotStarted,
            .deviceFlowNotAuthorized,
            .operationAlreadyInProgress,
            .invalidRefreshSchedule,
            .refreshAuthorizationExpired,
            .samlRecoveryNotAvailable,
            .invalidSAMLAuthorizationURL,
        ]
        for error in errors {
            XCTAssertFalse(error.localizedDescription.contains("super-secret"))
            XCTAssertFalse(String(describing: error).contains("super-secret"))
        }
    }

    private func configuration() throws -> GitHubAppDeviceFlowConfiguration {
        try GitHubAppDeviceFlowConfiguration(clientID: "Iv1ABC123", applicationSlug: "gitx-forge")
    }

    private func rotatingCredential(
        access: String = "old-access",
        refresh: String = "old-refresh",
        accessExpiry: TimeInterval,
        refreshExpiry: TimeInterval
    ) throws -> GitHubRotatingUserCredential {
        try GitHubRotatingUserCredential(
            accessToken: GitHubSecret(access),
            accessTokenExpiresAt: Date(timeIntervalSince1970: accessExpiry),
            refreshToken: GitHubSecret(refresh),
            refreshTokenExpiresAt: Date(timeIntervalSince1970: refreshExpiry)
        )
    }

    private func deviceAuthorizationJSON() -> Data {
        json([
            "device_code": "device-secret",
            "user_code": "ABCD-EFGH",
            "verification_uri": "https://github.com/login/device",
            "expires_in": 900,
            "interval": 5,
        ])
    }

    private func tokenJSON(access: String, refresh: String) -> Data {
        json([
            "access_token": access,
            "expires_in": 3600,
            "refresh_token": refresh,
            "refresh_token_expires_in": 86400,
            "token_type": "bearer",
        ])
    }

    private func userJSON() -> Data {
        json([
            "login": "octocat",
            "id": 1,
            "node_id": "MDQ6VXNlcjE=",
        ])
    }

    private func response(
        endpoint: URL,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        data: Data
    ) -> GitHubAuthenticationHTTPResponse {
        GitHubAuthenticationHTTPResponse(
            data: data,
            statusCode: statusCode,
            url: endpoint,
            headers: headers
        )
    }

    private func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func form(_ request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }
}

private enum ErrorMatcher {
    case transport(GitHubAuthenticationTransportError)
    case authentication(GitHubAuthenticationError)
    case rateLimited

    func assert(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        switch self {
        case let .transport(expected):
            XCTAssertEqual(error as? GitHubAuthenticationTransportError, expected, file: file, line: line)
        case let .authentication(expected):
            XCTAssertEqual(error as? GitHubAuthenticationError, expected, file: file, line: line)
        case .rateLimited:
            guard case .rateLimited? = error as? GitHubAuthenticationTransportError else {
                return XCTFail("Expected rate limiting, got \(error)", file: file, line: line)
            }
        }
    }
}

private actor GitHubAuthenticationHTTPClientStub: GitHubAuthenticationHTTPClient {
    private var responses: [Result<GitHubAuthenticationHTTPResponse, Error>]
    private var requests: [URLRequest] = []
    private let gatedRequestIndex: Int?
    private let gate: GitHubAuthenticationAsyncGate?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        responses: [Result<GitHubAuthenticationHTTPResponse, Error>],
        gatedRequestIndex: Int? = nil,
        gate: GitHubAuthenticationAsyncGate? = nil
    ) {
        self.responses = responses
        self.gatedRequestIndex = gatedRequestIndex
        self.gate = gate
    }

    var requestCount: Int {
        requests.count
    }

    var recordedRequests: [URLRequest] {
        requests
    }

    func waitUntilRequestCount(_ expected: Int) async {
        while requests.count < expected {
            await withCheckedContinuation { continuation in
                requestWaiters.append(continuation)
            }
        }
    }

    func perform(_ request: URLRequest) async throws -> GitHubAuthenticationHTTPResponse {
        let index = requests.count
        requests.append(request)
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if index == gatedRequestIndex, let gate {
            await gate.wait()
        }
        guard !responses.isEmpty else {
            throw GitHubAuthenticationTransportError.transportFailure
        }
        return try responses.removeFirst().get()
    }
}

private actor GitHubAuthenticationAsyncGate {
    private var isOpen = false
    private var waitHasStarted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waitStartWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        waitHasStarted = true
        let startWaiters = waitStartWaiters
        waitStartWaiters.removeAll()
        startWaiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilWaitStarts() async {
        guard !waitHasStarted else { return }
        await withCheckedContinuation { continuation in
            waitStartWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor GitHubAuthenticationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class GitHubAuthenticationURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data, URL)

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
            let (statusCode, headers, data, responseURL) = try XCTUnwrap(handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: responseURL,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class GitHubAuthenticationNonHTTPURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = URLResponse(
            url: url,
            mimeType: "application/json",
            expectedContentLength: 0,
            textEncodingName: "utf-8"
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
