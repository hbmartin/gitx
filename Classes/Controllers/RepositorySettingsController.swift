import AppKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

@objc(PBRepositoryUISettings)
final nonisolated class RepositoryUISettings: NSObject {
    private static let defaultsKey = "PBRepositoryUISettings"
    private let repositoryKey: String

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        repositoryKey = Self.commonGitDirectory(for: repository).standardizedFileURL.path
        super.init()
    }

    @objc var hideContainedBranches: Bool {
        get { value(for: "hideContainedBranches") as? Bool ?? false }
        set { setValue(newValue, for: "hideContainedBranches") }
    }

    @objc var pushAfterCommit: Bool {
        get { value(for: "pushAfterCommit") as? Bool ?? false }
        set { setValue(newValue, for: "pushAfterCommit") }
    }

    @objc var sidebarVisibility: [String: Bool] {
        get {
            value(for: "sidebarVisibility") as? [String: Bool] ?? [
                "Stage": true,
                "Remotes": true,
                "Tags": true,
                "Stashes": true,
                "Submodules": true,
                "Other": true,
            ]
        }
        set { setValue(newValue, for: "sidebarVisibility") }
    }

    @objc func isSidebarGroupVisible(_ group: String) -> Bool {
        sidebarVisibility[group] ?? true
    }

    private func value(for key: String) -> Any? {
        let all = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) ?? [:]
        return (all[repositoryKey] as? [String: Any])?[key]
    }

    private func setValue(_ value: Any, for key: String) {
        var all = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) ?? [:]
        var repository = all[repositoryKey] as? [String: Any] ?? [:]
        repository[key] = value
        all[repositoryKey] = repository
        UserDefaults.standard.set(all, forKey: Self.defaultsKey)
    }

    private static func commonGitDirectory(for repository: PBGitRepository) -> URL {
        if let output = try? repository.outputOfTask(withArguments: ["rev-parse", "--git-common-dir"]),
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            let base = repository.workingDirectoryURL() ?? repository.gitURL() ?? URL(fileURLWithPath: "/")
            return base.appendingPathComponent(path, isDirectory: true).standardizedFileURL
        }
        return repository.gitURL() ?? repository.workingDirectoryURL() ?? URL(fileURLWithPath: "/")
    }
}

@objc(PBRepositorySettingsStore)
final nonisolated class RepositorySettingsStore: NSObject {
    static let primaryBranchKey = "gitx.primaryBranch"
    static let commitRulesKey = "gitx.commitMessageReplacementRules"
    static let autoOpenURLKey = "gitx.autoOpenPushedURL"
    static let requireHostMatchKey = "gitx.requirePushedURLHostMatch"
    static let webURLTemplateKey = "gitx.webURLTemplate"
    static let diffSuppressionKey = "gitx.diffSuppressionPatterns"

    private let repository: PBGitRepository
    @objc let uiSettings: RepositoryUISettings
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositorySettings")

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        uiSettings = RepositoryUISettings(repository: repository)
        super.init()
    }

    @objc func string(forKey key: String) -> String {
        do {
            return try repository.outputOfTask(withArguments: ["config", "--local", "--get", key])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    @objc func bool(forKey key: String, defaultValue: Bool) -> Bool {
        let value = string(forKey: key).lowercased()
        if ["true", "yes", "on", "1"].contains(value) {
            return true
        }
        if ["false", "no", "off", "0"].contains(value) {
            return false
        }
        return defaultValue
    }

    @objc func setString(_ value: String, forKey key: String) throws {
        try repository.launchTask(withArguments: ["config", "--local", key, value])
        logger.info("Updated repository-local GitX configuration")
    }

    @objc func setBool(_ value: Bool, forKey key: String) throws {
        try setString(value ? "true" : "false", forKey: key)
    }

    @objc func detectedPrimaryBranch() -> String {
        let configured = string(forKey: Self.primaryBranchKey)
        if !configured.isEmpty {
            return configured
        }
        if let remoteHead = try? repository.outputOfTask(withArguments: [
            "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD",
        ]) {
            let short = remoteHead.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = short.firstIndex(of: "/") {
                return String(short[short.index(after: slash)...])
            }
        }
        if repository.ref(forName: "main") != nil {
            return "main"
        }
        if repository.ref(forName: "master") != nil {
            return "master"
        }
        return repository.headRef()?.ref()?.shortName() ?? "main"
    }
}

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
        store = RepositorySettingsStore(repository: repository)
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
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
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
        let template = webURLTemplateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !template.isEmpty, URL(string: template)?.scheme?.lowercased() != "https" {
            throw NSError(
                domain: PBGitXErrorDomain,
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "The web URL template must use HTTPS."]
            )
        }
        for line in rulesTextView.string.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.components(separatedBy: "=>")
            guard parts.count >= 2 else {
                throw NSError(
                    domain: PBGitXErrorDomain,
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Each commit rule must contain =>."]
                )
            }
            _ = try NSRegularExpression(pattern: parts[0].trimmingCharacters(in: .whitespaces))
        }
        for (lineNumber, line) in suppressionTextView.string.components(separatedBy: .newlines).enumerated() {
            let pattern = line.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty, !pattern.hasPrefix("#") else { continue }
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                throw NSError(
                    domain: PBGitXErrorDomain,
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Diff suppression pattern on line \(lineNumber + 1) is not a valid regular expression."]
                )
            }
        }
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

