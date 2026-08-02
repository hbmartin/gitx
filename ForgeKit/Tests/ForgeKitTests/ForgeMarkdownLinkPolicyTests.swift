@testable import ForgeKit
import Foundation
import XCTest

final class ForgeMarkdownLinkPolicyTests: XCTestCase {
    private let policy = ForgeMarkdownLinkPolicy()

    func testAbsoluteHTTPSClassifiesOnlyAcceptedBoundRepositoryDestinationsAsNative() throws {
        let context = try repositoryContext()
        let nativeCases: [(String, ForgeDestinationKind)] = [
            ("https://github.com/acme/widgets/pull/7", .pullRequest),
            ("https://github.com/acme/widgets/issues/8", .issue),
            ("https://github.com/acme/widgets/commit/abc1234", .commit),
            ("https://github.com/acme/widgets/blob/main/README.md#L2", .file),
        ]
        for (url, kind) in nativeCases {
            guard case let .native(destination) = policy.target(for: url, context: context) else {
                return XCTFail("Expected native route for \(url)")
            }
            XCTAssertEqual(destination.kind, kind)
        }

        for url in [
            "https://github.com/acme/widgets",
            "https://github.com/acme/widgets/tree/main",
            "https://github.com/other/widgets/pull/7",
            "https://example.com/acme/widgets/pull/7",
        ] {
            guard case .https = policy.target(for: url, context: context) else {
                return XCTFail("Expected browser route for \(url)")
            }
        }
    }

    func testRelativeReferencesUseRepositoryRootOrDisplayedFileDirectoryAndRevision() throws {
        let repository = try TestSupport.repository()
        let root = ForgeMarkdownContext(
            repository: repository,
            location: .repository(defaultBranch: .branch(TestSupport.main))
        )
        guard case let .native(.file(_, revision, path, selection)) = policy.target(
            for: "Docs/na%C3%AFve%20guide.md#L3-L5",
            context: root
        ) else {
            return XCTFail("Expected native root-relative file")
        }
        XCTAssertEqual(revision.value, "main")
        XCTAssertEqual(path.value, "Docs/naïve guide.md")
        XCTAssertEqual(selection, try ForgeLineSelection(start: 3, end: 5))

        let file = try ForgeMarkdownContext(
            repository: repository,
            location: .file(
                revision: .commit(ForgeCommitID("deadbeef")),
                path: ForgeFilePath("Docs/Guide/Current.md")
            )
        )
        guard case let .native(.file(_, displayedRevision, siblingPath, _)) = policy.target(
            for: "../Shared.md",
            context: file
        ) else {
            return XCTFail("Expected displayed-file-relative route")
        }
        XCTAssertEqual(displayedRevision.value, "deadbeef")
        XCTAssertEqual(siblingPath.value, "Docs/Shared.md")

        XCTAssertNotNil(policy.target(for: "Guide.md?plain=1", context: file))

        guard case .https = policy.target(for: "../Shared.md#overview", context: file) else {
            return XCTFail("Non-line file fragments remain browser links")
        }
    }

    func testRootRelativeReferencesMustRemainInsideTheBoundRepository() throws {
        let context = try repositoryContext()
        guard case .native(.issue) = policy.target(for: "/acme/widgets/issues/4", context: context) else {
            return XCTFail("Expected bound root-relative issue")
        }
        for rejected in [
            "/other/widgets/issues/4",
            "/acme/widgets/../other/issues/4",
            "/%2E%2E/acme/widgets/issues/4",
        ] {
            XCTAssertNil(policy.target(for: rejected, context: context), rejected)
        }
    }

    func testRepositoryBoundaryRequiresTheExactOriginAndPathPrefix() throws {
        let repository = try TestSupport.repository()
        XCTAssertTrue(try ForgeMarkdownLinkPolicy.isWithinBoundRepository(
            XCTUnwrap(URL(string: "https://github.com/acme/widgets/issues/4")),
            repository: repository
        ))
        XCTAssertFalse(try ForgeMarkdownLinkPolicy.isWithinBoundRepository(
            XCTUnwrap(URL(string: "https://example.com/acme/widgets/issues/4")),
            repository: repository
        ))
    }

