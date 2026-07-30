import ForgeKit
import Foundation
import GitHubForgeAdapter
import Network
import OSLog

// swift6-safety-justification: NWPathMonitor owns its thread-safe state; immutable fields are installed before start.
@MainActor
private final class ForgeApplicationNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.gitx.gitx.forge-application-network-path")
    private let handler: @Sendable (Bool) -> Void

    init(handler: @escaping @Sendable (Bool) -> Void) {
        self.handler = handler
    }

    func start() {
        monitor.pathUpdateHandler = { [handler] path in
            handler(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
        monitor.pathUpdateHandler = nil
    }
}

nonisolated struct ForgeApplicationRefreshRegistration: Hashable, Sendable {
    fileprivate let id: UUID
}

actor ForgeApplicationRefreshCoordinator {
    typealias RefreshOperation = @Sendable (ForgeRefreshReason) async -> Void
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    typealias TargetResolver = @Sendable (ForgeRepositoryBinding) async -> ForgeRefreshTarget?
    typealias BackgroundRefresh = @Sendable (ForgeRefreshTarget, ForgeRepositoryBinding, ForgeRefreshReason) async -> Void

    private struct Client: Sendable {
        var activity: ForgeOverlayActivity
        let refresh: RefreshOperation
    }

    private let bindingProvider: (any ForgeRepositoryBindingProviding)?
    private let resolveTarget: TargetResolver
    private let backgroundRefresh: BackgroundRefresh
    private let sleep: Sleep
    private var persistedBindings: [ForgeRefreshTarget: ForgeRepositoryBinding] = [:]
    private var clients: [ForgeRefreshTarget: [UUID: Client]] = [:]
    private var registrationTargets: [UUID: ForgeRefreshTarget] = [:]
    private var timers: [ForgeRefreshTarget: Task<Void, Never>] = [:]
    private var refreshTasks: [ForgeRefreshTarget: Task<Void, Never>] = [:]
    private var pendingReasons: [ForgeRefreshTarget: ForgeRefreshReason] = [:]
    private var networkMonitor: ForgeApplicationNetworkMonitor?
    private var lastNetworkAvailable: Bool?
    private var isStarted = false
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeRefreshCoordinator")

    init(
        bindingProvider: (any ForgeRepositoryBindingProviding)?,
        resolveTarget: @escaping TargetResolver,
        backgroundRefresh: @escaping BackgroundRefresh,
        sleep: @escaping Sleep = { interval in
            try await Task.sleep(for: .seconds(interval))
        }
    ) {
        self.bindingProvider = bindingProvider
        self.resolveTarget = resolveTarget
        self.backgroundRefresh = backgroundRefresh
        self.sleep = sleep
    }

    static func makeDefault(
        dataAvailability: ForgeApplicationDataAvailability,
        bindingCleaner: any ForgeRepositoryBindingCleaning,
        accountStore: ForgeAccountStore,
        adapterFactory: ForgeGitHubReadAdapterFactory,
        cooldowns: ForgeCredentialCooldownRegistry
    ) async -> ForgeApplicationRefreshCoordinator {
        let boundRefresher = ForgeBoundRepositoryOverlayRefresher(
            database: dataAvailability.database,
            accountStore: accountStore,
            adapterFactory: adapterFactory,
            cooldowns: cooldowns
        )
        let coordinator = ForgeApplicationRefreshCoordinator(
            bindingProvider: bindingCleaner as? any ForgeRepositoryBindingProviding,
            resolveTarget: { binding in
                guard let accountID = binding.preferredAccount else {
                    return nil
                }
                do {
                    guard let envelope = try await accountStore.credential(for: accountID),
                          envelope.account.id == accountID,
                          envelope.account.currentCredential.reference.accountID.forge == binding.primaryRepository.forge
                    else {
                        return nil
                    }
                    return try ForgeRefreshTarget(
                        authentication: .credential(envelope.account.currentCredential.reference),
                        repository: binding.primaryRepository
                    )
                } catch {
                    return nil
                }
            },
            backgroundRefresh: { target, binding, reason in
                await boundRefresher.refresh(target: target, binding: binding, reason: reason)
            }
        )
        let networkMonitor = await ForgeApplicationNetworkMonitor { [weak coordinator] available in
            Task {
                await coordinator?.networkAvailabilityDidChange(available)
            }
        }
        await coordinator.installNetworkMonitor(networkMonitor)
        await coordinator.start()
        return coordinator
    }

    private func installNetworkMonitor(_ monitor: ForgeApplicationNetworkMonitor) async {
        await networkMonitor?.cancel()
        networkMonitor = monitor
        await monitor.start()
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        await synchronizeBoundRepositories()
        logger.notice("Started application Forge refresh coordinator")
    }

    func synchronizeBoundRepositories() async {
        let bindings = bindingProvider?.forgeRepositoryBindings() ?? []
        var discovered: [ForgeRefreshTarget: ForgeRepositoryBinding] = [:]
        for binding in bindings {
            guard let target = await resolveTarget(binding),
                  ForgeRefreshPolicy.mayScheduleAutomatically(authentication: target.authentication)
            else {
                continue
            }
            discovered[target] = binding
        }
        let removed = Set(persistedBindings.keys).subtracting(discovered.keys)
        persistedBindings = discovered
        for target in removed where clients[target]?.isEmpty != false {
            cancelTarget(target)
        }
        for target in allTargets() {
            schedule(target)
        }
        logger.info("Synchronized bound Forge repositories count=\(discovered.count, privacy: .public)")
    }

    func register(
        binding: ForgeRepositoryBinding,
        authentication: ForgeRefreshAuthentication,
        activity: ForgeOverlayActivity,
        refresh: @escaping RefreshOperation
    ) async -> ForgeApplicationRefreshRegistration? {
        guard ForgeRefreshPolicy.mayScheduleAutomatically(authentication: authentication),
              let target = try? ForgeRefreshTarget(
                  authentication: authentication,
                  repository: binding.primaryRepository
              )
        else {
            return nil
        }
        let registration = ForgeApplicationRefreshRegistration(id: UUID())
        clients[target, default: [:]][registration.id] = Client(activity: activity, refresh: refresh)
        registrationTargets[registration.id] = target
        persistedBindings[target] = persistedBindings[target] ?? binding
        schedule(target)
        logger.debug("Registered open Forge overlay with application refresh coordinator")
        return registration
    }

    func updateActivity(
        _ activity: ForgeOverlayActivity,
        registration: ForgeApplicationRefreshRegistration
    ) {
        guard let target = registrationTargets[registration.id],
              var targetClients = clients[target],
              var client = targetClients[registration.id]
        else {
            return
        }
        client.activity = activity
        targetClients[registration.id] = client
        clients[target] = targetClients
        schedule(target)
    }

    func requestRefresh(
        registration: ForgeApplicationRefreshRegistration,
        reason: ForgeRefreshReason
    ) {
        guard let target = registrationTargets[registration.id] else { return }
        enqueueRefresh(target, reason: reason, preferredClient: registration.id)
    }

    func requestNetworkRestorationRefresh() {
        for target in allTargets() {
            enqueueRefresh(target, reason: .networkRestored, preferredClient: nil)
            schedule(target)
        }
        logger.notice("Coalesced Forge refresh targets after network restoration")
    }

    private func networkAvailabilityDidChange(_ available: Bool) {
        let previous = lastNetworkAvailable
        lastNetworkAvailable = available
        guard available, previous == false else { return }
        requestNetworkRestorationRefresh()
    }

    func unregister(_ registration: ForgeApplicationRefreshRegistration) {
        guard let target = registrationTargets.removeValue(forKey: registration.id) else { return }
        clients[target]?.removeValue(forKey: registration.id)
        if clients[target]?.isEmpty == true {
            clients.removeValue(forKey: target)
        }
        if persistedBindings[target] == nil {
            cancelTarget(target)
        } else {
            schedule(target)
        }
    }

    func invalidate() async {
        timers.values.forEach { $0.cancel() }
        refreshTasks.values.forEach { $0.cancel() }
        await networkMonitor?.cancel()
        timers.removeAll()
        refreshTasks.removeAll()
        pendingReasons.removeAll()
        clients.removeAll()
        registrationTargets.removeAll()
        networkMonitor = nil
        lastNetworkAvailable = nil
        isStarted = false
    }

    func interval(for target: ForgeRefreshTarget) -> TimeInterval? {
        guard persistedBindings[target] != nil || clients[target]?.isEmpty == false else { return nil }
        let activities = clients[target]?.values.map(\.activity) ?? []
        let activity = activities.min(by: { Self.rank($0) < Self.rank($1) }) ?? .otherBoundRepository
        return ForgeRefreshPolicy.interval(for: activity)
    }

    private func allTargets() -> Set<ForgeRefreshTarget> {
        Set(persistedBindings.keys).union(clients.keys)
    }

    private func schedule(_ target: ForgeRefreshTarget) {
        timers[target]?.cancel()
        timers[target] = nil
        guard isStarted, let interval = interval(for: target) else { return }
        let sleep = sleep
        timers[target] = Task { [weak self] in
            do {
                try await sleep(interval)
                guard !Task.isCancelled else { return }
                await self?.timerFired(target)
            } catch {
                return
            }
        }
    }

    private func timerFired(_ target: ForgeRefreshTarget) async {
        timers[target] = nil
        if clients[target]?.isEmpty != false {
            await synchronizeBoundRepositories()
            guard interval(for: target) != nil else { return }
        }
        enqueueRefresh(target, reason: .scheduledOverlay, preferredClient: nil)
        schedule(target)
    }

    private func enqueueRefresh(
        _ target: ForgeRefreshTarget,
        reason: ForgeRefreshReason,
        preferredClient: UUID?
    ) {
        guard refreshTasks[target] == nil else {
            pendingReasons[target] = reason
            return
        }
        let operation = refreshOperation(for: target, preferredClient: preferredClient)
        refreshTasks[target] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await operation(reason)
            guard !Task.isCancelled else { return }
            await self?.refreshFinished(target)
        }
    }

    private func refreshOperation(
        for target: ForgeRefreshTarget,
        preferredClient: UUID?
    ) -> RefreshOperation {
        if let preferredClient, let client = clients[target]?[preferredClient] {
            return client.refresh
        }
        if let client = clients[target]?.sorted(by: { lhs, rhs in
            let leftRank = Self.rank(lhs.value.activity)
            let rightRank = Self.rank(rhs.value.activity)
            return leftRank == rightRank
                ? lhs.key.uuidString < rhs.key.uuidString
                : leftRank < rightRank
        }).first?.value {
            return client.refresh
        }
        guard let binding = persistedBindings[target] else { return { _ in } }
        let backgroundRefresh = backgroundRefresh
        return { reason in
            await backgroundRefresh(target, binding, reason)
        }
    }

    private func refreshFinished(_ target: ForgeRefreshTarget) {
        refreshTasks[target] = nil
        guard let pending = pendingReasons.removeValue(forKey: target) else { return }
        enqueueRefresh(target, reason: pending, preferredClient: nil)
    }

    private func cancelTarget(_ target: ForgeRefreshTarget) {
        timers.removeValue(forKey: target)?.cancel()
        refreshTasks.removeValue(forKey: target)?.cancel()
        pendingReasons.removeValue(forKey: target)
    }

    private static func rank(_ activity: ForgeOverlayActivity) -> Int {
        switch activity {
        case .affectedViewActive: 0
        case .otherOpenRepository: 1
        case .otherBoundRepository: 2
        }
    }
}
