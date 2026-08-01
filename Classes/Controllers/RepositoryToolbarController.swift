import AppKit
import ForgeKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

enum RepositoryForgeLinkRevision: Equatable {
    case branch(String)
    case commit(String)
}

struct RepositoryForgeLinkContext: Equatable {
    let providerName: String?
    let isForgeAvailable: Bool
    let checkedOutRevision: RepositoryForgeLinkRevision?
    let selectedCommitIdentifiers: [String]
}

enum RepositoryForgeLinkAction: String, CaseIterable {
    case repository = "viewForgeRepository:"
    case checkedOutRevision = "viewForgeCheckedOutRevision:"
    case selectedCommit = "viewForgeSelectedCommit:"
    case compareSelectedCommits = "viewForgeSelectedComparison:"
    case numberedItem = "showForgePullRequestOrIssue:"

    init?(selector: Selector?) {
        guard let selector else { return nil }
        self.init(rawValue: NSStringFromSelector(selector))
    }

    var selector: Selector {
        NSSelectorFromString(rawValue)
    }

    var accessibilityIdentifier: String {
        switch self {
        case .repository: "GitX.Repository.ForgeLinks.Repository"
        case .checkedOutRevision: "GitX.Repository.ForgeLinks.CheckedOutRevision"
        case .selectedCommit: "GitX.Repository.ForgeLinks.SelectedCommit"
        case .compareSelectedCommits: "GitX.Repository.ForgeLinks.CompareSelectedCommits"
        case .numberedItem: "GitX.Repository.ForgeLinks.PullRequestOrIssue"
        }
    }
}

struct RepositoryForgeLinkMenuItemModel: Equatable {
    let action: RepositoryForgeLinkAction
    let title: String
    let accessibilityLabel: String
    let isEnabled: Bool
    let isHidden: Bool
}

/// Supplies one contextual link model to both the toolbar pull-down and Repository menu.
@objc(PBRepositoryForgeLinkMenuPresenter)
final class RepositoryForgeLinkMenuPresenter: NSObject {
    static func itemModels(context: RepositoryForgeLinkContext) -> [RepositoryForgeLinkMenuItemModel] {
        RepositoryForgeLinkAction.allCases.compactMap { itemModel(action: $0, context: context) }
    }

    static func itemModel(
        action: RepositoryForgeLinkAction,
        context: RepositoryForgeLinkContext
    ) -> RepositoryForgeLinkMenuItemModel? {
        let provider = context.providerName
        let providerSuffix = provider.map { " on \($0)" } ?? ""
        let enabled = context.isForgeAvailable
        switch action {
        case .repository:
            return RepositoryForgeLinkMenuItemModel(
                action: action,
                title: "View Repository\(providerSuffix)",
                accessibilityLabel: "View repository\(providerSuffix)",
                isEnabled: enabled,
                isHidden: false
            )
        case .checkedOutRevision:
            let title: String
            switch context.checkedOutRevision {
            case let .branch(name):
                title = "View Checked-Out Branch “\(name)”\(providerSuffix)"
            case .commit:
                title = "View Checked-Out Commit\(providerSuffix)"
            case nil:
                title = "View Checked-Out Revision\(providerSuffix)"
            }
            return RepositoryForgeLinkMenuItemModel(
                action: action,
                title: title,
                accessibilityLabel: title,
                isEnabled: enabled && context.checkedOutRevision != nil,
                isHidden: context.checkedOutRevision == nil
            )
        case .selectedCommit:
            let applicable = context.selectedCommitIdentifiers.count == 1
            return RepositoryForgeLinkMenuItemModel(
                action: action,
                title: "View Selected Commit\(providerSuffix)",
                accessibilityLabel: "View selected commit\(providerSuffix)",
                isEnabled: enabled && applicable,
                isHidden: !applicable
            )
        case .compareSelectedCommits:
            let applicable = context.selectedCommitIdentifiers.count == 2
            return RepositoryForgeLinkMenuItemModel(
                action: action,
                title: "Compare Selected Commits\(providerSuffix)",
                accessibilityLabel: "Compare selected commits\(providerSuffix)",
                isEnabled: enabled && applicable,
                isHidden: !applicable
            )
        case .numberedItem:
            return RepositoryForgeLinkMenuItemModel(
                action: action,
                title: "Pull Request or Issue…",
                accessibilityLabel: "Open pull request or issue\(providerSuffix)",
                isEnabled: enabled,
                isHidden: false
            )
        }
    }

    static func menuItems(context: RepositoryForgeLinkContext) -> [NSMenuItem] {
        let models = itemModels(context: context).filter { !$0.isHidden }
        var items: [NSMenuItem] = []
        for model in models {
            if model.action == .numberedItem, !items.isEmpty {
                items.append(.separator())
            }
            let item = NSMenuItem(title: model.title, action: model.action.selector, keyEquivalent: "")
            apply(model: model, to: item)
            item.target = nil
            items.append(item)
        }
        return items
    }

