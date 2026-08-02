@testable import ForgeKit
import XCTest

final class ForgeBindingTests: XCTestCase {
    func testUniqueHighConfidenceCandidateCreatesInitialBinding() throws {
        let repository = try TestSupport.repository()
        let candidate = try ForgeRepositoryCandidate(
            remoteName: "origin",
            repository: repository,
            confidence: .high,
            relationship: .direct
        )
        XCTAssertEqual(
            PrimaryForgeRepositorySelector.select(existingBinding: nil, candidates: [candidate]),
            try .automatic(ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: repository))
        )
    }

    func testExistingBindingNeverChangesWithSelectedOrNewRemoteCandidates() throws {
        let primary = try TestSupport.repository(owner: "person")
        let parent = try TestSupport.repository(owner: "organization")
        let account = try ForgeAccountID(forge: primary.forge, value: "viewer")
        let existing = try ForgeRepositoryBinding(
            localRemoteName: "my-fork",
            primaryRepository: primary,
            preferredAccount: account
        )
        let candidates = try [
            ForgeRepositoryCandidate(
                remoteName: "selected",
                repository: parent,
                confidence: .high,
                relationship: .parent
            ),
            ForgeRepositoryCandidate(
                remoteName: "upstream",
                repository: parent,
                confidence: .high,
                relationship: .upstream
            ),
        ]
        XCTAssertEqual(
            PrimaryForgeRepositorySelector.select(existingBinding: existing, candidates: candidates),
            .existing(existing)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeRepositoryBinding.self, from: JSONEncoder().encode(existing)),
            existing
        )
    }

    func testAmbiguousForkParentAndMediumConfidenceCandidatesRequireChoice() throws {
        let fork = try TestSupport.repository(owner: "person")
        let parent = try TestSupport.repository(owner: "organization")
        let candidates = try [
            ForgeRepositoryCandidate(
                remoteName: "origin",
                repository: fork,
                confidence: .high,
                relationship: .fork
            ),
            ForgeRepositoryCandidate(
                remoteName: "upstream",
                repository: parent,
                confidence: .high,
                relationship: .parent
            ),
        ]
        guard case let .requiresChoice(choices) = PrimaryForgeRepositorySelector.select(
            existingBinding: nil,
            candidates: candidates
        ) else {
            return XCTFail("Expected an explicit primary repository choice")
        }
        XCTAssertEqual(Set(choices), Set(candidates))

        let medium = try ForgeRepositoryCandidate(
            remoteName: "origin",
            repository: fork,
            confidence: .medium
        )
        XCTAssertEqual(
            PrimaryForgeRepositorySelector.select(existingBinding: nil, candidates: [medium]),
            .requiresChoice([medium])
        )
    }

    func testOriginAndUpstreamNamesAreHintsNotAuthorityAndDuplicatesCollapse() throws {
        let repository = try TestSupport.repository()
        let origin = try ForgeRepositoryCandidate(
            remoteName: "origin",
            repository: repository,
            confidence: .high
        )
        let upstream = try ForgeRepositoryCandidate(
            remoteName: "upstream",
            repository: repository,
            confidence: .high
        )
        let lowConfidenceOrigin = try ForgeRepositoryCandidate(
            remoteName: "origin",
            repository: repository,
            confidence: .low
        )
        guard case let .requiresChoice(choices) = PrimaryForgeRepositorySelector.select(
            existingBinding: nil,
            candidates: [lowConfidenceOrigin, upstream, origin, origin]
        ) else {
            return XCTFail("Expected a remote choice")
        }
        XCTAssertEqual(choices.map(\.remoteName), ["origin", "upstream"])
        XCTAssertEqual(
            PrimaryForgeRepositorySelector.select(existingBinding: nil, candidates: []),
            .unavailable
        )
    }

    func testBindingRejectsInvalidRemoteAndCrossForgeAccount() throws {
        let github = try TestSupport.repository()
        let gitlab = try TestSupport.repository(kind: .gitLab)
        XCTAssertThrowsError(try ForgeRepositoryBinding(localRemoteName: " ", primaryRepository: github))
        XCTAssertThrowsError(
            try ForgeRepositoryCandidate(remoteName: "", repository: github, confidence: .high)
        )
        let wrongAccount = try ForgeAccountID(forge: gitlab.forge, value: "viewer")
        XCTAssertThrowsError(
            try ForgeRepositoryBinding(
                localRemoteName: "origin",
                primaryRepository: github,
                preferredAccount: wrongAccount
            )
        ) {
            XCTAssertEqual($0 as? ForgeIdentityError, .mismatchedForge)
        }
    }
}
