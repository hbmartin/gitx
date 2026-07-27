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

    @objc let commitMessageView: PBCommitMessageView
    private let commitButton = NSButton(title: NSLocalizedString("Commit", comment: "Commit button in the staging pane"), target: nil, action: nil)
    private let amendButton = NSButton(checkboxWithTitle: NSLocalizedString("Amend", comment: "Amend checkbox in the staging pane"), target: nil, action: nil)
    private let pushAfterCommitButton = NSButton(checkboxWithTitle: NSLocalizedString("Push to", comment: "Push-after-commit checkbox in the staging pane"), target: nil, action: nil)
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
        selectionCoalescer?.cancel()
        selectionCoalescer = nil
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

        amendButton.bind(NSBindingName.value, to: index, withKeyPath: "amend", options: nil)
        pushAfterCommitButton.setAccessibilityIdentifier("PushAfterCommit")
        pushRemotePopUpButton.setAccessibilityIdentifier("PushRemote")
        pushAfterCommitButton.state = repositoryUISettings.pushAfterCommit ? .on : .off

        let coalescer = RefreshCoalescer { [weak self] in
            self?.renderSelectedDiffs()
        }
        selectionCoalescer = coalescer
        fileListController.onSelectionChange = { [weak self] in
            self?.selectionCoalescer?.requestRefresh()
        }
    }

    /// Refreshes everything that can go stale while the pane is hidden.
    @objc func updateView() {
        reloadPushRemotes()
        fileListController.rearrange()
        commitButton.isEnabled = fileListController.stagedFileCount > 0
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

        let showWhitespace = NSMenuItem(
            title: NSLocalizedString("Show whitespace", comment: "Staging view options item"),
            action: #selector(changeWhitespaceVisibility(_:)),
            keyEquivalent: ""
        )
        showWhitespace.target = self
        showWhitespace.tag = 0
        optionsMenu.addItem(showWhitespace)
        let ignoreWhitespace = NSMenuItem(
            title: NSLocalizedString("Ignore whitespace", comment: "Staging view options item"),
            action: #selector(changeWhitespaceVisibility(_:)),
            keyEquivalent: ""
        )
        ignoreWhitespace.target = self
        ignoreWhitespace.tag = 1
        optionsMenu.addItem(ignoreWhitespace)
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

    @objc private func changeWhitespaceVisibility(_ sender: NSMenuItem) {
        diffPaneController.ignoreWhitespace = sender.tag == 1
        NSLog("[GitX] Staging diffs now %@ whitespace", sender.tag == 1 ? "ignore" : "show")
    }

    @objc private func changeContextLines(_ sender: NSMenuItem) {
        diffPaneController.contextLines = UInt(max(0, sender.tag))
        NSLog("[GitX] Staging diff context set to %ld line(s)", sender.tag)
    }

    @objc private func openExternalDiff(_ sender: Any?) {
        let requests = fileListController.currentDiffRequests
        guard let request = requests.first else { return }
        var arguments = ["difftool", "-y", "--no-prompt"]
        if request.staged {
            arguments.append("--cached")
        }
        arguments.append(contentsOf: ["--", request.file.path])
        NSLog("[GitX] Launching external diff for %@", request.file.path)
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
        // awakeFromNib; invoke it directly to apply the text-substitution
        // preferences and register the guide-ruler observers.
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

        let controls = NSStackView(views: [amendButton, pushAfterCommitButton, pushRemotePopUpButton, NSView(), commitButton])
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

        pushAfterCommitButton.isEnabled = presentation.canPush
        pushRemotePopUpButton.isEnabled = presentation.canPush
        if presentation.canPush {
            var restoredChoice = wasAvailable ? livePushChoice : repositoryUISettings.pushAfterCommit
            if let failedSubmissionPushChoice {
                restoredChoice = failedSubmissionPushChoice.boolValue
                _ = commitWorkflowState.consumeRememberedPushChoice()
            }
            pushAfterCommitButton.state = restoredChoice ? .on : .off
        } else {
            pushAfterCommitButton.state = .off
        }
        pushCapabilityAvailable = presentation.canPush
        NSLog(
            "[GitX] Reloaded staging push controls (remote count: %ld, can push: %@)",
            presentation.remoteNames.count,
            presentation.canPush ? "yes" : "no"
        )
    }

    // MARK: Commit workflow

    private func commit(verify: Bool) {
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
                NSLocalizedString("Cannot commit merges", comment: "Title for sheet that GitX cannot create merge commits"),
                infoText: NSLocalizedString(
                    "GitX cannot commit merges yet. Please commit your changes from the command line.",
                    comment: "Information text for sheet that GitX cannot create merge commits"
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
        commitWorkflowState.beginSubmission(
            pushChoice: pushAfterCommitButton.state == .on,
            canRemember: pushAfterCommitButton.isEnabled
        )

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

    private func discardChanges(for files: [PBChangedFile], force: Bool) {
        guard !files.isEmpty else { return }
        let performDiscard: () -> Void = { [weak self] in
            self?.index.discardChanges(for: files)
        }
        guard !force else {
            performDiscard()
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
        _ = windowController?.confirmDialog(alert, suppressionIdentifier: nil, forAction: performDiscard)
    }

    // MARK: Actions

    @objc func commit(_ sender: Any?) {
        commit(verify: true)
    }

    @objc func forceCommit(_ sender: Any?) {
        commit(verify: false)
    }

    @objc func toggleAmendCommit(_ sender: Any?) {
        index.isAmend = !index.isAmend
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
        fileListController.interactionCoordinator.stageSelectedFiles()
    }

    @objc func unstageFiles(_ sender: Any?) {
        fileListController.interactionCoordinator.unstageSelectedFiles()
    }

    @objc func discardFiles(_ sender: Any?) {
        discardChanges(for: fileListController.selectedFiles(stagedContext: false), force: false)
    }

    @objc func discardFilesForcibly(_ sender: Any?) {
        discardChanges(for: fileListController.selectedFiles(stagedContext: false), force: true)
    }

    @objc func openFiles(_ sender: Any?) {
        guard let workingDirectoryURL = repository.workingDirectoryURL() else { return }
        let urls = selectedFiles(for: sender).map { workingDirectoryURL.appendingPathComponent($0.path) }
        windowController?.open(urls)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let workingDirectoryURL = repository.workingDirectoryURL() else { return }
        let urls = selectedFiles(for: sender).map { workingDirectoryURL.appendingPathComponent($0.path) }
        windowController?.revealURLs(inFinder: urls)
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard let workingDirectoryURL = repository.workingDirectoryURL() else { return }
        let files = selectedFiles(for: sender)
        guard !files.isEmpty else { return }

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
            var anyTrashed = false
            for file in files {
                let fileURL = workingDirectoryURL.appendingPathComponent(file.path)
                if (try? FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)) != nil {
                    anyTrashed = true
                }
            }
            if anyTrashed {
                self?.index.refresh()
            }
        }
    }

    @objc func ignoreFiles(_ sender: Any?) {
        let files = selectedFiles(for: sender)
        guard !files.isEmpty else { return }
        let paths = files.map(\.path).filter { !$0.isEmpty }
        do {
            try repository.ignoreFilePaths(paths)
        } catch {
            windowController?.showErrorSheet(error as NSError)
        }
        index.refresh()
    }

    private func selectedFiles(for sender: Any?) -> [PBChangedFile] {
        guard let menuItem = sender as? NSMenuItem else { return [] }
        let stagedContext = menuItem.menu === fileListController.stagedTable.menu
        return fileListController.selectedFiles(stagedContext: stagedContext)
    }

    // MARK: Notifications

    @objc private func refreshFinished(_ notification: Notification) {
        host?.isBusy = false
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
        commitMessageView.isEditable = true
        commitMessageView.string = ""
        if let description = notification.userInfo?["description"] as? String {
            diffPaneController.showStateMessage(description)
        }

        let rememberedPushChoice = commitWorkflowState.pendingRememberedPushChoice
        let pushPlan = commitWorkflowState.consumePendingPush()
        if let rememberedPushChoice {
            repositoryUISettings.pushAfterCommit = rememberedPushChoice.boolValue
            pushAfterCommitButton.state = rememberedPushChoice.boolValue ? .on : .off
            NSLog("[GitX] Remembered repository Push-after-commit choice: %@", rememberedPushChoice.boolValue ? "on" : "off")
        }

        if let pushPlan, pushPlan.branchRef.isBranch, !pushPlan.remoteName.isEmpty {
            let remoteRef = PBGitRef(from: kGitXRemoteRefPrefix + pushPlan.remoteName)
            windowController?.performPush(forBranch: pushPlan.branchRef, toRemote: remoteRef, requiresConfirmation: false)
        }
    }

    @objc private func commitFailed(_ notification: Notification) {
        finishCommitProgressSheet()
        host?.isBusy = false
        commitMessageView.isEditable = true
        if let rememberedPushChoice = commitWorkflowState.cancelSubmission() {
            pushAfterCommitButton.state = rememberedPushChoice.boolValue ? .on : .off
        }

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
        host?.isBusy = false
        commitMessageView.isEditable = true
        if let rememberedPushChoice = commitWorkflowState.cancelSubmission() {
            pushAfterCommitButton.state = rememberedPushChoice.boolValue ? .on : .off
        }

        let reason = notification.userInfo?["description"] as? String ?? ""
        host?.status = String(
            format: NSLocalizedString(
                "Commit hook failed: %@",
                comment: "Message in status bar when running a commit hook failed, including the reason for the failure"
            ),
            reason
        )
        windowController?.showCommitHookFailedSheet(
            NSLocalizedString("Commit hook failed", comment: "Title for sheet that running a commit hook has failed"),
            infoText: reason
        ) { [weak self] in
            self?.forceCommit(self)
        }
    }

    @objc private func amendMessageAvailable(_ notification: Notification) {
        guard CommitMessagePolicy.shouldReplaceMessageForAmend(currentMessage: commitMessageView.string),
              let message = notification.userInfo?["message"] as? String
        else { return }
        commitMessageView.string = message
    }

    @objc private func indexChanged(_ notification: Notification) {
        fileListController.rearrange()
        commitButton.isEnabled = fileListController.stagedFileCount > 0
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
        if action == #selector(changeWhitespaceVisibility(_:)) {
            menuItem.state = diffPaneController.ignoreWhitespace == (menuItem.tag == 1) ? .on : .off
            return true
        }
        if action == #selector(changeContextLines(_:)) {
            menuItem.state = diffPaneController.contextLines == UInt(menuItem.tag) ? .on : .off
            return true
        }
        if action == #selector(openExternalDiff(_:)) {
            return !fileListController.currentDiffRequests.isEmpty
        }
        if action == #selector(changeListLayout(_:)) {
            menuItem.state = fileListController.layout.rawValue == menuItem.tag ? .on : .off
            return true
        }
        let isSectionedMenu = menuItem.menu === fileListController.sectionedTable.menu
        if isSectionedMenu {
            if action == #selector(stageFiles(_:)) {
                return !fileListController.selectedFiles(stagedContext: false).isEmpty
            }
            if action == #selector(unstageFiles(_:)) {
                return !fileListController.selectedFiles(stagedContext: true).isEmpty
            }
        }
        let stagedContext = isSectionedMenu
            ? fileListController.selectedFiles(stagedContext: false).isEmpty &&
            !fileListController.selectedFiles(stagedContext: true).isEmpty
            : menuItem.menu === fileListController.stagedTable.menu
        let filesForStaging = fileListController.selectedFiles(stagedContext: false)
        let filesForUnstaging = fileListController.selectedFiles(stagedContext: true)
        let selectedFiles = stagedContext ? filesForUnstaging : filesForStaging
        let isInContextualMenu = menuItem.parent == nil
        let singleSelectionIsSubmodule = isInContextualMenu &&
            action == #selector(openFiles(_:)) &&
            selectedFiles.count == 1 &&
            (try? repository.submodule(atPath: selectedFiles[0].path)) != nil
        let isAmend = action == #selector(toggleAmendCommit(_:)) && index.isAmend
        let prepareHookExists = action == #selector(prepareCommitMessage(_:)) &&
            repository.hookExists("prepare-commit-msg")

        func menuFiles(_ files: [PBChangedFile]) -> [CommitMenuFile] {
            files.map {
                CommitMenuFile(path: $0.path, status: $0.status.rawValue, hasUnstagedChanges: $0.hasUnstagedChanges)
            }
        }

        let presentation = CommitMenuPresenter.presentation(
            action: action,
            unstagedFiles: menuFiles(filesForStaging),
            stagedFiles: menuFiles(filesForUnstaging),
            isStagedContext: stagedContext,
            allowsTrash: !stagedContext,
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
}

// swiftlint:enable unused_declaration
