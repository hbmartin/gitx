import AppKit
import ForgeKit
import OSLog // swiftlint:disable:this unused_import

/// Stable identities shared by focused AppKit tests and the launched-app UI plan.
@MainActor
enum RepositoryPullRequestReviewAccessibility {
    static let actionRoot = "GitX.PullRequest.Review.Actions"
    static let overlayRoot = "GitX.PullRequest.Review.Overlay"
    static let status = "GitX.PullRequest.Review.Status"
    static let retry = "GitX.PullRequest.Review.Retry"
    static let refresh = "GitX.PullRequest.Review.Refresh"
    static let reviewers = "GitX.PullRequest.Review.Reviewers"
    static let manageReviewers = "GitX.PullRequest.Review.ManageReviewers"
    static let formalReview = "GitX.PullRequest.Review.FormalReview"
    static let formalReviewSheet = "GitX.PullRequest.Review.FormalReviewSheet"
    static let formalReviewKind = "GitX.PullRequest.Review.FormalReviewKind"
    static let formalReviewBody = "GitX.PullRequest.Review.FormalReviewBody"
    static let formalReviewSubmit = "GitX.PullRequest.Review.FormalReviewSubmit"
    static let formalReviewCancel = "GitX.PullRequest.Review.FormalReviewCancel"
    static let lifecyclePrefix = "GitX.PullRequest.Review.Lifecycle."
    static let updateBranchSheet = "GitX.PullRequest.Review.Lifecycle.updateBranch.Sheet"
    static let updateBranchConfirm = "GitX.PullRequest.Review.Lifecycle.updateBranch.Confirm"
    static let updateBranchCancel = "GitX.PullRequest.Review.Lifecycle.updateBranch.Cancel"
    static let mergeMethod = "GitX.PullRequest.Review.MergeMethod"
    static let merge = "GitX.PullRequest.Review.Merge"
    static let mergeSheet = "GitX.PullRequest.Review.MergeSheet"
    static let mergeTitle = "GitX.PullRequest.Review.MergeTitle"
    static let mergeMessage = "GitX.PullRequest.Review.MergeMessage"
    static let mergeWarnings = "GitX.PullRequest.Review.MergeWarnings"
    static let mergeDeleteBranch = "GitX.PullRequest.Review.MergeDeleteBranch"
    static let mergeConfirm = "GitX.PullRequest.Review.MergeConfirm"
    static let mergeCancel = "GitX.PullRequest.Review.MergeCancel"
    static let mergeQueue = "GitX.PullRequest.Review.MergeQueue"
    static let deleteBranch = "GitX.PullRequest.Review.DeleteBranch"
    static let deleteBranchRetry = "GitX.PullRequest.Review.DeleteBranch.Retry"
    static let deleteBranchOpenInBrowser = "GitX.PullRequest.Review.DeleteBranch.OpenInBrowser"
    static let fetchBase = "GitX.PullRequest.Review.FetchBase"
    static let checkOutBase = "GitX.PullRequest.Review.CheckOutBase"
    static let threads = "GitX.PullRequest.Review.Threads"
    static let threadPrefix = "GitX.PullRequest.Review.Thread."
    static let inlinePanel = "GitX.PullRequest.Review.Inline"
    static let inlineBody = "GitX.PullRequest.Review.InlineBody"
    static let inlinePublish = "GitX.PullRequest.Review.InlinePublish"
    static let inlineReanchor = "GitX.PullRequest.Review.InlineReanchor"
    static let message = "GitX.PullRequest.Review.Message"
}

/// Native Snow-Leopard-inspired action and review-thread presentation. The
/// session owns every decision; this controller owns only AppKit wiring,
/// transient disclosure state, and explicit confirmations.
@MainActor
final class RepositoryPullRequestReviewOverlayController: NSViewController {
    private struct InlineWriteDestination: Hashable {
        let anchor: ForgeReviewAnchor
        let displayedHead: ForgeCommitID
    }

    private struct ResolutionControlPresentation: Equatable {
        let resolution: RepositoryReviewThreadResolutionPresentation
        let isEnabled: Bool
    }

    private struct ResolutionControlRow {
        let row: RepositoryReviewWrappingButtonRow
        let isFresh: Bool
        var presentation: ResolutionControlPresentation?
    }

