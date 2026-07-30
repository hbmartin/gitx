import AppKit
import ForgeKit
import Foundation
import GitHubForgeAdapter
import OSLog

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
}

actor ForgeAccountsService: ForgeAccountsClient {
    typealias CredentialIDProvider = @Sendable (GitHubPersonalAccessTokenKind, String?) throws -> ForgeCredentialID

    private let services: ForgeApplicationServices
    private let configuration: GitHubAppDeviceFlowConfiguration?
    private let authenticationTransport: GitHubAuthenticationTransport
    private let credentialIDProvider: CredentialIDProvider
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeAccounts")
    private var deviceFlowCoordinator: GitHubDeviceFlowCoordinator?
    private var refreshCoordinators: [ForgeAccountID: GitHubCredentialRefreshCoordinator] = [:]

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
                try await refreshCredentialIfNeeded(account, at: date)
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
            )
        )
        await ForgeAvatarLoader.shared.restoreAfterAccountAddition(account.id)
        self.deviceFlowCoordinator = nil
        logger.notice(
            "GitHub App Forge Account added account=\(account.id.value, privacy: .private(mask: .hash))"
        )
        return account
    }

    func addUsingExplicitGitHubCLIBrokerage() async throws -> ForgeAccount {
        let account = try await services.addAccountCoordinator.addUsingExplicitGitHubCLIBrokerage()
        logger.notice(
            "Explicit GitHub CLI Forge Account addition completed account=\(account.id.value, privacy: .private(mask: .hash))"
        )
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
        let account = try await services.addAccountCoordinator.addPersonalAccessToken(
            accountID: introspection.accountID,
            login: introspection.login,
            credentialID: credentialIDProvider(acquisition.kind, acquisition.label),
            kind: kind,
            token: acquisition.token,
            expiresAt: acquisition.expiresAt
        )
        logger.notice(
            "GitHub personal access Credential added kind=\(acquisition.kind.rawValue, privacy: .public) account=\(account.id.value, privacy: .private(mask: .hash))"
        )
        return account
    }

    func removeAccount(_ accountID: ForgeAccountID) async throws {
        try await services.removalCoordinator.removeAccount(accountID)
        refreshCoordinators[accountID] = nil
        logger.notice(
            "Forge Account removal completed account=\(accountID.value, privacy: .private(mask: .hash))"
        )
    }

    func githubApplicationInstallationURL() throws -> URL {
        guard let configuration else {
            throw ForgeAccountsError.githubApplicationNotConfigured
        }
        return configuration.newInstallationURL
    }

    private func refreshCredentialIfNeeded(_ account: ForgeAccount, at date: Date) async throws {
        guard let configuration,
              let envelope = try await services.accountStore.credential(for: account.id),
              let accessExpiresAt = account.currentCredential.expiresAt,
              let refreshExpiresAt = envelope.secrets.refreshTokenExpiresAt,
              let refreshToken = envelope.secrets.withUnsafeRefreshTokenBytes({ Data($0) })
        else {
            return
        }
        let credential = try GitHubRotatingUserCredential(
            accessToken: GitHubSecret(
                utf8Bytes: envelope.secrets.withUnsafeAccessTokenBytes { Data($0) }
            ),
            accessTokenExpiresAt: accessExpiresAt,
            refreshToken: GitHubSecret(utf8Bytes: refreshToken),
            refreshTokenExpiresAt: refreshExpiresAt
        )
        let coordinator: GitHubCredentialRefreshCoordinator
        if let current = refreshCoordinators[account.id] {
            coordinator = current
        } else {
            let created = GitHubCredentialRefreshCoordinator(configuration: configuration)
            refreshCoordinators[account.id] = created
            coordinator = created
        }
        switch try await coordinator.refreshIfNeeded(
            credential,
            at: date,
            minimumValidity: 5 * 60
        ) {
        case .current, .reauthorizationRequired:
            return
        case let .refreshed(rotated):
            try await services.accountStore.rotateCredential(
                expectedReference: account.currentCredential.reference,
                expiresAt: rotated.accessTokenExpiresAt,
                secrets: ForgeCredentialSecretMaterial(
                    accessToken: rotated.accessToken.withUnsafeUTF8Bytes { Data($0) },
                    refreshToken: rotated.refreshToken.withUnsafeUTF8Bytes { Data($0) },
                    refreshTokenExpiresAt: rotated.refreshTokenExpiresAt
                )
            )
            logger.notice(
                "GitHub App Credential refresh token rotated account=\(account.id.value, privacy: .private(mask: .hash))"
            )
        }
    }
}

@MainActor
final class ForgeAccountsPreferencesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    typealias ClientFactory = @Sendable () async throws -> any ForgeAccountsClient

    private let clientFactory: ClientFactory
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeAccountsPreferences")
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Loading Forge Accounts…")
    private let signInButton = NSButton(title: "Sign In with GitHub App…", target: nil, action: nil)
    private let alternatives = NSPopUpButton()
    private let removeButton = NSButton(title: "Remove Account…", target: nil, action: nil)
    private let configureButton = NSButton(title: "Configure Repository Access…", target: nil, action: nil)
    private var client: (any ForgeAccountsClient)?
    private var rows: [ForgeAccountPreferencesRow] = []
    private var installationURL: URL?
    private var didLoad = false
    private var operationTask: Task<Void, Never>?

    init(clientFactory: @escaping ClientFactory) {
        self.clientFactory = clientFactory
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 510))
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

    func numberOfRows(in _: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
        heightAnchor.constraint(greaterThanOrEqualToConstant: 510).isActive = true

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
        scrollView.heightAnchor.constraint(equalToConstant: 245).isActive = true

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

        let stack = NSStackView(views: [heading, detail, scrollView, actions, permissions, statusLabel])
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
        tableView.reloadData()
        if !rows.isEmpty, tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        statusLabel.stringValue = status ?? (rows.isEmpty
            ? "No GitHub.com Forge Accounts are configured."
            : "\(rows.count) GitHub.com Forge Account\(rows.count == 1 ? "" : "s") configured.")
        updateButtonState()
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
        let alert = NSAlert()
        alert.messageText = kind == .fineGrained
            ? "Add Fine-Grained Personal Access Token"
            : "Add Classic Personal Access Token"
        alert.informativeText = "GitX validates the Credential with GitHub and stores it only in Keychain."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Add Account")
        alert.addButton(withTitle: "Cancel")
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
}

private nonisolated extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
