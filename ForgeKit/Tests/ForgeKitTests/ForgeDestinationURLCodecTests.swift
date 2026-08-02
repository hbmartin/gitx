@testable import ForgeKit
import Foundation
import XCTest

final class ForgeDestinationURLCodecTests: XCTestCase {
    func testDestinationTablesCoverEverySupportedLinkFamily() throws {
        struct Expected {
            let kind: ForgeKind
            let repository: String
            let branch: String
            let commit: String
            let file: String
            let line: String
            let range: String
            let compare: String
            let pullRequest: String
            let issue: String
        }
        let examples = [
            Expected(
                kind: .github,
                repository: "https://github.com/acme/widgets",
                branch: "https://github.com/acme/widgets/tree/feature%2Fna%C3%AFve",
                commit: "https://github.com/acme/widgets/commit/abc1234",
                file: "https://github.com/acme/widgets/blob/feature%2Fna%C3%AFve/Sources/na%C3%AFve%20file.swift",
                line: "https://github.com/acme/widgets/blob/feature%2Fna%C3%AFve/Sources/na%C3%AFve%20file.swift#L10",
                range: "https://github.com/acme/widgets/blob/feature%2Fna%C3%AFve/Sources/na%C3%AFve%20file.swift#L10-L20",
                compare: "https://github.com/acme/widgets/compare/main...feature%2Fna%C3%AFve",
                pullRequest: "https://github.com/acme/widgets/pull/12",
                issue: "https://github.com/acme/widgets/issues/34"
            ),
            Expected(
                kind: .gitLab,
                repository: "https://gitlab.com/acme/widgets",
                branch: "https://gitlab.com/acme/widgets/-/tree/feature%2Fna%C3%AFve",
                commit: "https://gitlab.com/acme/widgets/-/commit/abc1234",
                file: "https://gitlab.com/acme/widgets/-/blob/feature%2Fna%C3%AFve/Sources/na%C3%AFve%20file.swift",
                line: "https://gitlab.com/acme/widgets/-/blob/feature%2Fna%C3%AFve/Sources/na%C3%AFve%20file.swift#L10",
                range: "https://gitlab.com/acme/widgets/-/blob/feature%2Fna%C3%AFve/Sources/na%C3%AFve%20file.swift#L10-L20",
                compare: "https://gitlab.com/acme/widgets/-/compare/main...feature%2Fna%C3%AFve",
                pullRequest: "https://gitlab.com/acme/widgets/-/merge_requests/12",
                issue: "https://gitlab.com/acme/widgets/-/issues/34"
            ),
            Expected(
                kind: .bitbucket,
                repository: "https://bitbucket.org/acme/widgets",
                branch: "https://bitbucket.org/acme/widgets/src/feature%2Fna%C3%AFve",
                commit: "https://bitbucket.org/acme/widgets/commits/abc1234",
                file: "https://bitbucket.org/acme/widgets/src/feature%2Fna%C3%AFve/Sources/na%C3%AFve%20file.swift",
                line: "https://bitbucket.org/acme/widgets/src/feature%2Fna%C3%AFve/Sources/na%C3%AFve%20file.swift#lines-10",
                range: "https://bitbucket.org/acme/widgets/src/feature%2Fna%C3%AFve/Sources/na%C3%AFve%20file.swift#lines-10:20",
                compare: "https://bitbucket.org/acme/widgets/branches/compare/feature%2Fna%C3%AFve..main",
                pullRequest: "https://bitbucket.org/acme/widgets/pull-requests/12",
                issue: "https://bitbucket.org/acme/widgets/issues/34"
            ),
        ]
        let file = try ForgeFilePath("Sources/naïve file.swift")
        let line = try ForgeLineSelection(line: 10)
        let range = try ForgeLineSelection(start: 10, end: 20)
        for expected in examples {
            let repository = try TestSupport.repository(kind: expected.kind)
            let destinations: [(ForgeDestination, String)] = try [
                (.repository(repository), expected.repository),
                (.branch(repository, TestSupport.feature), expected.branch),
                (.commit(repository, TestSupport.commit), expected.commit),
                (.file(repository, revision: .branch(TestSupport.feature), path: file, selection: nil), expected.file),
                (.file(repository, revision: .branch(TestSupport.feature), path: file, selection: line), expected.line),
                (.file(repository, revision: .branch(TestSupport.feature), path: file, selection: range), expected.range),
                (
                    .compare(
                        repository,
                        base: .branch(TestSupport.main),
                        head: .branch(TestSupport.feature)
                    ),
                    expected.compare
                ),
                (.pullRequest(repository, ForgeItemNumber(12)), expected.pullRequest),
                (.issue(repository, ForgeItemNumber(34)), expected.issue),
            ]
            for (destination, expectedURL) in destinations {
                XCTAssertEqual(try ForgeDestinationURLCodec.url(for: destination).absoluteString, expectedURL)
            }
        }
    }

    func testDestinationConstructionPercentEncodesEveryIdentityComponentAndPort() throws {
        let repository = try TestSupport.repository(
            host: "example.com",
            port: 8443,
            owner: "équipe/outils",
            name: "repo #1"
        )
        let destination = try ForgeDestination.file(
            repository,
            revision: .tag(ForgeRefName("v1.0")),
            path: ForgeFilePath("Doc/100%.md"),
            selection: nil
        )
        XCTAssertEqual(
            try ForgeDestinationURLCodec.url(for: destination).absoluteString,
            "https://example.com:8443/%C3%A9quipe/outils/repo%20%231/blob/v1.0/Doc/100%25.md"
        )
    }

