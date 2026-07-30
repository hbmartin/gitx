@testable import ForgeKit
import XCTest

final class ForgeDeepLinkTests: XCTestCase {
    func testEveryDestinationUsesReadOnlyCheckedInGrammarAndRoundTrips() throws {
        let fixture = try Fixture()
        let destinations: [ForgeDestination] = try [
            .repository(fixture.repository),
            .branch(fixture.repository, ForgeRefName("feature/native-links")),
            .commit(fixture.repository, fixture.commit),
            .file(
                fixture.repository,
                revision: .branch(ForgeRefName("feature/native-links")),
                path: ForgeFilePath("Sources/Native File.swift"),
                selection: nil
            ),
            .file(
                fixture.repository,
                revision: .commit(fixture.commit),
                path: ForgeFilePath("Sources/Native File.swift"),
                selection: ForgeLineSelection(start: 7, end: 11)
            ),
            .compare(
                fixture.repository,
                base: .branch(ForgeRefName("main")),
                head: .branch(ForgeRefName("feature/native-links"))
            ),
            .pullRequest(fixture.repository, ForgeItemNumber(42)),
            .issue(fixture.repository, ForgeItemNumber(81)),
        ]

        for destination in destinations {
            let url = try ForgeDeepLinkCodec.url(for: destination)
            XCTAssertEqual(url.scheme, "x-gitx")
            XCTAssertEqual(url.host, "github.com")
            XCTAssertNil(url.query)
            XCTAssertNil(url.fragment)
            let parsed = try ForgeDeepLinkCodec.parse(url, knownRepositories: [fixture.repository])
            XCTAssertEqual(parsed.repository, destination.repository)
            XCTAssertEqual(parsed.kind, destination.kind)
            XCTAssertEqual(try ForgeDeepLinkCodec.url(for: parsed), url)
        }
    }

