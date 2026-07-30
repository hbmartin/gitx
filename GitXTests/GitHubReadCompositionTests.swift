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
