import AppKit
import ForgeKit
import Foundation
import GitHubForgeAdapter
import OSLog // swiftlint:disable:this unused_import

nonisolated enum ForgeAccountsError: Error, Equatable, LocalizedError, Sendable {
    case githubApplicationNotConfigured
    case deviceFlowNotStarted
    case deviceFlowExpired
    case deviceFlowDenied
    case deviceFlowFailed
    case invalidPersonalAccessToken

    var errorDescription: String? {
        switch self {
        case .githubApplicationNotConfigured:
            "This build does not have a GitHub App client identifier and application slug."
        case .deviceFlowNotStarted:
            "The GitHub device authorization has not been started."
        case .deviceFlowExpired:
            "The GitHub device code expired. Start sign-in again."
        case .deviceFlowDenied:
            "GitHub authorization was denied."
        case .deviceFlowFailed:
            "GitHub could not complete device authorization."
        case .invalidPersonalAccessToken:
            "Enter a valid GitHub personal access token."
        }
    }
}

nonisolated enum ForgeGitHubAppConfiguration {
    static let clientIDInfoKey = "GitXGitHubAppClientID"
    static let applicationSlugInfoKey = "GitXGitHubAppSlug"

    static func bundled(bundle: Bundle = .main) -> GitHubAppDeviceFlowConfiguration? {
        configuration(infoDictionary: bundle.infoDictionary ?? [:])
    }

    static func configuration(infoDictionary: [String: Any]) -> GitHubAppDeviceFlowConfiguration? {
        guard let clientID = normalized(infoDictionary[clientIDInfoKey] as? String),
              let applicationSlug = normalized(infoDictionary[applicationSlugInfoKey] as? String)
        else {
            return nil
        }
        return try? GitHubAppDeviceFlowConfiguration(
            clientID: clientID,
            applicationSlug: applicationSlug
        )
    }

    #if DEBUG
        static func runProductProofConfigurationBoundaries() -> Bool {
            let missing = configuration(infoDictionary: [:])
            let whitespace = configuration(infoDictionary: [
                clientIDInfoKey: "   ", applicationSlugInfoKey: "gitx",
            ])
            let placeholder = configuration(infoDictionary: [
                clientIDInfoKey: "$(GITHUB_APP_CLIENT_ID)", applicationSlugInfoKey: "gitx",
            ])
            return missing == nil && whitespace == nil && placeholder == nil
        }
    #endif

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.contains("$("),
              !normalized.contains("${")
        else {
            return nil
        }
        return normalized
    }
}

nonisolated struct GitHubAuthorizationRecoveryPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case saml
        case installation
    }

    let kind: Kind
    let title: String
    let message: String
    let browserActionTitle: String
    let retryTitle: String
    let retryMessage: String
    let url: URL

    static func make(error: Error) -> GitHubAuthorizationRecoveryPresentation? {
        switch error {
        case let GitHubReadError.samlAuthorizationRequired(metadata),
             let GitHubMutationError.samlAuthorizationRequired(metadata):
            metadata.saml?.authorizationURL.map(saml)
        case let GitHubReadError.installationConfigurationRequired(metadata),
             let GitHubMutationError.installationConfigurationRequired(metadata):
            metadata.installation?.configurationURL.map(installation)
        default:
            nil
        }
    }

    private static func saml(_ url: URL) -> GitHubAuthorizationRecoveryPresentation {
        GitHubAuthorizationRecoveryPresentation(
            kind: .saml,
            title: "Organization Authorization Required",
            message: "Authorize this Credential for the organization in your browser. Existing repository capabilities remain available if you cancel.",
            browserActionTitle: "Authorize in Browser",
            retryTitle: "Retry Organization Access?",
            retryMessage: "After GitHub confirms authorization, retry the exact request once.",
            url: url
        )
    }

    private static func installation(_ url: URL) -> GitHubAuthorizationRecoveryPresentation {
        GitHubAuthorizationRecoveryPresentation(
            kind: .installation,
            title: "Repository Access Required",
            message: "Configure the GitHub App installation or repository selection in your browser. Existing repository capabilities remain available if you cancel.",
            browserActionTitle: "Configure Repository Access",
            retryTitle: "Retry Repository Access?",
            retryMessage: "After GitHub confirms repository access, retry the exact request once.",
            url: url
        )
    }
}

nonisolated enum GitHubAuthorizationRecoverySourcePolicy {
    static func allowsRecovery(
        for failure: GitHubRESTAuthorizationFailure,
        credentialSource: ForgeCredentialSource
    ) -> Bool {
        switch failure {
        case .samlAuthorizationRequired:
            credentialSource == .classicPersonalAccessToken ||
                credentialSource == .commandLineBroker
        case .installationConfigurationRequired:
            credentialSource == .forgeApplicationDeviceFlow
        case .badCredentials, .authorizationDenied:
            false
        }
    }
}

