import ForgeKit
import Foundation
import GitHubForgeAdapter
import XCTest

final class GitHubReadCompositionTests: XCTestCase {
    override func tearDown() {
        CompositionGitHubURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testAuthorityRequiresExactCurrentGitHubCredentialAndRejectsExpiredOrMalformedSecrets() async throws {
        let keychain = ReadCompositionKeychain()
        let accountStore = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("node-1")
        let account = try await accountStore.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("pat-1"),
            kind: .fineGrained,
            token: Data("github_pat_byte-safe".utf8),
            expiresAt: Date(timeIntervalSince1970: 2000)
        )
        let authority = ForgeGitHubReadCredentialAuthority(
            accountStore: accountStore,
            now: { Date(timeIntervalSince1970: 1000) }
        )

        let authentication = try await authority.currentAuthentication(
            for: account.currentCredential.reference
        )
        XCTAssertEqual(authentication?.account, account)
        XCTAssertEqual(authentication?.credential, account.currentCredential)

        let staleReference = try ForgeCredentialReference(
            accountID: accountID,
            credentialID: ForgeCredentialID("pat-1"),
            generation: ForgeCredentialGeneration(2)
        )
        let staleAuthentication = try await authority.currentAuthentication(for: staleReference)
        XCTAssertNil(staleAuthentication)

        let expiredAuthority = ForgeGitHubReadCredentialAuthority(
            accountStore: accountStore,
            now: { Date(timeIntervalSince1970: 2000) }
        )
        let expiredAuthentication = try await expiredAuthority.currentAuthentication(
            for: account.currentCredential.reference
        )
        XCTAssertNil(expiredAuthentication)

        let gitLabReference = try makeCredentialReference(
            kind: .gitLab,
            host: "gitlab.com",
            account: "gitlab-node"
        )
        let crossForgeAuthentication = try await authority.currentAuthentication(for: gitLabReference)
        XCTAssertNil(crossForgeAuthentication)
        XCTAssertEqual(
            ForgeGitHubReadCompositionError.githubDotComCredentialRequired.errorDescription,
            "GitHub reads require a GitHub.com Credential."
        )
        do {
            _ = try await authority.credentialChange(for: gitLabReference)
            XCTFail("cross-forge invalidation must fail closed")
        } catch {
            XCTAssertEqual(
                error as? ForgeGitHubReadCompositionError,
                .githubDotComCredentialRequired
            )
        }
        XCTAssertThrowsError(
            try ForgeGitHubReadAdapterFactory(credentialAuthority: authority)
                .makeAdapter(for: gitLabReference)
        ) {
            XCTAssertEqual(
                $0 as? ForgeGitHubReadCompositionError,
                .githubDotComCredentialRequired
            )
        }

        try keychain.replaceAccessToken(
            with: Data([0xFF]),
            accountKey: ForgeAccountStore.keychainAccountKey(for: accountID)
        )
        do {
            _ = try await authority.currentAuthentication(for: account.currentCredential.reference)
            XCTFail("malformed GitHub token bytes must fail before transport creation")
        } catch {
            XCTAssertEqual(error as? GitHubAuthenticationError, .invalidSecret)
            XCTAssertFalse(error.localizedDescription.contains("byte-safe"))
        }
    }

