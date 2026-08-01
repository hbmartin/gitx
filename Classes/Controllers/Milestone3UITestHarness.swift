import AppKit
import ForgeKit
import Foundation
import OSLog // swiftlint:disable:this unused_import

#if DEBUG || !GITX_APP_TARGET
    /// Launch-only deterministic Milestone 3 journeys. The harness never reads
    /// credentials or performs a provider request. It injects deterministic
    /// services into the shipped review workflow and mounts the production
    /// review controller over an isolated repository supplied by XCUITest.
    @MainActor
    final class Milestone3UITestHarness {
        /// The repository window owns an installed harness. Keeping the inverse
        /// edge weak lets window close synchronously release the harness and
        /// cancel every review task it owns.
        private weak var windowController: PBGitWindowController?
        private let environment: [String: String]
        private let logger = Logger(subsystem: "com.gitx.gitx", category: "Milestone3UITestHarness")
        private let stateMarker = NSTextField(labelWithString: "")
        private var containerController: PBViewController?
        private var reviewController: RepositoryPullRequestReviewOverlayController?
        private var reviewService: Milestone3ProductionReviewService?
        private var launchTask: Task<Void, Never>?
        private var repositoryRefsObservation: NSKeyValueObservation?
        private var repositoryCurrentBranchObservation: NSKeyValueObservation?

        private init(windowController: PBGitWindowController, environment: [String: String]) {
            self.windowController = windowController
            self.environment = environment
            installStateMarker()
        }

        isolated deinit {
            launchTask?.cancel()
            reviewController?.detach()
        }

        static func installIfRequested(for windowController: PBGitWindowController) -> Milestone3UITestHarness? {
            let environment = ProcessInfo.processInfo.environment
            guard environment["GITX_M3_UITEST"] == "1" else { return nil }
            let harness = Milestone3UITestHarness(
                windowController: windowController,
                environment: environment
            )
            harness.launchTask = Task { @MainActor [weak harness] in
                await Task.yield()
                harness?.start()
            }
            return harness
        }

        #if !GITX_APP_TARGET
            /// App-hosted tests can install a deterministic journey without changing
            /// the process environment shared by neighboring tests.
            static func runProductProof(
                for windowController: PBGitWindowController,
                environment: [String: String]
            ) -> AnyObject {
                let harness = Milestone3UITestHarness(
                    windowController: windowController,
                    environment: environment
                )
                harness.start()
                return harness
            }
        #endif

        private func start() {
            let rawScenario = environment["GITX_M3_SCENARIO"] ?? "missing"
            guard let windowController else { return }
            do {
                guard let journey = Milestone3DiagnosticJourney(rawValue: rawScenario) else {
                    throw Milestone3UITestHarnessError.invalidScenario(rawScenario)
                }
                guard let repository = windowController.repository else {
                    throw Milestone3UITestHarnessError.repositoryUnavailable
                }
                installRepositoryObservations(repository)
                guard let container = PBViewController(
                    repository: repository,
                    superController: windowController
                ) else {
                    throw Milestone3UITestHarnessError.presenterUnavailable
                }
                let fixture = try Milestone3ProductionReviewFixture(
                    repository: repository,
                    journey: journey
                )
                let stateHandler: Milestone3ProductionStateHandler = { [weak self] state, label in
                    self?.markState(state, label: label)
                }
                let service = Milestone3ProductionReviewService(
                    fixture: fixture,
                    journey: journey,
                    stateHandler: stateHandler
                )
                let localService = try Milestone3ProductionLocalReviewService(
                    repository: repository,
                    forgeRepository: fixture.repository,
                    accountID: fixture.accountID,
                    stateHandler: stateHandler
                )
                let session = RepositoryPullRequestReviewSession(
                    identity: fixture.identity,
                    service: service,
                    localService: localService
                )
                let controller = RepositoryPullRequestReviewOverlayController(
                    session: session,
                    router: Milestone3ProductionReviewRouter(stateHandler: stateHandler),
                    onFetchBaseCompletion: { [weak self] in
                        self?.refreshAfterBaseFetchCompletion()
                    },
                    onCheckOutBaseCompletion: { [weak self] in
                        self?.refreshAfterBaseCheckoutCompletion()
                    }
                )
                container.addChild(controller)
                container.view = productionRoot(for: controller)
                containerController = container
                reviewController = controller
                reviewService = service
                windowController.changeContentController(container)
                controller.start()
                markState(
                    "Ready.\(rawScenario)",
                    label: "Production Milestone 3 review UI ready for \(rawScenario)"
                )
                logger.notice("Started deterministic production Milestone 3 UI journey \(rawScenario, privacy: .public)")
            } catch {
                markState("Failure", label: error.localizedDescription)
                windowController.showErrorSheet(error)
                logger.fault(
                    "Could not start deterministic Milestone 3 UI journey scenario=\(rawScenario, privacy: .public) errorType=\(String(describing: type(of: error)), privacy: .public)"
                )
            }
        }

        private func installStateMarker() {
            guard let contentView = windowController?.window?.contentView else { return }
            stateMarker.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            stateMarker.textColor = .clear
            stateMarker.isBezeled = false
            stateMarker.drawsBackground = false
            stateMarker.setAccessibilityElement(true)
            stateMarker.setAccessibilityIdentifier(Milestone3AccessibilityIdentifier.harnessStarting)
            stateMarker.setAccessibilityLabel("Milestone 3 UI harness starting")
            contentView.addSubview(stateMarker)
        }

        private func markState(_ state: String, label: String) {
            stateMarker.setAccessibilityIdentifier(Milestone3AccessibilityIdentifier.harnessState(state))
            stateMarker.setAccessibilityLabel(label)
            logger.debug("Milestone 3 UI harness state=\(state, privacy: .public)")
            if state == "PostMerge.Fetched" || state == "PostMerge.BaseCheckedOut" {
                restoreProductionDestination()
            }
        }

        private func restoreProductionDestination() {
            guard let windowController, let containerController else { return }
            windowController.changeContentController(containerController)
        }

        private func refreshAfterBaseFetchCompletion() {
            #if GITX_APP_TARGET
                windowController?.refreshAfterForgeBaseFetch()
            #else
                windowController?.repository?.reloadRefs()
            #endif
            restoreProductionDestination()
        }

        private func refreshAfterBaseCheckoutCompletion() {
            #if GITX_APP_TARGET
                windowController?.refreshAfterForgeBaseCheckout()
            #else
                windowController?.jumpToCheckedOutBranch(nil)
            #endif
            restoreProductionDestination()
        }

        private func installRepositoryObservations(_ repository: PBGitRepository) {
            repositoryRefsObservation = repository.observe(\.refs, options: []) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.restoreProductionDestination()
                }
            }
            repositoryCurrentBranchObservation = repository.observe(\.currentBranch, options: []) {
                [weak self] _, _ in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.restoreProductionDestination()
                }
            }
        }

        private func productionRoot(
            for controller: RepositoryPullRequestReviewOverlayController
        ) -> NSView {
            let root = NSScrollView()
            root.hasVerticalScroller = true
            root.autohidesScrollers = true
            root.drawsBackground = false
            root.setAccessibilityIdentifier(Milestone3AccessibilityIdentifier.productionScrollView)

            let actionView = controller.view
            let overlayView = controller.reviewOverlayView
            let stack = NSStackView(views: [actionView, overlayView])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.setContentCompressionResistancePriority(.required, for: .vertical)
            let document = Milestone3FlippedDocumentView()
            document.translatesAutoresizingMaskIntoConstraints = false
            document.setAccessibilityElement(true)
            document.setAccessibilityRole(.group)
            document.setAccessibilityIdentifier(Milestone3AccessibilityIdentifier.nativeDestination)
            document.setAccessibilityLabel("Native Milestone 3 Pull Request destination")
            document.addSubview(stack)
            root.documentView = document
            NSLayoutConstraint.activate([
                document.leadingAnchor.constraint(equalTo: root.contentView.leadingAnchor),
                document.trailingAnchor.constraint(equalTo: root.contentView.trailingAnchor),
                document.topAnchor.constraint(equalTo: root.contentView.topAnchor),
                document.widthAnchor.constraint(equalTo: root.contentView.widthAnchor),
                stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                stack.topAnchor.constraint(equalTo: document.topAnchor),
                stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
                actionView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
                overlayView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            ])
            return root
        }
    }

    private final class Milestone3FlippedDocumentView: NSView {
        override var isFlipped: Bool {
            true
        }
    }

    private enum Milestone3UITestHarnessError: LocalizedError {
        case invalidScenario(String)
        case repositoryUnavailable
        case presenterUnavailable

        var errorDescription: String? {
            switch self {
            case let .invalidScenario(scenario):
                "The Milestone 3 UI test scenario ‘\(scenario)’ is invalid."
            case .repositoryUnavailable:
                "The Milestone 3 UI test repository was not available when the harness started."
            case .presenterUnavailable:
                "The Milestone 3 production review controller could not be mounted."
            }
        }
    }

    private typealias Milestone3ProductionStateHandler = @MainActor @Sendable (String, String) -> Void

    private struct Milestone3ProductionReviewFixture: Sendable {
        let now = Date(timeIntervalSince1970: 1_700_300_000)
        let identity: RepositoryPullRequestReviewIdentity
        let repository: ForgeRepositoryIdentity
        let accountID: ForgeAccountID
        let number: ForgeItemNumber
        let head: ForgeBranchReference
        let base: ForgeBranchReference
        let activeThreadID: ForgeObjectID
        let suggestedChange: ForgeSuggestedChange
        let journey: Milestone3DiagnosticJourney

        init(repository localRepository: PBGitRepository, journey: Milestone3DiagnosticJourney) throws {
            let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
            repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
            accountID = try ForgeAccountID(forge: forge, value: "m3-production-ui-account")
            number = try ForgeItemNumber(42)
            let headCommit = try ForgeCommitID(
                localRepository.outputOfTask(withArguments: ["rev-parse", "--verify", "HEAD"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let baseCommit = try ForgeCommitID(
                localRepository.outputOfTask(withArguments: ["rev-parse", "--verify", "main"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let currentBranch = try localRepository.outputOfTask(withArguments: ["branch", "--show-current"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            head = try ForgeBranchReference(
                repository: repository,
                name: ForgeRefName(currentBranch.isEmpty ? "feature/milestone-3" : currentBranch),
                commit: headCommit
            )
            base = try ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("main"),
                commit: baseCommit
            )
            identity = try RepositoryPullRequestReviewIdentity(
                accountID: accountID,
                repository: repository,
                number: number
            )
            activeThreadID = try ForgeObjectID(forge: forge, value: "m3-active-thread")
            suggestedChange = try ForgeSuggestedChange(
                repository: repository,
                pullRequest: number,
                displayedHead: headCommit,
                path: ForgeFilePath("M3Suggested.swift"),
                originalText: "let answer = 41",
                replacementText: "let answer = 42"
            )
            self.journey = journey
        }

        nonisolated func workspace(
            state: ForgePullRequestState? = nil,
            isDraft: Bool? = nil,
            queueState: ForgePullRequestMergeQueueState = .notQueued,
            deletionAvailable: Bool? = nil,
            threadIsResolved: Bool = false,
            canUpdateBranch: Bool? = nil
        ) throws -> RepositoryPullRequestReviewWorkspace {
            let selectedState = state ?? (journey == .postMerge ? .merged : .open)
            let selectedDraft = isDraft ?? (journey == .lifecycle)
            let offersDeletion = deletionAvailable ?? (journey == .queueDelete && selectedState == .merged)
            let offersUpdate = canUpdateBranch ?? (journey == .lifecycle && selectedState == .open)
            let context = try ForgePullRequestMutationContext(
                accountID: accountID,
                repository: repository,
                number: number,
                state: selectedState,
                isDraft: selectedDraft,
                head: head,
                base: base,
                updatedAt: now,
                allowedOperations: Set(ForgeOperation.allCases)
            )
            var warnings: Set<ForgePullRequestMergeWarning> = journey == .merge ? [.checksPending] : []
            if offersUpdate {
                warnings.insert(.branchBehind)
            }
            let merge = ForgePullRequestMergeSnapshot(
                context: context,
                viewerCanMerge: true,
                enabledMethods: Set(ForgePullRequestMergeMethod.allCases),
                warnings: warnings,
                queueState: queueState
            )
            let deletion = offersDeletion ? ForgeHeadBranchDeletionSnapshot(
                mergeSnapshot: merge,
                isSameRepository: true,
                isDefaultBranch: false,
                isProtected: false,
                viewerCanDelete: true,
                hasCheckedOutSafetyConflict: false
            ) : nil
            return try RepositoryPullRequestReviewWorkspace(
                identity: identity,
                displayedHead: head.commit,
                base: base,
                title: "Production Native Review",
                isDraft: selectedDraft,
                threads: threadRecords(isResolved: threadIsResolved),
                reviewers: .available([]),
                mutationContext: context,
                mergeSnapshot: merge,
                headBranchDeletionSnapshot: deletion,
                canUpdateBranch: offersUpdate,
                fetchedAt: now
            )
        }

        private nonisolated func threadRecords(isResolved: Bool) throws -> [RepositoryPullRequestReviewThreadRecord] {
            let path = try ForgeFilePath("M3Suggested.swift")
            let anchor = ForgeReviewAnchor(path: path, subject: .line, side: .right, line: 1)
            let commentCount = journey == .review ? 4 : 1
            let commentIDs = try (0 ..< commentCount).map {
                try ForgeObjectID(forge: repository.forge, value: "m3-comment-\($0)")
            }
            let comments = commentIDs.enumerated().map { index, id in
                ForgeReviewComment(
                    repository: repository,
                    id: id,
                    bodyMarkdown: index == 0 ? "Please review **the exact boundary**." : "Hidden review state",
                    createdAt: now.addingTimeInterval(Double(index)),
                    updatedAt: now.addingTimeInterval(Double(index)),
                    author: .unavailable(.partialResponse)
                )
            }
            let activeThread = try ForgeReviewThread(
                repository: repository,
                id: activeThreadID,
                isResolved: isResolved,
                isOutdated: false,
                anchor: .available(anchor),
                comments: .available(ForgePage(items: comments))
            )
            var visibility: [ForgeObjectID: ForgeReviewCommentVisibility] = [
                commentIDs[0]: .ordinary,
            ]
            if commentIDs.count == 4 {
                visibility[commentIDs[1]] = .minimized(reason: "Off-topic")
                visibility[commentIDs[2]] = .deleted
                visibility[commentIDs[3]] = .unavailable
            }
            let activePresentation = try ForgeReviewThreadPresentation(
                thread: activeThread,
                commentVisibility: visibility,
                commentReactions: [commentIDs[0]: [
                    ForgeReviewReactionSummary(kind: .eyes, count: 1, viewerReacted: false),
                    ForgeReviewReactionSummary(kind: .thumbsUp, count: 2, viewerReacted: false),
                ]]
            )
            let active = try RepositoryPullRequestReviewThreadRecord(
                pullRequest: number,
                presentation: activePresentation,
                suggestedChanges: journey == .suggestedChange ? [suggestedChange] : []
            )

            let outdatedID = try ForgeObjectID(forge: repository.forge, value: "m3-outdated-thread")
            let outdatedCommentID = try ForgeObjectID(forge: repository.forge, value: "m3-outdated-comment")
            let outdatedThread = try ForgeReviewThread(
                repository: repository,
                id: outdatedID,
                isResolved: false,
                isOutdated: true,
                anchor: .available(anchor),
                comments: .available(ForgePage(items: [ForgeReviewComment(
                    repository: repository,
                    id: outdatedCommentID,
                    bodyMarkdown: "This context moved, but remains visibly outdated.",
                    createdAt: now,
                    updatedAt: now,
                    author: .unavailable(.partialResponse)
                )]))
            )
            let outdatedPresentation = try ForgeReviewThreadPresentation(
                thread: outdatedThread,
                commentVisibility: [outdatedCommentID: .ordinary]
            )
            let outdated = try RepositoryPullRequestReviewThreadRecord(
                pullRequest: number,
                presentation: outdatedPresentation,
                exactOutdatedLocalAnchor: anchor
            )
            return journey == .review ? [active, outdated] : [active]
        }
    }

    private actor Milestone3ProductionReviewService: RepositoryPullRequestReviewMutationServing {
        private let fixture: Milestone3ProductionReviewFixture
        private let journey: Milestone3DiagnosticJourney
        private let stateHandler: Milestone3ProductionStateHandler
        private var state: ForgePullRequestState
        private var isDraft: Bool
        private var queueState: ForgePullRequestMergeQueueState = .notQueued
        private var deletionAvailable = false
        private var threadIsResolved = false
        private var branchWasUpdated = false

        init(
            fixture: Milestone3ProductionReviewFixture,
            journey: Milestone3DiagnosticJourney,
            stateHandler: @escaping Milestone3ProductionStateHandler
        ) {
            self.fixture = fixture
            self.journey = journey
            self.stateHandler = stateHandler
            let initialState: ForgePullRequestState = journey == .postMerge ? .merged : .open
            state = initialState
            isDraft = journey == .lifecycle
            deletionAvailable = journey == .queueDelete && initialState == .merged
        }

        func loadWorkspace(
            identity _: RepositoryPullRequestReviewIdentity
        ) async throws -> RepositoryPullRequestReviewWorkspace {
            try currentWorkspace()
        }

        func publishInlineReview(
            _: ForgeInlineReviewPublication
        ) async throws -> RepositoryPullRequestReviewWorkspace {
            await emit("Review.InlinePublished", "Inline review comment published by production workflow")
            return try currentWorkspace()
        }

        func replyToReviewThread(
            _: ForgeReviewThreadReplyPublication
        ) async throws -> RepositoryPullRequestReviewWorkspace {
            await emit("Review.ReplyPublished", "Review Thread reply published by production workflow")
            return try currentWorkspace()
        }

        func setReviewThreadResolution(
            identity _: RepositoryPullRequestReviewIdentity,
            threadID _: ForgeObjectID,
            mutation: ForgeReviewThreadResolutionMutation
        ) async throws {
            threadIsResolved = mutation == .resolve
            await emit(
                threadIsResolved ? "Review.Resolved" : "Review.ResolutionUndone",
                threadIsResolved ? "Review Thread resolved" : "Review Thread resolution undone"
            )
            if journey == .review, mutation == .resolve {
                // Hold the deterministic provider response until Undo cancels
                // this generation. This has no clock: the UI test waits only
                // on observable controls, while the production ordering path
                // proves that the inverse mutation cannot overtake the request.
                let cancellationGate = AsyncStream<Void> { _ in }
                for await _ in cancellationGate {}
                try Task.checkCancellation()
            }
        }

        func submitFormalReview(
            _: ForgeFormalReviewSubmission
        ) async throws -> RepositoryPullRequestReviewWorkspace {
            await emit("Review.FormalReviewSubmitted", "Formal review submitted by production workflow")
            return try currentWorkspace()
        }

        func performLifecycle(
            _ request: ForgePullRequestLifecycleRequest
        ) async throws -> RepositoryPullRequestReviewWorkspace {
            switch request.action {
            case .markReady:
                isDraft = false
                await emit("Lifecycle.Ready", "Pull Request marked ready")
            case .convertToDraft:
                isDraft = true
                await emit("Lifecycle.Draft", "Pull Request converted to draft")
            case .close:
                state = .closed
                await emit("Lifecycle.Closed", "Pull Request closed")
            case .reopen:
                state = .open
                await emit("Lifecycle.Reopened", "Pull Request reopened")
            case .updateBranch:
                branchWasUpdated = true
                await emit("Lifecycle.BranchUpdated", "Pull Request branch updated after confirmation")
            }
            return try currentWorkspace()
        }

        func freshMergeSnapshot(
            identity _: RepositoryPullRequestReviewIdentity
        ) async throws -> ForgePullRequestMergeSnapshot {
            try currentWorkspace().mergeSnapshot
        }

        func mergePullRequest(
            _: ForgePullRequestMergeRequest
        ) async throws -> RepositoryPullRequestReviewWorkspace {
            state = .merged
            deletionAvailable = true
            await emit("Merge.Succeeded", "Pull Request merged by production workflow")
            return try currentWorkspace()
        }

        func changeMergeQueue(
            _ request: ForgePullRequestMergeQueueRequest
        ) async throws -> RepositoryPullRequestReviewWorkspace {
            queueState = request.action == .enter ? .queued : .notQueued
            if request.action == .leave, journey == .queueDelete {
                state = .merged
                deletionAvailable = true
                await emit("Queue.MergeObserved", "Merge observed after leaving deterministic queue")
            } else {
                await emit(
                    request.action == .enter ? "Queue.Entered" : "Queue.Left",
                    request.action == .enter ? "Pull Request entered merge queue" : "Pull Request left merge queue"
                )
            }
            return try currentWorkspace()
        }

        func freshHeadBranchDeletionSnapshot(
            identity _: RepositoryPullRequestReviewIdentity
        ) async throws -> ForgeHeadBranchDeletionSnapshot {
            guard let snapshot = try currentWorkspace().headBranchDeletionSnapshot else {
                throw RepositoryPullRequestReviewServiceError.unavailable
            }
            return snapshot
        }

        func deleteHeadBranch(_: ForgeHeadBranchDeletionRequest) async throws {
            deletionAvailable = false
            await emit("BranchDeletion.Deleted", "Head branch deleted as a separate production mutation")
        }

        private func currentWorkspace() throws -> RepositoryPullRequestReviewWorkspace {
            try fixture.workspace(
                state: state,
                isDraft: isDraft,
                queueState: queueState,
                deletionAvailable: deletionAvailable,
                threadIsResolved: threadIsResolved,
                canUpdateBranch: journey == .lifecycle && state == .open && !branchWasUpdated
            )
        }

        private func emit(_ state: String, _ label: String) async {
            await stateHandler(state, label)
        }
    }

    private nonisolated struct Milestone3ProductionLocalReviewService: RepositoryPullRequestLocalReviewServing {
        private let production: RepositoryPullRequestLocalReviewService
        private let stateHandler: Milestone3ProductionStateHandler

        @MainActor init(
            repository: PBGitRepository,
            forgeRepository: ForgeRepositoryIdentity,
            accountID: ForgeAccountID,
            stateHandler: @escaping Milestone3ProductionStateHandler
        ) throws {
            let binding = try ForgeRepositoryBinding(
                localRemoteName: "origin",
                primaryRepository: forgeRepository,
                preferredAccount: accountID
            )
            production = RepositoryPullRequestLocalReviewService(
                runner: Milestone3ProductionGitRunner(repository: repository),
                workingDirectory: repository.workingDirectoryURL(),
                binding: binding
            )
            self.stateHandler = stateHandler
        }

        func reanchorCandidates(
            for context: ForgeReviewContext,
            currentHead: ForgeCommitID
        ) async throws -> [ForgeReviewReanchorCandidate] {
            try await production.reanchorCandidates(for: context, currentHead: currentHead)
        }

        func checkedOutHead() async throws -> ForgeCommitID? {
            try await production.checkedOutHead()
        }

        func applySuggestedChange(_ change: ForgeSuggestedChange) async throws {
            try await production.applySuggestedChange(change)
            await stateHandler(
                "SuggestedChange.Applied",
                "Suggested Change applied through the production atomic local service"
            )
        }

        func fetchBase(_ base: ForgeBranchReference) async throws {
            try await production.fetchBase(base)
            await stateHandler("PostMerge.Fetched", "Base fetched without changing checkout")
        }

        func checkOutBase(_ base: ForgeBranchReference) async throws {
            try await production.checkOutBase(base)
            await stateHandler("PostMerge.BaseCheckedOut", "Base checked out after explicit action")
        }
    }

    /// The real local review service validates provider identity through the
    /// configured Forge URL, while the actual deterministic fetch still uses
    /// XCUITest's local bare origin. Every other Git command passes through the
    /// same ObjectiveGit runner used by production.
    private struct Milestone3ProductionGitRunner: RepositoryPullRequestGitCommandRunning {
        private let base: RepositoryPullRequestObjectiveGitRunner

        init(repository: PBGitRepository) {
            base = RepositoryPullRequestObjectiveGitRunner(repository: repository)
        }

        func run(_ arguments: [String]) throws -> String {
            if arguments == ["remote", "get-url", "origin"] {
                return "https://github.com/hbmartin/gitx.git\n"
            }
            return try base.run(arguments)
        }
    }

    @MainActor
    private final class Milestone3ProductionReviewRouter: RepositoryPullRequestReviewRouting {
        private let stateHandler: Milestone3ProductionStateHandler

        init(stateHandler: @escaping Milestone3ProductionStateHandler) {
            self.stateHandler = stateHandler
        }

        func openInBrowser(_: ForgeDestination) {
            stateHandler("Lifecycle.ReviewersBrowserRouted", "Reviewer management routed to browser")
        }
    }

    #if GITX_APP_TARGET
        /// Objective-C-compatible proof that exercises the shipped repository
        /// collaboration controller instead of a test-target source copy.
        @MainActor
        @objc(PBMilestone3ProductCoverageHarness)
        // Referenced through the generated Objective-C interface by WindowControllerTests.
        // swiftlint:disable:next unused_declaration
        final class Milestone3ProductCoverageHarness: NSObject {
            @objc(repositoryForgeViewStateProofWithRepository:)
            // Referenced through the generated Objective-C interface by WindowControllerTests.
            // swiftlint:disable:next unused_declaration function_body_length
            static func repositoryForgeViewStateProof(repository: PBGitRepository) -> Bool {
                let preferences = ApplicationComposition.shared.applicationPreferences
                let settings = RepositoryUISettings(repository: repository, preferences: preferences)
                let originalPullRequests = settings.forgeReadSurfaceViewState(for: .pullRequests)
                let originalIssues = settings.forgeReadSurfaceViewState(for: .issues)
                let originalAttention = settings.forgeAttentionViewState
                let originalBinding = settings.forgeRepositoryBinding
                defer {
                    settings.setForgeReadSurfaceViewState(originalPullRequests, for: .pullRequests)
                    settings.setForgeReadSurfaceViewState(originalIssues, for: .issues)
                    settings.forgeAttentionViewState = originalAttention
                    settings.forgeRepositoryBinding = originalBinding
                }

                do {
                    let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
                    let forgeRepository = try ForgeRepositoryIdentity(
                        forge: forge,
                        owner: "hbmartin",
                        name: "gitx"
                    )
                    let originalAccount = try ForgeAccountID(forge: forge, value: "m3-view-state-original")
                    let replacementAccount = try ForgeAccountID(forge: forge, value: "m3-view-state-replacement")
                    let pullRequestState = try RepositoryForgeReadSurfaceViewState(
                        searchText: "review me",
                        stateFilter: .all,
                        visibleColumns: [.number, .title],
                        selectedDestination: .pullRequest(forgeRepository, ForgeItemNumber(42)),
                        inspectorLayout: RepositoryForgeInspectorLayoutState(
                            preferredFraction: 0.44,
                            isCollapsed: true
                        ),
                        inspectorMode: .changes
                    )
                    let attentionState = RepositoryForgeAttentionViewState(
                        query: ForgeAttentionViewState(
                            scope: .all,
                            visibility: .active,
                            sortOrder: .oldestFirst,
                            kinds: [.mention],
                            columns: [.repository, .title]
                        ),
                        inspectorLayout: RepositoryForgeInspectorLayoutState(preferredFraction: 0.47),
                        inspectorMode: .changes
                    )
                    let binding = try ForgeRepositoryBinding(
                        localRemoteName: "origin",
                        primaryRepository: forgeRepository,
                        preferredAccount: originalAccount
                    )
                    settings.setForgeReadSurfaceViewState(pullRequestState, for: .pullRequests)
                    settings.forgeAttentionViewState = attentionState
                    settings.forgeRepositoryBinding = try RepositoryForgeAccountSelection.updating(
                        binding,
                        preferredAccount: replacementAccount
                    )

                    let reopened = RepositoryUISettings(repository: repository, preferences: preferences)
                    return reopened.forgeReadSurfaceViewState(for: .pullRequests) == pullRequestState
                        && reopened.forgeReadSurfaceViewState(for: .issues) == originalIssues
                        && reopened.forgeAttentionViewState == attentionState
                        && reopened.forgeRepositoryBinding?.preferredAccount == replacementAccount
                        && reopened.forgeRepositoryBinding?.primaryRepository == forgeRepository
                } catch {
                    return false
                }
            }

            @objc(collaborationCloseLifecycleProofWithRepository:)
            // Referenced through the generated Objective-C interface by WindowControllerTests.
            // swiftlint:disable:next unused_declaration
            static func collaborationCloseLifecycleProof(repository: PBGitRepository) -> Bool {
                guard let controller = RepositoryForgeCollaborationController(
                    repository: repository,
                    superController: nil
                ) else { return false }
                let host = Milestone3CloseLifecycleReviewOverlayHost()
                controller.installReviewOverlayHostForCloseTesting(host)
                guard controller.hasReviewOverlayHostForTesting else { return false }

                controller.closeView()

                return host.detachCount == 1 && !controller.hasReviewOverlayHostForTesting
            }
        }

        @MainActor
        private final class Milestone3CloseLifecycleReviewOverlayHost:
            RepositoryPullRequestReviewOverlayHosting
        {
            private(set) var detachCount = 0

            func actionView(for _: ForgePullRequestSummary) -> NSView {
                NSView()
            }

            func install(
                in _: PBNativeContentView,
                pullRequest _: ForgePullRequestSummary,
                diff _: RepositoryLocalPullRequestDiff
            ) {}

            func refresh() {}

            func failClosedAfterRepositoryRefresh(_: String) {}

            func detach() {
                detachCount += 1
            }
        }
    #endif
#endif
