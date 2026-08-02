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
