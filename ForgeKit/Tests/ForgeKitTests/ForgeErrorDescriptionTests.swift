@testable import ForgeKit
import XCTest

final class ForgeErrorDescriptionTests: XCTestCase {
    func testIdentityErrorsHaveActionableDescriptions() {
        let cases: [(ForgeIdentityError, String)] = [
            (.httpsRequired, "A Forge origin must use HTTPS."),
            (.credentialsNotAllowed, "A Forge origin cannot contain credentials."),
            (.invalidHost, "The Forge host is invalid."),
            (.invalidPort, "The Forge port is invalid."),
            (.originContainsPath, "A Forge origin cannot contain a path."),
            (.originContainsQueryOrFragment, "A Forge origin cannot contain a query or fragment."),
            (.invalidOwner, "The Forge repository owner is invalid."),
            (.invalidRepositoryName, "The Forge repository name is invalid."),
            (.mismatchedForge, "The account and repository belong to different Forges."),
            (.invalidAccountIdentifier, "The Forge Account identifier is invalid."),
        ]
        for (error, description) in cases {
            XCTAssertEqual(error.errorDescription, description)
        }
    }

    func testDestinationErrorsHaveActionableDescriptions() {
        let validationCases: [(ForgeDestinationValidationError, String)] = [
            (.invalidReference, "The Forge reference is invalid."),
            (.invalidCommitID, "The Forge commit identifier is invalid."),
            (.invalidFilePath, "The Forge file path is invalid."),
            (.invalidLine, "The Forge line number is invalid."),
            (.invalidLineRange, "The Forge line range is invalid."),
            (.invalidItemNumber, "The Pull Request or Issue number is invalid."),
        ]
        for (error, description) in validationCases {
            XCTAssertEqual(error.errorDescription, description)
        }

        let codecCases: [(ForgeDestinationURLCodecError, String)] = [
            (.invalidURL, "The Forge destination URL is invalid."),
            (.originMismatch, "The Forge destination has a different origin."),
            (.repositoryMismatch, "The Forge destination belongs to another repository."),
            (.unsupportedDestination, "The Forge destination is unsupported."),
            (.malformedDestination, "The Forge destination path is malformed."),
            (.malformedFragment, "The Forge destination line fragment is malformed."),
        ]
        for (error, description) in codecCases {
            XCTAssertEqual(error.errorDescription, description)
        }
    }

    func testBindingAndRoutingErrorsHaveActionableDescriptions() {
        XCTAssertEqual(ForgeBindingError.invalidRemoteName.errorDescription, "The Git remote name is invalid.")
        XCTAssertLessThan(ForgeCandidateConfidence.low, .medium)
        XCTAssertLessThan(ForgeCandidateConfidence.medium, .high)

        let routingCases: [(ForgeRoutingError, String)] = [
            (.malformedNumberReference, "The Pull Request or Issue reference is malformed."),
            (.bindingRequired, "Choose a Primary Forge Repository before opening this reference."),
            (.noAvailableDestination, "No Pull Request or Issue destination is available."),
        ]
        for (error, description) in routingCases {
            XCTAssertEqual(error.errorDescription, description)
        }
    }

    func testRemoteAndWebPolicyErrorsHaveActionableDescriptions() {
        let remoteCases: [(ForgeRemoteParseError, String)] = [
            (.empty, "The Git remote URL is empty."),
            (.unsupportedScheme("http"), "The Git remote scheme http is unsupported."),
            (.malformedURL, "The Git remote URL is malformed."),
            (.credentialsNotAllowed, "HTTPS Git remote URLs cannot contain credentials."),
            (.missingHost, "The Git remote URL has no host."),
            (.missingRepository, "The Git remote URL has no repository path."),
            (.malformedPath, "The Git remote repository path is malformed."),
            (.queryOrFragmentNotAllowed, "The Git remote URL cannot contain a query or fragment."),
            (.unsafePathComponent, "The Git remote URL contains an unsafe path component."),
        ]
        for (error, description) in remoteCases {
            XCTAssertEqual(error.errorDescription, description)
        }

        let webCases: [(ForgeWebURLPolicyError, String)] = [
            (.invalidTemplate, "The custom Forge web URL template is invalid."),
            (.httpsRequired, "The custom Forge web URL must use HTTPS."),
            (.credentialsNotAllowed, "The custom Forge web URL cannot contain credentials."),
            (.hostMismatch, "The custom Forge web URL host does not match the Git remote."),
        ]
        for (error, description) in webCases {
            XCTAssertEqual(error.errorDescription, description)
        }
    }
}
