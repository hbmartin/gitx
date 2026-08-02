import ForgeKit
import Foundation
import GitHubForgeAdapter
import OSLog // swiftlint:disable:this unused_import
import UserNotifications

private nonisolated struct ForgeAttentionNotificationPayload: Codable, Sendable {
    let itemID: ForgeAttentionItemID
}

/// The one notification boundary used by every Attention coordinator. It
/// preserves the app's existing notification delegate through a small
/// forwarding bridge and registers only the two accepted actions.
actor ForgeAttentionNotificationDelivery: ForgeAttentionAlertDelivering {
    static let shared = ForgeAttentionNotificationDelivery()

    fileprivate static let categoryIdentifier = "PBForgeAttention"
    fileprivate static let openActionIdentifier = "PBForgeAttention.Open"
    fileprivate static let markSeenActionIdentifier = "PBForgeAttention.MarkSeen"
    private var isInstalled = false

    func authorizationStatus() async -> ForgeAttentionSystemAuthorization {
        await installIfNeeded()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        await installIfNeeded()
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func deliver(_ alert: ForgeAttentionAlert) async {
        await installIfNeeded()
        guard let payload = try? JSONEncoder().encode(ForgeAttentionNotificationPayload(itemID: alert.itemID)) else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = Self.title(alert.category)
        content.body = "GitX found a current item that needs your attention."
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["payload": payload.base64EncodedString()]
        let identifier = "forge-attention-\(payload.base64EncodedString())"
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
        } catch {
            // The current-state row remains available even when macOS cannot
            // accept a notification request.
        }
    }

    private func installIfNeeded() async {
        guard !isInstalled else { return }
        isInstalled = true
        let center = UNUserNotificationCenter.current()
        let actions = [
            UNNotificationAction(
                identifier: Self.openActionIdentifier,
                title: "Open",
                options: [.foreground]
            ),
            UNNotificationAction(
                identifier: Self.markSeenActionIdentifier,
                title: "Mark Seen",
                options: []
            ),
        ]
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
        var categories = await center.notificationCategories()
        categories.insert(category)
        center.setNotificationCategories(categories)
        await MainActor.run {
            ForgeAttentionNotificationDelegateBridge.shared.install(on: center)
        }
    }

    private static func title(_ category: ForgeAttentionAlertCategory) -> String {
        switch category {
        case .reviewRequests: "Review Requested"
        case .mentionsAndReplies: "Mention or Reply"
        case .assignments: "Assignment"
        case .failedChecksOnAuthoredPullRequests: "Pull Request Check Failed"
        }
    }

    nonisolated static func action(
        for identifier: String
    ) -> ForgeAttentionAlertAction? {
        switch identifier {
        case openActionIdentifier, UNNotificationDefaultActionIdentifier: .open
        case markSeenActionIdentifier: .markSeen
        default: nil
        }
    }

    fileprivate nonisolated static func payload(
        from response: UNNotificationResponse
    ) -> ForgeAttentionNotificationPayload? {
        guard response.notification.request.content.categoryIdentifier == categoryIdentifier,
              let value = response.notification.request.content.userInfo["payload"] as? String,
              let data = Data(base64Encoded: value)
        else { return nil }
        return try? JSONDecoder().decode(ForgeAttentionNotificationPayload.self, from: data)
    }
}

enum ForgeAttentionNotificationDelegateCompletionForwarding {
    nonisolated static func forwardPresentation(
        _ forwarding: (@escaping @Sendable (UNNotificationPresentationOptions) -> Void) -> Void?,
        completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        if forwarding(completionHandler) == nil {
            completionHandler([])
        }
    }

    nonisolated static func forwardResponse(
        _ forwarding: (@escaping @Sendable () -> Void) -> Void?,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        if forwarding(completionHandler) == nil {
            completionHandler()
        }
    }
}

