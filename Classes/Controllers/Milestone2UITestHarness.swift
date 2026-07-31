import AppKit
import ForgeKit
import Foundation
import GitHubForgeAdapter
import OSLog // swiftlint:disable:this unused_import

#if DEBUG
    /// Deterministic launch-only journeys for XCUITest. This seam never reads
    /// credentials or performs provider requests; production AppKit presenters and
    /// local-Git executors remain responsible for every observable transition.
    @MainActor
    final class Milestone2UITestHarness {
        private enum Scenario: String {
            case pushCreate = "push-create"
            case existingPullRequest = "existing-pull-request"
            case exactCheckout = "exact-checkout"
            case deepLink = "deep-link"
            case deepLinkNoCheckout = "deep-link-no-checkout"
            case stagingCreate = "staging-create"
        }

        private let windowController: PBGitWindowController
        private let environment: [String: String]
        private let logger = Logger(subsystem: "com.gitx.gitx", category: "Milestone2UITestHarness")
        private var pullRequestController: RepositoryPullRequestUIController?
        private var nativePullRequestController: PBViewController?
        private var nativeReadController: ForgeReadSurfaceViewController?
        private var launchTask: Task<Void, Never>?
        private let stateMarker = NSTextField(labelWithString: "")

        private init(windowController: PBGitWindowController, environment: [String: String]) {
            self.windowController = windowController
            self.environment = environment
            installStateMarker()
        }

        deinit {
            launchTask?.cancel()
        }

        static func installIfRequested(for windowController: PBGitWindowController) -> Milestone2UITestHarness? {
            let environment = ProcessInfo.processInfo.environment
            guard environment["GITX_M2_UITEST"] == "1" else { return nil }
            let harness = Milestone2UITestHarness(
                windowController: windowController,
                environment: environment
            )
            harness.launchTask = Task { @MainActor [weak harness] in
                await Task.yield()
                harness?.start()
            }
            return harness
        }

        /// App-target characterization entry point. The Objective-C hosted
        /// product harness supplies deterministic launch values without
        /// mutating the process environment used by neighboring tests.
        static func runProductProof(
            for windowController: PBGitWindowController,
            environment: [String: String]
        ) -> AnyObject {
            let harness = Milestone2UITestHarness(
                windowController: windowController,
                environment: environment
            )
            harness.start()
            return harness
        }

        /// Exercises the private deterministic service and native-destination
        /// collaborators through the shipped app target. This keeps the product
        /// proof honest without widening their production visibility.
        static func runInternalProductProof(for windowController: PBGitWindowController) async -> Bool {
            guard let repository = windowController.repository else { return false }
            do {
                let harness = Milestone2UITestHarness(windowController: windowController, environment: [:])
                let fixture = try harness.pullRequestFixture(repository: repository, branchAlreadyPushed: true)
                let summary = try harness.pullRequestSummary(
                    preparation: fixture.preparation,
                    title: fixture.form.title
                )
                let created = Milestone2PullRequestService(
                    outcome: .created,
                    destination: fixture.destination,
                    expectedAccountID: fixture.preparation.accountID,
                    expectedForm: fixture.form
                )
                let existing = Milestone2PullRequestService(
                    outcome: .existing,
                    destination: fixture.destination,
                    expectedAccountID: fixture.preparation.accountID,
                    expectedForm: fixture.form
                )
                let createdOutcome = try await created.createPullRequest(
                    accountID: fixture.preparation.accountID,
                    form: fixture.form
                )
                let existingOutcome = try await existing.createPullRequest(
                    accountID: fixture.preparation.accountID,
                    form: fixture.form
                )
                let rejectedIntent = await throwsExpected {
                    _ = try await created.createPullRequest(
                        accountID: ForgeAccountID(
                            forge: fixture.preparation.accountID.forge,
                            value: "unexpected"
                        ),
                        form: fixture.form
                    )
                }
                let unsupportedPreparation = await throwsExpected {
                    _ = try await created.prepareCreation(
                        repository: fixture.preparation.repository,
                        localBranch: fixture.preparation.head.name,
                        localHead: fixture.preparation.head.commit
                    )
                }
                let unsupportedEdit = await throwsExpected {
                    _ = try await created.editPullRequest(
                        accountID: fixture.preparation.accountID,
                        edit: ForgePullRequestEdit(
                            snapshot: ForgePullRequestEditableSnapshot(
                                repository: fixture.preparation.repository,
                                number: ForgeItemNumber(42),
                                title: "Original",
                                bodyMarkdown: "Original",
                                updatedAt: Date(timeIntervalSince1970: 1)
                            ),
                            title: "Updated",
                            bodyMarkdown: "Updated"
                        )
                    )
                }
                let unsupportedSync = await throwsExpected {
                    _ = try await created.syncFork(
                        accountID: fixture.preparation.accountID,
                        plan: ForgeSyncForkPlan(
                            fork: fixture.preparation.head.repository,
                            parent: fixture.preparation.repository,
                            branch: fixture.preparation.base.name,
                            localFetchRemoteName: "origin"
                        )
                    )
                }
                let unsupported = unsupportedPreparation && unsupportedEdit && unsupportedSync

                let nativeService = try Milestone2NativePullRequestService(summary: summary)
                let page = try await nativeService.loadItems(
                    kind: .pullRequests,
                    query: ForgeReadSurfaceQuery(),
                    after: nil
                )
                let details = try await nativeService.loadDetails(
                    for: .pullRequest(summary),
                    timelineAfter: nil,
                    checkAfter: nil
                )
                let invalidLoads = await throwsExpected {
                    _ = try await nativeService.loadItems(
                        kind: .issues,
                        query: ForgeReadSurfaceQuery(),
                        after: nil
                    )
                }
                let router = Milestone2NativeDestinationRouter()
                let context = ForgeMarkdownContext(
                    repository: summary.repository,
                    location: .repository(defaultBranch: .branch(fixture.preparation.base.name))
                )
                let markdown = Milestone2NativeMarkdownRenderer().makeView(
                    markdown: "**Native**",
                    context: context
                )
                let actor = try ForgeActor(
                    id: ForgeObjectID(forge: summary.repository.forge, value: "gitx"),
                    login: "gitx",
                    kind: .person
                )
                let avatar = Milestone2NativeAvatarRenderer().makeAvatarView(
                    for: actor,
                    size: NSSize(width: 24, height: 24)
                )
                let nativeMarkdown = ForgeReadNativeMarkdownRenderer(router: router)
                    .makeView(markdown: "**Product native**", context: context)
                let nativeAvatar = ForgeReadNativeAvatarRenderer(owner: .anonymous)
                    .makeAvatarView(for: actor, size: NSSize(width: 24, height: 24))
                let presentation = ForgeReadInspectorPresenter.present(details) { _ in "Product proof" }
                let readController = ForgeReadSurfaceViewController(
                    kind: .pullRequests,
                    defaultRevision: .branch(fixture.preparation.base.name),
                    service: nativeService,
                    markdownRenderer: Milestone2NativeMarkdownRenderer(),
                    avatarRenderer: Milestone2NativeAvatarRenderer(),
                    destinationRouter: router,
                    pullRequestChangesProvider: Milestone2FailingChangesProvider()
                )
                let diagnostics = await readController.runProductProofDiagnostics(presentation)
                let defaultNow = ForgeGitHubReadSurfaceService(
                    repository: summary.repository,
                    adapter: GitHubReadAdapter()
                ).productProofNow()
                router.openNative(destination: fixture.destination)
                router.openInBrowser(destination: fixture.destination)

                let descriptions = [
                    Milestone2UITestHarnessError.invalidScenario("invalid").localizedDescription,
                    Milestone2UITestHarnessError.repositoryUnavailable.localizedDescription,
                    Milestone2UITestHarnessError.unexpectedDestination.localizedDescription,
                    Milestone2UITestHarnessError.unexpectedCheckoutRemote("origin").localizedDescription,
                    Milestone2UITestHarnessError.unexpectedPullRequestIntent.localizedDescription,
                    Milestone2UITestHarnessError.nativeDestinationUnavailable.localizedDescription,
                ]
                return createdOutcome == .created(fixture.destination)
                    && existingOutcome == .existing(fixture.destination)
                    && rejectedIntent && unsupported && page.items.count == 1
                    && details.details.item.destination == fixture.destination
                    && invalidLoads && markdown is ForgeMarkdownNativeView
                    && avatar is NSImageView && nativeMarkdown is ForgeMarkdownNativeView
                    && nativeAvatar is ForgeAvatarView && diagnostics
                    && defaultNow.timeIntervalSince1970 > 0
                    && descriptions.allSatisfy { !$0.isEmpty }
            } catch {
                Logger(subsystem: "com.gitx.gitx", category: "Milestone2UITestHarness").error(
                    "Internal Milestone 2 product proof failed errorType=\(String(describing: type(of: error)), privacy: .public)"
                )
                return false
            }
        }

        private static func throwsExpected(_ body: () async throws -> Void) async -> Bool {
            do {
                try await body()
                return false
            } catch {
                return true
            }
        }

        private func start() {
            let rawScenario = environment["GITX_M2_SCENARIO"] ?? "missing"
            do {
                guard let scenario = Scenario(rawValue: rawScenario) else {
                    throw Milestone2UITestHarnessError.invalidScenario(rawScenario)
                }
                guard let repository = windowController.repository else {
                    throw Milestone2UITestHarnessError.repositoryUnavailable
                }
                switch scenario {
                case .pushCreate:
                    try startCreateJourney(repository: repository, requiresPush: true, outcome: .created)
                case .existingPullRequest:
                    try startCreateJourney(repository: repository, requiresPush: false, outcome: .existing)
                case .exactCheckout:
                    try startExactCheckout(repository: repository)
                case .deepLink:
                    try startDeepLink(repository: repository, bindsRepository: true)
                case .deepLinkNoCheckout:
                    try startDeepLink(repository: repository, bindsRepository: false)
                case .stagingCreate:
                    windowController.showUncommittedChanges(self)
                }
                markState("Ready.\(rawScenario)", label: "Milestone 2 UI harness ready for \(rawScenario)")
                logger.notice("Started deterministic Milestone 2 UI journey \(rawScenario, privacy: .public)")
            } catch {
                windowController.showErrorSheet(error)
                markState("Failure", label: error.localizedDescription)
                logger.fault(
                    "Could not start deterministic Milestone 2 UI journey scenario=\(rawScenario, privacy: .public) errorType=\(String(describing: type(of: error)), privacy: .public)"
                )
            }
        }

        private func installStateMarker() {
            guard let contentView = windowController.window?.contentView else { return }
            stateMarker.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            stateMarker.textColor = .clear
            stateMarker.isBezeled = false
            stateMarker.drawsBackground = false
            stateMarker.setAccessibilityElement(true)
            stateMarker.setAccessibilityIdentifier("GitX.M2.Harness.Starting")
            stateMarker.setAccessibilityLabel("Milestone 2 UI harness starting")
            contentView.addSubview(stateMarker)
        }

        private func markState(_ state: String, label: String) {
            stateMarker.setAccessibilityIdentifier("GitX.M2.Harness.\(state)")
            stateMarker.setAccessibilityLabel(label)
            logger.debug("Milestone 2 UI harness state=\(state, privacy: .public)")
        }

        private func startCreateJourney(
            repository: PBGitRepository,
            requiresPush: Bool,
            outcome: Milestone2PullRequestService.Outcome
        ) throws {
            let fixture = try pullRequestFixture(repository: repository, branchAlreadyPushed: !requiresPush)
            let summary = try pullRequestSummary(
                preparation: fixture.preparation,
                title: fixture.form.title
            )
            let service = Milestone2PullRequestService(
                outcome: outcome,
                destination: fixture.destination,
                expectedAccountID: fixture.preparation.accountID,
                expectedForm: fixture.form
            )
            let remoteActions = RepositoryRemoteActionCoordinator(
                repository: repository,
                windowController: windowController
            )
            let controller = RepositoryPullRequestUIController(
                repository: repository,
                windowController: windowController,
                remoteActions: remoteActions,
                service: service,
                destinationOpening: { [weak self] destination in
                    guard destination == fixture.destination else { return false }
                    do {
                        return try self?.presentNativePullRequest(
                            repository: repository,
                            summary: summary,
                            destination: destination,
                            onCheckout: nil
                        ) == true
                    } catch {
                        self?.markFailure(error, scenario: outcome.stateName)
                        return false
                    }
                },
                bindingResolving: {
                    try? ForgeRepositoryBinding(
                        localRemoteName: "origin",
                        primaryRepository: fixture.preparation.repository,
                        preferredAccount: fixture.preparation.accountID
                    )
                },
                postPushBrowserFallback: { _ in }
            )
            controller.onCreationDestinationOpened = { [weak self] destination, opened in
                guard destination == fixture.destination, opened else {
                    self?.markFailure(
                        Milestone2UITestHarnessError.unexpectedDestination,
                        scenario: outcome.stateName
                    )
                    return
                }
                self?.markState(
                    "Destination.\(outcome.stateName)",
                    label: "Native Pull Request #42 destination opened after \(outcome.stateName) outcome"
                )
            }
            pullRequestController = controller
            try controller.beginUITestCreateJourney(
                preparation: fixture.preparation,
                initialForm: fixture.form,
                branch: repository.headRef()?.ref(),
                requiresPush: requiresPush
            )
        }

        private func pullRequestSummary(
            preparation: RepositoryPullRequestCreationPreparation,
            title: String
        ) throws -> ForgePullRequestSummary {
            try ForgePullRequestSummary(
                repository: preparation.repository,
                number: ForgeItemNumber(42),
                state: .open,
                isDraft: false,
                title: title,
                author: .unavailable(.notRequested),
                head: .available(preparation.head),
                base: .available(preparation.base),
                createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_200_100),
                labels: .available([]),
                checkRollup: .available(.succeeded),
                reviewRollup: .available(.approved)
            )
        }

        private func pullRequestFixture(
            repository: PBGitRepository,
            branchAlreadyPushed: Bool
        ) throws -> (
            preparation: RepositoryPullRequestCreationPreparation,
            form: ForgePullRequestCreationForm,
            destination: ForgeDestination
        ) {
            let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
            let primary = try ForgeRepositoryIdentity(forge: forge, owner: "gitx", name: "gitx")
            let contributor = try ForgeRepositoryIdentity(forge: forge, owner: "contributor", name: "gitx")
            let accountID = try ForgeAccountID(forge: forge, value: "milestone-2-ui-test")
            let headID = try ForgeCommitID(repository.outputOfTask(withArguments: ["rev-parse", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines))
            let base = try ForgeBranchReference(
                repository: primary,
                name: ForgeRefName("main"),
                commit: headID
            )
            let head = try ForgeBranchReference(
                repository: contributor,
                name: ForgeRefName("feature/milestone-2"),
                commit: headID
            )
            let preparation = try RepositoryPullRequestCreationPreparation(
                accountID: accountID,
                repository: primary,
                base: base,
                head: head,
                branchAlreadyPushed: branchAlreadyPushed,
                commitsOldestFirst: [ForgePullRequestCommitSummary(
                    id: headID,
                    subject: "Milestone 2 deterministic Pull Request",
                    body: "Offline XCUITest journey"
                )]
            )
            let form = try preparation.initialForms().forms[0]
            return try (
                preparation,
                form,
                .pullRequest(primary, ForgeItemNumber(42))
            )
        }

        private func startExactCheckout(repository: PBGitRepository) throws {
            guard let expectedRaw = environment["GITX_M2_EXPECTED_HEAD"],
                  let remoteName = environment["GITX_M2_CHECKOUT_REMOTE"]
            else { throw RepositoryPullRequestServiceError.checkoutVerificationFailed }
            let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
            let primary = try ForgeRepositoryIdentity(forge: forge, owner: "gitx", name: "gitx")
            let contributor = try ForgeRepositoryIdentity(forge: forge, owner: "contributor", name: "gitx")
            let localBase = try ForgeCommitID(repository.outputOfTask(withArguments: ["rev-parse", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines))
            let summary = try ForgePullRequestSummary(
                repository: primary,
                number: ForgeItemNumber(42),
                state: .open,
                isDraft: false,
                title: "Contributor checkout through the native Pull Request inspector",
                author: .unavailable(.notRequested),
                head: .available(ForgeBranchReference(
                    repository: contributor,
                    name: ForgeRefName("feature"),
                    commit: ForgeCommitID(expectedRaw)
                )),
                base: .available(ForgeBranchReference(
                    repository: primary,
                    name: ForgeRefName("main"),
                    commit: localBase
                )),
                createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_200_100),
                labels: .available([]),
                checkRollup: .available(.succeeded),
                reviewRollup: .available(.approved)
            )
            let remoteActions = RepositoryRemoteActionCoordinator(
                repository: repository,
                windowController: windowController
            )
            let controller = RepositoryPullRequestUIController(
                repository: repository,
                windowController: windowController,
                remoteActions: remoteActions,
                service: UnavailableRepositoryPullRequestMutationService(),
                destinationOpening: { _ in false },
                bindingResolving: { nil },
                postPushBrowserFallback: { _ in }
            )
            pullRequestController = controller
            guard remoteName == "contributor" else {
                throw Milestone2UITestHarnessError.unexpectedCheckoutRemote(remoteName)
            }
            _ = try presentNativePullRequest(
                repository: repository,
                summary: summary,
                destination: .pullRequest(primary, summary.number),
                onCheckout: { [weak controller] selected in
                    controller?.checkout(selected)
                }
            )
        }

        private func startDeepLink(repository: PBGitRepository, bindsRepository: Bool) throws {
            guard let rawURL = environment["GITX_M2_DEEP_LINK"],
                  let url = URL(string: rawURL)
            else { throw ForgeDeepLinkError.invalidURL }
            let settings = RepositoryUISettings(repository: repository)
            let previousBinding = settings.forgeRepositoryBinding
            if bindsRepository {
                let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
                let identity = try ForgeRepositoryIdentity(forge: forge, owner: "gitx", name: "gitx")
                settings.forgeRepositoryBinding = try ForgeRepositoryBinding(
                    localRemoteName: "milestone-2-local-fixture",
                    primaryRepository: identity
                )
            } else {
                settings.forgeRepositoryBinding = nil
            }
            defer { settings.forgeRepositoryBinding = previousBinding }
            ForgeDeepLinkApplicationRouter.shared.route(url)
            logger.notice(
                "Routed deterministic local-only deep link boundCheckout=\(bindsRepository, privacy: .public)"
            )
        }

        @discardableResult
        private func presentNativePullRequest(
            repository: PBGitRepository,
            summary: ForgePullRequestSummary,
            destination: ForgeDestination,
            onCheckout: ((ForgePullRequestSummary) -> Void)?
        ) throws -> Bool {
            guard case let .available(base) = summary.base,
                  let service = try? Milestone2NativePullRequestService(summary: summary),
                  let controller = PBViewController(
                      repository: repository,
                      superController: windowController
                  )
            else {
                throw Milestone2UITestHarnessError.nativeDestinationUnavailable
            }
            let readController = ForgeReadSurfaceViewController(
                kind: .pullRequests,
                defaultRevision: .branch(base.name),
                service: service,
                markdownRenderer: Milestone2NativeMarkdownRenderer(),
                avatarRenderer: Milestone2NativeAvatarRenderer(),
                destinationRouter: Milestone2NativeDestinationRouter(),
                pullRequestChangesProvider: RepositoryLocalPullRequestChangesProvider(repository: repository),
                onCheckoutPullRequest: onCheckout
            )
            let root = NSView()
            root.setAccessibilityElement(true)
            root.setAccessibilityRole(.group)
            root.setAccessibilityIdentifier("GitX.M2.NativePullRequestDestination")
            root.setAccessibilityLabel("Native Pull Request destination")
            controller.addChild(readController)
            let readView = readController.view
            readView.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(readView)
            NSLayoutConstraint.activate([
                readView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                readView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                readView.topAnchor.constraint(equalTo: root.topAnchor),
                readView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
            controller.view = root
            _ = readController.open(destination: destination)
            readController.refresh()
            nativePullRequestController = controller
            nativeReadController = readController
            windowController.changeContentController(controller)
            logger.notice("Mounted deterministic product-native Pull Request destination")
            return true
        }

        private func markFailure(_ error: Error, scenario: String) {
            markState("Failure", label: error.localizedDescription)
            windowController.showErrorSheet(error)
            logger.fault(
                "Milestone 2 UI journey failed scenario=\(scenario, privacy: .public) errorType=\(String(describing: type(of: error)), privacy: .public)"
            )
        }
    }

    private struct Milestone2PullRequestService: RepositoryPullRequestMutationServing {
        enum Outcome: Sendable {
            case created
            case existing

            var stateName: String {
                switch self {
                case .created: "Created"
                case .existing: "Existing"
                }
            }
        }

        let outcome: Outcome
        let destination: ForgeDestination
        let expectedAccountID: ForgeAccountID
        let expectedForm: ForgePullRequestCreationForm

        func capabilities(
            accountID _: ForgeAccountID,
            repository _: ForgeRepositoryIdentity,
            operations: Set<ForgeOperation>
        ) async throws -> [ForgeOperation: ForgeOperationCapability] {
            Dictionary(uniqueKeysWithValues: operations.map { ($0, .verified(.knownAuthority)) })
        }

        func prepareCreation(
            repository _: ForgeRepositoryIdentity,
            localBranch _: ForgeRefName,
            localHead _: ForgeCommitID
        ) async throws -> RepositoryPullRequestCreationPreparation {
            throw RepositoryPullRequestServiceError.nativeCreationUnavailable
        }

        func createPullRequest(
            accountID: ForgeAccountID,
            form: ForgePullRequestCreationForm
        ) async throws -> RepositoryPullRequestCreationOutcome {
            guard accountID == expectedAccountID,
                  form.repository == expectedForm.repository,
                  form.base == expectedForm.base,
                  form.head == expectedForm.head,
                  form.title == expectedForm.title,
                  form.bodyMarkdown == expectedForm.bodyMarkdown,
                  form.isDraft == expectedForm.isDraft
            else { throw Milestone2UITestHarnessError.unexpectedPullRequestIntent }
            switch outcome {
            case .created: return .created(destination)
            case .existing: return .existing(destination)
            }
        }

        func editPullRequest(
            accountID _: ForgeAccountID,
            edit _: ForgePullRequestEdit
        ) async throws -> RepositoryPullRequestEditOutcome {
            throw RepositoryPullRequestServiceError.nativeCreationUnavailable
        }

        func syncFork(
            accountID _: ForgeAccountID,
            plan _: ForgeSyncForkPlan
        ) async throws -> RepositorySyncForkOutcome {
            throw RepositoryPullRequestServiceError.nativeCreationUnavailable
        }
    }

    private struct Milestone2FailingChangesProvider: RepositoryPullRequestChangesProviding {
        func changes(
            repository _: ForgeRepositoryIdentity,
            base _: ForgeBranchReference,
            head _: ForgeBranchReference
        ) async throws -> RepositoryLocalPullRequestDiff {
            throw Milestone2UITestHarnessError.nativeDestinationUnavailable
        }
    }

    private enum Milestone2UITestHarnessError: LocalizedError {
        case invalidScenario(String)
        case repositoryUnavailable
        case unexpectedDestination
        case unexpectedCheckoutRemote(String)
        case unexpectedPullRequestIntent
        case nativeDestinationUnavailable

        var errorDescription: String? {
            switch self {
            case let .invalidScenario(scenario):
                "The Milestone 2 UI test scenario ‘\(scenario)’ is invalid."
            case .repositoryUnavailable:
                "The Milestone 2 UI test repository was not available when the harness started."
            case .unexpectedDestination:
                "The Pull Request journey did not route the exact expected destination."
            case let .unexpectedCheckoutRemote(remote):
                "The Pull Request checkout fixture used unexpected remote ‘\(remote)’ instead of ‘contributor’."
            case .unexpectedPullRequestIntent:
                "The Pull Request journey did not preserve the exact approved account and form."
            case .nativeDestinationUnavailable:
                "The deterministic native Pull Request destination could not be mounted."
            }
        }
    }

    @MainActor
    private final class Milestone2NativePullRequestService: ForgeReadSurfaceServing {
        private let summary: ForgePullRequestSummary
        private let details: ForgeReadSurfaceDetailsSnapshot

        init(summary: ForgePullRequestSummary) throws {
            self.summary = summary
            let pullRequestDetails = try ForgePullRequestDetails(
                summary: summary,
                bodyMarkdown: .available(
                    "## Milestone 2 native destination\n\nThis deterministic Pull Request is rendered by GitX without network access."
                ),
                assignees: .available([]),
                milestone: .available(nil),
                reviewers: .available([]),
                linkedIssues: .available([]),
                mergeability: .available(.mergeable),
                checks: .available([]),
                timeline: .available(ForgePage(items: []))
            )
            details = ForgeReadSurfaceDetailsSnapshot(
                details: .pullRequest(ForgePullRequestDetailsPage(
                    details: pullRequestDetails,
                    nextCheckCursor: nil
                )),
                fetchedAt: Date(timeIntervalSince1970: 1_700_200_200)
            )
        }

        func loadItems(
            kind: ForgeReadSurfaceKind,
            query _: ForgeReadSurfaceQuery,
            after _: ForgePageCursor?
        ) async throws -> ForgeReadSurfacePage {
            guard kind == .pullRequests else {
                throw RepositoryPullRequestServiceError.repositoryUnavailable
            }
            return ForgeReadSurfacePage(
                items: [.pullRequest(summary)],
                totalCount: 1,
                fetchedAt: Date(timeIntervalSince1970: 1_700_200_200)
            )
        }

        func loadDetails(
            for item: ForgeRepositoryItem,
            timelineAfter _: ForgePageCursor?,
            checkAfter _: ForgePageCursor?
        ) async throws -> ForgeReadSurfaceDetailsSnapshot {
            guard item.destination == .pullRequest(summary.repository, summary.number) else {
                throw RepositoryPullRequestServiceError.repositoryUnavailable
            }
            return details
        }
    }

    @MainActor
    private final class Milestone2NativeMarkdownRenderer: ForgeReadMarkdownRendering {
        func makeView(markdown: String, context: ForgeMarkdownContext) -> NSView {
            ForgeMarkdownNativeView(document: ForgeMarkdownSanitizer().sanitize(markdown, context: context))
        }
    }

    @MainActor
    private final class Milestone2NativeAvatarRenderer: ForgeReadAvatarRendering {
        func makeAvatarView(for actor: ForgeActor, size: NSSize) -> NSView {
            let image = NSImageView(frame: NSRect(origin: .zero, size: size))
            image.image = NSImage(
                systemSymbolName: "person.crop.circle",
                accessibilityDescription: actor.displayName ?? actor.login
            )
            return image
        }
    }

    @MainActor
    private final class Milestone2NativeDestinationRouter: ForgeReadDestinationRouting,
        ForgeMarkdownNavigationRouting
    {
        func openNative(destination _: ForgeDestination) {}
        func openInBrowser(destination _: ForgeDestination) {}
        func activateMarkdownLink(_: ForgeMarkdownLinkTarget) {}
        func openMarkdownLinkInBrowser(_: URL) {}
    }
#endif
