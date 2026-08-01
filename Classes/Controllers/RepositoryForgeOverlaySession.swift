import ForgeKit
import Foundation
import GitHubForgeAdapter
import Network
import OSLog // swiftlint:disable:this unused_import

nonisolated struct RepositoryForgeOverlaySnapshot<Value: Hashable & Sendable>: Hashable, Sendable {
    let value: Value
    let fetchedAt: Date
    let isPartial: Bool
    let isStale: Bool

    func markingStale() -> RepositoryForgeOverlaySnapshot<Value> {
        RepositoryForgeOverlaySnapshot(
            value: value,
            fetchedAt: fetchedAt,
            isPartial: isPartial,
            isStale: true
        )
    }
}

nonisolated enum RepositoryForgeOverlayValueState<Value: Hashable & Sendable>: Hashable, Sendable {
    case unavailable(ForgeReadUnavailableReason)
    case loading(previous: RepositoryForgeOverlaySnapshot<Value>?)
    case value(RepositoryForgeOverlaySnapshot<Value>)

    var snapshot: RepositoryForgeOverlaySnapshot<Value>? {
        switch self {
        case .unavailable:
            nil
        case let .loading(previous):
            previous
        case let .value(snapshot):
            snapshot
        }
    }
}

nonisolated struct RepositoryForgeRemoteSnapshot<Value: Hashable & Sendable>: Sendable {
    let value: Value
    let fetchedAt: Date
    let completeness: ForgeSnapshotCompleteness
    let cooldownDeadline: Date?

    var isPartial: Bool {
        if case .partial = completeness {
            return true
        }
        return false
    }
}

nonisolated struct RepositoryForgeOverlayRemoteRequest: Hashable, Sendable {
    let reason: ForgeRefreshReason
    let cycle: UInt64
}

nonisolated protocol RepositoryForgeOverlayReading: Sendable {
    func repositoryFacts(
        request: RepositoryForgeOverlayRemoteRequest
    ) async throws -> RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts>
    func historyOverlay(
        commit: ForgeCommitID,
        request: RepositoryForgeOverlayRemoteRequest
    ) async throws -> RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay>
}

actor GitHubRepositoryForgeOverlayReader: RepositoryForgeOverlayReading {
    private let repository: ForgeRepositoryIdentity
    private let adapter: GitHubReadAdapter
    private let now: @Sendable () -> Date

    init(
        repository: ForgeRepositoryIdentity,
        adapter: GitHubReadAdapter,
        now: @escaping @Sendable () -> Date
    ) {
        self.repository = repository
        self.adapter = adapter
        self.now = now
    }

    func repositoryFacts(
        request: RepositoryForgeOverlayRemoteRequest
    ) async throws -> RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts> {
        let result = try await adapter.repositoryFacts(repository: repository)
        let fetchedAt = now()
        return RepositoryForgeRemoteSnapshot(
            value: result.value,
            fetchedAt: fetchedAt,
            completeness: Self.completeness(result.completeness, section: .repositoryFacts),
            cooldownDeadline: result.response.rateLimit.cooldownDeadline(
                statusCode: result.response.statusCode,
                now: fetchedAt
            )
        )
    }

    func historyOverlay(
        commit: ForgeCommitID,
        request: RepositoryForgeOverlayRemoteRequest
    ) async throws -> RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay> {
        let result = try await adapter.historyOverlay(repository: repository, commit: commit)
        let fetchedAt = now()
        return RepositoryForgeRemoteSnapshot(
            value: result.value,
            fetchedAt: fetchedAt,
            completeness: Self.completeness(result.completeness, section: .historyBadges),
            cooldownDeadline: result.response.rateLimit.cooldownDeadline(
                statusCode: result.response.statusCode,
                now: fetchedAt
            )
        )
    }

    private static func completeness(
        _ completeness: GitHubReadCompleteness,
        section: ForgeSnapshotSection
    ) -> ForgeSnapshotCompleteness {
        completeness == .complete ? .complete : .partial(unavailableSections: [section])
    }
}

nonisolated protocol GitHubAnonymousRepositoryReading: Sendable {
    func repositoryFacts(
        repository: ForgeRepositoryIdentity,
        reason: ForgeRefreshReason
    ) async throws -> GitHubAnonymousReadResult<ForgeRepositoryFacts>
    func pullRequests(
        repository: ForgeRepositoryIdentity,
        page cursor: ForgePageCursor?,
        states: Set<ForgePullRequestState>?,
        reason: ForgeRefreshReason
    ) async throws -> GitHubAnonymousReadResult<ForgePage<ForgePullRequestSummary>>
}

extension GitHubAnonymousRESTAdapter: GitHubAnonymousRepositoryReading {}

