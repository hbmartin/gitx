import Foundation
@testable import GitHubForgeAdapter
import XCTest

final class GitHubGraphQLTransportTests: XCTestCase {
    func testIsolatedConfigurationClearsAmbientAuthenticationStateWithoutMutatingInput() {
        let original = URLSessionConfiguration.default
        let cookieStorage = HTTPCookieStorage.shared
        let credentialStorage = URLCredentialStorage.shared
        let cache = URLCache(memoryCapacity: 1024, diskCapacity: 0)
        original.httpCookieStorage = cookieStorage
        original.httpShouldSetCookies = true
        original.urlCredentialStorage = credentialStorage
        original.urlCache = cache
        original.requestCachePolicy = .useProtocolCachePolicy
        original.protocolClasses = [GraphQLIsolationURLProtocol.self]

        let isolated = GitHubGraphQLTransportFactory.isolatedConfiguration(from: original)

        XCTAssertFalse(isolated === original)
        XCTAssertNil(isolated.httpCookieStorage)
        XCTAssertFalse(isolated.httpShouldSetCookies)
        XCTAssertNil(isolated.urlCredentialStorage)
        XCTAssertNil(isolated.urlCache)
        XCTAssertEqual(isolated.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(
            isolated.protocolClasses?.map(NSStringFromClass),
            [NSStringFromClass(GraphQLIsolationURLProtocol.self)]
        )

        XCTAssertTrue(original.httpCookieStorage === cookieStorage)
        XCTAssertTrue(original.httpShouldSetCookies)
        XCTAssertTrue(original.urlCredentialStorage === credentialStorage)
        XCTAssertTrue(original.urlCache === cache)
        XCTAssertEqual(original.requestCachePolicy, .useProtocolCachePolicy)
        XCTAssertEqual(
            original.protocolClasses?.map(NSStringFromClass),
            [NSStringFromClass(GraphQLIsolationURLProtocol.self)]
        )
    }

    func testSecondaryRateLimitEvidenceAcceptsOnlyDocumentedMessageFields() {
        XCTAssertTrue(GitHubSecondaryRateLimitEvidence.detect(in: Data(
            #"{"message":"You have exceeded a secondary rate limit."}"#.utf8
        )))
        XCTAssertTrue(GitHubSecondaryRateLimitEvidence.detect(in: Data(
            #"{"errors":[{"message":"You have triggered an abuse detection mechanism."}]}"#.utf8
        )))
        XCTAssertFalse(GitHubSecondaryRateLimitEvidence.detect(in: Data(
            #"{"message":"Resource not accessible by integration"}"#.utf8
        )))
        XCTAssertFalse(GitHubSecondaryRateLimitEvidence.detect(in: Data(
            #"{"documentation_url":"https://docs.github.com/rest/rate-limit"}"#.utf8
        )))
        XCTAssertFalse(GitHubSecondaryRateLimitEvidence.detect(in: Data(
            repeating: 0x20,
            count: 64 * 1024 + 1
        )))
    }

    func testMetadataBoxDetectsSecondaryRateLimitAcrossBoundedBodyChunks() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(URL(string: "https://api.github.com/graphql")),
            statusCode: 403,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/json"]
        ))
        let box = GitHubResponseMetadataBox()
        box.record(response)
        box.record(response, body: Data(#"{"message":"You have exceeded a "#.utf8))
        XCTAssertFalse(box.indicatesSecondaryRateLimit())
        box.record(response, body: Data(#"secondary rate limit."}"#.utf8))
        XCTAssertTrue(box.indicatesSecondaryRateLimit())

        let oversizedBox = GitHubResponseMetadataBox()
        oversizedBox.record(response, body: Data(
            repeating: 0x20,
            count: GitHubSecondaryRateLimitEvidence.maximumBodySize
        ))
        oversizedBox.record(response, body: Data("x".utf8))
        oversizedBox.record(response, body: Data(
            #"{"message":"You have exceeded a secondary rate limit."}"#.utf8
        ))
        XCTAssertFalse(oversizedBox.indicatesSecondaryRateLimit())
    }
}

private final class GraphQLIsolationURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool {
        false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {}

    override func stopLoading() {}
}