    func testRetainedAdapterUsesRotatedTokenThenRejectsReplacementAndRemovalBeforeNetwork() async throws {
        let keychain = ReadCompositionKeychain()
        let accountStore = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("node-rotation")
        let original = try await accountStore.addAccount(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("app-credential"),
            source: .forgeApplicationDeviceFlow,
            expiresAt: Date.distantFuture,
            secrets: rotatingSecrets(access: "original-access", refresh: "original-refresh")
        )
        let authority = ForgeGitHubReadCredentialAuthority(accountStore: accountStore)
        let factory = ForgeGitHubReadAdapterFactory(credentialAuthority: authority)
        let capture = ReadCompositionRequestCapture()
        CompositionGitHubURLProtocol.setHandler { request in
            capture.record(request)
            return CompositionStubResponse(status: 401, body: Data())
        }
        let adapter = try factory.makeAdapter(
            for: original.currentCredential.reference,
            sessionConfiguration: stubConfiguration()
        )

        await assertAuthenticationFailure(adapter)
        XCTAssertEqual(capture.authorizationHeaders, ["Bearer original-access"])
        let addedChange = try await factory.credentialChange(for: original.currentCredential.reference)
        XCTAssertEqual(addedChange.revision, 1)

        let rotated = try await accountStore.rotateCredential(
            expectedReference: original.currentCredential.reference,
            expiresAt: Date.distantFuture,
            secrets: rotatingSecrets(access: "rotated-access", refresh: "rotated-refresh")
        )
        XCTAssertEqual(rotated.currentCredential.reference, original.currentCredential.reference)
        await assertAuthenticationFailure(adapter)
        XCTAssertEqual(
            capture.authorizationHeaders,
            ["Bearer original-access", "Bearer rotated-access"]
        )
        let rotatedChange = try await factory.credentialChange(for: original.currentCredential.reference)
        XCTAssertEqual(rotatedChange.revision, 2)

        let replacement = try await accountStore.replaceCredential(
            expectedReference: original.currentCredential.reference,
            credentialID: ForgeCredentialID("replacement-pat"),
            source: .classicPersonalAccessToken,
            expiresAt: nil,
            secrets: ForgeCredentialSecretMaterial(accessToken: Data("replacement-access".utf8))
        )
        await assertAuthenticationFailure(adapter)
        XCTAssertEqual(capture.authorizationHeaders.count, 2, "replacement must reject before transport")
        let replacementChange = try await factory.credentialChange(for: original.currentCredential.reference)
        XCTAssertEqual(
            replacementChange,
            ForgeAccountCredentialChange(
                accountID: accountID,
                currentReference: replacement.currentCredential.reference,
                revision: 3
            )
        )

        let replacementAdapter = try factory.makeAdapter(
            for: replacement.currentCredential.reference,
            sessionConfiguration: stubConfiguration()
        )
        await assertAuthenticationFailure(replacementAdapter)
        XCTAssertEqual(capture.authorizationHeaders.last, "Bearer replacement-access")

        try await accountStore.removeAccount(accountID)
        await assertAuthenticationFailure(replacementAdapter)
        XCTAssertEqual(capture.authorizationHeaders.count, 3, "removal must reject before transport")
        let removedChange = try await factory.credentialChange(for: replacement.currentCredential.reference)
        XCTAssertEqual(
            removedChange,
            ForgeAccountCredentialChange(accountID: accountID, currentReference: nil, revision: 4)
        )
    }