    private let session: RepositoryPullRequestReviewSession
    private let router: any RepositoryPullRequestReviewRouting
    private let markdownRouter: RepositoryPullRequestReviewMarkdownRouter
    private let actionStack = NSStackView()
    private let overlayStack = NSStackView()
    private weak var actionContentBox: RepositoryReviewContentBox?
    private weak var overlayContentBox: RepositoryReviewContentBox?
    private(set) lazy var reviewOverlayView: NSView = makeOverlayRoot()
    private var tasks: [Task<Void, Never>] = []
    private var actionPresentationTasks: [Task<Void, Never>] = []
    /// Explicit overrides are required because the server presenter may start
    /// either expanded or collapsed. A Set could not represent collapsing an
    /// initially-expanded thread.
    private var threadExpansionOverrides: [ForgeObjectID: Bool] = [:]
    private var selectedAnchor: ForgeReviewAnchor?
    private var selectedContextLines: [String] = []
    private var selectedContextIsTruncated = false
    private var selectedDisplayedHead: ForgeCommitID?
    private var pendingReanchor: RepositoryPullRequestReviewSession.PendingReanchor?
    private var reanchorConfirmationInFlight = false
    private var replyWritesInFlight: Set<ForgeObjectID> = []
    private var inlineWritesInFlight: Set<InlineWriteDestination> = []
    private var suggestionInFlight: ForgeSuggestedChange?
    private var transientMessage: String?
    private var postMergeDeletionFailure: String?
    private var modalPanel: NSPanel?
    private var embeddedModalView: NSView?
    private var overlayDraftCoordinators: [RepositoryReviewDraftTextCoordinator] = []
    private var overlayDraftLoadTasks: [Task<Void, Never>] = []
    private var modalDraftCoordinator: RepositoryReviewDraftTextCoordinator?
    private var resolutionControlRows: [ForgeObjectID: ResolutionControlRow] = [:]
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "PullRequestReviewUI")
    var onWorkspacePresentationChange: (() -> Void)?

    init(
        session: RepositoryPullRequestReviewSession,
        router: any RepositoryPullRequestReviewRouting
    ) {
        self.session = session
        self.router = router
        markdownRouter = RepositoryPullRequestReviewMarkdownRouter(router: router)
        super.init(nibName: nil, bundle: nil)
        session.onStateChange = { [weak self] _ in self?.render() }
        session.onResolutionChange = { [weak self] threadID, state in
            self?.renderResolutionControls(threadID: threadID, state: state)
        }
        session.onMutationError = { [weak self] message in
            self?.transientMessage = message
            self?.render()
        }
        session.onOutcomeUnknown = { [weak self] in
            self?.transientMessage = "The server outcome is unknown. Refreshing without retrying…"
            self?.render()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    override func loadView() {
        configure(stack: actionStack, identifier: RepositoryPullRequestReviewAccessibility.actionRoot)
        let box = makeSnowLeopardBox(containing: actionStack)
        box.setAccessibilityIdentifier(RepositoryPullRequestReviewAccessibility.actionRoot)
        actionContentBox = box
        view = box
        renderActionArea()
    }

    func start() {
        session.load()
    }

    func failClosedAfterRepositoryRefresh(_ message: String) {
        session.failClosedAfterRepositoryRefresh(message)
    }

    func detach() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        actionPresentationTasks.forEach { $0.cancel() }
        actionPresentationTasks.removeAll()
        overlayDraftLoadTasks.forEach { $0.cancel() }
        overlayDraftLoadTasks.removeAll()
        overlayDraftCoordinators.forEach { $0.detach() }
        overlayDraftCoordinators.removeAll()
        resolutionControlRows.removeAll()
        closeModal()
        session.onStateChange = nil
        session.onResolutionChange = nil
        session.onMutationError = nil
        session.onOutcomeUnknown = nil
        onWorkspacePresentationChange = nil
    }

    func select(anchor: ForgeReviewAnchor, contextLines: [String], isTruncated: Bool) {
        selectedAnchor = anchor
        selectedContextLines = contextLines
        selectedContextIsTruncated = isTruncated
        selectedDisplayedHead = session.workspace?.displayedHead
        pendingReanchor = nil
        reanchorConfirmationInFlight = false
        renderOverlay()
    }

    func clearSelection() {
        selectedAnchor = nil
        selectedContextLines = []
        selectedContextIsTruncated = false
        selectedDisplayedHead = nil
        pendingReanchor = nil
        reanchorConfirmationInFlight = false
        renderOverlay()
    }

    // MARK: - Rendering

    private func render() {
        guard isViewLoaded else { return }
        renderActionArea()
        renderOverlay()
        onWorkspacePresentationChange?()
    }

    private func renderActionArea() {
        defer { actionContentBox?.invalidateIntrinsicContentSize() }
        actionPresentationTasks.forEach { $0.cancel() }
        actionPresentationTasks.removeAll()
        // A newly installed authoritative workspace invalidates every open
        // confirmation. Tear it down before rebuilding so a mutation that
        // renders re-entrantly cannot leave a stale modal reference behind.
        closeModal()
        clear(actionStack)
        addHeading("Pull Request Review & Merge", to: actionStack)
        addStateBanner(to: actionStack)
        guard let workspace = session.workspace else { return }

        let summary = NSTextField(
            wrappingLabelWithString: "#\(workspace.identity.number.rawValue)  \(workspace.title)"
        )
        summary.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        summary.maximumNumberOfLines = 2
        actionStack.addArrangedSubview(summary)

        addReviewers(workspace.reviewers, destination: workspace.browserDestination)
        actionStack.addArrangedSubview(separator())
        addLifecycleActions(workspace)
        addReviewAndMergeActions(workspace)
        if workspace.mutationContext.state == .merged {
            addPostMergeActions(workspace)
        }
        if let transientMessage {
            let message = banner(transientMessage, color: .systemOrange)
            message.setAccessibilityIdentifier(RepositoryPullRequestReviewAccessibility.message)
            actionStack.addArrangedSubview(message)
        }
        if let postMergeDeletionFailure {
            addPostMergeDeletionFailure(postMergeDeletionFailure, workspace: workspace)
        }
    }

    private func renderOverlay() {
        defer { overlayContentBox?.invalidateIntrinsicContentSize() }
        overlayDraftLoadTasks.forEach { $0.cancel() }
        overlayDraftLoadTasks.removeAll()
        overlayDraftCoordinators.forEach { $0.detach() }
        overlayDraftCoordinators.removeAll()
        resolutionControlRows.removeAll()
        clear(overlayStack)
        addHeading("Review Threads", to: overlayStack)
        addStateBanner(to: overlayStack)
        guard let workspace = session.workspace else { return }

        let threadList = NSStackView()
        configure(stack: threadList)
        if workspace.threads.isEmpty {
            let empty = NSTextField(labelWithString: "No review threads on this diff.")
            empty.textColor = .secondaryLabelColor
            threadList.addArrangedSubview(empty)
        } else {
            for record in workspace.threads {
                addFullWidthArrangedSubview(threadView(record, workspace: workspace), to: threadList)
            }
        }
        addFullWidthArrangedSubview(threadList, to: overlayStack)
        if let selectedAnchor {
            let composer = inlineComposer(
                anchor: selectedAnchor,
                workspace: workspace
            )
            addFullWidthArrangedSubview(composer, to: overlayStack)
        } else {
            let help = NSTextField(wrappingLabelWithString: "Select exact added, removed, or context lines in the local diff to add an inline review comment.")
            help.textColor = .secondaryLabelColor
            help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            overlayStack.addArrangedSubview(help)
        }
    }

    private func addStateBanner(to stack: NSStackView) {
        let value: (String, NSColor, Bool)? = switch session.state {
        case .idle:
            ("Review session is idle.", .secondaryLabelColor, true)
        case .loading:
            ("Loading review threads and fresh mutation eligibility…", .secondaryLabelColor, false)
        case let .stale(_, message):
            ("Showing stale review data. \(message)", .systemOrange, true)
        case let .failed(message):
            ("Couldn’t load native review data. \(message)", .systemRed, true)
        case .loaded:
            nil
        }
        guard let value else { return }
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        if case .loading = session.state {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            row.addArrangedSubview(spinner)
        }
        let label = banner(value.0, color: value.1)
        label.setAccessibilityIdentifier(RepositoryPullRequestReviewAccessibility.status)
        row.addArrangedSubview(label)
        if value.2 {
            let retry = makeButton(
                title: "Refresh",
                identifier: RepositoryPullRequestReviewAccessibility.retry
            ) { [weak self] in self?.session.load() }
            retry.controlSize = .small
            row.addArrangedSubview(retry)
        }
        stack.addArrangedSubview(row)
    }

    private func addReviewers(
        _ reviewers: ForgeReadSection<[ForgeReviewer]>,
        destination: ForgeDestination
    ) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let label = NSTextField(wrappingLabelWithString: reviewersDescription(reviewers))
        label.setAccessibilityIdentifier(RepositoryPullRequestReviewAccessibility.reviewers)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)
        let manage = makeButton(
            title: "Reviewers in Browser…",
            identifier: RepositoryPullRequestReviewAccessibility.manageReviewers
        ) { [weak self] in self?.router.openInBrowser(destination) }
        manage.bezelStyle = .rounded
        row.addArrangedSubview(manage)
        actionStack.addArrangedSubview(row)
    }

    private func addLifecycleActions(_ workspace: RepositoryPullRequestReviewWorkspace) {
        let row = wrappingButtonRow()
        for action in ForgePullRequestLifecycleAction.allCases {
            let button = makeButton(
                title: lifecycleTitle(action),
                identifier: RepositoryPullRequestReviewAccessibility.lifecyclePrefix + action.rawValue
            ) { [weak self] in
                if action == .updateBranch {
                    self?.prepareUpdateBranchConfirmation()
                } else {
                    self?.perform { try await self?.session.performLifecycle(action) }
                }
            }
            button.isEnabled = workspace.isMutationStateFresh && lifecycleAvailable(action, workspace: workspace)
            row.addArrangedSubview(button)
        }
        actionStack.addArrangedSubview(row)
    }

    private func addReviewAndMergeActions(_ workspace: RepositoryPullRequestReviewWorkspace) {
        let row = wrappingButtonRow()
        let review = makeButton(
            title: "Review…",
            identifier: RepositoryPullRequestReviewAccessibility.formalReview
        ) { [weak self] in self?.presentFormalReview() }
        review.isEnabled = workspace.isMutationStateFresh && formalReviewAvailable(workspace)
        row.addArrangedSubview(review)

        let method = RepositoryReviewPreferencePopUpButton()
        method.setAccessibilityIdentifier(RepositoryPullRequestReviewAccessibility.mergeMethod)
        let enabledMethods = ForgePullRequestMergeMethod.allCases.filter {
            if case .available = ForgePullRequestMergePolicy.confirmationDecision(
                snapshot: workspace.mergeSnapshot,
                method: $0
            ) {
                return true
            }
            return false
        }
        for item in enabledMethods {
            method.addItem(withTitle: mergeMethodTitle(item))
            method.lastItem?.representedObject = item.rawValue
        }
        method.isEnabled = workspace.isMutationStateFresh && !enabledMethods.isEmpty
        row.addArrangedSubview(method)

        let merge = makeButton(
            title: "Merge…",
            identifier: RepositoryPullRequestReviewAccessibility.merge
        ) { [weak self, weak method] in
            guard let raw = method?.selectedItem?.representedObject as? String,
                  let method = ForgePullRequestMergeMethod(rawValue: raw)
            else { return }
            self?.prepareMerge(method)
        }
        merge.isEnabled = workspace.isMutationStateFresh && !enabledMethods.isEmpty
        row.addArrangedSubview(merge)

        let queueAction: ForgePullRequestMergeQueueAction = workspace.mergeSnapshot.queueState == .queued
            ? .leave : .enter
        let queue = makeButton(
            title: queueAction == .enter ? "Enter Merge Queue" : "Leave Merge Queue",
            identifier: RepositoryPullRequestReviewAccessibility.mergeQueue
        ) { [weak self] in
            self?.perform { try await self?.session.changeMergeQueue(queueAction) }
        }
        queue.isEnabled = workspace.isMutationStateFresh && mergeQueueAvailable(queueAction, workspace: workspace)
        row.addArrangedSubview(queue)
        actionStack.addArrangedSubview(row)

        let preferredTask = Task { [weak self, weak method] in
            guard let preferred = await self?.session.preferredMergeMethod(),
                  !Task.isCancelled,
                  method?.hasUserSelected == false,
                  let index = method?.itemArray.firstIndex(where: {
                      $0.representedObject as? String == preferred.rawValue
                  })
            else { return }
            method?.selectItem(at: index)
        }
        actionPresentationTasks.append(preferredTask)
    }

    private func addPostMergeActions(_ workspace: RepositoryPullRequestReviewWorkspace) {
        let row = wrappingButtonRow()
        let fetch = makeButton(
            title: "Fetch Base",
            identifier: RepositoryPullRequestReviewAccessibility.fetchBase
        ) { [weak self] in self?.perform { try await self?.session.fetchBase() } }
        let checkout = makeButton(
            title: "Check Out Base",
            identifier: RepositoryPullRequestReviewAccessibility.checkOutBase
        ) { [weak self] in self?.perform { try await self?.session.checkOutBase() } }
        let fresh = workspace.isMutationStateFresh
        fetch.isEnabled = fresh
        checkout.isEnabled = fresh
        row.addArrangedSubview(fetch)
        row.addArrangedSubview(checkout)
        if workspace.headBranchDeletionSnapshot != nil {
            let delete = makeButton(
                title: "Delete Head Branch…",
                identifier: RepositoryPullRequestReviewAccessibility.deleteBranch
            ) { [weak self] in self?.confirmDeleteHeadBranch() }
            delete.isEnabled = fresh && canDeleteMergedHead(workspace)
            row.addArrangedSubview(delete)
        }
        actionStack.addArrangedSubview(row)
    }

    private func addPostMergeDeletionFailure(
        _ message: String,
        workspace: RepositoryPullRequestReviewWorkspace
    ) {
        actionStack.addArrangedSubview(banner(
            "Merge succeeded, but the separate head-branch deletion failed. \(message)",
            color: .systemOrange
        ))
        let row = wrappingButtonRow()
        let retry = makeButton(
            title: "Retry Branch Deletion",
            identifier: RepositoryPullRequestReviewAccessibility.deleteBranchRetry
        ) { [weak self] in self?.retryPostMergeDeletion() }
        retry.isEnabled = workspace.isMutationStateFresh
        row.addArrangedSubview(retry)
        row.addArrangedSubview(makeButton(
            title: "Open Pull Request in Browser",
            identifier: RepositoryPullRequestReviewAccessibility.deleteBranchOpenInBrowser
        ) { [weak self] in self?.router.openInBrowser(workspace.browserDestination) })
        actionStack.addArrangedSubview(row)
    }

    private func threadView(
        _ record: RepositoryPullRequestReviewThreadRecord,
        workspace: RepositoryPullRequestReviewWorkspace
    ) -> NSView {
        let isFresh = workspace.isMutationStateFresh
        var presentation = RepositoryReviewThreadPresenter.present(record)
        let id = record.presentation.thread.id
        if let override = threadExpansionOverrides[id] {
            presentation = presentation.updating(isExpanded: override)
        }
        let box = RepositoryReviewContentBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = presentation.isOutdated ? .systemOrange : .separatorColor
        box.cornerRadius = 4
        box.setAccessibilityIdentifier(RepositoryPullRequestReviewAccessibility.threadPrefix + id.value)
        box.setAccessibilityLabel(presentation.accessibilityLabel)
        let stack = NSStackView()
        configure(stack: stack)
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)
        installContent(stack, in: box)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        let expanded = presentation.isExpanded
        let toggle = makeButton(
            title: expanded ? "▾" : "▸",
            identifier: RepositoryPullRequestReviewAccessibility.threadPrefix + id.value + ".Toggle"
        ) { [weak self] in
            self?.threadExpansionOverrides[id] = !expanded
            self?.renderOverlay()
        }
        toggle.bezelStyle = .inline
        header.addArrangedSubview(toggle)
        let title = NSTextField(labelWithString: "\(presentation.title) — \(presentation.anchorText)")
        title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(title)
        if presentation.isOutdated {
            let marker = capsule(presentation.usesBestEffortLocalAnchor ? "OUTDATED · LOCAL MATCH" : "OUTDATED")
            marker.setAccessibilityIdentifier(RepositoryPullRequestReviewAccessibility.threadPrefix + id.value + ".Outdated")
            header.addArrangedSubview(marker)
        }
        stack.addArrangedSubview(header)
        guard expanded else { return box }

        for (index, comment) in presentation.comments.enumerated() {
            let commentView = NSStackView()
            configure(stack: commentView)
            commentView.setAccessibilityIdentifier(
                RepositoryPullRequestReviewAccessibility.threadPrefix + id.value + ".Comment.\(index)"
            )
            if let body = comment.bodyMarkdown {
                let document = ForgeMarkdownSanitizer().sanitize(
                    body,
                    context: markdownContext(for: record, workspace: workspace)
                )
                let bodyView = ForgeMarkdownNativeView(
                    document: document,
                    navigationRouter: markdownRouter
                )
                bodyView.setAccessibilityIdentifier(
                    RepositoryPullRequestReviewAccessibility.threadPrefix
                        + id.value + ".Comment.\(index).Markdown"
                )
                bodyView.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
                commentView.addArrangedSubview(bodyView)
            }
            if let status = comment.statusText {
                let statusLabel = banner(status, color: .secondaryLabelColor)
                statusLabel.setAccessibilityIdentifier(
                    RepositoryPullRequestReviewAccessibility.threadPrefix
                        + id.value + ".Comment.\(index).Status"
                )
                commentView.addArrangedSubview(statusLabel)
            }
            if let reactions = comment.reactionsText {
                let reactionLabel = NSTextField(labelWithString: reactions)
                reactionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                reactionLabel.textColor = .secondaryLabelColor
                reactionLabel.setAccessibilityIdentifier(
                    RepositoryPullRequestReviewAccessibility.threadPrefix + id.value + ".Reactions.\(index)"
                )
                commentView.addArrangedSubview(reactionLabel)
            }
            stack.addArrangedSubview(commentView)
        }
        let reply = makeMarkdownEditor(
            identifier: RepositoryPullRequestReviewAccessibility.threadPrefix + id.value + ".Reply",
            height: 50,
            context: markdownContext(for: record, workspace: workspace)
        )
        installReplyDraftEditor(reply.textView, threadID: id)
        stack.addArrangedSubview(reply)
        let controls = wrappingButtonRow()
        let replyButton = makeButton(
            title: "Reply",
            identifier: RepositoryPullRequestReviewAccessibility.threadPrefix + id.value + ".Reply.Publish"
        ) { [weak self, weak textView = reply.textView] in
            guard let body = textView?.string else { return }
            self?.publishReply(threadID: id, body: body)
        }
        replyButton.isEnabled = isFresh
            && workspaceAllows(.replyToReviewThread)
            && !replyWritesInFlight.contains(id)
        controls.addArrangedSubview(replyButton)

        let resolutionRow = wrappingButtonRow()
        controls.addArrangedSubview(resolutionRow)
        resolutionControlRows[id] = ResolutionControlRow(
            row: resolutionRow,
            isFresh: isFresh,
            presentation: nil
        )
        renderResolutionControls(
            threadID: id,
            state: session.resolutionStates[id] ?? .confirmed(isResolved: presentation.isResolved)
        )
        stack.addArrangedSubview(controls)

        for (index, suggestion) in presentation.suggestedChanges.enumerated() {
            let suggestionStack = NSStackView()
            configure(stack: suggestionStack)
            let preview = NSTextField(wrappingLabelWithString: "Suggested change in \(suggestion.path.value)\n− \(suggestion.originalText)\n+ \(suggestion.replacementText)")
            preview.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            preview.isSelectable = true
            suggestionStack.addArrangedSubview(preview)
            let apply = makeButton(
                title: "Apply Suggested Change",
                identifier: RepositoryPullRequestReviewAccessibility.threadPrefix + id.value + ".Suggestion.\(index).Apply"
            ) { [weak self] in self?.applySuggestion(suggestion) }
            apply.isEnabled = isFresh && suggestionInFlight == nil && !suggestion.isTruncated
            suggestionStack.addArrangedSubview(apply)
            stack.addArrangedSubview(suggestionStack)
        }
        return box
    }

    private func renderResolutionControls(
        threadID: ForgeObjectID,
        state: ForgeReviewThreadResolutionState
    ) {
        guard var controls = resolutionControlRows[threadID] else { return }
        let resolution = RepositoryReviewThreadResolutionPresenter.present(state)
        let resolutionOperation: ForgeOperation = resolution.isResolved
            ? .unresolveReviewThread : .resolveReviewThread
        let presentation = ResolutionControlPresentation(
            resolution: resolution,
            isEnabled: controls.isFresh && workspaceAllows(resolutionOperation)
        )
        guard controls.presentation != presentation else { return }
        controls.presentation = presentation
        resolutionControlRows[threadID] = controls
        clear(controls.row)
        let resolve = makeButton(
            title: resolution.isResolved ? "Unresolve" : "Resolve",
            identifier: RepositoryPullRequestReviewAccessibility.threadPrefix + threadID.value + ".Resolve"
        ) { [weak self] in
            self?.session.setResolution(
                threadID: threadID,
                mutation: resolution.isResolved ? .unresolve : .resolve
            )
        }
        resolve.isEnabled = presentation.isEnabled
        controls.row.addArrangedSubview(resolve)
        if resolution.canUndo {
            controls.row.addArrangedSubview(makeButton(
                title: "Undo",
                identifier: RepositoryPullRequestReviewAccessibility.threadPrefix + threadID.value + ".Undo"
            ) { [weak self] in self?.session.undoResolution(threadID: threadID) })
        }
    }

    private func inlineComposer(
        anchor: ForgeReviewAnchor,
        workspace: RepositoryPullRequestReviewWorkspace
    ) -> NSView {
        let box = RepositoryReviewContentBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.title = "New Inline Review at \(RepositoryReviewThreadPresenter.anchorDescription(anchor))"
        box.setAccessibilityIdentifier(RepositoryPullRequestReviewAccessibility.inlinePanel)
        let stack = NSStackView()
        configure(stack: stack)
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)
        installContent(stack, in: box)
        let editor = makeMarkdownEditor(
            identifier: RepositoryPullRequestReviewAccessibility.inlineBody,
            height: 64,
            context: ForgeMarkdownContext(
                repository: workspace.identity.repository,
                location: .file(
                    revision: .commit(selectedDisplayedHead ?? workspace.displayedHead),
                    path: anchor.path
                )
            )
        )
        installInlineDraftEditor(editor.textView, anchor: anchor, workspace: workspace)
        stack.addArrangedSubview(editor)
        let row = wrappingButtonRow()
        let publish = makeButton(
            title: "Publish Now",
            identifier: RepositoryPullRequestReviewAccessibility.inlinePublish
        ) { [weak self, weak textView = editor.textView] in
            guard let self, let body = textView?.string else { return }
            self.publishInline(anchor: anchor, body: body)
        }
        publish.isEnabled = workspace.isMutationStateFresh
            && workspace.mutationContext.environment == .available
            && workspace.mutationContext.allowedOperations.contains(.publishInlineReviewComment)
            && !selectedContextIsTruncated
            && !inlineWritesInFlight.contains(InlineWriteDestination(
                anchor: anchor,
                displayedHead: selectedDisplayedHead ?? workspace.displayedHead
            ))
        row.addArrangedSubview(publish)
        if let pendingReanchor {
            let confirm = makeButton(
                title: "Confirm Exact Re-anchor & Publish",
                identifier: RepositoryPullRequestReviewAccessibility.inlineReanchor
            ) { [weak self] in
                self?.confirmPendingReanchor(pendingReanchor)
            }
            confirm.isEnabled = !reanchorConfirmationInFlight
            row.addArrangedSubview(confirm)
            let warning = banner(
                "The displayed head changed. GitX found one exact context match; confirm the new location explicitly.",
                color: .systemOrange
            )
            stack.addArrangedSubview(warning)
        }
        if selectedContextIsTruncated {
            stack.addArrangedSubview(banner(
                "This selection is truncated and cannot be published.",
                color: .systemRed
            ))
        }
        stack.addArrangedSubview(row)
        return box
    }

    // MARK: - Actions and confirmation panels

    private func publishReply(threadID: ForgeObjectID, body: String) {
        guard replyWritesInFlight.insert(threadID).inserted else { return }
        renderOverlay()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                replyWritesInFlight.remove(threadID)
                render()
            }
            do {
                try await session.reply(threadID: threadID, bodyMarkdown: body)
            } catch is CancellationError {
                return
            } catch {
                transientMessage = error.localizedDescription
            }
        }
        tasks.append(task)
    }

    private func publishInline(anchor: ForgeReviewAnchor, body: String) {
        guard let workspace = session.workspace else { return }
        do {
            let context = try selectedReviewContext(anchor: anchor, workspace: workspace)
            let destination = InlineWriteDestination(anchor: anchor, displayedHead: context.displayedHead)
            guard inlineWritesInFlight.insert(destination).inserted else { return }
            renderOverlay()
            let task = Task { [weak self] in
                guard let self else { return }
                defer {
                    inlineWritesInFlight.remove(destination)
                    render()
                }
                do {
                    let pending = try await session.prepareInlinePublication(
                        context: context,
                        anchor: anchor,
                        bodyMarkdown: body
                    )
                    pendingReanchor = pending
                    if pending == nil {
                        clearSelection()
                        transientMessage = "Inline review comment published immediately."
                    }
                } catch is CancellationError {
                    return
                } catch {
                    transientMessage = error.localizedDescription
                }
            }
            tasks.append(task)
        } catch {
            transientMessage = error.localizedDescription
            render()
        }
    }

    private func confirmPendingReanchor(
        _ pending: RepositoryPullRequestReviewSession.PendingReanchor
    ) {
        guard !reanchorConfirmationInFlight, pendingReanchor == pending else { return }
        reanchorConfirmationInFlight = true
        renderOverlay()
        perform { [weak self] in
            guard let self else { return }
            defer {
                reanchorConfirmationInFlight = false
                render()
            }
            try await session.confirmReanchor(pending)
            clearSelection()
            transientMessage = "Inline review comment published at the confirmed exact re-anchor."
        }
    }

    private func selectedReviewContext(
        anchor: ForgeReviewAnchor,
        workspace: RepositoryPullRequestReviewWorkspace
    ) throws -> ForgeReviewContext {
        let displayedHead = selectedDisplayedHead ?? workspace.displayedHead
        selectedDisplayedHead = displayedHead
        return try ForgeReviewContext(
            repository: workspace.identity.repository,
            pullRequest: workspace.identity.number,
            displayedHead: displayedHead,
            path: anchor.path,
            lines: selectedContextLines,
            isTruncated: selectedContextIsTruncated
        )
    }

    private func installReplyDraftEditor(_ textView: NSTextView, threadID: ForgeObjectID) {
        let coordinator = RepositoryReviewDraftTextCoordinator(textView: textView) {
            [weak session = session] body in
            guard let session else { return }
            try await session.saveReplyDraft(threadID: threadID, bodyMarkdown: body)
        }
        overlayDraftCoordinators.append(coordinator)
        let task = Task { [weak session = session, weak coordinator] in
            do {
                let body = try await session?.loadReplyDraft(threadID: threadID) ?? ""
                guard !Task.isCancelled else { return }
                coordinator?.install(body)
            } catch {
                // Draft I/O failure is non-destructive and must not replace
                // the current server workspace or discard entered text.
            }
        }
        overlayDraftLoadTasks.append(task)
    }

    private func installInlineDraftEditor(
        _ textView: NSTextView,
        anchor: ForgeReviewAnchor,
        workspace: RepositoryPullRequestReviewWorkspace
    ) {
        guard let context = try? selectedReviewContext(anchor: anchor, workspace: workspace) else { return }
        let coordinator = RepositoryReviewDraftTextCoordinator(textView: textView) {
            [weak session = session] body in
            guard let session else { return }
            try await session.saveInlineDraft(
                context: context,
                anchor: anchor,
                bodyMarkdown: body
            )
        }
        overlayDraftCoordinators.append(coordinator)
        let task = Task { [weak session = session, weak coordinator] in
            do {
                let body = try await session?.loadInlineDraft(context: context, anchor: anchor) ?? ""
                guard !Task.isCancelled else { return }
                coordinator?.install(body)
            } catch {
                // Preserve whatever is already in the field when local draft
                // storage is temporarily unavailable.
            }
        }
        overlayDraftLoadTasks.append(task)
    }

    private func applySuggestion(_ suggestion: ForgeSuggestedChange) {
        guard suggestionInFlight == nil else { return }
        suggestionInFlight = suggestion
        renderOverlay()
        perform { [weak self] in
            guard let self else { return }
            defer {
                suggestionInFlight = nil
                render()
            }
            try await session.applySuggestedChange(suggestion)
            transientMessage = "Applied one suggested change as an unstaged local edit."
        }
    }

    private func presentFormalReview() {
        guard let workspace = session.workspace else { return }
        let displayedHead = workspace.displayedHead
        let panelStack = modalStack(identifier: RepositoryPullRequestReviewAccessibility.formalReviewSheet)
        addHeading("Submit Review", to: panelStack)
        let head = NSTextField(labelWithString: "Bound to displayed head \(displayedHead.value.prefix(12))")
        head.textColor = .secondaryLabelColor
        panelStack.addArrangedSubview(head)
        let kind = NSPopUpButton()
        kind.setAccessibilityIdentifier(RepositoryPullRequestReviewAccessibility.formalReviewKind)
        for value in ForgeFormalReviewKind.allCases where formalReviewAllowed(value, workspace: workspace) {
            kind.addItem(withTitle: formalReviewTitle(value))
            kind.lastItem?.representedObject = value.rawValue
        }
        panelStack.addArrangedSubview(kind)
        let editor = makeMarkdownEditor(
            identifier: RepositoryPullRequestReviewAccessibility.formalReviewBody,
            height: 110,
            context: ForgeMarkdownContext(
                repository: workspace.identity.repository,
                location: .repository(defaultBranch: .commit(displayedHead))
            )
        )
        let draftCoordinator = RepositoryReviewDraftTextCoordinator(textView: editor.textView) {
            [weak session = session] body in
            guard let session else { return }
            try await session.saveFormalReviewDraft(
                displayedHead: displayedHead,
                bodyMarkdown: body
            )
        }
        editor.textView.isEditable = false
        panelStack.addArrangedSubview(editor)
        let row = wrappingButtonRow()
        row.addArrangedSubview(makeButton(
            title: "Cancel",
            identifier: RepositoryPullRequestReviewAccessibility.formalReviewCancel
        ) { [weak self] in self?.closeModal() })
        let submit = makeButton(
            title: "Submit Review",
            identifier: RepositoryPullRequestReviewAccessibility.formalReviewSubmit
        ) { [weak self, weak kind, weak textView = editor.textView] in
            guard let raw = kind?.selectedItem?.representedObject as? String,
                  let reviewKind = ForgeFormalReviewKind(rawValue: raw),
                  let body = textView?.string
            else { return }
            self?.perform {
                try await self?.session.submitFormalReview(
                    displayedHead: displayedHead,
                    kind: reviewKind,
                    bodyMarkdown: body
                )
                self?.closeModal()
            }
        }
        submit.isEnabled = false
        row.addArrangedSubview(submit)
        panelStack.addArrangedSubview(row)
        presentModal(panelStack, title: "Pull Request Review")
        modalDraftCoordinator = draftCoordinator
        let task = Task { [weak self, weak draftCoordinator, weak textView = editor.textView, weak submit] in
            do {
                let draft = try await self?.session.loadFormalReviewDraft(displayedHead: displayedHead) ?? ""
                guard !Task.isCancelled else { return }
                draftCoordinator?.install(draft)
                textView?.isEditable = true
                submit?.isEnabled = true
            } catch {
                self?.transientMessage = error.localizedDescription
                self?.renderActionArea()
            }
        }
        tasks.append(task)
    }

    private func prepareMerge(_ method: ForgePullRequestMergeMethod) {
        perform { [weak self] in
            guard let self else { return }
            let confirmation = try await session.prepareMerge(method: method)
            presentMergeConfirmation(confirmation)
        }
    }

    private func prepareUpdateBranchConfirmation() {
        perform { [weak self] in
            guard let self else { return }
            let confirmation = try await session.prepareUpdateBranch()
            presentUpdateBranchConfirmation(confirmation)
        }
    }

    private func presentUpdateBranchConfirmation(
        _ confirmation: RepositoryPullRequestReviewSession.UpdateBranchConfirmation
    ) {
        let panelStack = modalStack(identifier: RepositoryPullRequestReviewAccessibility.updateBranchSheet)
        addHeading("Confirm Update Branch", to: panelStack)
        panelStack.addArrangedSubview(banner(
            "GitHub will update head \(confirmation.head.value.prefix(12)) from base \(confirmation.base.value.prefix(12)). This is separate from Merge and is never automatic.",
            color: .systemOrange
        ))
        let row = wrappingButtonRow()
        row.addArrangedSubview(makeButton(
            title: "Cancel",
            identifier: RepositoryPullRequestReviewAccessibility.updateBranchCancel
        ) { [weak self] in self?.closeModal() })
        row.addArrangedSubview(makeButton(
            title: "Confirm Update Branch",
            identifier: RepositoryPullRequestReviewAccessibility.updateBranchConfirm
        ) { [weak self] in
            self?.perform {
                try await self?.session.confirmUpdateBranch(confirmation)
                self?.closeModal()
            }
        })
        panelStack.addArrangedSubview(row)
        presentModal(panelStack, title: "Update Pull Request Branch")
    }

    private func presentMergeConfirmation(_ confirmation: ForgePullRequestMergeConfirmation) {
        let panelStack = modalStack(identifier: RepositoryPullRequestReviewAccessibility.mergeSheet)
        addHeading("Confirm \(mergeMethodTitle(confirmation.method))", to: panelStack)
        let warningText = confirmation.warnings.isEmpty
            ? "No current blockers reported. GitHub remains authoritative."
            : confirmation.warnings
            .sorted { $0.rawValue < $1.rawValue }
            .map { "• \(mergeWarningTitle($0))" }
            .joined(separator: "\n")
        let warnings = banner(warningText, color: confirmation.warnings.isEmpty ? .secondaryLabelColor : .systemOrange)
        warnings.setAccessibilityIdentifier(RepositoryPullRequestReviewAccessibility.mergeWarnings)
        panelStack.addArrangedSubview(warnings)
        let title = NSTextField(string: session.workspace?.title ?? "")
        title.placeholderString = "Merge title"
        title.setAccessibilityIdentifier(RepositoryPullRequestReviewAccessibility.mergeTitle)
        let message = makeTextEditor(
            identifier: RepositoryPullRequestReviewAccessibility.mergeMessage,
            height: 82
        )
        if confirmation.method == .rebase {
            let summary = NSTextField(wrappingLabelWithString: "Rebase preserves commit messages; title and message are read-only.")
            summary.textColor = .secondaryLabelColor
            panelStack.addArrangedSubview(summary)
        } else {
            panelStack.addArrangedSubview(title)
            panelStack.addArrangedSubview(message.container)
        }
        let delete = RepositoryReviewPreferenceCheckbox(title: "Delete head branch after merge")
        delete.state = .off
        delete.isEnabled = session.workspace?.canOfferHeadBranchDeletionAfterMerge == true
        delete.setAccessibilityIdentifier(RepositoryPullRequestReviewAccessibility.mergeDeleteBranch)
        panelStack.addArrangedSubview(delete)
        let row = wrappingButtonRow()
        row.addArrangedSubview(makeButton(
            title: "Cancel",
            identifier: RepositoryPullRequestReviewAccessibility.mergeCancel
        ) { [weak self] in self?.closeModal() })
        row.addArrangedSubview(makeButton(
            title: "Confirm Merge",
            identifier: RepositoryPullRequestReviewAccessibility.mergeConfirm
        ) { [weak self, weak title, weak textView = message.textView, weak delete] in
            self?.perform {
                guard let self else { return }
                let completion = try await self.session.confirmMerge(
                    confirmation,
                    title: confirmation.method == .rebase ? nil : title?.stringValue,
                    message: confirmation.method == .rebase ? nil : textView?.string,
                    deleteHeadBranchChoice: delete?.state == .on
                )
                switch completion {
                case .merged:
                    self.transientMessage = "Pull Request merged. The local checkout was not changed."
                case .mergedAndDeletedHeadBranch:
                    self.transientMessage = "Pull Request merged and its head branch was deleted separately."
                case let .mergedWithHeadBranchDeletionFailure(message):
                    self.postMergeDeletionFailure = message
                }
                self.closeModal()
                self.render()
            }
        })
        panelStack.addArrangedSubview(row)
        presentModal(panelStack, title: "Confirm Merge")
        let task = Task { [weak self, weak delete] in
            let remembered = await self?.session.rememberedDeleteBranchChoice() ?? false
            guard !Task.isCancelled,
                  delete?.isEnabled == true,
                  delete?.hasUserSelected == false
            else { return }
            delete?.state = remembered ? .on : .off
        }
        tasks.append(task)
    }

    private func confirmDeleteHeadBranch() {
        let panelStack = modalStack(identifier: RepositoryPullRequestReviewAccessibility.deleteBranch + ".Sheet")
        addHeading("Delete Head Branch?", to: panelStack)
        panelStack.addArrangedSubview(banner(
            "This is a separate, destructive GitHub mutation. Merge success is not changed if deletion fails.",
            color: .systemOrange
        ))
        let row = wrappingButtonRow()
        row.addArrangedSubview(makeButton(title: "Cancel", identifier: "GitX.PullRequest.Review.DeleteBranch.Cancel") {
            [weak self] in self?.closeModal()
        })
        row.addArrangedSubview(makeButton(title: "Delete Branch", identifier: "GitX.PullRequest.Review.DeleteBranch.Confirm") {
            [weak self] in
            self?.perform {
                try await self?.session.deleteHeadBranch()
                self?.closeModal()
            }
        })
        panelStack.addArrangedSubview(row)
        presentModal(panelStack, title: "Delete Head Branch")
    }

    private func retryPostMergeDeletion() {
        perform { [weak self] in
            guard let self else { return }
            do {
                try await session.deleteHeadBranch()
                postMergeDeletionFailure = nil
                transientMessage = "Deleted the merged Pull Request head branch."
            } catch {
                postMergeDeletionFailure = error.localizedDescription
                throw error
            }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        let task = Task { [weak self] in
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                self?.transientMessage = error.localizedDescription
                self?.render()
            }
        }
        tasks.append(task)
    }

    // MARK: - AppKit helpers

    private func makeOverlayRoot() -> NSView {
        configure(stack: overlayStack, identifier: RepositoryPullRequestReviewAccessibility.overlayRoot)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.setAccessibilityIdentifier(RepositoryPullRequestReviewAccessibility.threads)
        let document = RepositoryReviewFlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(overlayStack)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            overlayStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            overlayStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            overlayStack.topAnchor.constraint(equalTo: document.topAnchor),
            overlayStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 330).isActive = true
        let box = makeSnowLeopardBox(containing: scroll)
        overlayContentBox = box
        box.setAccessibilityIdentifier(RepositoryPullRequestReviewAccessibility.overlayRoot)
        renderOverlay()
        return box
    }

    private func makeSnowLeopardBox(containing content: NSView) -> RepositoryReviewContentBox {
        let box = RepositoryReviewContentBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.96)
        box.cornerRadius = 5
        box.contentViewMargins = NSSize(width: 10, height: 8)
        installContent(content, in: box)
        return box
    }

    private func installContent(_ content: NSView, in box: RepositoryReviewContentBox) {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        box.installMeasuredContentView(container)
        box.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    private func configure(stack: NSStackView, identifier: String? = nil) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        if let identifier {
            stack.setAccessibilityIdentifier(identifier)
        }
    }

    private func addFullWidthArrangedSubview(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        let horizontalInsets = stack.edgeInsets.left + stack.edgeInsets.right
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -horizontalInsets).isActive = true
    }

    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func clear(_ row: RepositoryReviewWrappingButtonRow) {
        row.removeAllArrangedSubviews()
    }

    private func addHeading(_ text: String, to stack: NSStackView) {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .controlTextColor
        stack.addArrangedSubview(label)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func banner(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = color
        label.maximumNumberOfLines = 4
        label.setAccessibilityLabel(text)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func capsule(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize - 1)
        label.textColor = .systemOrange
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        label.layer?.cornerRadius = 4
        return label
    }

    private func wrappingButtonRow() -> RepositoryReviewWrappingButtonRow {
        RepositoryReviewWrappingButtonRow(horizontalSpacing: 6, verticalSpacing: 6)
    }

    private func makeButton(
        title: String,
        identifier: String,
        action: @escaping @MainActor () -> Void
    ) -> NSButton {
        let button = RepositoryReviewButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        return button
    }

    private func makeTextEditor(identifier: String, height: CGFloat) -> (container: NSScrollView, textView: NSTextView) {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let text = NSTextView()
        text.isRichText = false
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.textContainerInset = NSSize(width: 5, height: 5)
        text.setAccessibilityIdentifier(identifier)
        scroll.documentView = text
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        return (scroll, text)
    }

    private func makeMarkdownEditor(
        identifier: String,
        height: CGFloat,
        context: ForgeMarkdownContext
    ) -> RepositoryReviewMarkdownEditor {
        RepositoryReviewMarkdownEditor(
            identifier: identifier,
            height: height,
            context: context,
            navigationRouter: markdownRouter
        )
    }

    private func markdownContext(
        for record: RepositoryPullRequestReviewThreadRecord,
        workspace: RepositoryPullRequestReviewWorkspace
    ) -> ForgeMarkdownContext {
        let location: ForgeMarkdownLocation
        let anchor: ForgeReviewAnchor? = switch record.presentation.thread.anchor {
        case let .available(value): value
        case .unavailable: nil
        }
        if let anchor {
            location = .file(revision: .commit(workspace.displayedHead), path: anchor.path)
        } else {
            location = .repository(defaultBranch: .commit(workspace.displayedHead))
        }
        return ForgeMarkdownContext(repository: workspace.identity.repository, location: location)
    }

    private func modalStack(identifier: String) -> NSStackView {
        let stack = NSStackView()
        configure(stack: stack, identifier: identifier)
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        return stack
    }

    private func presentModal(_ content: NSView, title: String) {
        closeModal()
        content.setAccessibilityLabel(title)
        if let owner = view.window {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 310),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            panel.title = title
            panel.contentView = content
            modalPanel = panel
            owner.beginSheet(panel)
        } else {
            embeddedModalView = content
            actionStack.addArrangedSubview(content)
        }
    }

    private func closeModal() {
        modalDraftCoordinator?.detach()
        modalDraftCoordinator = nil
        if let panel = modalPanel {
            modalPanel = nil
            panel.sheetParent?.endSheet(panel)
            panel.orderOut(nil)
        }
        if let modal = embeddedModalView {
            embeddedModalView = nil
            if actionStack.arrangedSubviews.contains(where: { $0 === modal }) {
                actionStack.removeArrangedSubview(modal)
            }
            if modal.superview != nil {
                modal.removeFromSuperview()
            }
        }
    }

    // MARK: - Presentation decisions

    private func reviewersDescription(_ value: ForgeReadSection<[ForgeReviewer]>) -> String {
        switch value {
        case let .available(reviewers):
            guard !reviewers.isEmpty else { return "Reviewers: none" }
            return "Reviewers: " + reviewers.map { reviewer in
                let name: String = switch reviewer.participant {
                case let .actor(actor): actor.displayName ?? "@\(actor.login)"
                case let .team(team): team.name
                }
                let state = reviewer.latestReviewState.map { " — \(reviewStateTitle($0))" }
                    ?? (reviewer.isRequested ? " — requested" : "")
                return name + state
            }.joined(separator: ", ")
        case let .unavailable(reason):
            return "Reviewers unavailable (\(reason.rawValue))"
        }
    }

    private func lifecycleAvailable(
        _ action: ForgePullRequestLifecycleAction,
        workspace: RepositoryPullRequestReviewWorkspace
    ) -> Bool {
        if case .available = ForgePullRequestLifecyclePolicy.decision(
            context: workspace.mutationContext,
            action: action,
            canUpdateBranch: workspace.canUpdateBranch
        ) {
            return true
        }
        return false
    }

    private func formalReviewAvailable(_ workspace: RepositoryPullRequestReviewWorkspace) -> Bool {
        let allowed = workspace.mutationContext.allowedOperations
        return workspace.mutationContext.environment == .available
            && workspace.mutationContext.state == .open && (
                allowed.contains(.submitApproveReview)
                    || allowed.contains(.submitCommentReview)
                    || allowed.contains(.submitRequestChangesReview)
            )
    }

    private func formalReviewAllowed(
        _ kind: ForgeFormalReviewKind,
        workspace: RepositoryPullRequestReviewWorkspace
    ) -> Bool {
        guard workspace.mutationContext.environment == .available,
              workspace.mutationContext.state == .open
        else { return false }
        let operation: ForgeOperation = switch kind {
        case .approve: .submitApproveReview
        case .comment: .submitCommentReview
        case .requestChanges: .submitRequestChangesReview
        }
        return workspace.mutationContext.allowedOperations.contains(operation)
    }

    private func workspaceAllows(_ operation: ForgeOperation) -> Bool {
        guard let workspace = session.workspace else { return false }
        return workspace.mutationContext.environment == .available
            && workspace.mutationContext.allowedOperations.contains(operation)
    }

    private func mergeQueueAvailable(
        _ action: ForgePullRequestMergeQueueAction,
        workspace: RepositoryPullRequestReviewWorkspace
    ) -> Bool {
        if case .available = ForgePullRequestMergeQueuePolicy.decision(
            snapshot: workspace.mergeSnapshot,
            action: action
        ) {
            return true
        }
        return false
    }

    private func canDeleteMergedHead(_ workspace: RepositoryPullRequestReviewWorkspace) -> Bool {
        guard let snapshot = workspace.headBranchDeletionSnapshot else { return false }
        return workspace.mutationContext.environment == .available
            && workspace.mutationContext.state == .merged
            && snapshot.isSameRepository
            && !snapshot.isDefaultBranch
            && !snapshot.isProtected
            && snapshot.viewerCanDelete
            && !snapshot.hasCheckedOutSafetyConflict
            && workspace.mutationContext.allowedOperations.contains(.deleteHeadBranch)
    }

    private func lifecycleTitle(_ action: ForgePullRequestLifecycleAction) -> String {
        switch action {
        case .markReady: "Mark Ready"
        case .convertToDraft: "Convert to Draft"
        case .close: "Close"
        case .reopen: "Reopen"
        case .updateBranch: "Update Branch"
        }
    }

    private func formalReviewTitle(_ kind: ForgeFormalReviewKind) -> String {
        switch kind {
        case .approve: "Approve"
        case .comment: "Comment"
        case .requestChanges: "Request Changes"
        }
    }

    private func mergeMethodTitle(_ method: ForgePullRequestMergeMethod) -> String {
        switch method {
        case .merge: "Merge Commit"
        case .squash: "Squash and Merge"
        case .rebase: "Rebase and Merge"
        }
    }

    private func mergeWarningTitle(_ warning: ForgePullRequestMergeWarning) -> String {
        switch warning {
        case .mergeabilityUnknown: "Mergeability is still being calculated"
        case .mergeConflictReported: "GitHub reports merge conflicts"
        case .checksPending: "Checks are pending"
        case .checksFailing: "Checks are failing"
        case .reviewRequired: "A required review is missing"
        case .changesRequested: "Changes were requested"
        case .branchBehind: "The head branch is behind the base"
        }
    }

    private func reviewStateTitle(_ state: ForgeReviewState) -> String {
        switch state {
        case .approved: "approved"
        case .changesRequested: "changes requested"
        case .commented: "commented"
        case .dismissed: "dismissed"
        }
    }
}

