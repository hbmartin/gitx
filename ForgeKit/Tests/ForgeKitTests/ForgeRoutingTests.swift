@testable import ForgeKit
import XCTest

final class ForgeRoutingTests: XCTestCase {
    private let router = ForgeDestinationRouter()

    func testExplicitDestinationRouteIncludesValidatedBrowserEscapeHatch() throws {
        let repository = try TestSupport.repository()
        let destination = try ForgeDestination.pullRequest(repository, ForgeItemNumber(42))
        XCTAssertEqual(
            try router.route(destination),
            try ForgeDestinationRoute(
                destination: destination,
                browserURL: XCTUnwrap(URL(string: "https://github.com/acme/widgets/pull/42"))
            )
        )
    }

    func testBoundNumberReferenceResolvesOnlyWhenItemFamilyIsUnambiguous() throws {
        let repository = try TestSupport.repository()
        XCTAssertEqual(
            router.routeNumberReference(
                " #0042 ",
                boundRepository: repository,
                availableKinds: [.pullRequest]
            ),
            try .destination(.pullRequest(repository, ForgeItemNumber(42)))
        )
        XCTAssertEqual(
            router.routeNumberReference(
                "#42",
                boundRepository: repository,
                availableKinds: [.issue]
            ),
            try .destination(.issue(repository, ForgeItemNumber(42)))
        )

        guard case let .requiresChoice(choices) = router.routeNumberReference(
            "#42",
            boundRepository: repository
        ) else {
            return XCTFail("Expected an item-family chooser")
        }
        XCTAssertEqual(choices.map(\.destination), try [
            .pullRequest(repository, ForgeItemNumber(42)),
            .issue(repository, ForgeItemNumber(42)),
        ])
        XCTAssertEqual(choices.map(\.title), [
            "acme/widgets — Pull Request #42",
            "acme/widgets — Issue #42",
        ])
    }

    func testUnboundNumberReferenceReturnsDeterministicRepositoryChoices() throws {
        let alpha = try TestSupport.repository(owner: "alpha")
        let beta = try TestSupport.repository(owner: "beta")
        guard case let .requiresChoice(choices) = router.routeNumberReference(
            "#3",
            boundRepository: nil,
            candidateRepositories: [beta, alpha, beta],
            availableKinds: [.issue]
        ) else {
            return XCTFail("Expected a repository chooser")
        }
        XCTAssertEqual(choices.map(\.destination), try [
            .issue(alpha, ForgeItemNumber(3)),
            .issue(beta, ForgeItemNumber(3)),
        ])
    }

    func testMalformedMissingBindingAndUnavailableReferencesFailStructurally() throws {
        let repository = try TestSupport.repository()
        for malformed in ["", "42", "##42", "#-1", "#0", "#12x", "# 12"] {
            XCTAssertEqual(
                router.routeNumberReference(malformed, boundRepository: repository),
                .failure(.malformedNumberReference),
                malformed
            )
        }
        XCTAssertEqual(
            router.routeNumberReference("#1", boundRepository: nil),
            .failure(.bindingRequired)
        )
        XCTAssertEqual(
            router.routeNumberReference("#1", boundRepository: repository, availableKinds: []),
            .failure(.noAvailableDestination)
        )
    }
}
