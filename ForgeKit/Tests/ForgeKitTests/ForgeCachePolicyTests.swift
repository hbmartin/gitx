@testable import ForgeKit
import Foundation
import XCTest

final class ForgeCachePolicyTests: XCTestCase {
    func testAcceptedStorageAndRetentionConstantsAreExact() {
        XCTAssertEqual(ForgePolicyConstants.disposableCacheByteLimit, 262_144_000)
        XCTAssertEqual(ForgePolicyConstants.avatarCacheByteLimit, 26_214_400)
        XCTAssertEqual(ForgePolicyConstants.repositoryIdleExpiration, 2_592_000)
        XCTAssertEqual(ForgePolicyConstants.durableRecordExpiration, 2_592_000)
        XCTAssertEqual(ForgePolicyConstants.recoveryCopyExpiration, 2_592_000)
        XCTAssertEqual(ForgePolicyConstants.anonymousReservedRequestCount, 10)
    }

    func testCachePartitionsAreExactToPublicOrAccountAndRepository() throws {
        let repository = try TestSupport.repository()
        let otherRepository = try TestSupport.repository(owner: "other")
        let account = try ForgeAccountID(forge: repository.forge, value: "one")
        let otherAccount = try ForgeAccountID(forge: repository.forge, value: "two")
        let values = try Set([
            ForgeRepositoryPartitionKey(cachePartition: .publicAccess, repository: repository),
            ForgeRepositoryPartitionKey(cachePartition: .account(account), repository: repository),
            ForgeRepositoryPartitionKey(cachePartition: .account(otherAccount), repository: repository),
            ForgeRepositoryPartitionKey(cachePartition: .account(account), repository: otherRepository),
        ])
        XCTAssertEqual(values.count, 4)

        let key = try XCTUnwrap(values.first { $0.cachePartition == .account(account) && $0.repository == repository })
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeRepositoryPartitionKey.self, from: JSONEncoder().encode(key)),
            key
        )
    }

    func testCachePartitionRejectsCrossForgeAccountDirectlyAndWhenDecoded() throws {
        struct UnvalidatedPartition: Encodable {
            let cachePartition: ForgeCachePartition
            let repository: ForgeRepositoryIdentity
        }

        let repository = try TestSupport.repository()
        let gitLab = try TestSupport.repository(kind: .gitLab)
        let accountID = try ForgeAccountID(forge: gitLab.forge, value: "account")
        XCTAssertThrowsError(
            try ForgeRepositoryPartitionKey(
                cachePartition: .account(accountID),
                repository: repository
            )
        ) {
            XCTAssertEqual($0 as? ForgeCachePolicyError, .mismatchedAccountForge)
        }
        let data = try JSONEncoder().encode(
            UnvalidatedPartition(cachePartition: .account(accountID), repository: repository)
        )
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeRepositoryPartitionKey.self, from: data)) {
            XCTAssertEqual($0 as? ForgeCachePolicyError, .mismatchedAccountForge)
        }
        XCTAssertNotNil(ForgeCachePolicyError.mismatchedAccountForge.errorDescription)
        XCTAssertNotNil(ForgeCachePolicyError.invalidAccessTimestampOrder.errorDescription)
        XCTAssertNotNil(ForgeCachePolicyError.staleRefreshGeneration.errorDescription)
    }

    func testSnapshotRefreshPreservesPartialDataAndMarksFailureStale() throws {
        let fetchedAt = Date(timeIntervalSince1970: 100)
        let failedAt = Date(timeIntervalSince1970: 200)
        let partial = ForgeSnapshotCompleteness.partial(unavailableSections: [.checks, .reviewDecision])
        let firstExecution = try execution(generation: 1)
        let firstRefresh = ForgeSnapshotState<String>.unavailable.startingRefresh(firstExecution)
        let fresh = try firstRefresh.applying(
            application(
                for: firstExecution,
                outcome: .success(record: "usable", fetchedAt: fetchedAt, completeness: partial)
            )
        )
        XCTAssertEqual(fresh, .fresh(record: "usable", fetchedAt: fetchedAt, completeness: partial))
        XCTAssertEqual(fresh.freshnessTimestamp, fetchedAt)

        let secondExecution = try execution(generation: 2)
        let refreshing = fresh.startingRefresh(secondExecution)
        XCTAssertEqual(
            refreshing,
            .refreshing(
                generation: secondExecution.generation,
                previous: ForgePreviousSnapshot(
                    record: "usable",
                    fetchedAt: fetchedAt,
                    completeness: partial
                )
            )
        )
        XCTAssertEqual(refreshing.completeness, partial)
        let failure: ForgeSnapshotRefreshApplication<String> = application(
            for: secondExecution,
            outcome: .failure(failedAt: failedAt)
        )
        let stale = try refreshing.applying(failure)
        XCTAssertEqual(
            stale,
            .stale(
                record: "usable",
                fetchedAt: fetchedAt,
                completeness: partial,
                failedAt: failedAt
            )
        )
        XCTAssertEqual(stale.completeness, partial)

        let unavailableExecution = try execution(generation: 3)
        XCTAssertEqual(
            try ForgeSnapshotState<String>.unavailable
                .startingRefresh(unavailableExecution)
                .applying(application(for: unavailableExecution, outcome: .failure(failedAt: failedAt))),
            .unavailable
        )
    }

    func testSnapshotRefreshHandlesEveryRetainedStateAndRejectsStaleResults() throws {
        let fetchedAt = Date(timeIntervalSince1970: 100)
        let failedAt = Date(timeIntervalSince1970: 200)
        let completeness = ForgeSnapshotCompleteness.partial(unavailableSections: [.timeline])
        let previous = ForgePreviousSnapshot(
            record: "usable",
            fetchedAt: fetchedAt,
            completeness: completeness
        )
        let firstExecution = try execution(generation: 1)
        let refreshing = ForgeSnapshotState<String>.refreshing(
            generation: firstExecution.generation,
            previous: previous
        )
        let secondExecution = try execution(generation: 2)
        XCTAssertEqual(
            refreshing.startingRefresh(secondExecution),
            .refreshing(generation: secondExecution.generation, previous: previous)
        )

        let stale = ForgeSnapshotState<String>.stale(
            record: previous.record,
            fetchedAt: previous.fetchedAt,
            completeness: previous.completeness,
            failedAt: failedAt
        )
        XCTAssertEqual(stale.startingRefresh(firstExecution), refreshing)
        XCTAssertEqual(stale.freshnessTimestamp, fetchedAt)
        XCTAssertEqual(stale.completeness, completeness)
        let laterFailure: ForgeSnapshotRefreshApplication<String> = application(
            for: firstExecution,
            outcome: .failure(failedAt: failedAt.addingTimeInterval(1))
        )
        XCTAssertEqual(
            try stale.startingRefresh(firstExecution).applying(laterFailure),
            .stale(
                record: previous.record,
                fetchedAt: previous.fetchedAt,
                completeness: previous.completeness,
                failedAt: failedAt.addingTimeInterval(1)
            )
        )

        let awaitingSecond = ForgeSnapshotState<String>.fresh(
            record: previous.record,
            fetchedAt: previous.fetchedAt,
            completeness: previous.completeness
        ).startingRefresh(secondExecution)
        XCTAssertThrowsError(try awaitingSecond.applying(laterFailure)) {
            XCTAssertEqual($0 as? ForgeCachePolicyError, .staleRefreshGeneration)
        }
        XCTAssertThrowsError(try stale.applying(laterFailure)) {
            XCTAssertEqual($0 as? ForgeCachePolicyError, .staleRefreshGeneration)
        }
        XCTAssertNil(ForgeSnapshotState<String>.unavailable.freshnessTimestamp)
        XCTAssertNil(ForgeSnapshotState<String>.unavailable.completeness)
        XCTAssertNil(
            ForgeSnapshotState<String>.refreshing(
                generation: firstExecution.generation,
                previous: nil
            ).freshnessTimestamp
        )
        XCTAssertNil(
            ForgeSnapshotState<String>.refreshing(
                generation: firstExecution.generation,
                previous: nil
            ).completeness
        )
    }

    func testAccessUpdatesOnlyLRUTimestamp() throws {
        let record = try snapshotRecord(
            identity: "one",
            bytes: 10,
            fetchedAt: Date(timeIntervalSince1970: 10),
            accessedAt: Date(timeIntervalSince1970: 20)
        )
        let updated = record.accessed(at: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(updated.key, record.key)
        XCTAssertEqual(updated.byteCount, record.byteCount)
        XCTAssertEqual(updated.fetchedAt, record.fetchedAt)
        XCTAssertEqual(updated.lastAccessedAt, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(
            updated.accessed(at: Date(timeIntervalSince1970: 15)).lastAccessedAt,
            Date(timeIntervalSince1970: 30)
        )
    }

    func testCacheRecordRejectsAccessBeforeFetchDirectlyAndWhenDecoded() throws {
        struct UnvalidatedRecord: Encodable {
            let key: ForgeDisposableCacheKey
            let byteCount: UInt64
            let fetchedAt: Date
            let lastAccessedAt: Date
            let completeness: ForgeSnapshotCompleteness
        }

        let key = try ForgeDisposableCacheKey.snapshot(snapshotKey(identity: "invalid-time"))
        let fetchedAt = Date(timeIntervalSince1970: 20)
        let lastAccessedAt = Date(timeIntervalSince1970: 10)
        XCTAssertThrowsError(
            try ForgeDisposableCacheRecord(
                key: key,
                byteCount: 1,
                fetchedAt: fetchedAt,
                lastAccessedAt: lastAccessedAt
            )
        ) {
            XCTAssertEqual($0 as? ForgeCachePolicyError, .invalidAccessTimestampOrder)
        }
        let malformed = UnvalidatedRecord(
            key: key,
            byteCount: 1,
            fetchedAt: fetchedAt,
            lastAccessedAt: lastAccessedAt,
            completeness: .complete
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ForgeDisposableCacheRecord.self,
                from: JSONEncoder().encode(malformed)
            )
        ) {
            XCTAssertEqual($0 as? ForgeCachePolicyError, .invalidAccessTimestampOrder)
        }

        let valid = try snapshotRecord(
            identity: "valid-time",
            bytes: 1,
            fetchedAt: fetchedAt,
            accessedAt: fetchedAt
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeDisposableCacheRecord.self, from: JSONEncoder().encode(valid)),
            valid
        )
    }

    func testGlobalLRUEvictsOnlyWhenLimitIsExceeded() throws {
        let limit = ForgePolicyConstants.disposableCacheByteLimit
        let equal = try snapshotRecord(identity: "equal", bytes: limit, accessedAt: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(ForgeCacheEvictionPolicy.keysToEvict(from: [equal]).isEmpty)

        let oldest = try snapshotRecord(identity: "oldest", bytes: 1, accessedAt: Date(timeIntervalSince1970: 1))
        let newest = try snapshotRecord(identity: "newest", bytes: limit, accessedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(ForgeCacheEvictionPolicy.keysToEvict(from: [newest, oldest]), [oldest.key])

        let tiedB = try snapshotRecord(identity: "b", bytes: limit, accessedAt: Date(timeIntervalSince1970: 3))
        let tiedA = try snapshotRecord(identity: "a", bytes: 1, accessedAt: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(ForgeCacheEvictionPolicy.keysToEvict(from: [tiedB, tiedA]), [tiedA.key])
    }

    func testAvatarSubcapIsInsideGlobalLRU() throws {
        let oldAvatar = try avatarRecord(
            url: "https://avatars.githubusercontent.com/u/1",
            bytes: 1,
            accessedAt: Date(timeIntervalSince1970: 1)
        )
        let newAvatar = try avatarRecord(
            url: "https://avatars.githubusercontent.com/u/2",
            bytes: ForgePolicyConstants.avatarCacheByteLimit,
            accessedAt: Date(timeIntervalSince1970: 2)
        )
        let snapshot = try snapshotRecord(
            identity: "large",
            bytes: ForgePolicyConstants.disposableCacheByteLimit - ForgePolicyConstants.avatarCacheByteLimit,
            accessedAt: Date(timeIntervalSince1970: 3)
        )
        XCTAssertEqual(
            ForgeCacheEvictionPolicy.keysToEvict(from: [snapshot, newAvatar, oldAvatar]),
            [oldAvatar.key]
        )
    }

    func testRepositoryPartitionExpiresAtThirtyIdleDaysButAvatarsDoNotCreatePartitions() throws {
        let old = try snapshotRecord(identity: "old", bytes: 1, accessedAt: Date(timeIntervalSince1970: 0))
        let recent = try snapshotRecord(identity: "recent", bytes: 1, accessedAt: Date(timeIntervalSince1970: 1))
        let avatar = try avatarRecord(
            url: "https://avatars.githubusercontent.com/u/1",
            bytes: 1,
            accessedAt: .distantPast
        )
        let partition = try snapshotKey(identity: "old").repositoryPartition

        XCTAssertTrue(
            ForgeCacheEvictionPolicy.expiredRepositoryPartitions(
                in: [old, recent, avatar],
                now: Date(timeIntervalSince1970: ForgePolicyConstants.repositoryIdleExpiration)
            ).isEmpty
        )
        XCTAssertEqual(
            ForgeCacheEvictionPolicy.expiredRepositoryPartitions(
                in: [old, recent, avatar],
                now: Date(timeIntervalSince1970: ForgePolicyConstants.repositoryIdleExpiration + 1)
            ),
            [partition]
        )
    }

    private func snapshotKey(identity: String) throws -> ForgeCacheRecordKey {
        try ForgeCacheRecordKey(
            repositoryPartition: ForgeRepositoryPartitionKey(
                cachePartition: .publicAccess,
                repository: TestSupport.repository()
            ),
            kind: .pullRequestDetail,
            identity: identity
        )
    }

    private func execution(generation: UInt64) throws -> ForgeRefreshExecution {
        let target = try ForgeRefreshTarget(
            authentication: .publicAccess,
            repository: TestSupport.repository()
        )
        return try ForgeRefreshExecution(
            request: ForgeRefreshRequest(
                target: target,
                reasons: [.manual],
                recordKinds: [.repositoryFacts],
                sequence: ForgeRefreshRequestSequence(generation),
                requestedAt: Date(timeIntervalSince1970: TimeInterval(generation))
            ),
            generation: ForgeRefreshGeneration(generation),
            startedAt: Date(timeIntervalSince1970: TimeInterval(generation))
        )
    }

    private func application<Record: Hashable & Sendable>(
        for execution: ForgeRefreshExecution,
        outcome: ForgeSnapshotRefreshOutcome<Record>
    ) -> ForgeSnapshotRefreshApplication<Record> {
        ForgeSnapshotRefreshApplication(
            result: ForgeSnapshotRefreshResult(
                generation: execution.generation,
                outcome: outcome
            ),
            nextRequest: nil
        )
    }

    private func snapshotRecord(
        identity: String,
        bytes: UInt64,
        fetchedAt: Date = Date(timeIntervalSince1970: 0),
        accessedAt: Date
    ) throws -> ForgeDisposableCacheRecord {
        try ForgeDisposableCacheRecord(
            key: .snapshot(snapshotKey(identity: identity)),
            byteCount: bytes,
            fetchedAt: fetchedAt,
            lastAccessedAt: accessedAt
        )
    }

    private func avatarRecord(
        url: String,
        bytes: UInt64,
        accessedAt: Date
    ) throws -> ForgeDisposableCacheRecord {
        try ForgeDisposableCacheRecord(
            key: .avatar(ForgeAvatarCacheKey(canonicalURL: URL(string: url)!)),
            byteCount: bytes,
            fetchedAt: .distantPast,
            lastAccessedAt: accessedAt
        )
    }
}
