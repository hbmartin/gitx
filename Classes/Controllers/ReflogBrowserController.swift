import AppKit
import GitXCore
import OSLog

private nonisolated struct ReflogBrowserLoad: Sendable {
    let branches: [String]
    let page: RepositoryReflogPage
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
    private var references = ["HEAD"]
    private var fingerprint: WorktreeFileFingerprint?
    private var hasMore = false
    private var closed = false
    private var generation: UInt64 = 0
    private var service: RepositoryReflogService?
    private var operation: Task<Void, Never>?
    private var mutating = false

    static func make(repository: PBGitRepository, windowController: PBGitWindowController? = nil) -> ReflogBrowserController? {
        ReflogBrowserController(repository: repository, superController: windowController)
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
        service?.cancel()
        operation?.cancel()
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        root.setAccessibilityIdentifier("GitX.Reflog")
        referencePopup.target = self
        referencePopup.action = #selector(referenceChanged)
        referencePopup.setAccessibilityIdentifier("GitX.Reflog.Reference")
        referencePopup.setAccessibilityLabel("Reflog reference")
        referencePopup.addItem(withTitle: "Current checkout’s HEAD")
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
        for child in [header, split, footer, message] {
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
            message.topAnchor.constraint(equalTo: footer.bottomAnchor, constant: 6),
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
        guard !closed, !mutating, service != nil else { return }
        generation &+= 1
        service?.cancel()
        operation?.cancel()
        service = nil
        operation = nil
        isBusy = false
        message.stringValue = "The repository changed. Refresh the reflog before continuing."
        status = message.stringValue
        detailText.string = message.stringValue
        updateControls()
        Self.logger.debug("Discarded stale reflog request after repository change")
    }

    override func closeView() {
        guard !closed else { return }
        closed = true
        generation &+= 1
        service?.cancel()
        operation?.cancel()
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
        references.indices.contains(referencePopup.indexOfSelectedItem) ? references[referencePopup.indexOfSelectedItem] : "HEAD"
    }

    private func updateControls() {
        referencePopup.isEnabled = !isBusy
        refreshButton.isEnabled = !mutating
        moreButton.isEnabled = hasMore && !isBusy
        cancelButton.isEnabled = isBusy && !mutating
        table.isEnabled = !mutating
        for button in selectionButtons {
            button.isEnabled = selectedEntry != nil && !isBusy
        }
    }

    private func run<Value: Sendable>(
        _ title: String, mutation: Bool = false,
        work: @escaping @Sendable (RepositoryReflogService) throws -> Value,
        completion: @escaping (ReflogBrowserController, Result<Value, Error>) -> Void
    ) {
        guard !closed, !mutating, let repository else { return }
        service?.cancel()
        operation?.cancel()
        generation &+= 1
        let request = generation
        let repositoryIdentity = ObjectIdentifier(repository)
        let started = ContinuousClock.now
        do {
            let service = try RepositoryReflogService(repository: repository)
            self.service = service
            mutating = mutation
            isBusy = true
            message.stringValue = title
            status = title
            updateControls()
            operation = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) { try work(service) }.result
                guard let self, !self.closed, self.generation == request,
                      self.repository.map(ObjectIdentifier.init) == repositoryIdentity else { return }
                self.service = nil
                self.operation = nil
                self.mutating = false
                self.isBusy = false
                self.updateControls()
                Self.logger.debug("Reflog request finished duration=\(String(describing: started.duration(to: .now)), privacy: .public)")
                completion(self, result)
            }
        } catch { show(error) }
    }

    private func show(_ error: Error) {
        message.stringValue = error is CancellationError ? "Cancelled." : error.localizedDescription
        status = message.stringValue
        detailText.string = message.stringValue
        Self.logger.error("Reflog request failed category=\(error is CancellationError ? "cancelled" : "unavailable", privacy: .public)")
    }

    override func refresh(_: Any?) {
        loadPage(append: false)
    }

    @objc private func referenceChanged() {
        loadPage(append: false)
    }

    @objc private func loadMore() {
        loadPage(append: true)
    }

    @objc private func cancelActivity() {
        service?.cancel()
    }

    private func loadPage(append: Bool) {
        guard !closed, !mutating else { return }
        let reference = selectedReference
        let offset = append ? entries.count : 0
        let expected = append ? fingerprint : nil
        if !append {
            entries = []
            table.reloadData()
            detailText.string = ""
            hasMore = false
        }
        run("Loading reflog…", work: { service in
            try ReflogBrowserLoad(branches: service.branches(), page: service.page(reference: reference, offset: offset, expectedFingerprint: expected))
        }) { owner, result in
            switch result {
            case let .success(load):
                owner.references = ["HEAD"] + load.branches
                owner.referencePopup.removeAllItems()
                owner.referencePopup.addItems(withTitles: ["Current checkout’s HEAD"] + load.branches.map { String($0.dropFirst("refs/heads/".count)) })
                owner.referencePopup.selectItem(at: owner.references.firstIndex(of: reference) ?? 0)
                owner.entries += load.page.entries
                owner.fingerprint = load.page.fingerprint
                owner.hasMore = load.page.hasMore
                owner.table.reloadData()
                owner.message.stringValue = owner.entries.isEmpty
                    ? "This reflog has no retained events. Git may have expired older history."
                    : "\(owner.entries.count) events. Recovery is available only while Git retains the selected commit."
                owner.status = owner.message.stringValue
                owner.updateControls()
            case let .failure(error): owner.show(error)
            }
        }
    }

    func numberOfRows(in _: NSTableView) -> Int {
        entries.count
    }

    func tableView(_: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = value
        return label
    }

    func tableViewSelectionDidChange(_: Notification) {
        updateControls()
        showDetails(compare: false)
    }

    private func showDetails(compare: Bool) {
        guard let entry = selectedEntry else { return }
        let objectID = entry.objectID
        run(compare ? "Comparing with HEAD…" : "Loading commit…", work: { try $0.details(objectID: objectID, compareWithHead: compare) }) { owner, result in
            switch result {
            case let .success(details):
                owner.detailText.string = details
                owner.message.stringValue = objectID
                owner.status = objectID
            case let .failure(error): owner.show(error)
            }
        }
    }

    @objc private func compareWithHead() {
        showDetails(compare: true)
    }

    @objc private func copyCommitID() {
        guard let entry = selectedEntry, !closed else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.objectID, forType: .string)
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
            self.run("Creating recovery branch…", mutation: true, work: { try $0.createRecoveryBranch(objectID: entry.objectID, name: branchName) }) { owner, result in
                switch result {
                case .success:
                    owner.repository?.reloadRefs()
                    owner.message.stringValue = "Created \(branchName)."
                    owner.status = owner.message.stringValue
                case let .failure(error): owner.show(error)
                }
            }
        }
    }

    @objc private func resetCheckout() {
        guard let entry = selectedEntry, let window = view.window, !closed, !isBusy else { return }
        let alert = NSAlert()
        alert.messageText = "Reset Current Checkout to This Commit"
        alert.informativeText = "Choose a mode, then review the affected paths before making changes."
        let modes = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 550, height: 28), pullsDown: false)
        modes.addItems(withTitles: ReflogResetMode.allCases.map { $0.rawValue.capitalized + " — " + $0.explanation })
        modes.setAccessibilityIdentifier("GitX.Reflog.ResetMode")
        alert.accessoryView = modes
        alert.addButton(withTitle: "Preview Reset")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !self.closed else { return }
            let mode = ReflogResetMode.allCases[modes.indexOfSelectedItem]
            self.run("Preparing reset preview…", work: { try $0.preview(target: entry.objectID, mode: mode) }) { owner, result in
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
        alert.addButton(withTitle: preview.mode == .hard ? "Continue…" : "Create Backup and Reset")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !self.closed else { return }
            if preview.mode == .hard {
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
        run("Creating backup and resetting checkout…", mutation: true, work: { try $0.reset(confirmed: preview, discardConfirmed: discard) }) { owner, result in
            owner.repository?.reloadRefs()
            owner.repository?.lazyReload()
            switch result {
            case let .success(backup):
                owner.message.stringValue = "Reset complete. Previous committed history: \(backup)."
                owner.status = owner.message.stringValue
                owner.detailText.string = owner.message.stringValue
            case let .failure(error): owner.show(error)
            }
        }
    }
}