@MainActor
private final class ForgeAttentionNotificationDelegateBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForgeAttentionNotificationDelegateBridge()

    // UserNotifications calls these delegate methods outside MainActor. The delegate is
    // installed once on MainActor before callbacks begin, then is only read afterward.
    // swift6-safety-justification: The weak reference only preserves that callback chain.
    private nonisolated(unsafe) weak var previousDelegate: (any UNUserNotificationCenterDelegate)?
    private var isInstalled = false

    func install(on center: UNUserNotificationCenter) {
        guard !isInstalled else { return }
        previousDelegate = center.delegate
        center.delegate = self
        isInstalled = true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        guard notification.request.content.categoryIdentifier != ForgeAttentionNotificationDelivery.categoryIdentifier else {
            completionHandler([.banner, .sound])
            return
        }
        ForgeAttentionNotificationDelegateCompletionForwarding.forwardPresentation(
            { handler in
                previousDelegate?.userNotificationCenter?(
                    center,
                    willPresent: notification,
                    withCompletionHandler: handler
                )
            },
            completionHandler: completionHandler
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        if let payload = ForgeAttentionNotificationDelivery.payload(from: response),
           let action = ForgeAttentionNotificationDelivery.action(for: response.actionIdentifier)
        {
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .forgeAttentionAlertAction,
                    object: nil,
                    userInfo: [
                        RepositoryAttentionNotificationKey.itemID: payload.itemID,
                        RepositoryAttentionNotificationKey.action: action,
                    ]
                )
                completionHandler()
            }
            return
        }
        ForgeAttentionNotificationDelegateCompletionForwarding.forwardResponse(
            { handler in
                previousDelegate?.userNotificationCenter?(
                    center,
                    didReceive: response,
                    withCompletionHandler: handler
                )
            },
            completionHandler: completionHandler
        )
    }
}

enum RepositoryAttentionSessionError: Error, LocalizedError {
    case databaseUnavailable

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            "Forge data is unavailable for this session. Local Git remains available."
        }
    }
}

@MainActor
protocol RepositoryAttentionServing: AnyObject {
    var account: ForgeAccount { get }
    var repositoryIdentity: ForgeRepositoryIdentity { get }
    var lastRefreshErrorDescription: String? { get }
    var lastRefreshError: Error? { get }

    func entries(state: ForgeAttentionViewState) async throws -> [ForgeAttentionInboxEntry]
    func markOpen(_ itemID: ForgeAttentionItemID) async throws
    func markUnseen(_ itemID: ForgeAttentionItemID) async throws
    func markAllSeen(state: ForgeAttentionViewState) async throws
    func refreshNow() async
    func makeReadService(for repository: ForgeRepositoryIdentity) throws -> ForgeReadSurfaceServing
}

extension RepositoryAttentionServing {
    var lastRefreshError: Error? {
        nil
    }
}

