import AppKit
import ForgeKit
import OSLog // swiftlint:disable:this unused_import

#if GITX_APP_TARGET
    @MainActor
    private final class ForgeRepositoryCloneApplicationController {
        static let shared = ForgeRepositoryCloneApplicationController()

        private var catalogTask: Task<Void, Never>?
        private var cloneTask: Task<Void, Never>?
        private var sheetController: ForgeRepositoryCloneSheetController?

        func present() {
            catalogTask?.cancel()
            let service = ApplicationComposition.shared.forgeCloneServices.service()
            catalogTask = Task { [weak self] in
                do {
                    let catalogs = try await service.cloneCatalogs()
                    guard let self, !Task.isCancelled else { return }
                    guard catalogs.contains(where: { !$0.repositories.isEmpty }) else {
                        throw RepositoryPullRequestServiceError.repositoryUnavailable
                    }
                    let controller = ForgeRepositoryCloneSheetController(catalogs: catalogs)
                    controller.onClone = { [weak self] choice in self?.clone(choice) }
                    sheetController = controller
                    if let parent = NSApp.keyWindow {
                        controller.beginSheet(for: parent)
                    } else {
                        controller.showWindow(nil)
                        controller.window?.makeKeyAndOrderFront(nil)
                    }
                    NSApp.activate(ignoringOtherApps: true)
                } catch is CancellationError {
                    return
                } catch {
                    NSApp.presentError(error)
                }
            }
        }

        private func clone(_ choice: RepositoryForgeCloneChoice) {
            cloneTask?.cancel()
            let executor = RepositoryForgeCloneExecutor(runner: RepositoryForgeProcessGitRunner())
            cloneTask = Task { [weak self] in
                do {
                    let receipt = try await Task.detached(priority: .userInitiated) {
                        try executor.clone(choice)
                    }.value
                    guard !Task.isCancelled else { return }
                    NSDocumentController.shared.openDocument(
                        withContentsOf: receipt.destinationURL,
                        display: true
                    ) { _, _, error in
                        if let error {
                            NSApp.presentError(error)
                        }
                    }
                    self?.sheetController = nil
                } catch is CancellationError {
                    return
                } catch {
                    NSApp.presentError(error)
                }
            }
        }
    }

    extension ApplicationController {
        @IBAction @objc(showForgeCloneRepositories:)
        func showForgeCloneRepositories(_: Any?) {
            ForgeRepositoryCloneApplicationController.shared.present()
        }
    }
#endif