    func testRejectsUnsupportedSchemesCredentialsMalformedEscapesAndTraversal() throws {
        let repositoryContext = try repositoryContext()
        let fileContext = try ForgeMarkdownContext(
            repository: repositoryContext.repository,
            location: .file(
                revision: .branch(TestSupport.main),
                path: ForgeFilePath("Docs/README.md")
            )
        )
        for rejected in [
            "http://github.com/acme/widgets",
            "file:///tmp/private",
            "javascript:alert(1)",
            "data:text/plain,secret",
            "//evil.example/path",
            "https://user@github.com/acme/widgets",
            "https://github.com/%ZZ",
            "C:\\private\\file.md",
        ] {
            XCTAssertNil(policy.target(for: rejected, context: repositoryContext), rejected)
        }
        XCTAssertNil(policy.target(for: "../../outside.md", context: fileContext))
        XCTAssertNil(policy.target(for: "%2E%2E/%2E%2E/outside.md", context: fileContext))
        XCTAssertNil(policy.target(for: "folder%2Fhidden.md", context: fileContext))
        XCTAssertNil(policy.target(for: "folder%5Chidden.md", context: fileContext))
        XCTAssertNil(policy.target(for: "%20hidden.md", context: fileContext))
        XCTAssertNil(policy.target(for: ".", context: repositoryContext))
        XCTAssertNil(policy.target(for: "?query", context: repositoryContext))
    }

    func testFragmentMailAndExternalLinksProduceTypedTargets() throws {
        let context = try repositoryContext()
        XCTAssertEqual(
            policy.target(for: "#caf%C3%A9", context: context),
            .heading(ForgeMarkdownHeadingID(rawValue: "café"))
        )
        XCTAssertNil(policy.target(for: "#", context: context))

        guard case let .mailto(mail) = policy.target(
            for: "mailto:dev@example.com?cc=review@example.com&bcc=audit@example.com&subject=Hello%20World&body=Draft",
            context: context
        ) else {
            return XCTFail("Expected mail target")
        }
        XCTAssertEqual(mail.to, ["dev@example.com"])
        XCTAssertEqual(mail.cc, ["review@example.com"])
        XCTAssertEqual(mail.bcc, ["audit@example.com"])
        XCTAssertEqual(mail.subject, "Hello World")
        XCTAssertTrue(mail.hasBody)

        guard case let .https(link) = policy.target(
            for: "HTTPS://BÜCHER.example:443/path?q=1",
            context: context
        ) else {
            return XCTFail("Expected normalized HTTPS target")
        }
        XCTAssertEqual(link.displayHost, "bücher.example")
        XCTAssertEqual(link.asciiHost, "xn--bcher-kva.example")
        XCTAssertEqual(link.origin.effectivePort, 443)
    }

    func testMailPolicyRejectsHiddenFieldsDuplicateHeadersAndHeaderInjection() throws {
        let context = try repositoryContext()
        for rejected in [
            "mailto:dev@example.com?reply-to=hidden@example.com",
            "mailto:dev@example.com?subject=one&subject=two",
            "mailto:dev@example.com?body=one&body=two",
            "mailto:dev@example.com?subject=Hello%0D%0ABcc:attacker@example.com",
            "mailto:dev%ZZ@example.com",
            "mailto:dev@example.com#fragment",
        ] {
            XCTAssertNil(policy.target(for: rejected, context: context), rejected)
        }
    }

