@testable import ForgeKit
import Foundation
import XCTest

final class ForgeWebURLPolicyTests: XCTestCase {
    func testCustomHTTPSURLTemplateExpandsEncodedValues() throws {
        let repository = try TestSupport.repository()
        let url = try ForgeWebURLPolicy.customURL(
            template: "{remoteURL}/tree/{branch}?from={sha}",
            repository: repository,
            branch: "feature/naïve?#",
            commitID: "abc 123",
            requireOriginMatch: true
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://github.com/acme/widgets/tree/feature%2Fna%C3%AFve%3F%23?from=abc%20123"
        )
    }

    func testCustomTemplateRejectsSchemesCredentialsUnknownFieldsAndOriginDeception() throws {
        let repository = try TestSupport.repository()
        let cases: [(String, ForgeWebURLPolicyError)] = [
            ("http://github.com/{branch}", .httpsRequired),
            ("https://user@github.com/{branch}", .credentialsNotAllowed),
            ("https://github.com/{unknown}", .invalidTemplate),
            ("https://github.com.evil/{branch}", .hostMismatch),
            ("https://.github.com/{branch}", .invalidTemplate),
            ("not a URL {branch}", .invalidTemplate),
        ]
        for (template, expected) in cases {
            XCTAssertThrowsError(
                try ForgeWebURLPolicy.customURL(
                    template: template,
                    repository: repository,
                    branch: "main",
                    commitID: "abc1234",
                    requireOriginMatch: true
                ),
                template
            ) {
                XCTAssertEqual($0 as? ForgeWebURLPolicyError, expected)
            }
        }
    }

    func testCustomTemplateOriginMatchingIncludesEffectivePort() throws {
        let repository = try TestSupport.repository(host: "git.example", port: 8443)
        XCTAssertNoThrow(
            try ForgeWebURLPolicy.customURL(
                template: "https://git.example:8443/acme/widgets/tree/{branch}",
                repository: repository,
                branch: "main",
                commitID: "abc1234",
                requireOriginMatch: true
            )
        )
        XCTAssertThrowsError(
            try ForgeWebURLPolicy.customURL(
                template: "https://git.example/acme/widgets/tree/{branch}",
                repository: repository,
                branch: "main",
                commitID: "abc1234",
                requireOriginMatch: true
            )
        ) {
            XCTAssertEqual($0 as? ForgeWebURLPolicyError, .hostMismatch)
        }
        XCTAssertNoThrow(
            try ForgeWebURLPolicy.customURL(
                template: "https://other.example/{branch}",
                repository: repository,
                branch: "main",
                commitID: "abc1234",
                requireOriginMatch: false
            )
        )
        XCTAssertThrowsError(
            try ForgeWebURLPolicy.customURL(
                template: "https://github%23evil/{branch}",
                repository: repository,
                branch: "main",
                commitID: "abc1234",
                requireOriginMatch: false
            )
        ) {
            XCTAssertEqual($0 as? ForgeWebURLPolicyError, .invalidTemplate)
        }
    }

    func testPostPushURLDetectionAndHostProtectionPreserveLegacyBehavior() throws {
        let repository = try TestSupport.repository()
        let first = try XCTUnwrap(
            ForgeWebURLPolicy.firstHTTPURL(
                in: "remote: See ftp://example.com/a then https://github.com/acme/widgets/pull/7 to review."
            )
        )
        XCTAssertEqual(first.absoluteString, "https://github.com/acme/widgets/pull/7")
        XCTAssertTrue(
            ForgeWebURLPolicy.postPushURL(first, matchesRemote: repository, requireHostMatch: true)
        )
        XCTAssertTrue(
            try ForgeWebURLPolicy.postPushURL(
                XCTUnwrap(URL(string: "http://github.com/acme/widgets/pull/7")),
                matchesRemote: repository,
                requireHostMatch: true
            )
        )
        XCTAssertFalse(
            try ForgeWebURLPolicy.postPushURL(
                XCTUnwrap(URL(string: "https://github.com.evil/acme/widgets/pull/7")),
                matchesRemote: repository,
                requireHostMatch: true
            )
        )
        XCTAssertFalse(
            try ForgeWebURLPolicy.postPushURL(
                XCTUnwrap(URL(string: "https://.github.com/acme/widgets/pull/7")),
                matchesRemote: repository,
                requireHostMatch: true
            )
        )
        XCTAssertTrue(
            try ForgeWebURLPolicy.postPushURL(
                XCTUnwrap(URL(string: "https://other.example/path")),
                matchesRemote: repository,
                requireHostMatch: false
            )
        )
    }

    func testPostPushPolicyRejectsUnsafeOrMissingURLs() throws {
        let repository = try TestSupport.repository()
        XCTAssertNil(ForgeWebURLPolicy.firstHTTPURL(in: "remote: no browser destination"))
        for string in [
            "ftp://github.com/path",
            "https://user@github.com/path",
            "file:///tmp/repo",
        ] {
            XCTAssertFalse(
                try ForgeWebURLPolicy.postPushURL(
                    XCTUnwrap(URL(string: string)),
                    matchesRemote: repository,
                    requireHostMatch: false
                ),
                string
            )
        }
    }
}
