import AppKit
import ForgeKit
import XCTest

@MainActor
final class ForgeExternalLinkRoutingTests: XCTestCase {
    func testTrustedOriginStorePersistsCanonicalExactOriginsAndFailsClosedOnMalformedData() throws {
        let defaults = try makeDefaults()
        let store = ForgeTrustedExternalOriginStore(defaults: defaults)
        let unicode = try ForgeTrustedExternalOrigin(
            origin: ForgeOrigin(host: "BÜCHER.example", port: 443)
        )
        let alternatePort = try ForgeTrustedExternalOrigin(
            origin: ForgeOrigin(host: "bücher.example", port: 8443)
        )

        XCTAssertTrue(store.add(alternatePort))
        XCTAssertTrue(store.add(unicode))
        XCTAssertFalse(store.add(unicode))
        XCTAssertEqual(
            store.sortedOrigins().map(\.origin.url.absoluteString),
            [unicode, alternatePort].map(\.origin.url.absoluteString).sorted()
        )

        let recreated = ForgeTrustedExternalOriginStore(defaults: defaults)
        XCTAssertEqual(recreated.origins(), [unicode, alternatePort])
        XCTAssertTrue(recreated.remove(unicode))
        XCTAssertFalse(recreated.remove(unicode))
        XCTAssertEqual(recreated.origins(), [alternatePort])
        XCTAssertTrue(recreated.removeAll())
        XCTAssertFalse(recreated.removeAll())

        defaults.set(Data("not-json".utf8), forKey: ForgeTrustedExternalOriginStore.storageKey)
        XCTAssertEqual(recreated.origins(), [])
        XCTAssertTrue(recreated.add(unicode))
        XCTAssertEqual(recreated.origins(), [unicode])
    }

    func testCentralRouterUsesNativeDestinationsAndValidatedBrowserFallbackWithoutGitSideEffects() throws {
        let repository = try makeRepository()
        let store = try ForgeTrustedExternalOriginStore(defaults: makeDefaults())
        let native = RecordingNativeOpener()
        let external = RecordingExternalOpener()
        let confirmations = RecordingConfirmationPresenter()
        let router = ForgeCentralDestinationRouter(
            repository: repository,
            trustedOrigins: store,
            nativeOpener: native,
            externalOpener: external,
            confirmations: confirmations
        )
        let issue = try ForgeDestination.issue(repository, ForgeItemNumber(12))

        router.openNative(destination: issue)
        XCTAssertEqual(native.destinations, [issue])
        XCTAssertEqual(external.urls, [])

        native.result = .unavailable
        router.openNative(destination: issue)
        XCTAssertEqual(native.destinations, [issue, issue])
        XCTAssertEqual(external.urls.map(\.absoluteString), ["https://github.com/hbmartin/gitx/issues/12"])
        XCTAssertEqual(confirmations.externalConfirmations, [])

        router.openInBrowser(destination: issue)
        XCTAssertEqual(native.destinations, [issue, issue], "Explicit browser escape must not re-enter native routing")
        XCTAssertEqual(external.urls.map(\.absoluteString), [
            "https://github.com/hbmartin/gitx/issues/12",
            "https://github.com/hbmartin/gitx/issues/12",
        ])

        try router.openMarkdownLinkInBrowser(XCTUnwrap(URL(string: "http://github.com/hbmartin/gitx")))
        XCTAssertEqual(external.urls.count, 2, "Non-HTTPS browser inputs must fail closed")
    }