    func testGeneratedDestinationsRoundTripForAllProvidersAndFamilies() throws {
        for kind in ForgeKind.allCases {
            let repository = try TestSupport.repository(kind: kind)
            let destinations: [ForgeDestination] = try [
                .repository(repository),
                .branch(repository, TestSupport.feature),
                .commit(repository, TestSupport.commit),
                .file(
                    repository,
                    revision: .branch(TestSupport.feature),
                    path: ForgeFilePath("Sources/File.swift"),
                    selection: ForgeLineSelection(start: 3, end: 8)
                ),
                .compare(
                    repository,
                    base: .branch(TestSupport.main),
                    head: .branch(TestSupport.feature)
                ),
                .pullRequest(repository, ForgeItemNumber(7)),
                .issue(repository, ForgeItemNumber(9)),
            ]
            for destination in destinations {
                let url = try ForgeDestinationURLCodec.url(for: destination)
                let parsed = try ForgeDestinationURLCodec.parse(url, boundTo: repository)
                XCTAssertEqual(parsed, try parsedForm(of: destination), url.absoluteString)
                XCTAssertEqual(try ForgeDestinationURLCodec.url(for: parsed), url)
            }
        }
    }

    func testAmbiguousFileAndCompareRevisionKindsParseAsOpaqueWithoutLosingText() throws {
        let repository = try TestSupport.repository()
        let revisions: [ForgeRevision] = try [
            .branch(ForgeRefName("deadbeef")),
            .tag(ForgeRefName("v1.0")),
            .commit(ForgeCommitID("abc1234")),
        ]
        for revision in revisions {
            let destination = try ForgeDestination.file(
                repository,
                revision: revision,
                path: ForgeFilePath("README.md"),
                selection: nil
            )
            let url = try ForgeDestinationURLCodec.url(for: destination)
            XCTAssertEqual(
                try ForgeDestinationURLCodec.parse(url, boundTo: repository),
                try .file(
                    repository,
                    revision: .opaque(ForgeRefName(revision.value)),
                    path: ForgeFilePath("README.md"),
                    selection: nil
                )
            )
        }

        let comparison = try ForgeDestination.compare(
            repository,
            base: .tag(ForgeRefName("v1.0")),
            head: .branch(ForgeRefName("deadbeef"))
        )
        let comparisonURL = try ForgeDestinationURLCodec.url(for: comparison)
        XCTAssertEqual(
            try ForgeDestinationURLCodec.parse(comparisonURL, boundTo: repository),
            try .compare(
                repository,
                base: .opaque(ForgeRefName("v1.0")),
                head: .opaque(ForgeRefName("deadbeef"))
            )
        )
    }

    func testParserRejectsOriginRepositoryPathFragmentAndNumberAttacks() throws {
        let repository = try TestSupport.repository()
        let cases: [(String, ForgeDestinationURLCodecError)] = [
            ("http://github.com/acme/widgets", .invalidURL),
            ("https://user@github.com/acme/widgets", .invalidURL),
            ("https://github.com/acme/widgets?x=1", .invalidURL),
            ("https://github.com.evil/acme/widgets", .originMismatch),
            ("https://github.com/acme/other", .repositoryMismatch),
            ("https://github.com/acme/widgets/unknown/path", .unsupportedDestination),
            ("https://github.com/acme/widgets#L1", .malformedFragment),
            ("https://github.com/acme/widgets/pull/0", .malformedDestination),
            ("https://github.com/acme/widgets/blob/main/File.swift#L0", .malformedFragment),
            ("https://github.com/acme/widgets/blob/main/File.swift#L9-L3", .malformedFragment),
            ("https://github.com/acme/widgets/blob/main/File.swift#other", .malformedFragment),
            ("https://github.com/acme/widgets/blob/main/dir%2Ffile.swift", .malformedDestination),
            ("https://github.com/acme/widgets/tree/../main", .malformedDestination),
        ]
        for (string, expected) in cases {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertThrowsError(try ForgeDestinationURLCodec.parse(url, boundTo: repository), string) {
                XCTAssertEqual($0 as? ForgeDestinationURLCodecError, expected, string)
            }
        }
    }

    func testMalformedComparisonsAndBitbucketFragmentsAreRejected() throws {
        let github = try TestSupport.repository()
        let bitbucket = try TestSupport.repository(kind: .bitbucket)
        for string in [
            "https://github.com/acme/widgets/compare/main...feature...extra",
            "https://github.com/acme/widgets/compare/main",
        ] {
            XCTAssertThrowsError(
                try ForgeDestinationURLCodec.parse(XCTUnwrap(URL(string: string)), boundTo: github)
            )
        }
        for string in [
            "https://bitbucket.org/acme/widgets/src/main/File.swift#lines-0",
            "https://bitbucket.org/acme/widgets/src/main/File.swift#lines-2:1",
            "https://bitbucket.org/acme/widgets/src/main/File.swift#L2",
        ] {
            XCTAssertThrowsError(
                try ForgeDestinationURLCodec.parse(XCTUnwrap(URL(string: string)), boundTo: bitbucket)
            )
        }
    }

    private func parsedForm(of destination: ForgeDestination) throws -> ForgeDestination {
        switch destination {
        case let .file(repository, revision, path, selection):
            try .file(
                repository,
                revision: .opaque(ForgeRefName(revision.value)),
                path: path,
                selection: selection
            )
        case let .compare(repository, base, head):
            try .compare(
                repository,
                base: .opaque(ForgeRefName(base.value)),
                head: .opaque(ForgeRefName(head.value))
            )
        default:
            destination
        }
    }
}