/// Owned/organization-only GitHub clone browser. The selected account and SSH
/// transport are always explicit; starred repositories never enter its model.
@MainActor
final class ForgeRepositoryCloneSheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onClone: ((RepositoryForgeCloneChoice) -> Void)?

    private let catalogs: [RepositoryForgeCloneCatalog]
    private let accountPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let repositoryTable = NSTableView()
    private let sshButton = NSButton(checkboxWithTitle: "Use SSH", target: nil, action: nil)
    private let destinationField = NSTextField()
    private let cloneButton = NSButton(title: "Clone", target: nil, action: nil)
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeClone")

    init(catalogs: [RepositoryForgeCloneCatalog]) {
        self.catalogs = catalogs.filter { !$0.repositories.isEmpty }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Clone GitHub Repository"
        super.init(window: panel)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ForgeRepositoryCloneSheetController is built in code")
    }

    func beginSheet(for parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        logger.notice("Presented owned/organization GitHub clone browser")
    }

    func selectedChoice(destinationDirectory: URL? = nil) throws -> RepositoryForgeCloneChoice {
        guard accountPopup.indexOfSelectedItem >= 0,
              accountPopup.indexOfSelectedItem < catalogs.count,
              repositoryTable.selectedRow >= 0,
              repositoryTable.selectedRow < currentEntries.count
        else {
            throw RepositoryPullRequestServiceError.repositoryUnavailable
        }
        let catalog = catalogs[accountPopup.indexOfSelectedItem]
        let entry = currentEntries[repositoryTable.selectedRow]
        let destination = destinationDirectory ?? URL(fileURLWithPath: destinationField.stringValue, isDirectory: true)
        let request = try ForgeCloneRequest(
            accountID: catalog.accountID,
            repository: entry.repository,
            relationship: entry.relationship,
            transport: sshButton.state == .on ? .ssh : .https
        )
        return try RepositoryForgeCloneChoice(request: request, destinationDirectory: destination)
    }

    private var currentEntries: [RepositoryForgeCloneCatalog.Entry] {
        guard accountPopup.indexOfSelectedItem >= 0, accountPopup.indexOfSelectedItem < catalogs.count else {
            return []
        }
        return catalogs[accountPopup.indexOfSelectedItem].repositories
    }

    private func configure() { // swiftlint:disable:this function_body_length
        guard let contentView = window?.contentView else { return }

        let accountLabel = NSTextField(labelWithString: "Account:")
        accountPopup.addItems(withTitles: catalogs.map(\.accountDisplayName))
        accountPopup.target = self
        accountPopup.action = #selector(accountChanged(_:))
        accountPopup.setAccessibilityIdentifier("GitX.Clone.Account")
        accountPopup.setAccessibilityLabel("GitHub Account")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repository"))
        column.title = "Owned and Organization Repositories"
        repositoryTable.addTableColumn(column)
        repositoryTable.headerView = NSTableHeaderView()
        repositoryTable.dataSource = self
        repositoryTable.delegate = self
        repositoryTable.rowHeight = 24
        repositoryTable.allowsEmptySelection = false
        repositoryTable.setAccessibilityIdentifier("GitX.Clone.Repositories")
        repositoryTable.setAccessibilityLabel("Owned and organization repositories")
        let scrollView = NSScrollView()
        scrollView.documentView = repositoryTable
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        sshButton.state = .on
        sshButton.setAccessibilityIdentifier("GitX.Clone.UseSSH")
        sshButton.setAccessibilityLabel("Clone using SSH")

        let destinationLabel = NSTextField(labelWithString: "Clone into:")
        destinationField.placeholderString = "Choose a destination folder"
        destinationField.setAccessibilityIdentifier("GitX.Clone.Destination")
        destinationField.setAccessibilityLabel("Clone destination folder")
        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseDestination(_:)))
        chooseButton.setAccessibilityIdentifier("GitX.Clone.ChooseDestination")

        cloneButton.target = self
        cloneButton.action = #selector(clone(_:))
        cloneButton.keyEquivalent = "\r"
        cloneButton.setAccessibilityIdentifier("GitX.Clone.Submit")
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("GitX.Clone.Cancel")

        let accountRow = NSStackView(views: [accountLabel, accountPopup, NSView(), sshButton])
        accountRow.orientation = .horizontal
        accountRow.spacing = 8
        let destinationRow = NSStackView(views: [destinationLabel, destinationField, chooseButton])
        destinationRow.orientation = .horizontal
        destinationRow.spacing = 8
        let buttons = NSStackView(views: [NSView(), cancelButton, cloneButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [accountRow, scrollView, destinationRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            accountRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            destinationRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            destinationField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
        repositoryTable.reloadData()
        if !currentEntries.isEmpty {
            repositoryTable.selectRowIndexes([0], byExtendingSelection: false)
        }
        updateEligibility()
    }

    func numberOfRows(in _: NSTableView) -> Int {
        currentEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ForgeCloneRepositoryCell")
        let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        let entry = currentEntries[row]
        let path = (entry.repository.ownerPathComponents + [entry.repository.name]).joined(separator: "/")
        let relationship = entry.relationship == .owned ? "Owned" : "Organization"
        field.stringValue = "\(path)  —  \(relationship)"
        return field
    }

    func tableViewSelectionDidChange(_: Notification) {
        updateEligibility()
    }

    @objc private func accountChanged(_: Any?) {
        repositoryTable.reloadData()
        if !currentEntries.isEmpty {
            repositoryTable.selectRowIndexes([0], byExtendingSelection: false)
        }
        updateEligibility()
    }

    @objc private func chooseDestination(_: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.destinationField.stringValue = url.path
            self?.updateEligibility()
        }
    }

    @objc private func clone(_: Any?) {
        do {
            let choice = try selectedChoice()
            closeSheet()
            onClone?(choice)
        } catch {
            NSSound.beep()
        }
    }

    @objc private func cancel(_: Any?) {
        closeSheet()
    }

    private func updateEligibility() {
        cloneButton.isEnabled = repositoryTable.selectedRow >= 0 && !destinationField.stringValue.isEmpty
    }

    private func closeSheet() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
    }
}
