import Foundation

public enum ForgePolicyConstants {
    public static let disposableCacheByteLimit: UInt64 = 250 * 1024 * 1024
    public static let avatarCacheByteLimit: UInt64 = 25 * 1024 * 1024
    public static let repositoryIdleExpiration: TimeInterval = 30 * 24 * 60 * 60
    public static let durableRecordExpiration: TimeInterval = 30 * 24 * 60 * 60
    public static let recoveryCopyExpiration: TimeInterval = 30 * 24 * 60 * 60
    public static let anonymousReservedRequestCount = 10
}

public enum ForgeCachePartition: Codable, Hashable, Sendable {
    case publicAccess
    case account(ForgeAccountID)
}

public enum ForgeCachePolicyError: Error, Equatable, LocalizedError, Sendable {
    case mismatchedAccountForge
    case invalidAccessTimestampOrder
    case staleRefreshGeneration

    public var errorDescription: String? {
        switch self {
        case .mismatchedAccountForge:
            "The cache Account and repository belong to different Forges."
        case .invalidAccessTimestampOrder:
            "The cache access timestamp predates the fetched snapshot."
        case .staleRefreshGeneration:
            "The snapshot result does not belong to the refresh currently awaiting a result."
        }
    }
}

public struct ForgeRepositoryPartitionKey: Codable, Hashable, Sendable {
    public let cachePartition: ForgeCachePartition
    public let repository: ForgeRepositoryIdentity

    public init(cachePartition: ForgeCachePartition, repository: ForgeRepositoryIdentity) throws {
        if case let .account(accountID) = cachePartition,
           accountID.forge != repository.forge
        {
            throw ForgeCachePolicyError.mismatchedAccountForge
        }
        self.cachePartition = cachePartition
        self.repository = repository
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            cachePartition: container.decode(ForgeCachePartition.self, forKey: .cachePartition),
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository)
        )
    }
}

public enum ForgeSnapshotSection: String, CaseIterable, Codable, Hashable, Sendable {
    case repositoryFacts
    case pullRequests
    case issues
    case timeline
    case checks
    case commitStatuses
    case reviewDecision
    case reviewThreads
    case historyBadges
}

public enum ForgeSnapshotCompleteness: Codable, Hashable, Sendable {
    case complete
    case partial(unavailableSections: Set<ForgeSnapshotSection>)
}

public enum ForgeCacheRecordKind: String, CaseIterable, Codable, Hashable, Sendable {
    case repositoryFacts
    case pullRequestPage
    case pullRequestDetail
    case pullRequestTimeline
    case issuePage
    case issueDetail
    case issueTimeline
    case checks
    case commitStatuses
    case reviewThreads
    case derivedRenderData
    case historyBadges
}

public struct ForgeCacheRecordKey: Codable, Hashable, Sendable {
    public let repositoryPartition: ForgeRepositoryPartitionKey
    public let kind: ForgeCacheRecordKind
    public let identity: String

    public init(
        repositoryPartition: ForgeRepositoryPartitionKey,
        kind: ForgeCacheRecordKind,
        identity: String
    ) {
        self.repositoryPartition = repositoryPartition
        self.kind = kind
        self.identity = identity
    }
}

public struct ForgeAvatarCacheKey: Codable, Hashable, Sendable {
    public let canonicalURL: URL

    public init(canonicalURL: URL) {
        self.canonicalURL = canonicalURL
    }
}

/// Attribution for a shared, credential-free avatar cache entry.
///
/// The same public avatar bytes may be reused across accounts, while this owner
/// set lets account removal delete an entry only when no anonymous or other
/// account use remains.
public enum ForgeAvatarCacheOwner: Hashable, Sendable {
    case anonymous
    case account(ForgeAccountID)
}

public enum ForgeDisposableCacheKey: Codable, Hashable, Sendable {
    case snapshot(ForgeCacheRecordKey)
    case avatar(ForgeAvatarCacheKey)
}