    func testErrorDescriptionsAndValidatedConstructorFailureFamilies() {
        XCTAssertEqual(
            ForgeMarkdownLinkPolicyError.invalidHTTPSURL.errorDescription,
            "The Markdown link is not a valid HTTPS URL."
        )
        XCTAssertEqual(
            ForgeMarkdownLinkPolicyError.invalidMailtoURL.errorDescription,
            "The Markdown link is not a valid mail address."
        )
        XCTAssertEqual(
            ForgeMarkdownLinkPolicyError.unsupportedMailtoField.errorDescription,
            "The mail link contains an unsupported field."
        )
        XCTAssertEqual(
            ForgeMarkdownLinkPolicyError.unsafeMailtoHeader.errorDescription,
            "The mail link contains an unsafe header value."
        )
        XCTAssertThrowsError(try ForgeHTTPSLink("https://.example.com/path")) {
            XCTAssertEqual($0 as? ForgeMarkdownLinkPolicyError, .invalidHTTPSURL)
        }
        XCTAssertThrowsError(try ForgeMailLink("mailto://example.com/dev")) {
            XCTAssertEqual($0 as? ForgeMarkdownLinkPolicyError, .invalidMailtoURL)
        }
        XCTAssertThrowsError(try ForgeMailLink("mailto:dev@example.com?subject=%FF")) {
            XCTAssertEqual($0 as? ForgeMarkdownLinkPolicyError, .invalidMailtoURL)
        }
    }

    func testMailToQueryEmptyRecipientsAndEmptyBodyRemainTyped() throws {
        let toQuery = try ForgeMailLink("mailto:?to=dev@example.com&body=")
        XCTAssertEqual(toQuery.to, ["dev@example.com"])
        XCTAssertFalse(toQuery.hasBody)

        let valuelessBody = try ForgeMailLink("mailto:dev@example.com?body")
        XCTAssertFalse(valuelessBody.hasBody)

        let noRecipients = try ForgeMailLink("mailto:?subject=Team")
        XCTAssertEqual(noRecipients.to, [])
        XCTAssertEqual(noRecipients.subject, "Team")
    }

