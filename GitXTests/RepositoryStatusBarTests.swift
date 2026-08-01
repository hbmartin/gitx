import AppKit
import ForgeKit
import XCTest

@MainActor
final class RepositoryStatusBarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testContextualForgeAccountPresentationSeparatesIdentityFromPersistentFailureMirroring() {
        let authenticated = RepositoryForgeAccountControlPresentation(
            providerName: "GitHub",
            login: "hbmartin",
            isPublic: false,
            persistentFailureText: "Forge Unavailable",
            isStatusBarVisible: false
        )
        XCTAssertEqual(authenticated.title, "@hbmartin")
        XCTAssertEqual(authenticated.avatarInitials, "HB")
        XCTAssertEqual(authenticated.accessibilityLabel, "GitHub account, hbmartin")
        XCTAssertTrue(authenticated.showsPersistentFailure)

        let visibleStatusBar = RepositoryForgeAccountControlPresentation(
            providerName: "GitHub",
            login: nil,
            isPublic: true,
            persistentFailureText: "Forge Unavailable",
            isStatusBarVisible: true
        )
        XCTAssertEqual(visibleStatusBar.title, "Public")
        XCTAssertEqual(visibleStatusBar.avatarInitials, "P")
        XCTAssertFalse(visibleStatusBar.showsPersistentFailure)
    }

    func testContextualForgeAccountRebindingPresentationDistinguishesWaitingAndRetryPending() {
        let waiting = RepositoryForgeAccountRebindingPresentation.present(
            isEnabled: false,
            cooldownDeadline: now.addingTimeInterval(60),
            now: now
        )
        XCTAssertFalse(waiting.isEnabled)
        XCTAssertEqual(
            waiting.helpText,
            "Account changes are paused until GitHub’s rate-limit window ends."
        )

        let retryPending = RepositoryForgeAccountRebindingPresentation.present(
            isEnabled: false,
            cooldownDeadline: now.addingTimeInterval(-1),
            now: now
        )
        XCTAssertFalse(retryPending.isEnabled)
        XCTAssertEqual(
            retryPending.helpText,
            "Account changes are paused until a successful GitHub retry completes."
        )

        let available = RepositoryForgeAccountRebindingPresentation.present(
            isEnabled: true,
            cooldownDeadline: now.addingTimeInterval(60),
            now: now
        )
        XCTAssertTrue(available.isEnabled)
        XCTAssertEqual(
            available.helpText,
            "Choose the account for this repository or manage accounts"
        )
    }

    func testContextualForgeAccountRoutesDeterministicallyToAccountsPreferences() {
        let defaults = UserDefaults.standard
        let key = RepositoryForgeAccountsPreferencesRouting.selectedPaneDefaultsKey
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set("Diff & Text", forKey: key)

        RepositoryForgeAccountsPreferencesRouting.prepare()

        XCTAssertEqual(defaults.string(forKey: key), RepositoryForgeAccountsPreferencesRouting.accountsPaneIdentifier)
    }

    func testContextualForgeAccountSelectionPreservesBindingAndChangesOnlyPreferredAccount() throws {
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
        let original = try ForgeAccountID(forge: forge, value: "original")
        let replacement = try ForgeAccountID(forge: forge, value: "replacement")
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository,
            preferredAccount: original
        )

        let updated = try RepositoryForgeAccountSelection.updating(
            binding,
            preferredAccount: replacement
        )

        XCTAssertEqual(updated.localRemoteName, "origin")
        XCTAssertEqual(updated.primaryRepository, repository)
        XCTAssertEqual(updated.preferredAccount, replacement)
    }

    func testPorcelainParserCoversBranchDivergenceEveryWorkingStateAndRenameContinuation() {
        let records = [
            "# branch.oid 0123456789abcdef",
            "# branch.head feature/ü",
            "# branch.upstream origin/feature/ü",
            "# branch.ab +2 -3",
            "1 M. N... 100644 100644 100644 a b staged.swift",
            "1 .M N... 100644 100644 100644 a b unstaged.swift",
            "1 MM N... 100644 100644 100644 a b both.swift",
            "2 R. N... 100644 100644 100644 a b R100 renamed.swift",
            "? source-name-that-must-not-be-counted",
            "u UU N... 100644 100644 100644 100644 a b c conflict.swift",
            "? untracked file.txt",
            "! ignored.txt",
            "malformed",
        ]
        let snapshot = RepositoryPorcelainStatusParser.parse(
            nulData(records),
            operation: .merge
        )

        XCTAssertEqual(snapshot?.head, .branch(name: "feature/ü", unborn: false))
        XCTAssertEqual(snapshot?.ahead, 2)
        XCTAssertEqual(snapshot?.behind, 3)
        XCTAssertEqual(snapshot?.counts, RepositoryWorkingStateCounts(staged: 3, unstaged: 2, untracked: 1, conflicts: 1))
        XCTAssertEqual(snapshot?.operation, .merge)
    }

    func testPorcelainParserHandlesUnbornDetachedUnknownMalformedAndInvalidUTF8() {
        let unborn = RepositoryPorcelainStatusParser.parse(
            nulData(["# branch.oid (initial)", "# branch.head main", "# branch.ab +bad -bad"]),
            operation: nil
        )
        XCTAssertEqual(unborn?.head, .branch(name: "main", unborn: true))
        XCTAssertEqual(unborn?.ahead, 0)
        XCTAssertEqual(unborn?.behind, 0)

        let detached = RepositoryPorcelainStatusParser.parse(
            nulData(["# branch.oid abcdef0123456789", "# branch.head (detached)"]),
            operation: nil
        )
        XCTAssertEqual(detached?.head, .detached(commit: "abcdef01"))

        let detachedWithoutCommit = RepositoryPorcelainStatusParser.parse(
            nulData(["# branch.oid (initial)", "# branch.head (detached)"]),
            operation: nil
        )
        XCTAssertEqual(detachedWithoutCommit?.head, .detached(commit: nil))
        XCTAssertEqual(RepositoryPorcelainStatusParser.parse(Data(), operation: nil)?.head, .unknown)
        XCTAssertNil(RepositoryPorcelainStatusParser.parse(Data([0xFF]), operation: nil))
    }

    func testGitOperationDetectorUsesStablePriorityAndEveryOperation() {
        let root = URL(fileURLWithPath: "/repository/.git")
        let cases: [(Set<String>, RepositoryGitOperation?)] = [
            (["rebase-merge", "MERGE_HEAD"], .rebase),
            (["rebase-apply", "rebase-apply/applying"], .applyMailbox),
            (["rebase-apply"], .rebase),
            (["MERGE_HEAD"], .merge),
            (["CHERRY_PICK_HEAD"], .cherryPick),
            (["REVERT_HEAD"], .revert),
            (["BISECT_LOG"], .bisect),
            ([], nil),
        ]
        for (existing, expected) in cases {
            XCTAssertEqual(
                RepositoryGitOperationDetector.detect(gitDirectory: root) {
                    existing.contains(String($0.dropFirst(root.path.count + 1)))
                },
                expected
            )
        }
        XCTAssertEqual(Set(RepositoryGitOperation.allCases.map(\.displayText)).count, 6)
    }

    func testLocalPresenterPreservesBranchAndOperationWhileFormattingLowerPriorityCounts() {
        let snapshot = RepositoryLocalStatusSnapshot(
            head: .branch(name: "main", unborn: false),
            ahead: 2,
            behind: 1,
            counts: RepositoryWorkingStateCounts(staged: 1, unstaged: 2, untracked: 3, conflicts: 4),
            operation: .rebase
        )
        let presentation = RepositoryLocalStatusPresenter.present(snapshot, activityText: nil, isBusy: false)
        XCTAssertEqual(presentation.branchText, "main")
        XCTAssertEqual(presentation.aheadBehindText, "↑2 ↓1")
        XCTAssertEqual(presentation.countsText, "1 staged · 2 unstaged · 3 untracked · 4 conflicts")
        XCTAssertEqual(presentation.operationText, "Rebase in progress")
        XCTAssertEqual(presentation.accessibilityLabel, "main; ↑2 ↓1; 1 staged · 2 unstaged · 3 untracked · 4 conflicts; Rebase in progress")
        XCTAssertFalse(presentation.showsProgress)

        let busy = RepositoryLocalStatusPresenter.present(snapshot, activityText: " Fetching ", isBusy: true)
        XCTAssertEqual(busy.operationText, "Fetching")
        XCTAssertTrue(busy.showsProgress)
    }

    func testLocalPresenterHandlesCleanUnbornDetachedAndUnknownRepositories() {
        let heads: [(RepositoryHeadStatus, String)] = [
            (.branch(name: "main", unborn: true), "main (unborn)"),
            (.detached(commit: "abcdef01"), "Detached at abcdef01"),
            (.detached(commit: nil), "Detached HEAD"),
            (.unknown, "Repository"),
        ]
        for (head, expected) in heads {
            let presentation = RepositoryLocalStatusPresenter.present(
                RepositoryLocalStatusSnapshot(
                    head: head,
                    ahead: 0,
                    behind: 0,
                    counts: RepositoryWorkingStateCounts(),
                    operation: nil
                ),
                activityText: "   ",
                isBusy: false
            )
            XCTAssertEqual(presentation.branchText, expected)
            XCTAssertNil(presentation.aheadBehindText)
            XCTAssertEqual(presentation.countsText, "Clean")
            XCTAssertNil(presentation.operationText)
        }
    }

    func testLayoutCollapsesCountsBeforeIdentityAndActiveOperation() {
        XCTAssertEqual(
            RepositoryStatusBarLayout.presentation(forWidth: 1000),
            RepositoryStatusBarLayout(
                showsAheadBehind: true,
                showsLocalCounts: true,
                showsForgeAccount: true,
                showsForgeFreshness: true
            )
        )
        XCTAssertFalse(RepositoryStatusBarLayout.presentation(forWidth: 899).showsLocalCounts)
        XCTAssertFalse(RepositoryStatusBarLayout.presentation(forWidth: 819).showsForgeAccount)
        XCTAssertFalse(RepositoryStatusBarLayout.presentation(forWidth: 759).showsAheadBehind)
        XCTAssertFalse(RepositoryStatusBarLayout.presentation(forWidth: 679).showsForgeFreshness)
    }

    func testDiagnosticDetailsExplainEveryRecoveryWithoutTransportPayloads() {
        let expected: [ForgeStatusDetailsAction: RepositoryForgeDiagnosticDetails] = [
            .explainOffline: RepositoryForgeDiagnosticDetails(
                title: "Forge is Offline",
                message: "Local Git remains available. Reconnect to refresh the cached Forge Overlay."
            ),
            .authenticate: RepositoryForgeDiagnosticDetails(
                title: "Sign In Required",
                message: "Choose a Forge Account in Settings, then refresh this repository."
            ),
            .explainRateLimit: RepositoryForgeDiagnosticDetails(
                title: "GitHub Rate Limit",
                message: "Cached data remains visible. Forge requests resume after GitHub's reset time."
            ),
            .recoverForgeData: RepositoryForgeDiagnosticDetails(
                title: "Forge Data Unavailable",
                message: "Open Settings to retry recovery or reset Forge data. Local Git is unaffected."
            ),
            .configureRepositoryAccess: RepositoryForgeDiagnosticDetails(
                title: "Repository Access Required",
                message: "Configure the GitHub App installation and repository selection, then retry."
            ),
            .explainUnavailable: RepositoryForgeDiagnosticDetails(
                title: "Forge Unavailable",
                message: "The Forge Overlay is unavailable. Local Git remains fully usable."
            ),
        ]
        for action in ForgeStatusDetailsAction.allCases {
            XCTAssertEqual(RepositoryForgeDiagnosticDetailsPresenter.present(action), expected[action])
        }
    }

    func testStatusBarControllerInstallsTogglesAndRoutesRefreshAndDetails() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
        let split = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let controller = RepositoryStatusBarController(splitView: split, contentView: content, now: { self.now })
        var refreshCount = 0
        var details: [ForgeStatusDetailsAction] = []
        var presentations: [ForgeRepositoryStatusPresentation] = []
        controller.presentationDidChange = { presentations.append($0) }
        let forgeCoordinator = RepositoryForgeStatusCoordinator(
            initialInput: .unbound,
            manualRefreshHandler: { refreshCount += 1 },
            detailsHandler: { details.append($0) }
        )
        controller.bind(to: forgeCoordinator)

        controller.install(visible: true)
        XCTAssertFalse(controller.view.isHidden)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.view.frame.height, 29)
        XCTAssertEqual(controller.view.accessibilityIdentifier(), "GitX.RepositoryStatusBar")

        forgeCoordinator.updateStatus(statusInput(diagnostic: .offline))
        XCTAssertEqual(controller.view.forgeDiagnosticLabel.stringValue, "Offline")
        XCTAssertTrue(controller.view.forgeRefreshButton.isEnabled)
        controller.view.detailsButton.performClick(nil)
        XCTAssertEqual(details, [.explainOffline])

        forgeCoordinator.updateStatus(statusInput())
        controller.view.forgeRefreshButton.performClick(nil)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(presentations.last?.repositoryText, "hbmartin/gitx")
        controller.updateLocal(RepositoryLocalStatusPresenter.present(.unavailable, activityText: nil, isBusy: false))
        forgeCoordinator.updateStatus(statusInput(diagnostic: .rateLimited(until: now.addingTimeInterval(300))))
        XCTAssertTrue(controller.hasScheduledClockRefresh)

        controller.setVisible(false)
        XCTAssertTrue(controller.view.isHidden)
        controller.setVisible(true)
        XCTAssertFalse(controller.view.isHidden)
        controller.install(visible: false)
        XCTAssertFalse(controller.view.isHidden, "Repeated installation is intentionally inert")
        controller.invalidate()
        XCTAssertFalse(controller.hasScheduledClockRefresh)
    }

    func testForgeCoordinatorMakesManualRefreshInputAndDetailsObservable() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let split = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let controller = RepositoryStatusBarController(splitView: split, contentView: content, now: { self.now })
        var refreshes = 0
        var actions: [ForgeStatusDetailsAction] = []
        let source = NSObject()
        let manualNotification = expectation(
            forNotification: .repositoryForgeManualRefreshRequested,
            object: source
        ) { notification in
            notification.userInfo?["reason"] as? String == ForgeRefreshReason.manual.rawValue
        }
        let coordinator = RepositoryForgeStatusCoordinator(
            initialInput: statusInput(),
            manualRefreshHandler: {
                refreshes += 1
                RepositoryForgeStatusCoordinator.postManualRefresh(from: source)
            },
            detailsHandler: { actions.append($0) }
        )
        controller.bind(to: coordinator)
        controller.install(visible: true)

        controller.view.forgeRefreshButton.performClick(nil)
        XCTAssertEqual(refreshes, 1)
        wait(for: [manualNotification], timeout: 0.1)
        coordinator.updateStatus(statusInput(diagnostic: .unavailable(.missingRepositoryAccess)))
        XCTAssertEqual(controller.currentForgePresentation.detailsAction, .configureRepositoryAccess)
        controller.requestCurrentDetails()
        XCTAssertEqual(actions, [.configureRepositoryAccess])
    }

    func testClockRefreshesOrdinaryCurrentAndStaleAgesWithoutAForgeRequest() {
        var clock = now
        let controller = RepositoryStatusBarController(
            splitView: NSView(),
            contentView: NSView(),
            now: { clock }
        )
        controller.updateForge(statusInput(freshness: .current(fetchedAt: now.addingTimeInterval(-60))))
        XCTAssertEqual(controller.currentForgePresentation.freshnessText, "Updated 1m ago")
        XCTAssertTrue(controller.hasScheduledClockRefresh)

        clock.addTimeInterval(60)
        controller.refreshClock()
        XCTAssertEqual(controller.currentForgePresentation.freshnessText, "Updated 2m ago")
        controller.updateForge(statusInput(freshness: .stale(cachedAt: now.addingTimeInterval(-120))))
        XCTAssertEqual(controller.currentForgePresentation.freshnessText, "Stale · cached 3m ago")
        XCTAssertTrue(controller.hasScheduledClockRefresh)

        controller.updateForge(statusInput(freshness: .stale(cachedAt: nil)))
        XCTAssertFalse(controller.hasScheduledClockRefresh)
        controller.invalidate()
    }

    func testStatusBarPalettePreservesSnowLeopardDepthInLightAndDarkAppearances() throws {
        let light = try RepositoryStatusBarPalette.colors(for: XCTUnwrap(NSAppearance(named: .aqua)))
        let dark = try RepositoryStatusBarPalette.colors(for: XCTUnwrap(NSAppearance(named: .darkAqua)))
        XCTAssertGreaterThan(try whiteComponent(light.top), try whiteComponent(light.bottom))
        XCTAssertGreaterThan(try whiteComponent(dark.top), try whiteComponent(dark.bottom))
        XCTAssertGreaterThan(try whiteComponent(light.bottom), try whiteComponent(dark.top))

        let view = RepositoryStatusBarView(frame: NSRect(x: 0, y: 0, width: 700, height: 29))
        view.appearance = NSAppearance(named: .darkAqua)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.draw(view.bounds)
        image.unlockFocus()
    }

    func testStatusBarViewAppliesProgressAccessibilityRateLimitAndNarrowLayout() {
        let view = RepositoryStatusBarView(frame: NSRect(x: 0, y: 0, width: 650, height: 29))
        view.apply(local: RepositoryLocalStatusPresenter.present(
            RepositoryLocalStatusSnapshot(
                head: .branch(name: "main", unborn: false),
                ahead: 1,
                behind: 0,
                counts: RepositoryWorkingStateCounts(staged: 2),
                operation: .merge
            ),
            activityText: "Refreshing history",
            isBusy: true
        ))
        view.apply(forge: ForgeRepositoryStatusPresenter.present(
            statusInput(
                freshness: .refreshing(cachedAt: now.addingTimeInterval(-120)),
                diagnostic: .rateLimited(until: now.addingTimeInterval(300))
            ),
            now: now
        ))
        view.layoutSubtreeIfNeeded()

        XCTAssertFalse(view.localProgress.isHidden)
        XCTAssertFalse(view.forgeProgress.isHidden)
        XCTAssertTrue(view.countsLabel.isHidden)
        XCTAssertTrue(view.aheadBehindLabel.isHidden)
        XCTAssertTrue(view.forgeAccountLabel.isHidden)
        XCTAssertTrue(view.forgeFreshnessLabel.isHidden)
        XCTAssertTrue(view.forgeRefreshButton.toolTip?.hasPrefix("Rate limited until ") == true)
        XCTAssertEqual(view.accessibilityLabel(), "Repository status: main; ↑1; 2 staged; Refreshing history")
        XCTAssertTrue(view.accessibilityHelp()?.contains("Rate Limited") == true)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.draw(view.bounds)
        image.unlockFocus()

        view.apply(local: RepositoryLocalStatusPresenter.present(.unavailable, activityText: nil, isBusy: false))
        view.apply(forge: ForgeRepositoryStatusPresenter.present(.unbound, now: now))
        XCTAssertTrue(view.localProgress.isHidden)
        XCTAssertTrue(view.forgeProgress.isHidden)
        XCTAssertEqual(view.forgeRefreshButton.toolTip, "Bind a Forge Repository to refresh its overlay")
        XCTAssertTrue(view.detailsButton.isHidden)
    }

    func testRepositoryStatusBarDiagnosticScreenshot() throws {
        let view = RepositoryStatusBarView(frame: NSRect(x: 0, y: 0, width: 1040, height: 29))
        view.apply(local: RepositoryLocalStatusPresenter.present(
            RepositoryLocalStatusSnapshot(
                head: .branch(name: "feature/github-integration", unborn: false),
                ahead: 2,
                behind: 1,
                counts: RepositoryWorkingStateCounts(staged: 2, unstaged: 1, untracked: 3, conflicts: 0),
                operation: .rebase
            ),
            activityText: nil,
            isBusy: false
        ))
        view.apply(forge: ForgeRepositoryStatusPresenter.present(
            statusInput(
                freshness: .stale(cachedAt: now.addingTimeInterval(-900)),
                diagnostic: .rateLimited(until: now.addingTimeInterval(300))
            ),
            now: now
        ))
        try attachScreenshot(of: view, named: "Milestone 1 - Repository Status Bar - Rate Limited")
    }

    func testStatusBarToolbarBridgeUsesWarningDetailsForPersistentFailuresOnlyWhenHidden() throws {
        let controller = RepositoryStatusBarController(
            splitView: NSView(),
            contentView: NSView(),
            now: { self.now }
        )
        let windowController = PBGitWindowController(window: NSWindow())
        let toolbar = PBRepositoryToolbarController(windowController: windowController)
        toolbar.install()
        let installedToolbar = try XCTUnwrap(windowController.window?.toolbar)
        if let accountIndex = installedToolbar.items.firstIndex(where: {
            $0.itemIdentifier == NSToolbarItem.Identifier("GitX.Toolbar.ForgeAccount")
        }) {
            installedToolbar.removeItem(at: accountIndex)
        }
        XCTAssertFalse(installedToolbar.items.contains {
            $0.itemIdentifier == NSToolbarItem.Identifier("GitX.Toolbar.ForgeAccount")
        })
        controller.updateForge(statusInput(diagnostic: .unavailable(.sessionDisabled)))
        toolbar.updateForgeDiagnostic(
            persistentFailureText: controller.currentForgePresentation.toolbarPersistentFailureText,
            statusBarVisible: false
        )
        XCTAssertTrue(
            installedToolbar.items.contains {
                $0.itemIdentifier == NSToolbarItem.Identifier("GitX.Toolbar.ForgeAccount")
            },
            "A customized or legacy toolbar must regain the Forge control while it mirrors a persistent failure"
        )
        let statusItem: NSToolbarItem = try XCTUnwrap(toolbar.toolbar(
            installedToolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("GitX.Toolbar.RefreshStatus"),
            willBeInsertedIntoToolbar: true
        ))
        let statusStack = try XCTUnwrap(statusItem.view as? NSStackView)
        let label = try XCTUnwrap(statusStack.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
        let accountItem = try XCTUnwrap(installedToolbar.items.first {
            $0.itemIdentifier == NSToolbarItem.Identifier("GitX.Toolbar.ForgeAccount")
        })
        let accountStack = try XCTUnwrap(accountItem.view as? NSStackView)
        let warning = try XCTUnwrap(accountStack.arrangedSubviews.compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "GitX.Toolbar.ForgeWarning"
        })

        XCTAssertEqual(label.stringValue, "Ready", "A Forge warning must not replace repository activity text")
        XCTAssertNil(statusStack.arrangedSubviews.first {
            $0.accessibilityIdentifier() == "GitX.Toolbar.ForgeWarning"
        })
        XCTAssertFalse(warning.isHidden)
        XCTAssertEqual(warning.action, NSSelectorFromString("showForgeStatusDetails:"))
        XCTAssertTrue(warning.target === windowController)
        XCTAssertTrue(warning.toolTip?.contains("Show Details") == true)
        windowController.window?.setContentSize(NSSize(width: 760, height: 180))
        windowController.window?.layoutIfNeeded()
        if let frameView = windowController.window?.contentView?.superview {
            try attachScreenshot(of: frameView, named: "Milestone 1 - Toolbar Forge Persistent Failure Mirror")
        }

        toolbar.updateForgeDiagnostic(
            persistentFailureText: controller.currentForgePresentation.toolbarPersistentFailureText,
            statusBarVisible: true
        )
        XCTAssertEqual(label.stringValue, "Ready")
        XCTAssertTrue(warning.isHidden)

        for diagnostic in [
            ForgeStatusDiagnostic.offline,
            .rateLimited(until: now.addingTimeInterval(300)),
            .unavailable(.missingInstallation),
        ] {
            controller.updateForge(statusInput(diagnostic: diagnostic))
            toolbar.updateForgeDiagnostic(
                persistentFailureText: controller.currentForgePresentation.toolbarPersistentFailureText,
                statusBarVisible: false
            )
            XCTAssertTrue(warning.isHidden, "\(diagnostic) must not be mirrored in the toolbar")
            XCTAssertEqual(label.stringValue, "Ready")
        }
    }

    func testLocalStatusLoaderReadsRealRepositoryAndFailsClosedWithoutLeakingOutput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitx-status-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: directory)
        try "untracked\n".write(to: directory.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let repository = try XCTUnwrap(PBGitRepository(url: directory))

        let loaded = expectation(description: "local status loaded")
        let loader = RepositoryLocalStatusLoader(repository: repository, gitExecutablePath: "/usr/bin/git") { snapshot in
            XCTAssertEqual(snapshot.head, .branch(name: "main", unborn: true))
            XCTAssertEqual(snapshot.counts.untracked, 1)
            loaded.fulfill()
        }
        loader.refresh()
        wait(for: [loaded], timeout: 10)

        let failed = expectation(description: "local status failure")
        let failingLoader = RepositoryLocalStatusLoader(repository: repository, gitExecutablePath: "/not/an/executable") {
            XCTAssertEqual($0, .unavailable)
            failed.fulfill()
        }
        failingLoader.refresh()
        wait(for: [failed], timeout: 10)
        failingLoader.cancel()
    }

    private func statusInput(
        freshness: ForgeOverlayFreshness = .notLoaded,
        diagnostic: ForgeStatusDiagnostic = .none
    ) -> ForgeRepositoryStatusInput {
        ForgeRepositoryStatusInput(
            repository: try! ForgeRepositoryIdentity(
                forge: ForgeIdentity(kind: .github, origin: try! ForgeOrigin(host: "github.com")),
                owner: "hbmartin",
                name: "gitx"
            ),
            access: .account(login: "octocat"),
            freshness: freshness,
            diagnostic: diagnostic
        )
    }

    private func nulData(_ records: [String]) -> Data {
        Data((records.joined(separator: "\0") + "\0").utf8)
    }

    private func whiteComponent(_ color: NSColor) throws -> CGFloat {
        try XCTUnwrap(color.usingColorSpace(.deviceGray)).whiteComponent
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let task = PBTask(launchPath: "/usr/bin/git", arguments: arguments, inDirectory: directory.path)
        task.timeout = 10
        try task.launch()
    }

    private func attachScreenshot(of view: NSView, named name: String) throws {
        view.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let screenshot = NSImage(size: view.bounds.size)
        screenshot.addRepresentation(representation)
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