    static func apply(model: RepositoryForgeLinkMenuItemModel, to item: NSMenuItem) {
        item.title = model.title
        item.isEnabled = model.isEnabled
        item.isHidden = model.isHidden
        item.identifier = NSUserInterfaceItemIdentifier(model.action.accessibilityIdentifier)
        item.setAccessibilityIdentifier(model.action.accessibilityIdentifier)
        item.setAccessibilityLabel(model.accessibilityLabel)
    }

    /// Objective-C-visible decision seam for app-hosted tests.
    @objc(menuItemsForProviderName:forgeAvailable:currentBranchName:checkedOutCommitIdentifier:selectedCommitIdentifiers:)
    // swiftlint:disable:next unused_declaration
    static func menuItems(
        providerName: String?,
        forgeAvailable: Bool,
        currentBranchName: String?,
        checkedOutCommitIdentifier: String?,
        selectedCommitIdentifiers: [String]
    ) -> [NSMenuItem] {
        let checkedOutRevision: RepositoryForgeLinkRevision?
        if let currentBranchName {
            checkedOutRevision = .branch(currentBranchName)
        } else if let checkedOutCommitIdentifier {
            checkedOutRevision = .commit(checkedOutCommitIdentifier)
        } else {
            checkedOutRevision = nil
        }
        return menuItems(context: RepositoryForgeLinkContext(
            providerName: providerName,
            isForgeAvailable: forgeAvailable,
            checkedOutRevision: checkedOutRevision,
            selectedCommitIdentifiers: selectedCommitIdentifiers
        ))
    }
}

