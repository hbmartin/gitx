import ForgeKit
@testable import GitHubForgeAdapter
import XCTest

final class GitHubAuthorizationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)

    func testHeadersAreCaseInsensitiveAndDuplicateCaseDoesNotTrap() {
        let headers = GitHubHTTPHeaders(["Retry-After": "5", "retry-after": "10", "X-Other": "value"])
        XCTAssertNotNil(headers["RETRY-AFTER"])
        XCTAssertEqual(headers["x-other"], "value")
        XCTAssertNil(headers["missing"])
    }

    func testRESTAuthorizationParserRejectsNonAuthorizationStatusesAndMapsBadCredentials() {
        XCTAssertNil(
            GitHubRESTAuthorizationParser.parse(
                statusCode: 500,
                headers: [:],
                body: json(["message": "access-secret"]),
                installationConfigurationURL: nil
            )
        )
        XCTAssertEqual(
            GitHubRESTAuthorizationParser.parse(
                statusCode: 401,
                headers: [:],
                body: json(["message": "Bad credentials: access-secret"]),
                installationConfigurationURL: nil
            ),
            .badCredentials
        )
    }

    func testSAMLAuthorizationRequiresAnExactSafeGitHubOrganizationURL() throws {
        let expected = try XCTUnwrap(URL(string: "https://github.com/orgs/acme/sso?authorization_request=abc"))
        XCTAssertEqual(
            GitHubRESTAuthorizationParser.parse(
                statusCode: 403,
                headers: ["X-GitHub-SSO": "required; url=\(expected.absoluteString)"],
                body: Data(),
                installationConfigurationURL: nil
            ),
            .samlAuthorizationRequired(authorizeURL: expected)
        )

        for url in [
            "http://github.com/orgs/acme/sso",
            "https://github.com.evil/orgs/acme/sso",
            "https://user@github.com/orgs/acme/sso",
            "https://github.com:444/orgs/acme/sso",
            "https://github.com/org/acme/sso",
            "https://github.com/orgs/acme/sso/extra",
            "https://github.com/orgs/acme/sso#fragment",
        ] {
            XCTAssertEqual(
                GitHubRESTAuthorizationParser.parse(
                    statusCode: 403,
                    headers: ["x-github-sso": "required; url=\(url)"],
                    body: Data(),
                    installationConfigurationURL: nil
                ),
                .authorizationDenied
            )
        }
        XCTAssertEqual(
            GitHubRESTAuthorizationParser.parse(
                statusCode: 403,
                headers: ["x-github-sso": "required; malformed"],
                body: Data(),
                installationConfigurationURL: nil
            ),
            .authorizationDenied
        )
    }

    func testMissingInstallationAndRepositorySelectionUseOnlyValidatedConfigurationURLs() throws {
        let validURLs = try [
            XCTUnwrap(URL(string: "https://github.com/settings/installations/123")),
            XCTUnwrap(URL(string: "https://github.com/organizations/acme/settings/installations/123")),
            XCTUnwrap(URL(string: "https://github.com/apps/gitx-forge/installations/new")),
        ]
        let messages = [
            "Resource not accessible by integration",
            "The repository is not accessible by this app",
            "Installation not found",
        ]
        for (url, message) in zip(validURLs, messages) {
            XCTAssertEqual(
                GitHubRESTAuthorizationParser.parse(
                    statusCode: 403,
                    headers: [:],
                    body: json(["message": message]),
                    installationConfigurationURL: url
                ),
                .installationConfigurationRequired(configurationURL: url)
            )
        }

        let unsafeURLs = try [
            XCTUnwrap(URL(string: "http://github.com/settings/installations/123")),
            XCTUnwrap(URL(string: "https://github.com.evil/settings/installations/123")),
            XCTUnwrap(URL(string: "https://user@github.com/settings/installations/123")),
            XCTUnwrap(URL(string: "https://github.com:444/settings/installations/123")),
            XCTUnwrap(URL(string: "https://github.com/settings/installations/not-a-number")),
            XCTUnwrap(URL(string: "https://github.com/apps/gitx-forge/installations/new?q=1")),
            XCTUnwrap(URL(string: "https://github.com/apps/gitx-forge/installations/new#x")),
            XCTUnwrap(URL(string: "https://github.com/other/path")),
        ]
        for url in unsafeURLs {
            XCTAssertEqual(
                GitHubRESTAuthorizationParser.parse(
                    statusCode: 404,
                    headers: [:],
                    body: json(["message": "Resource not accessible by integration"]),
                    installationConfigurationURL: url
                ),
                .authorizationDenied
            )
        }
        XCTAssertEqual(
            GitHubRESTAuthorizationParser.parse(
                statusCode: 403,
                headers: [:],
                body: Data("private response access-secret".utf8),
                installationConfigurationURL: validURLs[0]
            ),
            .authorizationDenied
        )
        XCTAssertEqual(
            GitHubRESTAuthorizationParser.parse(
                statusCode: 403,
                headers: [:],
                body: json(["message": "Unrelated private response access-secret"]),
                installationConfigurationURL: validURLs[0]
            ),
            .authorizationDenied
        )
    }

    func testAuthorizationRecoveryURLsAreRedactedFromEveryTextualSurface() throws {
        let secretFragments = ["authorization_request=private", "installations/987654"]
        let failures: [GitHubRESTAuthorizationFailure] = try [
            .badCredentials,
            .authorizationDenied,
            .samlAuthorizationRequired(
                authorizeURL: XCTUnwrap(URL(string: "https://github.com/orgs/acme/sso?authorization_request=private"))
            ),
            .installationConfigurationRequired(
                configurationURL: XCTUnwrap(URL(string: "https://github.com/settings/installations/987654"))
            ),
        ]
        for failure in failures {
            let output = [
                failure.description,
                failure.debugDescription,
                String(describing: failure),
                String(reflecting: failure),
            ].joined()
            XCTAssertTrue(failure.customMirror.children.isEmpty)
            for secret in secretFragments {
                XCTAssertFalse(output.contains(secret))
            }
        }
    }

    func testRateLimitParserMapsCountersResourceResetAndNumericRetryAfter() throws {
        let metadata = GitHubRateLimitParser.parse(
            statusCode: 429,
            headers: [
                "X-RateLimit-Limit": "5000",
                "x-ratelimit-remaining": "0",
                "X-RateLimit-Used": "5000",
                "X-RateLimit-Reset": "1100",
                "Retry-After": "20",
                "X-RateLimit-Resource": "graphql_core",
            ],
            receivedAt: now
        )
        XCTAssertEqual(metadata.limit, 5000)
        XCTAssertEqual(metadata.remaining, 0)
        XCTAssertEqual(metadata.used, 5000)
        XCTAssertEqual(metadata.resetAt, Date(timeIntervalSince1970: 1100))
        XCTAssertEqual(metadata.retryAt, now.addingTimeInterval(20))
        XCTAssertEqual(metadata.resource, "graphql_core")
        XCTAssertEqual(metadata.cooldownDeadline(statusCode: 429, now: now), Date(timeIntervalSince1970: 1100))

        let reference = try credentialReference()
        let cooldown = try XCTUnwrap(metadata.credentialCooldown(statusCode: 429, credential: reference, now: now))
        XCTAssertEqual(cooldown.credential, reference)
        XCTAssertEqual(cooldown.deadline, Date(timeIntervalSince1970: 1100))
    }

    func testRateLimitParserAcceptsHTTPDateAndCooldownOnlyWhenServerReportsThrottle() throws {
        let httpDate = GitHubRateLimitParser.parse(
            statusCode: 403,
            headers: ["Retry-After": "Thu, 01 Jan 1970 00:18:20 GMT"],
            receivedAt: now
        )
        XCTAssertEqual(httpDate.retryAt, Date(timeIntervalSince1970: 1100))
        XCTAssertEqual(httpDate.cooldownDeadline(statusCode: 403, now: now), Date(timeIntervalSince1970: 1100))

        let healthy = GitHubRateLimitParser.parse(
            statusCode: 200,
            headers: ["X-RateLimit-Limit": "100", "X-RateLimit-Remaining": "90", "X-RateLimit-Reset": "1100"],
            receivedAt: now
        )
        XCTAssertNil(healthy.cooldownDeadline(statusCode: 200, now: now))
        XCTAssertNil(try healthy.credentialCooldown(statusCode: 200, credential: credentialReference(), now: now))

        let elapsed = GitHubRateLimitMetadata(
            limit: 10,
            remaining: 0,
            used: 10,
            resetAt: now,
            retryAt: now.addingTimeInterval(-1),
            resource: "core"
        )
        XCTAssertNil(elapsed.cooldownDeadline(statusCode: 403, now: now))
    }

    func testBare429UsesCheckedFallbackButBare403RequiresThrottleEvidence() {
        let bare = GitHubRateLimitParser.parse(statusCode: 429, headers: [:], receivedAt: now)
        XCTAssertEqual(bare.cooldownDeadline(statusCode: 429, now: now), now.addingTimeInterval(60))
        XCTAssertNil(bare.cooldownDeadline(statusCode: 403, now: now))

        let exhaustedWithoutReset = GitHubRateLimitParser.parse(
            statusCode: 403,
            headers: ["X-RateLimit-Remaining": "0"],
            receivedAt: now
        )
        XCTAssertNil(exhaustedWithoutReset.cooldownDeadline(statusCode: 403, now: now))

        let exhaustedWithReset = GitHubRateLimitParser.parse(
            statusCode: 403,
            headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1100"],
            receivedAt: now
        )
        XCTAssertEqual(
            exhaustedWithReset.cooldownDeadline(statusCode: 403, now: now),
            Date(timeIntervalSince1970: 1100)
        )
        XCTAssertNil(
            bare.cooldownDeadline(
                statusCode: 429,
                now: Date(timeIntervalSinceReferenceDate: .nan)
            )
        )
    }

    func testRateLimitParserFailsIndividualMalformedFieldsClosed() {
        let metadata = GitHubRateLimitParser.parse(
            statusCode: 429,
            headers: [
                "X-RateLimit-Limit": "-1",
                "X-RateLimit-Remaining": "5001",
                "X-RateLimit-Used": "not-int",
                "X-RateLimit-Reset": "nan",
                "Retry-After": "invalid",
                "X-RateLimit-Resource": "private\nvalue",
            ],
            receivedAt: now
        )
        XCTAssertNil(metadata.limit)
        XCTAssertEqual(metadata.remaining, 5001)
        XCTAssertNil(metadata.used)
        XCTAssertNil(metadata.resetAt)
        XCTAssertNil(metadata.retryAt)
        XCTAssertNil(metadata.resource)

        let overLimit = GitHubRateLimitParser.parse(
            statusCode: 403,
            headers: ["X-RateLimit-Limit": "10", "X-RateLimit-Remaining": "11", "X-RateLimit-Used": "12"],
            receivedAt: now
        )
        XCTAssertNil(overLimit.remaining)
        XCTAssertNil(overLimit.used)

        let overflow = GitHubRateLimitParser.parse(
            statusCode: 429,
            headers: ["X-RateLimit-Reset": "1e309", "Retry-After": "1e308"],
            receivedAt: Date(timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude)
        )
        XCTAssertNil(overflow.resetAt)
        XCTAssertNil(overflow.retryAt)

        let nonfiniteClock = GitHubRateLimitParser.parse(
            statusCode: 429,
            headers: ["Retry-After": "60"],
            receivedAt: Date(timeIntervalSinceReferenceDate: .infinity)
        )
        XCTAssertNil(nonfiniteClock.retryAt)
    }

    func testRequestedAppEnvelopeCannotAuthorizeAndObservedPermissionsMapExactly() throws {
        let request = GitHubCapabilityMapper.milestone3AppPermissionRequest
        XCTAssertEqual(request.permissions["contents"], .write)
        XCTAssertEqual(request.permissions["pull_requests"], .write)

        let context = try identityContext()
        let unobserved = GitHubPermissionSnapshot(permissions: [:], isComplete: false)
        let unobservedEvidence = try GitHubCapabilityMapper.permissionEvidence(
            credentialMetadata: metadata(.forgeApplicationDeviceFlow, reference: context.credential),
            repository: context.repository,
            authority: .appUserToken(
                credential: context.credential,
                repository: context.repository,
                permissions: unobserved
            )
        )
        for permission in ForgeRepositoryPermission.allCases {
            XCTAssertEqual(unobservedEvidence.authority(for: permission), .unknown)
        }

        let expected: [ForgeRepositoryPermission: ForgePermissionAuthority] = [
            .metadata: .known(.read),
            .contents: .known(.write),
            .pullRequests: .known(.write),
            .issues: .known(.write),
            .checks: .known(.read),
            .commitStatuses: .known(.read),
        ]
        let evidence = try GitHubCapabilityMapper.permissionEvidence(
            credentialMetadata: metadata(.forgeApplicationDeviceFlow, reference: context.credential),
            repository: context.repository,
            authority: .appUserToken(
                credential: context.credential,
                repository: context.repository,
                permissions: observedMilestone3AppPermissions()
            )
        )
        for permission in ForgeRepositoryPermission.allCases {
            XCTAssertEqual(evidence.authority(for: permission), expected[permission])
        }

        let allAccess = GitHubPermissionSnapshot(
            permissions: [
                "metadata": .none,
                "contents": .read,
                "pull_requests": .write,
                "issues": .admin,
            ],
            isComplete: true
        )
        let allEvidence = try GitHubCapabilityMapper.permissionEvidence(
            credentialMetadata: metadata(.forgeApplicationDeviceFlow, reference: context.credential),
            repository: context.repository,
            authority: .appUserToken(
                credential: context.credential,
                repository: context.repository,
                permissions: allAccess
            ),
            freshness: .cached
        )
        XCTAssertEqual(allEvidence.freshness, .cached)
        XCTAssertEqual(allEvidence.authority(for: .metadata), .known(.unavailable))
        XCTAssertEqual(allEvidence.authority(for: .contents), .known(.read))
        XCTAssertEqual(allEvidence.authority(for: .pullRequests), .known(.write))
        XCTAssertEqual(allEvidence.authority(for: .issues), .known(.write))
        XCTAssertEqual(allEvidence.authority(for: .checks), .known(.unavailable))
    }

    func testIncompleteFineGrainedPermissionsRemainUnknownForUnverifiedWrite() throws {
        let context = try identityContext()
        let snapshot = GitHubPermissionSnapshot(permissions: ["metadata": .read], isComplete: false)
        let evidence = try GitHubCapabilityMapper.permissionEvidence(
            credentialMetadata: metadata(.fineGrainedPersonalAccessToken, reference: context.credential),
            repository: context.repository,
            authority: .fineGrainedPersonalAccessToken(
                credential: context.credential,
                repository: context.repository,
                permissions: snapshot
            )
        )
        XCTAssertEqual(evidence.authority(for: .metadata), .known(.read))
        XCTAssertEqual(evidence.authority(for: .pullRequests), .unknown)
    }

    func testClassicAndCLIScopesMapOnlyKnownRepositoryAuthority() throws {
        let context = try identityContext()
        let repoEvidence = try GitHubCapabilityMapper.permissionEvidence(
            credentialMetadata: metadata(.classicPersonalAccessToken, reference: context.credential),
            repository: context.repository,
            authority: .classicPersonalAccessToken(
                credential: context.credential,
                repository: context.repository,
                scopes: ["REPO"],
                repositoryIsPublic: false
            )
        )
        XCTAssertEqual(repoEvidence.authority(for: .metadata), .known(.read))
        XCTAssertEqual(repoEvidence.authority(for: .contents), .known(.write))
        XCTAssertEqual(repoEvidence.authority(for: .pullRequests), .known(.write))
        XCTAssertEqual(repoEvidence.authority(for: .issues), .known(.write))
        XCTAssertEqual(repoEvidence.authority(for: .checks), .known(.read))
        XCTAssertEqual(repoEvidence.authority(for: .commitStatuses), .known(.write))

        let publicEvidence = try GitHubCapabilityMapper.permissionEvidence(
            credentialMetadata: metadata(.commandLineBroker, reference: context.credential),
            repository: context.repository,
            authority: .commandLineBroker(
                credential: context.credential,
                repository: context.repository,
                scopes: ["public_repo"],
                repositoryIsPublic: true
            )
        )
        XCTAssertEqual(publicEvidence.authority(for: .contents), .known(.write))

        let privateEvidence = try GitHubCapabilityMapper.permissionEvidence(
            credentialMetadata: metadata(.classicPersonalAccessToken, reference: context.credential),
            repository: context.repository,
            authority: .classicPersonalAccessToken(
                credential: context.credential,
                repository: context.repository,
                scopes: ["public_repo"],
                repositoryIsPublic: false
            )
        )
        XCTAssertEqual(privateEvidence.authority(for: .contents), .unknown)

        let statusOnly = try GitHubCapabilityMapper.permissionEvidence(
            credentialMetadata: metadata(.classicPersonalAccessToken, reference: context.credential),
            repository: context.repository,
            authority: .classicPersonalAccessToken(
                credential: context.credential,
                repository: context.repository,
                scopes: ["repo:status"],
                repositoryIsPublic: false
            )
        )
        XCTAssertEqual(statusOnly.authority(for: .commitStatuses), .known(.write))
        XCTAssertEqual(statusOnly.authority(for: .metadata), .unknown)
    }

    func testValidClassicAndCLICredentialsHaveAccountPartitionedPublicReadAuthority() throws {
        let context = try identityContext()
        for (source, authority) in [
            (
                ForgeCredentialSource.classicPersonalAccessToken,
                GitHubCredentialAuthority.classicPersonalAccessToken(
                    credential: context.credential,
                    repository: context.repository,
                    scopes: [],
                    repositoryIsPublic: true
                )
            ),
            (
                ForgeCredentialSource.commandLineBroker,
                GitHubCredentialAuthority.commandLineBroker(
                    credential: context.credential,
                    repository: context.repository,
                    scopes: [],
                    repositoryIsPublic: true
                )
            ),
        ] {
            let credentialMetadata = metadata(source, reference: context.credential)
            let evidence = try GitHubCapabilityMapper.permissionEvidence(
                credentialMetadata: credentialMetadata,
                repository: context.repository,
                authority: authority
            )
            XCTAssertEqual(evidence.credential, credentialMetadata.reference)
            XCTAssertEqual(evidence.credential.accountID, context.credential.accountID)
            for permission in ForgeRepositoryPermission.allCases {
                XCTAssertEqual(evidence.authority(for: permission), .known(.read))
            }
        }
    }

    func testCredentialAuthorityBindsExactSourceCredentialAndRepository() throws {
        let context = try identityContext()
        let claims: [(ForgeCredentialSource, GitHubCredentialAuthority)] = [
            (
                .classicPersonalAccessToken,
                .appUserToken(
                    credential: context.credential,
                    repository: context.repository,
                    permissions: observedMilestone3AppPermissions()
                )
            ),
            (
                .forgeApplicationDeviceFlow,
                .classicPersonalAccessToken(
                    credential: context.credential,
                    repository: context.repository,
                    scopes: ["repo"],
                    repositoryIsPublic: false
                )
            ),
            (
                .classicPersonalAccessToken,
                .fineGrainedPersonalAccessToken(
                    credential: context.credential,
                    repository: context.repository,
                    permissions: GitHubPermissionSnapshot(permissions: [:], isComplete: false)
                )
            ),
            (
                .fineGrainedPersonalAccessToken,
                .commandLineBroker(
                    credential: context.credential,
                    repository: context.repository,
                    scopes: ["repo"],
                    repositoryIsPublic: false
                )
            ),
        ]
        for (source, authority) in claims {
            XCTAssertThrowsError(
                try GitHubCapabilityMapper.permissionEvidence(
                    credentialMetadata: metadata(source, reference: context.credential),
                    repository: context.repository,
                    authority: authority
                )
            ) {
                XCTAssertEqual($0 as? GitHubAuthenticationError, .mismatchedCredentialAuthority)
            }
        }

        let nextGeneration = try ForgeCredentialReference(
            accountID: context.credential.accountID,
            credentialID: context.credential.credentialID,
            generation: ForgeCredentialGeneration(context.credential.generation.value + 1)
        )
        let otherAccount = try ForgeAccountID(
            forge: context.credential.accountID.forge,
            value: "other-account"
        )
        let otherAccountCredential = ForgeCredentialReference(
            accountID: otherAccount,
            credentialID: context.credential.credentialID,
            generation: context.credential.generation
        )
        let otherCredentialID = try ForgeCredentialReference(
            accountID: context.credential.accountID,
            credentialID: ForgeCredentialID("other-credential"),
            generation: context.credential.generation
        )
        let authority = GitHubCredentialAuthority.appUserToken(
            credential: context.credential,
            repository: context.repository,
            permissions: observedMilestone3AppPermissions()
        )
        for mismatchedReference in [nextGeneration, otherAccountCredential, otherCredentialID] {
            XCTAssertThrowsError(
                try GitHubCapabilityMapper.permissionEvidence(
                    credentialMetadata: metadata(.forgeApplicationDeviceFlow, reference: mismatchedReference),
                    repository: context.repository,
                    authority: authority
                )
            ) {
                XCTAssertEqual($0 as? GitHubAuthenticationError, .mismatchedCredentialAuthority)
            }
        }

        let otherRepository = try ForgeRepositoryIdentity(
            forge: context.repository.forge,
            owner: context.repository.owner,
            name: "other-repository"
        )
        XCTAssertThrowsError(
            try GitHubCapabilityMapper.permissionEvidence(
                credentialMetadata: metadata(.forgeApplicationDeviceFlow, reference: context.credential),
                repository: otherRepository,
                authority: authority
            )
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .mismatchedCredentialAuthority)
        }

        let reboundAuthority = GitHubCredentialAuthority.appUserToken(
            credential: nextGeneration,
            repository: context.repository,
            permissions: observedMilestone3AppPermissions()
        )
        let reboundEvidence = try GitHubCapabilityMapper.permissionEvidence(
            credentialMetadata: metadata(.forgeApplicationDeviceFlow, reference: nextGeneration),
            repository: context.repository,
            authority: reboundAuthority
        )
        XCTAssertEqual(reboundEvidence.credential, nextGeneration)
        XCTAssertEqual(reboundEvidence.repository, context.repository)
    }

    func testViewerPermissionsMapAllKnownRolesAndUnknownValues() {
        let values: [(String?, ForgeRepositoryRoleEvidence)] = [
            ("NONE", .known(.none)),
            ("read", .known(.read)),
            ("TRIAGE", .known(.triage)),
            ("write", .known(.write)),
            ("MAINTAIN", .known(.maintain)),
            ("admin", .known(.admin)),
            ("OWNER", .unknown),
            (nil, .unknown),
        ]
        for (input, expected) in values {
            XCTAssertEqual(GitHubCapabilityMapper.role(from: input), expected)
        }
    }

    func testRepositoryAccessMapsRecoveryAndDenialWithoutLeakingURLsIntoForgeKit() throws {
        let context = try identityContext()
        let saml = try GitHubRESTAuthorizationFailure.samlAuthorizationRequired(
            authorizeURL: XCTUnwrap(URL(string: "https://github.com/orgs/acme/sso"))
        )
        let installation = try GitHubRESTAuthorizationFailure.installationConfigurationRequired(
            configurationURL: XCTUnwrap(URL(string: "https://github.com/settings/installations/1"))
        )
        let cases: [(GitHubRESTAuthorizationFailure?, String?, ForgeRepositoryAccessStatus, ForgeRepositoryRoleEvidence)] = [
            (nil, "WRITE", .granted, .known(.write)),
            (nil, nil, .unknown, .unknown),
            (saml, "READ", .samlAuthorizationRequired, .known(.read)),
            (installation, "READ", .installationConfigurationRequired, .known(.read)),
            (.badCredentials, nil, .denied, .unknown),
            (.authorizationDenied, "NONE", .denied, .known(.none)),
        ]
        for (failure, permission, expectedStatus, expectedRole) in cases {
            let evidence = try GitHubCapabilityMapper.repositoryAccessEvidence(
                credential: context.credential,
                repository: context.repository,
                viewerPermission: permission,
                failure: failure,
                freshness: .stale
            )
            XCTAssertEqual(evidence.status, expectedStatus)
            XCTAssertEqual(evidence.role, expectedRole)
            XCTAssertEqual(evidence.freshness, .stale)
        }
    }

    func testCapabilityMappingRejectsOtherForgesAndMismatchedGitHubOrigins() throws {
        let context = try identityContext()
        let gitLab = try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com")),
            owner: "acme",
            name: "widgets"
        )
        XCTAssertThrowsError(
            try GitHubCapabilityMapper.permissionEvidence(
                credentialMetadata: metadata(.forgeApplicationDeviceFlow, reference: context.credential),
                repository: gitLab,
                authority: .appUserToken(
                    credential: context.credential,
                    repository: context.repository,
                    permissions: observedMilestone3AppPermissions()
                )
            )
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .nonGitHubIdentity)
        }

        let enterpriseLike = try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.example.com")),
            owner: "acme",
            name: "widgets"
        )
        XCTAssertThrowsError(
            try GitHubCapabilityMapper.repositoryAccessEvidence(
                credential: context.credential,
                repository: enterpriseLike,
                viewerPermission: "READ"
            )
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .nonGitHubIdentity)
        }

        let enterpriseForge = try ForgeIdentity(
            kind: .github,
            origin: ForgeOrigin(host: "github.example.com")
        )
        let enterpriseAccount = try ForgeAccountID(forge: enterpriseForge, value: "account")
        let enterpriseCredential = try ForgeCredentialReference(
            accountID: enterpriseAccount,
            credentialID: ForgeCredentialID("credential"),
            generation: ForgeCredentialGeneration(1)
        )
        XCTAssertThrowsError(
            try GitHubCapabilityMapper.permissionEvidence(
                credentialMetadata: metadata(.forgeApplicationDeviceFlow, reference: enterpriseCredential),
                repository: enterpriseLike,
                authority: .appUserToken(
                    credential: enterpriseCredential,
                    repository: enterpriseLike,
                    permissions: observedMilestone3AppPermissions()
                )
            )
        ) {
            XCTAssertEqual($0 as? GitHubAuthenticationError, .nonGitHubIdentity)
        }

        let normalizedForge = try ForgeIdentity(
            kind: .github,
            origin: ForgeOrigin(host: "GITHUB.COM.", port: 443)
        )
        let normalizedAccount = try ForgeAccountID(forge: normalizedForge, value: "account")
        let normalizedCredential = try ForgeCredentialReference(
            accountID: normalizedAccount,
            credentialID: ForgeCredentialID("credential"),
            generation: ForgeCredentialGeneration(1)
        )
        let normalizedRepository = try ForgeRepositoryIdentity(
            forge: normalizedForge,
            owner: "acme",
            name: "widgets"
        )
        XCTAssertNoThrow(
            try GitHubCapabilityMapper.permissionEvidence(
                credentialMetadata: metadata(.forgeApplicationDeviceFlow, reference: normalizedCredential),
                repository: normalizedRepository,
                authority: .appUserToken(
                    credential: normalizedCredential,
                    repository: normalizedRepository,
                    permissions: observedMilestone3AppPermissions()
                )
            )
        )
    }

    private func observedMilestone3AppPermissions() -> GitHubPermissionSnapshot {
        GitHubPermissionSnapshot(
            permissions: [
                "metadata": .read,
                "contents": .write,
                "pull_requests": .write,
                "issues": .write,
                "checks": .read,
                "statuses": .read,
            ],
            isComplete: true
        )
    }

    private func identityContext() throws -> (credential: ForgeCredentialReference, repository: ForgeRepositoryIdentity) {
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let account = try ForgeAccountID(forge: forge, value: "account")
        return try (
            ForgeCredentialReference(
                accountID: account,
                credentialID: ForgeCredentialID("credential"),
                generation: ForgeCredentialGeneration(1)
            ),
            ForgeRepositoryIdentity(forge: forge, owner: "acme", name: "widgets")
        )
    }

    private func credentialReference() throws -> ForgeCredentialReference {
        try identityContext().credential
    }

    private func metadata(
        _ source: ForgeCredentialSource,
        reference: ForgeCredentialReference
    ) -> ForgeCredentialMetadata {
        ForgeCredentialMetadata(reference: reference, source: source)
    }

    private func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