actor GitHubAnonymousRepositoryForgeOverlayReader: RepositoryForgeOverlayReading {
    private typealias PullRequestResult = GitHubAnonymousReadResult<ForgePage<ForgePullRequestSummary>>

    private let repository: ForgeRepositoryIdentity
    private let adapter: any GitHubAnonymousRepositoryReading
    private var pullRequestCycle: UInt64?
    private var pullRequestTask: Task<PullRequestResult, Error>?

    init(
        repository: ForgeRepositoryIdentity,
        adapter: any GitHubAnonymousRepositoryReading
    ) async {
        self.repository = repository
        self.adapter = adapter
    }

    func repositoryFacts(
        request: RepositoryForgeOverlayRemoteRequest
    ) async throws -> RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts> {
        let result = try await adapter.repositoryFacts(repository: repository, reason: request.reason)
        try requirePublicPartition(result.partition)
        return RepositoryForgeRemoteSnapshot(
            value: result.value,
            fetchedAt: result.fetchedAt,
            completeness: Self.completeness(result.completeness, section: .repositoryFacts),
            cooldownDeadline: result.response.rateLimit.cooldownDeadline(
                statusCode: result.response.statusCode,
                now: result.fetchedAt
            )
        )
    }

    func historyOverlay(
        commit: ForgeCommitID,
        request: RepositoryForgeOverlayRemoteRequest
    ) async throws -> RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay> {
        let result = try await pullRequests(request: request)
        try requirePublicPartition(result.partition)
        let matching = result.value.items.filter { pullRequest in
            guard case let .available(head) = pullRequest.head else { return false }
            return head.commit == commit
        }
        let overlay = try ForgeHistoryOverlay(
            repository: repository,
            commit: commit,
            checkRollup: .unavailable(.authenticationRequired),
            pullRequests: .available(ForgePage(items: matching, totalCount: matching.count))
        )
        return RepositoryForgeRemoteSnapshot(
            value: overlay,
            fetchedAt: result.fetchedAt,
            completeness: .partial(unavailableSections: [.historyBadges]),
            cooldownDeadline: result.response.rateLimit.cooldownDeadline(
                statusCode: result.response.statusCode,
                now: result.fetchedAt
            )
        )
    }

    private func pullRequests(
        request: RepositoryForgeOverlayRemoteRequest
    ) async throws -> PullRequestResult {
        if pullRequestCycle != request.cycle || pullRequestTask == nil {
            pullRequestCycle = request.cycle
            let adapter = adapter
            let repository = repository
            pullRequestTask = Task {
                try await adapter.pullRequests(
                    repository: repository,
                    page: nil,
                    states: nil,
                    reason: request.reason
                )
            }
        }
        guard let pullRequestTask else { throw CancellationError() }
        return try await pullRequestTask.value
    }

    private func requirePublicPartition(_ partition: ForgeRepositoryPartitionKey) throws {
        let expected = try ForgeRepositoryPartitionKey(
            cachePartition: .publicAccess,
            repository: repository
        )
        guard partition == expected else { throw ForgeSQLiteError.mismatchedAccountForge }
    }

    private static func completeness(
        _ completeness: GitHubReadCompleteness,
        section: ForgeSnapshotSection
    ) -> ForgeSnapshotCompleteness {
        completeness == .complete ? .complete : .partial(unavailableSections: [section])
    }
}

nonisolated protocol RepositoryForgeOverlayCaching: Sendable {
    func cachedRepositoryFacts(accessedAt: Date) async throws -> RepositoryForgeOverlaySnapshot<ForgeRepositoryFacts>?
    func putRepositoryFacts(_ snapshot: RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts>) async throws
    func cachedHistoryOverlay(
        commit: ForgeCommitID,
        accessedAt: Date
    ) async throws -> RepositoryForgeOverlaySnapshot<ForgeHistoryOverlay>?
    func putHistoryOverlay(_ snapshot: RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay>) async throws
}

/// Stateless value wrapper; ForgeSQLiteStore remains the serialization owner.
nonisolated struct SQLiteRepositoryForgeOverlayCache: RepositoryForgeOverlayCaching {
    private let database: ForgeSQLiteStore
    private let partition: ForgeRepositoryPartitionKey

    init(database: ForgeSQLiteStore, partition: ForgeRepositoryPartitionKey) {
        self.database = database
        self.partition = partition
    }

    func cachedRepositoryFacts(
        accessedAt: Date
    ) async throws -> RepositoryForgeOverlaySnapshot<ForgeRepositoryFacts>? {
        let key = cacheKey(kind: .repositoryFacts, identity: "repository-facts")
        guard let entry = try await database.cacheEntry(for: .snapshot(key), accessedAt: accessedAt) else {
            return nil
        }
        let facts = try JSONDecoder().decode(ForgeRepositoryFacts.self, from: entry.payload)
        guard facts.repository == partition.repository else { throw ForgeSQLiteError.mismatchedAccountForge }
        return RepositoryForgeOverlaySnapshot(
            value: facts,
            fetchedAt: entry.record.fetchedAt,
            isPartial: Self.isPartial(entry.record.completeness),
            isStale: false
        )
    }

    func putRepositoryFacts(_ snapshot: RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts>) async throws {
        let key = cacheKey(kind: .repositoryFacts, identity: "repository-facts")
        try await put(snapshot, key: key)
    }

    func cachedHistoryOverlay(
        commit: ForgeCommitID,
        accessedAt: Date
    ) async throws -> RepositoryForgeOverlaySnapshot<ForgeHistoryOverlay>? {
        let key = cacheKey(kind: .historyBadges, identity: commit.value)
        guard let entry = try await database.cacheEntry(for: .snapshot(key), accessedAt: accessedAt) else {
            return nil
        }
        let overlay = try JSONDecoder().decode(ForgeHistoryOverlay.self, from: entry.payload)
        guard overlay.repository == partition.repository, overlay.commit == commit else {
            throw ForgeSQLiteError.mismatchedAccountForge
        }
        return RepositoryForgeOverlaySnapshot(
            value: overlay,
            fetchedAt: entry.record.fetchedAt,
            isPartial: Self.isPartial(entry.record.completeness),
            isStale: false
        )
    }

    func putHistoryOverlay(_ snapshot: RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay>) async throws {
        let key = cacheKey(kind: .historyBadges, identity: snapshot.value.commit.value)
        try await put(snapshot, key: key)
    }

    private func put<Value: Encodable & Hashable & Sendable>(
        _ snapshot: RepositoryForgeRemoteSnapshot<Value>,
        key: ForgeCacheRecordKey
    ) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(snapshot.value)
        let record = try ForgeDisposableCacheRecord(
            key: .snapshot(key),
            byteCount: UInt64(payload.count),
            fetchedAt: snapshot.fetchedAt,
            lastAccessedAt: snapshot.fetchedAt,
            completeness: snapshot.completeness
        )
        try await database.putCacheEntry(ForgeSQLiteCacheEntry(record: record, payload: payload))
        _ = try await database.enforceCacheLimits()
    }

    private func cacheKey(kind: ForgeCacheRecordKind, identity: String) -> ForgeCacheRecordKey {
        ForgeCacheRecordKey(repositoryPartition: partition, kind: kind, identity: identity)
    }

    private static func isPartial(_ completeness: ForgeSnapshotCompleteness) -> Bool {
        if case .partial = completeness {
            return true
        }
        return false
    }
}