public struct ForgeDisposableCacheRecord: Codable, Hashable, Sendable {
    public let key: ForgeDisposableCacheKey
    public let byteCount: UInt64
    public let fetchedAt: Date
    public private(set) var lastAccessedAt: Date
    public let completeness: ForgeSnapshotCompleteness

    public init(
        key: ForgeDisposableCacheKey,
        byteCount: UInt64,
        fetchedAt: Date,
        lastAccessedAt: Date,
        completeness: ForgeSnapshotCompleteness = .complete
    ) throws {
        guard lastAccessedAt >= fetchedAt else {
            throw ForgeCachePolicyError.invalidAccessTimestampOrder
        }
        self.key = key
        self.byteCount = byteCount
        self.fetchedAt = fetchedAt
        self.lastAccessedAt = lastAccessedAt
        self.completeness = completeness
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            key: container.decode(ForgeDisposableCacheKey.self, forKey: .key),
            byteCount: container.decode(UInt64.self, forKey: .byteCount),
            fetchedAt: container.decode(Date.self, forKey: .fetchedAt),
            lastAccessedAt: container.decode(Date.self, forKey: .lastAccessedAt),
            completeness: container.decode(ForgeSnapshotCompleteness.self, forKey: .completeness)
        )
    }

    public func accessed(at date: Date) -> ForgeDisposableCacheRecord {
        var updated = self
        updated.lastAccessedAt = max(lastAccessedAt, date)
        return updated
    }

    private enum CodingKeys: CodingKey {
        case key
        case byteCount
        case fetchedAt
        case lastAccessedAt
        case completeness
    }
}

public struct ForgePreviousSnapshot<Record: Hashable & Sendable>: Hashable, Sendable {
    public let record: Record
    public let fetchedAt: Date
    public let completeness: ForgeSnapshotCompleteness

    public init(
        record: Record,
        fetchedAt: Date,
        completeness: ForgeSnapshotCompleteness
    ) {
        self.record = record
        self.fetchedAt = fetchedAt
        self.completeness = completeness
    }
}

public enum ForgeSnapshotState<Record: Hashable & Sendable>: Hashable, Sendable {
    case unavailable
    case refreshing(generation: ForgeRefreshGeneration, previous: ForgePreviousSnapshot<Record>?)
    case fresh(record: Record, fetchedAt: Date, completeness: ForgeSnapshotCompleteness)
    case stale(
        record: Record,
        fetchedAt: Date,
        completeness: ForgeSnapshotCompleteness,
        failedAt: Date
    )
}

public enum ForgeSnapshotRefreshOutcome<Record: Hashable & Sendable>: Hashable, Sendable {
    case success(record: Record, fetchedAt: Date, completeness: ForgeSnapshotCompleteness)
    case failure(failedAt: Date)
}

public struct ForgeSnapshotRefreshResult<Record: Hashable & Sendable>: Hashable, Sendable {
    public let generation: ForgeRefreshGeneration
    public let outcome: ForgeSnapshotRefreshOutcome<Record>
}

public struct ForgeSnapshotRefreshApplication<Record: Hashable & Sendable>: Hashable, Sendable {
    public let result: ForgeSnapshotRefreshResult<Record>
    public let nextRequest: ForgeRefreshRequest?
}

public extension ForgeSnapshotState {
    func startingRefresh(_ execution: ForgeRefreshExecution) -> ForgeSnapshotState<Record> {
        switch self {
        case .unavailable:
            .refreshing(generation: execution.generation, previous: nil)
        case let .refreshing(_, previous):
            .refreshing(generation: execution.generation, previous: previous)
        case let .fresh(record, fetchedAt, completeness):
            .refreshing(
                generation: execution.generation,
                previous: ForgePreviousSnapshot(
                    record: record,
                    fetchedAt: fetchedAt,
                    completeness: completeness
                )
            )
        case let .stale(record, fetchedAt, completeness, _):
            .refreshing(
                generation: execution.generation,
                previous: ForgePreviousSnapshot(
                    record: record,
                    fetchedAt: fetchedAt,
                    completeness: completeness
                )
            )
        }
    }

