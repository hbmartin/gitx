import AppKit
import Darwin
import ForgeKit
import GitHubForgeAdapter
import ObjectiveC
import XCTest

final class ForgeAccountLifecycleTests: XCTestCase {
    @MainActor
    func testAccountsPreferencesViewExposesStableAccessibilityContract() {
        let view = ForgeAccountsPreferencesView {
            throw ForgeAccountsError.deviceFlowFailed
        }
        let identifiers = accessibilityIdentifiers(in: view)

        XCTAssertTrue(identifiers.isSuperset(of: [
            "ForgeAccountsHeading",
            "ForgeAccountsTable",
            "AddForgeAccountWithGitHubApp",
            "ForgeAccountAlternativeMethods",
            "RemoveForgeAccount",
            "ConfigureForgeRepositoryAccess",
            "ForgeAccountPermissionEnvelope",
            "ForgeAccountsStatus",
            "ForgeAttentionPreferencesHeading",
            "ForgeAttentionWatchesTable",
            "RemoveForgeAttentionWatch",
            "ForgeAttentionPollingPreset",
            "ForgeAttentionAuthoredFailedChecks",
            "ForgeAttentionAwaitingReviewFailedChecks",
        ]))
    }

    func testAccountsPreferencesPresentationCoversEveryCredentialSourceAndExpiryState() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fixtures: [(String, ForgeCredentialSource, Date?)] = [
            ("app", .forgeApplicationDeviceFlow, now.addingTimeInterval(8 * 24 * 60 * 60)),
            ("cli", .commandLineBroker, nil),
            ("fine", .fineGrainedPersonalAccessToken, now.addingTimeInterval(24 * 60 * 60)),
            ("classic", .classicPersonalAccessToken, now.addingTimeInterval(-1)),
        ]
        let accounts = try fixtures.enumerated().map { index, fixture in
            let accountID = try makeAccountID("preferences-\(index)")
            return try ForgeAccount(
                id: accountID,
                login: fixture.0,
                currentCredential: ForgeCredentialMetadata(
                    reference: ForgeCredentialReference(
                        accountID: accountID,
                        credentialID: ForgeCredentialID("credential-\(index)"),
                        generation: ForgeCredentialGeneration(1)
                    ),
                    source: fixture.1,
                    expiresAt: fixture.2
                )
            )
        }

        let rows = ForgeAccountPreferencesPresenter.rows(accounts: accounts, now: now)