@objc(PBCommitMessageTransformer)
final class CommitMessageTransformer: NSObject {
    private let store: RepositorySettingsStore

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        store = RepositorySettingsStore(repository: repository)
        super.init()
    }

    @objc(transformMessage:error:)
    func transform(message: String) throws -> String {
        var result = message
        let configuredRules = store.string(forKey: RepositorySettingsStore.commitRulesKey)
        for (lineNumber, line) in configuredRules.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.range(of: "=>") else {
                throw CommitMessageTransformError.invalidRule(line: lineNumber + 1)
            }
            let pattern = trimmed[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let replacement = trimmed[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            do {
                let expression = try NSRegularExpression(pattern: pattern)
                let range = NSRange(result.startIndex..., in: result)
                result = expression.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: replacement
                )
            } catch {
                throw CommitMessageTransformError.invalidRegularExpression(
                    line: lineNumber + 1,
                    underlying: error
                )
            }
        }
        return result
    }
}

/// Objective-C callers are not visible to SwiftLint's analyzer.
@objc(PBBranchSidebarPresentation)
final class BranchSidebarPresentation: NSObject { // swiftlint:disable:this unused_declaration
    private let repository: PBGitRepository
    private var commitDates: [String: TimeInterval] = [:]
    private var containedBranches: Set<String> = []

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        super.init()
    }

    @objc var usesRecentSorting: Bool {
        ApplicationSettings.branchSort == .recentCommit
    }

    @objc func toggleSorting() {
        ApplicationSettings.branchSort = usesRecentSorting ? .alphabetical : .recentCommit
    }

    @objc func reload() {
        commitDates = branchCommitDates()
        containedBranches = mergedBranches()
    }

    @objc(shouldShowRevision:)
    // swiftlint:disable:next unused_declaration
    func shouldShow(revision: PBGitRevSpecifier) -> Bool {
        guard let ref = revision.ref(), ref.isBranch else { return true }
        let settings = RepositoryUISettings(repository: repository)
        guard settings.hideContainedBranches else { return true }
        let primary = RepositorySettingsStore(repository: repository).detectedPrimaryBranch()
        let current = repository.headRef()?.ref()?.shortName()
        let name = ref.shortName()
        return name == primary || name == current || !containedBranches.contains(name)
    }

    @objc(sortedBranchItems:)
    // swiftlint:disable:next unused_declaration
    func sortedBranchItems(_ items: [PBSourceViewItem]) -> [PBSourceViewItem] {
        guard usesRecentSorting else { return items }
        return items.sorted { lhs, rhs in
            let left = commitDates[lhs.ref()?.ref ?? ""] ?? 0
            let right = commitDates[rhs.ref()?.ref ?? ""] ?? 0
            if left != right {
                return left > right
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private func branchCommitDates() -> [String: TimeInterval] {
        guard let output = try? repository.outputOfTask(withArguments: [
            "for-each-ref", "--format=%(refname)%00%(committerdate:unix)", "refs/heads",
        ]) else { return [:] }
        var result: [String: TimeInterval] = [:]
        for line in output.components(separatedBy: .newlines) {
            let fields = line.components(separatedBy: "\0")
            guard fields.count == 2, let timestamp = TimeInterval(fields[1]) else { continue }
            result[fields[0]] = timestamp
        }
        return result
    }

    private func mergedBranches() -> Set<String> {
        let settings = RepositoryUISettings(repository: repository)
        guard settings.hideContainedBranches else { return [] }
        let primary = RepositorySettingsStore(repository: repository).detectedPrimaryBranch()
        guard let output = try? repository.outputOfTask(withArguments: [
            "branch", "--merged", primary, "--format=%(refname:short)",
        ]) else { return [] }
        return Set(output.components(separatedBy: .newlines).filter { !$0.isEmpty })
    }
}

private enum CommitMessageTransformError: LocalizedError {
    case invalidRule(line: Int)
    case invalidRegularExpression(line: Int, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .invalidRule(line):
            "Commit message replacement rule \(line) does not contain =>."
        case let .invalidRegularExpression(line, underlying):
            "Commit message replacement rule \(line) is invalid: \(underlying.localizedDescription)"
        }
    }
}

@objc(PBRepositoryRemoteURLCoordinator)
final class RepositoryRemoteURLCoordinator: NSObject {
    @objc static let shared = RepositoryRemoteURLCoordinator()
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryRemoteURL")

    @objc(handleSuccessfulPushOutput:repository:remote:presentingWindow:)
    func handleSuccessfulPush(
        output: String,
        repository: PBGitRepository,
        remote: PBGitRef?,
        presenting window: NSWindow?
    ) {
        let settings = RepositorySettingsStore(repository: repository)
        guard settings.bool(forKey: RepositorySettingsStore.autoOpenURLKey, defaultValue: false),
              let url = firstHTTPURL(in: output) else { return }
        if settings.bool(forKey: RepositorySettingsStore.requireHostMatchKey, defaultValue: true) {
            guard let expectedHost = gitHost(
                remoteURL(for: remoteName(for: remote, repository: repository), repository: repository)
            ), expectedHost.caseInsensitiveCompare(url.host ?? "") == .orderedSame else {
                logger.info("Ignored pushed URL because its host did not match the Git remote")
                return
            }
        }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
            self.logger.info("Opened URL returned by successful push")
        }
    }

    /// Objective-C callers are not visible to SwiftLint's analyzer.
    @objc(viewRemoteForRepository:presentingWindow:)
    // swiftlint:disable:next unused_declaration
    func viewRemote(repository: PBGitRepository, presenting window: NSWindow?) {
        guard let remoteName = chooseRemoteName(repository: repository, presenting: window),
              let remoteURL = remoteURL(for: remoteName, repository: repository),
              let baseURL = webBaseURL(for: remoteURL)
        else {
            present(
                title: "No Web Remote Available",
                message: "Configure a Git remote or a custom web URL template in Repository Settings.",
                window: window
            )
            return
        }

        let head = repository.headRef()?.ref()
        let branch = head?.isBranch == true ? head?.shortName() ?? "" : ""
        let sha = (try? repository.outputOfTask(withArguments: ["rev-parse", "HEAD"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let settings = RepositorySettingsStore(repository: repository)
        let template = settings.string(forKey: RepositorySettingsStore.webURLTemplateKey)
        let url: URL?
        if !template.isEmpty {
            let expanded = template
                .replacingOccurrences(of: "{remoteURL}", with: baseURL.absoluteString)
                .replacingOccurrences(of: "{branch}", with: urlComponent(branch))
                .replacingOccurrences(of: "{sha}", with: urlComponent(sha))
            url = URL(string: expanded)
        } else {
            url = providerURL(baseURL: baseURL, branch: branch, sha: sha)
        }
        guard let url else {
            present(
                title: "Remote URL Is Invalid",
                message: "Check the remote and custom template in Repository Settings.",
                window: window
            )
            return
        }
        NSWorkspace.shared.open(url)
        logger.info("Opened repository remote in browser")
    }

    @objc(firstHTTPURLInOutput:)
    func firstHTTPURL(in output: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(output.startIndex..., in: output)
        var result: URL?
        detector.enumerateMatches(in: output, range: range) { match, _, stop in
            guard let candidate = match?.url,
                  candidate.scheme == "http" || candidate.scheme == "https" else { return }
            result = candidate
            stop.pointee = true
        }
        return result
    }

    @objc(webURLForRemoteURL:branch:sha:)
    // swiftlint:disable:next unused_declaration
    func webURL(remoteURL: String, branch: String, sha: String) -> URL? {
        guard let baseURL = webBaseURL(for: remoteURL) else { return nil }
        return providerURL(baseURL: baseURL, branch: branch, sha: sha)
    }

    private func remoteName(for remote: PBGitRef?, repository: PBGitRepository) -> String? {
        if let name = remote?.remoteName, !name.isEmpty {
            return name
        }
        guard let head = repository.headRef()?.ref(), head.isBranch,
              let tracking = try? repository.remoteRef(forBranch: head) else { return nil }
        return tracking.remoteName
    }

    private func chooseRemoteName(repository: PBGitRepository, presenting window: NSWindow?) -> String? {
        if let name = remoteName(for: nil, repository: repository) {
            return name
        }
        let remotes = repository.remotes() ?? []
        if remotes.count == 1 {
            return remotes[0]
        }
        guard !remotes.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = "Choose a Remote"
        alert.informativeText = "The current commit has no upstream remote."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        popup.addItems(withTitles: remotes)
        alert.accessoryView = popup
        alert.addButton(withTitle: "View Remote")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? popup.titleOfSelectedItem : nil
    }

    private func remoteURL(for remoteName: String?, repository: PBGitRepository) -> String? {
        guard let remoteName, !remoteName.isEmpty else { return nil }
        let output = try? repository.outputOfTask(withArguments: ["remote", "get-url", remoteName])
        let value = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func webBaseURL(for remoteURL: String) -> URL? {
        var candidate = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("git@"), let colon = candidate.firstIndex(of: ":") {
            let hostStart = candidate.index(candidate.startIndex, offsetBy: 4)
            candidate = "https://" + candidate[hostStart ..< colon] + "/" + candidate[candidate.index(after: colon)...]
        } else if candidate.hasPrefix("ssh://") {
            guard var components = URLComponents(string: candidate) else { return nil }
            components.scheme = "https"
            components.user = nil
            components.port = nil
            candidate = components.string ?? candidate
        } else if candidate.hasPrefix("git://") {
            candidate = "https://" + candidate.dropFirst(6)
        }
        if candidate.hasSuffix(".git") {
            candidate.removeLast(4)
        }
        return URL(string: candidate)
    }

    private func providerURL(baseURL: URL, branch: String, sha: String) -> URL? {
        let revision = branch.isEmpty ? sha : branch
        guard !revision.isEmpty else { return baseURL }
        let suffix: String
        switch baseURL.host?.lowercased() ?? "" {
        case let host where host.contains("gitlab"):
            suffix = "/-/tree/\(urlComponent(revision))"
        case let host where host.contains("bitbucket"):
            suffix = "/src/\(urlComponent(revision))"
        default:
            suffix = "/tree/\(urlComponent(revision))"
        }
        return URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + suffix)
    }

    private func gitHost(_ remoteURL: String?) -> String? {
        guard let remoteURL else { return nil }
        if remoteURL.hasPrefix("git@"), let colon = remoteURL.firstIndex(of: ":") {
            return String(remoteURL[remoteURL.index(remoteURL.startIndex, offsetBy: 4) ..< colon])
        }
        return webBaseURL(for: remoteURL)?.host
    }

    private func urlComponent(_ string: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private func present(title: String, message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension Notification.Name {
    static let repositorySettingsDidChange = Notification.Name("PBRepositorySettingsDidChangeNotification")
}