    func applying(
        _ application: ForgeSnapshotRefreshApplication<Record>
    ) throws -> ForgeSnapshotState<Record> {
        guard case let .refreshing(expectedGeneration, previous) = self,
              application.result.generation == expectedGeneration
        else {
            throw ForgeCachePolicyError.staleRefreshGeneration
        }
        return switch application.result.outcome {
        case let .success(record, fetchedAt, completeness):
            .fresh(record: record, fetchedAt: fetchedAt, completeness: completeness)
        case let .failure(failedAt):
            switch previous {
            case let previous?:
                .stale(
                    record: previous.record,
                    fetchedAt: previous.fetchedAt,
                    completeness: previous.completeness,
                    failedAt: failedAt
                )
            case nil:
                .unavailable
            }
        }
    }

    var freshnessTimestamp: Date? {
        switch self {
        case let .fresh(_, fetchedAt, _), let .stale(_, fetchedAt, _, _): fetchedAt
        case let .refreshing(_, previous): previous?.fetchedAt
        case .unavailable: nil
        }
    }

    var completeness: ForgeSnapshotCompleteness? {
        switch self {
        case let .fresh(_, _, completeness), let .stale(_, _, completeness, _): completeness
        case let .refreshing(_, previous): previous?.completeness
        case .unavailable: nil
        }
    }
}

public enum ForgeCacheEvictionPolicy {
    public static func keysToEvict(from records: [ForgeDisposableCacheRecord]) -> [ForgeDisposableCacheKey] {
        let oldestFirst = records.sorted {
            if $0.lastAccessedAt != $1.lastAccessedAt {
                return $0.lastAccessedAt < $1.lastAccessedAt
            }
            return String(describing: $0.key) < String(describing: $1.key)
        }
        var retained = records
        var evicted: [ForgeDisposableCacheKey] = []

        evict(
            from: &retained,
            orderedBy: oldestFirst,
            whileByteCountExceeds: ForgePolicyConstants.avatarCacheByteLimit,
            matching: {
                if case .avatar = $0.key {
                    true
                } else {
                    false
                }
            },
            into: &evicted
        )
        evict(
            from: &retained,
            orderedBy: oldestFirst,
            whileByteCountExceeds: ForgePolicyConstants.disposableCacheByteLimit,
            matching: { _ in true },
            into: &evicted
        )
        return evicted
    }

    public static func expiredRepositoryPartitions(
        in records: [ForgeDisposableCacheRecord],
        now: Date
    ) -> Set<ForgeRepositoryPartitionKey> {
        let grouped = Dictionary(grouping: records.compactMap { record -> (ForgeRepositoryPartitionKey, Date)? in
            guard case let .snapshot(key) = record.key else { return nil }
            return (key.repositoryPartition, record.lastAccessedAt)
        }, by: \.0)

        return Set(grouped.compactMap { partition, entries in
            guard let mostRecentAccess = entries.map(\.1).max(),
                  now.timeIntervalSince(mostRecentAccess) >= ForgePolicyConstants.repositoryIdleExpiration
            else { return nil }
            return partition
        })
    }

    private static func evict(
        from retained: inout [ForgeDisposableCacheRecord],
        orderedBy oldestFirst: [ForgeDisposableCacheRecord],
        whileByteCountExceeds limit: UInt64,
        matching: (ForgeDisposableCacheRecord) -> Bool,
        into evicted: inout [ForgeDisposableCacheKey]
    ) {
        func byteCount() -> UInt64 {
            retained.lazy.filter(matching).reduce(0) { $0 + $1.byteCount }
        }

        for candidate in oldestFirst where byteCount() > limit && matching(candidate) {
            guard let index = retained.firstIndex(where: { $0.key == candidate.key }) else { continue }
            retained.remove(at: index)
            evicted.append(candidate.key)
        }
    }
}