@MainActor
private final class RepositoryPullRequestReviewMarkdownRouter: ForgeMarkdownNavigationRouting {
    private weak var reviewRouter: (any RepositoryPullRequestReviewRouting)?
    private weak var centralRouter: (any ForgeMarkdownNavigationRouting)?

    init(router: any RepositoryPullRequestReviewRouting) {
        reviewRouter = router
        centralRouter = router as? any ForgeMarkdownNavigationRouting
    }

    func activateMarkdownLink(_ target: ForgeMarkdownLinkTarget) {
        if let centralRouter {
            centralRouter.activateMarkdownLink(target)
        } else if case let .native(destination) = target {
            reviewRouter?.openInBrowser(destination)
        }
    }

    func openMarkdownLinkInBrowser(_ url: URL) {
        centralRouter?.openMarkdownLinkInBrowser(url)
    }
}

@MainActor
private final class RepositoryReviewMarkdownEditor: NSStackView {
    let textView = NSTextView()
    private let writeView = NSScrollView()
    private let previewContainer = NSView()
    private let modeControl = NSSegmentedControl(
        labels: ["Write", "Preview"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let context: ForgeMarkdownContext
    private weak var navigationRouter: (any ForgeMarkdownNavigationRouting)?
    private var previewView: ForgeMarkdownNativeView?

    init(
        identifier: String,
        height: CGFloat,
        context: ForgeMarkdownContext,
        navigationRouter: any ForgeMarkdownNavigationRouting
    ) {
        self.context = context
        self.navigationRouter = navigationRouter
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 5
        translatesAutoresizingMaskIntoConstraints = false

        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(changeMode(_:))
        modeControl.setAccessibilityIdentifier(identifier + ".WritePreview")
        modeControl.setAccessibilityLabel("Markdown editor mode")
        addArrangedSubview(modeControl)

        writeView.borderType = .bezelBorder
        writeView.hasVerticalScroller = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.setAccessibilityIdentifier(identifier)
        writeView.documentView = textView
        writeView.heightAnchor.constraint(equalToConstant: height).isActive = true
        writeView.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        addArrangedSubview(writeView)

        previewContainer.isHidden = true
        previewContainer.setAccessibilityIdentifier(identifier + ".Preview")
        previewContainer.heightAnchor.constraint(equalToConstant: height).isActive = true
        previewContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        addArrangedSubview(previewContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changeMode(_: Any?) {
        let showsPreview = modeControl.selectedSegment == 1
        writeView.isHidden = showsPreview
        previewContainer.isHidden = !showsPreview
        guard showsPreview else { return }
        previewView?.removeFromSuperview()
        let document = ForgeMarkdownSanitizer().sanitize(textView.string, context: context)
        let preview = ForgeMarkdownNativeView(document: document, navigationRouter: navigationRouter)
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            preview.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            preview.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
        ])
        previewView = preview
    }
}

@MainActor
private final class RepositoryReviewDraftTextCoordinator: NSObject, NSTextViewDelegate {
    private weak var textView: NSTextView?
    private let save: @MainActor (String) async throws -> Void
    private var isInstalling = false
    private var saveTask: Task<Void, Never>?

    init(
        textView: NSTextView,
        save: @escaping @MainActor (String) async throws -> Void
    ) {
        self.textView = textView
        self.save = save
        super.init()
        textView.delegate = self
    }

    func install(_ body: String) {
        guard let textView, textView.string.isEmpty else { return }
        isInstalling = true
        textView.string = body
        isInstalling = false
    }

    func textDidChange(_ notification: Notification) {
        guard !isInstalling,
              let textView = notification.object as? NSTextView,
              textView === self.textView
        else { return }
        let body = textView.string
        saveTask?.cancel()
        saveTask = Task { [save] in
            do {
                try await save(body)
            } catch is CancellationError {
                return
            } catch {
                // The editor keeps the user's text. Publication also saves
                // before dispatch, so a transient autosave failure cannot
                // turn a failed network mutation into lost input.
            }
        }
    }

    func detach() {
        if textView?.delegate === self {
            textView?.delegate = nil
        }
        textView = nil
    }
}

@MainActor
private final class RepositoryReviewPreferencePopUpButton: NSPopUpButton {
    private(set) var hasUserSelected = false

    init() {
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(recordUserSelection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func recordUserSelection() {
        hasUserSelected = true
    }
}

@MainActor
private final class RepositoryReviewWrappingButtonRow: NSView {
    private struct Line {
        let views: [(view: NSView, size: NSSize)]
        let height: CGFloat
    }

    private let horizontalSpacing: CGFloat
    private let verticalSpacing: CGFloat
    private var superviewWidthConstraint: NSLayoutConstraint?

    init(horizontalSpacing: CGFloat, verticalSpacing: CGFloat) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        superviewWidthConstraint?.isActive = false
        if superview is RepositoryReviewWrappingButtonRow {
            translatesAutoresizingMaskIntoConstraints = true
            superviewWidthConstraint = nil
            return
        }
        translatesAutoresizingMaskIntoConstraints = false
        guard let superview else {
            superviewWidthConstraint = nil
            return
        }
        let stackInsets = (superview as? NSStackView)?.edgeInsets ?? NSEdgeInsets()
        superviewWidthConstraint = widthAnchor.constraint(
            equalTo: superview.widthAnchor,
            constant: -(stackInsets.left + stackInsets.right)
        )
        superviewWidthConstraint?.isActive = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            invalidateWrappingLayout()
        }
    }

    override var intrinsicContentSize: NSSize {
        let availableWidth = bounds.width > 0 ? bounds.width : naturalWidth
        let fittedLines = lines(fitting: availableWidth)
        let height = fittedLines.map(\.height).reduce(0, +)
            + (verticalSpacing * CGFloat(max(0, fittedLines.count - 1)))
        return NSSize(
            width: superview is RepositoryReviewWrappingButtonRow ? naturalWidth : NSView.noIntrinsicMetric,
            height: height
        )
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for line in lines(fitting: bounds.width) {
            var x: CGFloat = 0
            for entry in line.views {
                entry.view.frame = NSRect(
                    x: x,
                    y: y + ((line.height - entry.size.height) / 2),
                    width: entry.size.width,
                    height: entry.size.height
                )
                x += entry.size.width + horizontalSpacing
            }
            y += line.height + verticalSpacing
        }
    }

    func addArrangedSubview(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = !(view is RepositoryReviewWrappingButtonRow)
        addSubview(view)
        invalidateWrappingLayout()
    }

    func removeAllArrangedSubviews() {
        subviews.forEach { $0.removeFromSuperview() }
        invalidateWrappingLayout()
    }

    private func invalidateWrappingLayout() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        (superview as? RepositoryReviewWrappingButtonRow)?.invalidateWrappingLayout()
    }

    private var naturalWidth: CGFloat {
        let widths = subviews.map { fittingSize(for: $0).width }
        return widths.reduce(0, +) + (horizontalSpacing * CGFloat(max(0, widths.count - 1)))
    }

    private func lines(fitting availableWidth: CGFloat) -> [Line] {
        let width = max(1, availableWidth)
        var result: [Line] = []
        var entries: [(view: NSView, size: NSSize)] = []
        var usedWidth: CGFloat = 0
        var height: CGFloat = 0
        for view in subviews {
            let size = fittingSize(for: view, maximumWidth: width)
            let proposedWidth = entries.isEmpty ? size.width : usedWidth + horizontalSpacing + size.width
            if !entries.isEmpty, proposedWidth > width {
                result.append(Line(views: entries, height: height))
                entries = []
                usedWidth = 0
                height = 0
            }
            entries.append((view, size))
            usedWidth = entries.count == 1 ? size.width : usedWidth + horizontalSpacing + size.width
            height = max(height, size.height)
        }
        if !entries.isEmpty {
            result.append(Line(views: entries, height: height))
        }
        return result
    }

    private func fittingSize(for view: NSView, maximumWidth: CGFloat? = nil) -> NSSize {
        if let nestedRow = view as? RepositoryReviewWrappingButtonRow,
           let maximumWidth
        {
            let width = min(ceil(nestedRow.naturalWidth), maximumWidth)
            let fittedLines = nestedRow.lines(fitting: width)
            let height = fittedLines.map(\.height).reduce(0, +)
                + (nestedRow.verticalSpacing * CGFloat(max(0, fittedLines.count - 1)))
            return NSSize(width: width, height: ceil(height))
        }
        let size = view.fittingSize
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }
}

@MainActor
private final class RepositoryReviewContentBox: NSBox {
    private var measurementWidthConstraint: NSLayoutConstraint?