/// Objective-C callers are not visible to SwiftLint's analyzer.
@objc(PBRepositoryToolbarController)
final class RepositoryToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    private static let toolbarIdentifier = NSToolbar.Identifier("GitX.Repository.HistoryToolbar")

    private enum Item {
        static let commit = NSToolbarItem.Identifier("GitX.Toolbar.Commit")
        static let fetch = NSToolbarItem.Identifier("GitX.Toolbar.Fetch")
        static let pull = NSToolbarItem.Identifier("GitX.Toolbar.Pull")
        static let push = NSToolbarItem.Identifier("GitX.Toolbar.Push")
        static let newPullRequest = NSToolbarItem.Identifier("GitX.Toolbar.NewPullRequest")
        static let refreshStatus = NSToolbarItem.Identifier("GitX.Toolbar.RefreshStatus")
        static let viewRemote = NSToolbarItem.Identifier("GitX.Toolbar.ViewRemote")
        static let reveal = NSToolbarItem.Identifier("GitX.Toolbar.Reveal")
        static let terminal = NSToolbarItem.Identifier("GitX.Toolbar.Terminal")
        static let repositorySettings = NSToolbarItem.Identifier("GitX.Toolbar.RepositorySettings")
        static let addRemote = NSToolbarItem.Identifier("GitX.Toolbar.AddRemote")
        static let createBranch = NSToolbarItem.Identifier("GitX.Toolbar.CreateBranch")
        static let createTag = NSToolbarItem.Identifier("GitX.Toolbar.CreateTag")
        static let jump = NSToolbarItem.Identifier("GitX.Toolbar.Jump")
        static let actions = NSToolbarItem.Identifier("GitX.Toolbar.Actions")
        static let attention = NSToolbarItem.Identifier("GitX.Toolbar.Attention")
        static let forgeAccount = NSToolbarItem.Identifier("GitX.Toolbar.ForgeAccount")
    }

    private struct StatusViews {
        let label: NSTextField
        let spinner: NSProgressIndicator
    }

    private final class ForgeAccountViews {
        let item: NSToolbarItem
        let accountPopup: NSPopUpButton
        let avatarContainer: NSView
        let warningButton: NSButton

        init(
            item: NSToolbarItem,
            accountPopup: NSPopUpButton,
            avatarContainer: NSView,
            warningButton: NSButton
        ) {
            self.item = item
            self.accountPopup = accountPopup
            self.avatarContainer = avatarContainer
            self.warningButton = warningButton
        }
    }

    private weak var windowController: PBGitWindowController?
    private var toolbar: NSToolbar?
    private var statusViews: StatusViews?
    private var forgeAccountViews: ForgeAccountViews?
    private var attentionItem: NSToolbarItem?
    private var attentionBadge: NSTextField?
    private var newPullRequestItem: NSToolbarItem?
    private var createPullRequestControl: ForgeMutationControlPresentation
    private var unseenAttentionCount = 0
    private var currentStatus = ""
    private var currentBusy = false
    private var forgePersistentFailureText: String?
    private var isRepositoryStatusBarVisible = true
    private var forgeProviderName: String
    private var forgeAccountLogin: String?
    private var forgeAccountID: ForgeAccountID?
    private var forgeAccountChoices: [RepositoryForgeAccountChoice] = []
    private var isPublicForgeAccess = false
    private var isForgeAccountRebindingEnabled = true
    private var forgeAccountRebindingCooldownDeadline: Date?
    private var forgeAccountSelectionTask: Task<Void, Never>?
    private var insertedForgeAccountForPersistentFailure = false
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryToolbar")

    @objc(initWithWindowController:)
    init(windowController: PBGitWindowController) {
        self.windowController = windowController
        createPullRequestControl = windowController.createPullRequestControl
        forgeProviderName = windowController.forgeLinkContext.providerName ?? "Forge"
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(attentionUnseenDidChange(_:)),
            name: .repositoryAttentionUnseenDidChange,
            object: windowController.repository
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositoryForgeAccountDidChange(_:)),
            name: .repositoryForgeAccountDidChange,
            object: windowController.repository
        )
    }

    deinit {
        forgeAccountSelectionTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc func install() {
        installToolbar()
    }

    @objc(updateWithStatus:busy:baseWindowTitle:)
    // swiftlint:disable:next unused_declaration
    func update(status: String, busy: Bool, baseWindowTitle: String) {
        currentStatus = status
        currentBusy = busy
        applyCurrentStatus()
        if let window = windowController?.window {
            window.title = status.isEmpty ? baseWindowTitle : "\(baseWindowTitle) — \(status)"
        }
    }

    @objc(updateWithForgePersistentFailureText:statusBarVisible:)
    func updateForgeDiagnostic(persistentFailureText: String?, statusBarVisible: Bool) {
        forgePersistentFailureText = persistentFailureText
        isRepositoryStatusBarVisible = statusBarVisible
        applyForgeAccountPresentation()
        reconcilePersistentFailureAccountItem()
    }

    func updateCreatePullRequestControl(_ presentation: ForgeMutationControlPresentation) {
        createPullRequestControl = presentation
        if let newPullRequestItem {
            applyCreatePullRequestControl(to: newPullRequestItem)
        }
    }

    private func installToolbar() {
        guard let window = windowController?.window else { return }
        let start = ProcessInfo.processInfo.systemUptime
        let reused = toolbar != nil
        let installed = toolbar ?? makeToolbar()
        toolbar = installed
        window.toolbar = installed
        window.toolbarStyle = .expanded
        reconcilePersistentFailureAccountItem()
        applyCurrentStatus()
        applyForgeAccountPresentation()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        logger.info(
            "Installed repository toolbar, cached: \(reused, privacy: .public), elapsed: \(elapsed, format: .fixed(precision: 4))s"
        )
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconAndLabel
        toolbar.sizeMode = .regular
        return toolbar
    }

    private func applyCurrentStatus() {
        guard let views = statusViews else { return }
        views.label.stringValue = currentStatus.isEmpty ? "Ready" : currentStatus
        if currentBusy {
            views.spinner.startAnimation(nil)
            views.spinner.isHidden = false
        } else {
            views.spinner.stopAnimation(nil)
            views.spinner.isHidden = true
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Item.commit,
            .flexibleSpace,
            Item.actions,
            Item.forgeAccount,
            Item.attention,
            Item.addRemote,
            Item.fetch,
            Item.pull,
            Item.push,
            Item.newPullRequest,
            .flexibleSpace,
            Item.jump,
            Item.viewRemote,
            Item.reveal,
            Item.terminal,
            Item.refreshStatus,
            Item.repositorySettings,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Item.commit,
            Item.fetch,
            Item.pull,
            Item.push,
            Item.newPullRequest,
            Item.refreshStatus,
            Item.viewRemote,
            Item.reveal,
            Item.terminal,
            Item.repositorySettings,
            Item.addRemote,
            Item.createBranch,
            Item.createTag,
            Item.jump,
            Item.actions,
            Item.attention,
            Item.forgeAccount,
            .space,
            .flexibleSpace,
        ]
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem,
              item.itemIdentifier == Item.forgeAccount
        else { return }
        forgeAccountViews = nil
        guard forgeAccountPresentation.showsPersistentFailure else { return }
        DispatchQueue.main.async { [weak self] in
            self?.reconcilePersistentFailureAccountItem()
        }
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == Item.refreshStatus {
            return statusItem(identifier: itemIdentifier, isActualInsertion: flag)
        }
        if itemIdentifier == Item.actions {
            return actionsItem(identifier: itemIdentifier)
        }
        if itemIdentifier == Item.viewRemote {
            return viewRemoteItem(identifier: itemIdentifier)
        }
        if itemIdentifier == Item.attention {
            return makeAttentionItem(identifier: itemIdentifier, isActualInsertion: flag)
        }
        if itemIdentifier == Item.forgeAccount {
            return makeForgeAccountItem(identifier: itemIdentifier, isActualInsertion: flag)
        }
        let descriptor = descriptor(for: itemIdentifier)
        guard let descriptor else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = descriptor.label
        item.paletteLabel = descriptor.label
        item.toolTip = descriptor.toolTip
        item.image = ToolbarIconFactory.image(
            symbol: descriptor.symbol,
            topColor: descriptor.topColor,
            bottomColor: descriptor.bottomColor
        )
        item.target = windowController
        item.action = descriptor.action
        if itemIdentifier == Item.newPullRequest {
            item.autovalidates = false
            applyCreatePullRequestControl(to: item)
            if flag {
                newPullRequestItem = item
            }
        }
        return item
    }

    private func applyCreatePullRequestControl(to item: NSToolbarItem) {
        let defaultHelp = "Create a Pull Request for the checked-out branch"
        item.isEnabled = createPullRequestControl.isVisible && createPullRequestControl.isEnabled
        item.toolTip = createPullRequestControl.helpText ?? defaultHelp
    }

    private func viewRemoteItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = "View Remote"
        item.paletteLabel = "View Remote"
        item.toolTip = "Open this repository or a contextual revision on its Git host"
        item.image = ToolbarIconFactory.image(
            symbol: "safari",
            topColor: NSColor(calibratedRed: 0.43, green: 0.72, blue: 0.96, alpha: 1),
            bottomColor: NSColor(calibratedRed: 0.12, green: 0.36, blue: 0.70, alpha: 1)
        )
        item.target = windowController
        item.action = NSSelectorFromString("viewRemote:")

        let menu = NSMenu(title: "View Remote")
        menu.identifier = NSUserInterfaceItemIdentifier("GitX.Toolbar.ViewRemote.Menu")
        menu.delegate = self
        item.menu = menu
        updateForgeLinkMenu(menu)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateForgeLinkMenu(menu)
    }

    private func updateForgeLinkMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let context = windowController?.forgeLinkContext ?? RepositoryForgeLinkContext(
            providerName: nil,
            isForgeAvailable: false,
            checkedOutRevision: nil,
            selectedCommitIdentifiers: []
        )
        for item in RepositoryForgeLinkMenuPresenter.menuItems(context: context) {
            menu.addItem(item)
        }
        logger.debug(
            "Updated Forge link menu provider=\(context.providerName ?? "unresolved", privacy: .public) itemCount=\(menu.items.count, privacy: .public)"
        )
    }

    private func actionsItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = "Actions"
        item.paletteLabel = "Selected Reference Actions"
        item.toolTip = "Actions for the selected branch, tag, remote, or submodule"
        item.image = ToolbarIconFactory.image(
            symbol: "ellipsis.circle",
            topColor: NSColor(calibratedWhite: 0.82, alpha: 1),
            bottomColor: NSColor(calibratedWhite: 0.43, alpha: 1)
        )
        let menu = NSMenu(title: "Selected Reference Actions")
        menu.delegate = windowController?.sidebarViewController
        item.menu = menu
        return item
    }

    private func makeAttentionItem(
        identifier: NSToolbarItem.Identifier,
        isActualInsertion: Bool
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let presentation = RepositoryAttentionUnseenPresenter.present(count: unseenAttentionCount)
        item.label = presentation.toolbarLabel
        item.paletteLabel = "Attention Inbox"
        item.toolTip = presentation.toolbarToolTip

        let button = NSButton(
            image: ToolbarIconFactory.image(
                symbol: "bell",
                topColor: NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.26, alpha: 1),
                bottomColor: NSColor(calibratedRed: 0.72, green: 0.32, blue: 0.06, alpha: 1)
            ),
            target: windowController?.sidebarViewController,
            action: NSSelectorFromString("showForgeAttention:")
        )
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier("GitX.Toolbar.Attention")
        button.setAccessibilityLabel(presentation.toolbarAccessibilityLabel)

        let badge = NSTextField(labelWithString: presentation.badgeText ?? "")
        badge.alignment = .center
        badge.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = .systemRed
        badge.drawsBackground = true
        badge.isBezeled = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = presentation.badgeText == nil
        badge.setAccessibilityIdentifier("GitX.Toolbar.Attention.Badge")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 38, height: 30))
        container.addSubview(button)
        container.addSubview(badge)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30),
            badge.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            badge.topAnchor.constraint(equalTo: container.topAnchor),
            badge.heightAnchor.constraint(equalToConstant: 14),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
        ])
        item.view = container
        if isActualInsertion {
            attentionItem = item
            attentionBadge = badge
        }
        return item
    }

    @objc private func attentionUnseenDidChange(_ notification: Notification) {
        guard let repository = windowController?.repository,
              let sourceRepository = notification.object as? PBGitRepository,
              sourceRepository === repository
        else { return }
        unseenAttentionCount = max(
            0,
            notification.userInfo?[RepositoryAttentionNotificationKey.count] as? Int ?? 0
        )
        let presentation = RepositoryAttentionUnseenPresenter.present(count: unseenAttentionCount)
        attentionItem?.label = presentation.toolbarLabel
        attentionItem?.toolTip = presentation.toolbarToolTip
        attentionBadge?.stringValue = presentation.badgeText ?? ""
        attentionBadge?.isHidden = presentation.badgeText == nil
        (attentionItem?.view?.subviews.compactMap { $0 as? NSButton }.first)?
            .setAccessibilityLabel(presentation.toolbarAccessibilityLabel)
    }

    @objc private func repositoryForgeAccountDidChange(_ notification: Notification) {
        guard let repository = windowController?.repository,
              let sourceRepository = notification.object as? PBGitRepository,
              sourceRepository === repository
        else { return }
        forgeProviderName = notification.userInfo?[RepositoryForgeAccountNotificationKey.providerName] as? String
            ?? windowController?.forgeLinkContext.providerName
            ?? "Forge"
        forgeAccountLogin = notification.userInfo?[RepositoryForgeAccountNotificationKey.login] as? String
        forgeAccountID = notification.userInfo?[RepositoryForgeAccountNotificationKey.accountID] as? ForgeAccountID
        forgeAccountChoices = RepositoryForgeAccountChoice.notificationChoices(
            from: notification.userInfo?[RepositoryForgeAccountNotificationKey.accounts]
        )
        isPublicForgeAccess = notification.userInfo?[RepositoryForgeAccountNotificationKey.isPublic] as? Bool
            ?? false
        isForgeAccountRebindingEnabled = notification
            .userInfo?[RepositoryForgeAccountNotificationKey.accountRebindingEnabled] as? Bool ?? true
        forgeAccountRebindingCooldownDeadline = notification
            .userInfo?[RepositoryForgeAccountNotificationKey.accountRebindingCooldownDeadline] as? Date
        applyForgeAccountPresentation()
        let providerName = forgeProviderName
        let isAuthenticated = forgeAccountLogin != nil
        logger.info(
            "Updated contextual \(providerName, privacy: .public) toolbar account, authenticated=\(isAuthenticated, privacy: .public)"
        )
    }

    private var forgeAccountPresentation: RepositoryForgeAccountControlPresentation {
        RepositoryForgeAccountControlPresentation(
            providerName: forgeProviderName,
            login: forgeAccountLogin,
            isPublic: isPublicForgeAccess,
            persistentFailureText: forgePersistentFailureText,
            isStatusBarVisible: isRepositoryStatusBarVisible
        )
    }

    private func makeForgeAccountItem(
        identifier: NSToolbarItem.Identifier,
        isActualInsertion: Bool
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Forge Account"
        item.paletteLabel = "Forge Account"

        let avatarContainer = NSView()
        avatarContainer.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.setAccessibilityIdentifier("GitX.Toolbar.ForgeAccountAvatarContainer")
        avatarContainer.widthAnchor.constraint(equalToConstant: 24).isActive = true
        avatarContainer.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let accountPopup = NSPopUpButton(frame: .zero, pullsDown: true)
        accountPopup.bezelStyle = .texturedRounded
        accountPopup.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        accountPopup.setAccessibilityIdentifier("GitX.Toolbar.ForgeAccount")
        accountPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
        accountPopup.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let warningButton = NSButton()
        warningButton.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Forge Unavailable"
        )
        warningButton.contentTintColor = .systemOrange
        warningButton.bezelStyle = .inline
        warningButton.isBordered = false
        warningButton.imagePosition = .imageOnly
        warningButton.target = windowController
        warningButton.action = NSSelectorFromString("showForgeStatusDetails:")
        warningButton.setAccessibilityIdentifier("GitX.Toolbar.ForgeWarning")
        warningButton.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let stack = NSStackView(views: [avatarContainer, accountPopup, warningButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        item.view = stack
        let views = ForgeAccountViews(
            item: item,
            accountPopup: accountPopup,
            avatarContainer: avatarContainer,
            warningButton: warningButton
        )
        if isActualInsertion {
            forgeAccountViews = views
        }
        applyForgeAccountPresentation(to: views)
        return item
    }

    private func applyForgeAccountPresentation() {
        guard let forgeAccountViews else { return }
        applyForgeAccountPresentation(to: forgeAccountViews)
    }

    private func applyForgeAccountPresentation(to views: ForgeAccountViews) {
        let presentation = forgeAccountPresentation
        views.item.toolTip = presentation.toolTip
        configureForgeAccountMenu(views.accountPopup, presentation: presentation)
        configureForgeAccountAvatar(in: views.avatarContainer, presentation: presentation)
        let rebinding = RepositoryForgeAccountRebindingPresentation.present(
            isEnabled: isForgeAccountRebindingEnabled,
            cooldownDeadline: forgeAccountRebindingCooldownDeadline,
            now: Date()
        )
        views.accountPopup.isEnabled = rebinding.isEnabled
        views.accountPopup.toolTip = rebinding.isEnabled ? presentation.toolTip : rebinding.helpText
        views.accountPopup.setAccessibilityLabel(presentation.accessibilityLabel)
        views.accountPopup.setAccessibilityHelp(rebinding.helpText)
        views.warningButton.isHidden = !presentation.showsPersistentFailure
        views.warningButton.isEnabled = presentation.showsPersistentFailure
        views.warningButton.toolTip = presentation.persistentFailureText.map { "\($0). Show Details" }
        views.warningButton.setAccessibilityLabel(
            presentation.persistentFailureText.map { "\($0). Show details" } ?? "Forge status details"
        )
    }

    private func configureForgeAccountMenu(
        _ popup: NSPopUpButton,
        presentation: RepositoryForgeAccountControlPresentation
    ) {
        popup.removeAllItems()
        popup.addItem(withTitle: presentation.title)
        popup.item(at: 0)?.isEnabled = false
        popup.item(at: 0)?.identifier = NSUserInterfaceItemIdentifier("GitX.Toolbar.ForgeAccount.Current")
        popup.item(at: 0)?.setAccessibilityIdentifier("GitX.Toolbar.ForgeAccount.Current")

        for choice in forgeAccountChoices {
            let item = NSMenuItem(
                title: "@\(choice.login)",
                action: #selector(selectForgeAccount(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = choice.id
            item.state = choice.id == forgeAccountID ? .on : .off
            item.isEnabled = isForgeAccountRebindingEnabled
            let identifier = "GitX.Toolbar.ForgeAccount.Choice.\(choice.id.value)"
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.setAccessibilityIdentifier(identifier)
            item.setAccessibilityLabel("Use GitHub account \(choice.login) for this repository")
            popup.menu?.addItem(item)
        }

        if !forgeAccountChoices.isEmpty {
            popup.menu?.addItem(.separator())
        }
        let manage = NSMenuItem(
            title: "Manage Accounts…",
            action: #selector(openForgeAccountsPreferences(_:)),
            keyEquivalent: ""
        )
        manage.target = self
        manage.identifier = NSUserInterfaceItemIdentifier("GitX.Toolbar.ForgeAccount.Manage")
        manage.setAccessibilityIdentifier("GitX.Toolbar.ForgeAccount.Manage")
        manage.setAccessibilityLabel("Manage Forge accounts")
        popup.menu?.addItem(manage)
    }

    private func configureForgeAccountAvatar(
        in container: NSView,
        presentation: RepositoryForgeAccountControlPresentation
    ) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let owner = forgeAccountID.map(ForgeAvatarCacheOwner.account) ?? .anonymous
        let avatar = ForgeAvatarView(owner: owner)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.setAccessibilityIdentifier("GitX.Toolbar.ForgeAccountAvatar")
        let displayName = forgeAccountLogin ?? (isPublicForgeAccess ? "Public" : presentation.providerName)
        let avatarURL = forgeAccountChoices.first(where: { $0.id == forgeAccountID })?.avatarURL
        avatar.configure(displayName: displayName, avatarURL: avatarURL)
        container.addSubview(avatar)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            avatar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            avatar.topAnchor.constraint(equalTo: container.topAnchor),
            avatar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @objc private func selectForgeAccount(_ sender: NSMenuItem) {
        guard let accountID = sender.representedObject as? ForgeAccountID,
              let repository = windowController?.repository,
              let binding = ApplicationComposition.shared.repositoryViewState(for: repository).forgeRepositoryBinding
        else {
            NSSound.beep()
            return
        }
        let currentAccountID = forgeAccountID
        forgeAccountSelectionTask?.cancel()
        forgeAccountSelectionTask = Task { [weak self] in
            do {
                let services = try await ApplicationComposition.shared.forgeServices.services()
                if let currentAccountID {
                    guard let envelope = try await services.accountStore.credential(for: currentAccountID)
                    else {
                        NSSound.beep()
                        return
                    }
                    let currentCredential = envelope.account.currentCredential.reference
                    let state = await services.credentialCooldowns.retainedState(
                        for: currentCredential,
                        at: Date()
                    )
                    guard !Task.isCancelled, let self else { return }
                    guard self.windowController?.repository === repository,
                          self.forgeAccountID == currentAccountID,
                          ApplicationComposition.shared.repositoryViewState(for: repository)
                          .forgeRepositoryBinding == binding,
                          self.forgeAccountChoices.contains(where: { $0.id == accountID }),
                          let currentEnvelope = try await services.accountStore.credential(for: currentAccountID),
                          currentEnvelope.account.currentCredential.reference == currentCredential
                    else {
                        NSSound.beep()
                        return
                    }
                    guard state == .none else {
                        self.isForgeAccountRebindingEnabled = false
                        self.forgeAccountRebindingCooldownDeadline = switch state {
                        case .none: nil
                        case let .waiting(until): until
                        case let .retryPending(deadline): deadline
                        }
                        self.applyForgeAccountPresentation()
                        NSSound.beep()
                        return
                    }
                }
                guard !Task.isCancelled,
                      let self,
                      self.windowController?.repository === repository,
                      ApplicationComposition.shared.repositoryViewState(for: repository)
                      .forgeRepositoryBinding == binding
                else { return }
                let updated = try RepositoryForgeAccountSelection.updating(
                    binding,
                    preferredAccount: accountID
                )
                ApplicationComposition.shared.repositoryViewState(for: repository).forgeRepositoryBinding = updated
                NotificationCenter.default.post(name: .forgeAccountsDidChange, object: repository)
                self.logger.notice("Changed the repository's contextual Forge account")
            } catch is CancellationError {
                return
            } catch {
                self?.windowController?.showErrorSheet(error)
            }
        }
    }

    #if DEBUG
        func waitForForgeAccountSelectionForProductProof() async {
            await forgeAccountSelectionTask?.value
        }
    #endif

    @objc private func openForgeAccountsPreferences(_: Any?) {
        RepositoryForgeAccountsPreferencesRouting.prepare()
        if !NSApp.sendAction(NSSelectorFromString("openPreferencesWindow:"), to: nil, from: self) {
            NSSound.beep()
        }
    }

    private func reconcilePersistentFailureAccountItem() {
        guard let toolbar else { return }
        let containsAccountItem = toolbar.items.contains { $0.itemIdentifier == Item.forgeAccount }
        let requiresAccountItem = forgeAccountPresentation.showsPersistentFailure
        if requiresAccountItem, !containsAccountItem {
            let statusIndex = toolbar.items.firstIndex { $0.itemIdentifier == Item.refreshStatus } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: Item.forgeAccount, at: statusIndex)
            insertedForgeAccountForPersistentFailure = true
            logger.notice("Restored the Forge toolbar control to mirror a persistent failure")
        } else if !requiresAccountItem, insertedForgeAccountForPersistentFailure, containsAccountItem,
                  let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Item.forgeAccount })
        {
            toolbar.removeItem(at: index)
            forgeAccountViews = nil
            insertedForgeAccountForPersistentFailure = false
        }
    }

    private func statusItem(
        identifier: NSToolbarItem.Identifier,
        isActualInsertion: Bool
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Refresh"
        item.paletteLabel = "Refresh & Status"
        item.toolTip = "Refresh the current view and show repository activity"

        let refresh = NSButton(
            image: ToolbarIconFactory.image(
                symbol: "arrow.clockwise",
                topColor: NSColor(calibratedRed: 0.30, green: 0.68, blue: 0.98, alpha: 1),
                bottomColor: NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.74, alpha: 1)
            ),
            target: windowController,
            action: #selector(PBGitWindowController.refresh(_:))
        )
        refresh.isBordered = false
        refresh.toolTip = "Refresh"
        refresh.setAccessibilityLabel("Refresh")

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true

        let label = NSTextField(labelWithString: "Ready")
        label.font = .preferredFont(forTextStyle: .caption1, options: [:])
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true

        let view = NSStackView(views: [refresh, spinner, label])
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 5
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 118).isActive = true
        view.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        item.view = view
        if isActualInsertion {
            statusViews = StatusViews(label: label, spinner: spinner)
        }
        logger.debug(
            "Created repository status item, actual insertion: \(isActualInsertion, privacy: .public)"
        )
        label.stringValue = currentStatus.isEmpty ? "Ready" : currentStatus
        if currentBusy {
            spinner.startAnimation(nil)
            spinner.isHidden = false
        }
        return item
    }

    private struct Descriptor {
        let label: String
        let toolTip: String
        let symbol: String
        let action: Selector
        let topColor: NSColor
        let bottomColor: NSColor
    }

    private func descriptor(for identifier: NSToolbarItem.Identifier) -> Descriptor? {
        let blueTop = NSColor(calibratedRed: 0.43, green: 0.72, blue: 0.96, alpha: 1)
        let blueBottom = NSColor(calibratedRed: 0.12, green: 0.36, blue: 0.70, alpha: 1)
        let greenTop = NSColor(calibratedRed: 0.49, green: 0.82, blue: 0.45, alpha: 1)
        let greenBottom = NSColor(calibratedRed: 0.16, green: 0.48, blue: 0.18, alpha: 1)
        let orangeTop = NSColor(calibratedRed: 1.00, green: 0.73, blue: 0.33, alpha: 1)
        let orangeBottom = NSColor(calibratedRed: 0.75, green: 0.34, blue: 0.08, alpha: 1)
        let grayTop = NSColor(calibratedWhite: 0.82, alpha: 1)
        let grayBottom = NSColor(calibratedWhite: 0.43, alpha: 1)

        switch identifier {
        case Item.commit:
            return Descriptor(label: "Uncommitted Changes", toolTip: "Show uncommitted changes", symbol: "checkmark.circle", action: #selector(PBGitWindowController.showUncommittedChanges(_:)), topColor: greenTop, bottomColor: greenBottom)
        case Item.fetch:
            return Descriptor(label: "Fetch", toolTip: "Fetch all remotes", symbol: "arrow.down", action: NSSelectorFromString("toolbarFetch:"), topColor: blueTop, bottomColor: blueBottom)
        case Item.pull:
            return Descriptor(label: "Pull", toolTip: "Pull the checked-out branch", symbol: "arrow.down.to.line", action: NSSelectorFromString("toolbarPull:"), topColor: greenTop, bottomColor: greenBottom)
        case Item.push:
            return Descriptor(label: "Push", toolTip: "Push the checked-out branch", symbol: "arrow.up.to.line", action: NSSelectorFromString("toolbarPush:"), topColor: orangeTop, bottomColor: orangeBottom)
        case Item.newPullRequest:
            return Descriptor(
                label: "New Pull Request",
                toolTip: "Create a Pull Request for the checked-out branch",
                symbol: "arrow.triangle.pull",
                action: NSSelectorFromString("newPullRequest:"),
                topColor: blueTop,
                bottomColor: blueBottom
            )
        case Item.reveal:
            return Descriptor(label: "Show in Finder", toolTip: "Reveal the repository in Finder", symbol: "folder", action: #selector(PBGitWindowController.revealInFinder(_:)), topColor: blueTop, bottomColor: blueBottom)
        case Item.terminal:
            return Descriptor(label: "Terminal", toolTip: "Open the repository in the configured terminal", symbol: "terminal", action: #selector(PBGitWindowController.openInTerminal(_:)), topColor: grayTop, bottomColor: grayBottom)
        case Item.repositorySettings:
            return Descriptor(label: "Repo Settings", toolTip: "Open settings for this repository", symbol: "gearshape", action: #selector(PBGitWindowController.showRepositorySettings(_:)), topColor: grayTop, bottomColor: grayBottom)
        case Item.addRemote:
            return Descriptor(label: "Add Remote", toolTip: "Add a repository remote", symbol: "network.badge.shield.half.filled", action: #selector(PBGitWindowController.addRemote(_:)), topColor: blueTop, bottomColor: blueBottom)
        case Item.createBranch:
            return Descriptor(label: "New Branch", toolTip: "Create a branch", symbol: "arrow.triangle.branch", action: #selector(PBGitWindowController.createBranch(_:)), topColor: greenTop, bottomColor: greenBottom)
        case Item.createTag:
            return Descriptor(label: "New Tag", toolTip: "Create a tag", symbol: "tag", action: #selector(PBGitWindowController.createTag(_:)), topColor: orangeTop, bottomColor: orangeBottom)
        case Item.jump:
            return Descriptor(label: "Current Branch", toolTip: "Jump to the checked-out branch", symbol: "scope", action: #selector(PBGitWindowController.jumpToCheckedOutBranch(_:)), topColor: blueTop, bottomColor: blueBottom)
        default:
            return nil
        }
    }
}

private enum ToolbarIconFactory {
    static func image(symbol: String, topColor: NSColor, bottomColor: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 28), flipped: false) { rect in
            let background = rect.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6)
            NSGradient(starting: topColor, ending: bottomColor)?.draw(in: path, angle: -90)
            NSColor(calibratedWhite: 0.15, alpha: 0.45).setStroke()
            path.lineWidth = 0.7
            path.stroke()
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
            {
                let glyphRect = NSRect(x: 7, y: 7, width: 14, height: 14)
                NSColor.white.set()
                glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 0.95)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