        XCTAssertEqual(rows.map(\.credentialTitle), [
            "GitHub App",
            "GitHub CLI",
            "Fine-grained token",
            "Classic token",
        ])
        XCTAssertEqual(rows.map(\.canConfigureRepositoryAccess), [true, false, false, false])
        XCTAssertEqual(rows[0].expiry, .current(now.addingTimeInterval(8 * 24 * 60 * 60)))
        XCTAssertEqual(rows[1].expiry, .doesNotExpire)
        XCTAssertEqual(rows[2].expiry, .expiresSoon(now.addingTimeInterval(24 * 60 * 60)))
        XCTAssertEqual(rows[3].expiry, .expired(now.addingTimeInterval(-1)))
        XCTAssertEqual(
            ForgeAccountPreferencesPresenter.removalMessage(for: rows[0]),
            "Remove the GitHub.com Forge Account app? Its Credential and account-scoped Forge data will be deleted."
        )
    }

    @MainActor
    func testAccountsPreferencesLoadsRowsRendersWatchesAndPersistsAttentionActions() async throws {
        let originalPolling = ApplicationSettings.attentionPollingPreset
        let originalAuthored = ApplicationSettings.attentionIncludesFailedChecksOnAuthoredPullRequests
        let originalAwaiting = ApplicationSettings.attentionIncludesFailedChecksAwaitingReview
        let originalAlerts = ApplicationSettings.attentionAlertCategories
        defer {
            ApplicationSettings.attentionPollingPreset = originalPolling
            ApplicationSettings.attentionIncludesFailedChecksOnAuthoredPullRequests = originalAuthored
            ApplicationSettings.attentionIncludesFailedChecksAwaitingReview = originalAwaiting
            ApplicationSettings.attentionAlertCategories = originalAlerts
        }
        ApplicationSettings.attentionAlertCategories = Set(ForgeAttentionAlertCategory.allCases)

        let accountID = try makeAccountID("preferences-ui-app")
        let accounts = try [
            makeAccount(
                id: accountID,
                login: "app-user",
                source: .forgeApplicationDeviceFlow,
                expiresAt: Date().addingTimeInterval(30 * 24 * 60 * 60)
            ),
            makeAccount(
                id: makeAccountID("preferences-ui-cli"),
                login: "cli-user",
                source: .commandLineBroker,
                expiresAt: nil
            ),
            makeAccount(
                id: makeAccountID("preferences-ui-soon"),
                login: "soon-user",
                source: .fineGrainedPersonalAccessToken,
                expiresAt: Date().addingTimeInterval(60)
            ),
            makeAccount(
                id: makeAccountID("preferences-ui-expired"),
                login: "expired-user",
                source: .classicPersonalAccessToken,
                expiresAt: Date().addingTimeInterval(-60)
            ),
        ]
        let repository = try ForgeRepositoryIdentity(
            forge: accountID.forge,
            owner: "hbmartin",
            name: "gitx"
        )
        let watchKey = try ForgeWatchedRepositoryKey(accountID: accountID, repository: repository)
        let client = try PreferencesAccountsClientDouble(
            accounts: accounts,
            watches: [ForgeAttentionWatchPreferencesRow(
                key: watchKey,
                accountLogin: "app-user",
                repositoryName: "hbmartin/gitx",
                includesBotReplies: false
            )],
            installationURL: XCTUnwrap(URL(string: "https://github.com/apps/gitx-test/installations/new"))
        )
        let view = ForgeAccountsPreferencesView { client }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 880),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        await waitUntil("initial account load") {
            await client.accountLoads() >= 1
        }
        await settleMainActor()

        let accountTable = try XCTUnwrap(descendant(identifier: "ForgeAccountsTable", in: view) as? NSTableView)
        XCTAssertEqual(accountTable.numberOfRows, 4)
        for row in 0 ..< accountTable.numberOfRows {
            for column in accountTable.tableColumns {
                XCTAssertNotNil(accountTable.view(
                    atColumn: accountTable.column(withIdentifier: column.identifier),
                    row: row,
                    makeIfNecessary: true
                ))
            }
        }
        let statusColumn = accountTable.column(withIdentifier: NSUserInterfaceItemIdentifier("Status"))
        let currentStatus = try XCTUnwrap(
            accountTable.view(atColumn: statusColumn, row: 0, makeIfNecessary: true) as? NSTextField
        )
        XCTAssertTrue(currentStatus.stringValue.hasPrefix("Expires "))
        XCTAssertNil(accountTable.delegate?.tableView?(accountTable, viewFor: nil, row: 0))

        let watchTable = try XCTUnwrap(descendant(identifier: "ForgeAttentionWatchesTable", in: view) as? NSTableView)
        XCTAssertEqual(watchTable.numberOfRows, 1)
        for column in watchTable.tableColumns {
            XCTAssertNotNil(watchTable.view(
                atColumn: watchTable.column(withIdentifier: column.identifier),
                row: 0,
                makeIfNecessary: true
            ))
        }
        view.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let screenshot = NSImage(size: view.bounds.size)
        screenshot.addRepresentation(representation)
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Milestone 1 - Accounts and Attention Preferences"
        attachment.lifetime = .keepAlways
        add(attachment)

        let botReply = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionWatchBotReplies", in: view) as? NSButton
        )
        botReply.performClick(nil)
        await waitUntil("bot-reply preference update") {
            await client.botReplyUpdateCount() >= 1
        }
        await waitUntil("account reload after bot-reply update") {
            await client.accountLoads() >= 2
        }
        await settleMainActor()
        let botReplyUpdates = await client.botReplyUpdates()
        XCTAssertEqual(botReplyUpdates, [true])

        for index in 0 ..< 4 {
            let polling = try XCTUnwrap(
                descendant(identifier: "ForgeAttentionPollingPreset", in: view) as? NSPopUpButton
            )
            polling.selectItem(at: index)
            try NSApp.sendAction(XCTUnwrap(polling.action), to: polling.target, from: polling)
        }
        XCTAssertEqual(ApplicationSettings.attentionPollingPreset, .manual)

        let authored = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionAuthoredFailedChecks", in: view) as? NSButton
        )
        let awaiting = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionAwaitingReviewFailedChecks", in: view) as? NSButton
        )
        authored.state = .on
        awaiting.state = .off
        try NSApp.sendAction(XCTUnwrap(authored.action), to: authored.target, from: authored)
        XCTAssertTrue(ApplicationSettings.attentionIncludesFailedChecksOnAuthoredPullRequests)
        XCTAssertFalse(ApplicationSettings.attentionIncludesFailedChecksAwaitingReview)

        let reviewAlert = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionAlert.reviewRequests", in: view) as? NSButton
        )
        reviewAlert.state = .off
        try NSApp.sendAction(XCTUnwrap(reviewAlert.action), to: reviewAlert.target, from: reviewAlert)
        XCTAssertFalse(ApplicationSettings.attentionAlertCategories.contains(.reviewRequests))

        watchTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        view.tableViewSelectionDidChange(Notification(
            name: NSTableView.selectionDidChangeNotification,
            object: watchTable
        ))
        let removeWatch = try XCTUnwrap(
            descendant(identifier: "RemoveForgeAttentionWatch", in: view) as? NSButton
        )
        await waitUntil("Remove Attention watch button to become enabled") {
            removeWatch.isEnabled
        }
        XCTAssertTrue(removeWatch.isEnabled)
        removeWatch.performClick(nil)
        await waitUntil("Attention watch removal") {
            await client.watchRemovalCount() >= 1
        }
        await waitUntil("account reload after Attention watch removal") {
            await client.accountLoads() >= 3
        }
        await settleMainActor()
        let removedWatches = await client.removedWatches()
        XCTAssertEqual(removedWatches, [watchKey])

        let alternatives = try XCTUnwrap(
            descendant(identifier: "ForgeAccountAlternativeMethods", in: view) as? NSPopUpButton
        )
        await waitUntil("alternative account methods to become enabled") {
            alternatives.isEnabled
        }
        alternatives.selectItem(at: 1)
        try NSApp.sendAction(XCTUnwrap(alternatives.action), to: alternatives.target, from: alternatives)
        await waitUntil("explicit GitHub CLI account addition") {
            await client.cliAdditionCount() >= 1
        }
        await waitUntil("account reload after CLI addition") {
            await client.accountLoads() >= 4
        }
        await settleMainActor()
        XCTAssertEqual(alternatives.indexOfSelectedItem, 0)
        let cliAdditionCount = await client.cliAdditionCount()
        XCTAssertEqual(cliAdditionCount, 1)
        _ = window
    }

    func testAccountsConfigurationRejectsMissingPlaceholderAndMalformedBuildValues() throws {
        _ = ForgeGitHubAppConfiguration.bundled(bundle: .main)
        XCTAssertEqual(
            ForgeAccountsError.deviceFlowNotStarted.localizedDescription,
            "The GitHub device authorization has not been started."
        )
        XCTAssertEqual(
            ForgeAccountsError.deviceFlowFailed.localizedDescription,
            "GitHub could not complete device authorization."
        )
        XCTAssertNil(ForgeGitHubAppConfiguration.configuration(infoDictionary: [:]))
        XCTAssertNil(ForgeGitHubAppConfiguration.configuration(infoDictionary: [
            ForgeGitHubAppConfiguration.clientIDInfoKey: "$(GITX_GITHUB_APP_CLIENT_ID)",
            ForgeGitHubAppConfiguration.applicationSlugInfoKey: "$(GITX_GITHUB_APP_SLUG)",
        ]))
        XCTAssertNil(ForgeGitHubAppConfiguration.configuration(infoDictionary: [
            ForgeGitHubAppConfiguration.clientIDInfoKey: "bad client",
            ForgeGitHubAppConfiguration.applicationSlugInfoKey: "gitx-forge",
        ]))
        let configuration = try XCTUnwrap(ForgeGitHubAppConfiguration.configuration(infoDictionary: [
            ForgeGitHubAppConfiguration.clientIDInfoKey: "  Iv1ABC123  ",
            ForgeGitHubAppConfiguration.applicationSlugInfoKey: " gitx-forge ",
        ]))
        XCTAssertEqual(configuration.clientID, "Iv1ABC123")
        XCTAssertEqual(configuration.applicationSlug, "gitx-forge")
        XCTAssertEqual(
            configuration.newInstallationURL.absoluteString,
            "https://github.com/apps/gitx-forge/installations/new"
        )
    }

    func testRuntimeAuthorizationRecoveryPresentationAcceptsOnlyTypedSafeRetryableFailures() throws {
        let samlURL = try XCTUnwrap(URL(string: "https://github.com/orgs/example/sso"))
        let installationURL = try XCTUnwrap(
            URL(string: "https://github.com/apps/gitx-test/installations/new")
        )
        let rateLimit = GitHubRateLimitParser.parse(
            statusCode: 403,
            headers: [:],
            receivedAt: Date(timeIntervalSince1970: 1)
        )
        let samlMetadata = GitHubResponseMetadata(
            statusCode: 403,
            rateLimit: rateLimit,
            saml: GitHubSAMLMetadata(authorizationURL: samlURL)
        )
        let installationMetadata = GitHubResponseMetadata(
            statusCode: 403,
            rateLimit: rateLimit,
            installation: GitHubInstallationMetadata(configurationURL: installationURL)
        )

        let saml = try XCTUnwrap(GitHubAuthorizationRecoveryPresentation.make(
            error: GitHubReadError.samlAuthorizationRequired(samlMetadata)
        ))
        XCTAssertEqual(saml.kind, .saml)
        XCTAssertEqual(saml.browserActionTitle, "Authorize in Browser")
        XCTAssertEqual(saml.url, samlURL)
        let installation = try XCTUnwrap(GitHubAuthorizationRecoveryPresentation.make(
            error: GitHubMutationError.installationConfigurationRequired(installationMetadata)
        ))
        XCTAssertEqual(installation.kind, .installation)
        XCTAssertEqual(installation.browserActionTitle, "Configure Repository Access")
        XCTAssertEqual(installation.url, installationURL)
        XCTAssertNil(GitHubAuthorizationRecoveryPresentation.make(
            error: GitHubMutationError.outcomeUnknown(nil)
        ))
        XCTAssertNil(GitHubAuthorizationRecoveryPresentation.make(
            error: GitHubReadError.samlAuthorizationRequired(GitHubResponseMetadata(
                statusCode: 403,
                rateLimit: rateLimit,
                saml: GitHubSAMLMetadata(authorizationURL: nil)
            ))
        ))
    }

    @MainActor
    func testRuntimeAuthorizationRecoveryPresenterCompletesBrowserAndRetrySheets() async throws {
        let alerts = ScopedAlertRunModalDriver()
        defer { alerts.restore() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }
        let controller = PBGitWindowController(window: window)
        let authorizationURL = try XCTUnwrap(URL(string: "https://github.com/orgs/example/sso"))
        let metadata = GitHubResponseMetadata(
            statusCode: 403,
            rateLimit: GitHubRateLimitParser.parse(
                statusCode: 403,
                headers: [:],
                receivedAt: Date(timeIntervalSince1970: 1)
            ),
            saml: GitHubSAMLMetadata(authorizationURL: authorizationURL)
        )
        var retryCount = 0

        XCTAssertTrue(GitHubAuthorizationRecoveryPresenter.present(
            error: GitHubReadError.samlAuthorizationRequired(metadata),
            for: controller,
            retry: { retryCount += 1 }
        ))
        let browserSheet = try XCTUnwrap(window.sheets.first)
        let browserContentView = try XCTUnwrap(browserSheet.contentView)
        attachScreenshot(
            of: browserContentView,
            named: "M1-Accounts-03-Typed-Authorization-Recovery"
        )
        window.endSheet(browserSheet, returnCode: .alertFirstButtonReturn)
        await settleMainActor()

        XCTAssertEqual(alerts.openedURLs, [authorizationURL])
        let retrySheet = try XCTUnwrap(window.sheets.first)
        window.endSheet(retrySheet, returnCode: .alertFirstButtonReturn)
        await settleMainActor()
        XCTAssertEqual(retryCount, 1)
    }

    func testAuthorizationRecoverySourcePolicyMatchesCredentialAuthority() throws {
        let samlURL = try XCTUnwrap(URL(string: "https://github.com/orgs/example/sso"))
        let installationURL = try XCTUnwrap(
            URL(string: "https://github.com/apps/gitx-test/installations/new")
        )
        let saml = GitHubRESTAuthorizationFailure.samlAuthorizationRequired(authorizeURL: samlURL)
        let installation = GitHubRESTAuthorizationFailure.installationConfigurationRequired(
            configurationURL: installationURL
        )
        let sources: [ForgeCredentialSource] = [
            .forgeApplicationDeviceFlow,
            .commandLineBroker,
            .fineGrainedPersonalAccessToken,
            .classicPersonalAccessToken,
        ]

        XCTAssertEqual(
            sources.filter {
                GitHubAuthorizationRecoverySourcePolicy.allowsRecovery(
                    for: saml,
                    credentialSource: $0
                )
            },
            [.commandLineBroker, .classicPersonalAccessToken]
        )
        XCTAssertEqual(
            sources.filter {
                GitHubAuthorizationRecoverySourcePolicy.allowsRecovery(
                    for: installation,
                    credentialSource: $0
                )
            },
            [.forgeApplicationDeviceFlow]
        )
        for failure in [GitHubRESTAuthorizationFailure.badCredentials, .authorizationDenied] {
            XCTAssertTrue(sources.allSatisfy {
                !GitHubAuthorizationRecoverySourcePolicy.allowsRecovery(
                    for: failure,
                    credentialSource: $0
                )
            })
        }
    }

    @MainActor
    func testAccountsPreferencesMakesFailuresAndModalCancellationsActionable() async throws {
        let alerts = ScopedAlertRunModalDriver()
        defer { alerts.restore() }

        let accountID = try makeAccountID("preferences-failure")
        let account = try makeAccount(
            id: accountID,
            login: "failure-user",
            source: .forgeApplicationDeviceFlow,
            expiresAt: nil
        )
        let repository = try ForgeRepositoryIdentity(
            forge: accountID.forge,
            owner: "hbmartin",
            name: "gitx"
        )
        let watchKey = try ForgeWatchedRepositoryKey(accountID: accountID, repository: repository)
        let authorization = try GitHubDeviceAuthorizationParser.parse(
            Data(#"{"device_code":"device-secret","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}"#.utf8),
            receivedAt: Date().addingTimeInterval(-5)
        )
        let installationURL = try XCTUnwrap(URL(string: "https://github.com/apps/gitx-test/installations/new"))

        let initialFailure = PreferencesFailureClientDouble(
            account: account,
            watch: nil,
            installationURL: installationURL,
            authorization: authorization
        )
        await initialFailure.setFailure(.accounts, enabled: true)
        alerts.enqueue(.alertFirstButtonReturn)
        let failedView = ForgeAccountsPreferencesView { initialFailure }
        let failedWindow = makePreferencesWindow(contentView: failedView)
        await waitUntil("failed initial account load") {
            await initialFailure.callCount(for: .accounts) == 1
        }
        await settleMainActor()
        let failedStatus = try XCTUnwrap(
            descendant(identifier: "ForgeAccountsStatus", in: failedView) as? NSTextField
        )
        XCTAssertEqual(failedStatus.stringValue, "No GitHub.com Forge Accounts are configured.")

        let client = PreferencesFailureClientDouble(
            account: account,
            watch: ForgeAttentionWatchPreferencesRow(
                key: watchKey,
                accountLogin: account.login,
                repositoryName: "hbmartin/gitx",
                includesBotReplies: false
            ),
            installationURL: installationURL,
            authorization: authorization
        )
        let view = ForgeAccountsPreferencesView { client }
        let window = makePreferencesWindow(contentView: view)
        await waitUntil("working account load") {
            await client.callCount(for: .accounts) == 1
        }
        await settleMainActor()
        let status = try XCTUnwrap(descendant(identifier: "ForgeAccountsStatus", in: view) as? NSTextField)
        let alternatives = try XCTUnwrap(
            descendant(identifier: "ForgeAccountAlternativeMethods", in: view) as? NSPopUpButton
        )

        await client.setFailure(.cli, enabled: true)
        alerts.enqueue(.alertFirstButtonReturn)
        alternatives.selectItem(at: 1)
        try NSApp.sendAction(XCTUnwrap(alternatives.action), to: alternatives.target, from: alternatives)
        await waitUntil("GitHub CLI failure presentation") {
            await client.callCount(for: .cli) == 1 && status.stringValue == PreferencesClientFailure.cli.localizedDescription
        }
        XCTAssertEqual(alternatives.indexOfSelectedItem, 0)
        await client.setFailure(.cli, enabled: false)

        alerts.enqueue(.alertSecondButtonReturn) { alert in
            self.assertPersonalAccessTokenAlertLayout(alert)
            self.attachScreenshot(
                of: alert.window.contentView,
                named: "M1-Accounts-02-Personal-Access-Token-Entry"
            )
        }
        alternatives.selectItem(at: 2)
        try NSApp.sendAction(XCTUnwrap(alternatives.action), to: alternatives.target, from: alternatives)
        var personalAccessTokenCalls = await client.callCount(for: .personalAccessToken)
        XCTAssertEqual(personalAccessTokenCalls, 0)

        alerts.enqueue(.alertFirstButtonReturn)
        alerts.enqueue(.alertFirstButtonReturn)
        alternatives.selectItem(at: 3)
        try NSApp.sendAction(XCTUnwrap(alternatives.action), to: alternatives.target, from: alternatives)
        XCTAssertEqual(status.stringValue, ForgeAccountsError.invalidPersonalAccessToken.localizedDescription)
        personalAccessTokenCalls = await client.callCount(for: .personalAccessToken)
        XCTAssertEqual(personalAccessTokenCalls, 0)

        alerts.enqueue(.alertFirstButtonReturn) { alert in
            self.populatePersonalAccessToken(in: alert, token: "github_pat_test", label: " laptop ")
        }
        alternatives.selectItem(at: 2)
        try NSApp.sendAction(XCTUnwrap(alternatives.action), to: alternatives.target, from: alternatives)
        await waitUntil("personal access token success") {
            await client.callCount(for: .personalAccessToken) == 1 &&
                status.stringValue == "Personal access Credential added."
        }
        let acquisitions = await client.personalAccessTokenAcquisitions()
        XCTAssertEqual(acquisitions.map(\.label), ["laptop"])

        await client.setFailure(.personalAccessToken, enabled: true)
        alerts.enqueue(.alertFirstButtonReturn) { alert in
            self.populatePersonalAccessToken(in: alert, token: "ghp_test", label: "classic")
        }
        alerts.enqueue(.alertFirstButtonReturn)
        alternatives.selectItem(at: 3)
        try NSApp.sendAction(XCTUnwrap(alternatives.action), to: alternatives.target, from: alternatives)
        await waitUntil("personal access token failure") {
            await client.callCount(for: .personalAccessToken) == 2 &&
                status.stringValue == PreferencesClientFailure.personalAccessToken.localizedDescription
        }
        await client.setFailure(.personalAccessToken, enabled: false)

        let watchTable = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionWatchesTable", in: view) as? NSTableView
        )
        _ = watchTable.view(atColumn: 2, row: 0, makeIfNecessary: true)
        let botReplies = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionWatchBotReplies", in: view) as? NSButton
        )
        await client.setFailure(.botReplies, enabled: true)
        alerts.enqueue(.alertFirstButtonReturn)
        botReplies.performClick(nil)
        await waitUntil("bot reply failure") {
            await client.callCount(for: .botReplies) == 1 &&
                status.stringValue == PreferencesClientFailure.botReplies.localizedDescription
        }
        await client.setFailure(.botReplies, enabled: false)

        watchTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        view.tableViewSelectionDidChange(Notification(
            name: NSTableView.selectionDidChangeNotification,
            object: watchTable
        ))
        let removeWatch = try XCTUnwrap(
            descendant(identifier: "RemoveForgeAttentionWatch", in: view) as? NSButton
        )
        await client.setFailure(.removeWatch, enabled: true)
        alerts.enqueue(.alertFirstButtonReturn)
        removeWatch.performClick(nil)
        await waitUntil("watch removal failure") {
            await client.callCount(for: .removeWatch) == 1 &&
                status.stringValue == PreferencesClientFailure.removeWatch.localizedDescription
        }
        await client.setFailure(.removeWatch, enabled: false)

        let removeAccount = try XCTUnwrap(descendant(identifier: "RemoveForgeAccount", in: view) as? NSButton)
        alerts.enqueue(.alertSecondButtonReturn)
        removeAccount.performClick(nil)
        let removeAccountCalls = await client.callCount(for: .removeAccount)
        XCTAssertEqual(removeAccountCalls, 0)

        await client.setFailure(.removeAccount, enabled: true)
        alerts.enqueue(.alertFirstButtonReturn)
        alerts.enqueue(.alertFirstButtonReturn)
        removeAccount.performClick(nil)
        await waitUntil("account removal failure") {
            await client.callCount(for: .removeAccount) == 1 &&
                status.stringValue == PreferencesClientFailure.removeAccount.localizedDescription
        }

        let signIn = try XCTUnwrap(
            descendant(identifier: "AddForgeAccountWithGitHubApp", in: view) as? NSButton
        )
        alerts.enqueue(.alertSecondButtonReturn) { alert in
            self.attachScreenshot(
                of: alert.window.contentView,
                named: "M1-Accounts-01-Device-Authorization"
            )
        }
        signIn.performClick(nil)
        await waitUntil("cancelled device authorization") {
            await client.callCount(for: .beginDeviceFlow) == 1
        }
        let pollDeviceFlowCalls = await client.callCount(for: .pollDeviceFlow)
        XCTAssertEqual(pollDeviceFlowCalls, 0)

        let missingConfiguration = PreferencesFailureClientDouble(
            account: account,
            watch: nil,
            installationURL: installationURL,
            authorization: authorization
        )
        await missingConfiguration.setFailure(.installationURL, enabled: true)
        let missingView = ForgeAccountsPreferencesView { missingConfiguration }
        let missingWindow = makePreferencesWindow(contentView: missingView)
        await waitUntil("missing installation URL load") {
            await missingConfiguration.callCount(for: .accounts) == 1
        }
        let configure = try XCTUnwrap(
            descendant(identifier: "ConfigureForgeRepositoryAccess", in: missingView) as? NSButton
        )
        alerts.enqueue(.alertFirstButtonReturn)
        try NSApp.sendAction(XCTUnwrap(configure.action), to: configure.target, from: configure)
        let missingStatus = try XCTUnwrap(
            descendant(identifier: "ForgeAccountsStatus", in: missingView) as? NSTextField
        )
        XCTAssertEqual(
            missingStatus.stringValue,
            ForgeAccountsError.githubApplicationNotConfigured.localizedDescription
        )

        XCTAssertEqual(alerts.pendingResponseCount, 0)
        _ = [failedWindow, window, missingWindow]
    }

    @MainActor
    func testAccountsPreferencesCompletesDeviceFlowRemovalAndAuthorizationRecovery() async throws {
        let alerts = ScopedAlertRunModalDriver()
        defer { alerts.restore() }

        let accountID = try makeAccountID("preferences-success")
        let account = try makeAccount(
            id: accountID,
            login: "success-user",
            source: .forgeApplicationDeviceFlow,
            expiresAt: nil
        )
        let issuedAt = Date().addingTimeInterval(-10)
        let authorization = try GitHubDeviceAuthorizationParser.parse(
            Data(#"{"device_code":"device-secret","user_code":"WXYZ-9876","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}"#.utf8),
            receivedAt: issuedAt
        )
        let installationURL = try XCTUnwrap(URL(string: "https://github.com/apps/gitx-test/installations/new"))
        let client = PreferencesFailureClientDouble(
            account: account,
            watch: nil,
            installationURL: installationURL,
            authorization: authorization
        )
        let view = ForgeAccountsPreferencesView { client }
        let window = makePreferencesWindow(contentView: view)
        await waitUntil("success-path account load") {
            await client.callCount(for: .accounts) == 1
        }
        await settleMainActor()

        let status = try XCTUnwrap(descendant(identifier: "ForgeAccountsStatus", in: view) as? NSTextField)
        let signIn = try XCTUnwrap(
            descendant(identifier: "AddForgeAccountWithGitHubApp", in: view) as? NSButton
        )
        let rotatingCredential = try GitHubRotatingUserCredential(
            accessToken: GitHubSecret("device-access"),
            accessTokenExpiresAt: Date().addingTimeInterval(3600),
            refreshToken: GitHubSecret("device-refresh"),
            refreshTokenExpiresAt: Date().addingTimeInterval(7200)
        )
        await client.setPollResults([
            .notYetPollable(nextPollAt: issuedAt.addingTimeInterval(2)),
            .pending(nextPollAt: issuedAt.addingTimeInterval(3)),
            .slowedDown(nextPollAt: issuedAt.addingTimeInterval(4)),
            .authorized(rotatingCredential),
        ])
        alerts.enqueue(.alertFirstButtonReturn)
        signIn.performClick(nil)
        await waitUntil("authorized device-flow completion") {
            await client.callCount(for: .completeDeviceFlow) == 1 &&
                status.stringValue == "GitHub App Forge Account added."
        }
        XCTAssertTrue(alerts.openedURLs.contains(authorization.verificationURL))

        await client.setPollResults([.terminal(.authorized)])
        alerts.enqueue(.alertFirstButtonReturn)
        signIn.performClick(nil)
        await waitUntil("terminal authorized device-flow completion") {
            await client.callCount(for: .completeDeviceFlow) == 2
        }

        let terminalFailures: [(GitHubDeviceFlowPollResult, ForgeAccountsError)] = [
            (.expired, .deviceFlowExpired),
            (.denied, .deviceFlowDenied),
            (.terminal(.expired), .deviceFlowExpired),
            (.terminal(.denied), .deviceFlowDenied),
        ]
        for (offset, fixture) in terminalFailures.enumerated() {
            await waitUntil("device-flow button after prior operation") { signIn.isEnabled }
            let priorPolls = await client.callCount(for: .pollDeviceFlow)
            await client.setPollResults([fixture.0])
            alerts.enqueue(.alertFirstButtonReturn)
            alerts.enqueue(.alertFirstButtonReturn)
            signIn.performClick(nil)
            await waitUntil("device-flow terminal failure \(offset)") {
                await client.callCount(for: .pollDeviceFlow) == priorPolls + 1 &&
                    status.stringValue == fixture.1.localizedDescription
            }
        }

        let alternatives = try XCTUnwrap(
            descendant(identifier: "ForgeAccountAlternativeMethods", in: view) as? NSPopUpButton
        )
        await client.setCancellation(.cli, enabled: true)
        alternatives.selectItem(at: 1)
        try NSApp.sendAction(XCTUnwrap(alternatives.action), to: alternatives.target, from: alternatives)
        await waitUntil("cancelled account operation") {
            status.stringValue == "Account operation cancelled."
        }
        await client.setCancellation(.cli, enabled: false)

        let configure = try XCTUnwrap(
            descendant(identifier: "ConfigureForgeRepositoryAccess", in: view) as? NSButton
        )
        try NSApp.sendAction(XCTUnwrap(configure.action), to: configure.target, from: configure)
        XCTAssertTrue(alerts.openedURLs.contains(installationURL))

        let removeAccount = try XCTUnwrap(descendant(identifier: "RemoveForgeAccount", in: view) as? NSButton)
        alerts.enqueue(.alertFirstButtonReturn)
        removeAccount.performClick(nil)
        await waitUntil("successful account removal") {
            await client.callCount(for: .removeAccount) == 1 &&
                status.stringValue == "Forge Account removed."
        }

        let configurationURL = try XCTUnwrap(URL(string: "https://github.com/settings/installations/123"))
        let installationFailure = GitHubRESTAuthorizationFailure.installationConfigurationRequired(
            configurationURL: configurationURL
        )
        await client.setPersonalAccessTokenAuthorizationFailures([installationFailure])
        let fineGrainedInstallationBaseline = await client.callCount(for: .personalAccessToken)
        alerts.enqueue(.alertFirstButtonReturn) { alert in
            self.populatePersonalAccessToken(in: alert, token: "github_pat_install", label: "installation")
        }
        alerts.enqueue(.alertFirstButtonReturn)
        alternatives.selectItem(at: 2)
        try NSApp.sendAction(XCTUnwrap(alternatives.action), to: alternatives.target, from: alternatives)
        await waitUntil("fine-grained Credential rejects installation recovery") {
            await client.callCount(for: .personalAccessToken) == fineGrainedInstallationBaseline + 1 &&
                status.stringValue == installationFailure.description
        }
        XCTAssertFalse(alerts.openedURLs.contains(configurationURL))

        await client.setPersonalAccessTokenAuthorizationFailures([installationFailure])
        let classicInstallationBaseline = await client.callCount(for: .personalAccessToken)
        alerts.enqueue(.alertFirstButtonReturn) { alert in
            self.populatePersonalAccessToken(in: alert, token: "ghp_install", label: "installation")
        }
        alerts.enqueue(.alertFirstButtonReturn)
        alternatives.selectItem(at: 3)
        try NSApp.sendAction(XCTUnwrap(alternatives.action), to: alternatives.target, from: alternatives)
        await waitUntil("classic Credential rejects installation recovery") {
            await client.callCount(for: .personalAccessToken) == classicInstallationBaseline + 1 &&
                status.stringValue == installationFailure.description
        }
        XCTAssertFalse(alerts.openedURLs.contains(configurationURL))

        let samlURL = try XCTUnwrap(URL(string: "https://github.com/orgs/example/sso?authorization_request=test"))
        await client.setPersonalAccessTokenAuthorizationFailures([
            .samlAuthorizationRequired(authorizeURL: samlURL),
        ])
        let samlRecoveryBaseline = await client.callCount(for: .personalAccessToken)
        alerts.enqueue(.alertFirstButtonReturn) { alert in
            self.populatePersonalAccessToken(in: alert, token: "ghp_saml", label: "saml")
        }
        alerts.enqueue(.alertFirstButtonReturn)
        alerts.enqueue(.alertFirstButtonReturn)
        alternatives.selectItem(at: 3)
        try NSApp.sendAction(XCTUnwrap(alternatives.action), to: alternatives.target, from: alternatives)
        await waitUntil("SAML recovery retry") {
            await client.callCount(for: .personalAccessToken) == samlRecoveryBaseline + 2 &&
                status.stringValue == "Personal access Credential added."
        }
        XCTAssertTrue(alerts.openedURLs.contains(samlURL))

        for responses in [
            [NSApplication.ModalResponse.alertSecondButtonReturn],
            [.alertFirstButtonReturn, .alertSecondButtonReturn],
        ] {
            await client.setPersonalAccessTokenAuthorizationFailures([
                .samlAuthorizationRequired(authorizeURL: samlURL),
            ])
            let baseline = await client.callCount(for: .personalAccessToken)
            alerts.enqueue(.alertFirstButtonReturn) { alert in
                self.populatePersonalAccessToken(in: alert, token: "ghp_decline", label: "decline")
            }
            for response in responses {
                alerts.enqueue(response)
            }
            alternatives.selectItem(at: 3)
            try NSApp.sendAction(XCTUnwrap(alternatives.action), to: alternatives.target, from: alternatives)
            await waitUntil("SAML recovery cancellation") {
                await client.callCount(for: .personalAccessToken) == baseline + 1 && alternatives.isEnabled
            }
        }

        for failure in [GitHubRESTAuthorizationFailure.badCredentials, .authorizationDenied] {
            await client.setPersonalAccessTokenAuthorizationFailures([failure])
            let baseline = await client.callCount(for: .personalAccessToken)
            alerts.enqueue(.alertFirstButtonReturn) { alert in
                self.populatePersonalAccessToken(in: alert, token: "ghp_denied", label: "denied")
            }
            alerts.enqueue(.alertFirstButtonReturn)
            alternatives.selectItem(at: 3)
            try NSApp.sendAction(XCTUnwrap(alternatives.action), to: alternatives.target, from: alternatives)
            await waitUntil("nonrecoverable authorization failure") {
                await client.callCount(for: .personalAccessToken) == baseline + 1 &&
                    status.stringValue == failure.description
            }
        }

        XCTAssertEqual(alerts.pendingResponseCount, 0)
        _ = window
    }

    func testPersonalAccessAcquisitionRedactsTokenAndNormalizesOptionalLabel() throws {
        let acquisition = try ForgePersonalAccessTokenAcquisition(
            kind: .fineGrained,
            token: Data("secret-token".utf8),
            label: "  laptop  "
        )

        XCTAssertEqual(acquisition.label, "laptop")
        XCTAssertFalse(String(describing: acquisition).contains("secret-token"))
        XCTAssertFalse(String(reflecting: acquisition).contains("secret-token"))
        XCTAssertTrue(acquisition.customMirror.children.isEmpty)
        XCTAssertThrowsError(try ForgePersonalAccessTokenAcquisition(
            kind: .classic,
            token: Data(),
            label: nil
        )) {
            XCTAssertEqual($0 as? ForgeAccountsError, .invalidPersonalAccessToken)
        }
    }

    func testGitHubCLIIsConsultedOnlyByExplicitAddAccountAndStoresBrokeredToken() async throws {
        let runner = StubForgeCLICommandRunner(results: [
            ForgeCLICommandResult(
                standardOutput: Data("cli-secret-token\n".utf8),
                standardError: Data(),
                terminationStatus: 0
            ),
            ForgeCLICommandResult(
                standardOutput: Data(#"{"node_id":"MDQ6VXNlcjE=","login":"octocat"}"#.utf8),
                standardError: Data(),
                terminationStatus: 0
            ),
        ])
        let keychain = LifecycleKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let coordinator = ForgeAddAccountCoordinator(
            accountStore: store,
            cliBroker: GitHubCLIAccountBroker(runner: runner)
        )

        let initialCommands = await runner.commands()
        XCTAssertEqual(initialCommands, [], "composition must never consult GitHub CLI")
        let account = try await coordinator.addUsingExplicitGitHubCLIBrokerage()
        XCTAssertEqual(account.login, "octocat")
        XCTAssertEqual(account.id.value, "MDQ6VXNlcjE=")
        XCTAssertEqual(account.currentCredential.source, .commandLineBroker)
        let executedArguments = await runner.commands().map(\.arguments)
        XCTAssertEqual(executedArguments, [
            ["gh", "auth", "token", "--hostname", "github.com"],
            ["gh", "api", "--hostname", "github.com", "user"],
        ])
        let executedCommands = await runner.commands()
        let identityCommand = try XCTUnwrap(executedCommands.last)
        let identityEnvironment = try XCTUnwrap(identityCommand.secretEnvironment)
        XCTAssertEqual(identityEnvironment.name, "GH_TOKEN")
        XCTAssertEqual(
            identityEnvironment.withUnsafeValue { Data($0) },
            Data("cli-secret-token".utf8)
        )
        XCTAssertFalse(String(describing: identityCommand).contains("cli-secret-token"))
        XCTAssertFalse(String(reflecting: identityCommand).contains("cli-secret-token"))
        XCTAssertTrue(identityCommand.customMirror.children.isEmpty)
        XCTAssertFalse(String(describing: identityEnvironment).contains("cli-secret-token"))
        XCTAssertFalse(String(reflecting: identityEnvironment).contains("cli-secret-token"))
        XCTAssertTrue(identityEnvironment.customMirror.children.isEmpty)
        let storedCredential = try await store.credential(for: account.id)
        let envelope = try XCTUnwrap(storedCredential)
        XCTAssertEqual(
            envelope.secrets.withUnsafeAccessTokenBytes { Data($0) },
            Data("cli-secret-token".utf8)
        )
        XCTAssertFalse(String(reflecting: envelope).contains("cli-secret-token"))
    }

    func testCLIBrokerFailuresExposeStatusButNeverCommandOutput() async throws {
        let runner = StubForgeCLICommandRunner(results: [
            ForgeCLICommandResult(
                standardOutput: Data("private-response".utf8),
                standardError: Data("secret-diagnostic".utf8),
                terminationStatus: 23
            ),
        ])
        do {
            _ = try await GitHubCLIAccountBroker(runner: runner).brokerForExplicitAddAccount()
            XCTFail("a failing CLI command must not produce a Credential")
        } catch {
            XCTAssertEqual(error as? ForgeCLIBrokerError, .commandFailed(status: 23))
            XCTAssertFalse(error.localizedDescription.contains("private-response"))
            XCTAssertFalse(error.localizedDescription.contains("secret-diagnostic"))
        }
    }

    func testCLIBrokerRejectsMalformedIdentityAndEmptyToken() async throws {
        let malformedIdentityRunner = StubForgeCLICommandRunner(results: [
            ForgeCLICommandResult(
                standardOutput: Data("token".utf8),
                standardError: Data(),
                terminationStatus: 0
            ),
            ForgeCLICommandResult(
                standardOutput: Data(#"{"login":"octocat"}"#.utf8),
                standardError: Data(),
                terminationStatus: 0
            ),
        ])
        do {
            _ = try await GitHubCLIAccountBroker(runner: malformedIdentityRunner).brokerForExplicitAddAccount()
            XCTFail("brokerage requires GitHub's stable node identity")
        } catch {
            XCTAssertEqual(error as? ForgeCLIBrokerError, .invalidIdentityResponse)
            XCTAssertEqual(error.localizedDescription, "GitHub CLI returned an invalid account identity.")
        }

        let emptyTokenRunner = StubForgeCLICommandRunner(results: [
            ForgeCLICommandResult(
                standardOutput: Data(" \n\t".utf8),
                standardError: Data(),
                terminationStatus: 0
            ),
        ])
        do {
            _ = try await GitHubCLIAccountBroker(runner: emptyTokenRunner).brokerForExplicitAddAccount()
            XCTFail("brokerage requires nonempty Credential material")
        } catch {
            XCTAssertEqual(error as? ForgeCLIBrokerError, .invalidTokenResponse)
            XCTAssertEqual(error.localizedDescription, "GitHub CLI returned invalid Credential material.")
        }

        let invalidTypedIdentityRunner = StubForgeCLICommandRunner(results: [
            ForgeCLICommandResult(
                standardOutput: Data("token".utf8),
                standardError: Data(),
                terminationStatus: 0
            ),
            ForgeCLICommandResult(
                standardOutput: Data(#"{"node_id":"","login":"octocat"}"#.utf8),
                standardError: Data(),
                terminationStatus: 0
            ),
        ])
        await XCTAssertThrowsErrorAsync(
            try await GitHubCLIAccountBroker(runner: invalidTypedIdentityRunner).brokerForExplicitAddAccount()
        ) { error in
            XCTAssertEqual(error as? ForgeCLIBrokerError, .invalidIdentityResponse)
        }
    }

    func testCredentialRefreshRejectsCurrentResultAfterIncarnationChangesAndUsesDefaultFactory() async throws {
        let store = ForgeAccountStore(keychain: LifecycleKeychain())
        let accountID = try makeAccountID("refresh-incarnation")
        let original = try await store.addAccount(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("github-app"),
            source: .forgeApplicationDeviceFlow,
            expiresAt: Date(timeIntervalSince1970: 10000),
            secrets: ForgeCredentialSecretMaterial(
                accessToken: Data("access".utf8),
                refreshToken: Data("refresh".utf8),
                refreshTokenExpiresAt: Date(timeIntervalSince1970: 20000)
            )
        )
        let optionalSnapshot = try await store.credentialSnapshot(for: accountID)
        let snapshot = try XCTUnwrap(optionalSnapshot)
        let configuration = try GitHubAppDeviceFlowConfiguration(
            clientID: "Iv1ABC123",
            applicationSlug: "gitx-test"
        )
        let mutatingRefresher = MutatingCurrentCredentialRefresher {
            _ = try await store.rotateCredential(
                expectedReference: original.currentCredential.reference,
                expectedRevision: snapshot.revision,
                expiresAt: Date(timeIntervalSince1970: 11000),
                secrets: ForgeCredentialSecretMaterial(
                    accessToken: Data("rotated-access".utf8),
                    refreshToken: Data("rotated-refresh".utf8),
                    refreshTokenExpiresAt: Date(timeIntervalSince1970: 21000)
                )
            )
        }
        let coordinator = ForgeAccountCredentialRefreshCoordinator(
            accountStore: store,
            configuration: configuration,
            refresherFactory: { _ in mutatingRefresher }
        )

        let staleCredential = try await coordinator.credential(
            for: original.currentCredential.reference,
            at: Date(timeIntervalSince1970: 9900)
        )
        XCTAssertNil(staleCredential)

        let optionalCurrent = try await store.credential(for: accountID)
        let current = try XCTUnwrap(optionalCurrent)
        let defaultCoordinator = ForgeAccountCredentialRefreshCoordinator(
            accountStore: store,
            configuration: configuration
        )
        let defaultCredential = try await defaultCoordinator.credential(
            for: current.account.currentCredential.reference,
            at: Date(timeIntervalSince1970: 9900),
            minimumValidity: 1
        )
        XCTAssertNotNil(defaultCredential)
    }

    func testCLIBrokerBindsIdentityToTokenWhenActiveCLIAccountChangesBetweenCommands() async throws {
        let runner = RacingForgeCLICommandRunner()
        let credential = try await GitHubCLIAccountBroker(runner: runner).brokerForExplicitAddAccount()

        XCTAssertEqual(credential.accountID.value, "node-token-account")
        XCTAssertEqual(credential.login, "token-account")
        XCTAssertFalse(String(describing: credential).contains("token-account-secret"))
        XCTAssertFalse(String(reflecting: credential).contains("token-account-secret"))
        XCTAssertTrue(credential.customMirror.children.isEmpty)
        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].arguments, ["gh", "auth", "token", "--hostname", "github.com"])
        XCTAssertNil(commands[0].secretEnvironment)
        XCTAssertEqual(commands[1].arguments, ["gh", "api", "--hostname", "github.com", "user"])
        XCTAssertEqual(
            commands[1].secretEnvironment?.withUnsafeValue { Data($0) },
            Data("token-account-secret".utf8)
        )
        XCTAssertFalse(commands[1].arguments.joined().contains("token-account-secret"))
        XCTAssertFalse(String(reflecting: commands[1]).contains("token-account-secret"))
    }

    func testSystemCLIRunnerCapturesOutputAndMapsLaunchFailureWithoutLeakingArguments() async throws {
        let runner = SystemForgeCLICommandRunner()
        let result = try await runner.run(ForgeCLICommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["runner-output"]
        ))
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput, Data("runner-output".utf8))
        XCTAssertEqual(result.standardError, Data())
        let environmentResult = try await runner.run(ForgeCLICommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s \"$GH_TOKEN\""],
            secretEnvironment: ForgeCLISecretEnvironment(
                name: "GH_TOKEN",
                value: Data("environment-secret".utf8)
            )
        ))
        XCTAssertEqual(environmentResult.standardOutput, Data("environment-secret".utf8))
        XCTAssertFalse(String(reflecting: environmentResult).contains("environment-secret"))
        do {
            _ = try await runner.run(ForgeCLICommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: [],
                secretEnvironment: ForgeCLISecretEnvironment(name: "GH_TOKEN", value: Data([0xFF]))
            ))
            XCTFail("non-UTF-8 secret material must fail before launch")
        } catch {
            XCTAssertEqual(error as? ForgeCLIBrokerError, .invalidTokenResponse)
        }
        let secretResult = ForgeCLICommandResult(
            standardOutput: Data("secret-standard-output".utf8),
            standardError: Data("secret-standard-error".utf8),
            terminationStatus: 23
        )
        XCTAssertFalse(String(describing: secretResult).contains("secret-standard"))
        XCTAssertFalse(String(reflecting: secretResult).contains("secret-standard"))
        XCTAssertTrue(secretResult.customMirror.children.isEmpty)

        do {
            _ = try await runner.run(ForgeCLICommand(
                executableURL: URL(fileURLWithPath: "/not/a/real/executable"),
                arguments: ["secret-argument"]
            ))
            XCTFail("an invalid executable must fail closed")
        } catch {
            XCTAssertEqual(error as? ForgeCLIBrokerError, .commandLaunchFailed)
            XCTAssertFalse(error.localizedDescription.contains("secret-argument"))
        }
    }

    func testSystemCLIRunnerCancellationPreventsLaunchAndTerminatesRunningChild() async throws {
        let runner = SystemForgeCLICommandRunner()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitx-cli-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = """
        printf '%s' "$$" > "$1"
        printf '%s' "$GH_TOKEN" >&2
        trap 'exit 0' TERM INT
        while :; do :; done
        """
        let secret = "cancellation-secret"

        let preventedMarker = directory.appendingPathComponent("prevented.pid")
        let preventedCommand = ForgeCLICommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "gitx-cancellation-test", preventedMarker.path],
            secretEnvironment: ForgeCLISecretEnvironment(name: "GH_TOKEN", value: Data(secret.utf8))
        )
        let gate = AsyncStream<Void>.makeStream()
        let preventedTask = Task {
            for await _ in gate.stream {
                break
            }
            return try await runner.run(preventedCommand)
        }
        preventedTask.cancel()
        gate.continuation.yield(())
        gate.continuation.finish()
        do {
            _ = try await preventedTask.value
            XCTFail("cancellation before launch must not start a child process")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: preventedMarker.path))
        XCTAssertFalse(String(reflecting: preventedCommand).contains(secret))

        let runningMarker = directory.appendingPathComponent("running.pid.fifo")
        XCTAssertEqual(mkfifo(runningMarker.path, mode_t(S_IRUSR | S_IWUSR)), 0)
        let runningCommand = ForgeCLICommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "gitx-cancellation-test", runningMarker.path],
            secretEnvironment: ForgeCLISecretEnvironment(name: "GH_TOKEN", value: Data(secret.utf8))
        )
        async let observedProcessID = ForgeAccountLifecycleTests.readProcessID(fromFIFO: runningMarker)
        let runningTask = Task { try await runner.run(runningCommand) }
        let launchedProcessID = try await observedProcessID
        var processRequiresCleanup = true
        defer {
            if processRequiresCleanup {
                _ = kill(launchedProcessID, SIGKILL)
                for _ in 0 ..< 100 {
                    errno = 0
                    guard kill(launchedProcessID, 0) == 0 || errno != ESRCH else { break }
                    usleep(10000)
                }
            }
        }

        runningTask.cancel()
        do {
            _ = try await runningTask.value
            XCTFail("cancellation after launch must surface as CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("cancellation must not be reclassified: \(error.localizedDescription)")
        }
        errno = 0
        let probeResult = kill(launchedProcessID, 0)
        let probeError = errno
        XCTAssertEqual(probeResult, -1, "the cancelled CLI child must be fully reaped")
        XCTAssertEqual(probeError, ESRCH)
        processRequiresCleanup = probeResult != -1 || probeError != ESRCH
        XCTAssertFalse(String(reflecting: runningCommand).contains(secret))
    }

    func testAddAccountCoordinatorDelegatesPATAndSharedAvatarCleanupIsANoOp() async throws {
        let keychain = LifecycleKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let coordinator = ForgeAddAccountCoordinator(
            accountStore: store,
            cliBroker: GitHubCLIAccountBroker(runner: StubForgeCLICommandRunner(results: []))
        )
        let accountID = try makeAccountID("pat-account")

        let account = try await coordinator.addPersonalAccessToken(
            accountID: accountID,
            login: "pat-user",
            credentialID: ForgeCredentialID("fine-grained-pat"),
            kind: .fineGrained,
            token: Data("pat-token".utf8),
            expiresAt: nil
        )

        XCTAssertEqual(account.id, accountID)
        XCTAssertEqual(account.currentCredential.source, .fineGrainedPersonalAccessToken)
        try await PreservingSharedForgeAvatarCleaner().removeAccountAssociations(for: accountID)
        let defaults = try makeDefaults()
        try ForgeRepositoryBindingAccountCleaner(userDefaults: defaults).removeBindings(for: accountID)
        XCTAssertNil(defaults.dictionary(forKey: ForgeRepositoryBindingAccountCleaner.repositorySettingsKey))
    }

    func testAccountsServiceExercisesExplicitCLILifecycleAndConfigurationBoundaries() async throws {
        AccountsGitHubURLProtocol.setHandler { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let suffix = if authorization.contains("classic-service-token") {
                "classic"
            } else if authorization.contains("default-service-token") {
                "default"
            } else {
                "fine"
            }
            return try (
                200,
                ["X-OAuth-Scopes": "repo", "X-RateLimit-Remaining": "4999"],
                JSONSerialization.data(withJSONObject: [
                    "node_id": "service-pat-\(suffix)",
                    "login": "\(suffix)-user",
                    "id": suffix == "classic" ? 41 : suffix == "fine" ? 42 : 43,
                ]),
                XCTUnwrap(URL(string: "https://api.github.com/user"))
            )
        }
        defer { AccountsGitHubURLProtocol.setHandler(nil) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeAccountsServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try makeDefaults()
        let runner = try StubForgeCLICommandRunner(results: [
            ForgeCLICommandResult(
                standardOutput: Data("service-cli-token\n".utf8),
                standardError: Data(),
                terminationStatus: 0
            ),
            ForgeCLICommandResult(
                standardOutput: JSONSerialization.data(withJSONObject: [
                    "node_id": "service-cli-account",
                    "login": "service-user",
                ]),
                standardError: Data(),
                terminationStatus: 0
            ),
        ])
        let services = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: directory,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
            keychain: LifecycleKeychain(),
            cliRunner: runner
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AccountsGitHubURLProtocol.self]
        let service = ForgeAccountsService(
            services: services,
            configuration: nil,
            authenticationTransport: GitHubAuthenticationTransport(sessionConfiguration: sessionConfiguration),
            credentialIDProvider: { kind, label in
                try ForgeCredentialID("service-\(kind.rawValue)-\(label ?? "unlabeled")")
            }
        )
        let date = Date(timeIntervalSince1970: 3_000_000)

        let initiallyEmptyAccounts = try await service.accounts(refreshingExpiringCredentialsAt: date)
        XCTAssertEqual(initiallyEmptyAccounts, [])
        await XCTAssertThrowsErrorAsync(try await service.beginDeviceFlow(receivedAt: date)) { error in
            XCTAssertEqual(error as? ForgeAccountsError, .githubApplicationNotConfigured)
        }
        await XCTAssertThrowsErrorAsync(try await service.pollDeviceFlow(receivedAt: date)) { error in
            XCTAssertEqual(error as? ForgeAccountsError, .deviceFlowNotStarted)
        }
        await XCTAssertThrowsErrorAsync(try await service.completeDeviceFlow(receivedAt: date)) { error in
            XCTAssertEqual(error as? ForgeAccountsError, .deviceFlowNotStarted)
        }
        await XCTAssertThrowsErrorAsync(try await service.githubApplicationInstallationURL()) { error in
            XCTAssertEqual(error as? ForgeAccountsError, .githubApplicationNotConfigured)
        }

        let added = try await service.addUsingExplicitGitHubCLIBrokerage()
        XCTAssertEqual(added.login, "service-user")
        XCTAssertEqual(added.currentCredential.source, .commandLineBroker)
        let storedAccounts = try await service.accounts(refreshingExpiringCredentialsAt: date)
        let emptyWatches = try await service.attentionWatches()
        XCTAssertEqual(storedAccounts, [added])
        XCTAssertEqual(emptyWatches, [])

        let classic = try await service.addPersonalAccessToken(
            ForgePersonalAccessTokenAcquisition(
                kind: .classic,
                token: Data("classic-service-token".utf8),
                label: "desktop"
            ),
            receivedAt: date
        )
        let fine = try await service.addPersonalAccessToken(
            ForgePersonalAccessTokenAcquisition(
                kind: .fineGrained,
                token: Data("fine-service-token".utf8),
                label: "laptop"
            ),
            receivedAt: date
        )
        XCTAssertEqual(classic.login, "classic-user")
        XCTAssertEqual(classic.currentCredential.source, .classicPersonalAccessToken)
        XCTAssertEqual(fine.login, "fine-user")
        XCTAssertEqual(fine.currentCredential.source, .fineGrainedPersonalAccessToken)
        let defaultCredentialService = ForgeAccountsService(
            services: services,
            configuration: nil,
            authenticationTransport: GitHubAuthenticationTransport(sessionConfiguration: sessionConfiguration)
        )
        let updatedFine = try await defaultCredentialService.addPersonalAccessToken(
            ForgePersonalAccessTokenAcquisition(
                kind: .fineGrained,
                token: Data("default-service-token".utf8),
                label: "mobile:test"
            ),
            receivedAt: date
        )
        XCTAssertNotEqual(updatedFine.id, fine.id)
        XCTAssertEqual(updatedFine.login, "default-user")
        XCTAssertTrue(updatedFine.currentCredential.reference.credentialID.value.contains("mobile-test"))

        let repository = try ForgeRepositoryIdentity(
            forge: added.id.forge,
            owner: "hbmartin",
            name: "gitx"
        )
        let watchKey = try ForgeWatchedRepositoryKey(accountID: added.id, repository: repository)
        let secondaryRepository = try ForgeRepositoryIdentity(
            forge: added.id.forge,
            owner: "aardvark",
            name: "notes"
        )
        let secondaryWatchKey = try ForgeWatchedRepositoryKey(
            accountID: added.id,
            repository: secondaryRepository
        )
        let classicRepository = try ForgeRepositoryIdentity(
            forge: classic.id.forge,
            owner: "alpha",
            name: "project"
        )
        let classicWatchKey = try ForgeWatchedRepositoryKey(
            accountID: classic.id,
            repository: classicRepository
        )
        let persistence = try ForgeSQLiteAttentionPersistence(store: XCTUnwrap(services.database))
        try await persistence.save(ForgeWatchedRepository(
            key: watchKey,
            addedAt: date,
            source: .repositoryOpened
        ))
        try await persistence.save(ForgeWatchedRepository(
            key: secondaryWatchKey,
            addedAt: date,
            source: .preferences
        ))
        try await persistence.save(ForgeWatchedRepository(
            key: classicWatchKey,
            addedAt: date,
            source: .preferences,
            includesBotReplies: true,
            baselineEstablishedAt: date,
            lastSuccessfulPollAt: date
        ))
        var watches = try await service.attentionWatches()
        XCTAssertEqual(watches.map(\.accountLogin), ["classic-user", "service-user", "service-user"])
        XCTAssertEqual(watches.map(\.repositoryName), ["alpha/project", "aardvark/notes", "hbmartin/gitx"])
        XCTAssertEqual(watches.map(\.includesBotReplies), [true, false, false])

        try await service.setAttentionBotReplies(true, for: watchKey)
        watches = try await service.attentionWatches()
        XCTAssertTrue(try XCTUnwrap(watches.first { $0.key == watchKey }).includesBotReplies)
        try await service.removeAttentionWatch(classicWatchKey)
        watches = try await service.attentionWatches()
        XCTAssertEqual(watches.map(\.key), [secondaryWatchKey, watchKey])
        try await service.removeAttentionWatch(secondaryWatchKey)
        try await service.removeAttentionWatch(watchKey)
        await XCTAssertThrowsErrorAsync(try await service.setAttentionBotReplies(true, for: watchKey)) { error in
            XCTAssertEqual(error as? ForgeAttentionInboxError, .missingWatchedRepository)
        }
        try await service.removeAccount(added.id)
        try await service.removeAccount(classic.id)
        try await service.removeAccount(fine.id)
        try await service.removeAccount(updatedFine.id)
        let removedAccounts = try await service.accounts(refreshingExpiringCredentialsAt: date)
        XCTAssertEqual(removedAccounts, [])
    }

    func testAccountsServiceChecksGitHubAppCredentialRefreshAndRetainsAccountsAfterFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeAccountsRefreshTests-\(UUID().uuidString)", isDirectory: true)
        let defaults = try makeDefaults()
        let baseServices = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: directory,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
            keychain: LifecycleKeychain(),
            cliRunner: StubForgeCLICommandRunner(results: [])
        )
        addTeardownBlock {
            await baseServices.refreshCoordinator?.invalidate()
            await baseServices.database?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let date = Date(timeIntervalSince1970: 4_000_000)
        let account = try await baseServices.accountStore.addAccount(
            accountID: makeAccountID("accounts-refresh-failure"),
            login: "refresh-user",
            credentialID: ForgeCredentialID("github-app-refresh"),
            source: .forgeApplicationDeviceFlow,
            expiresAt: date.addingTimeInterval(60),
            secrets: ForgeCredentialSecretMaterial(
                accessToken: Data("expiring-access".utf8),
                refreshToken: Data("refresh-token".utf8),
                refreshTokenExpiresAt: date.addingTimeInterval(3600)
            )
        )
        let configuration = try GitHubAppDeviceFlowConfiguration(
            clientID: "Iv1ABC123",
            applicationSlug: "gitx-test"
        )
        let refresher = FailingAccountsCredentialRefresher()
        let refreshCoordinator = ForgeAccountCredentialRefreshCoordinator(
            accountStore: baseServices.accountStore,
            configuration: configuration,
            refresherFactory: { _ in refresher }
        )
        let authority = ForgeGitHubReadCredentialAuthority(
            accountStore: baseServices.accountStore,
            credentialRefreshCoordinator: refreshCoordinator,
            now: { date }
        )
        let services = ForgeApplicationServices(
            dataAvailability: baseServices.dataAvailability,
            accountStore: baseServices.accountStore,
            addAccountCoordinator: baseServices.addAccountCoordinator,
            removalCoordinator: baseServices.removalCoordinator,
            githubReadAdapterFactory: ForgeGitHubReadAdapterFactory(credentialAuthority: authority),
            githubAnonymousRESTBudget: baseServices.githubAnonymousRESTBudget,
            deferredAccountCleanup: baseServices.deferredAccountCleanup,
            recoveryCoordinator: baseServices.recoveryCoordinator
        )
        let service = ForgeAccountsService(
            services: services,
            configuration: configuration
        )

        let accounts = try await service.accounts(refreshingExpiringCredentialsAt: date)

        XCTAssertEqual(accounts, [account])
        let refreshCallCount = await refresher.callCount()
        XCTAssertEqual(refreshCallCount, 1)
    }

    func testBindingProviderDiscoversValidPersistedBindingsOnceInStableOrder() throws {
        let defaults = try makeDefaults()
        let provider = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)
        XCTAssertTrue(provider.forgeRepositoryBindings().isEmpty)
        let accountID = try makeAccountID("bound-account")
        let firstRepository = try ForgeRepositoryIdentity(
            forge: accountID.forge,
            owner: "alpha",
            name: "first"
        )
        let secondRepository = try ForgeRepositoryIdentity(
            forge: accountID.forge,
            owner: "beta",
            name: "second"
        )
        let first = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: firstRepository,
            preferredAccount: accountID
        )
        let second = try ForgeRepositoryBinding(
            localRemoteName: "upstream",
            primaryRepository: secondRepository,
            preferredAccount: accountID
        )
        try defaults.set([
            "second": [ForgeRepositoryBindingAccountCleaner.forgeBindingKey: JSONEncoder().encode(second)],
            "first": [ForgeRepositoryBindingAccountCleaner.forgeBindingKey: JSONEncoder().encode(first)],
            "duplicate": [ForgeRepositoryBindingAccountCleaner.forgeBindingKey: JSONEncoder().encode(first)],
            "invalid": [ForgeRepositoryBindingAccountCleaner.forgeBindingKey: Data([0x00])],
            "unrelated": "value",
        ], forKey: ForgeRepositoryBindingAccountCleaner.repositorySettingsKey)

        XCTAssertEqual(provider.forgeRepositoryBindings(), [first, second])
    }

    func testRemovalDeletesAccountScopedStateAndPreservesTrustedOriginsAndOtherBindings() async throws {
        let defaults = try makeDefaults()
        let keychain = LifecycleKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let targetID = try makeAccountID("target")
        let otherID = try makeAccountID("other")
        _ = try await store.addPersonalAccessToken(
            accountID: targetID,
            login: "target-login",
            credentialID: ForgeCredentialID("target-pat"),
            kind: .fineGrained,
            token: Data("target-token".utf8),
            expiresAt: nil
        )
        _ = try await store.addPersonalAccessToken(
            accountID: otherID,
            login: "other-login",
            credentialID: ForgeCredentialID("other-pat"),
            kind: .classic,
            token: Data("other-token".utf8),
            expiresAt: nil
        )

        let repository = try ForgeRepositoryIdentity(
            forge: targetID.forge,
            owner: "example",
            name: "repository"
        )
        let targetBinding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository,
            preferredAccount: targetID
        )
        let otherBinding = try ForgeRepositoryBinding(
            localRemoteName: "upstream",
            primaryRepository: repository,
            preferredAccount: otherID
        )
        try defaults.set([
            "target-repository": [
                "forgeRepositoryBinding": JSONEncoder().encode(targetBinding),
                "selectedTab": "history",
            ],
            "other-repository": [
                "forgeRepositoryBinding": JSONEncoder().encode(otherBinding),
            ],
        ], forKey: "PBRepositoryUISettings")
        let trustedOrigins = ["https://docs.example.com"]
        defaults.set(trustedOrigins, forKey: "PBForgeTrustedExternalOrigins")

        let persistence = RecordingPersistenceCleaner()
        let avatars = RecordingAvatarCleaner()
        let coordinator = ForgeAccountRemovalCoordinator(
            accountStore: store,
            persistenceCleaner: persistence,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
            avatarCleaner: avatars
        )
        try await coordinator.removeAccount(targetID)

        let removedCredential = try await store.credential(for: targetID)
        let retainedCredential = try await store.credential(for: otherID)
        let persistedRemovals = await persistence.removedAccounts()
        let avatarRemovals = await avatars.removedAccounts()
        XCTAssertNil(removedCredential)
        XCTAssertNotNil(retainedCredential)
        XCTAssertEqual(persistedRemovals, [targetID])
        XCTAssertEqual(avatarRemovals, [targetID])
        let repositorySettings = try XCTUnwrap(defaults.dictionary(forKey: "PBRepositoryUISettings"))
        let targetSettings = try XCTUnwrap(repositorySettings["target-repository"] as? [String: Any])
        XCTAssertNil(targetSettings["forgeRepositoryBinding"])
        XCTAssertEqual(targetSettings["selectedTab"] as? String, "history")
        let otherSettings = try XCTUnwrap(repositorySettings["other-repository"] as? [String: Any])
        XCTAssertNotNil(otherSettings["forgeRepositoryBinding"])
        XCTAssertEqual(defaults.stringArray(forKey: "PBForgeTrustedExternalOrigins"), trustedOrigins)
    }

    func testRemovalStopsBeforeStateCleanupWhenKeychainRemovalFails() async throws {
        let defaults = try makeDefaults()
        let keychain = LifecycleKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("target")
        _ = try await store.addPersonalAccessToken(
            accountID: accountID,
            login: "target-login",
            credentialID: ForgeCredentialID("pat"),
            kind: .classic,
            token: Data("token".utf8),
            expiresAt: nil
        )
        keychain.failure = .interactionNotAllowed(operation: .remove)
        let persistence = RecordingPersistenceCleaner()
        let avatars = RecordingAvatarCleaner()
        let coordinator = ForgeAccountRemovalCoordinator(
            accountStore: store,
            persistenceCleaner: persistence,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
            avatarCleaner: avatars
        )

        do {
            try await coordinator.removeAccount(accountID)
            XCTFail("state cleanup must not proceed while a Credential remains usable")
        } catch {
            XCTAssertEqual(
                error as? ForgeCredentialStoreError,
                .keychain(.interactionNotAllowed(operation: .remove))
            )
        }
        let persistedRemovals = await persistence.removedAccounts()
        let avatarRemovals = await avatars.removedAccounts()
        XCTAssertEqual(persistedRemovals, [])
        XCTAssertEqual(avatarRemovals, [])
    }

    private func makeAccountID(_ value: String) throws -> ForgeAccountID {
        try ForgeAccountID(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            value: value
        )
    }

    private func makeAccount(
        id: ForgeAccountID,
        login: String,
        source: ForgeCredentialSource,
        expiresAt: Date?
    ) throws -> ForgeAccount {
        try ForgeAccount(
            id: id,
            login: login,
            currentCredential: ForgeCredentialMetadata(
                reference: ForgeCredentialReference(
                    accountID: id,
                    credentialID: ForgeCredentialID("credential-\(id.value)"),
                    generation: ForgeCredentialGeneration(1)
                ),
                source: source,
                expiresAt: expiresAt
            )
        )
    }

    @MainActor
    private func accessibilityIdentifiers(in root: NSView) -> Set<String> {
        Set(
            [root.accessibilityIdentifier()].compactMap(\.self)
                + root.subviews.flatMap { Array(accessibilityIdentifiers(in: $0)) }
        )
    }

    @MainActor
    private func descendant(identifier: String, in root: NSView?) -> NSView? {
        guard let root else { return nil }
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        for subview in root.subviews {
            if let match = descendant(identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func settleMainActor() async {
        for _ in 0 ..< 5 {
            await Task.yield()
        }
    }

    @MainActor
    private func makePreferencesWindow(contentView: ForgeAccountsPreferencesView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 880),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        return window
    }

    @MainActor
    private func populatePersonalAccessToken(in alert: NSAlert, token: String, label: String) {
        let fields = descendants(in: alert.accessoryView).compactMap { $0 as? NSTextField }
        let tokenField = fields.first { $0 is NSSecureTextField }
        let labelField = fields.first { $0.placeholderString == "Optional label" }
        tokenField?.stringValue = token
        labelField?.stringValue = label
    }

    @MainActor
    private func assertPersonalAccessTokenAlertLayout(
        _ alert: NSAlert,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let accessory = alert.accessoryView else {
            return XCTFail("Personal access token fields are unavailable", file: file, line: line)
        }
        let fittingSize = accessory.fittingSize
        XCTAssertGreaterThanOrEqual(
            accessory.bounds.width,
            ceil(fittingSize.width),
            "The accessory must materialize its complete fitting width",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            accessory.bounds.height,
            ceil(fittingSize.height),
            "The accessory must materialize its complete fitting height",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            alert.window.frame.width,
            fittingSize.width + 32,
            "The alert must contain the complete token and label fields without clipping",
            file: file,
            line: line
        )
        let fields = descendants(in: accessory).compactMap { $0 as? NSTextField }
        for field in fields where field is NSSecureTextField || field.placeholderString == "Optional label" {
            XCTAssertTrue(
                accessory.bounds.contains(field.convert(field.bounds, to: accessory)),
                "Every editable field must remain inside the accessory bounds",
                file: file,
                line: line
            )
        }
        guard let contentView = alert.window.contentView,
              let informativeText = descendants(in: contentView)
              .compactMap({ $0 as? NSTextField })
              .first(where: { $0.stringValue.hasPrefix("GitX validates the Credential") })
        else {
            return XCTFail("Personal access token explanation is unavailable", file: file, line: line)
        }
        let accessoryFrame = accessory.convert(accessory.bounds, to: contentView)
        let informativeFrame = informativeText.convert(informativeText.bounds, to: contentView)
        XCTAssertLessThanOrEqual(
            accessoryFrame.maxY + 8,
            informativeFrame.minY,
            "The complete fields must remain below the explanatory text",
            file: file,
            line: line
        )
    }

    @MainActor
    private func attachScreenshot(
        of view: NSView?,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let view else {
            XCTFail("Diagnostic screenshot view is unavailable", file: file, line: line)
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Diagnostic screenshot could not allocate a bitmap", file: file, line: line)
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func descendants(in root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { descendants(in: $0) }
    }

    @MainActor
    private func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "ForgeAccountLifecycleTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            throw XCTSkip("could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private nonisolated static func readProcessID(fromFIFO url: URL) async throws -> pid_t {
        // swift6-safety-justification: The detached worker exclusively owns the blocking FIFO descriptor until EOF.
        try await Task.detached(priority: .userInitiated) {
            let descriptor = open(url.path, O_RDONLY)
            guard descriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { close(descriptor) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 32)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
            guard let text = String(data: data, encoding: .utf8),
                  let processID = pid_t(text)
            else {
                throw ForgeCLIProcessTestError.invalidProcessID
            }
            return processID
        }.value
    }
}

private enum ForgeCLIProcessTestError: Error {
    case invalidProcessID
}

private actor PreferencesAccountsClientDouble: ForgeAccountsClient {
    private let configuredAccounts: [ForgeAccount]
    private var configuredWatches: [ForgeAttentionWatchPreferencesRow]
    private let installationURL: URL
    private var accountLoadCount = 0
    private var cliAdds = 0
    private var botReplies: [Bool] = []
    private var removed: [ForgeWatchedRepositoryKey] = []

    init(
        accounts: [ForgeAccount],
        watches: [ForgeAttentionWatchPreferencesRow],
        installationURL: URL
    ) {
        configuredAccounts = accounts
        configuredWatches = watches
        self.installationURL = installationURL
    }

    func accounts(refreshingExpiringCredentialsAt _: Date) async throws -> [ForgeAccount] {
        accountLoadCount += 1
        return configuredAccounts
    }

    func beginDeviceFlow(receivedAt _: Date) async throws -> GitHubDeviceAuthorization {
        throw ForgeAccountsError.deviceFlowFailed
    }

    func pollDeviceFlow(receivedAt _: Date) async throws -> GitHubDeviceFlowPollResult {
        throw ForgeAccountsError.deviceFlowFailed
    }

    func completeDeviceFlow(receivedAt _: Date) async throws -> ForgeAccount {
        throw ForgeAccountsError.deviceFlowFailed
    }

    func addUsingExplicitGitHubCLIBrokerage() async throws -> ForgeAccount {
        cliAdds += 1
        return configuredAccounts[0]
    }

    func addPersonalAccessToken(
        _: ForgePersonalAccessTokenAcquisition,
        receivedAt _: Date
    ) async throws -> ForgeAccount {
        configuredAccounts[0]
    }

    func removeAccount(_: ForgeAccountID) async throws {}

    func githubApplicationInstallationURL() async throws -> URL {
        installationURL
    }

    func attentionWatches() async throws -> [ForgeAttentionWatchPreferencesRow] {
        configuredWatches
    }

    func setAttentionBotReplies(_ enabled: Bool, for key: ForgeWatchedRepositoryKey) async throws {
        botReplies.append(enabled)
        if let index = configuredWatches.firstIndex(where: { $0.key == key }) {
            let current = configuredWatches[index]
            configuredWatches[index] = ForgeAttentionWatchPreferencesRow(
                key: key,
                accountLogin: current.accountLogin,
                repositoryName: current.repositoryName,
                includesBotReplies: enabled
            )
        }
    }

    func removeAttentionWatch(_ key: ForgeWatchedRepositoryKey) async throws {
        removed.append(key)
        configuredWatches.removeAll { $0.key == key }
    }

    func accountLoads() -> Int {
        accountLoadCount
    }

    func cliAdditionCount() -> Int {
        cliAdds
    }

    func botReplyUpdateCount() -> Int {
        botReplies.count
    }

    func watchRemovalCount() -> Int {
        removed.count
    }

    func botReplyUpdates() -> [Bool] {
        botReplies
    }

    func removedWatches() -> [ForgeWatchedRepositoryKey] {
        removed
    }
}

private enum PreferencesClientOperation: Hashable, Sendable {
    case accounts
    case installationURL
    case beginDeviceFlow
    case pollDeviceFlow
    case completeDeviceFlow
    case cli
    case personalAccessToken
    case removeAccount
    case watches
    case botReplies
    case removeWatch
}

private enum PreferencesClientFailure: String, LocalizedError, Sendable {
    case accounts
    case installationURL
    case beginDeviceFlow
    case pollDeviceFlow
    case completeDeviceFlow
    case cli
    case personalAccessToken
    case removeAccount
    case watches
    case botReplies
    case removeWatch

    var errorDescription: String? {
        "Injected Forge Accounts client failure: \(rawValue)"
    }
}

private actor PreferencesFailureClientDouble: ForgeAccountsClient {
    private let account: ForgeAccount
    private let watch: ForgeAttentionWatchPreferencesRow?
    private let installationURL: URL
    private let authorization: GitHubDeviceAuthorization
    private var failures: Set<PreferencesClientOperation> = []
    private var cancellations: Set<PreferencesClientOperation> = []
    private var calls: [PreferencesClientOperation: Int] = [:]
    private var acquisitions: [ForgePersonalAccessTokenAcquisition] = []
    private var pollResults: [GitHubDeviceFlowPollResult] = []
    private var personalAccessTokenAuthorizationFailures: [GitHubRESTAuthorizationFailure] = []

    init(
        account: ForgeAccount,
        watch: ForgeAttentionWatchPreferencesRow?,
        installationURL: URL,
        authorization: GitHubDeviceAuthorization
    ) {
        self.account = account
        self.watch = watch
        self.installationURL = installationURL
        self.authorization = authorization
    }

    func setFailure(_ operation: PreferencesClientOperation, enabled: Bool) {
        if enabled {
            failures.insert(operation)
        } else {
            failures.remove(operation)
        }
    }

    func setCancellation(_ operation: PreferencesClientOperation, enabled: Bool) {
        if enabled {
            cancellations.insert(operation)
        } else {
            cancellations.remove(operation)
        }
    }

    func setPollResults(_ results: [GitHubDeviceFlowPollResult]) {
        pollResults = results
    }

    func setPersonalAccessTokenAuthorizationFailures(_ failures: [GitHubRESTAuthorizationFailure]) {
        personalAccessTokenAuthorizationFailures = failures
    }

    func accounts(refreshingExpiringCredentialsAt _: Date) async throws -> [ForgeAccount] {
        try record(.accounts)
        return [account]
    }

    func beginDeviceFlow(receivedAt _: Date) async throws -> GitHubDeviceAuthorization {
        try record(.beginDeviceFlow)
        return authorization
    }

    func pollDeviceFlow(receivedAt _: Date) async throws -> GitHubDeviceFlowPollResult {
        try record(.pollDeviceFlow)
        guard !pollResults.isEmpty else { return .expired }
        return pollResults.removeFirst()
    }

    func completeDeviceFlow(receivedAt _: Date) async throws -> ForgeAccount {
        try record(.completeDeviceFlow)
        return account
    }

    func addUsingExplicitGitHubCLIBrokerage() async throws -> ForgeAccount {
        try record(.cli)
        return account
    }

    func addPersonalAccessToken(
        _ acquisition: ForgePersonalAccessTokenAcquisition,
        receivedAt _: Date
    ) async throws -> ForgeAccount {
        acquisitions.append(acquisition)
        try record(.personalAccessToken)
        if !personalAccessTokenAuthorizationFailures.isEmpty {
            throw GitHubAuthenticationTransportError.authorizationFailure(
                personalAccessTokenAuthorizationFailures.removeFirst()
            )
        }
        return account
    }

    func removeAccount(_: ForgeAccountID) async throws {
        try record(.removeAccount)
    }

    func githubApplicationInstallationURL() async throws -> URL {
        try record(.installationURL)
        return installationURL
    }

    func attentionWatches() async throws -> [ForgeAttentionWatchPreferencesRow] {
        try record(.watches)
        return [watch].compactMap(\.self)
    }

    func setAttentionBotReplies(_: Bool, for _: ForgeWatchedRepositoryKey) async throws {
        try record(.botReplies)
    }

    func removeAttentionWatch(_: ForgeWatchedRepositoryKey) async throws {
        try record(.removeWatch)
    }

    func callCount(for operation: PreferencesClientOperation) -> Int {
        calls[operation, default: 0]
    }

    func personalAccessTokenAcquisitions() -> [ForgePersonalAccessTokenAcquisition] {
        acquisitions
    }

    private func record(_ operation: PreferencesClientOperation) throws {
        calls[operation, default: 0] += 1
        if cancellations.contains(operation) {
            throw CancellationError()
        }
        guard failures.contains(operation) else { return }
        throw PreferencesClientFailure(rawValue: String(describing: operation)) ?? .accounts
    }
}

@MainActor
private final class ScopedAlertRunModalDriver {
    typealias Handler = @MainActor (NSAlert) -> NSApplication.ModalResponse

    private weak static var active: ScopedAlertRunModalDriver?
    private var handlers: [Handler] = []
    private var isInstalled = false
    private(set) var openedURLs: [URL] = []

    init() {
        precondition(Self.active == nil, "only one scoped NSAlert interceptor may be active")
        guard let original = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal)),
              let replacement = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.gitxTest_runModal)),
              let workspaceOriginal = class_getInstanceMethod(NSWorkspace.self, NSSelectorFromString("openURL:")),
              let workspaceReplacement = class_getInstanceMethod(
                  NSWorkspace.self,
                  #selector(NSWorkspace.gitxTest_open(_:))
              )
        else {
            preconditionFailure("AppKit modal and URL-opening methods must be visible to the Objective-C runtime")
        }
        Self.active = self
        method_exchangeImplementations(original, replacement)
        method_exchangeImplementations(workspaceOriginal, workspaceReplacement)
        isInstalled = true
    }

    var pendingResponseCount: Int {
        handlers.count
    }

    func enqueue(
        _ response: NSApplication.ModalResponse,
        configure: @escaping @MainActor (NSAlert) -> Void = { _ in }
    ) {
        handlers.append { alert in
            configure(alert)
            return response
        }
    }

    func restore() {
        guard isInstalled,
              let original = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal)),
              let replacement = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.gitxTest_runModal)),
              let workspaceOriginal = class_getInstanceMethod(NSWorkspace.self, NSSelectorFromString("openURL:")),
              let workspaceReplacement = class_getInstanceMethod(
                  NSWorkspace.self,
                  #selector(NSWorkspace.gitxTest_open(_:))
              )
        else {
            return
        }
        method_exchangeImplementations(original, replacement)
        method_exchangeImplementations(workspaceOriginal, workspaceReplacement)
        Self.active = nil
        isInstalled = false
    }

    fileprivate static func nextResponse(for alert: NSAlert) -> NSApplication.ModalResponse {
        guard let active else {
            XCTFail("NSAlert interception invoked without an active response driver")
            return .alertSecondButtonReturn
        }
        guard !active.handlers.isEmpty else {
            XCTFail("NSAlert presented without a queued test response: \(alert.messageText)")
            return .alertSecondButtonReturn
        }
        return active.handlers.removeFirst()(alert)
    }

    fileprivate static func recordOpen(_ url: URL) -> Bool {
        guard let active else {
            XCTFail("NSWorkspace interception invoked without an active response driver")
            return false
        }
        active.openedURLs.append(url)
        return true
    }
}