@MainActor
enum GitHubAuthorizationRecoveryPresenter {
    @discardableResult
    static func present(
        error: Error,
        for windowController: PBGitWindowController?,
        retry: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let presentation = GitHubAuthorizationRecoveryPresentation.make(error: error),
              let window = windowController?.window
        else { return false }
        let alert = NSAlert()
        alert.messageText = presentation.title
        alert.informativeText = presentation.message
        alert.addButton(withTitle: presentation.browserActionTitle)
        alert.addButton(withTitle: "Not Now")
        alert.buttons.first?.setAccessibilityIdentifier("GitX.GitHubAuthorization.OpenBrowser")
        alert.buttons.last?.setAccessibilityIdentifier("GitX.GitHubAuthorization.NotNow")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            _ = NSWorkspace.shared.open(presentation.url)
            DispatchQueue.main.async {
                let retryAlert = NSAlert()
                retryAlert.messageText = presentation.retryTitle
                retryAlert.informativeText = presentation.retryMessage
                retryAlert.addButton(withTitle: "Retry")
                retryAlert.addButton(withTitle: "Not Now")
                retryAlert.buttons.first?.setAccessibilityIdentifier("GitX.GitHubAuthorization.Retry")
                retryAlert.buttons.last?.setAccessibilityIdentifier("GitX.GitHubAuthorization.RetryNotNow")
                retryAlert.beginSheetModal(for: window) { retryResponse in
                    guard retryResponse == .alertFirstButtonReturn else { return }
                    retry()
                }
            }
        }
        return true
    }
}

