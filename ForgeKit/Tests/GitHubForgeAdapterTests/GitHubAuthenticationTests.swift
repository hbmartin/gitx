import ForgeKit
@testable import GitHubForgeAdapter
import XCTest

final class GitHubAuthenticationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)

    func testAuthenticationErrorsHaveSafeDescriptions() {
        let errors: [GitHubAuthenticationError] = [
            .invalidClientIdentifier,
            .invalidApplicationSlug,
            .invalidSecret,
            .invalidPersonalAccessTokenLabel,
            .invalidPersonalAccessTokenExpiry,
            .invalidDeviceAuthorization,
            .invalidTokenResponse,
            .unsupportedTokenType,
            .mismatchedCredentialAuthority,
            .authorizationDenied,
            .deviceCodeExpired,
            .serverRejectedAuthorization,
            .nonGitHubIdentity,
        ]
        XCTAssertTrue(errors.allSatisfy { $0.errorDescription?.contains("super-secret") == false })
    }

    func testSecretRejectsEmptyWhitespaceAndControlBytesAndProvidesExplicitByteAccess() throws {
        for invalid in ["", " ", "abc\n", "abc\u{7F}"] {
            XCTAssertThrowsError(try GitHubSecret(invalid)) {
                XCTAssertEqual($0 as? GitHubAuthenticationError, .invalidSecret)
            }
        }
        let secret = try GitHubSecret("ghu_super-secret")
        let duplicate = try GitHubSecret("ghu_super-secret")
        XCTAssertEqual(secret, duplicate)
        let recovered = secret.withUnsafeUTF8Bytes { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(recovered, "ghu_super-secret")
        assertRedacted(secret, forbidden: ["ghu_super-secret", "super-secret"])
    }

    func testSecretAcceptsValidatedDataWithoutStringBridgeAndRejectsMalformedBytes() throws {
        let bytes = Data("github_pat_byte-secret".utf8)
        let secret = try GitHubSecret(utf8Bytes: bytes)
        XCTAssertEqual(secret.withUnsafeUTF8Bytes { Data($0) }, bytes)
        assertRedacted(secret, forbidden: ["github_pat_byte-secret", "byte-secret"])

        for invalid in [Data(), Data("space separated".utf8), Data([0x7F]), Data([0xFF])] {
            XCTAssertThrowsError(try GitHubSecret(utf8Bytes: invalid)) {
                XCTAssertEqual($0 as? GitHubAuthenticationError, .invalidSecret)
            }
        }
    }

    func testDeviceConfigurationAcceptsOnlyOpaqueClientIDAndGitHubAppSlug() throws {
        let configuration = try configuration()
        XCTAssertEqual(configuration.clientID, "Iv1ABC123")
        XCTAssertEqual(configuration.applicationSlug, "gitx-forge")
        XCTAssertEqual(configuration.newInstallationURL.absoluteString, "https://github.com/apps/gitx-forge/installations/new")
        XCTAssertEqual(
            GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL.absoluteString,
            "https://github.com/login/device/code"
        )
        XCTAssertEqual(
            GitHubAppDeviceFlowConfiguration.tokenURL.absoluteString,
            "https://github.com/login/oauth/access_token"
        )

        for invalid in ["", "abc-123", "abc 123", "abc\n"] {
            XCTAssertThrowsError(try GitHubAppDeviceFlowConfiguration(clientID: invalid, applicationSlug: "gitx"))
        }
        for invalid in ["", "-gitx", "gitx-", "GitX", "git_x", "git x"] {
            XCTAssertThrowsError(try GitHubAppDeviceFlowConfiguration(clientID: "ABC123", applicationSlug: invalid))
        }
    }

    func testOAuthRequestsUseExactGitHubEndpointsGrantTypesAndJSONAcceptHeader() throws {
        let configuration = try configuration()
        let secret = try GitHubSecret("token/+value")
        let device = GitHubOAuthRequestFactory.deviceAuthorization(configuration: configuration)
        let poll = GitHubOAuthRequestFactory.poll(configuration: configuration, deviceCode: secret)
        let refresh = GitHubOAuthRequestFactory.refresh(configuration: configuration, refreshToken: secret)

        XCTAssertEqual(form(device), "client_id=Iv1ABC123")
        XCTAssertEqual(
            form(poll),
            "client_id=Iv1ABC123&device_code=token%2F%2Bvalue&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
        )
        XCTAssertEqual(
            form(refresh),
            "client_id=Iv1ABC123&grant_type=refresh_token&refresh_token=token%2F%2Bvalue"
        )
        for oauthRequest in [device, poll, refresh] {
            let request = oauthRequest.makeURLRequest()
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            XCTAssertFalse(String(describing: oauthRequest).contains("token/+value"))
            XCTAssertFalse(String(reflecting: oauthRequest).contains("token/+value"))
            XCTAssertTrue(oauthRequest.customMirror.children.isEmpty)
        }
        XCTAssertEqual(
            try GitHubOAuthRequest(endpoint: XCTUnwrap(URL(string: "mailto:help@example.com")), form: []).description,
            "POST github.comhelp@example.com (body redacted)"
        )
    }

    func testDeviceAuthorizationParsesExactSafeGitHubVerificationURLAndTiming() throws {
        let authorization = try GitHubDeviceAuthorizationParser.parse(
            json([
                "device_code": "device-secret",
                "user_code": "ABCD-EFGH",
                "verification_uri": "https://github.com/login/device",
                "expires_in": 900,
                "interval": 5,
            ]),
            receivedAt: now
        )
        XCTAssertEqual(authorization.userCode, "ABCD-EFGH")
        XCTAssertEqual(authorization.verificationURL.absoluteString, "https://github.com/login/device")
        XCTAssertEqual(authorization.issuedAt, now)
        XCTAssertEqual(authorization.expiresAt, now.addingTimeInterval(900))
        XCTAssertEqual(authorization.pollingInterval, 5)
        assertRedacted(authorization, forbidden: ["device-secret"])
    }

    func testDeviceAuthorizationFailsClosedForMalformedPayloadsAndUnsafeURLs() {
        let invalidPayloads: [[String: Any]] = [
            [:],
            ["device_code": "", "user_code": "A", "verification_uri": "https://github.com/login/device", "expires_in": 1, "interval": 1],
            ["device_code": "secret", "user_code": "", "verification_uri": "https://github.com/login/device", "expires_in": 1, "interval": 1],
            ["device_code": "secret", "user_code": "A\n", "verification_uri": "https://github.com/login/device", "expires_in": 1, "interval": 1],
            ["device_code": "secret", "user_code": "A", "verification_uri": "http://github.com/login/device", "expires_in": 1, "interval": 1],
            ["device_code": "secret", "user_code": "A", "verification_uri": "https://github.com.evil/login/device", "expires_in": 1, "interval": 1],
            ["device_code": "secret", "user_code": "A", "verification_uri": "https://user@github.com/login/device", "expires_in": 1, "interval": 1],
            ["device_code": "secret", "user_code": "A", "verification_uri": "https://github.com:444/login/device", "expires_in": 1, "interval": 1],
            ["device_code": "secret", "user_code": "A", "verification_uri": "https://github.com/login/other", "expires_in": 1, "interval": 1],
            ["device_code": "secret", "user_code": "A", "verification_uri": "https://github.com/login/device?q=1", "expires_in": 1, "interval": 1],
            ["device_code": "secret", "user_code": "A", "verification_uri": "https://github.com/login/device#x", "expires_in": 1, "interval": 1],
            ["device_code": "secret", "user_code": "A", "verification_uri": "https://github.com/login/device", "expires_in": 0, "interval": 1],
            ["device_code": "secret", "user_code": "A", "verification_uri": "https://github.com/login/device", "expires_in": 1, "interval": 0],
            ["device_code": "secret", "user_code": "A", "verification_uri": "https://github.com/login/device", "expires_in": 1, "interval": 1],
        ]
        for payload in invalidPayloads {
            XCTAssertThrowsError(try GitHubDeviceAuthorizationParser.parse(json(payload), receivedAt: now)) {
                XCTAssertEqual($0 as? GitHubAuthenticationError, .invalidDeviceAuthorization)
            }
        }
    }

    func testDeviceAuthorizationRejectsNonfiniteAndOverflowingClockArithmetic() {
        let valid = json([
            "device_code": "secret",
            "user_code": "A",
            "verification_uri": "https://github.com/login/device",
            "expires_in": 10,
            "interval": 1,
        ])
        XCTAssertThrowsError(
            try GitHubDeviceAuthorizationParser.parse(
                valid,
                receivedAt: Date(timeIntervalSinceReferenceDate: .nan)
            )
        )
        XCTAssertThrowsError(
            try GitHubDeviceAuthorizationParser.parse(
                json([
                    "device_code": "secret",
                    "user_code": "A",
                    "verification_uri": "https://github.com/login/device",
                    "expires_in": Double.greatestFiniteMagnitude,
                    "interval": 1,
                ]),
                receivedAt: Date(timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude)
            )
        )
    }

    func testTokenParserRequiresExpiringBearerAndRotatingRefreshToken() throws {
        let credential = try GitHubOAuthTokenResponseParser.parse(successTokenJSON(), receivedAt: now)
        XCTAssertEqual(credential.accessTokenExpiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(credential.refreshTokenExpiresAt, now.addingTimeInterval(86400))
        XCTAssertEqual(credential.forgeExpiryMetadata, credential.accessTokenExpiresAt)
        XCTAssertFalse(credential.isAccessTokenExpired(at: now.addingTimeInterval(3599)))
        XCTAssertTrue(credential.isAccessTokenExpired(at: now.addingTimeInterval(3600)))
        XCTAssertTrue(credential.canRefresh(at: now.addingTimeInterval(86399)))
        XCTAssertFalse(credential.canRefresh(at: now.addingTimeInterval(86400)))
        assertRedacted(credential, forbidden: ["access-secret", "rotated-refresh-secret"])
    }

    func testRefreshResponseReplacesBothSecretsWithoutRetainingPriorMaterial() throws {
        let original = try GitHubOAuthTokenResponseParser.parse(
            successTokenJSON(access: "old-access", refresh: "old-refresh"),
            receivedAt: now
        )
        let rotated = try GitHubOAuthTokenResponseParser.parse(
            successTokenJSON(access: "new-access", refresh: "new-refresh"),
            receivedAt: now.addingTimeInterval(100)
        )
        XCTAssertNotEqual(original, rotated)
        assertRedacted(rotated, forbidden: ["old-access", "old-refresh", "new-access", "new-refresh"])
    }

    func testTokenParserReturnsOnlySafeErrorsForFailureAndMalformedResponses() {
        XCTAssertThrowsError(try GitHubOAuthTokenResponseParser.parse(Data("not-json".utf8), receivedAt: now)) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .invalidTokenResponse)
        }
        XCTAssertThrowsError(
            try GitHubOAuthTokenResponseParser.parse(json(["error": "access_denied", "error_description": "access-secret"]), receivedAt: now)
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .serverRejectedAuthorization)
            XCTAssertFalse($0.localizedDescription.contains("access-secret"))
        }
        XCTAssertThrowsError(
            try GitHubOAuthTokenResponseParser.parse(
                json(["access_token": "secret", "refresh_token": "refresh", "expires_in": 1, "refresh_token_expires_in": 1, "token_type": "mac"]),
                receivedAt: now
            )
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .unsupportedTokenType)
        }
        let invalid: [[String: Any]] = [
            ["refresh_token": "refresh", "expires_in": 1, "refresh_token_expires_in": 1, "token_type": "bearer"],
            ["access_token": "access", "expires_in": 1, "refresh_token_expires_in": 1, "token_type": "bearer"],
            ["access_token": "access", "refresh_token": "refresh", "expires_in": 0, "refresh_token_expires_in": 1, "token_type": "bearer"],
            ["access_token": "access", "refresh_token": "refresh", "expires_in": 1, "refresh_token_expires_in": 0, "token_type": "bearer"],
        ]
        for payload in invalid {
            XCTAssertThrowsError(try GitHubOAuthTokenResponseParser.parse(json(payload), receivedAt: now)) {
                XCTAssertEqual($0 as? GitHubAuthenticationError, .invalidTokenResponse)
            }
        }
        XCTAssertThrowsError(
            try GitHubOAuthTokenResponseParser.parse(
                successTokenJSON(),
                receivedAt: Date(timeIntervalSinceReferenceDate: .infinity)
            )
        )
        XCTAssertThrowsError(
            try GitHubOAuthTokenResponseParser.parse(
                json([
                    "access_token": "access",
                    "refresh_token": "refresh",
                    "expires_in": Double.greatestFiniteMagnitude,
                    "refresh_token_expires_in": 1,
                    "token_type": "bearer",
                ]),
                receivedAt: Date(timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude)
            )
        )
    }

    func testDevicePollerHandlesPendingSlowDownExpirationDenialAndAuthorization() throws {
        let authorization = try makeAuthorization()
        var poller = GitHubDeviceFlowPoller(authorization: authorization)
        XCTAssertEqual(poller.pollingInterval, 5)
        XCTAssertEqual(poller.status, .active(nextPollAt: now.addingTimeInterval(5)))
        XCTAssertEqual(
            try poller.consume(json(["error": "authorization_pending"]), receivedAt: now),
            .notYetPollable(nextPollAt: now.addingTimeInterval(5))
        )
        XCTAssertEqual(
            try poller.consume(json(["error": "authorization_pending"]), receivedAt: now.addingTimeInterval(5)),
            .pending(nextPollAt: now.addingTimeInterval(10))
        )
        XCTAssertEqual(
            try poller.consume(json(["error": "slow_down"]), receivedAt: now.addingTimeInterval(10)),
            .slowedDown(nextPollAt: now.addingTimeInterval(20))
        )
        XCTAssertEqual(poller.pollingInterval, 10)
        XCTAssertEqual(
            try poller.consume(json(["error": "access_denied"]), receivedAt: now.addingTimeInterval(11)),
            .notYetPollable(nextPollAt: now.addingTimeInterval(20))
        )

        let authorized = try poller.consume(successTokenJSON(), receivedAt: now.addingTimeInterval(20))
        guard case let .authorized(credential) = authorized else { return XCTFail("Expected authorization") }
        XCTAssertEqual(credential.accessTokenExpiresAt, now.addingTimeInterval(3620))
        XCTAssertEqual(poller.status, .terminal(.authorized))
        XCTAssertEqual(
            try poller.consume(json(["error": "access_denied"]), receivedAt: now.addingTimeInterval(21)),
            .terminal(.authorized)
        )
    }

    func testDevicePollerFailsClosedForExpiredMalformedAndUnknownServerStates() throws {
        var poller = try GitHubDeviceFlowPoller(authorization: makeAuthorization())
        XCTAssertEqual(
            try poller.consume(successTokenJSON(), receivedAt: now.addingTimeInterval(900)),
            .expired
        )
        XCTAssertEqual(
            try poller.consume(Data("invalid".utf8), receivedAt: now),
            .terminal(.expired)
        )

        var malformed = try GitHubDeviceFlowPoller(authorization: makeAuthorization())
        XCTAssertEqual(
            try malformed.consume(Data("invalid".utf8), receivedAt: now),
            .notYetPollable(nextPollAt: now.addingTimeInterval(5))
        )
        XCTAssertThrowsError(try malformed.consume(Data("invalid".utf8), receivedAt: now.addingTimeInterval(5))) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .invalidTokenResponse)
        }
        XCTAssertThrowsError(try malformed.consume(json(["error": "incorrect_device_code"]), receivedAt: now.addingTimeInterval(5))) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .serverRejectedAuthorization)
        }
        XCTAssertThrowsError(
            try malformed.consume(
                successTokenJSON(),
                receivedAt: Date(timeIntervalSinceReferenceDate: .nan)
            )
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .invalidTokenResponse)
        }
    }

    func testDevicePollerMakesDenialAndServerExpiryTerminal() throws {
        var denied = try GitHubDeviceFlowPoller(authorization: makeAuthorization())
        XCTAssertEqual(
            try denied.consume(json(["error": "access_denied"]), receivedAt: now.addingTimeInterval(5)),
            .denied
        )
        XCTAssertEqual(denied.status, .terminal(.denied))
        XCTAssertEqual(
            try denied.consume(successTokenJSON(), receivedAt: now.addingTimeInterval(6)),
            .terminal(.denied)
        )

        var expired = try GitHubDeviceFlowPoller(authorization: makeAuthorization())
        XCTAssertEqual(
            try expired.consume(json(["error": "expired_token"]), receivedAt: now.addingTimeInterval(5)),
            .expired
        )
        XCTAssertEqual(expired.status, .terminal(.expired))
        XCTAssertEqual(
            try expired.consume(successTokenJSON(), receivedAt: now.addingTimeInterval(6)),
            .terminal(.expired)
        )
    }

    func testDevicePollerChecksSlowDownAndScheduleArithmetic() throws {
        XCTAssertThrowsError(try GitHubDeviceFlowPoller.slowedInterval(from: .infinity)) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .invalidDeviceAuthorization)
        }

        let invalidIssuedAt = try GitHubDeviceAuthorization(
            deviceCode: GitHubSecret("device-secret"),
            userCode: "A",
            verificationURL: XCTUnwrap(URL(string: "https://github.com/login/device")),
            issuedAt: Date(timeIntervalSinceReferenceDate: .nan),
            expiresAt: now.addingTimeInterval(10),
            pollingInterval: 5
        )
        XCTAssertEqual(
            GitHubDeviceFlowPoller(authorization: invalidIssuedAt).status,
            .active(nextPollAt: invalidIssuedAt.expiresAt)
        )

        let authorization = try GitHubDeviceAuthorization(
            deviceCode: GitHubSecret("device-secret"),
            userCode: "A",
            verificationURL: XCTUnwrap(URL(string: "https://github.com/login/device")),
            issuedAt: Date(timeIntervalSinceReferenceDate: -Double.greatestFiniteMagnitude),
            expiresAt: Date(timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude),
            pollingInterval: Double.greatestFiniteMagnitude
        )
        var overflow = GitHubDeviceFlowPoller(authorization: authorization)
        XCTAssertThrowsError(
            try overflow.consume(
                json(["error": "authorization_pending"]),
                receivedAt: Date(timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude / 2)
            )
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .invalidDeviceAuthorization)
        }
    }

    func testGitHubCLIBrokerageIsAllowedOnlyForExplicitAddAccount() {
        XCTAssertEqual(GitHubCredentialBrokerageIntent.allCases.count, 3)
        XCTAssertEqual(GitHubCLIBrokeragePolicy.decision(for: .explicitAddAccount), .allowedForAddAccount)
        XCTAssertEqual(GitHubCLIBrokeragePolicy.decision(for: .backgroundRefresh), .denied)
        XCTAssertEqual(GitHubCLIBrokeragePolicy.decision(for: .runtimeFallback), .denied)
    }

    func testPATEntryRetainsOnlyExplicitSafeMetadataAndRedactsToken() throws {
        let expiry = now.addingTimeInterval(100)
        let secret = try GitHubSecret("github_pat_secret")
        let fineGrained = try GitHubPersonalAccessTokenEntry(
            token: secret,
            kind: .fineGrained,
            label: "Work repositories",
            expiresAt: expiry
        )
        let classic = try GitHubPersonalAccessTokenEntry(token: secret, kind: .classic)
        XCTAssertEqual(fineGrained.label, "Work repositories")
        XCTAssertEqual(fineGrained.expiresAt, expiry)
        XCTAssertNil(classic.label)
        XCTAssertNil(classic.expiresAt)
        XCTAssertEqual(GitHubPersonalAccessTokenKind.allCases, [.fineGrained, .classic])
        XCTAssertEqual(fineGrained.kind.forgeCredentialSource, .fineGrainedPersonalAccessToken)
        XCTAssertEqual(classic.kind.forgeCredentialSource, .classicPersonalAccessToken)
        assertRedacted(fineGrained, forbidden: ["github_pat_secret"])
        assertRedacted(classic, forbidden: ["github_pat_secret"])

        for label in ["", "line\nbreak", String(repeating: "a", count: 81)] {
            XCTAssertThrowsError(try GitHubPersonalAccessTokenEntry(token: secret, kind: .classic, label: label)) {
                XCTAssertEqual($0 as? GitHubAuthenticationError, .invalidPersonalAccessTokenLabel)
            }
        }
        for expiry in [
            Date(timeIntervalSinceReferenceDate: .nan),
            Date(timeIntervalSinceReferenceDate: .infinity),
        ] {
            XCTAssertThrowsError(
                try GitHubPersonalAccessTokenEntry(token: secret, kind: .classic, expiresAt: expiry)
            ) {
                XCTAssertEqual($0 as? GitHubAuthenticationError, .invalidPersonalAccessTokenExpiry)
            }
        }
    }

    private func configuration() throws -> GitHubAppDeviceFlowConfiguration {
        try GitHubAppDeviceFlowConfiguration(clientID: "Iv1ABC123", applicationSlug: "gitx-forge")
    }

    private func makeAuthorization() throws -> GitHubDeviceAuthorization {
        try GitHubDeviceAuthorizationParser.parse(
            json([
                "device_code": "device-secret",
                "user_code": "ABCD-EFGH",
                "verification_uri": "https://github.com/login/device",
                "expires_in": 900,
                "interval": 5,
            ]),
            receivedAt: now
        )
    }

    private func successTokenJSON(
        access: String = "access-secret",
        refresh: String = "rotated-refresh-secret"
    ) -> Data {
        json([
            "access_token": access,
            "expires_in": 3600,
            "refresh_token": refresh,
            "refresh_token_expires_in": 86400,
            "token_type": "Bearer",
        ])
    }

    private func form(_ request: GitHubOAuthRequest) -> String {
        String(decoding: request.makeURLRequest().httpBody ?? Data(), as: UTF8.self)
    }

    private func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func assertRedacted<T: CustomStringConvertible & CustomDebugStringConvertible & CustomReflectable>(
        _ value: T,
        forbidden: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let presentations = [value.description, value.debugDescription, String(describing: value), String(reflecting: value)]
        for secret in forbidden {
            XCTAssertFalse(presentations.joined().contains(secret), file: file, line: line)
        }
        XCTAssertTrue(value.customMirror.children.isEmpty, file: file, line: line)
    }
}
