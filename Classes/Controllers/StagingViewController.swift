import AppKit
import ObjectiveGit

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

/// The staging interface hosted inside the History view's Details tab when the
/// Uncommitted Changes row is selected: file lists and commit composer on the
/// left, the staging diff pane on the right. Ports the commit workflow from
/// the standalone Commit view controller.
@objc(PBStagingViewController)
final class StagingViewController: NSViewController, NSTextViewDelegate, NSMenuDelegate, NSMenuItemValidation {
    private static let minimalCommitMessageLength = 3

    private unowned let repository: PBGitRepository
    @objc private(set) weak var host: PBGitHistoryController?

    @objc let fileListController: StagingFileListController
    @objc let diffPaneController: StagingDiffPaneController
    private let commitWorkflowState = CommitWorkflowState()
    private let repositoryUISettings: RepositoryUISettings
    private var commitProgressSheet: CommitProgressSheetController?
    private var selectionCoalescer: RefreshCoalescer?
    private var pushCapabilityAvailable = false
    private var pendingCreatePullRequestAfterPush = false
    private var submissionObservation: NSKeyValueObservation?
    private var pendingMutationObservation: NSKeyValueObservation?

    /// A local filesystem seam keeps filename-target tests away from Trash.
    @objc var trashItemHandler: (URL) -> Bool = { url in
        (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
    }

    @objc let commitMessageView: PBCommitMessageView
    private let commitButton = NSButton(title: NSLocalizedString("Commit", comment: "Commit button in the staging pane"), target: nil, action: nil)
    private let amendButton = NSButton(checkboxWithTitle: NSLocalizedString("Amend", comment: "Amend checkbox in the staging pane"), target: nil, action: nil)
    private let pushAfterCommitButton = NSButton(checkboxWithTitle: NSLocalizedString("Push to", comment: "Push-after-commit checkbox in the staging pane"), target: nil, action: nil)
    private let createPullRequestAfterPushButton = NSButton(
        checkboxWithTitle: NSLocalizedString(
            "Create Pull Request",
            comment: "One-shot Create Pull Request after push checkbox"
        ),
        target: nil,
        action: nil
    )
    private let pushRemotePopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sortPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    @objc let searchField = NSSearchField()
    private let optionsButton = NSButton(title: "", target: nil, action: nil)
    private let optionsMenu = NSMenu()

    private var index: PBGitIndex {
        repository.index
    }

    private var windowController: PBGitWindowController? {
        host?.windowController
    }

    @objc(initWithRepository:hostController:)
    init(repository: PBGitRepository, hostController: PBGitHistoryController) {
        self.repository = repository
        host = hostController
        fileListController = StagingFileListController(repository: repository, index: repository.index)
        diffPaneController = StagingDiffPaneController(repository: repository)
        repositoryUISettings = RepositoryUISettings(repository: repository)
        commitMessageView = PBCommitMessageView(frame: .zero)
        super.init(nibName: nil, bundle: nil)

        let center = NotificationCenter.default
        let index = repository.index
        center.addObserver(self, selector: #selector(refreshFinished(_:)), name: NSNotification.Name(PBGitIndexFinishedIndexRefresh), object: index)
        center.addObserver(self, selector: #selector(commitStatusUpdated(_:)), name: NSNotification.Name(PBGitIndexCommitStatus), object: index)
        center.addObserver(self, selector: #selector(commitOutputReceived(_:)), name: NSNotification.Name(PBGitIndexCommitOutput), object: index)
        center.addObserver(self, selector: #selector(commitFinished(_:)), name: NSNotification.Name(PBGitIndexFinishedCommit), object: index)
        center.addObserver(self, selector: #selector(commitFailed(_:)), name: NSNotification.Name(PBGitIndexCommitFailed), object: index)
        center.addObserver(self, selector: #selector(commitHookFailed(_:)), name: NSNotification.Name(PBGitIndexCommitHookFailed), object: index)
        center.addObserver(self, selector: #selector(amendMessageAvailable(_:)), name: NSNotification.Name(PBGitIndexAmendMessageAvailable), object: index)
        center.addObserver(self, selector: #selector(indexChanged(_:)), name: NSNotification.Name(PBGitIndexIndexUpdated), object: index)
        center.addObserver(self, selector: #selector(indexOperationFailed(_:)), name: NSNotification.Name(PBGitIndexOperationFailed), object: index)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StagingViewController is built in code")
    }

    @objc func closeView() {
        NotificationCenter.default.removeObserver(self)
        pendingMutationObservation = nil
        selectionCoalescer?.cancel()
        selectionCoalescer = nil
        if amendButton.infoForBinding(.value) != nil {
            amendButton.unbind(.value)
        }
        fileListController.close()
    }

    override func loadView() {
        let outerSplit = NSSplitView()
        outerSplit.isVertical = true
        outerSplit.dividerStyle = .thin
        outerSplit.autosaveName = "StagingPaneMain"

        let listColumn = NSView()
        listColumn.translatesAutoresizingMaskIntoConstraints = false
        let headerBar = makeHeaderBar()
        listColumn.addSubview(headerBar)
        listColumn.addSubview(fileListController.view)
        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: listColumn.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: listColumn.trailingAnchor),
            fileListController.view.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            fileListController.view.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor),
            fileListController.view.trailingAnchor.constraint(equalTo: listColumn.trailingAnchor),
            fileListController.view.bottomAnchor.constraint(equalTo: listColumn.bottomAnchor),
        ])

        let composerSplit = NSSplitView()
        composerSplit.isVertical = false
        composerSplit.dividerStyle = .thin
        composerSplit.autosaveName = "StagingPaneComposer"
        composerSplit.addArrangedSubview(listColumn)
        composerSplit.addArrangedSubview(makeComposerView())

        outerSplit.addArrangedSubview(composerSplit)
        outerSplit.addArrangedSubview(diffPaneController.contentView)
        outerSplit.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)

        view = outerSplit

        configureCommitMessageView()
        commitButton.target = self
        commitButton.action = #selector(commit(_:))
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = .command
        commitButton.setAccessibilityIdentifier("CommitButton")
        commitButton.isEnabled = false

        amendButton.bind(NSBindingName.value, to: index, withKeyPath: "amend", options: [.conditionallySetsEnabled: false])
        pushAfterCommitButton.target = self
        pushAfterCommitButton.action = #selector(pushAfterCommitChanged(_:))
        pushAfterCommitButton.setAccessibilityIdentifier("PushAfterCommit")
        createPullRequestAfterPushButton.setAccessibilityIdentifier("GitX.Staging.CreatePullRequestAfterPush")
        createPullRequestAfterPushButton.setAccessibilityLabel("Create Pull Request after pushing this commit")
        createPullRequestAfterPushButton.state = .off
        createPullRequestAfterPushButton.target = self
        createPullRequestAfterPushButton.action = #selector(createPullRequestAfterPushChanged(_:))
        pushRemotePopUpButton.setAccessibilityIdentifier("PushRemote")
        pushAfterCommitButton.state = repositoryUISettings.pushAfterCommit ? .on : .off

        let coalescer = RefreshCoalescer { [weak self] in
            self?.renderSelectedDiffs()
        }
        selectionCoalescer = coalescer
        fileListController.onSelectionChange = { [weak self] in
            guard let self else { return }
            diffPaneController.updateSelection(fileListController.currentDiffRequests)
            selectionCoalescer?.requestRefresh()
        }
        submissionObservation = index.observe(\.submissionActive, options: [.new]) { [weak self] _, _ in
            // swift6-safety-justification: The index changes submission state on the main thread.
            MainActor.assumeIsolated { self?.refreshOperationControls() }
        }
        pendingMutationObservation = index.observe(\.mutationReconciliationPending, options: [.initial, .new]) { [weak self] _, _ in
            // swift6-safety-justification: PBGitIndex publishes mutation state on the main thread; initial observation is installed by loadView.
            MainActor.assumeIsolated { self?.refreshOperationControls() }
        }
    }

    /// Refreshes everything that can go stale while the pane is hidden.
    @objc func updateView() {
        reloadPushRemotes()
        fileListController.rearrange()
        refreshOperationControls()
        if fileListController.currentDiffRequests.isEmpty {
            fileListController.selectInitialFile()
        }
        renderSelectedDiffs()
    }

    @objc var paneFirstResponder: NSResponder {
        commitMessageView
    }

    private func renderSelectedDiffs() {
        diffPaneController.render(fileListController.currentDiffRequests)
    }

    // MARK: Header bar

    private func makeHeaderBar() -> NSView {
        sortPopUpButton.addItem(withTitle: NSLocalizedString(
            "Pending files, sorted by path",
            comment: "Staging header sort choice"
        ))
        sortPopUpButton.lastItem?.tag = StagingFileSortOrder.path.rawValue
        sortPopUpButton.addItem(withTitle: NSLocalizedString(
            "Pending files, sorted by status",
            comment: "Staging header sort choice"
        ))
        sortPopUpButton.lastItem?.tag = StagingFileSortOrder.status.rawValue
        sortPopUpButton.selectItem(withTag: ApplicationSettings.stagingFileSortOrder.rawValue)
        sortPopUpButton.target = self
        sortPopUpButton.action = #selector(sortOrderChanged(_:))
        sortPopUpButton.bezelStyle = .texturedRounded
        sortPopUpButton.setAccessibilityIdentifier("StagingSortOrder")

        searchField.placeholderString = NSLocalizedString("Search", comment: "Staging file search placeholder")
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.setAccessibilityIdentifier("StagingSearch")

        buildOptionsMenu()
        optionsButton.image = NSImage(
            systemSymbolName: "ellipsis.circle",
            accessibilityDescription: NSLocalizedString("View options", comment: "Staging view options button")
        )
        optionsButton.imagePosition = .imageOnly
        optionsButton.isBordered = false
        optionsButton.target = self
        optionsButton.action = #selector(showOptionsMenu(_:))
        optionsButton.setAccessibilityIdentifier("StagingViewOptions")

        let bar = NSStackView(views: [sortPopUpButton, NSView(), searchField, optionsButton])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        bar.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return bar
    }

    private func buildOptionsMenu() {
        optionsMenu.autoenablesItems = true
        let externalDiff = NSMenuItem(
            title: NSLocalizedString("External Diff", comment: "Staging view options item"),
            action: #selector(openExternalDiff(_:)),
            keyEquivalent: ""
        )
        externalDiff.target = self
        optionsMenu.addItem(externalDiff)
        optionsMenu.addItem(.separator())

        let contextParent = NSMenuItem(
            title: NSLocalizedString("Lines of context", comment: "Staging view options submenu title"),
            action: nil,
            keyEquivalent: ""
        )
        let contextMenu = NSMenu()
        for lines in [1, 3, 6, 12, 25, 50, 100] {
            let item = NSMenuItem(title: "\(lines)", action: #selector(changeContextLines(_:)), keyEquivalent: "")
            item.target = self
            item.tag = lines
            contextMenu.addItem(item)
        }
        contextParent.submenu = contextMenu
        optionsMenu.addItem(contextParent)
        optionsMenu.addItem(.separator())

        let combinedLayout = NSMenuItem(
            title: NSLocalizedString("Combined list", comment: "Staging view options item"),
            action: #selector(changeListLayout(_:)),
            keyEquivalent: ""
        )
        combinedLayout.target = self
        combinedLayout.tag = StagingListLayout.sectionedList.rawValue
        optionsMenu.addItem(combinedLayout)
        let splitLayout = NSMenuItem(
            title: NSLocalizedString("Split sections", comment: "Staging view options item"),
            action: #selector(changeListLayout(_:)),
            keyEquivalent: ""
        )
        splitLayout.target = self
        splitLayout.tag = StagingListLayout.splitTables.rawValue
        optionsMenu.addItem(splitLayout)
    }

    @objc private func changeListLayout(_ sender: NSMenuItem) {
        guard let newLayout = StagingListLayout(rawValue: sender.tag) else { return }
        fileListController.setListLayout(newLayout)
    }

    @objc private func showOptionsMenu(_ sender: NSButton) {
        optionsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func sortOrderChanged(_ sender: NSPopUpButton) {
        let order = StagingFileSortOrder(rawValue: sender.selectedTag()) ?? .path
        ApplicationSettings.stagingFileSortOrder = order
        fileListController.viewModel.sortOrder = order
        fileListController.applyFilterAndSort()
        NSLog("[GitX] Staging file sort changed to %ld", order.rawValue)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        fileListController.viewModel.searchText = sender.stringValue
        fileListController.applyFilterAndSort()
    }

    @objc private func changeContextLines(_ sender: NSMenuItem) {
        diffPaneController.contextLines = UInt(max(0, sender.tag))
        NSLog("[GitX] Staging diff context set to %ld line(s)", sender.tag)
    }

    @objc private func openExternalDiff(_ sender: Any?) {
        guard let request = fileListController.currentDiffRequests.first else { return }
        var error: NSError?
        guard let arguments = index.diffToolArguments(for: request.file, staged: request.staged, error: &error) else {
            if let error {
                windowController?.showErrorSheet(error)
            }
            return
        }
        NSLog("[GitX] Launching external diff for one supported filename")
        let task = repository.task(withArguments: arguments)
        task.perform(on: DispatchQueue.global(qos: .userInitiated)) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.windowController?.showErrorSheet(error as NSError)
            }
        }
    }

    // MARK: Composer construction

    private func configureCommitMessageView() {
        // The message view is built in code, so AppKit never sends it
        // awakeFromNib; invoke it directly to apply the text-substitution preferences.
        commitMessageView.awakeFromNib()
        commitMessageView.repository = repository
        commitMessageView.delegate = self
        commitMessageView.setAccessibilityIdentifier("CommitMessage")
        commitMessageView.isRichText = false
        commitMessageView.allowsUndo = true
        commitMessageView.isContinuousSpellCheckingEnabled = true
        var attributes = commitMessageView.typingAttributes
        attributes[.font] = NSFont.preferredFont(forTextStyle: .body)
        commitMessageView.typingAttributes = attributes
    }

    private func makeComposerView() -> NSView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        commitMessageView.minSize = NSSize(width: 0, height: 0)
        commitMessageView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        commitMessageView.isVerticallyResizable = true
        commitMessageView.isHorizontallyResizable = false
        commitMessageView.autoresizingMask = [.width]
        commitMessageView.textContainer?.widthTracksTextView = true
        scrollView.documentView = commitMessageView

        let controls = NSStackView(views: [
            amendButton,
            pushAfterCommitButton,
            pushRemotePopUpButton,
            createPullRequestAfterPushButton,
            NSView(),
            commitButton,
        ])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.setHuggingPriority(.defaultLow, for: .horizontal)

        let composer = NSView()
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(scrollView)
        composer.addSubview(controls)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: composer.topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -4),
            controls.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            controls.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -8),
            controls.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -8),
            composer.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
        return composer
    }

    // MARK: Push remotes

    private var selectedPushRemoteName: String? {
        pushRemotePopUpButton.selectedItem?.representedObject as? String
    }

    @objc func reloadPushRemotes() {
        let wasAvailable = pushCapabilityAvailable
        let livePushChoice = pushAfterCommitButton.state == .on
        let failedSubmissionPushChoice = commitWorkflowState.pendingRememberedPushChoice
        let previousSelection = selectedPushRemoteName
        let remotes = CommitRemotePresentationPolicy.sortedRemoteNames(repository.remotes() ?? [])
        let headRef = repository.headRef()?.ref()
        var trackingRemoteName: String?
        if let headRef,
           CommitRemotePresentationPolicy.shouldResolveTrackingRemote(
               remoteNames: remotes,
               previousSelection: previousSelection,
               isBranch: headRef.isBranch
           )
        {
            trackingRemoteName = (try? repository.remoteRef(forBranch: headRef))?.remoteName
        }
        let presentation = CommitRemotePresentationPolicy.presentation(
            remoteNames: remotes,
            previousSelection: previousSelection,
            trackingRemoteName: trackingRemoteName,
            isBranch: headRef?.isBranch ?? false
        )

        pushRemotePopUpButton.removeAllItems()
        if presentation.remoteNames.isEmpty {
            pushRemotePopUpButton.addItem(withTitle: NSLocalizedString(
                "No Remotes",
                comment: "Placeholder in the staging push remote popup when no remotes are configured"
            ))
            pushRemotePopUpButton.lastItem?.isEnabled = false
        } else {
            for remoteName in presentation.remoteNames {
                pushRemotePopUpButton.addItem(withTitle: remoteName)
                pushRemotePopUpButton.lastItem?.representedObject = remoteName
            }
            if let selected = presentation.selectedRemoteName {
                pushRemotePopUpButton.selectItem(withTitle: selected)
            }
        }

        pushCapabilityAvailable = presentation.canPush
        refreshOperationControls()
        if presentation.canPush {
            var restoredChoice = wasAvailable ? livePushChoice : repositoryUISettings.pushAfterCommit
            if let failedSubmissionPushChoice {
                restoredChoice = failedSubmissionPushChoice.boolValue
            }
            pushAfterCommitButton.state = restoredChoice ? .on : .off
        } else {
            pushAfterCommitButton.state = failedSubmissionPushChoice?.boolValue == true ? .on : .off
            createPullRequestAfterPushButton.state = .off
        }
        NSLog(
            "[GitX] Reloaded staging push controls (remote count: %ld, can push: %@)",
            presentation.remoteNames.count,
            presentation.canPush ? "yes" : "no"
        )
    }

    // MARK: Commit workflow

    private var mutationControlsEnabled: Bool {
        CommitSubmissionEligibility.allowsMutation(index) && !commitWorkflowState.submissionActive
    }

    private var commitControlsEnabled: Bool {
        mutationControlsEnabled && fileListController.stagedFileCount > 0
    }

    private func refreshOperationControls() {
        guard isViewLoaded else { return }
        let enabled = mutationControlsEnabled
        commitButton.isEnabled = commitControlsEnabled
        amendButton.isEnabled = enabled
        pushAfterCommitButton.isEnabled = enabled && pushCapabilityAvailable
        pushRemotePopUpButton.isEnabled = enabled && pushCapabilityAvailable
        createPullRequestAfterPushButton.isEnabled = enabled && pushCapabilityAvailable
    }

    private func supportedPaths(for files: [PBChangedFile]) -> [String]? {
        let paths = files.compactMap(\.safePath)
        guard paths.count == files.count else {
            NSLog("[GitX] Refused a string-only action for unsupported filename bytes")
            windowController?.showMessageSheet(
                NSLocalizedString("Filename unavailable for this action", comment: "Unsupported raw filename action title"),
                infoText: Self.unsupportedFilenameExplanation
            )
            return nil
        }
        return paths
    }

    private static var unsupportedFilenameExplanation: String {
        NSLocalizedString(
            "This filename contains bytes that cannot be represented safely for this action. Whole-file Git staging operations remain available.",
            comment: "Unsupported raw filename action explanation"
        )
    }

    private func commit(verify: Bool) {
        guard mutationControlsEnabled else {
            host?.status = NSLocalizedString("A commit is already in progress or the index is refreshing.", comment: "Rejected late commit invocation")
            return
        }
        let mergeHeadPath = repository.gitURL().map { ($0.path as NSString).appendingPathComponent("MERGE_HEAD") }
        let mergeInProgress = mergeHeadPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let stagedCount = fileListController.stagedFileCount

        let commitMessage: String
        do {
            commitMessage = try CommitMessageEditCoordinator.transform(
                message: commitMessageView.string,
                in: commitMessageView,
                repository: repository
            )
        } catch {
            windowController?.showErrorSheet(error as NSError)
            return
        }

        let validationPlan = CommitSubmissionPolicy.plan(
            mergeInProgress: mergeInProgress,
            stagedCount: stagedCount,
            messageLength: commitMessage.count,
            pushEnabled: false,
            pushRequested: false,
            isBranch: false,
            remoteName: nil
        )
        switch validationPlan.disposition {
        case .mergeInProgress:
            windowController?.showMessageSheet(
                NSLocalizedString("Cannot commit merges", comment: "Title for sheet that Half Dark cannot create merge commits"),
                infoText: NSLocalizedString(
                    "Half Dark cannot commit merges yet. Please commit your changes from the command line.",
                    comment: "Information text for sheet that Half Dark cannot create merge commits"
                )
            )
            return
        case .noStagedChanges:
            windowController?.showMessageSheet(
                NSLocalizedString("No changes to commit", comment: "Title for sheet that you need to stage changes before creating a commit"),
                infoText: NSLocalizedString(
                    "You need to stage some changed files before committing by moving them to the list of Staged Changes.",
                    comment: "Information text for sheet that you need to stage changes before creating a commit"
                )
            )
            return
        case .messageTooShort:
            windowController?.showMessageSheet(
                NSLocalizedString("Missing commit message", comment: "Title for sheet that you need to enter a commit message before creating a commit"),
                infoText: String(
                    format: NSLocalizedString(
                        "Please enter a commit message at least %i characters long before commiting.",
                        comment: "Format for sheet that you need to enter a commit message before creating a commit giving the minimum length of the commit message required"
                    ),
                    Self.minimalCommitMessageLength
                )
            )
            return
        default:
            break
        }

        commitWorkflowState.clear()
        let headRef = repository.headRef()?.ref()
        let remoteName = selectedPushRemoteName
        let submissionPlan = CommitSubmissionPolicy.plan(
            mergeInProgress: false,
            stagedCount: stagedCount,
            messageLength: commitMessage.count,
            pushEnabled: pushAfterCommitButton.isEnabled,
            pushRequested: pushAfterCommitButton.state == .on,
            isBranch: headRef?.isBranch ?? false,
            remoteName: remoteName
        )
        if submissionPlan.shouldArmPendingPush, let headRef, let remoteName {
            commitWorkflowState.arm(branchRef: headRef, remoteName: remoteName)
        }
        pendingCreatePullRequestAfterPush = submissionPlan.shouldArmPendingPush &&
            createPullRequestAfterPushButton.state == .on
        commitWorkflowState.beginSubmission(
            pushChoice: pushAfterCommitButton.state == .on,
            canRemember: pushAfterCommitButton.isEnabled
        )

        refreshOperationControls()
        fileListController.clearSelections()
        host?.isBusy = true
        commitMessageView.isEditable = false

        if let windowController {
            let sheet = CommitProgressSheetController(repositoryWindowController: windowController)
            sheet.begin(withPhase: NSLocalizedString("Preparing commit…", comment: "Initial interactive commit progress phase"))
            commitProgressSheet = sheet
        }
        index.commit(withMessage: commitMessage, andVerify: verify)
    }

    private func finishCommitProgressSheet() {
        commitProgressSheet?.finish()
        commitProgressSheet = nil
    }

    private var discardSelectionIdentity: [String] {
        fileListController.currentDiffRequests.map { ($0.staged ? "s:" : "u:") + $0.file.rawPath.base64EncodedString() }
    }

    private func discardChanges(for files: [PBChangedFile], force: Bool) {
        guard mutationControlsEnabled, !files.isEmpty else { return }
        if force {
            index.discardChanges(for: files, completion: { _, _ in }); return
        }
        let selection = discardSelectionIdentity
        let expectedAmend = index.isAmend
        let eligibility: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return selection == discardSelectionIdentity && !index.submissionActive && index.isAmend == expectedAmend
        }
        diffPaneController.prepareDiscard(files: files, eligibility: eligibility) { [weak self] authorization, error in
            guard let self else { return }
            guard let authorization, error == nil, mutationControlsEnabled, eligibility() else {
                presentStaleDiscard(error)
                return
            }
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Discard changes", comment: "Title for Discard Changes sheet")
            alert.informativeText = NSLocalizedString(
                "Are you sure you wish to discard the changes to this file?\n\nYou cannot undo this operation.",
                comment: "Informative text for Discard Changes sheet"
            )
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button in Discard Changes sheet"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button in Discard Changes sheet"))
            _ = windowController?.confirmDialog(alert, suppressionIdentifier: nil) { [weak self] in
                guard let self else { return }
                guard mutationControlsEnabled, eligibility() else { presentStaleDiscard(nil); return }
                if !index.discardChanges(for: files, authorization: authorization, completion: { _, _ in }) {
                    presentStaleDiscard(nil)
                }
            }
        }
    }

    private func presentStaleDiscard(_ error: NSError?) {
        NotificationCenter.default.post(name: Notification.Name(PBGitIndexOperationFailed), object: index,
                                        userInfo: ["description": error?.localizedDescription ?? "The selected diff or repository state changed. Refresh and retry this action."])
        diffPaneController.rerenderCurrentRequests()
    }

    // MARK: Actions

    @objc func commit(_ sender: Any?) {
        commit(verify: true)
    }

    @objc func forceCommit(_ sender: Any?) {
        commit(verify: false)
    }

    @objc func toggleAmendCommit(_ sender: Any?) {
        guard mutationControlsEnabled else { return }
        index.isAmend = !index.isAmend
    }

    @objc func pushAfterCommitChanged(_: Any?) {
        guard mutationControlsEnabled else { return }
        commitWorkflowState.updateRememberedPushChoice(pushAfterCommitButton.state == .on)
    }

    @objc func createPullRequestAfterPushChanged(_: Any?) {
        guard mutationControlsEnabled else { return }
        if createPullRequestAfterPushButton.state == .on {
            pushAfterCommitButton.state = .on
            pushAfterCommitChanged(nil)
        }
    }

    @objc func signOff(_ sender: Any?) {
        let config = repository.gtRepo.flatMap { try? $0.configuration() }
        let userName = config?.string(forKey: "user.name")
        let userEmail = config?.string(forKey: "user.email")
        guard let userName, let userEmail else {
            windowController?.showMessageSheet(
                NSLocalizedString("User‘s name not set", comment: "Title for sheet that the user’s name is not set in the git configuration"),
                infoText: NSLocalizedString(
                    "Signing off a commit requires setting user.name and user.email in your git config",
                    comment: "Information text for sheet that the user’s name is not set in the git configuration"
                )
            )
            return
        }
        let result = CommitMessagePolicy.messageByAddingSignOff(
            to: commitMessageView.string,
            userName: userName,
            userEmail: userEmail
        )
        if result.didAddSignOff {
            let selectedRanges = commitMessageView.selectedRanges
            commitMessageView.string = result.message
            commitMessageView.selectedRanges = selectedRanges
        }
    }

    @objc func prepareCommitMessage(_ sender: Any?) {
        guard mutationControlsEnabled else { return }
        host?.isBusy = true
        if let prepared = index.createPrepareCommitMessage() {
            let replacementRange = NSRange(location: 0, length: (commitMessageView.string as NSString).length)
            if commitMessageView.shouldChangeText(in: replacementRange, replacementString: prepared) {
                commitMessageView.replaceCharacters(in: replacementRange, with: prepared)
            }
        }
        host?.isBusy = false
    }

    @objc func stageFiles(_ sender: Any?) {
        guard mutationControlsEnabled else { return }
        let selection = actionSelection(for: .stage, sender: sender)
        guard !selection.files.isEmpty else { return }
        NSLog("[GitX] Staging %ld file(s) from the resolved action selection", selection.files.count)
        index.stageFiles(selection.files, completion: { _, _ in })
    }

    @objc func unstageFiles(_ sender: Any?) {
        guard mutationControlsEnabled else { return }
        let selection = actionSelection(for: .unstage, sender: sender)
        guard !selection.files.isEmpty else { return }
        NSLog("[GitX] Unstaging %ld file(s) from the resolved action selection", selection.files.count)
        index.unstageFiles(selection.files, completion: { _, _ in })
    }

    @objc func discardFiles(_ sender: Any?) {
        discardChanges(for: actionSelection(for: .discard, sender: sender).files, force: false)
    }

    @objc func discardFilesForcibly(_ sender: Any?) {
        discardChanges(for: actionSelection(for: .forceDiscard, sender: sender).files, force: true)
    }

    @objc func openFiles(_ sender: Any?) {
        guard let workingDirectoryURL = repository.workingDirectoryURL() else { return }
        let files = actionSelection(for: .open, sender: sender).files
        guard let paths = supportedPaths(for: files) else { return }
        let urls = paths.map { workingDirectoryURL.appendingPathComponent($0) }
        windowController?.open(urls)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let workingDirectoryURL = repository.workingDirectoryURL() else { return }
        let files = actionSelection(for: .reveal, sender: sender).files
        guard let paths = supportedPaths(for: files) else { return }
        let urls = paths.map { workingDirectoryURL.appendingPathComponent($0) }
        windowController?.revealURLs(inFinder: urls)
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard mutationControlsEnabled else { return }
        guard let workingDirectoryURL = repository.workingDirectoryURL() else { return }
        let files = actionSelection(for: .trash, sender: sender).files
        guard !files.isEmpty, let paths = supportedPaths(for: files) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Move to trash", comment: "Move to trash alert - title")
        alert.informativeText = NSLocalizedString(
            "Do you want to move the following files to the trash ?",
            comment: "Move to trash alert - message"
        )
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Move to trash alert - OK button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Move to trash alert - Cancel button"))
        _ = windowController?.confirmDialog(alert, suppressionIdentifier: nil) { [weak self] in
            guard let self, mutationControlsEnabled else { return }
            var anyTrashed = false
            for path in paths {
                let fileURL = workingDirectoryURL.appendingPathComponent(path)
                if trashItemHandler(fileURL) {
                    anyTrashed = true
                }
            }
            if anyTrashed {
                index.refresh()
            }
        }
    }

    @objc func ignoreFiles(_ sender: Any?) {
        guard mutationControlsEnabled else { return }
        let files = actionSelection(for: .ignore, sender: sender).files
        guard !files.isEmpty else { return }
        guard let paths = supportedPaths(for: files) else { return }
        do {
            try repository.ignoreFilePaths(RepositoryIgnoreLiteralPatterns.patterns(for: paths))
        } catch {
            windowController?.showErrorSheet(error as NSError)
        }
        index.refresh()
    }

    private func actionSelection(for action: StagingFileAction, sender: Any?) -> StagingActionSelection {
        // The snapshot pins the exact files the presented menu titles described, so an
        // index refresh between menu-open and click is deliberately ignored. Consuming
        // it here keeps long-lived main-menu items from retaining the last selection
        // between uses; the next validation pass stores a fresh snapshot.
        if let menuItem = sender as? NSMenuItem,
           let snapshot = menuItem.representedObject as? StagingActionSelection,
           snapshot.action == action
        {
            menuItem.representedObject = nil
            NSLog("[GitX] Consumed a %ld-file staging menu selection snapshot", snapshot.files.count)
            return snapshot
        }
        return fileListController.resolvedSelection(
            for: action,
            contextualMenu: (sender as? NSMenuItem)?.menu
        )
    }

    // MARK: Notifications

    @objc private func refreshFinished(_ notification: Notification) {
        if !commitWorkflowState.submissionActive {
            host?.isBusy = false
        }
        refreshOperationControls()
        host?.status = NSLocalizedString(
            "Index refresh finished",
            comment: "Message in status bar when refreshing the index is done"
        )
    }

    @objc private func commitStatusUpdated(_ notification: Notification) {
        let description = notification.userInfo?["description"] as? String
        host?.status = description
        if let description {
            commitProgressSheet?.updatePhase(description)
        }
    }

    @objc private func commitOutputReceived(_ notification: Notification) {
        guard let output = notification.userInfo?["output"] as? String, !output.isEmpty else { return }
        commitProgressSheet?.appendOutput(output)
    }

    @objc private func commitFinished(_ notification: Notification) {
        finishCommitProgressSheet()
        host?.isBusy = false
        commitMessageView.isEditable = true
        commitMessageView.string = ""
        if let description = notification.userInfo?["description"] as? String {
            diffPaneController.showStateMessage(description)
        }

        let rememberedPushChoice = commitWorkflowState.pendingRememberedPushChoice
        let pushPlan = commitWorkflowState.consumePendingPush()
        refreshOperationControls()
        let createPullRequestAfterPush = pendingCreatePullRequestAfterPush
        pendingCreatePullRequestAfterPush = false
        createPullRequestAfterPushButton.state = .off
        if let rememberedPushChoice {
            repositoryUISettings.pushAfterCommit = rememberedPushChoice.boolValue
            pushAfterCommitButton.state = rememberedPushChoice.boolValue ? .on : .off
            NSLog("[GitX] Remembered repository Push-after-commit choice: %@", rememberedPushChoice.boolValue ? "on" : "off")
        }

        if let pushPlan, pushPlan.branchRef.isBranch, !pushPlan.remoteName.isEmpty {
            let remoteRef = PBGitRef(from: kGitXRemoteRefPrefix + pushPlan.remoteName)
            windowController?.performPush(
                forBranch: pushPlan.branchRef,
                toRemote: remoteRef,
                requiresConfirmation: false,
                initiallyCreatePullRequest: createPullRequestAfterPush
            )
        }
    }

    @objc private func commitFailed(_ notification: Notification) {
        pendingCreatePullRequestAfterPush = false
        finishCommitProgressSheet()
        host?.isBusy = false
        commitMessageView.isEditable = true
        if let rememberedPushChoice = commitWorkflowState.cancelSubmission() {
            pushAfterCommitButton.state = rememberedPushChoice.boolValue ? .on : .off
        }
        refreshOperationControls()

        let reason = notification.userInfo?["description"] as? String ?? ""
        host?.status = String(
            format: NSLocalizedString(
                "Commit failed: %@",
                comment: "Message in status bar when creating a commit has failed, including the reason for the failure"
            ),
            reason
        )
        windowController?.showMessageSheet(
            NSLocalizedString("Commit failed", comment: "Title for sheet that creating a commit has failed"),
            infoText: reason
        )
    }

    @objc private func commitHookFailed(_ notification: Notification) {
        finishCommitProgressSheet()
        let retained = index.awaitingHookDecision
        if retained {
            commitWorkflowState.awaitHookDecision()
            commitMessageView.isEditable = false
        } else {
            endCancelledHookSubmission()
        }
        refreshOperationControls()
        let reason = notification.userInfo?["description"] as? String ?? ""
        host?.status = String(format: NSLocalizedString("Commit hook failed: %@", comment: "Commit hook failure status"), reason)
        windowController?.showCommitHookFailedSheet(
            NSLocalizedString("Commit hook failed", comment: "Commit hook failure sheet title"),
            infoText: reason,
            retryHandler: { [weak self] in
                guard let self else { return }
                if self.index.awaitingHookDecision {
                    self.commitWorkflowState.retrySubmission()
                    self.host?.isBusy = true
                    if let windowController = self.windowController {
                        let sheet = CommitProgressSheetController(repositoryWindowController: windowController)
                        sheet.begin(withPhase: NSLocalizedString("Preparing commit…", comment: "Retry commit progress phase"))
                        self.commitProgressSheet = sheet
                    }
                    self.index.retryCommitWithoutVerification()
                } else {
                    self.forceCommit(self)
                }
            },
            cancelHandler: { [weak self] in
                guard let self else { return }
                self.index.cancelCommitSubmission()
                self.endCancelledHookSubmission()
            }
        )
    }

    private func endCancelledHookSubmission() {
        pendingCreatePullRequestAfterPush = false
        host?.isBusy = false
        commitMessageView.isEditable = true
        if let rememberedPushChoice = commitWorkflowState.cancelSubmission() {
            pushAfterCommitButton.state = rememberedPushChoice.boolValue ? .on : .off
        }
        refreshOperationControls()
    }

    @objc private func amendMessageAvailable(_ notification: Notification) {
        guard CommitMessagePolicy.shouldReplaceMessageForAmend(currentMessage: commitMessageView.string),
              let message = notification.userInfo?["message"] as? String
        else { return }
        commitMessageView.string = message
    }

    @objc private func indexChanged(_ notification: Notification) {
        fileListController.rearrange()
        diffPaneController.updateSelection(fileListController.currentDiffRequests)
        selectionCoalescer?.requestRefresh()
        refreshOperationControls()
    }

    @objc private func indexOperationFailed(_ notification: Notification) {
        windowController?.showMessageSheet(
            NSLocalizedString("Index operation failed", comment: "Title for sheet that running an index operation has failed"),
            infoText: notification.userInfo?["description"] as? String ?? ""
        )
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if fileListController.layout == .sectionedList {
            if commandSelector == #selector(NSResponder.insertTab(_:)) ||
                commandSelector == #selector(NSResponder.insertBacktab(_:))
            {
                fileListController.focusFileList()
                return true
            }
            return false
        }
        return fileListController.interactionCoordinator.handle(commandSelector: commandSelector)
    }

    // MARK: Menu validation

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            _ = validateMenuItem(item)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return false }
        if action == #selector(changeContextLines(_:)) {
            menuItem.state = diffPaneController.contextLines == UInt(menuItem.tag) ? .on : .off
            return true
        }
        if action == #selector(openExternalDiff(_:)) {
            guard let request = fileListController.currentDiffRequests.first else { return false }
            var error: NSError?
            let available = index.diffToolArguments(for: request.file, staged: request.staged, error: &error) != nil
            menuItem.toolTip = available ? nil : error?.localizedDescription
            return available
        }
        if CommitMenuPresenter.isMutation(action: action), !mutationControlsEnabled {
            return false
        }
        if action == #selector(commit(_:)) || action == #selector(forceCommit(_:)) {
            return commitControlsEnabled
        }
        if action == #selector(changeListLayout(_:)) {
            menuItem.state = fileListController.layout.rawValue == menuItem.tag ? .on : .off
            return true
        }
        let stagingAction = stagingFileAction(for: action)
        let selection = stagingAction.map {
            fileListController.resolvedSelection(for: $0, contextualMenu: menuItem.menu)
        }
        if let selection {
            menuItem.representedObject = selection
        }
        let resolvedFiles = selection?.files ?? []
        let isInContextualMenu = menuItem.parent == nil
        if CommitMenuPresenter.requiresStringPath(action: action), resolvedFiles.contains(where: { $0.safePath == nil }) {
            menuItem.toolTip = Self.unsupportedFilenameExplanation
            return false
        }
        menuItem.toolTip = nil
        let singleSelectionIsSubmodule = isInContextualMenu &&
            action == #selector(openFiles(_:)) &&
            resolvedFiles.count == 1 &&
            resolvedFiles[0].safePath.flatMap { try? repository.submodule(atPath: $0) } != nil
        let isAmend = action == #selector(toggleAmendCommit(_:)) && index.isAmend
        let prepareHookExists = action == #selector(prepareCommitMessage(_:)) &&
            repository.hookExists("prepare-commit-msg")

        func menuFiles(_ files: [PBChangedFile]) -> [CommitMenuFile] {
            files.map {
                CommitMenuFile(path: $0.path, status: $0.worktreeStatus.rawValue, hasUnstagedChanges: $0.hasUnstagedChanges)
            }
        }

        let presentation = CommitMenuPresenter.presentation(
            action: action,
            resolvedFiles: menuFiles(resolvedFiles),
            allowsTrash: fileListController.layout == .sectionedList ||
                menuItem.menu !== fileListController.stagedTable.menu,
            isContextualMenu: isInContextualMenu,
            singleSelectionIsSubmodule: singleSelectionIsSubmodule,
            isAmend: isAmend,
            prepareHookExists: prepareHookExists,
            fallbackEnabled: menuItem.isEnabled
        )
        if let title = presentation.title {
            menuItem.title = title
        }
        if presentation.updatesHidden {
            menuItem.isHidden = presentation.hidden
        }
        if presentation.updatesAlternate {
            menuItem.isAlternate = presentation.alternate
        }
        if presentation.updatesState {
            menuItem.state = NSControl.StateValue(rawValue: presentation.state)
        }
        return presentation.enabled
    }

    private func stagingFileAction(for selector: Selector) -> StagingFileAction? {
        switch selector {
        case #selector(stageFiles(_:)): .stage
        case #selector(unstageFiles(_:)): .unstage
        case #selector(discardFiles(_:)): .discard
        case #selector(discardFilesForcibly(_:)): .forceDiscard
        case #selector(openFiles(_:)): .open
        case #selector(revealInFinder(_:)): .reveal
        case #selector(ignoreFiles(_:)): .ignore
        case #selector(moveToTrash(_:)): .trash
        default: nil
        }
    }
}

// swiftlint:enable unused_declaration
