import ForgeKit
@testable import GitHubForgeAdapter
import XCTest

final class GitHubAuthorizationRecoveryTransportTests: XCTestCase {
    override func tearDown() {
        RecoveryGraphQLURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testGraphQLMutationClassifiesInstallationBeforeOutcomeUnknownWithoutRetry() async throws {
        let authentication = try makeAuthentication(source: .forgeApplicationDeviceFlow)
        let repository = try makeRepository()
        let installationURL = try XCTUnwrap(
            URL(string: "https://github.com/apps/gitx-forge/installations/new")
        )
        let queue = RecoveryGraphQLQueue([
            .success(operation: "GitHubPullRequestCreationPreflight", data: creationPreflight()),
            .payload(
                operation: "GitHubCreatePullRequest",
                value: [
                    "data": ["createPullRequest": NSNull()],
                    "errors": [["message": "Resource not accessible by integration"]],
                ]
            ),
        ])
        install(queue)

        do {
            _ = try await makeAdapter(
                authentication: authentication,
                installationConfigurationURL: installationURL
            ).createPullRequest(
                accountID: authentication.account.id,
                form: creationForm(repository: repository),
                authorization: authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .createPullRequest
                )
            )
            XCTFail("Expected missing installation recovery")
        } catch let GitHubMutationError.installationConfigurationRequired(response) {
            XCTAssertEqual(response.installation?.configurationURL, installationURL)
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertEqual(queue.requestCount, 2)
        XCTAssertEqual(queue.remainingCount, 0, "Authorization recovery never retries a mutation automatically")
    }

    func testGraphQLMutationClassifiesBodyOnlySAMLForClassicCredential() async throws {
        let authentication = try makeAuthentication(source: .classicPersonalAccessToken)
        let repository = try makeRepository()
        let queue = RecoveryGraphQLQueue([
            .success(operation: "GitHubPullRequestCreationPreflight", data: creationPreflight()),
            .payload(
                operation: "GitHubCreatePullRequest",
                value: [
                    "errors": [[
                        "message": "Resource protected by organization SAML enforcement.",
                    ]],
                ]
            ),
        ])
        install(queue)

        do {
            _ = try await makeAdapter(authentication: authentication).createPullRequest(
                accountID: authentication.account.id,
                form: creationForm(repository: repository),
                authorization: authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .createPullRequest
                )
            )
            XCTFail("Expected SAML recovery")
        } catch let GitHubMutationError.samlAuthorizationRequired(response) {
            XCTAssertNotNil(response.saml)
            XCTAssertNil(response.saml?.authorizationURL)
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertEqual(queue.requestCount, 2)
    }

    func testGraphQLPreflightClassifiesInstallationBeforeAuthoritativeFailure() async throws {
        let authentication = try makeAuthentication(source: .forgeApplicationDeviceFlow)
        let repository = try makeRepository()
        let installationURL = try XCTUnwrap(
            URL(string: "https://github.com/apps/gitx-forge/installations/new")
        )
        let queue = RecoveryGraphQLQueue([
            .payload(
                operation: "GitHubSyncForkPreflight",
                value: ["errors": [["message": "Resource not accessible by integration"]]]
            ),
        ])
        install(queue)
        let restClient = RecoveryRESTClient(response: GitHubMutationHTTPResponse(
            statusCode: 500,
            headers: [:],
            data: Data()
        ))

        do {
            _ = try await makeAdapter(
                authentication: authentication,
                restClient: restClient,
                installationConfigurationURL: installationURL
            ).syncFork(
                accountID: authentication.account.id,
                plan: syncPlan(repository: repository),
                authorization: authorization(
                    authentication: authentication,
                    repository: repository,
                    operation: .syncFork
                )
            )
            XCTFail("Expected missing installation recovery")
        } catch let error as GitHubMutationError {
            guard case let .installationConfigurationRequired(metadata) = error else {
                return XCTFail("Unexpected \(error)")
            }
            XCTAssertEqual(metadata.installation?.configurationURL, installationURL)
            XCTAssertEqual(error.errorDescription, "GitHub App repository access configuration is required.")
        }
        XCTAssertEqual(queue.requestCount, 1)
        XCTAssertEqual(queue.remainingCount, 0)
        let restRequestCount = await restClient.requestCount
        XCTAssertEqual(restRequestCount, 0, "A failed preflight cannot dispatch the mutation")
    }

    func testPreflightAdmissionHonorsOfflineAndCooldownChangesAfterCredentialValidation() async throws {
        let authentication = try makeAuthentication(source: .classicPersonalAccessToken)
        let repository = try makeRepository()
        let evaluationDate = Date(timeIntervalSince1970: 1_775_000_000)
        let cooldownDeadline = evaluationDate.addingTimeInterval(60)

        for (transition, expectedError) in [
            (RecoveryAdmissionTransition.offline, GitHubMutationError.offline),
            (.cooldown(until: cooldownDeadline), .cooldown(until: cooldownDeadline)),
        ] {
            let gate = GitHubMutationSessionGate()
            let authority = RecoveryTransitioningCredentialAuthority(
                authentication: authentication,
                gate: gate,
                transition: transition
            )
            let queue = RecoveryGraphQLQueue([])
            install(queue)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RecoveryGraphQLURLProtocol.self]
            let adapter = GitHubMutationAdapter(
                expectedCredential: authentication.credential.reference,
                credentialAuthority: authority,
                sessionConfiguration: configuration,
                restClient: RecoveryRESTClient(response: GitHubMutationHTTPResponse(
                    statusCode: 500,
                    headers: [:],
                    data: Data()
                )),
                sessionGate: gate,
                now: { evaluationDate }
            )

            do {
                _ = try await adapter.createPullRequest(
                    accountID: authentication.account.id,
                    form: creationForm(repository: repository),
                    authorization: authorization(
                        authentication: authentication,
                        repository: repository,
                        operation: .createPullRequest
                    )
                )
                XCTFail("Expected request admission to stop before transport")
            } catch let error as GitHubMutationError {
                XCTAssertEqual(error, expectedError)
            }
            XCTAssertEqual(queue.requestCount, 0)
        }
    }