nonisolated struct ForgePersonalAccessTokenAcquisition: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    let kind: GitHubPersonalAccessTokenKind
    let token: Data
    let label: String?
    let expiresAt: Date?

    init(
        kind: GitHubPersonalAccessTokenKind,
        token: Data,
        label: String? = nil,
        expiresAt: Date? = nil
    ) throws {
        guard !token.isEmpty else {
            throw ForgeAccountsError.invalidPersonalAccessToken
        }
        self.kind = kind
        self.token = token
        self.label = label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.expiresAt = expiresAt
    }

    var description: String {
        "GitHub personal access Credential acquisition (token redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

nonisolated struct ForgeAccountPreferencesRow: Equatable, Sendable {
    enum Expiry: Equatable, Sendable {
        case doesNotExpire
        case current(Date)
        case expiresSoon(Date)
        case expired(Date)
    }

    let accountID: ForgeAccountID
    let login: String
    let credentialSource: ForgeCredentialSource
    let credentialTitle: String
    let expiry: Expiry
    let canConfigureRepositoryAccess: Bool
}

nonisolated struct ForgeAttentionWatchPreferencesRow: Equatable, Sendable {
    let key: ForgeWatchedRepositoryKey
    let accountLogin: String
    let repositoryName: String
    let includesBotReplies: Bool
}

nonisolated enum ForgeAccountPreferencesPresenter {
    static func rows(accounts: [ForgeAccount], now: Date) -> [ForgeAccountPreferencesRow] {
        accounts.map { account in
            ForgeAccountPreferencesRow(
                accountID: account.id,
                login: account.login,
                credentialSource: account.currentCredential.source,
                credentialTitle: credentialTitle(account.currentCredential.source),
                expiry: expiry(account.currentCredential.expiresAt, now: now),
                canConfigureRepositoryAccess: account.currentCredential.source == .forgeApplicationDeviceFlow
            )
        }
    }

    static func removalMessage(for row: ForgeAccountPreferencesRow) -> String {
        "Remove the GitHub.com Forge Account \(row.login)? Its Credential and account-scoped Forge data will be deleted."
    }

    private static func credentialTitle(_ source: ForgeCredentialSource) -> String {
        switch source {
        case .forgeApplicationDeviceFlow:
            "GitHub App"
        case .commandLineBroker:
            "GitHub CLI"
        case .fineGrainedPersonalAccessToken:
            "Fine-grained token"
        case .classicPersonalAccessToken:
            "Classic token"
        }
    }

    private static func expiry(_ date: Date?, now: Date) -> ForgeAccountPreferencesRow.Expiry {
        guard let date else { return .doesNotExpire }
        if date <= now {
            return .expired(date)
        }
        if date.timeIntervalSince(now) <= 7 * 24 * 60 * 60 {
            return .expiresSoon(date)
        }
        return .current(date)
    }
}

nonisolated protocol ForgeAccountsClient: Sendable {
    func accounts(refreshingExpiringCredentialsAt date: Date) async throws -> [ForgeAccount]
    func beginDeviceFlow(receivedAt: Date) async throws -> GitHubDeviceAuthorization
    func pollDeviceFlow(receivedAt: Date) async throws -> GitHubDeviceFlowPollResult
    func completeDeviceFlow(receivedAt: Date) async throws -> ForgeAccount
    func addUsingExplicitGitHubCLIBrokerage() async throws -> ForgeAccount
    func addPersonalAccessToken(
        _ acquisition: ForgePersonalAccessTokenAcquisition,
        receivedAt: Date
    ) async throws -> ForgeAccount
    func removeAccount(_ accountID: ForgeAccountID) async throws
    func githubApplicationInstallationURL() async throws -> URL
    func attentionWatches() async throws -> [ForgeAttentionWatchPreferencesRow]
    func setAttentionBotReplies(_ enabled: Bool, for key: ForgeWatchedRepositoryKey) async throws
    func removeAttentionWatch(_ key: ForgeWatchedRepositoryKey) async throws
}

actor ForgeAccountsService: ForgeAccountsClient {
    typealias CredentialIDProvider = @Sendable (GitHubPersonalAccessTokenKind, String?) throws -> ForgeCredentialID

    private let services: ForgeApplicationServices
    private let configuration: GitHubAppDeviceFlowConfiguration?
    private let authenticationTransport: GitHubAuthenticationTransport
    private let credentialIDProvider: CredentialIDProvider
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeAccounts")
    private var deviceFlowCoordinator: GitHubDeviceFlowCoordinator?

    init(
        services: ForgeApplicationServices,
        configuration: GitHubAppDeviceFlowConfiguration?,
        authenticationTransport: GitHubAuthenticationTransport = GitHubAuthenticationTransport(),
        credentialIDProvider: @escaping CredentialIDProvider = { kind, label in
            let component = label?.replacingOccurrences(of: ":", with: "-") ?? UUID().uuidString
            return try ForgeCredentialID("\(kind.rawValue)-pat:\(component)")
        }
    ) {
        self.services = services
        self.configuration = configuration
        self.authenticationTransport = authenticationTransport
        self.credentialIDProvider = credentialIDProvider
    }

    func accounts(refreshingExpiringCredentialsAt date: Date) async throws -> [ForgeAccount] {
        let accounts = try await services.accountStore.accounts()
        guard configuration != nil else { return accounts }
        for account in accounts where account.currentCredential.source == .forgeApplicationDeviceFlow {
            do {
                _ = try await services.githubReadAdapterFactory.refreshCredentialIfNeeded(
                    for: account.currentCredential.reference,
                    at: date
                )
            } catch {
                logger.error(
                    "GitHub App Credential refresh check failed account=\(account.id.value, privacy: .private(mask: .hash))"
                )
            }
        }
        return try await services.accountStore.accounts()
    }

    func beginDeviceFlow(receivedAt: Date = Date()) async throws -> GitHubDeviceAuthorization {
        guard let configuration else {
            throw ForgeAccountsError.githubApplicationNotConfigured
        }
        let coordinator = GitHubDeviceFlowCoordinator(configuration: configuration)
        deviceFlowCoordinator = coordinator
        let authorization = try await coordinator.begin(receivedAt: receivedAt)
        logger.notice("GitHub App device authorization presented")
        return authorization
    }

    func pollDeviceFlow(receivedAt: Date = Date()) async throws -> GitHubDeviceFlowPollResult {
        guard let deviceFlowCoordinator else {
            throw ForgeAccountsError.deviceFlowNotStarted
        }
        return try await deviceFlowCoordinator.poll(receivedAt: receivedAt)
    }

    func completeDeviceFlow(receivedAt: Date = Date()) async throws -> ForgeAccount {
        guard let configuration, let deviceFlowCoordinator else {
            throw ForgeAccountsError.deviceFlowNotStarted
        }
        let authorization = try await deviceFlowCoordinator.completeAuthorization(receivedAt: receivedAt)
        let accessToken = authorization.credential.accessToken.withUnsafeUTF8Bytes { Data($0) }
        let refreshToken = authorization.credential.refreshToken.withUnsafeUTF8Bytes { Data($0) }
        let account = try await services.accountStore.addAccount(
            accountID: authorization.identity.accountID,
            login: authorization.identity.login,
            credentialID: ForgeCredentialID("github-app:\(configuration.applicationSlug)"),
            source: .forgeApplicationDeviceFlow,
            expiresAt: authorization.credential.accessTokenExpiresAt,
            secrets: ForgeCredentialSecretMaterial(
                accessToken: accessToken,
                refreshToken: refreshToken,
                refreshTokenExpiresAt: authorization.credential.refreshTokenExpiresAt
            ),
            authorizationEvidence: .githubApplicationMilestone3
        )
        await ForgeAvatarLoader.shared.restoreAfterAccountAddition(account.id)
        self.deviceFlowCoordinator = nil
        logger.notice(
            "GitHub App Forge Account added account=\(account.id.value, privacy: .private(mask: .hash))"
        )
        await Self.notifyAccountsChanged()
        return account
    }

    func addUsingExplicitGitHubCLIBrokerage() async throws -> ForgeAccount {
        let account = try await services.addAccountCoordinator.addUsingExplicitGitHubCLIBrokerage()
        logger.notice(
            "Explicit GitHub CLI Forge Account addition completed account=\(account.id.value, privacy: .private(mask: .hash))"
        )
        await Self.notifyAccountsChanged()
        return account
    }

    func addPersonalAccessToken(
        _ acquisition: ForgePersonalAccessTokenAcquisition,
        receivedAt: Date = Date()
    ) async throws -> ForgeAccount {
        let entry = try GitHubPersonalAccessTokenEntry(
            token: GitHubSecret(utf8Bytes: acquisition.token),
            kind: acquisition.kind,
            label: acquisition.label,
            expiresAt: acquisition.expiresAt
        )
        let introspection = try await authenticationTransport.introspectPersonalAccessToken(
            entry,
            receivedAt: receivedAt
        )
        let kind: ForgePersonalAccessTokenKind = switch acquisition.kind {
        case .fineGrained: .fineGrained
        case .classic: .classic
        }
        let authorizationEvidence: ForgeStoredCredentialAuthorizationEvidence = switch introspection.scopeEvidence {
        case let .classic(scopes): .githubClassicScopes(scopes)
        case .fineGrainedNotIntrospectable: .githubFineGrainedNotIntrospectable
        }
        let account = try await services.addAccountCoordinator.addPersonalAccessToken(
            accountID: introspection.accountID,
            login: introspection.login,
            credentialID: credentialIDProvider(acquisition.kind, acquisition.label),
            kind: kind,
            token: acquisition.token,
            expiresAt: acquisition.expiresAt,
            authorizationEvidence: authorizationEvidence
        )
        logger.notice(
            "GitHub personal access Credential added kind=\(acquisition.kind.rawValue, privacy: .public) account=\(account.id.value, privacy: .private(mask: .hash))"
        )
        await Self.notifyAccountsChanged()
        return account
    }

    func removeAccount(_ accountID: ForgeAccountID) async throws {
        try await services.removalCoordinator.removeAccount(accountID)
        logger.notice(
            "Forge Account removal completed account=\(accountID.value, privacy: .private(mask: .hash))"
        )
        await Self.notifyAccountsChanged()
    }

    func githubApplicationInstallationURL() throws -> URL {
        guard let configuration else {
            throw ForgeAccountsError.githubApplicationNotConfigured
        }
        return configuration.newInstallationURL
    }

    func attentionWatches() async throws -> [ForgeAttentionWatchPreferencesRow] {
        guard let database = services.database else { return [] }
        let accounts = try await services.accountStore.accounts()
        let persistence = ForgeSQLiteAttentionPersistence(store: database)
        var rows: [ForgeAttentionWatchPreferencesRow] = []
        for account in accounts {
            let watches = try await persistence.watchedRepositories(accountID: account.id)
            rows.append(contentsOf: watches.map { watch in
                ForgeAttentionWatchPreferencesRow(
                    key: watch.key,
                    accountLogin: account.login,
                    repositoryName: "\(watch.key.repository.owner)/\(watch.key.repository.name)",
                    includesBotReplies: watch.includesBotReplies
                )
            })
        }
        return rows.sorted { lhs, rhs in
            if lhs.accountLogin != rhs.accountLogin {
                return lhs.accountLogin.localizedStandardCompare(rhs.accountLogin) == .orderedAscending
            }
            return lhs.repositoryName.localizedStandardCompare(rhs.repositoryName) == .orderedAscending
        }
    }

    func setAttentionBotReplies(
        _ enabled: Bool,
        for key: ForgeWatchedRepositoryKey
    ) async throws {
        guard let database = services.database else { return }
        let persistence = ForgeSQLiteAttentionPersistence(store: database)
        let watches = try await persistence.watchedRepositories(accountID: key.accountID)
        guard let current = watches.first(where: { $0.key == key }) else {
            throw ForgeAttentionInboxError.missingWatchedRepository
        }
        try await persistence.save(ForgeWatchedRepository(
            key: current.key,
            addedAt: current.addedAt,
            source: current.source,
            includesBotReplies: enabled,
            baselineEstablishedAt: current.baselineEstablishedAt,
            lastSuccessfulPollAt: current.lastSuccessfulPollAt
        ))
        await Self.notifyAttentionChanged()
        logger.notice("Updated per-repository Attention bot-reply policy")
    }

    func removeAttentionWatch(_ key: ForgeWatchedRepositoryKey) async throws {
        guard let database = services.database else { return }
        try await ForgeSQLiteAttentionPersistence(store: database).removeWatchedRepository(key)
        await Self.notifyAttentionChanged()
        logger.notice("Removed one watched Forge Repository from Attention")
    }

    @MainActor
    private static func notifyAccountsChanged() {
        NotificationCenter.default.post(name: .forgeAccountsDidChange, object: nil)
    }

    @MainActor
    private static func notifyAttentionChanged() {
        NotificationCenter.default.post(name: .forgeAttentionInboxDidChange, object: nil)
    }
}

@MainActor
final class ForgeAccountsPreferencesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    typealias ClientFactory = @Sendable () async throws -> any ForgeAccountsClient

    private let clientFactory: ClientFactory
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeAccountsPreferences")
    private let tableView = NSTableView()
    private let watchTableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Loading Forge Accounts…")
    private let signInButton = NSButton(title: "Sign In with GitHub App…", target: nil, action: nil)
    private let alternatives = NSPopUpButton()
    private let removeButton = NSButton(title: "Remove Account…", target: nil, action: nil)
    private let configureButton = NSButton(title: "Configure Repository Access…", target: nil, action: nil)
    private let removeWatchButton = NSButton(title: "Remove Watch", target: nil, action: nil)
    private let pollingPreset = NSPopUpButton(frame: .zero, pullsDown: false)
    private let authoredFailedChecks = NSButton(
        checkboxWithTitle: "Failed checks on my Pull Requests",
        target: nil,
        action: nil
    )
    private let awaitingReviewFailedChecks = NSButton(
        checkboxWithTitle: "Failed checks awaiting my review",
        target: nil,
        action: nil
    )
    private var alertButtons: [ForgeAttentionAlertCategory: NSButton] = [:]
    private var client: (any ForgeAccountsClient)?
    private var rows: [ForgeAccountPreferencesRow] = []
    private var watchRows: [ForgeAttentionWatchPreferencesRow] = []
    private var installationURL: URL?
    private var didLoad = false
    private var operationTask: Task<Void, Never>?

    init(clientFactory: @escaping ClientFactory) {
        self.clientFactory = clientFactory
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 825))
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        operationTask?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didLoad else { return }
        didLoad = true
        loadClientAndAccounts()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === watchTableView ? watchRows.count : rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === watchTableView {
            return watchCell(tableColumn: tableColumn, row: row)
        }
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let value: String
        switch identifier {
        case "Account": value = rows[row].login
        case "Credential": value = rows[row].credentialTitle
        case "Status": value = statusText(rows[row].expiry)
        default: return nil
        }
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityIdentifier("ForgeAccount\(identifier)Cell")
        return field
    }

    func tableViewSelectionDidChange(_: Notification) {
        updateButtonState()
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 760).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 825).isActive = true

        let heading = NSTextField(labelWithString: "Accounts")
        heading.font = .preferredFont(forTextStyle: .headline, options: [:])
        heading.setAccessibilityIdentifier("ForgeAccountsHeading")
        let detail = NSTextField(wrappingLabelWithString:
            "Add one or more GitHub.com Forge Accounts. GitHub App sign-in is recommended; GitHub CLI and personal access tokens are used only when you choose them here.")
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3

        for (title, width) in [("Account", 210.0), ("Credential", 210.0), ("Status", 235.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.headerView = NSTableHeaderView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = false
        tableView.setAccessibilityIdentifier("ForgeAccountsTable")
        tableView.setAccessibilityLabel("GitHub.com Forge Accounts")
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.widthAnchor.constraint(equalToConstant: 704).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 190).isActive = true

        signInButton.bezelStyle = .rounded
        signInButton.target = self
        signInButton.action = #selector(signInWithGitHubApp(_:))
        signInButton.setAccessibilityIdentifier("AddForgeAccountWithGitHubApp")
        signInButton.setAccessibilityLabel("Sign in with GitHub App")

        alternatives.addItems(withTitles: [
            "Other Add Account Method…",
            "Use GitHub CLI",
            "Add Fine-Grained Token…",
            "Add Classic Token…",
        ])
        alternatives.target = self
        alternatives.action = #selector(addAlternativeAccount(_:))
        alternatives.setAccessibilityIdentifier("ForgeAccountAlternativeMethods")

        removeButton.target = self
        removeButton.action = #selector(removeSelectedAccount(_:))
        removeButton.setAccessibilityIdentifier("RemoveForgeAccount")
        configureButton.target = self
        configureButton.action = #selector(configureRepositoryAccess(_:))
        configureButton.setAccessibilityIdentifier("ConfigureForgeRepositoryAccess")

        let actions = NSStackView(views: [
            signInButton,
            alternatives,
            NSView(),
            configureButton,
            removeButton,
        ])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.widthAnchor.constraint(equalToConstant: 704).isActive = true

        let permissions = NSTextField(wrappingLabelWithString:
            "GitHub App permission envelope: Metadata read; Contents, Pull Requests, and Issues write; Checks and Commit Statuses read. Issue features remain read-only through Milestone 3.")
        permissions.textColor = .secondaryLabelColor
        permissions.font = .preferredFont(forTextStyle: .footnote, options: [:])
        permissions.maximumNumberOfLines = 3
        permissions.setAccessibilityIdentifier("ForgeAccountPermissionEnvelope")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setAccessibilityIdentifier("ForgeAccountsStatus")

        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 704).isActive = true
        let attentionPreferences = makeAttentionPreferencesView()

        let stack = NSStackView(views: [
            heading,
            detail,
            scrollView,
            actions,
            permissions,
            statusLabel,
            separator,
            attentionPreferences,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
        ])
        updateButtonState()
    }

    private func makeAttentionPreferencesView() -> NSView {
        let heading = NSTextField(labelWithString: "Attention")
        heading.font = .preferredFont(forTextStyle: .headline, options: [:])
        heading.setAccessibilityIdentifier("ForgeAttentionPreferencesHeading")
        let detail = NSTextField(wrappingLabelWithString:
            "Only explicitly watched repositories are polled. Opening or binding a repository adds it here; removing a watch also removes its local seen state.")
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.widthAnchor.constraint(equalToConstant: 704).isActive = true

        for (title, width) in [("Repository", 330.0), ("Account", 185.0), ("Bot Replies", 155.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            column.title = title
            column.width = width
            watchTableView.addTableColumn(column)
        }
        watchTableView.headerView = NSTableHeaderView()
        watchTableView.delegate = self
        watchTableView.dataSource = self
        watchTableView.allowsMultipleSelection = false
        watchTableView.setAccessibilityIdentifier("ForgeAttentionWatchesTable")
        watchTableView.setAccessibilityLabel("Watched Forge Repositories")
        let watchScroll = NSScrollView()
        watchScroll.documentView = watchTableView
        watchScroll.hasVerticalScroller = true
        watchScroll.borderType = .bezelBorder
        watchScroll.widthAnchor.constraint(equalToConstant: 704).isActive = true
        watchScroll.heightAnchor.constraint(equalToConstant: 105).isActive = true

        removeWatchButton.target = self
        removeWatchButton.action = #selector(removeSelectedWatch(_:))
        removeWatchButton.controlSize = .small
        removeWatchButton.setAccessibilityIdentifier("RemoveForgeAttentionWatch")
        let watchActions = NSStackView(views: [NSView(), removeWatchButton])
        watchActions.orientation = .horizontal
        watchActions.widthAnchor.constraint(equalToConstant: 704).isActive = true

        pollingPreset.addItems(withTitles: ["Frequent", "Balanced", "Conservative", "Manual"])
        pollingPreset.selectItem(at: Self.pollingIndex(ApplicationSettings.attentionPollingPreset))
        pollingPreset.target = self
        pollingPreset.action = #selector(attentionPollingChanged(_:))
        pollingPreset.setAccessibilityIdentifier("ForgeAttentionPollingPreset")

        authoredFailedChecks.state = ApplicationSettings.attentionIncludesFailedChecksOnAuthoredPullRequests
            ? .on
            : .off
        authoredFailedChecks.target = self
        authoredFailedChecks.action = #selector(attentionCheckPolicyChanged(_:))
        authoredFailedChecks.setAccessibilityIdentifier("ForgeAttentionAuthoredFailedChecks")
        awaitingReviewFailedChecks.state = ApplicationSettings.attentionIncludesFailedChecksAwaitingReview
            ? .on
            : .off
        awaitingReviewFailedChecks.target = self
        awaitingReviewFailedChecks.action = #selector(attentionCheckPolicyChanged(_:))
        awaitingReviewFailedChecks.setAccessibilityIdentifier("ForgeAttentionAwaitingReviewFailedChecks")

        let checkStack = NSStackView(views: [authoredFailedChecks, awaitingReviewFailedChecks])
        checkStack.orientation = .vertical
        checkStack.alignment = .leading
        checkStack.spacing = 4

        let alertStack = NSStackView()
        alertStack.orientation = .vertical
        alertStack.alignment = .leading
        alertStack.spacing = 3
        for category in ForgeAttentionAlertCategory.allCases {
            let button = NSButton(
                checkboxWithTitle: Self.alertTitle(category),
                target: self,
                action: #selector(attentionAlertCategoryChanged(_:))
            )
            button.identifier = NSUserInterfaceItemIdentifier("ForgeAttentionAlert.\(category.rawValue)")
            button.state = ApplicationSettings.attentionAlertCategories.contains(category) ? .on : .off
            button.setAccessibilityIdentifier("ForgeAttentionAlert.\(category.rawValue)")
            alertButtons[category] = button
            alertStack.addArrangedSubview(button)
        }

        let pollingRow = labeledRow("Polling:", control: pollingPreset)
        let checksRow = labeledRow("Failed checks:", control: checkStack)
        let alertsRow = labeledRow("macOS alerts:", control: alertStack)
        let stack = NSStackView(views: [
            heading,
            detail,
            watchScroll,
            watchActions,
            pollingRow,
            checksRow,
            alertsRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.setAccessibilityIdentifier("ForgeAttentionPreferences")
        return stack
    }

    private func labeledRow(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        return row
    }

    private func loadClientAndAccounts() {
        setBusy(true, status: "Loading Forge Accounts…")
        operationTask = Task { [weak self, clientFactory] in
            guard let self else { return }
            do {
                let client = try await clientFactory()
                self.client = client
                self.installationURL = try? await client.githubApplicationInstallationURL()
                try await self.reloadAccounts(status: nil)
            } catch {
                self.present(error)
            }
            self.setBusy(false, status: self.rows.isEmpty ? "No GitHub.com Forge Accounts are configured." : nil)
        }
    }

    private func reloadAccounts(status: String?) async throws {
        guard let client else { return }
        let accounts = try await client.accounts(refreshingExpiringCredentialsAt: Date())
        rows = ForgeAccountPreferencesPresenter.rows(accounts: accounts, now: Date())
        watchRows = try await client.attentionWatches()
        tableView.reloadData()
        watchTableView.reloadData()
        if !rows.isEmpty, tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        statusLabel.stringValue = status ?? (rows.isEmpty
            ? "No GitHub.com Forge Accounts are configured."
            : "\(rows.count) GitHub.com Forge Account\(rows.count == 1 ? "" : "s") configured.")
        updateButtonState()
    }

    private func watchCell(tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard watchRows.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else {
            return nil
        }
        let watch = watchRows[row]
        switch identifier {
        case "Repository":
            let field = NSTextField(labelWithString: watch.repositoryName)
            field.lineBreakMode = .byTruncatingMiddle
            field.setAccessibilityIdentifier("ForgeAttentionWatchRepositoryCell")
            return field
        case "Account":
            let field = NSTextField(labelWithString: watch.accountLogin)
            field.lineBreakMode = .byTruncatingTail
            field.setAccessibilityIdentifier("ForgeAttentionWatchAccountCell")
            return field
        case "Bot Replies":
            let button = ForgeAttentionWatchBotButton(key: watch.key)
            button.title = "Include"
            button.setButtonType(.switch)
            button.state = watch.includesBotReplies ? .on : .off
            button.target = self
            button.action = #selector(attentionBotRepliesChanged(_:))
            button.setAccessibilityIdentifier("ForgeAttentionWatchBotReplies")
            button.setAccessibilityLabel("Include bot replies for \(watch.repositoryName)")
            return button
        default:
            return nil
        }
    }

    @objc private func attentionPollingChanged(_ sender: NSPopUpButton) {
        let values: [ForgeAttentionPollingPreset] = [.frequent, .balanced, .conservative, .manual]
        guard values.indices.contains(sender.indexOfSelectedItem) else { return }
        ApplicationSettings.attentionPollingPreset = values[sender.indexOfSelectedItem]
        logger.info("Attention polling preset changed")
    }

    @objc private func attentionCheckPolicyChanged(_: Any?) {
        ApplicationSettings.attentionIncludesFailedChecksOnAuthoredPullRequests = authoredFailedChecks.state == .on
        ApplicationSettings.attentionIncludesFailedChecksAwaitingReview = awaitingReviewFailedChecks.state == .on
        logger.info("Attention failed-check policy changed")
    }

    @objc private func attentionAlertCategoryChanged(_: Any?) {
        let previous = ApplicationSettings.attentionAlertCategories
        let updated = Set(alertButtons.compactMap { category, button in
            button.state == .on ? category : nil
        })
        ApplicationSettings.attentionAlertCategories = updated
        if ForgeAttentionAlertPolicy.shouldRequestSystemPermission(previous: previous, updated: updated) {
            Task {
                _ = await ForgeAttentionNotificationDelivery.shared.requestAuthorization()
            }
        }
        logger.info("Attention alert categories changed")
    }

    @objc private func attentionBotRepliesChanged(_ sender: ForgeAttentionWatchBotButton) {
        guard let client else { return }
        runOperation(status: "Updating Attention policy…") { [weak self] in
            guard let self else { return }
            try await client.setAttentionBotReplies(sender.state == .on, for: sender.key)
            try await self.reloadAccounts(status: "Attention policy updated.")
        }
    }

    @objc private func removeSelectedWatch(_: Any?) {
        guard let client, watchRows.indices.contains(watchTableView.selectedRow) else { return }
        let watch = watchRows[watchTableView.selectedRow]
        runOperation(status: "Removing Attention watch…") { [weak self] in
            guard let self else { return }
            try await client.removeAttentionWatch(watch.key)
            try await self.reloadAccounts(status: "Attention watch removed.")
        }
    }

    @objc private func signInWithGitHubApp(_: Any?) {
        guard let client else { return }
        runOperation(status: "Requesting a GitHub device code…") { [weak self] in
            guard let self else { return }
            let authorization = try await client.beginDeviceFlow(receivedAt: Date())
            guard self.presentDeviceAuthorization(authorization) else { return }
            _ = NSWorkspace.shared.open(authorization.verificationURL)
            var nextPollAt = authorization.issuedAt.addingTimeInterval(authorization.pollingInterval)
            while true {
                try Task.checkCancellation()
                try await Self.wait(until: nextPollAt)
                switch try await client.pollDeviceFlow(receivedAt: Date()) {
                case let .notYetPollable(date), let .pending(date), let .slowedDown(date):
                    nextPollAt = date
                    self.statusLabel.stringValue = "Waiting for GitHub authorization…"
                case .authorized:
                    _ = try await client.completeDeviceFlow(receivedAt: Date())
                    try await self.reloadAccounts(status: "GitHub App Forge Account added.")
                    return
                case .expired:
                    throw ForgeAccountsError.deviceFlowExpired
                case .denied:
                    throw ForgeAccountsError.deviceFlowDenied
                case let .terminal(status):
                    switch status {
                    case .authorized:
                        _ = try await client.completeDeviceFlow(receivedAt: Date())
                        try await self.reloadAccounts(status: "GitHub App Forge Account added.")
                        return
                    case .expired:
                        throw ForgeAccountsError.deviceFlowExpired
                    case .denied:
                        throw ForgeAccountsError.deviceFlowDenied
                    }
                }
            }
        }
    }

    @objc private func addAlternativeAccount(_ sender: NSPopUpButton) {
        defer { sender.selectItem(at: 0) }
        switch sender.indexOfSelectedItem {
        case 1: addUsingGitHubCLI()
        case 2: addPersonalAccessToken(kind: .fineGrained)
        case 3: addPersonalAccessToken(kind: .classic)
        default: break
        }
    }

    private func addUsingGitHubCLI() {
        guard let client else { return }
        runOperation(status: "Consulting GitHub CLI for this Add Account request…") { [weak self] in
            guard let self else { return }
            _ = try await client.addUsingExplicitGitHubCLIBrokerage()
            try await self.reloadAccounts(status: "GitHub CLI Forge Account added.")
        }
    }

    private func addPersonalAccessToken(kind: GitHubPersonalAccessTokenKind) {
        guard let client, let acquisition = presentPersonalAccessTokenEntry(kind: kind) else { return }
        runOperation(status: "Validating the GitHub personal access Credential…") { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.addPersonalAccessToken(acquisition, receivedAt: Date())
            } catch let GitHubAuthenticationTransportError.authorizationFailure(failure) {
                guard try await self.recoverAuthorizationFailure(
                    failure,
                    source: kind.forgeCredentialSource,
                    retry: { try await client.addPersonalAccessToken(acquisition, receivedAt: Date()) }
                ) != nil else {
                    return
                }
            }
            try await self.reloadAccounts(status: "Personal access Credential added.")
        }
    }

    @objc private func removeSelectedAccount(_: Any?) {
        guard let client, let row = selectedRow else { return }
        let alert = NSAlert()
        alert.messageText = "Remove Forge Account?"
        alert.informativeText = ForgeAccountPreferencesPresenter.removalMessage(for: row)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove Account")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runOperation(status: "Removing \(row.login)…") { [weak self] in
            guard let self else { return }
            try await client.removeAccount(row.accountID)
            try await self.reloadAccounts(status: "Forge Account removed.")
        }
    }

    @objc private func configureRepositoryAccess(_: Any?) {
        guard let installationURL else {
            present(ForgeAccountsError.githubApplicationNotConfigured)
            return
        }
        _ = NSWorkspace.shared.open(installationURL)
        logger.notice("Opened GitHub App repository-access configuration")
    }

    private var selectedRow: ForgeAccountPreferencesRow? {
        guard rows.indices.contains(tableView.selectedRow) else { return nil }
        return rows[tableView.selectedRow]
    }

    private func updateButtonState() {
        let hasClient = client != nil && operationTask == nil
        signInButton.isEnabled = hasClient && installationURL != nil
        alternatives.isEnabled = hasClient
        removeButton.isEnabled = hasClient && selectedRow != nil
        configureButton.isEnabled = hasClient &&
            (selectedRow?.canConfigureRepositoryAccess == true) &&
            installationURL != nil
        removeWatchButton.isEnabled = hasClient && watchRows.indices.contains(watchTableView.selectedRow)
        signInButton.toolTip = installationURL == nil
            ? ForgeAccountsError.githubApplicationNotConfigured.localizedDescription
            : "Use GitHub's device flow to add a GitHub App Forge Account."
    }

    private func setBusy(_ busy: Bool, status: String?) {
        if let status {
            statusLabel.stringValue = status
        }
        if !busy {
            operationTask = nil
        }
        updateButtonState()
    }

    private func runOperation(
        status: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        operationTask?.cancel()
        setBusy(true, status: status)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
            } catch is CancellationError {
                self.statusLabel.stringValue = "Account operation cancelled."
            } catch {
                self.present(error)
            }
            self.setBusy(false, status: nil)
        }
    }

    private func presentDeviceAuthorization(_ authorization: GitHubDeviceAuthorization) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Authorize GitX on GitHub"
        alert.informativeText = "GitHub will ask for this one-time code:\n\n\(authorization.userCode)\n\nGitX will open the exact GitHub device authorization page and wait for approval."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open GitHub and Continue")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.setAccessibilityIdentifier("OpenGitHubDeviceAuthorization")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentPersonalAccessTokenEntry(
        kind: GitHubPersonalAccessTokenKind
    ) -> ForgePersonalAccessTokenAcquisition? {
        let token = NSSecureTextField()
        token.placeholderString = kind == .fineGrained ? "github_pat_…" : "ghp_…"
        token.setAccessibilityIdentifier("ForgePersonalAccessToken")
        let label = NSTextField()
        label.placeholderString = "Optional label"
        label.setAccessibilityIdentifier("ForgePersonalAccessTokenLabel")
        let tokenRow = NSStackView(views: [NSTextField(labelWithString: "Token:"), token])
        let labelRow = NSStackView(views: [NSTextField(labelWithString: "Label:"), label])
        for row in [tokenRow, labelRow] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.views.first?.widthAnchor.constraint(equalToConstant: 52).isActive = true
            row.views.last?.widthAnchor.constraint(equalToConstant: 330).isActive = true
        }
        let accessory = NSStackView(views: [tokenRow, labelRow])
        accessory.orientation = .vertical
        accessory.spacing = 8
        let accessorySize = accessory.fittingSize
        accessory.setFrameSize(NSSize(
            width: ceil(accessorySize.width),
            height: ceil(accessorySize.height)
        ))
        let alert = NSAlert()
        alert.messageText = kind == .fineGrained
            ? "Add Fine-Grained Personal Access Token"
            : "Add Classic Personal Access Token"
        alert.informativeText = "GitX validates the Credential with GitHub and stores it only in Keychain."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Add Account")
        alert.addButton(withTitle: "Cancel")
        alert.layout()
        logger.debug("Sized personal access Credential alert to contain its complete fields")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let tokenData = Data(token.stringValue.utf8)
        token.stringValue = ""
        do {
            return try ForgePersonalAccessTokenAcquisition(
                kind: kind,
                token: tokenData,
                label: label.stringValue
            )
        } catch {
            present(error)
            return nil
        }
    }

    private func recoverAuthorizationFailure<Value: Sendable>(
        _ failure: GitHubRESTAuthorizationFailure,
        source: ForgeCredentialSource,
        retry: @escaping @Sendable () async throws -> Value
    ) async throws -> Value? {
        guard GitHubAuthorizationRecoverySourcePolicy.allowsRecovery(
            for: failure,
            credentialSource: source
        ) else {
            throw GitHubAuthenticationTransportError.authorizationFailure(failure)
        }
        switch failure {
        case let .samlAuthorizationRequired(authorizeURL):
            let coordinator = GitHubSAMLRetryCoordinator()
            _ = try await coordinator.offer(for: failure, credentialSource: source)
            guard confirmRecovery(
                title: "Organization Authorization Required",
                message: "Authorize this Credential for the organization in your browser, then retry.",
                action: "Authorize in Browser"
            ) else {
                _ = try await coordinator.decline()
                return nil
            }
            _ = NSWorkspace.shared.open(authorizeURL)
            guard confirmRecovery(
                title: "Retry Organization Access?",
                message: "After GitHub confirms authorization, retry the original Add Account request.",
                action: "Retry"
            ) else {
                _ = try await coordinator.decline()
                return nil
            }
            return try await coordinator.retry(retry)
        case let .installationConfigurationRequired(configurationURL):
            guard confirmRecovery(
                title: "Repository Access Required",
                message: "Configure the GitHub App installation or repository selection, then retry.",
                action: "Configure Repository Access"
            ) else {
                return nil
            }
            _ = NSWorkspace.shared.open(configurationURL)
            guard confirmRecovery(
                title: "Retry Repository Access?",
                message: "After GitHub confirms repository access, retry the original request.",
                action: "Retry"
            ) else {
                return nil
            }
            return try await retry()
        case .badCredentials, .authorizationDenied:
            throw GitHubAuthenticationTransportError.authorizationFailure(failure)
        }
    }

    private func confirmRecovery(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.alertStyle = .warning
        alert.runModal()
        statusLabel.stringValue = error.localizedDescription
        logger.error("Forge Account UI operation failed type=\(String(describing: type(of: error)), privacy: .public)")
    }

    private func statusText(_ expiry: ForgeAccountPreferencesRow.Expiry) -> String {
        let date: Date
        let prefix: String
        switch expiry {
        case .doesNotExpire:
            return "Current"
        case let .current(value):
            date = value
            prefix = "Expires"
        case let .expiresSoon(value):
            date = value
            prefix = "Expires soon"
        case let .expired(value):
            date = value
            prefix = "Expired"
        }
        return "\(prefix) \(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short))"
    }

    private static func wait(until date: Date) async throws {
        let seconds = max(0, date.timeIntervalSinceNow)
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(min(seconds, 60) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private static func pollingIndex(_ preset: ForgeAttentionPollingPreset) -> Int {
        switch preset {
        case .frequent: 0
        case .balanced: 1
        case .conservative: 2
        case .manual: 3
        }
    }

    private static func alertTitle(_ category: ForgeAttentionAlertCategory) -> String {
        switch category {
        case .reviewRequests: "Review requests"
        case .mentionsAndReplies: "Mentions and replies"
        case .assignments: "Assignments"
        case .failedChecksOnAuthoredPullRequests: "Failed checks on my Pull Requests"
        }
    }
}

@MainActor
private final class ForgeAttentionWatchBotButton: NSButton {
    let key: ForgeWatchedRepositoryKey

    init(key: ForgeWatchedRepositoryKey) {
        self.key = key
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private nonisolated extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