actor ForgeCredentialCooldownRegistry {
    private let sessionGate: GitHubMutationSessionGate

    init(sessionGate: GitHubMutationSessionGate = GitHubMutationSessionGate()) {
        self.sessionGate = sessionGate
    }

    func activeDeadline(for credential: ForgeCredentialReference, at date: Date) async -> Date? {
        switch await sessionGate.environment(for: credential, at: date) {
        case let .rateLimited(until): until
        case .available, .offline: nil
        }
    }

    func retainedDeadline(for credential: ForgeCredentialReference) async -> Date? {
        await sessionGate.retainedCooldownDeadline(for: credential)
    }

    func retainedState(
        for credential: ForgeCredentialReference,
        at date: Date
    ) async -> GitHubCredentialCooldownState {
        await sessionGate.retainedCooldownState(for: credential, at: date)
    }

    func changes() async -> AsyncStream<ForgeCredentialReference> {
        await sessionGate.cooldownChanges()
    }

    func register(_ cooldown: ForgeCredentialCooldown) async {
        await sessionGate.recordCooldown(for: cooldown.credential, until: cooldown.deadline)
    }
}

nonisolated enum RepositoryForgeOverlayLoadError: Error, Equatable, Sendable {
    case rateLimited(until: Date)
}

nonisolated struct RepositoryForgeOverlayContext: Sendable {
    let access: ForgeStatusAccess
    let authentication: ForgeRefreshAuthentication
    let reader: any RepositoryForgeOverlayReading
    let cache: any RepositoryForgeOverlayCaching
    let cooldowns: ForgeCredentialCooldownRegistry
    let binding: ForgeRepositoryBinding?
    let refreshCoordinator: ForgeApplicationRefreshCoordinator?

    init(
        access: ForgeStatusAccess,
        authentication: ForgeRefreshAuthentication,
        reader: any RepositoryForgeOverlayReading,
        cache: any RepositoryForgeOverlayCaching,
        cooldowns: ForgeCredentialCooldownRegistry,
        binding: ForgeRepositoryBinding? = nil,
        refreshCoordinator: ForgeApplicationRefreshCoordinator? = nil
    ) {
        self.access = access
        self.authentication = authentication
        self.reader = reader
        self.cache = cache
        self.cooldowns = cooldowns
        self.binding = binding
        self.refreshCoordinator = refreshCoordinator
    }

    var credential: ForgeCredentialReference? {
        guard case let .credential(credential) = authentication else { return nil }
        return credential
    }
}

nonisolated enum RepositoryForgeOverlayBootstrap: Sendable {
    case unbound
    case unsupported(ForgeRepositoryIdentity)
    case authenticationRequired(ForgeRepositoryIdentity)
    case recoveryRequired(ForgeRepositoryIdentity, ForgeSQLiteRecoveryCopy)
    case sessionDisabled(ForgeRepositoryIdentity, ForgeSQLiteRecoveryCopy?)
    case unavailable(ForgeRepositoryIdentity)
    case ready(ForgeRepositoryIdentity, RepositoryForgeOverlayContext)
}