/// One repository-window session participates in the account-wide durable
/// inbox. The scheduler still considers every watched repository for that
/// account, while this window identifies its repository as active/open.
@MainActor
final class RepositoryAttentionSession: NSObject, RepositoryAttentionServing {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "AttentionSession")
    private static var sessionsByAccount: [ForgeAccountID: [WeakRepositoryAttentionSession]] = [:]

    let account: ForgeAccount
    let repositoryIdentity: ForgeRepositoryIdentity
    private weak var repositoryObject: PBGitRepository?
    private let services: ForgeApplicationServices
    private let persistence: ForgeSQLiteAttentionPersistence
    private let watchedKey: ForgeWatchedRepositoryKey
    private var coordinator: ForgeAttentionInboxCoordinator
    private var pollingTask: Task<Void, Never>?
    private var didStart = false
    private var didEnrollOpenedRepository = false
    private(set) var lastRefreshErrorDescription: String?
    private(set) var lastRefreshError: Error?
    var onOpenAttentionItem: ((ForgeAttentionItemID) -> Void)?

    init(
        account: ForgeAccount,
        repositoryIdentity: ForgeRepositoryIdentity,
        repositoryObject: PBGitRepository,
        services: ForgeApplicationServices
    ) throws {
        guard let database = services.database else {
            throw RepositoryAttentionSessionError.databaseUnavailable
        }
        self.account = account
        self.repositoryIdentity = repositoryIdentity
        self.repositoryObject = repositoryObject
        self.services = services
        persistence = ForgeSQLiteAttentionPersistence(store: database)
        watchedKey = try ForgeWatchedRepositoryKey(
            accountID: account.id,
            repository: repositoryIdentity
        )
        coordinator = try Self.makeCoordinator(
            account: account,
            services: services,
            persistence: persistence
        )
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged(_:)),
            name: .forgeAttentionPreferencesDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(alertAction(_:)),
            name: .forgeAttentionAlertAction,
            object: nil
        )
    }

    deinit {
        pollingTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        Self.register(self)
        beginPollingCycle(shouldEnrollOpenedRepository: !didEnrollOpenedRepository)
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        didStart = false
        Self.unregister(self)
    }

    #if DEBUG
        func waitForCurrentPollingCycleForProductProof() async {
            await pollingTask?.value
        }
    #endif

    func entries(state: ForgeAttentionViewState) async throws -> [ForgeAttentionInboxEntry] {
        try await persistence.cachedEntries(
            query: ForgeAttentionInboxQuery(
                accountID: account.id,
                currentRepository: repositoryIdentity,
                state: state
            ),
            at: Date()
        )
    }

    func markOpen(_ itemID: ForgeAttentionItemID) async throws {
        _ = try await persistence.open(itemID, at: Date())
        try await publishChange()
    }

    func markUnseen(_ itemID: ForgeAttentionItemID) async throws {
        _ = try await persistence.markUnseen(itemID, at: Date())
        try await publishChange()
    }

    func markAllSeen(state: ForgeAttentionViewState) async throws {
        let scope: ForgeAttentionScope = state.scope == .all
            ? .all(accountID: account.id)
            : .currentRepository(watchedKey)
        _ = try await persistence.markAllSeen(
            query: ForgeAttentionQuery(scope: scope, visibility: state.visibility),
            at: Date()
        )
        try await publishChange()
    }

    func refreshNow() async {
        // A cancelled replacement refresh must not leave an authorization
        // failure from an older attempt visible to the view.
        lastRefreshError = nil
        lastRefreshErrorDescription = nil
        var refreshFailure: (any Error)?
        do {
            _ = try await coordinator.refreshAllWatched(accountID: account.id)
        } catch is CancellationError {
            return
        } catch {
            refreshFailure = error
        }

        var publishFailure: (any Error)?
        do {
            try await publishChange()
        } catch is CancellationError {
            if refreshFailure == nil {
                return
            }
        } catch {
            publishFailure = error
        }

        if let failure = refreshFailure ?? publishFailure {
            lastRefreshError = failure
            lastRefreshErrorDescription = failure.localizedDescription
            Self.logger.error(
                "Manual Attention refresh failed type=\(String(describing: type(of: failure)), privacy: .public)"
            )
        } else {
            lastRefreshError = nil
            lastRefreshErrorDescription = nil
        }
    }

    func makeReadService(for repository: ForgeRepositoryIdentity) throws -> ForgeReadSurfaceServing {
        let adapter = try services.githubReadAdapterFactory.makeAdapter(
            for: account.currentCredential.reference
        )
        return ForgeGitHubReadSurfaceService(repository: repository, adapter: adapter)
    }

    private static func makeCoordinator(
        account: ForgeAccount,
        services: ForgeApplicationServices,
        persistence: ForgeSQLiteAttentionPersistence
    ) throws -> ForgeAttentionInboxCoordinator {
        let adapter = try services.githubReadAdapterFactory.makeAdapter(
            for: account.currentCredential.reference
        )
        return ForgeAttentionInboxCoordinator(
            persistence: persistence,
            fetcher: GitHubAttentionSnapshotFetcher(adapter: adapter),
            alertDelivery: ForgeAttentionNotificationDelivery.shared,
            attentionPolicy: ApplicationSettings.attentionPolicy,
            enabledAlertCategories: ApplicationSettings.attentionAlertCategories,
            pollingPreset: ApplicationSettings.attentionPollingPreset
        )
    }

    private func beginPollingCycle(shouldEnrollOpenedRepository: Bool) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            if shouldEnrollOpenedRepository, let session = self {
                await session.enrollOpenedRepositoryForPolling()
            }
            guard ApplicationSettings.attentionPollingPreset != .manual else { return }
            while !Task.isCancelled {
                // Reacquire the session only for one bounded poll. The task
                // must not keep its owner alive while it sleeps indefinitely.
                if let session = self {
                    await session.refreshScheduledAttention()
                } else {
                    return
                }
                let interval = ApplicationSettings.attentionPollingPreset.activeInterval ?? 60
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(interval, 1) * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    private func enrollOpenedRepositoryForPolling() async {
        do {
            try await enrollWatchIfNeeded()
            didEnrollOpenedRepository = true
            try await publishChange()
        } catch {
            lastRefreshErrorDescription = error.localizedDescription
        }
    }

    private func refreshScheduledAttention() async {
        do {
            let reconciliation = try await coordinator.refreshNextDue(
                accountID: account.id,
                activeOrOpenRepositories: [watchedKey],
                at: Date()
            )
            if reconciliation != nil {
                lastRefreshErrorDescription = nil
                try await publishChange()
            }
        } catch is CancellationError {
            return
        } catch {
            lastRefreshErrorDescription = error.localizedDescription
            Self.logger.error(
                "Scheduled Attention refresh failed type=\(String(describing: type(of: error)), privacy: .public)"
            )
            NotificationCenter.default.post(
                name: .forgeAttentionInboxDidChange,
                object: repositoryObject
            )
        }
    }

    private func enrollWatchIfNeeded() async throws {
        let watches = try await persistence.watchedRepositories(accountID: account.id)
        guard !watches.contains(where: { $0.key == watchedKey }) else { return }
        try await persistence.save(ForgeWatchedRepository(
            key: watchedKey,
            addedAt: Date(),
            source: .repositoryOpened
        ))
        Self.logger.notice("Added opened repository to the Attention watch set")
    }

    private func publishChange() async throws {
        let state = ForgeAttentionViewState(
            scope: .all,
            visibility: .unseenOnly,
            sortOrder: .newestFirst
        )
        let unseen = try await persistence.cachedEntries(
            query: ForgeAttentionInboxQuery(
                accountID: account.id,
                currentRepository: repositoryIdentity,
                state: state
            ),
            at: Date()
        ).count
        NotificationCenter.default.post(
            name: .forgeAttentionInboxDidChange,
            object: repositoryObject
        )
        NotificationCenter.default.post(
            name: .repositoryAttentionUnseenDidChange,
            object: repositoryObject,
            userInfo: [RepositoryAttentionNotificationKey.count: unseen]
        )
    }

    @objc private func preferencesChanged(_: Notification) {
        do {
            coordinator = try Self.makeCoordinator(
                account: account,
                services: services,
                persistence: persistence
            )
            if didStart {
                beginPollingCycle(shouldEnrollOpenedRepository: !didEnrollOpenedRepository)
            }
        } catch {
            lastRefreshErrorDescription = error.localizedDescription
        }
    }

    @objc private func alertAction(_ notification: Notification) {
        guard let itemID = notification.userInfo?[RepositoryAttentionNotificationKey.itemID]
            as? ForgeAttentionItemID,
            itemID.accountID == account.id,
            Self.alertHandler(for: account.id) === self,
            let action = notification.userInfo?[RepositoryAttentionNotificationKey.action]
            as? ForgeAttentionAlertAction
        else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let destination = try await self.coordinator.handle(
                    action: action,
                    itemID: itemID,
                    at: Date()
                )
                try await self.publishChange()
                if destination != nil {
                    self.onOpenAttentionItem?(itemID)
                }
            } catch {
                Self.logger.error("Attention alert action failed")
            }
        }
    }

    private static func register(_ session: RepositoryAttentionSession) {
        var sessions = sessionsByAccount[session.account.id] ?? []
        sessions.removeAll { $0.value == nil || $0.value === session }
        sessions.append(WeakRepositoryAttentionSession(session))
        sessionsByAccount[session.account.id] = sessions
    }

    private static func unregister(_ session: RepositoryAttentionSession) {
        var sessions = sessionsByAccount[session.account.id] ?? []
        sessions.removeAll { $0.value == nil || $0.value === session }
        sessionsByAccount[session.account.id] = sessions.isEmpty ? nil : sessions
    }

    private static func alertHandler(for accountID: ForgeAccountID) -> RepositoryAttentionSession? {
        var sessions = sessionsByAccount[accountID] ?? []
        sessions.removeAll { $0.value == nil }
        sessionsByAccount[accountID] = sessions.isEmpty ? nil : sessions
        return sessions.last?.value
    }
}

@MainActor
private final class WeakRepositoryAttentionSession {
    weak var value: RepositoryAttentionSession?

    init(_ value: RepositoryAttentionSession) {
        self.value = value
    }
}