private extension NSAlert {
    @objc func gitxTest_runModal() -> NSApplication.ModalResponse {
        ScopedAlertRunModalDriver.nextResponse(for: self)
    }
}

private extension NSWorkspace {
    @objc func gitxTest_open(_ url: URL) -> Bool {
        // swift6-safety-justification: NSWorkspace.open is invoked synchronously by this main-actor AppKit view test.
        MainActor.assumeIsolated {
            ScopedAlertRunModalDriver.recordOpen(url)
        }
    }
}

// swift6-safety-justification: URLProtocol owns request delivery while all shared test state is serialized by lock.
private final class AccountsGitHubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data, URL)

    private static let lock = NSLock()
    // swift6-safety-justification: Every access to the test handler is serialized by the adjacent static lock.
    private nonisolated(unsafe) static var handler: Handler?

    static func setHandler(_ handler: Handler?) {
        lock.withLock {
            self.handler = handler
        }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let handler = Self.lock.withLock { Self.handler }
            let (statusCode, headers, data, responseURL) = try XCTUnwrap(handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: responseURL,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor StubForgeCLICommandRunner: ForgeCLICommandRunning {
    private var results: [ForgeCLICommandResult]
    private var recordedCommands: [ForgeCLICommand] = []

    init(results: [ForgeCLICommandResult]) {
        self.results = results
    }

    func run(_ command: ForgeCLICommand) async throws -> ForgeCLICommandResult {
        recordedCommands.append(command)
        guard !results.isEmpty else {
            throw ForgeCLIBrokerError.commandLaunchFailed
        }
        return results.removeFirst()
    }

    func commands() -> [ForgeCLICommand] {
        recordedCommands
    }
}

private actor MutatingCurrentCredentialRefresher: ForgeGitHubCredentialRefreshing {
    private let mutation: @Sendable () async throws -> Void

    init(mutation: @escaping @Sendable () async throws -> Void) {
        self.mutation = mutation
    }

    func refreshIfNeeded(
        _: GitHubRotatingUserCredential,
        at _: Date,
        minimumValidity _: TimeInterval
    ) async throws -> GitHubCredentialRefreshResult {
        try await mutation()
        return .current(refreshAt: Date(timeIntervalSince1970: 10000))
    }
}

private actor FailingAccountsCredentialRefresher: ForgeGitHubCredentialRefreshing {
    private var recordedCallCount = 0

    func refreshIfNeeded(
        _: GitHubRotatingUserCredential,
        at _: Date,
        minimumValidity _: TimeInterval
    ) async throws -> GitHubCredentialRefreshResult {
        recordedCallCount += 1
        throw ForgeAccountsError.deviceFlowFailed
    }

    func callCount() -> Int {
        recordedCallCount
    }
}

private actor RacingForgeCLICommandRunner: ForgeCLICommandRunning {
    private var recordedCommands: [ForgeCLICommand] = []

    func run(_ command: ForgeCLICommand) async throws -> ForgeCLICommandResult {
        recordedCommands.append(command)
        if recordedCommands.count == 1 {
            // Simulate the user switching the gh active account immediately after
            // token acquisition. The second command must not inherit that change.
            return ForgeCLICommandResult(
                standardOutput: Data("token-account-secret\n".utf8),
                standardError: Data(),
                terminationStatus: 0
            )
        }
        let authority = command.secretEnvironment?.withUnsafeValue { Data($0) }
        let identity = if authority == Data("token-account-secret".utf8) {
            #"{"node_id":"node-token-account","login":"token-account"}"#
        } else {
            #"{"node_id":"node-new-active-account","login":"new-active-account"}"#
        }
        return ForgeCLICommandResult(
            standardOutput: Data(identity.utf8),
            standardError: Data(),
            terminationStatus: 0
        )
    }

    func commands() -> [ForgeCLICommand] {
        recordedCommands
    }
}

private actor RecordingPersistenceCleaner: ForgeAccountPersistenceCleaning {
    private var accounts: [ForgeAccountID] = []

    func removeAccount(_ accountID: ForgeAccountID) async throws {
        accounts.append(accountID)
    }

    func removedAccounts() -> [ForgeAccountID] {
        accounts
    }
}

private actor RecordingAvatarCleaner: ForgeAccountAvatarCleaning {
    private var accounts: [ForgeAccountID] = []

    func removeAccountAssociations(for accountID: ForgeAccountID) async throws {
        accounts.append(accountID)
    }

    func removedAccounts() -> [ForgeAccountID] {
        accounts
    }
}

// swift6-safety-justification: The lock serializes all test-double storage and failure state.
private final nonisolated class LifecycleKeychain: ForgeCredentialKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    var failure: ForgeKeychainError?

    func data(for accountKey: String) throws -> Data? {
        try lock.withLock {
            if let failure {
                throw failure
            }
            return storage[accountKey]
        }
    }

    func allItems() throws -> [ForgeKeychainItem] {
        try lock.withLock {
            if let failure {
                throw failure
            }
            return storage.map(ForgeKeychainItem.init(accountKey:data:))
        }
    }

    func replace(_ data: Data, for accountKey: String) throws {
        try lock.withLock {
            if let failure {
                throw failure
            }
            storage[accountKey] = data
        }
    }

    func remove(accountKey: String) throws {
        try lock.withLock {
            if let failure {
                throw failure
            }
            storage.removeValue(forKey: accountKey)
        }
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