actor RepositoryForgeOverlayLoader {
    private let binding: ForgeRepositoryBinding?
    private let services: ForgeApplicationServiceLoader?
    private let now: @Sendable () -> Date
    private var context: RepositoryForgeOverlayContext?
    private var preparedBootstrap: RepositoryForgeOverlayBootstrap?
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeOverlayLoader")

    init(
        binding: ForgeRepositoryBinding?,
        services: ForgeApplicationServiceLoader,
        now: @escaping @Sendable () -> Date
    ) {
        self.binding = binding
        self.services = services
        self.now = now
    }

    init(
        bootstrap: RepositoryForgeOverlayBootstrap,
        now: @escaping @Sendable () -> Date
    ) {
        binding = nil
        services = nil
        self.now = now
        preparedBootstrap = bootstrap
        if case let .ready(_, preparedContext) = bootstrap {
            context = preparedContext
        }
    }

    func prepare() async -> RepositoryForgeOverlayBootstrap {
        if let preparedBootstrap {
            return preparedBootstrap
        }
        guard let binding else { return remember(.unbound) }
        let repository = binding.primaryRepository
        guard Self.isGitHubDotCom(repository) else { return remember(.unsupported(repository)) }
        do {
            guard let services else { return remember(.unavailable(repository)) }
            let applicationServices: ForgeApplicationServices
            switch try await services.overlayServices() {
            case let .enabled(enabledServices):
                applicationServices = enabledServices
            case let .sessionDisabled(copy):
                logger.notice("Kept Forge disabled for this session while preserving local Git access")
                return remember(.sessionDisabled(repository, copy))
            }
            guard let database = applicationServices.database else {
                guard let copy = applicationServices.dataAvailability.recoveryCopy else {
                    return remember(.unavailable(repository))
                }
                return remember(.recoveryRequired(repository, copy))
            }
            guard let accountID = binding.preferredAccount else {
                let partition = try ForgeRepositoryPartitionKey(
                    cachePartition: .publicAccess,
                    repository: repository
                )
                let adapter = GitHubAnonymousRESTAdapter(
                    budget: applicationServices.githubAnonymousRESTBudget,
                    now: now
                )
                let preparedContext = RepositoryForgeOverlayContext(
                    access: .publicAccess,
                    authentication: .publicAccess,
                    reader: await GitHubAnonymousRepositoryForgeOverlayReader(
                        repository: repository,
                        adapter: adapter
                    ),
                    cache: SQLiteRepositoryForgeOverlayCache(database: database, partition: partition),
                    cooldowns: applicationServices.credentialCooldowns,
                    binding: binding,
                    refreshCoordinator: applicationServices.refreshCoordinator
                )
                context = preparedContext
                logger.notice("Prepared public-partition anonymous GitHub repository overlay session")
                return remember(.ready(repository, preparedContext))
            }
            guard let envelope = try await applicationServices.accountStore.credential(for: accountID),
                  envelope.account.id == accountID,
                  envelope.account.currentCredential.reference.accountID.forge == repository.forge
            else {
                return remember(.authenticationRequired(repository))
            }
            let credential = envelope.account.currentCredential.reference
            let adapter = try applicationServices.githubReadAdapterFactory.makeAdapter(for: credential)
            let partition = try ForgeRepositoryPartitionKey(
                cachePartition: .account(accountID),
                repository: repository
            )
            let preparedContext = RepositoryForgeOverlayContext(
                access: .account(login: envelope.account.login),
                authentication: .credential(credential),
                reader: GitHubRepositoryForgeOverlayReader(repository: repository, adapter: adapter, now: now),
                cache: SQLiteRepositoryForgeOverlayCache(database: database, partition: partition),
                cooldowns: applicationServices.credentialCooldowns,
                binding: binding,
                refreshCoordinator: applicationServices.refreshCoordinator
            )
            context = preparedContext
            logger.notice("Prepared exact-account GitHub repository overlay session")
            return remember(.ready(repository, preparedContext))
        } catch {
            logger.error("Could not prepare GitHub repository overlay session")
            return remember(.unavailable(repository))
        }
    }

    func cachedRepositoryFacts() async throws -> RepositoryForgeOverlaySnapshot<ForgeRepositoryFacts>? {
        try await context?.cache.cachedRepositoryFacts(accessedAt: now())
    }

    func refreshRepositoryFacts(
        request: RepositoryForgeOverlayRemoteRequest
    ) async throws -> RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts> {
        guard let context else { throw CancellationError() }
        try requireAllowedRequest(request, context: context)
        try await requireAvailableBudget(context)
        do {
            let snapshot = try await context.reader.repositoryFacts(request: request)
            try await registerAndStore(snapshot, context: context) {
                try await context.cache.putRepositoryFacts(snapshot)
            }
            return snapshot
        } catch {
            throw await classify(error, context: context)
        }
    }

    func cachedHistoryOverlay(
        commit: ForgeCommitID
    ) async throws -> RepositoryForgeOverlaySnapshot<ForgeHistoryOverlay>? {
        try await context?.cache.cachedHistoryOverlay(commit: commit, accessedAt: now())
    }

    func refreshHistoryOverlay(
        commit: ForgeCommitID,
        request: RepositoryForgeOverlayRemoteRequest
    ) async throws -> RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay> {
        guard let context else { throw CancellationError() }
        try requireAllowedRequest(request, context: context)
        try await requireAvailableBudget(context)
        do {
            let snapshot = try await context.reader.historyOverlay(commit: commit, request: request)
            try await registerAndStore(snapshot, context: context) {
                try await context.cache.putHistoryOverlay(snapshot)
            }
            return snapshot
        } catch {
            throw await classify(error, context: context)
        }
    }

    private func requireAvailableBudget(_ context: RepositoryForgeOverlayContext) async throws {
        guard let credential = context.credential else { return }
        if let deadline = await context.cooldowns.activeDeadline(for: credential, at: now()) {
            throw RepositoryForgeOverlayLoadError.rateLimited(until: deadline)
        }
    }

    private func requireAllowedRequest(
        _ request: RepositoryForgeOverlayRemoteRequest,
        context: RepositoryForgeOverlayContext
    ) throws {
        guard case .publicAccess = context.authentication else { return }
        guard ForgeRefreshPolicy.anonymousRequestIsExplicitlyAllowed(for: request.reason) else {
            throw GitHubAnonymousRESTError.explicitRequestRequired
        }
    }

    private func registerAndStore<Value: Hashable & Sendable>(
        _ snapshot: RepositoryForgeRemoteSnapshot<Value>,
        context: RepositoryForgeOverlayContext,
        store: () async throws -> Void
    ) async throws {
        if let deadline = snapshot.cooldownDeadline,
           let credential = context.credential
        {
            await context.cooldowns.register(ForgeCredentialCooldown(
                credential: credential,
                deadline: deadline
            ))
        }
        try await store()
    }

    private func classify(
        _ error: Error,
        context: RepositoryForgeOverlayContext
    ) async -> Error {
        if case let GitHubReadError.rateLimited(metadata) = error {
            let deadline = metadata.rateLimit.cooldownDeadline(
                statusCode: metadata.statusCode,
                now: now()
            ) ?? now().addingTimeInterval(60)
            if let credential = context.credential {
                await context.cooldowns.register(ForgeCredentialCooldown(
                    credential: credential,
                    deadline: deadline
                ))
            }
            return RepositoryForgeOverlayLoadError.rateLimited(until: deadline)
        }
        switch error {
        case let GitHubAnonymousRESTError.cooldown(until):
            return RepositoryForgeOverlayLoadError.rateLimited(until: until)
        case let GitHubAnonymousRESTError.rateLimited(until):
            return RepositoryForgeOverlayLoadError.rateLimited(
                until: until ?? now().addingTimeInterval(60)
            )
        default:
            return error
        }
    }

    private func remember(_ bootstrap: RepositoryForgeOverlayBootstrap) -> RepositoryForgeOverlayBootstrap {
        preparedBootstrap = bootstrap
        return bootstrap
    }

    private static func isGitHubDotCom(_ repository: ForgeRepositoryIdentity) -> Bool {
        let origin = repository.forge.origin.url
        return repository.forge.kind == .github &&
            origin.scheme == "https" &&
            origin.host?.lowercased() == "github.com" &&
            origin.user == nil &&
            origin.password == nil &&
            origin.port == nil
    }
}