    func testCrossOriginHTTPSRequiresConfirmationAndAlwaysAllowPersistsOnlyTheExactOrigin() throws {
        let repository = try makeRepository()
        let store = try ForgeTrustedExternalOriginStore(defaults: makeDefaults())
        let external = RecordingExternalOpener()
        let confirmations = RecordingConfirmationPresenter()
        confirmations.externalDecisions = [
            .open(alwaysTrustOrigin: true),
            .cancel,
            .cancel,
        ]
        let router = ForgeCentralDestinationRouter(
            repository: repository,
            trustedOrigins: store,
            nativeOpener: RecordingNativeOpener(),
            externalOpener: external,
            confirmations: confirmations
        )
        let first = try ForgeHTTPSLink("https://BÜCHER.example:443/path?value=1")

        router.activateMarkdownLink(.https(first))
        XCTAssertEqual(confirmations.externalConfirmations.count, 1)
        XCTAssertEqual(confirmations.externalConfirmations[0].url, first.url)
        XCTAssertEqual(confirmations.externalConfirmations[0].displayHost, "bücher.example")
        XCTAssertEqual(confirmations.externalConfirmations[0].asciiHost, "xn--bcher-kva.example")
        XCTAssertEqual(store.origins(), [ForgeTrustedExternalOrigin(origin: first.origin)])
        XCTAssertEqual(external.urls, [first.url])

        let sameOrigin = try ForgeHTTPSLink("https://xn--bcher-kva.example/next")
        router.activateMarkdownLink(.https(sameOrigin))
        XCTAssertEqual(confirmations.externalConfirmations.count, 1)
        XCTAssertEqual(external.urls, [first.url, sameOrigin.url])

        let alternatePort = try ForgeHTTPSLink("https://bücher.example:8443/next")
        router.activateMarkdownLink(.https(alternatePort))
        let subdomain = try ForgeHTTPSLink("https://sub.bücher.example/next")
        router.activateMarkdownLink(.https(subdomain))
        XCTAssertEqual(confirmations.externalConfirmations.map(\.origin.origin), [
            first.origin,
            alternatePort.origin,
            subdomain.origin,
        ])
        XCTAssertEqual(external.urls, [first.url, sameOrigin.url])
        XCTAssertEqual(store.origins(), [ForgeTrustedExternalOrigin(origin: first.origin)])
    }

    func testForeignNativeDestinationAndMailAreConfirmedWithoutPersistentMailBypass() throws {
        let repository = try makeRepository()
        let store = try ForgeTrustedExternalOriginStore(defaults: makeDefaults())
        let native = RecordingNativeOpener()
        let external = RecordingExternalOpener()
        let confirmations = RecordingConfirmationPresenter()
        confirmations.externalDecisions = [.open(alwaysTrustOrigin: false)]
        confirmations.mailDecisions = [.open, .cancel]
        let router = ForgeCentralDestinationRouter(
            repository: repository,
            trustedOrigins: store,
            nativeOpener: native,
            externalOpener: external,
            confirmations: confirmations
        )
        let foreignRepository = try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com")),
            owner: "team",
            name: "project"
        )
        let foreignIssue = try ForgeDestination.issue(foreignRepository, ForgeItemNumber(3))

        router.openNative(destination: foreignIssue)
        XCTAssertEqual(native.destinations, [], "Cross-repository values must never reach the native opener")
        XCTAssertEqual(confirmations.externalConfirmations.count, 1)
        XCTAssertEqual(external.urls.map(\.absoluteString), ["https://gitlab.com/team/project/-/issues/3"])
        XCTAssertEqual(store.origins(), [])