    func installMeasuredContentView(_ view: NSView) {
        contentView = view
        let initialWidth = max(1, bounds.width > horizontalInsets ? bounds.width - horizontalInsets : view.fittingSize.width)
        let constraint = view.widthAnchor.constraint(equalToConstant: initialWidth)
        constraint.priority = NSLayoutConstraint.Priority(999)
        constraint.isActive = true
        measurementWidthConstraint = constraint
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            measurementWidthConstraint?.constant = max(1, newSize.width - horizontalInsets)
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let contentView else { return super.intrinsicContentSize }
        let contentSize = contentView.fittingSize
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: contentSize.height + (contentViewMargins.height * 2) + (borderWidth * 2)
        )
    }

    private var horizontalInsets: CGFloat {
        (contentViewMargins.width * 2) + (borderWidth * 2)
    }
}

@MainActor
private final class RepositoryReviewFlippedDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

@MainActor
private final class RepositoryReviewPreferenceCheckbox: NSButton {
    private(set) var hasUserSelected = false

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        setButtonType(.switch)
        target = self
        action = #selector(recordUserSelection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func recordUserSelection() {
        hasUserSelected = true
    }
}

@MainActor
private final class RepositoryReviewButton: NSButton {
    private let handler: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(invoke)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func invoke() {
        handler()
    }
}