    func testCancelledTaskPropagatesCancellationDuringGraphQLPreflight() async throws {
        let authentication = try makeAuthentication(source: .classicPersonalAccessToken)
        let repository = try makeRepository()
        let queue = RecoveryGraphQLQueue([
            .success(operation: "GitHubPullRequestCreationPreflight", data: creationPreflight()),
        ])
        install(queue)
        let adapter = makeAdapter(authentication: authentication)
        let form = try creationForm(repository: repository)
        let mutationAuthorization = try authorization(
            authentication: authentication,
            repository: repository,
            operation: .createPullRequest
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await adapter.createPullRequest(
                accountID: authentication.account.id,
                form: form,
                authorization: mutationAuthorization
            )
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Cancellation remains cancellation; it is never offered as an authorization retry.
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testRESTMutationInstallationRecoveryIsAppOnlyAndDoesNotRetry() async throws {
        let repository = try makeRepository()
        let installationURL = try XCTUnwrap(
            URL(string: "https://github.com/apps/gitx-forge/installations/new")
        )
        let response = GitHubMutationHTTPResponse(
            statusCode: 403,
            headers: [:],
            data: Data(#"{"message":"Resource not accessible by integration"}"#.utf8)
        )

        let appAuthentication = try makeAuthentication(source: .forgeApplicationDeviceFlow)
        let appGraphQL = RecoveryGraphQLQueue([
            .success(operation: "GitHubSyncForkPreflight", data: syncPreflight()),
        ])
        install(appGraphQL)
        let appREST = RecoveryRESTClient(response: response)
        do {
            _ = try await makeAdapter(
                authentication: appAuthentication,
                restClient: appREST,
                installationConfigurationURL: installationURL
            ).syncFork(
                accountID: appAuthentication.account.id,
                plan: syncPlan(repository: repository),
                authorization: authorization(
                    authentication: appAuthentication,
                    repository: repository,
                    operation: .syncFork
                )
            )
            XCTFail("Expected missing installation recovery")
        } catch let GitHubMutationError.installationConfigurationRequired(metadata) {
            XCTAssertEqual(metadata.installation?.configurationURL, installationURL)
        } catch {
            XCTFail("Unexpected \(error)")
        }
        let appRESTRequestCount = await appREST.requestCount
        XCTAssertEqual(appRESTRequestCount, 1)

        let classicAuthentication = try makeAuthentication(source: .classicPersonalAccessToken)
        let classicGraphQL = RecoveryGraphQLQueue([
            .success(operation: "GitHubSyncForkPreflight", data: syncPreflight()),
        ])
        install(classicGraphQL)
        let classicREST = RecoveryRESTClient(response: response)
        do {
            _ = try await makeAdapter(
                authentication: classicAuthentication,
                restClient: classicREST,
                installationConfigurationURL: installationURL
            ).syncFork(
                accountID: classicAuthentication.account.id,
                plan: syncPlan(repository: repository),
                authorization: authorization(
                    authentication: classicAuthentication,
                    repository: repository,
                    operation: .syncFork
                )
            )
            XCTFail("Expected an ordinary permission denial")
        } catch let error as GitHubMutationError {
            guard case .permissionDenied = error else {
                return XCTFail("Unexpected \(error)")
            }
        }
        let classicRESTRequestCount = await classicREST.requestCount
        XCTAssertEqual(classicRESTRequestCount, 1)
    }
}

private extension GitHubAuthorizationRecoveryTransportTests {
    func install(_ queue: RecoveryGraphQLQueue) {
        RecoveryGraphQLURLProtocol.setHandler { try queue.response(for: $0) }
    }

    func makeRepository() throws -> ForgeRepositoryIdentity {
        try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            owner: "hbmartin",
            name: "gitx"
        )
    }

    func makeAuthentication(source: ForgeCredentialSource) throws -> GitHubReadAuthentication {
        let accountID = try ForgeAccountID(forge: makeRepository().forge, value: "octocat")
        let credential = try ForgeCredentialMetadata(
            reference: ForgeCredentialReference(
                accountID: accountID,
                credentialID: ForgeCredentialID("github-recovery"),
                generation: ForgeCredentialGeneration(1)
            ),
            source: source
        )
        return try GitHubReadAuthentication(
            account: ForgeAccount(id: accountID, login: "octocat", currentCredential: credential),
            credential: credential,
            accessToken: GitHubSecret("recovery-secret")
        )
    }

    func makeAdapter(
        authentication: GitHubReadAuthentication,
        restClient: (any GitHubMutationHTTPClient)? = nil,
        installationConfigurationURL: URL? = nil
    ) -> GitHubMutationAdapter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryGraphQLURLProtocol.self]
        let authority = RecoveryCredentialAuthority(authentication: authentication)
        if let restClient {
            return GitHubMutationAdapter(
                expectedCredential: authentication.credential.reference,
                credentialAuthority: authority,
                sessionConfiguration: configuration,
                restClient: restClient,
                now: { Date(timeIntervalSince1970: 1_775_000_000) },
                installationConfigurationURL: installationConfigurationURL
            )
        }
        return GitHubMutationAdapter(
            expectedCredential: authentication.credential.reference,
            credentialAuthority: authority,
            sessionConfiguration: configuration,
            installationConfigurationURL: installationConfigurationURL
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

    func syncPlan(repository: ForgeRepositoryIdentity) throws -> ForgeSyncForkPlan {
        try ForgeSyncForkPlan(
            fork: repository,
            parent: ForgeRepositoryIdentity(forge: repository.forge, owner: "gitx", name: "gitx"),
            branch: ForgeRefName("master"),
            localFetchRemoteName: "origin"
        )
    }

    func creationPreflight() -> [String: Any] {
        [
            "repository": repositoryIdentity().merging([
                "pullRequests": [
                    "__typename": "PullRequestConnection",
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
            ]) { _, new in new },
            "headRepository": repositoryIdentity(),
        ]
    }

    func syncPreflight() -> [String: Any] {
        [
            "repository": repositoryIdentity().merging([
                "isFork": true,
                "parent": [
                    "__typename": "Repository",
                    "id": "parent-node",
                    "name": "gitx",
                    "nameWithOwner": "gitx/gitx",
                    "owner": ["__typename": "Organization", "login": "gitx"],
                ],
            ]) { _, new in new },
        ]
    }

    func repositoryIdentity() -> [String: Any] {
        [
            "__typename": "Repository",
            "id": "repo-node",
            "name": "gitx",
            "nameWithOwner": "hbmartin/gitx",
            "owner": ["__typename": "User", "login": "hbmartin"],
        ]
    }
}

private actor RecoveryCredentialAuthority: GitHubReadCredentialAuthority {
    let authentication: GitHubReadAuthentication

    init(authentication: GitHubReadAuthentication) {
        self.authentication = authentication
    }

    func currentAuthentication(for _: ForgeCredentialReference) -> GitHubReadAuthentication? {
        authentication
    }
}

private enum RecoveryAdmissionTransition: Sendable {
    case offline
    case cooldown(until: Date)
}

private actor RecoveryTransitioningCredentialAuthority: GitHubReadCredentialAuthority {
    let authentication: GitHubReadAuthentication
    let gate: GitHubMutationSessionGate
    let transition: RecoveryAdmissionTransition

    init(
        authentication: GitHubReadAuthentication,
        gate: GitHubMutationSessionGate,
        transition: RecoveryAdmissionTransition
    ) {
        self.authentication = authentication
        self.gate = gate
        self.transition = transition
    }

    func currentAuthentication(for _: ForgeCredentialReference) async -> GitHubReadAuthentication? {
        switch transition {
        case .offline:
            await gate.setOffline(true)
        case let .cooldown(until):
            await gate.recordCooldown(for: authentication.credential.reference, until: until)
        }
        return authentication
    }
}

private actor RecoveryRESTClient: GitHubMutationHTTPClient {
    let response: GitHubMutationHTTPResponse
    private(set) var requestCount = 0

    init(response: GitHubMutationHTTPResponse) {
        self.response = response
    }

    func execute(_: URLRequest) async -> GitHubMutationHTTPResponse {
        requestCount += 1
        return response
    }
}

private struct RecoveryGraphQLResponse: Sendable {
    let operation: String
    let body: Data

    static func success(operation: String, data: [String: Any]) -> Self {
        payload(operation: operation, value: ["data": data])
    }

    static func payload(operation: String, value: [String: Any]) -> Self {
        Self(
            operation: operation,
            body: try! JSONSerialization.data(withJSONObject: value)
        )
    }
}

private final class RecoveryGraphQLQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [RecoveryGraphQLResponse]
    private var recordedRequestCount = 0

    init(_ responses: [RecoveryGraphQLResponse]) {
        self.responses = responses
    }

    var remainingCount: Int {
        lock.withLock { responses.count }
    }

    var requestCount: Int {
        lock.withLock { recordedRequestCount }
    }

    func response(for request: URLRequest) throws -> RecoveryGraphQLResponse {
        let body = try request.httpBody ?? XCTUnwrap(readBodyStream(request.httpBodyStream))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try lock.withLock {
            guard let response = responses.first,
                  response.operation == payload["operationName"] as? String
            else {
                throw RecoveryTransportError.unexpectedRequest
            }
            responses.removeFirst()
            recordedRequestCount += 1
            return response
        }
    }

    private func readBodyStream(_ stream: InputStream?) -> Data? {
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
}

private final class RecoveryGraphQLURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> RecoveryGraphQLResponse)?

    static func setHandler(_ value: (@Sendable (URLRequest) throws -> RecoveryGraphQLResponse)?) {
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
            client?.urlProtocol(self, didFailWithError: RecoveryTransportError.unexpectedRequest)
            return
        }
        do {
            let stub = try current(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/2",
                headerFields: ["Content-Type": "application/json"]
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

private enum RecoveryTransportError: Error {
    case unexpectedRequest
}