        let mail = try ForgeMailLink(
            "mailto:dev@example.com?cc=review@example.com&bcc=audit@example.com"
                + "&subject=Decoded%20Subject&body=Draft"
        )
        router.activateMarkdownLink(.mailto(mail))
        router.activateMarkdownLink(.mailto(mail))
        XCTAssertEqual(confirmations.mailConfirmations.count, 2, "Mail confirmation is never bypassed")
        XCTAssertEqual(confirmations.mailConfirmations[0].to, ["dev@example.com"])
        XCTAssertEqual(confirmations.mailConfirmations[0].cc, ["review@example.com"])
        XCTAssertEqual(confirmations.mailConfirmations[0].bcc, ["audit@example.com"])
        XCTAssertEqual(confirmations.mailConfirmations[0].subject, "Decoded Subject")
        XCTAssertTrue(confirmations.mailConfirmations[0].hasBody)
        XCTAssertEqual(external.urls.last, mail.url)
    }

    func testAppKitConfirmationsAndGeneralPreferencesExposeCompleteManageableTrustDetails() throws {
        let original = PBApplicationComposition.shared()
        let defaults = try makeDefaults()
        let store = ForgeTrustedExternalOriginStore(defaults: defaults)
        let origin = try ForgeTrustedExternalOrigin(
            origin: ForgeOrigin(host: "BÜCHER.example", port: 8443)
        )
        store.add(origin)
        PBApplicationComposition.setShared(PBApplicationComposition(userDefaults: defaults))
        defer { PBApplicationComposition.setShared(original) }

        let link = try ForgeHTTPSLink("https://BÜCHER.example:8443/complete/path?query=value#fragment")
        let externalConfirmation = ForgeExternalLinkConfirmation(
            url: link.url,
            origin: origin,
            displayHost: link.displayHost,
            asciiHost: link.asciiHost
        )
        let externalAlert = AppKitForgeLinkConfirmationPresenter.externalAlert(externalConfirmation)
        XCTAssertEqual(externalAlert.messageText, "Open External Link?")
        XCTAssertTrue(externalAlert.informativeText.contains(link.url.absoluteString))
        XCTAssertTrue(externalAlert.informativeText.contains("Display host: bücher.example"))
        XCTAssertTrue(externalAlert.informativeText.contains("ASCII host: xn--bcher-kva.example"))
        XCTAssertTrue(externalAlert.informativeText.contains(origin.origin.url.absoluteString))
        XCTAssertEqual(externalAlert.buttons.map(\.title), ["Open Link", "Cancel"])
        XCTAssertEqual(externalAlert.suppressionButton?.title, "Always Allow Links to This Host")
        let externalAlertContentView = try XCTUnwrap(externalAlert.window.contentView)
        try attachScreenshot(
            of: externalAlertContentView,
            named: "M1-Links-01-External-Origin-Confirmation"
        )

        let mail = try ForgeMailLink(
            "mailto:dev@example.com?cc=review@example.com&bcc=audit@example.com"
                + "&subject=Decoded%20Subject&body=Draft"
        )
        let mailAlert = AppKitForgeLinkConfirmationPresenter.mailAlert(ForgeMailConfirmation(
            url: mail.url,
            to: mail.to,
            cc: mail.cc,
            bcc: mail.bcc,
            subject: mail.subject,
            hasBody: mail.hasBody
        ))
        for detail in [
            "To: dev@example.com",
            "CC: review@example.com",
            "BCC: audit@example.com",
            "Subject: Decoded Subject",
            "Prefilled body: Yes",
        ] {
            XCTAssertTrue(mailAlert.informativeText.contains(detail), detail)
        }
        XCTAssertFalse(mailAlert.showsSuppressionButton, "Mail confirmation has no persistent bypass")
        let mailAlertContentView = try XCTUnwrap(mailAlert.window.contentView)
        try attachScreenshot(
            of: mailAlertContentView,
            named: "M1-Links-02-Mail-Confirmation"
        )

        let pane = PBSettingsViewFactory.generalView(legacyView: NSView())
        pane.frame = NSRect(origin: .zero, size: pane.fittingSize)
        pane.layoutSubtreeIfNeeded()
        let descendants = descendants(of: pane)
        XCTAssertNotNil(descendants.first {
            $0.accessibilityIdentifier() == "ForgeTrustedExternalOrigins"
        })
        XCTAssertTrue(descendants.compactMap { ($0 as? NSTextField)?.stringValue }.contains(
            origin.origin.url.absoluteString
        ))
        let remove = try XCTUnwrap(descendants.compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "RemoveForgeTrustedExternalOrigin"
        })
        try attachScreenshot(of: pane, named: "Trusted external Forge origins preferences")
        remove.performClick(nil)
        XCTAssertEqual(store.origins(), [])
    }

    func testAppKitConfirmationPresenterMapsEveryResponseWithoutPersistingPolicy() throws {
        let link = try ForgeHTTPSLink("https://external.example/path")
        let externalConfirmation = ForgeExternalLinkConfirmation(
            url: link.url,
            origin: ForgeTrustedExternalOrigin(origin: link.origin),
            displayHost: link.displayHost,
            asciiHost: link.asciiHost
        )
        let mail = try ForgeMailLink("mailto:dev@example.com")
        let mailConfirmation = ForgeMailConfirmation(
            url: mail.url,
            to: mail.to,
            cc: mail.cc,
            bcc: mail.bcc,
            subject: mail.subject,
            hasBody: mail.hasBody
        )
        let presentation = RecordingAlertPresentation()
        presentation.responses = [
            .alertSecondButtonReturn,
            .alertFirstButtonReturn,
            .alertFirstButtonReturn,
            .alertSecondButtonReturn,
        ]
        presentation.suppressedPresentationIndices = [1]
        let presenter = AppKitForgeLinkConfirmationPresenter(
            windowProvider: { nil },
            alertPresentation: presentation.present(_:for:completion:)
        )

        var externalDecisions: [ForgeExternalLinkDecision] = []
        presenter.confirmExternalLink(externalConfirmation) { externalDecisions.append($0) }
        presenter.confirmExternalLink(externalConfirmation) { externalDecisions.append($0) }
        XCTAssertEqual(externalDecisions, [.cancel, .open(alwaysTrustOrigin: true)])

        var mailDecisions: [ForgeMailLinkDecision] = []
        presenter.confirmMailLink(mailConfirmation) { mailDecisions.append($0) }
        presenter.confirmMailLink(mailConfirmation) { mailDecisions.append($0) }
        XCTAssertEqual(mailDecisions, [.open, .cancel])
        XCTAssertEqual(presentation.presentedMessages, [
            "Open External Link?",
            "Open External Link?",
            "Open Mail Link?",
            "Open Mail Link?",
        ])

        let router = try ForgeCentralDestinationRouter(
            repository: makeRepository(),
            trustedOrigins: ForgeTrustedExternalOriginStore(defaults: makeDefaults()),
            nativeOpener: RecordingNativeOpener(),
            externalOpener: RecordingExternalOpener(),
            confirmations: RecordingConfirmationPresenter()
        )
        router.activateMarkdownLink(.heading(ForgeMarkdownHeadingID(rawValue: "details")))
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "ForgeExternalLinkRoutingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    private func makeRepository() throws -> ForgeRepositoryIdentity {
        try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            owner: "hbmartin",
            name: "gitx"
        )
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap(descendants(of:))
    }

    private func attachScreenshot(of view: NSView, named name: String) throws {
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class RecordingAlertPresentation {
    var responses: [NSApplication.ModalResponse] = []
    var suppressedPresentationIndices: Set<Int> = []
    private(set) var presentedMessages: [String] = []

    func present(
        _ alert: NSAlert,
        for window: NSWindow?,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        XCTAssertNil(window)
        let index = presentedMessages.count
        presentedMessages.append(alert.messageText)
        if suppressedPresentationIndices.contains(index) {
            alert.suppressionButton?.state = .on
        }
        completion(responses.removeFirst())
    }
}

@MainActor
private final class RecordingNativeOpener: ForgeNativeDestinationOpening {
    var result: ForgeNativeDestinationOpenResult = .opened
    private(set) var destinations: [ForgeDestination] = []

    func open(_ destination: ForgeDestination) -> ForgeNativeDestinationOpenResult {
        destinations.append(destination)
        return result
    }
}

@MainActor
private final class RecordingExternalOpener: ForgeExternalURLOpening {
    private(set) var urls: [URL] = []

    func open(_ url: URL) {
        urls.append(url)
    }
}

@MainActor
private final class RecordingConfirmationPresenter: ForgeLinkConfirmationPresenting {
    var externalDecisions: [ForgeExternalLinkDecision] = []
    var mailDecisions: [ForgeMailLinkDecision] = []
    private(set) var externalConfirmations: [ForgeExternalLinkConfirmation] = []
    private(set) var mailConfirmations: [ForgeMailConfirmation] = []

    func confirmExternalLink(
        _ confirmation: ForgeExternalLinkConfirmation,
        completion: @escaping (ForgeExternalLinkDecision) -> Void
    ) {
        externalConfirmations.append(confirmation)
        completion(externalDecisions.isEmpty ? .cancel : externalDecisions.removeFirst())
    }

    func confirmMailLink(
        _ confirmation: ForgeMailConfirmation,
        completion: @escaping (ForgeMailLinkDecision) -> Void
    ) {
        mailConfirmations.append(confirmation)
        completion(mailDecisions.isEmpty ? .cancel : mailDecisions.removeFirst())
    }
}
