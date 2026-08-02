@testable import ForgeKit
import Foundation
import XCTest

final class ForgeAccountTests: XCTestCase {
    func testAccountOwnsExactlyOneMatchingCurrentCredentialAndRoundTrips() throws {
        let accountID = try makeAccountID(value: "account-1")
        let credential = try makeCredential(accountID: accountID)
        let account = try ForgeAccount(id: accountID, login: "octocat", currentCredential: credential)

        XCTAssertEqual(account.id, accountID)
        XCTAssertEqual(account.login, "octocat")
        XCTAssertEqual(account.currentCredential, credential)
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeAccount.self, from: JSONEncoder().encode(account)),
            account
        )
    }

    func testAccountRejectsInvalidLoginAndCredentialFromAnotherAccount() throws {
        let accountID = try makeAccountID(value: "account-1")
        let otherID = try makeAccountID(value: "account-2")
        let credential = try makeCredential(accountID: otherID)

        for login in ["", " octocat", "octocat\n"] {
            XCTAssertThrowsError(
                try ForgeAccount(id: accountID, login: login, currentCredential: credential)
            ) {
                XCTAssertEqual($0 as? ForgeAccountError, .invalidAccountLogin)
            }
        }
        XCTAssertThrowsError(
            try ForgeAccount(id: accountID, login: "octocat", currentCredential: credential)
        ) {
            XCTAssertEqual($0 as? ForgeAccountError, .mismatchedCredentialAccount)
        }
    }

    func testCredentialIdentifierAndGenerationValidateDirectAndDecodedValues() throws {
        for value in ["", " credential", "credential\n"] {
            XCTAssertThrowsError(try ForgeCredentialID(value)) {
                XCTAssertEqual($0 as? ForgeAccountError, .invalidCredentialIdentifier)
            }
        }
        XCTAssertThrowsError(try ForgeCredentialGeneration(0)) {
            XCTAssertEqual($0 as? ForgeAccountError, .invalidCredentialGeneration)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCredentialID.self, from: Data(#"""#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCredentialGeneration.self, from: Data("0".utf8)))

        let identifier = try ForgeCredentialID("credential-1")
        let generation = try ForgeCredentialGeneration(7)
        XCTAssertEqual(try JSONDecoder().decode(ForgeCredentialID.self, from: JSONEncoder().encode(identifier)), identifier)
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeCredentialGeneration.self, from: JSONEncoder().encode(generation)),
            generation
        )
        XCTAssertLessThan(try ForgeCredentialGeneration(1), generation)
    }

    func testTokenRefreshChangesExpiryWithoutChangingLogicalCredential() throws {
        let accountID = try makeAccountID(value: "account-1")
        let original = try makeCredential(
            accountID: accountID,
            source: .forgeApplicationDeviceFlow,
            expiresAt: Date(timeIntervalSince1970: 100)
        )
        let refreshed = original.refreshed(expiresAt: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(refreshed.reference, original.reference)
        XCTAssertEqual(refreshed.source, original.source)
        XCTAssertEqual(refreshed.expiresAt, Date(timeIntervalSince1970: 200))
    }

    func testCredentialSourcesKeepAcquisitionChoicesDistinct() {
        let sources: Set<ForgeCredentialSource> = [
            .forgeApplicationDeviceFlow,
            .commandLineBroker,
            .fineGrainedPersonalAccessToken,
            .classicPersonalAccessToken,
        ]
        XCTAssertEqual(sources.count, 4)
    }

    func testAccountErrorsHaveSafeDescriptions() {
        XCTAssertEqual(ForgeAccountError.invalidCredentialIdentifier.errorDescription, "The Credential identifier is invalid.")
        XCTAssertEqual(ForgeAccountError.invalidCredentialGeneration.errorDescription, "The Credential generation is invalid.")
        XCTAssertEqual(ForgeAccountError.invalidAccountLogin.errorDescription, "The Forge Account login is invalid.")
        XCTAssertEqual(
            ForgeAccountError.mismatchedCredentialAccount.errorDescription,
            "The Credential belongs to a different Forge Account."
        )
    }

    private func makeAccountID(value: String) throws -> ForgeAccountID {
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        return try ForgeAccountID(forge: forge, value: value)
    }

    private func makeCredential(
        accountID: ForgeAccountID,
        source: ForgeCredentialSource = .classicPersonalAccessToken,
        expiresAt: Date? = nil
    ) throws -> ForgeCredentialMetadata {
        try ForgeCredentialMetadata(
            reference: ForgeCredentialReference(
                accountID: accountID,
                credentialID: ForgeCredentialID("credential-1"),
                generation: ForgeCredentialGeneration(1)
            ),
            source: source,
            expiresAt: expiresAt
        )
    }
}