    func testMailRecipientsPreserveEncodedAndQuotedCommasExactly() throws {
        let link = try ForgeMailLink(
            "mailto:%22last%2Cfirst%22@example.com,second@example.com"
                + "?to=%22query%2Cname%22@example.com&cc=team%2Calias@example.com"
        )
        XCTAssertEqual(
            link.to,
            [#""last,first"@example.com"#, "second@example.com", #""query,name"@example.com"#]
        )
        XCTAssertEqual(link.cc, ["team,alias@example.com"])

        let unicodeRecipient = try ForgeMailLink("mailto:d%C3%A9v@example.com")
        XCTAssertEqual(unicodeRecipient.to, ["dév@example.com"])

        XCTAssertThrowsError(try ForgeMailLink(#"mailto:"unterminated@example.com"#))
        XCTAssertThrowsError(try ForgeMailLink(#"mailto:"escaped\"@example.com"#))
        XCTAssertThrowsError(try ForgeMailLink("mailto:first@example.com,,last@example.com"))
    }

    func testActivationRequiresExactOriginTrustAndAlwaysConfirmsMail() throws {
        let repository = try TestSupport.repository()

        let heading = ForgeMarkdownHeadingID(rawValue: "details")
        XCTAssertEqual(
            try ForgeMarkdownLinkActivationPolicy.activation(
                for: .heading(heading),
                boundTo: repository,
                trustedExternalOrigins: []
            ),
            .scrollToHeading(heading)
        )

        let native = try ForgeDestination.issue(repository, ForgeItemNumber(9))
        guard case let .openNative(destination, browserURL) = try ForgeMarkdownLinkActivationPolicy.activation(
            for: .native(native),
            boundTo: repository,
            trustedExternalOrigins: []
        ) else {
            return XCTFail("Expected native activation")
        }
        XCTAssertEqual(destination, native)
        XCTAssertEqual(browserURL.absoluteString, "https://github.com/acme/widgets/issues/9")

        let untrustedLink = try ForgeHTTPSLink("https://bücher.example/path")
        guard case let .confirmHTTPS(confirmation) = try ForgeMarkdownLinkActivationPolicy.activation(
            for: .https(untrustedLink),
            boundTo: repository,
            trustedExternalOrigins: []
        ) else {
            return XCTFail("Expected confirmation")
        }
        XCTAssertEqual(confirmation.displayHost, "bücher.example")
        XCTAssertEqual(confirmation.asciiHost, "xn--bcher-kva.example")

        let trusted = ForgeTrustedExternalOrigin(origin: untrustedLink.origin)
        guard case .openHTTPS = try ForgeMarkdownLinkActivationPolicy.activation(
            for: .https(untrustedLink),
            boundTo: repository,
            trustedExternalOrigins: [trusted]
        ) else {
            return XCTFail("Expected exact trusted origin to open")
        }

        let alternatePort = try ForgeHTTPSLink("https://bücher.example:8443/path")
        guard case .confirmHTTPS = try ForgeMarkdownLinkActivationPolicy.activation(
            for: .https(alternatePort),
            boundTo: repository,
            trustedExternalOrigins: [trusted]
        ) else {
            return XCTFail("Trust must not inherit across ports")
        }

        let mail = try ForgeMailLink("mailto:dev@example.com")
        guard case .confirmMail = try ForgeMarkdownLinkActivationPolicy.activation(
            for: .mailto(mail),
            boundTo: repository,
            trustedExternalOrigins: [trusted]
        ) else {
            return XCTFail("Mail never receives a trust bypass")
        }
    }

    func testExternalTrustNeverInheritsAcrossHostBoundariesOrEquivalentDefaultPortSpelling() throws {
        let repository = try TestSupport.repository()
        let trustedLink = try ForgeHTTPSLink("https://BÜCHER.example:443/path")
        let trusted = ForgeTrustedExternalOrigin(origin: trustedLink.origin)

        for openWithoutConfirmation in [
            "https://bücher.example/other",
            "https://xn--bcher-kva.example/encoded-host",
        ] {
            guard case .openHTTPS = try ForgeMarkdownLinkActivationPolicy.activation(
                for: .https(ForgeHTTPSLink(openWithoutConfirmation)),
                boundTo: repository,
                trustedExternalOrigins: [trusted]
            ) else {
                return XCTFail("Equivalent exact origin should be trusted: \(openWithoutConfirmation)")
            }
        }

        for requiresConfirmation in [
            "https://sub.bücher.example/path",
            "https://example/path",
            "https://bücher.example:444/path",
            "https://bücher.example.evil.test/path",
        ] {
            guard case .confirmHTTPS = try ForgeMarkdownLinkActivationPolicy.activation(
                for: .https(ForgeHTTPSLink(requiresConfirmation)),
                boundTo: repository,
                trustedExternalOrigins: [trusted]
            ) else {
                return XCTFail("Non-exact origin must require confirmation: \(requiresConfirmation)")
            }
        }
    }

    func testNativeActivationCannotEscapeTheExactBoundRepositoryAfterConstructionOrDecoding() throws {
        let bound = try TestSupport.repository()
        let sameOriginOther = try ForgeRepositoryIdentity(
            forge: bound.forge,
            owner: "other",
            name: "widgets"
        )
        let sameOriginTarget = try ForgeMarkdownLinkTarget.native(
            .issue(sameOriginOther, ForgeItemNumber(4))
        )
        guard case let .openHTTPS(url) = try ForgeMarkdownLinkActivationPolicy.activation(
            for: sameOriginTarget,
            boundTo: bound,
            trustedExternalOrigins: []
        ) else {
            return XCTFail("A different repository must not route natively")
        }
        XCTAssertEqual(url.absoluteString, "https://github.com/other/widgets/issues/4")

        let repositoryTarget = ForgeMarkdownLinkTarget.native(.repository(bound))
        guard case let .openHTTPS(repositoryURL) = try ForgeMarkdownLinkActivationPolicy.activation(
            for: repositoryTarget,
            boundTo: bound,
            trustedExternalOrigins: []
        ) else {
            return XCTFail("A non-Markdown native kind must reclassify through HTTPS")
        }
        XCTAssertEqual(repositoryURL.absoluteString, "https://github.com/acme/widgets")

        let unsupportedEncoded = try JSONEncoder().encode(ForgeMarkdownLinkTarget.native(
            .compare(
                bound,
                base: .branch(ForgeRefName("main")),
                head: .branch(ForgeRefName("feature"))
            )
        ))
        let unsupportedDecoded = try JSONDecoder().decode(
            ForgeMarkdownLinkTarget.self,
            from: unsupportedEncoded
        )
        guard case let .openHTTPS(compareURL) = try ForgeMarkdownLinkActivationPolicy.activation(
            for: unsupportedDecoded,
            boundTo: bound,
            trustedExternalOrigins: []
        ) else {
            return XCTFail("A decoded non-Markdown kind must reclassify through HTTPS")
        }
        XCTAssertEqual(compareURL.absoluteString, "https://github.com/acme/widgets/compare/main...feature")

        let foreignOrigin = try ForgeOrigin(host: "gitlab.com")
        let foreignRepository = try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .gitLab, origin: foreignOrigin),
            owner: "acme",
            name: "widgets"
        )
        let encoded = try JSONEncoder().encode(ForgeMarkdownLinkTarget.native(
            .issue(foreignRepository, ForgeItemNumber(5))
        ))
        let decoded = try JSONDecoder().decode(ForgeMarkdownLinkTarget.self, from: encoded)
        guard case let .confirmHTTPS(confirmation) = try ForgeMarkdownLinkActivationPolicy.activation(
            for: decoded,
            boundTo: bound,
            trustedExternalOrigins: []
        ) else {
            return XCTFail("A decoded cross-origin target must require confirmation")
        }
        XCTAssertEqual(confirmation.url.absoluteString, "https://gitlab.com/acme/widgets/-/issues/5")
    }

    func testValidatedLinksRoundTripAndRejectUnsafeDecodedPayloads() throws {
        let https = try ForgeHTTPSLink("https://example.com/path")
        let mail = try ForgeMailLink("mailto:dev@example.com?subject=Hello")
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeHTTPSLink.self, from: JSONEncoder().encode(https)),
            https
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeMailLink.self, from: JSONEncoder().encode(mail)),
            mail
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(ForgeHTTPSLink.self, from: Data(#""http://example.com""#.utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ForgeMailLink.self,
                from: Data(#""mailto:dev@example.com?subject=x%0D%0Ay""#.utf8)
            )
        )
    }

    func testDotSegmentsMalformedRootAndProviderFilePrefixes() throws {
        let github = try ForgeMarkdownContext(
            repository: TestSupport.repository(),
            location: .repository(defaultBranch: .branch(TestSupport.main))
        )
        guard case let .native(.file(_, _, dotPath, _)) = policy.target(
            for: "./Docs/Guide.md#L1",
            context: github
        ) else {
            return XCTFail("Expected dot-relative file")
        }
        XCTAssertEqual(dotPath.value, "Docs/Guide.md")
        XCTAssertNil(policy.target(for: "/[", context: github))

        for (kind, host, expectedMarker) in [
            (ForgeKind.gitLab, "gitlab.com", "/-/blob/"),
            (ForgeKind.bitbucket, "bitbucket.org", "/src/"),
        ] {
            let origin = try ForgeOrigin(host: host)
            let repository = try ForgeRepositoryIdentity(
                forge: ForgeIdentity(kind: kind, origin: origin),
                owner: "acme",
                name: "widgets"
            )
            let context = ForgeMarkdownContext(
                repository: repository,
                location: .repository(defaultBranch: .branch(TestSupport.main))
            )
            guard case let .native(destination) = policy.target(for: "Docs/Guide.md", context: context) else {
                return XCTFail("Expected provider file link")
            }
            let url = try ForgeDestinationURLCodec.url(for: destination)
            XCTAssertTrue(url.path.contains(expectedMarker), url.absoluteString)
        }
    }

    private func repositoryContext() throws -> ForgeMarkdownContext {
        try ForgeMarkdownContext(
            repository: TestSupport.repository(),
            location: .repository(defaultBranch: .branch(TestSupport.main))
        )
    }
}