    func testConcurrentAuthorityLoadsStayExactAndRedacted() async throws {
        let keychain = ReadCompositionKeychain()
        let accountStore = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("node-concurrent")
        let account = try await accountStore.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("concurrent-pat"),
            kind: .classic,
            token: Data("concurrent-secret-token".utf8),
            expiresAt: nil
        )
        let authority = ForgeGitHubReadCredentialAuthority(accountStore: accountStore)
        let factory = ForgeGitHubReadAdapterFactory(credentialAuthority: authority)
        let readsBeforeConcurrentLoad = keychain.dataReadCount
        let references = try await withThrowingTaskGroup(
            of: ForgeCredentialReference?.self,
            returning: [ForgeCredentialReference?].self
        ) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    try await authority.currentAuthentication(
                        for: account.currentCredential.reference
                    )?.credential.reference
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(references.count, 32)
        XCTAssertTrue(references.allSatisfy { $0 == account.currentCredential.reference })
        XCTAssertEqual(keychain.dataReadCount, readsBeforeConcurrentLoad + 32)
        assertRedacted(authority, forbidden: "concurrent-secret-token")
        assertRedacted(factory, forbidden: "concurrent-secret-token")
        let authentication = try await authority.currentAuthentication(
            for: account.currentCredential.reference
        )
        let resolvedAuthentication = try XCTUnwrap(authentication)
        assertRedacted(resolvedAuthentication, forbidden: "concurrent-secret-token")
    }

    func testCancellationBeforeAuthorityEntryPreventsKeychainAndNetworkAccess() async throws {
        let keychain = ReadCompositionKeychain()
        let accountStore = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("node-cancelled")
        let account = try await accountStore.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("cancelled-pat"),
            kind: .classic,
            token: Data("cancelled-secret-token".utf8),
            expiresAt: nil
        )
        let authority = ForgeGitHubReadCredentialAuthority(accountStore: accountStore)
        let capture = ReadCompositionRequestCapture()
        CompositionGitHubURLProtocol.setHandler { request in
            capture.record(request)
            return CompositionStubResponse(status: 200, body: Data())
        }
        let adapter = try ForgeGitHubReadAdapterFactory(credentialAuthority: authority).makeAdapter(
            for: account.currentCredential.reference,
            sessionConfiguration: stubConfiguration()
        )
        let keychainReadsBeforeRequest = keychain.dataReadCount
        let repository = try makeRepository()
        let gate = AsyncStream<Void>.makeStream()
        let stream = gate.stream
        let task = Task { [adapter, repository, stream] in
            for await _ in stream {
                break
            }
            return try await adapter.repositoryFacts(repository: repository)
        }
        task.cancel()
        gate.continuation.yield(())
        gate.continuation.finish()

        do {
            _ = try await task.value
            XCTFail("pre-cancelled read must not enter credential or transport work")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(keychain.dataReadCount, keychainReadsBeforeRequest)
        XCTAssertEqual(capture.authorizationHeaders, [])
    }

    @MainActor
    func testReadSurfaceAdapterBoxAndConvenienceServiceFailClosedWithoutAuthentication() async throws {
        let repository = try makeRepository()
        let cursor = try ForgePageCursor("next")
        let adapter = GitHubReadAdapter(sessionConfiguration: stubConfiguration())
        let box = ForgeGitHubReadSurfaceAdapterBox(adapter: adapter)

        await assertAuthenticationRequired {
            try await box.pullRequests(repository: repository, after: cursor, states: [.closed, .merged])
        }
        await assertAuthenticationRequired {
            try await box.issues(repository: repository, after: cursor, states: [.open])
        }
        await assertAuthenticationRequired {
            try await box.searchRepositoryItems(repository: repository, text: "literal search", after: cursor)
        }
        await assertAuthenticationRequired {
            try await box.pullRequestDetails(
                repository: repository,
                number: ForgeItemNumber(7),
                timelineAfter: cursor,
                checkAfter: cursor
            )
        }
        await assertAuthenticationRequired {
            try await box.issueDetails(
                repository: repository,
                number: ForgeItemNumber(8),
                timelineAfter: cursor
            )
        }

        let service = ForgeGitHubReadSurfaceService(
            repository: repository,
            adapter: adapter,
            now: { Date(timeIntervalSince1970: 500) }
        )
        await assertAuthenticationRequired {
            try await service.loadItems(
                kind: .pullRequests,
                query: ForgeReadSurfaceQuery(stateFilter: .all),
                after: nil
            )
        }
    }

    func testReadSurfaceAdapterBoxPreservesSuccessfulAdapterReads() async throws {
        let keychain = ReadCompositionKeychain()
        let accountStore = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("surface-success")
        let account = try await accountStore.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("surface-pat"),
            kind: .fineGrained,
            token: Data("surface-access".utf8),
            expiresAt: nil
        )
        CompositionGitHubURLProtocol.setHandler { request in
            CompositionStubResponse(
                status: 200,
                body: Self.readSurfaceResponse(for: Self.operationName(from: request))
            )
        }
        let adapter = try ForgeGitHubReadAdapterFactory(
            credentialAuthority: ForgeGitHubReadCredentialAuthority(accountStore: accountStore)
        ).makeAdapter(
            for: account.currentCredential.reference,
            sessionConfiguration: stubConfiguration()
        )
        let box = ForgeGitHubReadSurfaceAdapterBox(adapter: adapter)
        let repository = try makeRepository()
        let number = try ForgeItemNumber(7)

        let pullRequests = try await box.pullRequests(repository: repository, after: nil, states: [.open])
        let issues = try await box.issues(repository: repository, after: nil, states: [.closed])
        let search = try await box.searchRepositoryItems(repository: repository, text: "surface", after: nil)
        let pullRequest = try await box.pullRequestDetails(
            repository: repository,
            number: number,
            timelineAfter: nil,
            checkAfter: nil
        )
        let issue = try await box.issueDetails(
            repository: repository,
            number: number,
            timelineAfter: nil
        )

        XCTAssertEqual(pullRequests.value.items, [])
        XCTAssertEqual(issues.value.items, [])
        XCTAssertEqual(search.value.items, [])
        XCTAssertEqual(pullRequest.value.details.summary.number, number)
        XCTAssertEqual(issue.value.summary.number, number)
    }

    func testReadSurfaceResultWrapperPreservesCompleteAndPartialEvidence() throws {
        let repository = try makeRepository()
        let credential = try makeCredentialReference(
            kind: .github,
            host: "github.com",
            account: "surface-result"
        )
        let response = GitHubResponseMetadata(
            statusCode: 200,
            requestID: "request-id",
            rateLimit: GitHubRateLimitParser.parse(
                statusCode: 200,
                headers: [:],
                receivedAt: Date(timeIntervalSince1970: 400)
            )
        )
        let ownership = try GitHubReadOwnership(credential: credential, repository: repository)
        let partial = ForgeGitHubSurfaceRead(GitHubReadResult(
            value: "partial",
            completeness: .partial,
            problems: [],
            response: response,
            ownership: ownership
        ))
        let complete = ForgeGitHubSurfaceRead(GitHubReadResult(
            value: "complete",
            completeness: .complete,
            problems: [],
            response: response,
            ownership: ownership
        ))

        XCTAssertEqual(partial.value, "partial")
        XCTAssertTrue(partial.isPartial)
        XCTAssertEqual(complete.value, "complete")
        XCTAssertFalse(complete.isPartial)
    }

    private func assertAuthenticationFailure(
        _ adapter: GitHubReadAdapter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await adapter.repositoryFacts(repository: makeRepository())
            XCTFail("request must be rejected", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .authenticationRequired, file: file, line: line)
        }
    }

    private func assertAuthenticationRequired<Value>(
        _ operation: () async throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("request must require authentication", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .authenticationRequired, file: file, line: line)
        }
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompositionGitHubURLProtocol.self]
        return configuration
    }

    private func makeRepository() throws -> ForgeRepositoryIdentity {
        try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            owner: "hbmartin",
            name: "gitx"
        )
    }

    private static func operationName(from request: URLRequest) -> String {
        guard let body = request.httpBody ?? readBodyStream(request.httpBodyStream),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let operationName = object["operationName"] as? String
        else {
            return ""
        }
        return operationName
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func readSurfaceResponse(for operation: String) -> Data {
        let data: [String: Any]
        switch operation {
        case "GitHubPullRequestList":
            data = ["repository": [
                "__typename": "Repository",
                "id": "repository",
                "pullRequests": emptyConnection("PullRequestConnection"),
            ]]
        case "GitHubIssueList":
            data = ["repository": [
                "__typename": "Repository",
                "id": "repository",
                "issues": emptyConnection("IssueConnection"),
            ]]
        case "GitHubRepositoryItemSearch":
            data = ["search": emptyConnection("SearchResultItemConnection")]
        case "GitHubPullRequestDetails":
            data = ["repository": [
                "__typename": "Repository",
                "id": "repository",
                "pullRequest": pullRequestDetails,
            ]]
        case "GitHubIssueDetails":
            data = ["repository": [
                "__typename": "Repository",
                "id": "repository",
                "issue": issueDetails,
            ]]
        default:
            data = [:]
        }
        return try! JSONSerialization.data(withJSONObject: ["data": data])
    }

    private static var pageInfo: [String: Any] {
        [
            "__typename": "PageInfo",
            "hasPreviousPage": false,
            "startCursor": NSNull(),
            "hasNextPage": false,
            "endCursor": NSNull(),
        ]
    }

    private static func emptyConnection(_ type: String) -> [String: Any] {
        ["__typename": type, "totalCount": 0, "pageInfo": pageInfo, "nodes": []]
    }

    private static var actor: [String: Any] {
        [
            "__typename": "User",
            "id": "actor",
            "login": "octocat",
            "name": "Octo",
            "avatarUrl": "https://avatars.githubusercontent.com/u/1",
        ]
    }

    private static var repositoryIdentity: [String: Any] {
        [
            "__typename": "Repository",
            "id": "repository",
            "name": "gitx",
            "nameWithOwner": "hbmartin/gitx",
            "owner": ["__typename": "User", "login": "hbmartin"],
        ]
    }

    private static var pullRequestDetails: [String: Any] {
        [
            "__typename": "PullRequest",
            "id": "pr",
            "number": 7,
            "pullRequestState": "OPEN",
            "isDraft": false,
            "title": "Adapter",
            "body": "body",
            "createdAt": "2026-07-29T12:34:56Z",
            "updatedAt": "2026-07-29T12:34:56Z",
            "closedAt": NSNull(),
            "mergedAt": NSNull(),
            "author": actor,
            "headRefName": "feature",
            "headRefOid": "abcdef12",
            "headRepository": repositoryIdentity,
            "baseRefName": "main",
            "baseRefOid": "1234abcd",
            "baseRepository": repositoryIdentity,
            "labels": emptyConnection("LabelConnection"),
            "statusCheckRollup": [
                "__typename": "StatusCheckRollup",
                "state": "SUCCESS",
                "contexts": emptyConnection("StatusCheckRollupContextConnection"),
            ],
            "reviewDecision": NSNull(),
            "mergeable": "MERGEABLE",
            "assignedActors": emptyConnection("AssigneeConnection"),
            "milestone": NSNull(),
            "participants": emptyConnection("UserConnection"),
            "reviewRequests": emptyConnection("ReviewRequestConnection"),
            "latestReviews": emptyConnection("PullRequestReviewConnection"),
            "closingIssuesReferences": emptyConnection("IssueConnection"),
            "timelineItems": emptyConnection("PullRequestTimelineItemsConnection"),
        ]
    }

    private static var issueDetails: [String: Any] {
        [
            "__typename": "Issue",
            "id": "issue",
            "number": 7,
            "issueState": "OPEN",
            "title": "Issue",
            "body": "body",
            "createdAt": "2026-07-29T12:34:56Z",
            "updatedAt": "2026-07-29T12:34:56Z",
            "closedAt": NSNull(),
            "author": actor,
            "labels": emptyConnection("LabelConnection"),
            "assignedActors": emptyConnection("AssigneeConnection"),
            "milestone": NSNull(),
            "participants": emptyConnection("UserConnection"),
            "timelineItems": emptyConnection("IssueTimelineItemsConnection"),
        ]
    }

    private func makeAccountID(_ value: String) throws -> ForgeAccountID {
        try ForgeAccountID(forge: makeRepository().forge, value: value)
    }

    private func makeCredentialReference(
        kind: ForgeKind,
        host: String,
        account: String
    ) throws -> ForgeCredentialReference {
        let accountID = try ForgeAccountID(
            forge: ForgeIdentity(kind: kind, origin: ForgeOrigin(host: host)),
            value: account
        )
        return try ForgeCredentialReference(
            accountID: accountID,
            credentialID: ForgeCredentialID("credential"),
            generation: ForgeCredentialGeneration(1)
        )
    }

    private func rotatingSecrets(access: String, refresh: String) throws -> ForgeCredentialSecretMaterial {
        try ForgeCredentialSecretMaterial(
            accessToken: Data(access.utf8),
            refreshToken: Data(refresh.utf8),
            refreshTokenExpiresAt: Date.distantFuture
        )
    }

    private func assertRedacted<Value>(
        _ value: Value,
        forbidden: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(String(describing: value).contains(forbidden), file: file, line: line)
        XCTAssertFalse(String(reflecting: value).contains(forbidden), file: file, line: line)
        if let reflected = value as? any CustomReflectable {
            XCTAssertTrue(reflected.customMirror.children.isEmpty, file: file, line: line)
        }
    }
}