actor ForgeBoundRepositoryOverlayRefresher {
    private let database: ForgeSQLiteStore?
    private let accountStore: ForgeAccountStore
    private let adapterFactory: ForgeGitHubReadAdapterFactory
    private let cooldowns: ForgeCredentialCooldownRegistry
    private let now: @Sendable () -> Date
    private var cycles: [ForgeRefreshTarget: UInt64] = [:]
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeBoundRefresh")

    init(
        database: ForgeSQLiteStore?,
        accountStore: ForgeAccountStore,
        adapterFactory: ForgeGitHubReadAdapterFactory,
        cooldowns: ForgeCredentialCooldownRegistry,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.database = database
        self.accountStore = accountStore
        self.adapterFactory = adapterFactory
        self.cooldowns = cooldowns
        self.now = now
    }

    func refresh(
        target: ForgeRefreshTarget,
        binding: ForgeRepositoryBinding,
        reason: ForgeRefreshReason
    ) async {
        guard let database,
              binding.primaryRepository == target.repository,
              case let .credential(credential) = target.authentication,
              binding.preferredAccount == credential.accountID
        else {
            return
        }
        do {
            guard let envelope = try await accountStore.credential(for: credential.accountID),
                  envelope.account.currentCredential.reference == credential
            else {
                return
            }
            let adapter = try adapterFactory.makeAdapter(for: credential)
            let partition = try ForgeRepositoryPartitionKey(
                cachePartition: .account(credential.accountID),
                repository: target.repository
            )
            let context = RepositoryForgeOverlayContext(
                access: .account(login: envelope.account.login),
                authentication: target.authentication,
                reader: GitHubRepositoryForgeOverlayReader(
                    repository: target.repository,
                    adapter: adapter,
                    now: now
                ),
                cache: SQLiteRepositoryForgeOverlayCache(database: database, partition: partition),
                cooldowns: cooldowns
            )
            let loader = RepositoryForgeOverlayLoader(
                bootstrap: .ready(target.repository, context),
                now: now
            )
            let cycle = cycles[target, default: 0] &+ 1
            cycles[target] = cycle
            _ = try await loader.refreshRepositoryFacts(
                request: RepositoryForgeOverlayRemoteRequest(reason: reason, cycle: cycle)
            )
            logger.info("Refreshed bound repository Forge overlay without an open window")
        } catch {
            logger.error("Bound repository Forge overlay refresh failed without logging response content")
        }
    }
}

@MainActor
protocol RepositoryForgeOverlayScheduledAction: AnyObject {
    func cancel()
}

@MainActor
protocol RepositoryForgeOverlayScheduling: AnyObject {
    func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> any RepositoryForgeOverlayScheduledAction
}

@MainActor
private final class RepositoryForgeOverlayTaskSchedule: RepositoryForgeOverlayScheduledAction {
    private var task: Task<Void, Never>?