/// Production host shared by the Overview and Changes modes. One exact
/// account/repository/number identity owns one session until selection changes.
@MainActor
final class RepositoryPullRequestReviewOverlayHost: NSObject,
    RepositoryPullRequestReviewOverlayHosting
{
    var onSelectedAnchor: ((ForgeReviewAnchor, [String], Bool) -> Void)?

    private let applicationSession: RepositoryPullRequestReviewApplicationSession
    private let accountID: ForgeAccountID
    private let router: any RepositoryPullRequestReviewRouting
    private var identity: RepositoryPullRequestReviewIdentity?
    private var controller: RepositoryPullRequestReviewOverlayController?
    private weak var nativeDiffView: PBNativeContentView?
    private var diff: RepositoryLocalPullRequestDiff?
    private var selectionObserver: NSObjectProtocol?
    private var textStorageObserver: NSObjectProtocol?
    private struct HighlightedRange {
        let range: NSRange
        let original: NSAttributedString
    }

    private var highlightedRanges: [HighlightedRange] = []
    private var isApplyingServerAnchorPlacements = false
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "PullRequestReviewOverlay")

    init(
        applicationSession: RepositoryPullRequestReviewApplicationSession,
        accountID: ForgeAccountID,
        router: any RepositoryPullRequestReviewRouting
    ) {
        self.applicationSession = applicationSession
        self.accountID = accountID
        self.router = router
        super.init()
    }

    isolated deinit {
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
        if let textStorageObserver {
            NotificationCenter.default.removeObserver(textStorageObserver)
        }
    }

    func actionView(for pullRequest: ForgePullRequestSummary) -> NSView {
        activate(pullRequest)
        return controller?.view ?? unavailableView("Review session identity is invalid.")
    }

    func install(
        in nativeDiffView: PBNativeContentView,
        pullRequest: ForgePullRequestSummary,
        diff: RepositoryLocalPullRequestDiff
    ) {
        activate(pullRequest)
        if self.nativeDiffView !== nativeDiffView {
            removeObservers()
            removeHighlights()
            self.nativeDiffView?.setAccessory(nil)
        } else {
            removeObservers()
        }
        self.nativeDiffView = nativeDiffView
        self.diff = diff
        _ = controller?.view
        nativeDiffView.setAccessory(controller?.reviewOverlayView)
        observeSelection(in: nativeDiffView)
        applyServerAnchorPlacements()
        logger.info("Installed exact-account native review overlay in the local diff")
    }

    func refresh() {
        controller?.start()
        logger.info("Refreshing the active native Pull Request review session")
    }

    func detach() {
        removeObservers()
        removeHighlights()
        nativeDiffView?.setAccessory(nil)
        nativeDiffView = nil
        diff = nil
        controller?.detach()
        controller = nil
        identity = nil
        logger.info("Detached native Pull Request review session and cancelled owned work")
    }

    func failClosedAfterRepositoryRefresh(_ message: String) {
        controller?.failClosedAfterRepositoryRefresh(message)
        logger.error("Failed the active native review session closed after repository refresh failure")
    }

    private func activate(_ pullRequest: ForgePullRequestSummary) {
        guard let nextIdentity = try? RepositoryPullRequestReviewIdentity(
            accountID: accountID,
            repository: pullRequest.repository,
            number: pullRequest.number
        ) else {
            detach()
            return
        }
        guard identity != nextIdentity || controller == nil else { return }
        detach()
        identity = nextIdentity
        let session = applicationSession.makeReviewSession(identity: nextIdentity)
        let controller = RepositoryPullRequestReviewOverlayController(session: session, router: router)
        self.controller = controller
        controller.onWorkspacePresentationChange = { [weak self] in
            self?.applyServerAnchorPlacements()
        }
        controller.start()
        logger.info("Started native review session for exact selected Pull Request")
    }

    private func observeSelection(in nativeView: PBNativeContentView) {
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: nativeView.textView,
            queue: .main
        ) { [weak self] _ in
            // swift6-safety-justification: NotificationCenter delivers this observer on the requested main queue.
            MainActor.assumeIsolated { self?.mapCurrentSelection() }
        }
        if let storage = nativeView.textView.textStorage as NSTextStorage? {
            textStorageObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: storage,
                queue: .main
            ) { [weak self] _ in
                // swift6-safety-justification: NotificationCenter delivers this observer on the requested main queue.
                MainActor.assumeIsolated { self?.applyServerAnchorPlacements() }
            }
        }
        mapCurrentSelection()
    }

    private func mapCurrentSelection() {
        guard let nativeDiffView, let diff else { return }
        let range = nativeDiffView.textView.selectedRange()
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= (nativeDiffView.textView.string as NSString).length
        else {
            controller?.clearSelection()
            return
        }
        let selected = (nativeDiffView.textView.string as NSString).substring(with: range)
        do {
            let selection = try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
                patch: diff.patch,
                selectedText: selected
            )
            controller?.select(
                anchor: selection.anchor,
                contextLines: selection.contextLines,
                isTruncated: selection.isTruncated
            )
            onSelectedAnchor?(selection.anchor, selection.contextLines, selection.isTruncated)
            logger.info("Mapped explicit native diff selection to one exact review anchor")
        } catch {
            controller?.clearSelection()
            logger.info("Ignored native diff selection without one exact review anchor")
        }
    }

    private func applyServerAnchorPlacements() {
        guard !isApplyingServerAnchorPlacements else { return }
        isApplyingServerAnchorPlacements = true
        defer { isApplyingServerAnchorPlacements = false }
        guard let nativeDiffView, let diff, let workspace = controller?.sessionWorkspaceForHost else { return }
        removeHighlights()
        let renderedText = nativeDiffView.textView.string
        guard !renderedText.isEmpty else { return }
        var ranges: [NSRange] = []
        for record in workspace.threads {
            let thread = record.presentation.thread
            let anchor: ForgeReviewAnchor? = if thread.isOutdated {
                // An outdated server anchor is historical and must never be
                // presented as a current local placement. Only the exact,
                // unique local-context match computed by the workflow may be
                // highlighted.
                record.exactOutdatedLocalAnchor
            } else if case let .available(value) = thread.anchor {
                value
            } else {
                nil
            }
            guard let anchor else { continue }
            do {
                let placement = try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
                    patch: diff.patch,
                    renderedText: renderedText,
                    anchor: anchor
                )
                ranges.append(contentsOf: placement.characterRanges)
            } catch {
                logger.info("Review thread has no unique local rendered anchor; leaving it visibly unplaced")
            }
        }
        guard let storage = nativeDiffView.textView.textStorage else { return }
        for range in normalizedHighlightRanges(ranges) where NSMaxRange(range) <= storage.length {
            highlightedRanges.append(HighlightedRange(
                range: range,
                original: storage.attributedSubstring(from: range)
            ))
            storage.addAttributes([
                .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.18),
                .underlineColor: NSColor.systemOrange,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)
        }
    }

    private func removeHighlights() {
        guard let storage = nativeDiffView?.textView.textStorage else {
            highlightedRanges.removeAll()
            return
        }
        for highlight in highlightedRanges where NSMaxRange(highlight.range) <= storage.length {
            highlight.original.enumerateAttributes(
                in: NSRange(location: 0, length: highlight.original.length)
            ) { attributes, range, _ in
                storage.setAttributes(
                    attributes,
                    range: NSRange(
                        location: highlight.range.location + range.location,
                        length: range.length
                    )
                )
            }
        }
        highlightedRanges.removeAll()
    }

    private func normalizedHighlightRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted {
                $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
            }
        var result: [NSRange] = []
        for range in sorted {
            guard let previous = result.last else {
                result.append(range)
                continue
            }
            if range.location <= NSMaxRange(previous) {
                result[result.count - 1] = NSRange(
                    location: previous.location,
                    length: max(NSMaxRange(previous), NSMaxRange(range)) - previous.location
                )
            } else {
                result.append(range)
            }
        }
        return result
    }

    private func removeObservers() {
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
        if let textStorageObserver {
            NotificationCenter.default.removeObserver(textStorageObserver)
        }
        selectionObserver = nil
        textStorageObserver = nil
    }

    private func unavailableView(_ message: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .secondaryLabelColor
        return label
    }
}

private extension RepositoryPullRequestReviewOverlayController {
    var sessionWorkspaceForHost: RepositoryPullRequestReviewWorkspace? {
        session.workspace
    }
}
