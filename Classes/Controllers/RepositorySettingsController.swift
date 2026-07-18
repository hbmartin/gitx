import AppKit
import GitXCore

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

@objc(PBRepositorySettingsController)
final class RepositorySettingsController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private static var activeControllers: [RepositorySettingsController] = []
    private enum Tab: String, CaseIterable {
        case general = "General"
        case commit = "Commit"
        case sidebar = "Sidebar"
        case diff = "Diff"

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .commit: "text.badge.checkmark"
            case .sidebar: "sidebar.left"
            case .diff: "doc.text.magnifyingglass"
            }
        }
    }

    private weak var parentWindow: NSWindow?
    private let repository: PBGitRepository
    private let store: RepositorySettingsStore
    private let contentHost = NSView()
    private var panes: [Tab: NSView] = [:]
    private var selectedTab: Tab = .general
    private let primaryBranchField = NSTextField()
    private let autoOpenURLButton = NSButton()
    private let requireHostMatchButton = NSButton()
    private let webURLTemplateField = NSTextField()
    private let notifyButton = NSButton()
    private let rulesTextView = NSTextView()
    private let sidebarButtons: [String: NSButton] = Dictionary(
        uniqueKeysWithValues: ["Stage", "Remotes", "Tags", "Stashes", "Submodules", "Other"].map {
            ($0, NSButton())
        }
    )
    private let hideContainedButton = NSButton()
    private let suppressionTextView = NSTextView()
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositorySettingsSheet")

    /// Objective-C callers are not visible to SwiftLint's analyzer.
    @objc(beginSheetForRepository:windowController:)
    // swiftlint:disable:next unused_declaration
    static func beginSheet(for repository: PBGitRepository, windowController: PBGitWindowController) {
        let controller = RepositorySettingsController(repository: repository, parentWindow: windowController.window)
        activeControllers.append(controller)
        controller.showSheet()
    }

    private init(repository: PBGitRepository, parentWindow: NSWindow?) {
        self.repository = repository
        self.parentWindow = parentWindow
        store = ApplicationComposition.shared.repositoryConfiguration(for: repository)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Settings for \(repository.projectName() ?? "Repository")"
        super.init(window: panel)
        panel.delegate = self
        configureToolbar()
        configureContent()
        loadValues()
        select(tab: .general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "GitX.RepositorySettings.Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .preference
    }

    private func configureContent() {
        guard let root = window?.contentView else { return }
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentHost)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        save.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(cancel)
        root.addSubview(save)
        NSLayoutConstraint.activate([
            contentHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: root.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: cancel.topAnchor, constant: -14),
            save.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            save.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
        ])
        panes[.general] = generalPane()
        panes[.commit] = commitPane()
        panes[.sidebar] = sidebarPane()
        panes[.diff] = diffPane()
    }

    private func showSheet() {
        guard let window, let parentWindow else { return }
        parentWindow.beginSheet(window)
        logger.info("Presented repository settings sheet")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = Tab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.rawValue
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.rawValue)
        item.target = self
        item.action = #selector(tabSelected(_:))
        return item
    }

    @objc private func tabSelected(_ sender: NSToolbarItem) {
        guard let tab = Tab(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(tab: tab)
    }

    private func select(tab: Tab) {
        selectedTab = tab
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        guard let pane = panes[tab] else { return }
        pane.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 24),
            pane.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -24),
            pane.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 20),
            pane.bottomAnchor.constraint(lessThanOrEqualTo: contentHost.bottomAnchor, constant: -12),
        ])
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)
    }

    private func generalPane() -> NSView {
        primaryBranchField.widthAnchor.constraint(equalToConstant: 270).isActive = true
        webURLTemplateField.widthAnchor.constraint(equalToConstant: 390).isActive = true
        autoOpenURLButton.setButtonType(.switch)
        autoOpenURLButton.title = "Automatically open the first URL returned by a successful push"
        requireHostMatchButton.setButtonType(.switch)
        requireHostMatchButton.title = "Require the URL host to match the pushed Git remote"
        notifyButton.setButtonType(.switch)
        notifyButton.title = "Notify me when scheduled fetch finds new commits"
        return pane(
            title: "General",
            rows: [
                row(label: "Primary branch:", control: primaryBranchField),
                autoOpenURLButton,
                requireHostMatchButton,
                row(label: "Web URL template:", control: webURLTemplateField),
                help("HTTPS only. Available placeholders: {remoteURL}, {branch}, and {sha}."),
                notifyButton,
            ]
        )
    }

    private func commitPane() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = rulesTextView
        scroll.heightAnchor.constraint(equalToConstant: 245).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 635).isActive = true
        return pane(
            title: "Commit Message Replacement Rules",
            rows: [
                help("One ordered rule per line: regular expression => replacement. Use $1 capture groups. Prefix flags with (?i), (?m), or (?s). Rules run top-to-bottom over every match."),
                scroll,
                help("The transformed message replaces the editor contents as one undoable change before commit hooks run."),
            ]
        )
    }

    private func sidebarPane() -> NSView {
        let checks = sidebarButtons.keys.sorted().compactMap { name -> NSView? in
            guard let button = sidebarButtons[name] else { return nil }
            button.setButtonType(.switch)
            button.title = name
            return button
        }
        hideContainedButton.setButtonType(.switch)
        hideContainedButton.title = "Hide branches with no commits outside the primary branch"
        return pane(
            title: "Sidebar",
            rows: [
                help("BRANCHES is always visible. Choose the other groups shown for this repository."),
                NSStackView(views: checks),
                hideContainedButton,
            ]
        )
    }

    private func diffPane() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = suppressionTextView
        scroll.heightAnchor.constraint(equalToConstant: 270).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 635).isActive = true
        return pane(
            title: "Diff Suppression Patterns",
            rows: [
                help("Regular expressions, one per line. Lines beginning with # are comments. Matching files show a placeholder and a Show Diff button instead of rendering automatically."),
                scroll,
            ]
        )
    }

    private func pane(title: String, rows: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .preferredFont(forTextStyle: .headline, options: [:])
        heading.setAccessibilityIdentifier("RepositorySettingsPaneHeading")
        let stack = NSStackView(views: [heading] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private func row(label: String, control: NSView) -> NSView {
        let field = NSTextField(labelWithString: label)
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 145).isActive = true
        let row = NSStackView(views: [field, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func help(_ string: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 3
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 635).isActive = true
        return field
    }

    private func loadValues() {
        primaryBranchField.stringValue = store.detectedPrimaryBranch()
        autoOpenURLButton.state = store.bool(forKey: RepositorySettingsStore.autoOpenURLKey, defaultValue: false) ? .on : .off
        requireHostMatchButton.state = store.bool(forKey: RepositorySettingsStore.requireHostMatchKey, defaultValue: true) ? .on : .off
        webURLTemplateField.stringValue = store.string(forKey: RepositorySettingsStore.webURLTemplateKey)
        notifyButton.state = PBGitDefaults.notifyAboutFetchedCommits(forRepositoryURL: repository.workingDirectoryURL()) ? .on : .off
        rulesTextView.string = store.string(forKey: RepositorySettingsStore.commitRulesKey)
        suppressionTextView.string = store.string(forKey: RepositorySettingsStore.diffSuppressionKey)
        for (name, button) in sidebarButtons {
            button.state = store.uiSettings.isSidebarGroupVisible(name) ? .on : .off
        }
        hideContainedButton.state = store.uiSettings.hideContainedBranches ? .on : .off
    }

    @objc private func cancel(_ sender: Any?) {
        closeSheet()
    }

    @objc private func save(_ sender: Any?) {
        do {
            try validateValues()
            try store.setString(primaryBranchField.stringValue, forKey: RepositorySettingsStore.primaryBranchKey)
            try store.setBool(autoOpenURLButton.state == .on, forKey: RepositorySettingsStore.autoOpenURLKey)
            try store.setBool(requireHostMatchButton.state == .on, forKey: RepositorySettingsStore.requireHostMatchKey)
            try store.setString(webURLTemplateField.stringValue, forKey: RepositorySettingsStore.webURLTemplateKey)
            try store.setString(rulesTextView.string, forKey: RepositorySettingsStore.commitRulesKey)
            try store.setString(suppressionTextView.string, forKey: RepositorySettingsStore.diffSuppressionKey)
            PBGitDefaults.setNotifyAboutFetchedCommits(notifyButton.state == .on, forRepositoryURL: repository.workingDirectoryURL())
            store.uiSettings.sidebarVisibility = sidebarButtons.mapValues { $0.state == .on }
            store.uiSettings.hideContainedBranches = hideContainedButton.state == .on
            NotificationCenter.default.post(name: .repositorySettingsDidChange, object: repository)
            logger.info("Saved repository settings")
            closeSheet()
        } catch {
            _ = window?.presentError(error)
        }
    }

    private func validateValues() throws {
        guard let issue = RepositoryConfigurationPolicy.validate(
            webURLTemplate: webURLTemplateField.stringValue,
            commitRules: rulesTextView.string,
            diffSuppressionPatterns: suppressionTextView.string
        ) else { return }
        throw NSError(
            domain: PBGitXErrorDomain,
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: RepositoryConfigurationIssuePresenter.message(for: issue)]
        )
    }

    private func closeSheet() {
        guard let window else { return }
        if let parentWindow {
            parentWindow.endSheet(window)
        }
        window.orderOut(nil)
        Self.activeControllers.removeAll { $0 === self }
    }
}