    init(interval: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                action()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
final class RepositoryForgeOverlayTaskScheduler: RepositoryForgeOverlayScheduling {
    func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> any RepositoryForgeOverlayScheduledAction {
        RepositoryForgeOverlayTaskSchedule(interval: interval, action: action)
    }
}

@MainActor
protocol RepositoryForgeNetworkMonitoring: AnyObject {
    func start(handler: @escaping @MainActor @Sendable (Bool) -> Void)
    func cancel()
}

@MainActor
final class RepositoryForgeNetworkMonitor: RepositoryForgeNetworkMonitoring {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.gitx.gitx.forge-network-path")
    private var isStarted = false

    func start(handler: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { path in
            let available = path.status == .satisfied
            Task { @MainActor in
                handler(available)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        guard isStarted else { return }
        monitor.cancel()
        monitor.pathUpdateHandler = nil
        isStarted = false
    }
}

@MainActor
final class RepositoryForgeOverlaySession: RepositoryForgeStatusCoordinating {
    typealias FactsState = RepositoryForgeOverlayValueState<ForgeRepositoryFacts>
    typealias HistoryState = RepositoryForgeOverlayValueState<ForgeHistoryOverlay>

    private let repository: ForgeRepositoryIdentity?
    private let loader: RepositoryForgeOverlayLoader
    private let detailsHandler: (ForgeStatusDetailsAction) -> Void
    private let scheduler: any RepositoryForgeOverlayScheduling
    private let networkMonitor: any RepositoryForgeNetworkMonitoring
    private var applicationRefreshCoordinator: ForgeApplicationRefreshCoordinator?
    private var applicationRefreshRegistration: ForgeApplicationRefreshRegistration?
    private var applicationRefreshRegistrationTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var factsTask: Task<Void, Never>?
    private var historyTasks: [ForgeCommitID: Task<Void, Never>] = [:]
    private var scheduledRefresh: (any RepositoryForgeOverlayScheduledAction)?
    private var demandedCommits: Set<ForgeCommitID> = []
    private var bootstrapResolved = false
    private var authentication: ForgeRefreshAuthentication?
    private var activity: ForgeOverlayActivity
    private var lastNetworkAvailable: Bool?
    private var nextCycle: UInt64 = 0
    private var currentRequest: RepositoryForgeOverlayRemoteRequest?
    private var historyUnavailableReason: ForgeReadUnavailableReason?
    private var pendingFactsRefresh: RepositoryForgeOverlayRemoteRequest?
    private var pendingHistoryRefreshes: [ForgeCommitID: RepositoryForgeOverlayRemoteRequest] = [:]
    private var coordinatedRefreshWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private var coordinatedRefreshOutstanding: [UInt64: Int] = [:]
    private var factsObservers: [UUID: (FactsState) -> Void] = [:]
    private var historyObservers: [UUID: (ForgeCommitID, HistoryState) -> Void] = [:]
    private(set) var factsState: FactsState = .unavailable(.notRequested)
    private(set) var historyStates: [ForgeCommitID: HistoryState] = [:]
    private(set) var recoveryCopy: ForgeSQLiteRecoveryCopy?
    private(set) var currentInput: ForgeRepositoryStatusInput
    var inputDidChange: ((ForgeRepositoryStatusInput) -> Void)?
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeOverlaySession")

    init(
        binding: ForgeRepositoryBinding?,
        services: ForgeApplicationServiceLoader,
        now: @escaping @Sendable () -> Date = Date.init,
        scheduler: any RepositoryForgeOverlayScheduling = RepositoryForgeOverlayTaskScheduler(),
        networkMonitor: any RepositoryForgeNetworkMonitoring = RepositoryForgeNetworkMonitor(),
        activity: ForgeOverlayActivity = .otherOpenRepository,
        detailsHandler: @escaping (ForgeStatusDetailsAction) -> Void
    ) {
        repository = binding?.primaryRepository
        loader = RepositoryForgeOverlayLoader(binding: binding, services: services, now: now)
        self.scheduler = scheduler
        self.networkMonitor = networkMonitor
        self.activity = activity
        self.detailsHandler = detailsHandler
        currentInput = ForgeRepositoryStatusInput(
            repository: binding?.primaryRepository,
            access: .noAccount,
            freshness: .notLoaded,
            diagnostic: binding == nil ? .none : .authenticationRequired
        )
    }

    init(
        repository: ForgeRepositoryIdentity?,
        loader: RepositoryForgeOverlayLoader,
        scheduler: any RepositoryForgeOverlayScheduling = RepositoryForgeOverlayTaskScheduler(),
        networkMonitor: any RepositoryForgeNetworkMonitoring = RepositoryForgeNetworkMonitor(),
        activity: ForgeOverlayActivity = .otherOpenRepository,
        detailsHandler: @escaping (ForgeStatusDetailsAction) -> Void = { _ in }
    ) {
        self.repository = repository
        self.loader = loader
        self.scheduler = scheduler
        self.networkMonitor = networkMonitor
        self.activity = activity
        self.detailsHandler = detailsHandler
        currentInput = ForgeRepositoryStatusInput(
            repository: repository,
            access: .noAccount,
            freshness: .notLoaded,
            diagnostic: repository == nil ? .none : .authenticationRequired
        )
    }

    func start() {
        guard bootstrapTask == nil else { return }
        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            let bootstrap = await loader.prepare()
            guard !Task.isCancelled else { return }
            apply(bootstrap)
        }
    }

    func requestManualRefresh() {
        guard bootstrapTask != nil else {
            start()
            return
        }
        requestCoalescedRefresh(reason: .manual)
        logger.notice("Requested manual repository Forge refresh")
    }

    func requestRefresh(reason: ForgeRefreshReason) {
        logger.info("Requested repository Forge refresh reason=\(reason.rawValue, privacy: .public)")
        requestCoalescedRefresh(reason: reason)
    }

    func setActivity(_ activity: ForgeOverlayActivity) {
        guard self.activity != activity else { return }
        self.activity = activity
        if let applicationRefreshCoordinator, let applicationRefreshRegistration {
            Task {
                await applicationRefreshCoordinator.updateActivity(
                    activity,
                    registration: applicationRefreshRegistration
                )
            }
        } else {
            scheduleNextRefresh()
        }
        logger.info("Updated repository Forge overlay activity=\(activity.rawValue, privacy: .public)")
    }

    func showDetails(for action: ForgeStatusDetailsAction) {
        detailsHandler(action)
    }

    func updateStatus(_ input: ForgeRepositoryStatusInput) {
        publishStatus(input)
    }

    func requestHistoryOverlay(
        _ commit: ForgeCommitID,
        force: Bool = false,
        request: RepositoryForgeOverlayRemoteRequest? = nil
    ) {
        demandedCommits.insert(commit)
        guard bootstrapResolved else {
            if historyStates[commit] == nil {
                publishHistory(.loading(previous: nil), for: commit)
            }
            return
        }
        if let historyUnavailableReason {
            publishHistory(.unavailable(historyUnavailableReason), for: commit)
            return
        }
        guard let request = request ?? currentRequest else { return }
        guard isAllowed(request) else { return }
        if historyTasks[commit] != nil {
            if force {
                pendingHistoryRefreshes[commit] = request
            }
            return
        }
        if !force, case .value = historyStates[commit] {
            return
        }
        let previous = historyStates[commit]?.snapshot
        publishHistory(.loading(previous: previous), for: commit)
        historyTasks[commit] = Task { [weak self] in
            guard let self else { return }
            defer {
                historyTasks[commit] = nil
                finishCoordinatedRefresh(cycle: request.cycle)
                if let pending = pendingHistoryRefreshes.removeValue(forKey: commit) {
                    requestHistoryOverlay(commit, force: true, request: pending)
                }
            }
            var cached = previous
            if !force || cached == nil {
                do {
                    if let loaded = try await loader.cachedHistoryOverlay(commit: commit) {
                        cached = loaded
                        publishHistory(.loading(previous: loaded), for: commit)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    logger.error("Ignored invalid disposable History overlay cache entry")
                }
            }
            do {
                let remote = try await loader.refreshHistoryOverlay(commit: commit, request: request)
                let snapshot = RepositoryForgeOverlaySnapshot(
                    value: remote.value,
                    fetchedAt: remote.fetchedAt,
                    isPartial: remote.isPartial,
                    isStale: false
                )
                publishHistory(.value(snapshot), for: commit)
                publishFreshness(.current(fetchedAt: remote.fetchedAt), diagnostic: statusDiagnostic(after: remote))
            } catch is CancellationError {
                return
            } catch {
                publishHistory(cached.map { .value($0.markingStale()) } ?? .unavailable(.partialResponse), for: commit)
                handleFailure(error, cachedAt: cached?.fetchedAt)
            }
        }
    }

    @discardableResult
    func observeFacts(_ observer: @escaping (FactsState) -> Void) -> UUID {
        let token = UUID()
        factsObservers[token] = observer
        observer(factsState)
        return token
    }

    @discardableResult
    func observeHistory(_ observer: @escaping (ForgeCommitID, HistoryState) -> Void) -> UUID {
        let token = UUID()
        historyObservers[token] = observer
        for (commit, state) in historyStates {
            observer(commit, state)
        }
        return token
    }

    func removeObserver(_ token: UUID) {
        factsObservers.removeValue(forKey: token)
        historyObservers.removeValue(forKey: token)
    }

    func invalidate() {
        bootstrapTask?.cancel()
        factsTask?.cancel()
        historyTasks.values.forEach { $0.cancel() }
        scheduledRefresh?.cancel()
        networkMonitor.cancel()
        applicationRefreshRegistrationTask?.cancel()
        if let applicationRefreshCoordinator, let applicationRefreshRegistration {
            Task {
                await applicationRefreshCoordinator.unregister(applicationRefreshRegistration)
            }
        }
        bootstrapTask = nil
        factsTask = nil
        historyTasks.removeAll()
        scheduledRefresh = nil
        applicationRefreshRegistrationTask = nil
        applicationRefreshRegistration = nil
        applicationRefreshCoordinator = nil
        pendingFactsRefresh = nil
        pendingHistoryRefreshes.removeAll()
        coordinatedRefreshWaiters.values.flatMap { $0 }.forEach { $0.resume() }
        coordinatedRefreshWaiters.removeAll()
        coordinatedRefreshOutstanding.removeAll()
        factsObservers.removeAll()
        historyObservers.removeAll()
        inputDidChange = nil
    }

    private func apply(_ bootstrap: RepositoryForgeOverlayBootstrap) {
        bootstrapResolved = true
        switch bootstrap {
        case .unbound:
            historyUnavailableReason = .unsupported
            publishStatus(.unbound)
            publishFacts(.unavailable(.unsupported))
        case let .unsupported(repository):
            historyUnavailableReason = .unsupported
            publishStatus(ForgeRepositoryStatusInput(
                repository: repository,
                access: .noAccount,
                freshness: .notLoaded,
                diagnostic: .unavailable(.other)
            ))
            publishFacts(.unavailable(.unsupported))
        case let .authenticationRequired(repository):
            historyUnavailableReason = .authenticationRequired
            publishStatus(ForgeRepositoryStatusInput(
                repository: repository,
                access: .noAccount,
                freshness: .notLoaded,
                diagnostic: .authenticationRequired
            ))
            publishFacts(.unavailable(.authenticationRequired))
        case let .recoveryRequired(repository, copy):
            historyUnavailableReason = .partialResponse
            recoveryCopy = copy
            publishStatus(ForgeRepositoryStatusInput(
                repository: repository,
                access: .noAccount,
                freshness: .notLoaded,
                diagnostic: .unavailable(.persistentStorageFailure)
            ))
            publishFacts(.unavailable(.partialResponse))
        case let .sessionDisabled(repository, copy):
            historyUnavailableReason = .partialResponse
            recoveryCopy = copy
            publishStatus(ForgeRepositoryStatusInput(
                repository: repository,
                access: .noAccount,
                freshness: .notLoaded,
                diagnostic: .unavailable(.sessionDisabled)
            ))
            publishFacts(.unavailable(.partialResponse))
        case let .unavailable(repository):
            historyUnavailableReason = .partialResponse
            publishStatus(ForgeRepositoryStatusInput(
                repository: repository,
                access: .noAccount,
                freshness: .notLoaded,
                diagnostic: .unavailable(.other)
            ))
            publishFacts(.unavailable(.partialResponse))
        case let .ready(repository, context):
            historyUnavailableReason = nil
            authentication = context.authentication
            applicationRefreshCoordinator = context.refreshCoordinator
            publishStatus(ForgeRepositoryStatusInput(
                repository: repository,
                access: context.access,
                freshness: .notLoaded,
                diagnostic: .none
            ))
            if context.refreshCoordinator == nil {
                startNetworkMonitoringIfNeeded()
            }
            registerWithApplicationRefreshCoordinatorIfNeeded(context: context)
            if context.refreshCoordinator == nil {
                scheduleNextRefresh()
            }
            beginRefresh(reason: .repositoryOpened, force: false)
        }
        if let historyUnavailableReason {
            for commit in demandedCommits {
                publishHistory(.unavailable(historyUnavailableReason), for: commit)
            }
        }
    }

    @discardableResult
    private func beginRefresh(
        reason: ForgeRefreshReason,
        force: Bool
    ) -> RepositoryForgeOverlayRemoteRequest? {
        guard bootstrapResolved, let authentication else { return nil }
        if case .publicAccess = authentication,
           !ForgeRefreshPolicy.anonymousRequestIsExplicitlyAllowed(for: reason)
        {
            logger.debug("Skipped non-explicit anonymous repository Forge refresh")
            return nil
        }
        let request = makeRequest(reason: reason)
        guard isAllowed(request) else {
            logger.debug("Skipped non-explicit anonymous repository Forge refresh")
            return nil
        }
        currentRequest = request
        requestFactsRefresh(force: force, request: request)
        for commit in demandedCommits {
            requestHistoryOverlay(commit, force: force, request: request)
        }
        return request
    }

    private func requestCoalescedRefresh(reason: ForgeRefreshReason) {
        if let applicationRefreshCoordinator, let applicationRefreshRegistration {
            Task {
                await applicationRefreshCoordinator.requestRefresh(
                    registration: applicationRefreshRegistration,
                    reason: reason
                )
            }
            return
        }
        beginRefresh(reason: reason, force: true)
    }

    private func registerWithApplicationRefreshCoordinatorIfNeeded(
        context: RepositoryForgeOverlayContext
    ) {
        guard let coordinator = context.refreshCoordinator,
              let binding = context.binding,
              ForgeRefreshPolicy.mayScheduleAutomatically(authentication: context.authentication)
        else {
            return
        }
        let authentication = context.authentication
        let activity = activity
        applicationRefreshRegistrationTask = Task { [weak self] in
            let registration = await coordinator.register(
                binding: binding,
                authentication: authentication,
                activity: activity
            ) { [weak self] reason in
                await self?.performCoordinatedRefresh(reason: reason)
            }
            guard !Task.isCancelled else {
                if let registration {
                    await coordinator.unregister(registration)
                }
                return
            }
            self?.applicationRefreshRegistration = registration
            if let registration, let self {
                await coordinator.updateActivity(self.activity, registration: registration)
            }
        }
    }

    private func performCoordinatedRefresh(reason: ForgeRefreshReason) async {
        guard let request = beginRefresh(reason: reason, force: true) else { return }
        coordinatedRefreshOutstanding[request.cycle] = 1 + demandedCommits.count
        await withCheckedContinuation { continuation in
            coordinatedRefreshWaiters[request.cycle, default: []].append(continuation)
        }
    }

    private func finishCoordinatedRefresh(cycle: UInt64) {
        guard let outstanding = coordinatedRefreshOutstanding[cycle] else { return }
        guard outstanding <= 1 else {
            coordinatedRefreshOutstanding[cycle] = outstanding - 1
            return
        }
        coordinatedRefreshOutstanding.removeValue(forKey: cycle)
        coordinatedRefreshWaiters.removeValue(forKey: cycle)?.forEach { $0.resume() }
    }

    private func makeRequest(reason: ForgeRefreshReason) -> RepositoryForgeOverlayRemoteRequest {
        nextCycle = nextCycle == .max ? 1 : nextCycle + 1
        return RepositoryForgeOverlayRemoteRequest(reason: reason, cycle: nextCycle)
    }

    private func isAllowed(_ request: RepositoryForgeOverlayRemoteRequest) -> Bool {
        guard let authentication else { return false }
        if case .publicAccess = authentication {
            return ForgeRefreshPolicy.anonymousRequestIsExplicitlyAllowed(for: request.reason)
        }
        return true
    }

    private func requestFactsRefresh(
        force: Bool,
        request: RepositoryForgeOverlayRemoteRequest
    ) {
        guard authentication != nil else { return }
        if factsTask != nil {
            if force || pendingFactsRefresh == nil {
                pendingFactsRefresh = request
            }
            return
        }
        let previous = factsState.snapshot
        factsTask = Task { [weak self] in
            guard let self else { return }
            defer {
                factsTask = nil
                finishCoordinatedRefresh(cycle: request.cycle)
                if let pending = pendingFactsRefresh {
                    pendingFactsRefresh = nil
                    requestFactsRefresh(force: true, request: pending)
                }
            }
            var cached = previous
            if !force || cached == nil {
                do {
                    if let loaded = try await loader.cachedRepositoryFacts() {
                        cached = loaded
                        publishFacts(.loading(previous: loaded))
                        publishFreshness(.refreshing(cachedAt: loaded.fetchedAt), diagnostic: .none)
                    } else {
                        publishFacts(.loading(previous: previous))
                        publishFreshness(.refreshing(cachedAt: previous?.fetchedAt), diagnostic: .none)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    logger.error("Ignored invalid disposable Repository Facts cache entry")
                    publishFacts(.loading(previous: previous))
                    publishFreshness(.refreshing(cachedAt: previous?.fetchedAt), diagnostic: .none)
                }
            } else {
                publishFacts(.loading(previous: cached))
                publishFreshness(.refreshing(cachedAt: cached?.fetchedAt), diagnostic: .none)
            }
            do {
                let remote = try await loader.refreshRepositoryFacts(request: request)
                let snapshot = RepositoryForgeOverlaySnapshot(
                    value: remote.value,
                    fetchedAt: remote.fetchedAt,
                    isPartial: remote.isPartial,
                    isStale: false
                )
                publishFacts(.value(snapshot))
                publishFreshness(.current(fetchedAt: remote.fetchedAt), diagnostic: statusDiagnostic(after: remote))
            } catch is CancellationError {
                return
            } catch {
                publishFacts(cached.map { .value($0.markingStale()) } ?? .unavailable(.partialResponse))
                handleFailure(error, cachedAt: cached?.fetchedAt)
            }
        }
    }

    private func scheduleNextRefresh() {
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        guard bootstrapResolved,
              let authentication,
              ForgeRefreshPolicy.mayScheduleAutomatically(authentication: authentication)
        else {
            return
        }
        let interval = ForgeRefreshPolicy.interval(for: activity)
        scheduledRefresh = scheduler.schedule(after: interval) { [weak self] in
            guard let self else { return }
            scheduledRefresh = nil
            beginRefresh(reason: .scheduledOverlay, force: true)
            scheduleNextRefresh()
        }
        logger.debug("Scheduled repository Forge overlay refresh interval=\(interval, privacy: .public)")
    }

    private func startNetworkMonitoringIfNeeded() {
        guard let authentication,
              ForgeRefreshPolicy.mayScheduleAutomatically(authentication: authentication)
        else {
            return
        }
        networkMonitor.start { [weak self] available in
            guard let self else { return }
            let previous = lastNetworkAvailable
            lastNetworkAvailable = available
            guard available, previous == false else { return }
            if let applicationRefreshCoordinator {
                Task {
                    await applicationRefreshCoordinator.requestNetworkRestorationRefresh()
                }
            } else {
                beginRefresh(reason: .networkRestored, force: true)
                scheduleNextRefresh()
            }
            logger.notice("Requested repository Forge refresh after network restoration")
        }
    }

    private func statusDiagnostic<Value: Hashable & Sendable>(
        after snapshot: RepositoryForgeRemoteSnapshot<Value>
    ) -> ForgeStatusDiagnostic {
        snapshot.cooldownDeadline.map { .rateLimited(until: $0) } ?? .none
    }

    private func handleFailure(_ error: Error, cachedAt: Date?) {
        let diagnostic: ForgeStatusDiagnostic
        switch error {
        case let RepositoryForgeOverlayLoadError.rateLimited(until):
            diagnostic = .rateLimited(until: until)
        case GitHubReadError.authenticationRequired:
            diagnostic = .authenticationRequired
        case GitHubReadError.permissionDenied:
            diagnostic = .unavailable(.missingRepositoryAccess)
        case GitHubReadError.transportFailure:
            diagnostic = .offline
        case is URLError:
            diagnostic = .offline
        case GitHubAnonymousRESTError.reserveProtected,
             GitHubAnonymousRESTError.explicitRequestRequired:
            diagnostic = .unavailable(.other)
        case GitHubAnonymousRESTError.notFound:
            diagnostic = .unavailable(.missingRepositoryAccess)
        case is ForgeSQLiteError:
            diagnostic = .unavailable(.persistentStorageFailure)
        default:
            diagnostic = .unavailable(.other)
        }
        publishFreshness(.stale(cachedAt: cachedAt), diagnostic: diagnostic)
        logger.error("Repository Forge refresh failed without logging response content")
    }

    private func publishFreshness(
        _ freshness: ForgeOverlayFreshness,
        diagnostic: ForgeStatusDiagnostic
    ) {
        publishStatus(ForgeRepositoryStatusInput(
            repository: currentInput.repository ?? repository,
            access: currentInput.access,
            freshness: freshness,
            diagnostic: diagnostic
        ))
    }

    private func publishStatus(_ input: ForgeRepositoryStatusInput) {
        currentInput = input
        inputDidChange?(input)
    }

    private func publishFacts(_ state: FactsState) {
        factsState = state
        factsObservers.values.forEach { $0(state) }
    }

    private func publishHistory(_ state: HistoryState, for commit: ForgeCommitID) {
        historyStates[commit] = state
        historyObservers.values.forEach { $0(commit, state) }
    }
}
