@testable import ForgeKit
import Foundation
import XCTest

final class ForgeIdentityTests: XCTestCase {
    func testForgeKindDetectionPreservesLegacySubstringHeuristicAndGitHubFallback() {
        XCTAssertEqual(ForgeKind.detect(host: "github.com"), .github)
        XCTAssertEqual(ForgeKind.detect(host: "code.gitlab.example"), .gitLab)
        XCTAssertEqual(ForgeKind.detect(host: "BITBUCKET.example"), .bitbucket)
        XCTAssertEqual(ForgeKind.detect(host: "notgitlab.example"), .gitLab)
        XCTAssertEqual(ForgeKind.detect(host: "my-bitbucket-mirror.example"), .bitbucket)
        XCTAssertEqual(ForgeKind.detect(host: "example.test"), .github)
    }

    func testOriginNormalizesCaseDefaultPortAndTrailingDot() throws {
        let origin = try ForgeOrigin(url: XCTUnwrap(URL(string: "https://GitHub.COM.:443/")))
        XCTAssertEqual(origin.host, "github.com")
        XCTAssertNil(origin.port)
        XCTAssertEqual(origin.effectivePort, 443)
        XCTAssertEqual(origin.url.absoluteString, "https://github.com")
        XCTAssertTrue(try origin.isSameOrigin(as: ForgeOrigin(host: "github.com", port: 443)))
        XCTAssertFalse(try origin.isSameOrigin(as: ForgeOrigin(host: "github.com", port: 8443)))
        XCTAssertEqual(try ForgeOrigin(host: "github.com."), origin)
    }

    func testOriginNormalizesUnicodeAndPunycodeHosts() throws {
        let unicode = try ForgeOrigin(url: XCTUnwrap(URL(string: "https://例え.テスト")))
        let ascii = try ForgeOrigin(host: "xn--r8jz45g.xn--zckzah")
        XCTAssertEqual(unicode, ascii)
    }

    func testOriginRejectsUnsafeOrNonOriginURLs() throws {
        let cases: [(String, ForgeIdentityError)] = [
            ("http://github.com", .httpsRequired),
            ("ssh://git@github.com/acme/widgets", .httpsRequired),
            ("https://user@github.com", .credentialsNotAllowed),
            ("https://github.com/acme", .originContainsPath),
            ("https://github.com?x=1", .originContainsQueryOrFragment),
            ("https://github.com#fragment", .originContainsQueryOrFragment),
        ]
        for (value, expected) in cases {
            XCTAssertThrowsError(try ForgeOrigin(url: XCTUnwrap(URL(string: value))), value) {
                XCTAssertEqual($0 as? ForgeIdentityError, expected)
            }
        }
        for invalid in [
            "", " github.com", "github.com ", ".", ".github.com", "..github.com", "github.com..",
            "%2egithub.com", "bad..host", "bad/host", "bad@host", "github.com%00.evil", "github.com%0A.evil",
            "github%23evil",
        ] {
            XCTAssertThrowsError(try ForgeOrigin(host: invalid), invalid)
        }
        for invalidPort in [0, -1, 65536] {
            XCTAssertThrowsError(try ForgeOrigin(host: "example.com", port: invalidPort))
        }
    }

    func testEveryAcceptedOriginHasAReusableValidatedURL() throws {
        for host in ["github.com", "例え.テスト", "[::1]"] {
            let origin = try ForgeOrigin(host: host, port: 8443)
            XCTAssertEqual(try ForgeOrigin(url: origin.url), origin)
        }
    }

    func testRepositoryIdentitySupportsNestedUnicodeOwnerAndStableCoding() throws {
        let repository = try TestSupport.repository(owner: "équipe/outils", name: "café")
        XCTAssertEqual(repository.ownerPathComponents, ["équipe", "outils"])
        XCTAssertEqual(repository.canonicalKey, "github|https://github.com|équipe/outils/café")
        let encoded = try JSONEncoder().encode(repository)
        XCTAssertEqual(try JSONDecoder().decode(ForgeRepositoryIdentity.self, from: encoded), repository)
    }

    func testRepositoryAndAccountRejectUnsafeIdentityComponents() throws {
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        for owner in ["", "/acme", "acme/", "acme//team", ".", "..", "acme\\team"] {
            XCTAssertThrowsError(try ForgeRepositoryIdentity(forge: forge, owner: owner, name: "repo"), owner)
        }
        for name in ["", ".", "..", "a/b", "a\\b", " repo"] {
            XCTAssertThrowsError(try ForgeRepositoryIdentity(forge: forge, owner: "acme", name: name), name)
        }
        for account in ["", " account", "account\n"] {
            XCTAssertThrowsError(try ForgeAccountID(forge: forge, value: account), account)
        }
        let account = try ForgeAccountID(forge: forge, value: "account-1")
        XCTAssertEqual(try JSONDecoder().decode(ForgeAccountID.self, from: JSONEncoder().encode(account)), account)
    }

    func testValidatedValueCodersRejectInvalidPayloads() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeOrigin.self, from: Data(#"{"host":"bad..host"}"#.utf8)))
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ForgeRepositoryIdentity.self,
                from: Data(#"{"forge":{"kind":"github","origin":{"host":"github.com"}},"owner":"..","name":"repo"}"#.utf8)
            )
        )
    }
}