    func testCodecPreservesCustomOriginPortAndNestedOwner() throws {
        let forge = try ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "forge.example", port: 8443))
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "group/subgroup", name: "project")
        let destination = try ForgeDestination.issue(repository, ForgeItemNumber(9))
        let url = try ForgeDeepLinkCodec.url(for: destination)
        XCTAssertEqual(url.absoluteString, "x-gitx://forge.example:8443/group/subgroup/project/issue/9")
        XCTAssertEqual(try ForgeDeepLinkCodec.parse(url, knownRepositories: [repository]), destination)
    }

    func testCodecRejectsSchemesCredentialsAuthoritiesQueriesAndFragments() throws {
        let fixture = try Fixture()
        let cases: [(String, ForgeDeepLinkError)] = [
            ("https://github.com/gitx/gitx/repository", .unsupportedScheme),
            ("x-gitx://user:secret@github.com/gitx/gitx/repository", .credentialsNotAllowed),
            ("x-gitx:/gitx/gitx/repository", .malformedAuthority),
            ("x-gitx://github.com/gitx/gitx/repository?token=secret", .queryOrFragmentNotAllowed),
            ("x-gitx://github.com/gitx/gitx/repository#fragment", .queryOrFragmentNotAllowed),
        ]
        for (rawURL, expected) in cases {
            XCTAssertThrowsError(try ForgeDeepLinkCodec.parse(
                XCTUnwrap(URL(string: rawURL)),
                knownRepositories: [fixture.repository]
            )) {
                XCTAssertEqual($0 as? ForgeDeepLinkError, expected)
            }
        }
    }

    func testCodecRejectsUnknownAndAmbiguousRepositoryBoundaries() throws {
        let fixture = try Fixture()
        let unknown = try XCTUnwrap(URL(string: "x-gitx://github.com/other/repo/repository"))
        XCTAssertThrowsError(try ForgeDeepLinkCodec.parse(unknown, knownRepositories: [fixture.repository])) {
            XCTAssertEqual($0 as? ForgeDeepLinkError, .unknownRepository)
        }

        let nested = try ForgeRepositoryIdentity(
            forge: fixture.repository.forge,
            owner: "gitx/gitx",
            name: "repository"
        )
        let ambiguous = try XCTUnwrap(URL(string: "x-gitx://github.com/gitx/gitx/repository/issue/1"))
        XCTAssertThrowsError(try ForgeDeepLinkCodec.parse(
            ambiguous,
            knownRepositories: [fixture.repository, nested]
        )) {
            XCTAssertEqual($0 as? ForgeDeepLinkError, .ambiguousRepository)
        }
    }

    func testCodecRejectsMutationAuthenticationAndUnknownRouteFamilies() throws {
        let fixture = try Fixture()
        for family in ["auth", "oauth", "callback", "mutate", "mutation", "delete", "merge"] {
            let url = try XCTUnwrap(URL(string: "x-gitx://github.com/gitx/gitx/\(family)/1"))
            XCTAssertThrowsError(try ForgeDeepLinkCodec.parse(url, knownRepositories: [fixture.repository])) {
                XCTAssertEqual($0 as? ForgeDeepLinkError, .unsupportedRoute)
            }
        }
    }

    func testCodecRejectsMalformedRouteShapesAndValues() throws {
        let fixture = try Fixture()
        let routes = [
            "",
            "repository/extra",
            "branch",
            "branch/-bad",
            "commit/not-a-sha",
            "file/main/not-lines/0/0/File.swift",
            "file/main/lines/not-a-number/1/File.swift",
            "file/main/lines/2/1/File.swift",
            "file/main/lines/0/1/File.swift",
            "file/main/lines/0/0",
            "compare/main",
            "compare/main/-bad",
            "pull-request",
            "pull-request/0",
            "pull-request/nope",
            "issue/1/extra",
            "issue/-1",
            "../repository",
            "%00/repository",
            "repository/",
        ]
        for route in routes {
            let url = try XCTUnwrap(URL(string: "x-gitx://github.com/gitx/gitx/\(route)"))
            XCTAssertThrowsError(try ForgeDeepLinkCodec.parse(url, knownRepositories: [fixture.repository]), route) {
                XCTAssertEqual($0 as? ForgeDeepLinkError, .malformedRoute, route)
            }
        }
    }

    func testOpenCheckoutValidatesAndRoundTrips() throws {
        let fixture = try Fixture()
        let checkout = try ForgeOpenCheckout(
            identifier: "window-1",
            repository: fixture.repository,
            frontmostRank: 0,
            availableCommits: [fixture.commit]
        )
        XCTAssertEqual(try roundTrip(checkout), checkout)
        XCTAssertThrowsError(try ForgeOpenCheckout(
            identifier: " ",
            repository: fixture.repository,
            frontmostRank: 0
        ))
        XCTAssertThrowsError(try ForgeOpenCheckout(
            identifier: "window",
            repository: fixture.repository,
            frontmostRank: -1
        ))
    }

    func testRouterUsesSoleMatchingCheckoutAndNeverRequiresGitObjectForRepositoryItems() throws {
        let fixture = try Fixture()
        let checkout = try ForgeOpenCheckout(
            identifier: "window",
            repository: fixture.repository,
            frontmostRank: 0
        )
        for destination in try [
            ForgeDestination.repository(fixture.repository),
            .branch(fixture.repository, ForgeRefName("main")),
            .file(
                fixture.repository,
                revision: .branch(ForgeRefName("main")),
                path: ForgeFilePath("README.md"),
                selection: nil
            ),
            .compare(
                fixture.repository,
                base: .branch(ForgeRefName("main")),
                head: .branch(ForgeRefName("feature"))
            ),
            .pullRequest(fixture.repository, ForgeItemNumber(1)),
            .issue(fixture.repository, ForgeItemNumber(2)),
        ] {
            XCTAssertEqual(
                ForgeDeepLinkRouter.route(destination, openCheckouts: [checkout]),
                .open(checkoutIdentifier: "window", destination: destination)
            )
        }
    }

    func testRouterChoosesAmongMatchingCheckoutsInFrontmostStableOrder() throws {
        let fixture = try Fixture()
        let destination = try ForgeDestination.pullRequest(fixture.repository, ForgeItemNumber(42))
        let windows = try [
            ForgeOpenCheckout(identifier: "z-window", repository: fixture.repository, frontmostRank: 1),
            ForgeOpenCheckout(identifier: "b-window", repository: fixture.repository, frontmostRank: 0),
            ForgeOpenCheckout(identifier: "a-window", repository: fixture.repository, frontmostRank: 0),
            ForgeOpenCheckout(identifier: "other", repository: fixture.otherRepository, frontmostRank: 0),
        ]
        XCTAssertEqual(
            ForgeDeepLinkRouter.route(destination, openCheckouts: windows),
            .chooseCheckout(
                checkoutIdentifiers: ["a-window", "b-window", "z-window"],
                destination: destination
            )
        )
    }

    func testRouterOffersOnlyFetchAndBrowserForMissingCommitWithoutAutomaticWork() throws {
        let fixture = try Fixture()
        let checkout = try ForgeOpenCheckout(
            identifier: "window",
            repository: fixture.repository,
            frontmostRank: 0
        )
        let commit = ForgeDestination.commit(fixture.repository, fixture.commit)
        XCTAssertEqual(
            ForgeDeepLinkRouter.route(commit, openCheckouts: [checkout]),
            .missingLocalObject(
                checkoutIdentifier: "window",
                destination: commit,
                actions: [.fetch, .openInBrowser]
            )
        )

        let file = try ForgeDestination.file(
            fixture.repository,
            revision: .commit(fixture.commit),
            path: ForgeFilePath("README.md"),
            selection: nil
        )
        XCTAssertEqual(
            ForgeDeepLinkRouter.route(file, openCheckouts: [checkout]),
            .missingLocalObject(
                checkoutIdentifier: "window",
                destination: file,
                actions: [.fetch, .openInBrowser]
            )
        )

        let available = try ForgeOpenCheckout(
            identifier: "window",
            repository: fixture.repository,
            frontmostRank: 0,
            availableCommits: [fixture.commit]
        )
        XCTAssertEqual(
            ForgeDeepLinkRouter.route(commit, openCheckouts: [available]),
            .open(checkoutIdentifier: "window", destination: commit)
        )
    }

    func testRouterReportsNoMatchingCheckoutWithoutCloning() throws {
        let fixture = try Fixture()
        let destination = try ForgeDestination.issue(fixture.repository, ForgeItemNumber(4))
        let unrelated = try ForgeOpenCheckout(
            identifier: "other",
            repository: fixture.otherRepository,
            frontmostRank: 0
        )
        XCTAssertEqual(
            ForgeDeepLinkRouter.route(destination, openCheckouts: [unrelated]),
            .noMatchingCheckout(destination: destination)
        )
    }

    func testErrorsHaveStableDescriptionsAndActionsAreExact() {
        let errors: [ForgeDeepLinkError] = [
            .invalidURL, .unsupportedScheme, .credentialsNotAllowed, .malformedAuthority,
            .queryOrFragmentNotAllowed, .unknownRepository, .ambiguousRepository,
            .unsupportedRoute, .malformedRoute,
        ]
        XCTAssertTrue(errors.allSatisfy { !($0.errorDescription ?? "").isEmpty })
        XCTAssertEqual(Set(ForgeDeepLinkMissingObjectAction.allCases), [.fetch, .openInBrowser])
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}

private struct Fixture {
    let repository: ForgeRepositoryIdentity
    let otherRepository: ForgeRepositoryIdentity
    let commit = try! ForgeCommitID(String(repeating: "a", count: 40))

    init() throws {
        let github = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        repository = try ForgeRepositoryIdentity(forge: github, owner: "gitx", name: "gitx")
        otherRepository = try ForgeRepositoryIdentity(forge: github, owner: "other", name: "gitx")
    }
}
