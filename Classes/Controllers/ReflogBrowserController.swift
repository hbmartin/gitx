import AppKit
import GitXCore
import OSLog // swiftlint:disable:this unused_import -- Logger requires OSLog; removing it fails Debug compilation.

private nonisolated struct ReflogBrowserLoad: Sendable {
    let branches: [RepositoryReflogReference]
    let reference: String
    let page: RepositoryReflogPage
}

/// Repository reconciliation belongs to the operation, even after its browser closes.
@MainActor
private enum ReflogBrowserMutation {
    case branch, reset

    func reconcile(_ repository: PBGitRepository) {
        repository.reloadRefs()
        if self == .reset {
            repository.hasChanged = true
            repository.lazyReload()
        }
    }
}

/// Owns presentation and request lifetimes; Git and recovery decisions live in
/// RepositoryReflogService and GitXCore.
@MainActor
final class ReflogBrowserController: PBViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "ReflogBrowser")
    private let referencePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let split = NSSplitView()
    private let detailText = NSTextView()
    private let message = NSTextField(labelWithString: "Loading reflog…")
    private let moreButton = NSButton(title: "Load More", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var selectionButtons: [NSButton] = []
    private var entries: [ReflogEntry] = []
    private var references: [RepositoryReflogReference] = []
    private var requests = ReflogBrowserRequestPolicy()
    private var resetRetryNotice: String?
    private var refreshTask: Task<Void, Never>?
    private var slowMutationTask: Task<Void, Never>?
    private var delay: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    private var pasteboard = NSPasteboard.general
    private let resultSummary = NSTextField(wrappingLabelWithString: "")
    private var emptyResultHeight: NSLayoutConstraint?
    private var fingerprint: WorktreeFileFingerprint?
    private var hasMore = false
    private var closed = false
    private var generation: UInt64 = 0
    private var service: RepositoryReflogService?
    private(set) var operation: Task<Void, Never>?
    private var mutating = false
    private var restoringSelection = false
    private var serviceFactory: (PBGitRepository) throws -> RepositoryReflogService = { try RepositoryReflogService(repository: $0) }

    static func make(repository: PBGitRepository, windowController: PBGitWindowController? = nil,
                     serviceFactory: @escaping (PBGitRepository) throws -> RepositoryReflogService = { try RepositoryReflogService(repository: $0) },
                     pasteboard: NSPasteboard = .general,
                     delay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) -> ReflogBrowserController?
    {
        let controller = ReflogBrowserController(repository: repository, superController: windowController)
        controller?.serviceFactory = serviceFactory
        controller?.pasteboard = pasteboard
        controller?.delay = delay
        return controller
    }

    @objc(initWithRepository:superController:)
    override init?(repository: PBGitRepository, superController controller: PBGitWindowController?) {
        super.init(repository: repository, superController: controller)
    }

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ReflogBrowserController requires a repository")
    }

    isolated deinit {
        refreshTask?.cancel()
        slowMutationTask?.cancel()
        if !mutating {
            service?.cancel()
            operation?.cancel()
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        root.setAccessibilityIdentifier("GitX.Reflog")
        referencePopup.target = self
        referencePopup.action = #selector(referenceChanged)
        referencePopup.setAccessibilityIdentifier("GitX.Reflog.Reference")
        referencePopup.setAccessibilityLabel("Reflog reference")
        referencePopup.addItem(withTitle: "Current checkout’s HEAD")
        referencePopup.menu?.autoenablesItems = false
        configure(refreshButton, action: #selector(refresh(_:)), identifier: "Refresh")
        configure(moreButton, action: #selector(loadMore), identifier: "LoadMore")
        configure(cancelButton, action: #selector(cancelActivity), identifier: "Cancel")
        let header = NSStackView(views: [NSTextField(labelWithString: "Reflog:"), referencePopup, refreshButton, moreButton, cancelButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.setHuggingPriority(.required, for: .vertical)

        table.delegate = self
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.setAccessibilityIdentifier("GitX.Reflog.Events")
        for (identifier, title, width) in [("time", "Event Time", 160.0), ("actor", "Actor", 130.0), ("action", "Action", 200.0), ("commit", "Commit", 100.0), ("subject", "Subject", 280.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        let events = NSScrollView()
        events.hasVerticalScroller = true
        events.hasHorizontalScroller = true
        events.documentView = table
        detailText.isEditable = false
        detailText.isSelectable = true
        detailText.isRichText = false
        detailText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailText.autoresizingMask = [.width]
        detailText.setAccessibilityIdentifier("GitX.Reflog.Details")
        let details = NSScrollView()
        details.hasVerticalScroller = true
        details.documentView = detailText
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(events)
        split.addArrangedSubview(details)
        events.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        details.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let actions: [(String, Selector, String)] = [
            ("Compare with HEAD", #selector(compareWithHead), "Compare"),
            ("Copy Commit Identifier", #selector(copyCommitID), "Copy"),
            ("Create Recovery Branch…", #selector(createBranch), "CreateBranch"),
            ("Reset Current Checkout to This Commit…", #selector(resetCheckout), "Reset"),
        ]
        selectionButtons = actions.map { title, selector, identifier in
            let button = NSButton(title: title, target: self, action: selector)
            configure(button, action: selector, identifier: identifier)
            return button
        }
        let inspectionActions = NSStackView(views: Array(selectionButtons.prefix(2)))
        let recoveryActions = NSStackView(views: Array(selectionButtons.suffix(2)))
        let footer = NSStackView(views: [inspectionActions, recoveryActions])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 8
        for row in [inspectionActions, recoveryActions, footer] {
            row.setHuggingPriority(.required, for: .vertical)
        }
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        message.setAccessibilityIdentifier("GitX.Reflog.Status")
        resultSummary.isSelectable = true
        resultSummary.maximumNumberOfLines = 2
        resultSummary.setAccessibilityIdentifier("GitX.Reflog.LastResult")
        resultSummary.textColor = .secondaryLabelColor
        emptyResultHeight = resultSummary.heightAnchor.constraint(equalToConstant: 0)
        emptyResultHeight?.isActive = true
        for child in [header, split, footer, resultSummary, message] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            footer.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            resultSummary.topAnchor.constraint(equalTo: footer.bottomAnchor, constant: 6),
            resultSummary.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            resultSummary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            message.topAnchor.constraint(equalTo: resultSummary.bottomAnchor, constant: 6),
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            message.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            message.heightAnchor.constraint(equalToConstant: 18),
            message.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        view = root
        updateControls()
    }

    private func configure(_ button: NSButton, action: Selector, identifier: String) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("GitX.Reflog." + identifier)
    }

    override func updateView() {
        guard !closed else { return }
        view.layoutSubtreeIfNeeded()
        split.setPosition(split.bounds.height * 0.45, ofDividerAt: 0)
        refresh(nil)
    }

    override func firstResponder() -> NSResponder? {
        table
    }

    func repositoryDidChange() {
        guard !closed else { return }
        requests.repositoryDidChange()
        fingerprint = nil
        hasMore = false
        if !isBusy {
            showStatus("The repository changed. Refreshing the reflog…")
            scheduleRefresh()
        }
        updateControls()
        let revision = requests.revision
        Self.logger.debug("Coalesced reflog invalidation revision=\(revision)")
    }

    private func scheduleRefresh() {
        guard !closed, requests.shouldRefresh else { return }
        refreshTask?.cancel()
        let delay = delay
        refreshTask = Task { [weak self] in
            do { try await delay(.milliseconds(150)) } catch { return }
            guard !Task.isCancelled, let self, !self.closed, self.requests.shouldRefresh else { return }
            self.refreshTask = nil
            self.loadPage(append: false)
        }
    }

    private func publishResult(_ text: String) {
        resultSummary.stringValue = text
        resultSummary.toolTip = text
        resultSummary.setAccessibilityHelp(text)
        emptyResultHeight?.isActive = false
        detailText.string = text
    }

    override func closeView() {
        resetRetryNotice = nil
        guard !closed else { return }
        closed = true
        refreshTask?.cancel()
        slowMutationTask?.cancel()
        generation &+= 1
        if !mutating {
            service?.cancel()
            operation?.cancel()
        }
        isBusy = false
        for control in [referencePopup, refreshButton, moreButton, cancelButton] + selectionButtons {
            control.isEnabled = false
            control.target = nil
            control.action = nil
        }
        table.delegate = nil
        table.dataSource = nil
        Self.logger.info("Closed reflog browser")
        super.closeView()
    }

    private var selectedEntry: ReflogEntry? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    }

    private var selectedReference: String {
        let index = referencePopup.indexOfSelectedItem - 1
        return references.indices.contains(index) ? references[index].name ?? "HEAD" : "HEAD"
    }

    private func updateControls() {
        referencePopup.isEnabled = !isBusy
        refreshButton.isEnabled = !mutating
        moreButton.isEnabled = hasMore && !isBusy
        cancelButton.isEnabled = isBusy && !mutating
        table.isEnabled = !closed && requests.permitsSelection
        for (index, button) in selectionButtons.enumerated() {
            button.isEnabled = selectedEntry != nil && !isBusy && (index < 2 || requests.permitsRecovery)
        }
    }

    @discardableResult
    private func run<Value: Sendable>(
        _ title: String, kind: ReflogBrowserRequestKind = .details, mutation: ReflogBrowserMutation? = nil,
        work: @escaping @Sendable (RepositoryReflogService) throws -> Value,
        completion: @escaping (ReflogBrowserController, Result<Value, Error>) -> Void
    ) -> Bool {
        let kind = mutation == nil ? kind : .mutation
        guard !closed, requests.permits(kind), let repository else { return false }
        let service: RepositoryReflogService
        let activity: RepositoryLocalMutationRegistry.Ticket?
        do {
            service = try serviceFactory(repository)
            activity = mutation == nil ? nil : try RepositoryLocalMutationRegistry.shared.admitContinuation()
        } catch {
            if self.service == nil {
                isBusy = false; requests.active = nil; updateControls()
            }
            show(error)
            return false
        }
        self.service?.cancel()
        operation?.cancel()
        slowMutationTask?.cancel()
        generation &+= 1
        let request = generation
        let revision = requests.revision
        let repositoryIdentity = ObjectIdentifier(repository)
        let started = ContinuousClock.now
        do {
            self.service = service
            requests.active = kind
            mutating = mutation != nil
            isBusy = true
            showStatus(title)
            updateControls()
            if mutation != nil {
                let delay = delay
                slowMutationTask = Task { [weak self] in
                    do { try await delay(.seconds(60)) } catch { return }
                    guard !Task.isCancelled, let self, !self.closed, self.generation == request, self.mutating else { return }
                    self.showStatus("The Git operation is still running. It will finish without being interrupted.")
                    Self.logger.notice("Admitted reflog mutation remains active after sixty seconds")
                }
            }
            operation = Task { [weak self, weak repository] in
                defer {
                    if let activity {
                        RepositoryLocalMutationRegistry.shared.finish(activity)
                    }
                }
                let result = await Task.detached(priority: .userInitiated) {
                    if let activity {
                        return try RepositoryLocalMutationRegistry.shared.withStartedActivity(activity) { try work(service) }
                    }
                    return try work(service)
                }.result
                if let mutation, let repository {
                    mutation.reconcile(repository)
                    Self.logger.debug("Reconciled completed reflog mutation independently of browser presentation")
                }
                guard let self, !self.closed, self.generation == request,
                      self.repository.map(ObjectIdentifier.init) == repositoryIdentity else { return }
                self.slowMutationTask?.cancel()
                self.slowMutationTask = nil
                self.service = nil
                self.operation = nil
                self.requests.active = nil
                self.mutating = false
                self.isBusy = false
                self.updateControls()
                Self.logger.debug("Reflog request finished duration=\(String(describing: started.duration(to: .now)), privacy: .public)")
                if mutation == nil, self.requests.revision != revision {
                    if kind == .preview || kind == .details {
                        let message = kind == .preview
                            ? "The repository changed before the reset preview was ready. Refreshing the reflog…"
                            : "The repository changed while commit details were loading. Refreshing the reflog…"
                        self.showStatus(message)
                    }
                    self.scheduleRefresh()
                    return
                }
                completion(self, result)
                self.scheduleRefresh()
            }
        }
        return true
    }

    private func showStatus(_ text: String) {
        let displayed = resetRetryNotice ?? text
        message.stringValue = displayed
        status = displayed
    }

    private func show(_ error: Error) {
        let errorMessage = error is CancellationError ? "Cancelled." : error.localizedDescription
        showStatus(errorMessage)
        detailText.string = errorMessage
        Self.logger.error("Reflog request failed category=\(error is CancellationError ? "cancelled" : "unavailable", privacy: .public)")
    }

    override func refresh(_: Any?) {
        loadPage(append: false)
    }

    @objc private func referenceChanged() {
        resetRetryNotice = nil
        loadPage(append: false)
    }

    @objc private func loadMore() {
        loadPage(append: true)
    }

    @objc private func cancelActivity() {
        service?.cancel()
    }

    private func loadPage(append: Bool, successMessage: String? = nil) {
        guard !closed, !mutating, !append || (!requests.stale && !isBusy) else { return }
        let reference = selectedReference
        let selectedObject = selectedEntry?.objectID
        let offset = append ? entries.count : 0
        let expected = append ? fingerprint : nil
        let accepted = run(successMessage ?? "Loading reflog…", kind: .page, work: { service in
            let branches = try service.referenceChoices()
            let actualReference = reference == "HEAD" || branches.contains(where: { $0.name == reference }) ? reference : "HEAD"
            let actualOffset = actualReference == reference ? offset : 0
            return try ReflogBrowserLoad(branches: branches, reference: actualReference,
                                         page: service.page(reference: actualReference, offset: actualOffset,
                                                            expectedFingerprint: actualOffset == 0 ? nil : expected, references: branches))
        }) { owner, result in
            switch result {
            case let .success(load):
                owner.references = load.branches
                owner.referencePopup.removeAllItems()
                owner.referencePopup.addItem(withTitle: "Current checkout’s HEAD")
                for branch in load.branches {
                    owner.referencePopup.addItem(withTitle: branch.displayName)
                    owner.referencePopup.itemArray.last?.isEnabled = branch.name != nil
                }
                let selection = load.branches.firstIndex { $0.name == load.reference }.map { $0 + 1 } ?? 0
                owner.referencePopup.selectItem(at: selection)
                owner.entries = append && reference == load.reference ? owner.entries + load.page.entries : load.page.entries
                owner.fingerprint = load.page.fingerprint
                owner.hasMore = load.page.hasMore
                owner.requests.refreshSucceeded()
                owner.restoringSelection = true
                owner.table.reloadData()
                if let selectedObject, let row = owner.entries.firstIndex(where: { $0.objectID == selectedObject }) {
                    owner.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                owner.restoringSelection = false
                owner.showStatus(owner.entries.isEmpty
                    ? "This reflog has no retained events. Git may have expired older history."
                    : "\(owner.entries.count) events. Recovery is available only while Git retains the selected commit.")
                owner.updateControls()
            case let .failure(error):
                if !append {
                    owner.requests.refreshFailed()
                }
                owner.show(error)
            }
        }
        if accepted {
            refreshTask?.cancel()
            refreshTask = nil
            if !append {
                requests.beginRefresh(); fingerprint = nil; hasMore = false
            }
            updateControls()
        }
    }

    func numberOfRows(in _: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "time": value = entry.eventDate.formatted(date: .numeric, time: .standard)
        case "actor": value = entry.actor
        case "action": value = entry.action
        case "commit": value = String(entry.objectID.prefix(12))
        default: value = entry.subject
        }
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("subject")
        let label = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        label.identifier = identifier
        label.stringValue = value
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = value
        return label
    }

    func tableViewSelectionDidChange(_: Notification) {
        updateControls()
        guard !restoringSelection, requests.permitsSelection else { return }
        showDetails(compare: false)
    }

    private func showDetails(compare: Bool) {
        guard let entry = selectedEntry else { return }
        let objectID = entry.objectID
        run(compare ? "Comparing with HEAD…" : "Loading commit…", work: { try $0.details(objectID: objectID, compareWithHead: compare) }) { owner, result in
            switch result {
            case let .success(details):
                owner.detailText.string = details
                owner.showStatus(objectID)
            case let .failure(error): owner.show(error)
            }
        }
    }

    @objc private func compareWithHead() {
        showDetails(compare: true)
    }

    @objc private func copyCommitID() {
        guard let entry = selectedEntry, !closed else { return }
        pasteboard.clearContents()
        pasteboard.setString(entry.objectID, forType: .string)
    }

    @objc private func createBranch() {
        guard let entry = selectedEntry, let window = view.window, !closed, !isBusy else { return }
        let alert = NSAlert()
        alert.messageText = "Create Recovery Branch"
        alert.informativeText = "Preserve commit \(entry.objectID) in a new branch. Your current checkout stays in place."
        let name = NSTextField(string: "recovery/" + String(entry.objectID.prefix(12)))
        name.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
        name.setAccessibilityIdentifier("GitX.Reflog.BranchName")
        alert.accessoryView = name
        alert.addButton(withTitle: "Create Branch")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !self.closed else { return }
            let branchName = name.stringValue
            self.run("Creating recovery branch…", mutation: .branch, work: { try $0.createRecoveryBranch(objectID: entry.objectID, name: branchName) }) { owner, result in
                switch result {
                case .success:
                    owner.publishResult("Created \(branchName).")
                case let .failure(error): owner.publishResult(error.localizedDescription)
                }
                owner.loadPage(append: false)
            }
        }
    }

    @objc private func resetCheckout() {
        guard let entry = selectedEntry, let window = view.window, !closed, !isBusy else { return }
        if resetRetryNotice != nil {
            resetRetryNotice = nil
            showStatus("Choose a reset mode to preview the affected paths.")
        }
        let alert = NSAlert()
        alert.messageText = "Reset Current Checkout to This Commit"
        alert.informativeText = "Choose a mode, then review the affected paths before making changes."
        let modes = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 550, height: 28), pullsDown: false)
        modes.addItems(withTitles: ReflogResetMode.allCases.map { $0.rawValue.capitalized + " — " + $0.explanation })
        modes.setAccessibilityIdentifier("GitX.Reflog.ResetMode")
        alert.accessoryView = modes
        alert.addButton(withTitle: "Preview Reset")
        alert.addButton(withTitle: "Cancel")
        let revision = requests.revision
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !self.closed else { return }
            guard self.requests.permitsResetPreview(at: revision) else {
                let notice = "The repository changed. Review the current reflog and try Preview Reset again."
                self.resetRetryNotice = notice
                self.showStatus(notice)
                self.scheduleRefresh()
                return
            }
            let mode = ReflogResetMode.allCases[modes.indexOfSelectedItem]
            self.run("Preparing reset preview…", kind: .preview, work: { try $0.preview(target: entry.objectID, mode: mode) }) { owner, result in
                switch result {
                case let .success(preview): owner.confirmReset(preview)
                case let .failure(error): owner.show(error)
                }
            }
        }
    }

    private func confirmReset(_ preview: RepositoryRecoveryPreview) {
        guard !closed, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Review \(preview.mode.rawValue.capitalized) Reset"
        let checkout = preview.branch == "HEAD" ? "Detached HEAD" : preview.branch
        alert.informativeText = "Checkout: \(checkout)\nCurrent commit: \(preview.previousHead)\nTarget commit: \(preview.target)\n\n\(preview.mode.explanation)\n\nA new recovery/… branch will preserve the current committed history only. Uncommitted changes are not backed up. No automatic stash is created. Submodules are not recursively reset."
        let paths = NSTextView(frame: NSRect(x: 0, y: 0, width: 550, height: 180))
        paths.isEditable = false
        paths.isRichText = false
        paths.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        paths.string = "Affected paths:\n" + (preview.affectedPaths.isEmpty ? "None" : preview.affectedPaths.joined(separator: "\n"))
        if preview.mode == .hard {
            paths.string += "\n\nLocal changes and obstructing files to discard (including ignored files):\n" + (preview.discardedPaths.isEmpty ? "None" : preview.discardedPaths.joined(separator: "\n"))
        }
        paths.setAccessibilityIdentifier("GitX.Reflog.ResetPreview")
        let scroll = NSScrollView(frame: paths.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = paths
        alert.accessoryView = scroll
        alert.addButton(withTitle: preview.mode.requiresDiscardConfirmation ? "Continue…" : "Create Backup and Reset")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !self.closed else { return }
            if preview.mode.requiresDiscardConfirmation {
                self.confirmDiscard(preview)
            } else {
                self.performReset(preview, discard: false)
            }
        }
    }

    private func confirmDiscard(_ preview: RepositoryRecoveryPreview) {
        guard !closed, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard Changes and Reset?"
        alert.informativeText = "Hard reset discards tracked edits and removes untracked or ignored files that obstruct the target. The recovery branch preserves committed history only; it cannot restore discarded local changes."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes and Reset")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self, !self.closed else { return }
            self.performReset(preview, discard: true)
        }
    }

    private func performReset(_ preview: RepositoryRecoveryPreview, discard: Bool) {
        run("Creating backup and resetting checkout…", mutation: .reset, work: { try $0.reset(confirmed: preview, discardConfirmed: discard) }) { owner, result in
            switch result {
            case let .success(backup):
                owner.publishResult("Reset complete. Previous committed history: \(backup).")
            case let .failure(error): owner.publishResult(error.localizedDescription)
            }
            owner.loadPage(append: false)
        }
    }
}