// swift6-safety-justification: The lock serializes all in-memory Keychain test-double state.
private final nonisolated class ReadCompositionKeychain: ForgeCredentialKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var reads = 0

    var dataReadCount: Int {
        lock.withLock { reads }
    }

    func data(for accountKey: String) throws -> Data? {
        lock.withLock {
            reads += 1
            return storage[accountKey]
        }
    }

    func allItems() throws -> [ForgeKeychainItem] {
        lock.withLock { storage.map(ForgeKeychainItem.init(accountKey:data:)) }
    }

    func replace(_ data: Data, for accountKey: String) throws {
        lock.withLock { storage[accountKey] = data }
    }

    func remove(accountKey: String) throws {
        lock.withLock { _ = storage.removeValue(forKey: accountKey) }
    }

    func replaceAccessToken(with token: Data, accountKey: String) throws {
        try lock.withLock {
            let data = try XCTUnwrap(storage[accountKey])
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            var secrets = try XCTUnwrap(object["secrets"] as? [String: Any])
            secrets["accessToken"] = token.base64EncodedString()
            object["secrets"] = secrets
            storage[accountKey] = try JSONSerialization.data(withJSONObject: object)
        }
    }
}

private struct CompositionStubResponse: Sendable {
    let status: Int
    let body: Data
}

// swift6-safety-justification: The lock serializes captured request metadata.
private final nonisolated class ReadCompositionRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var headers: [String] = []

    var authorizationHeaders: [String] {
        lock.withLock { headers }
    }

    func record(_ request: URLRequest) {
        lock.withLock {
            headers.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        }
    }
}

// swift6-safety-justification: The lock serializes the nonisolated handler used by URLProtocol callbacks.
private final class CompositionGitHubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    // swift6-safety-justification: The lock serializes all reads and writes of the URLProtocol handler.
    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> CompositionStubResponse)?

    static func setHandler(_ value: (@Sendable (URLRequest) -> CompositionStubResponse)?) {
        lock.withLock { handler = value }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }) else {
            client?.urlProtocol(self, didFailWithError: GitHubReadError.transportFailure)
            return
        }
        let stub = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/2",
            headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
