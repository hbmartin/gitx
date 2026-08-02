@testable import ForgeKit
import Foundation
import SQLite3
import XCTest

final class ForgeSQLitePersistenceTests: XCTestCase {
    func testBatchCacheReadUpdatesOneHundredRowsAtomically() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        let keys = try (0 ..< 100).map {
            try fixture.snapshotKey(.account(fixture.firstAccount), identity: "batch-\($0)")
        }
        for (index, key) in keys.enumerated() {
            try await store.putCacheEntry(fixture.entry(
                key,
                payload: String(index),
                fetched: 1,
                accessed: 1
            ))
        }
        try RawSQLite.execute(
            """
            CREATE TRIGGER fail_mid_batch_cache_access
            BEFORE UPDATE OF accessed_at ON forge_cache_entries
            WHEN OLD.payload = X'3530'
            BEGIN
                SELECT RAISE(ABORT, 'forced mid-batch access failure');
            END
            """,
            at: fixture.databaseURL
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await store.cacheEntries(for: keys, accessedAt: fixture.date(2))
        }
        XCTAssertEqual(
            try RawSQLite.scalar(
                "SELECT COUNT(*) FROM forge_cache_entries WHERE accessed_at = 1700000001",
                at: fixture.databaseURL
            ),
            100,
            "A failed list load must roll back every earlier LRU update in the same batch"
        )

        try RawSQLite.execute("DROP TRIGGER fail_mid_batch_cache_access", at: fixture.databaseURL)
        let loaded = try await store.cacheEntries(for: keys, accessedAt: fixture.date(2))
        XCTAssertEqual(loaded.compactMap { $0 }.count, 100)
        XCTAssertTrue(loaded.compactMap { $0 }.allSatisfy {
            $0.record.lastAccessedAt == fixture.date(2)
        })
        await store.close()
    }

    func testCachePartitionsStayExactAndReadsUpdateGlobalLRU() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        let publicKey = try fixture.snapshotKey(.publicAccess, identity: "same-key")
        let firstKey = try fixture.snapshotKey(.account(fixture.firstAccount), identity: "same-key")
        let secondKey = try fixture.snapshotKey(.account(fixture.secondAccount), identity: "same-key")

        try await store.putCacheEntry(fixture.entry(
            publicKey,
            payload: "public",
            fetched: 10,
            accessed: 10,
            completeness: .partial(unavailableSections: [.timeline])
        ))
        try await store.putCacheEntry(fixture.entry(firstKey, payload: "first", fetched: 20, accessed: 20))
        try await store.putCacheEntry(fixture.entry(secondKey, payload: "second", fetched: 30, accessed: 30))

        let loadedPublicRecord = try await store.cacheEntry(
            for: publicKey,
            accessedAt: fixture.date(40)
        )
        let publicRecord = try XCTUnwrap(loadedPublicRecord)
        XCTAssertEqual(publicRecord.payload, Data("public".utf8))
        XCTAssertEqual(publicRecord.record.fetchedAt, fixture.date(10))
        XCTAssertEqual(publicRecord.record.lastAccessedAt, fixture.date(40))
        XCTAssertEqual(publicRecord.record.completeness, .partial(unavailableSections: [.timeline]))
        let firstRecord = try await store.cacheEntry(
            for: firstKey,
            accessedAt: fixture.date(50)
        )
        XCTAssertEqual(firstRecord?.payload, Data("first".utf8))
        let differentRecord = try await store.cacheEntry(
            for: fixture.snapshotKey(.publicAccess, identity: "different"),
            accessedAt: fixture.date(60)
        )
        XCTAssertNil(differentRecord)

        let evicted = try await store.enforceCacheLimits(totalByteLimit: 11, avatarByteLimit: 11)
        XCTAssertEqual(evicted, 1)
        let evictedRecord = try await store.cacheEntry(
            for: secondKey,
            accessedAt: fixture.date(70)
        )
        XCTAssertNil(evictedRecord)
        let retainedRecord = try await store.cacheEntry(
            for: publicKey,
            accessedAt: fixture.date(70)
        )
        XCTAssertNotNil(retainedRecord)
        await store.close()
    }

    func testCacheUpsertIdleRepositoryRemovalAndEmptyPayload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        let current = try fixture.snapshotKey(.account(fixture.firstAccount), identity: "current")
        let idleRepository = try ForgeRepositoryIdentity(
            forge: fixture.forge,
            owner: "acme",
            name: "idle"
        )
        let idlePartition = try ForgeRepositoryPartitionKey(
            cachePartition: .account(fixture.firstAccount),
            repository: idleRepository
        )
        let idle = ForgeDisposableCacheKey.snapshot(ForgeCacheRecordKey(
            repositoryPartition: idlePartition,
            kind: .pullRequestTimeline,
            identity: "idle"
        ))

        try await store.putCacheEntry(fixture.entry(current, payload: "12", fetched: 1, accessed: 50))
        try await store.putCacheEntry(fixture.entry(current, payload: "", fetched: 2, accessed: 60))
        try await store.putCacheEntry(fixture.entry(idle, payload: "3", fetched: 1, accessed: 1))

        let removed = try await store.removeIdleCacheRepositories(notAccessedSince: fixture.date(10))
        XCTAssertEqual(removed, 1)
        let idleRecord = try await store.cacheEntry(
            for: idle,
            accessedAt: fixture.date(70)
        )
        XCTAssertNil(idleRecord)
        let loadedCurrentRecord = try await store.cacheEntry(
            for: current,
            accessedAt: fixture.date(70)
        )
        let currentRecord = try XCTUnwrap(loadedCurrentRecord)
        XCTAssertEqual(currentRecord.payload, Data())
        XCTAssertEqual(currentRecord.record.fetchedAt, fixture.date(2))
        let evicted = try await store.enforceCacheLimits(totalByteLimit: 0, avatarByteLimit: 0)
        XCTAssertEqual(evicted, 0)
        await store.close()
    }

    func testIdleRepositoryRemovalIncludesTheExactCutoffBoundary() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        let boundaryRepository = try ForgeRepositoryIdentity(
            forge: fixture.forge,
            owner: "acme",
            name: "boundary"
        )
        let boundaryPartition = try ForgeRepositoryPartitionKey(
            cachePartition: .account(fixture.firstAccount),
            repository: boundaryRepository
        )
        let boundaryKey = ForgeDisposableCacheKey.snapshot(ForgeCacheRecordKey(
            repositoryPartition: boundaryPartition,
            kind: .pullRequestTimeline,
            identity: "boundary"
        ))
        try await store.putCacheEntry(fixture.entry(
            boundaryKey,
            payload: "expired",
            fetched: 1,
            accessed: 30
        ))

        let removed = try await store.removeIdleCacheRepositories(
            notAccessedSince: fixture.date(30)
        )
        let removedEntry = try await store.cacheEntry(for: boundaryKey, accessedAt: fixture.date(31))
        XCTAssertEqual(removed, 1)
        XCTAssertNil(removedEntry)
        await store.close()
    }

    func testCacheReadFailsClosedOnPartitionMetadataMismatchAndUpsertRepairsIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var store: ForgeSQLiteStore? = try ForgeSQLiteStore(configuration: fixture.configuration)
        let key = try fixture.snapshotKey(.account(fixture.firstAccount), identity: "partition-check")
        let entry = try fixture.entry(key, payload: "cached", fetched: 1, accessed: 1)
        try await store?.putCacheEntry(entry)
        await store?.close()
        store = nil
        let wrongAccount = try ForgeSQLiteStore.encodedKey(fixture.secondAccount)
        let hex = wrongAccount.map { String(format: "%02x", $0) }.joined()
        try RawSQLite.execute(
            "UPDATE forge_cache_entries SET account_key = X'\(hex)';",
            at: fixture.databaseURL
        )

        store = try ForgeSQLiteStore(configuration: fixture.configuration)
        do {
            _ = try await store?.cacheEntry(for: key, accessedAt: fixture.date(2))
            XCTFail("Expected mismatched partition metadata to fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cache partition"))
        }
        try await store?.putCacheEntry(entry)
        let repaired = try await store?.cacheEntry(for: key, accessedAt: fixture.date(2))
        XCTAssertEqual(repaired, try ForgeSQLiteCacheEntry(
            record: entry.record.accessed(at: fixture.date(2)),
            payload: entry.payload
        ))
        await store?.close()
    }

    func testAvatarSubcapIsCredentialFreeAndIndependentOfGlobalLRU() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        let firstAvatar = try ForgeDisposableCacheKey.avatar(ForgeAvatarCacheKey(
            canonicalURL: XCTUnwrap(URL(string: "https://avatars.example/one"))
        ))
        let secondAvatar = try ForgeDisposableCacheKey.avatar(ForgeAvatarCacheKey(
            canonicalURL: XCTUnwrap(URL(string: "https://avatars.example/two"))
        ))
        let snapshot = try fixture.snapshotKey(.account(fixture.firstAccount), identity: "snapshot")
        try await store.putCacheEntry(fixture.entry(firstAvatar, payload: "1111", fetched: 1, accessed: 1))
        try await store.putCacheEntry(fixture.entry(secondAvatar, payload: "2222", fetched: 2, accessed: 2))
        try await store.putCacheEntry(fixture.entry(snapshot, payload: "state", fetched: 1, accessed: 1))

        let evicted = try await store.enforceCacheLimits(totalByteLimit: 20, avatarByteLimit: 4)
        XCTAssertEqual(evicted, 1)
        let first = try await store.cacheEntry(for: firstAvatar, accessedAt: fixture.date(3))
        let second = try await store.cacheEntry(for: secondAvatar, accessedAt: fixture.date(3))
        let retainedSnapshot = try await store.cacheEntry(for: snapshot, accessedAt: fixture.date(3))
        XCTAssertNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotNil(retainedSnapshot)
        await store.close()
    }

    func testAvatarAttributionDeletesOnlyAccountExclusiveEntries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        let exclusive = try ForgeAvatarCacheKey(
            canonicalURL: XCTUnwrap(URL(string: "https://avatars.example/exclusive"))
        )
        let shared = try ForgeAvatarCacheKey(
            canonicalURL: XCTUnwrap(URL(string: "https://avatars.example/shared"))
        )
        let anonymous = try ForgeAvatarCacheKey(
            canonicalURL: XCTUnwrap(URL(string: "https://avatars.example/anonymous"))
        )

        try await store.putAvatarCacheEntry(
            fixture.entry(.avatar(exclusive), payload: "exclusive", fetched: 1, accessed: 1),
            owners: [.account(fixture.firstAccount)]
        )
        try await store.putAvatarCacheEntry(
            fixture.entry(.avatar(shared), payload: "shared", fetched: 2, accessed: 2),
            owners: [.account(fixture.firstAccount)]
        )
        let loadedShared = try await store.avatarCacheEntry(
            for: shared,
            owner: .account(fixture.secondAccount),
            accessedAt: fixture.date(3)
        )
        XCTAssertEqual(loadedShared?.payload, Data("shared".utf8))
        try await store.putCacheEntry(
            fixture.entry(.avatar(anonymous), payload: "anonymous", fetched: 3, accessed: 3)
        )
        try await store.associateAvatarCacheEntry(
            anonymous,
            owner: .account(fixture.firstAccount)
        )

        try await store.removeAccount(fixture.firstAccount)

        let removedExclusive = try await store.cacheEntry(for: .avatar(exclusive), accessedAt: fixture.date(4))
        let retainedShared = try await store.cacheEntry(for: .avatar(shared), accessedAt: fixture.date(4))
        let retainedAnonymous = try await store.cacheEntry(for: .avatar(anonymous), accessedAt: fixture.date(4))
        XCTAssertNil(removedExclusive)
        XCTAssertNotNil(retainedShared)
        XCTAssertNotNil(retainedAnonymous)
        let repeatedRemoval = try await store.removeAvatarAssociations(for: fixture.firstAccount)
        let finalOwnerRemoval = try await store.removeAvatarAssociations(for: fixture.secondAccount)
        XCTAssertEqual(repeatedRemoval, 0)
        XCTAssertEqual(finalOwnerRemoval, 1)
        let removedShared = try await store.cacheEntry(for: .avatar(shared), accessedAt: fixture.date(5))
        XCTAssertNil(removedShared)
        let firstAnonymousRemoval = try await store.removeAvatarCacheEntry(anonymous)
        let secondAnonymousRemoval = try await store.removeAvatarCacheEntry(anonymous)
        XCTAssertTrue(firstAnonymousRemoval)
        XCTAssertFalse(secondAnonymousRemoval)
        await store.close()
    }

    func testAvatarAttributionValidationAndForeignKeysFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        let avatar = try ForgeAvatarCacheKey(
            canonicalURL: XCTUnwrap(URL(string: "https://avatars.example/validation"))
        )
        let avatarEntry = try fixture.entry(.avatar(avatar), payload: "avatar", fetched: 1, accessed: 1)
        let snapshotEntry = try fixture.entry(
            fixture.snapshotKey(.publicAccess, identity: "not-avatar"),
            payload: "snapshot",
            fetched: 1,
            accessed: 1
        )

        await XCTAssertThrowsErrorAsync {
            try await store.putAvatarCacheEntry(snapshotEntry, owners: [.anonymous])
        } verify: {
            XCTAssertEqual($0.localizedDescription, ForgeSQLiteError.notAvatarCacheEntry.localizedDescription)
        }
        await XCTAssertThrowsErrorAsync {
            try await store.putAvatarCacheEntry(avatarEntry, owners: [])
        } verify: {
            XCTAssertEqual($0.localizedDescription, ForgeSQLiteError.missingAvatarOwner.localizedDescription)
        }
        let gitLab = try ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com"))
        let gitLabAccount = try ForgeAccountID(forge: gitLab, value: "foreign")
        await XCTAssertThrowsErrorAsync {
            try await store.putAvatarCacheEntry(avatarEntry, owners: [.account(gitLabAccount)])
        } verify: {
            XCTAssertEqual($0.localizedDescription, ForgeSQLiteError.unsupportedAvatarOwner.localizedDescription)
        }
        let enterprise = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.example"))
        let enterpriseAccount = try ForgeAccountID(forge: enterprise, value: "enterprise")
        await XCTAssertThrowsErrorAsync {
            try await store.putAvatarCacheEntry(avatarEntry, owners: [.account(enterpriseAccount)])
        } verify: {
            XCTAssertEqual($0.localizedDescription, ForgeSQLiteError.unsupportedAvatarOwner.localizedDescription)
        }
        await XCTAssertThrowsErrorAsync {
            try await store.associateAvatarCacheEntry(avatar, owner: .anonymous)
        }
        let missing = try await store.avatarCacheEntry(
            for: avatar,
            owner: .anonymous,
            accessedAt: fixture.date(2)
        )
        XCTAssertNil(missing)
        await store.close()
    }

    func testExactAvatarPurgeRemovesZeroByteRowsAndPreservesSnapshots() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        let avatar = try ForgeAvatarCacheKey(
            canonicalURL: XCTUnwrap(URL(string: "https://avatars.example/zero-byte"))
        )
        let snapshot = try fixture.snapshotKey(.publicAccess, identity: "purge-boundary")
        try await store.putCacheEntry(
            fixture.entry(.avatar(avatar), payload: "", fetched: 1, accessed: 1)
        )
        try await store.putCacheEntry(
            fixture.entry(snapshot, payload: "snapshot", fetched: 1, accessed: 1)
        )

        let removed = try await store.removeAllAvatarCacheEntries()

        let removedAvatar = try await store.cacheEntry(for: .avatar(avatar), accessedAt: fixture.date(2))
        let retainedSnapshot = try await store.cacheEntry(for: snapshot, accessedAt: fixture.date(2))
        XCTAssertEqual(removed, 1)
        XCTAssertNil(removedAvatar)
        XCTAssertEqual(retainedSnapshot?.payload, Data("snapshot".utf8))
        XCTAssertEqual(try RawSQLite.scalar(
            "SELECT COUNT(*) FROM forge_avatar_cache_owners",
            at: fixture.databaseURL
        ), 0)
        await store.close()
    }

    func testNonGitHubAccountRemovalStillDeletesOrdinaryPartitions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        let forge = try ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com"))
        let account = try ForgeAccountID(forge: forge, value: "gitlab-account")
        let repository = try ForgeRepositoryIdentity(
            forge: forge,
            owner: "example",
            name: "project"
        )
        let snapshot = try ForgeDisposableCacheKey.snapshot(ForgeCacheRecordKey(
            repositoryPartition: ForgeRepositoryPartitionKey(
                cachePartition: .account(account),
                repository: repository
            ),
            kind: .repositoryFacts,
            identity: "gitlab-removal"
        ))
        let durable = try ForgeSQLiteDurableRecord(
            kind: .attention,
            accountID: account,
            repository: repository,
            key: Data("gitlab-attention".utf8),
            payload: Data("state".utf8),
            lastActivityAt: fixture.date(1)
        )
        try await store.putCacheEntry(
            fixture.entry(snapshot, payload: "cached", fetched: 1, accessed: 1)
        )
        try await store.saveDurableRecord(durable)

        try await store.removeAccount(account)

        let removedSnapshot = try await store.cacheEntry(for: snapshot, accessedAt: fixture.date(2))
        let removedDurable = try await store.durableRecord(
            kind: durable.kind,
            accountID: account,
            repository: repository,
            key: durable.key
        )
        let unsupportedAvatarAssociations = try await store.removeAvatarAssociations(for: account)
        XCTAssertNil(removedSnapshot)
        XCTAssertNil(removedDurable)
        XCTAssertEqual(unsupportedAvatarAssociations, 0)
        await store.close()
    }

    func testVersionOneAvatarRowsMigrateAsAnonymousSharedEntries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let avatar = try ForgeAvatarCacheKey(
            canonicalURL: XCTUnwrap(URL(string: "https://avatars.example/migrated"))
        )
        var store: ForgeSQLiteStore? = try ForgeSQLiteStore(configuration: fixture.configuration)
        try await store?.putCacheEntry(
            fixture.entry(.avatar(avatar), payload: "legacy", fetched: 1, accessed: 1)
        )
        await store?.close()
        store = nil
        try RawSQLite.execute(
            "DROP TABLE forge_avatar_cache_owners; PRAGMA user_version = 1;",
            at: fixture.databaseURL
        )

        store = try ForgeSQLiteStore(configuration: fixture.configuration)
        XCTAssertEqual(try RawSQLite.scalar("PRAGMA user_version", at: fixture.databaseURL), 3)
        try await store?.removeAccount(fixture.firstAccount)
        let migratedAvatar = try await store?.cacheEntry(for: .avatar(avatar), accessedAt: fixture.date(2))
        XCTAssertNotNil(migratedAvatar)
        XCTAssertEqual(try RawSQLite.scalar(
            "SELECT COUNT(*) FROM forge_avatar_cache_owners WHERE length(account_key) = 0",
            at: fixture.databaseURL
        ), 1)
        await store?.close()
    }

    func testVersionTwoDurableRowsMigrateWithoutLossAndAcceptUnknownOutcomes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var store: ForgeSQLiteStore? = try ForgeSQLiteStore(configuration: fixture.configuration)
        let attention = try fixture.record(.attention, key: "existing", payload: "state", activity: 1)
        try await store?.saveDurableRecord(attention)
        await store?.close()
        store = nil
        try RawSQLite.execute(
            """
            ALTER TABLE forge_durable_records RENAME TO forge_durable_records_v3;
            DROP INDEX forge_durable_expiration;
            CREATE TABLE forge_durable_records (
                kind INTEGER NOT NULL CHECK(kind IN (1, 2, 3)),
                account_key BLOB NOT NULL CHECK(length(account_key) > 0),
                repository_key BLOB NOT NULL CHECK(length(repository_key) > 0),
                record_key BLOB NOT NULL CHECK(length(record_key) > 0),
                payload BLOB NOT NULL,
                last_activity_at REAL NOT NULL,
                expires_at REAL,
                CHECK(expires_at IS NULL OR expires_at >= last_activity_at),
                PRIMARY KEY(kind, account_key, repository_key, record_key)
            );
            INSERT INTO forge_durable_records
                (kind, account_key, repository_key, record_key, payload, last_activity_at, expires_at)
            SELECT kind, account_key, repository_key, record_key, payload, last_activity_at, expires_at
            FROM forge_durable_records_v3;
            DROP TABLE forge_durable_records_v3;
            CREATE INDEX forge_durable_expiration
                ON forge_durable_records(expires_at) WHERE expires_at IS NOT NULL;
            PRAGMA user_version = 2;
            """,
            at: fixture.databaseURL
        )

        store = try ForgeSQLiteStore(configuration: fixture.configuration)
        XCTAssertEqual(try RawSQLite.scalar("PRAGMA user_version", at: fixture.databaseURL), 3)
        let migratedAttention = try await store?.durableRecord(
            kind: .attention,
            accountID: attention.accountID,
            repository: attention.repository,
            key: attention.key
        )
        XCTAssertEqual(migratedAttention, attention)

        let unknownOutcome = try fixture.record(
            .unknownMutationOutcome,
            key: "mutation",
            payload: "redacted",
            activity: 2
        )
        try await store?.saveDurableRecord(unknownOutcome)
        let persistedUnknownOutcome = try await store?.durableRecord(
            kind: .unknownMutationOutcome,
            accountID: unknownOutcome.accountID,
            repository: unknownOutcome.repository,
            key: unknownOutcome.key
        )
        XCTAssertEqual(persistedUnknownOutcome, unknownOutcome)
        await store?.close()
    }

    func testDurableKindsPersistExpireAndDeleteIndependently() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var store: ForgeSQLiteStore? = try ForgeSQLiteStore(configuration: fixture.configuration)
        let draft = try fixture.record(.draft, key: "destination+head", payload: "draft", activity: 1)
        let watched = try fixture.record(.watchedRepository, key: "watch", payload: "watch", activity: 1)
        let attention = try fixture.record(.attention, key: "mention", payload: "seen", activity: 1)
        let unseenAttention = try ForgeSQLiteDurableRecord(
            kind: .attention,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: Data("unseen-active".utf8),
            payload: Data("unseen".utf8),
            lastActivityAt: fixture.date(1)
        )

        try await store?.saveDurableRecord(draft)
        try await store?.saveDurableRecord(watched)
        try await store?.saveDurableRecord(attention)
        try await store?.saveDurableRecord(unseenAttention)
        try await store?.saveDurableRecord(fixture.record(
            .draft,
            key: "destination+head",
            payload: "edited",
            activity: 2
        ))
        await store?.close()
        store = try ForgeSQLiteStore(configuration: fixture.configuration)

        let edited = try await store?.durableRecord(
            kind: .draft,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: Data("destination+head".utf8)
        )
        XCTAssertEqual(edited?.payload, Data("edited".utf8))
        let expired = try await store?.removeExpiredDurableRecords(
            at: fixture.date(ForgePolicyConstants.durableRecordExpiration + 10)
        )
        XCTAssertEqual(expired, 2)
        let removedAttention = try await store?.durableRecord(
            kind: .attention,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: Data("mention".utf8)
        )
        XCTAssertNil(removedAttention)
        let retainedUnseenAttention = try await store?.durableRecord(
            kind: .attention,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: Data("unseen-active".utf8)
        )
        XCTAssertNotNil(retainedUnseenAttention)
        let retainedWatch = try await store?.durableRecord(
            kind: .watchedRepository,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: Data("watch".utf8)
        )
        XCTAssertNotNil(retainedWatch)
        let firstDelete = try await store?.deleteDurableRecord(
            kind: .watchedRepository,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: Data("watch".utf8)
        )
        XCTAssertTrue(firstDelete == true)
        let secondDelete = try await store?.deleteDurableRecord(
            kind: .watchedRepository,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: Data("watch".utf8)
        )
        XCTAssertFalse(secondDelete == true)
        await store?.close()
    }

    func testDeleteDurableRecordsScopesBulkRemovalByKindAccountAndRepository() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        let firstAttention = try fixture.record(.attention, key: "first", payload: "one", activity: 1)
        let secondAttention = try fixture.record(.attention, key: "second", payload: "two", activity: 2)
        let retainedDraft = try fixture.record(.draft, key: "draft", payload: "draft", activity: 3)
        let retainedAccountAttention = try fixture.record(
            .attention,
            account: fixture.secondAccount,
            key: "other-account",
            payload: "other",
            activity: 4
        )
        for record in [firstAttention, secondAttention, retainedDraft, retainedAccountAttention] {
            try await store.saveDurableRecord(record)
        }

        let removed = try await store.deleteDurableRecords(
            kind: .attention,
            accountID: fixture.firstAccount,
            repository: fixture.repository
        )

        let removedAccountAttention = try await store.durableRecords(
            kind: .attention,
            accountID: fixture.firstAccount,
            repository: fixture.repository
        )
        let storedDraft = try await store.durableRecord(
            kind: .draft,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: retainedDraft.key
        )
        let storedOtherAccountAttention = try await store.durableRecord(
            kind: .attention,
            accountID: fixture.secondAccount,
            repository: fixture.repository,
            key: retainedAccountAttention.key
        )
        XCTAssertEqual(removed, 2)
        XCTAssertTrue(removedAccountAttention.isEmpty)
        XCTAssertEqual(storedDraft, retainedDraft)
        XCTAssertEqual(storedOtherAccountAttention, retainedAccountAttention)
        await store.close()
    }

    func testCanonicalDraftIdentityPersistsByExactAccountDestinationAndDisplayedHead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        let destination = try ForgeDraftDestination.inlineReview(
            repository: fixture.repository,
            pullRequest: ForgeItemNumber(17),
            path: ForgeFilePath("Sources/Feature.swift"),
            selection: ForgeLineSelection(start: 4, end: 7)
        )
        let identity = try ForgeDraftIdentity(
            accountID: fixture.firstAccount,
            destination: destination,
            displayedPullRequestHead: ForgeCommitID("abcdef12")
        )
        let draft = try ForgeDraft(
            identity: identity,
            content: ForgeDraftContent(body: "private draft body"),
            createdAt: fixture.date(1),
            lastActivityAt: fixture.date(2)
        )
        let record = try ForgeSQLiteDurableRecord(
            kind: .draft,
            accountID: identity.accountID,
            repository: identity.destination.repository,
            key: ForgeSQLiteStore.encodedKey(identity),
            payload: ForgeSQLiteStore.encodedKey(draft),
            lastActivityAt: draft.lastActivityAt,
            expiresAt: draft.lastActivityAt.addingTimeInterval(ForgePolicyConstants.durableRecordExpiration)
        )
        try await store.saveDurableRecord(record)

        let otherHeadIdentity = try ForgeDraftIdentity(
            accountID: fixture.firstAccount,
            destination: destination,
            displayedPullRequestHead: ForgeCommitID("12345678")
        )
        let loaded = try await store.durableRecord(
            kind: .draft,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: ForgeSQLiteStore.encodedKey(identity)
        )
        let wrongHead = try await store.durableRecord(
            kind: .draft,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: ForgeSQLiteStore.encodedKey(otherHeadIdentity)
        )
        XCTAssertEqual(loaded, record)
        XCTAssertNil(wrongHead)
        XCTAssertEqual(try JSONDecoder().decode(ForgeDraft.self, from: XCTUnwrap(loaded).payload), draft)
        await store.close()
    }

    func testAccountRemovalIsTransactionalAndLeavesPublicAndOtherAccountData() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        let publicKey = try fixture.snapshotKey(.publicAccess, identity: "repo")
        let firstKey = try fixture.snapshotKey(.account(fixture.firstAccount), identity: "repo")
        let secondKey = try fixture.snapshotKey(.account(fixture.secondAccount), identity: "repo")
        for (key, payload) in [(publicKey, "public"), (firstKey, "first"), (secondKey, "second")] {
            try await store.putCacheEntry(fixture.entry(key, payload: payload, fetched: 1, accessed: 1))
        }
        try await store.saveDurableRecord(fixture.record(.draft, key: "first", payload: "first", activity: 1))
        try await store.saveDurableRecord(fixture.record(
            .draft,
            account: fixture.secondAccount,
            key: "second",
            payload: "second",
            activity: 1
        ))

        try await store.removeAccount(fixture.firstAccount)

        let removedCache = try await store.cacheEntry(
            for: firstKey,
            accessedAt: fixture.date(2)
        )
        XCTAssertNil(removedCache)
        let publicCache = try await store.cacheEntry(
            for: publicKey,
            accessedAt: fixture.date(2)
        )
        XCTAssertNotNil(publicCache)
        let otherCache = try await store.cacheEntry(
            for: secondKey,
            accessedAt: fixture.date(2)
        )
        XCTAssertNotNil(otherCache)
        let removedDraft = try await store.durableRecord(
            kind: .draft,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: Data("first".utf8)
        )
        XCTAssertNil(removedDraft)
        let otherDraft = try await store.durableRecord(
            kind: .draft,
            accountID: fixture.secondAccount,
            repository: fixture.repository,
            key: Data("second".utf8)
        )
        XCTAssertNotNil(otherDraft)
        await store.close()
    }

    func testValidationAndClosedStoreErrorsAreExplicit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let foreignForge = try ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.example"))
        let foreignAccount = try ForgeAccountID(forge: foreignForge, value: "foreign")
        XCTAssertThrowsError(try ForgeRepositoryPartitionKey(
            cachePartition: .account(foreignAccount),
            repository: fixture.repository
        ))
        XCTAssertThrowsError(try ForgeSQLiteDurableRecord(
            kind: .draft,
            accountID: foreignAccount,
            repository: fixture.repository,
            key: Data([1]),
            payload: Data(),
            lastActivityAt: fixture.date(1)
        ))
        XCTAssertThrowsError(try fixture.record(.draft, key: "", payload: "", activity: 1))
        XCTAssertThrowsError(try ForgeSQLiteDurableRecord(
            kind: .draft,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: Data([1]),
            payload: Data(),
            lastActivityAt: Date(timeIntervalSince1970: .infinity)
        ))
        XCTAssertThrowsError(try ForgeSQLiteDurableRecord(
            kind: .draft,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: Data([1]),
            payload: Data(),
            lastActivityAt: fixture.date(1),
            expiresAt: Date(timeIntervalSince1970: .infinity)
        ))

        let key = try fixture.snapshotKey(.publicAccess, identity: "size")
        XCTAssertThrowsError(try ForgeSQLiteCacheEntry(
            record: ForgeDisposableCacheRecord(
                key: key,
                byteCount: 2,
                fetchedAt: fixture.date(1),
                lastAccessedAt: fixture.date(1)
            ),
            payload: Data([1])
        ))
        XCTAssertThrowsError(try ForgeSQLiteCacheEntry(
            record: ForgeDisposableCacheRecord(
                key: key,
                byteCount: 0,
                fetchedAt: Date(timeIntervalSince1970: .infinity),
                lastAccessedAt: Date(timeIntervalSince1970: .infinity)
            ),
            payload: Data()
        ))
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        do {
            _ = try await store.cacheEntry(
                for: key,
                accessedAt: Date(timeIntervalSince1970: .infinity)
            )
            XCTFail("Expected an invalid access timestamp")
        } catch {
            XCTAssertEqual(error.localizedDescription, ForgeSQLiteError.invalidTimestamp.localizedDescription)
        }
        do {
            _ = try await store.removeIdleCacheRepositories(
                notAccessedSince: Date(timeIntervalSince1970: .infinity)
            )
            XCTFail("Expected an invalid idle cutoff")
        } catch {
            XCTAssertEqual(error.localizedDescription, ForgeSQLiteError.invalidTimestamp.localizedDescription)
        }
        do {
            _ = try await store.removeExpiredDurableRecords(
                at: Date(timeIntervalSince1970: .infinity)
            )
            XCTFail("Expected an invalid expiration time")
        } catch {
            XCTAssertEqual(error.localizedDescription, ForgeSQLiteError.invalidTimestamp.localizedDescription)
        }
        await store.close()
        do {
            _ = try await store.enforceCacheLimits(totalByteLimit: 0, avatarByteLimit: 0)
            XCTFail("Expected closed store")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The Forge SQLite store is closed.")
        }
    }

    func testSQLiteRowRejectsMismatchedAndNonfiniteStorageClasses() {
        XCTAssertThrowsError(try ForgeSQLiteRow(values: [.text("integer")]).integer(0))
        XCTAssertThrowsError(try ForgeSQLiteRow(values: [.integer(1)]).double(0))
        XCTAssertThrowsError(try ForgeSQLiteRow(values: [.double(.infinity)]).double(0))
        XCTAssertThrowsError(try ForgeSQLiteRow(values: [.blob(Data())]).text(0))
    }

    func testRestorePreservesDurableRecordWithoutExpiration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record(
            .watchedRepository,
            key: "watch-without-expiration",
            payload: "watch",
            activity: 1
        )
        XCTAssertNil(record.expiresAt)
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)

        try await store.restore(ForgeSQLiteSalvage(
            durableRecords: [record],
            skippedRecordCount: 0
        ))
        let restored = try await store.durableRecord(
            kind: record.kind,
            accountID: record.accountID,
            repository: record.repository,
            key: record.key
        )
        XCTAssertEqual(restored, record)
        await store.close()
    }

    func testMalformedSQLiteStorageClassesFailClosedAndSalvageSkipsThem() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var store: ForgeSQLiteStore? = try ForgeSQLiteStore(configuration: fixture.configuration)
        let cacheKey = try fixture.snapshotKey(.publicAccess, identity: "malformed")
        try await store?.putCacheEntry(fixture.entry(cacheKey, payload: "cache", fetched: 1, accessed: 1))
        let durable = try fixture.record(.draft, key: "malformed", payload: "draft", activity: 1)
        try await store?.saveDurableRecord(durable)
        try RawSQLite.execute(
            """
            PRAGMA ignore_check_constraints = ON;
            UPDATE forge_cache_entries SET byte_count = -1;
            UPDATE forge_durable_records SET payload = 17;
            """,
            at: fixture.databaseURL
        )

        do {
            _ = try await store?.cacheEntry(for: cacheKey, accessedAt: fixture.date(3))
            XCTFail("Expected malformed cache byte count to fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("negative byte count"))
        }
        do {
            _ = try await store?.durableRecord(
                kind: .draft,
                accountID: fixture.firstAccount,
                repository: fixture.repository,
                key: durable.key
            )
            XCTFail("Expected malformed durable timestamp to fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("BLOB"))
        }
        await store?.close()
        store = nil

        let salvage = try ForgeSQLiteStore.salvageDurableRecords(from: fixture.databaseURL)
        XCTAssertTrue(salvage.durableRecords.isEmpty)
        XCTAssertEqual(salvage.skippedRecordCount, 1)
    }

    func testNewDatabaseMigratesTransactionallyAndUsesOwnerOnlyPermissions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        await store.close()

        XCTAssertEqual(try RawSQLite.scalar("PRAGMA user_version", at: fixture.databaseURL), 3)
        XCTAssertEqual(try RawSQLite.scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name LIKE 'forge_%'",
            at: fixture.databaseURL
        ), 3)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.databaseURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: fixture.root.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testSQLitePrimitivesFailClosedAcrossOpenIntegritySchemaAndStepErrors() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directoryDatabase = fixture.root.appendingPathComponent("directory.sqlite3", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryDatabase, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ForgeSQLiteConnection(url: directoryDatabase))

        let databaseURL = fixture.root.appendingPathComponent("primitives.sqlite3")
        let connection = try ForgeSQLiteConnection(url: databaseURL)
        try connection.configure()
        try connection.migrate(to: ForgeSQLiteStore.schemaVersion)
        XCTAssertThrowsError(try connection.verifySchema(version: ForgeSQLiteStore.schemaVersion + 1))
        try connection.execute("CREATE TABLE unique_values(value INTEGER PRIMARY KEY)")
        try connection.execute("INSERT INTO unique_values VALUES (1)")
        XCTAssertThrowsError(try connection.execute("INSERT INTO unique_values VALUES (1)"))
        XCTAssertThrowsError(try connection.query("INSERT INTO unique_values VALUES (1) RETURNING value"))
        XCTAssertEqual(try connection.scalarInt("SELECT value FROM unique_values WHERE value = 2"), 0)

        let existingBackup = fixture.root.appendingPathComponent("existing-backup.sqlite3", isDirectory: true)
        try FileManager.default.createDirectory(at: existingBackup, withIntermediateDirectories: false)
        XCTAssertThrowsError(try connection.backup(to: existingBackup))
        let invalidSourceBackup = fixture.root.appendingPathComponent("invalid-source-backup.sqlite3")
        XCTAssertThrowsError(try connection.backup(to: invalidSourceBackup, sourceName: "missing"))
        connection.close()
        connection.close()
        XCTAssertThrowsError(try connection.execute("SELECT 1"))

        XCTAssertThrowsError(try connection.verifyIntegrity([
            ForgeSQLiteRow(values: [.text("not ok")]),
        ]))
    }

    func testSQLiteConnectionDeinitClosesHandleAndReleasesExclusiveTransaction() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let databaseURL = fixture.root.appendingPathComponent("deinit.sqlite3")
        var first: ForgeSQLiteConnection? = try ForgeSQLiteConnection(url: databaseURL)
        try first?.execute("CREATE TABLE values_table(value INTEGER)")
        try first?.execute("BEGIN EXCLUSIVE")

        first = nil

        let replacement = try ForgeSQLiteConnection(url: databaseURL)
        XCTAssertNoThrow(try replacement.execute("BEGIN IMMEDIATE"))
        XCTAssertNoThrow(try replacement.execute("COMMIT"))
        replacement.close()
    }

    func testMigrationFailureRollsBackAndCopiesDatabaseInsteadOfResetting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try RawSQLite.execute(
            "CREATE TABLE forge_durable_records (conflict INTEGER); PRAGMA user_version = 0;",
            at: fixture.databaseURL
        )

        let copy = try recoveryCopy(from: fixture) {
            _ = try ForgeSQLiteStore(configuration: fixture.configuration)
        }
        XCTAssertEqual(try RawSQLite.scalar("PRAGMA user_version", at: copy.url), 0)
        XCTAssertEqual(try RawSQLite.scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='forge_cache_entries'",
            at: copy.url
        ), 0)
        XCTAssertEqual(try RawSQLite.scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='forge_durable_records'",
            at: copy.url
        ), 1)
    }

    func testCurrentVersionWithMissingSchemaIsPreservedForRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try RawSQLite.execute("CREATE TABLE unrelated(value INTEGER); PRAGMA user_version = 3;", at: fixture.databaseURL)

        let copy = try recoveryCopy(from: fixture) {
            _ = try ForgeSQLiteStore(configuration: fixture.configuration)
        }
        XCTAssertEqual(try RawSQLite.scalar("PRAGMA user_version", at: copy.url), 3)
        XCTAssertEqual(try RawSQLite.scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='unrelated'",
            at: copy.url
        ), 1)
    }

    func testCorruptDatabaseIsPreservedExactlyAndMarkedAsRecoveryData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data("not a sqlite database\u{0}private draft".utf8)
        try original.write(to: fixture.databaseURL)

        let copy = try recoveryCopy(from: fixture) {
            _ = try ForgeSQLiteStore(configuration: fixture.configuration)
        }
        XCTAssertEqual(try Data(contentsOf: copy.url), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: copy.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try copy.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try Data(contentsOf: fixture.databaseURL), original)
    }

    func testRawRecoveryFallbackPreservesAndSecuresEveryJournalSidecar() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let main = Data("damaged main".utf8)
        try main.write(to: fixture.databaseURL)
        let suffixes = ["-wal", "-shm", "-journal"]
        for suffix in suffixes {
            try Data(suffix.utf8).write(to: URL(fileURLWithPath: fixture.databaseURL.path + suffix))
        }

        let copy = try ForgeSQLiteStore.makeRecoveryCopy(
            of: fixture.databaseURL,
            in: fixture.recoveryURL,
            at: fixture.date(1)
        )
        XCTAssertEqual(try Data(contentsOf: copy.url), main)
        XCTAssertEqual(copy.sidecarURLs.count, suffixes.count)
        for sidecar in copy.sidecarURLs {
            let attributes = try FileManager.default.attributesOfItem(atPath: sidecar.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(
                try sidecar.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
                true
            )
        }
        let invalidSidecar = URL(fileURLWithPath: copy.url.path + "-other")
        try Data("must remain".utf8).write(to: invalidSidecar)
        XCTAssertThrowsError(try ForgeSQLiteStore.deleteRecoveryCopy(
            ForgeSQLiteRecoveryCopy(
                url: copy.url,
                sidecarURLs: copy.sidecarURLs + [invalidSidecar],
                createdAt: copy.createdAt
            ),
            in: fixture.recoveryURL
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.url.path))
        try ForgeSQLiteStore.deleteRecoveryCopy(
            ForgeSQLiteRecoveryCopy(url: copy.url, createdAt: copy.createdAt),
            in: fixture.recoveryURL
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.url.path))
        XCTAssertTrue(copy.sidecarURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testFutureSchemaIsPreservedAndKnownDurableRowsCanBeSalvaged() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try ForgeSQLiteStore(configuration: fixture.configuration)
        let valid = try fixture.record(.draft, key: "draft-key", payload: "content", activity: 4)
        try await original.saveDurableRecord(valid)
        let disposableKey = try fixture.snapshotKey(.account(fixture.firstAccount), identity: "snapshot")
        try await original.putCacheEntry(fixture.entry(
            disposableKey,
            payload: "disposable",
            fetched: 1,
            accessed: 1
        ))
        await original.close()
        try RawSQLite.execute(
            "UPDATE forge_durable_records SET account_key = X'FF' WHERE record_key = X'626164';",
            at: fixture.databaseURL
        )
        try RawSQLite.execute("PRAGMA user_version = 99;", at: fixture.databaseURL)

        let copy = try recoveryCopy(from: fixture) {
            _ = try ForgeSQLiteStore(configuration: fixture.configuration)
        }
        let salvage = try ForgeSQLiteStore.salvageDurableRecords(from: copy.url)
        XCTAssertEqual(salvage.durableRecords, [valid])
        XCTAssertEqual(salvage.skippedRecordCount, 0)

        try FileManager.default.removeItem(at: fixture.databaseURL)
        let replacement = try ForgeSQLiteStore(configuration: fixture.configuration)
        try await replacement.restore(salvage)
        let restored = try await replacement.durableRecord(
            kind: .draft,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: Data("draft-key".utf8)
        )
        XCTAssertEqual(restored, valid)
        let restoredCache = try await replacement.cacheEntry(
            for: disposableKey,
            accessedAt: fixture.date(5)
        )
        XCTAssertNil(restoredCache)
        await replacement.close()
    }

    func testSalvageSkipsMalformedAndUnknownDurableRows() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        try await store.saveDurableRecord(fixture.record(.attention, key: "bad", payload: "state", activity: 1))
        try await store.saveDurableRecord(fixture.record(.draft, key: "unknown", payload: "draft", activity: 1))
        await store.close()
        try RawSQLite.execute(
            """
            PRAGMA ignore_check_constraints = ON;
            UPDATE forge_durable_records SET account_key = X'FF' WHERE record_key = X'626164';
            UPDATE forge_durable_records SET kind = 99 WHERE record_key = X'756e6b6e6f776e';
            """,
            at: fixture.databaseURL
        )

        let salvage = try ForgeSQLiteStore.salvageDurableRecords(from: fixture.databaseURL)
        XCTAssertTrue(salvage.durableRecords.isEmpty)
        XCTAssertEqual(salvage.skippedRecordCount, 2)

        let emptyURL = fixture.root.appendingPathComponent("empty.sqlite3")
        try RawSQLite.execute("CREATE TABLE unrelated (value INTEGER);", at: emptyURL)
        XCTAssertEqual(
            try ForgeSQLiteStore.salvageDurableRecords(from: emptyURL),
            ForgeSQLiteSalvage(durableRecords: [], skippedRecordCount: 0)
        )
    }

    func testSalvageSkipsInvalidTimestampOrderingWithoutAbortingValidRows() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try ForgeSQLiteStore(configuration: fixture.configuration)
        let invalid = try fixture.record(.draft, key: "invalid-order", payload: "bad", activity: 1)
        let valid = try fixture.record(.draft, key: "valid-order", payload: "good", activity: 2)
        try await store.saveDurableRecord(invalid)
        try await store.saveDurableRecord(valid)
        await store.close()
        try RawSQLite.execute(
            """
            PRAGMA ignore_check_constraints = ON;
            UPDATE forge_durable_records SET expires_at = last_activity_at - 1 WHERE record_key = X'696e76616c69642d6f72646572';
            """,
            at: fixture.databaseURL
        )

        let salvage = try ForgeSQLiteStore.salvageDurableRecords(from: fixture.databaseURL)
        XCTAssertEqual(salvage.durableRecords, [valid])
        XCTAssertEqual(salvage.skippedRecordCount, 1)

        let replacementURL = fixture.root.appendingPathComponent("replacement.sqlite3")
        let replacement = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: replacementURL,
            recoveryDirectoryURL: fixture.recoveryURL
        ))
        try await replacement.restore(salvage)
        let restored = try await replacement.durableRecord(
            kind: .draft,
            accountID: fixture.firstAccount,
            repository: fixture.repository,
            key: valid.key
        )
        XCTAssertEqual(restored, valid)
        await replacement.close()
    }

    func testRecoveryCopiesCanBeListedExpiredAndDeletedOnlyWithinRecoveryDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(try ForgeSQLiteStore.recoveryCopies(
            in: fixture.recoveryURL,
            now: fixture.date(1),
            maximumAge: 100
        ), [])
        try RawSQLite.execute("CREATE TABLE future(value INTEGER); PRAGMA user_version = 99;", at: fixture.databaseURL)
        let copy = try recoveryCopy(from: fixture) {
            _ = try ForgeSQLiteStore(configuration: fixture.configuration)
        }

        XCTAssertEqual(try ForgeSQLiteStore.recoveryCopies(
            in: fixture.recoveryURL,
            now: Date(),
            maximumAge: .infinity
        ).map { $0.url.resolvingSymlinksInPath() }, [copy.url.resolvingSymlinksInPath()])
        try ForgeSQLiteStore.deleteRecoveryCopy(copy, in: fixture.recoveryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.url.path))

        let outside = fixture.root.appendingPathComponent("ForgeKit-recovery-outside.sqlite3")
        try Data().write(to: outside)
        XCTAssertThrowsError(try ForgeSQLiteStore.deleteRecoveryCopy(
            ForgeSQLiteRecoveryCopy(url: outside, createdAt: Date()),
            in: fixture.recoveryURL
        ))

        let expiredCopy = try recoveryCopy(from: fixture) {
            _ = try ForgeSQLiteStore(configuration: fixture.configuration)
        }
        let expiredSidecar = URL(fileURLWithPath: expiredCopy.url.path + "-wal")
        try Data("private expired fragment".utf8).write(to: expiredSidecar)
        XCTAssertEqual(try ForgeSQLiteStore.recoveryCopies(
            in: fixture.recoveryURL,
            now: .distantFuture
        ), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredSidecar.path))
    }

    func testExpiredOrphanRecoverySidecarsAreRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.recoveryURL, withIntermediateDirectories: true)
        let orphan = fixture.recoveryURL
            .appendingPathComponent("ForgeKit-recovery-orphan.sqlite3-wal")
        try Data("private draft fragment".utf8).write(to: orphan)

        XCTAssertEqual(try ForgeSQLiteStore.recoveryCopies(
            in: fixture.recoveryURL,
            now: .distantFuture
        ), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testEncodedKeysAreStableAndErrorsDoNotExposePayloads() throws {
        struct Key: Encodable { let z: Int; let a: String }
        XCTAssertEqual(
            try ForgeSQLiteStore.encodedKey(Key(z: 2, a: "one")),
            Data(#"{"a":"one","z":2}"#.utf8)
        )
        let copy = ForgeSQLiteRecoveryCopy(url: URL(fileURLWithPath: "/tmp/recovery.sqlite3"), createdAt: Date())
        XCTAssertTrue(ForgeSQLiteError.recoveryRequired(copy: copy, reason: "failed").localizedDescription.contains("recovery.sqlite3"))
        XCTAssertTrue(ForgeSQLiteError.sqlite(operation: "query", code: 1, message: "bad").localizedDescription.contains("query"))
        XCTAssertEqual(ForgeSQLiteError.mismatchedAccountForge.localizedDescription, "The Forge Account and repository belong to different Forges.")
        XCTAssertEqual(ForgeSQLiteError.emptyKey.localizedDescription, "SQLite record keys must not be empty.")
        XCTAssertEqual(
            ForgeSQLiteError.mismatchedByteCount.localizedDescription,
            "The Forge cache payload size differs from its validated byte count."
        )
        XCTAssertEqual(ForgeSQLiteError.invalidTimestamp.localizedDescription, "Forge SQLite timestamps must be finite.")
        XCTAssertTrue(ForgeSQLiteError.invalidTimestampOrder.localizedDescription.contains("must not precede"))
        XCTAssertTrue(ForgeSQLiteError.notAvatarCacheEntry.localizedDescription.contains("avatar"))
        XCTAssertTrue(ForgeSQLiteError.missingAvatarOwner.localizedDescription.contains("owner"))
        XCTAssertTrue(ForgeSQLiteError.unsupportedAvatarOwner.localizedDescription.contains("GitHub.com"))
    }

    private func recoveryCopy(from fixture: Fixture, operation: () throws -> Void) throws -> ForgeSQLiteRecoveryCopy {
        do {
            try operation()
            XCTFail("Expected recovery-required error")
            throw CocoaError(.fileReadCorruptFile)
        } catch let ForgeSQLiteError.recoveryRequired(copy, reason) {
            XCTAssertFalse(reason.isEmpty)
            return copy
        } catch {
            XCTFail("Unexpected error: \(error)")
            throw error
        }
    }
}

private func XCTAssertThrowsErrorAsync<Result>(
    _ expression: () async throws -> Result,
    file: StaticString = #filePath,
    line: UInt = #line,
    verify: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        verify(error)
    }
}

private struct Fixture {
    let root: URL
    let databaseURL: URL
    let recoveryURL: URL
    let forge: ForgeIdentity
    let repository: ForgeRepositoryIdentity
    let firstAccount: ForgeAccountID
    let secondAccount: ForgeAccountID

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeSQLitePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = root.appendingPathComponent("Forge.sqlite3")
        recoveryURL = root.appendingPathComponent("Recovery", isDirectory: true)
        forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        repository = try ForgeRepositoryIdentity(forge: forge, owner: "acme", name: "widgets")
        firstAccount = try ForgeAccountID(forge: forge, value: "account-1")
        secondAccount = try ForgeAccountID(forge: forge, value: "account-2")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var configuration: ForgeSQLiteConfiguration {
        ForgeSQLiteConfiguration(databaseURL: databaseURL, recoveryDirectoryURL: recoveryURL)
    }

    func snapshotKey(
        _ partition: ForgeCachePartition,
        identity: String
    ) throws -> ForgeDisposableCacheKey {
        let repositoryPartition = try ForgeRepositoryPartitionKey(
            cachePartition: partition,
            repository: repository
        )
        return .snapshot(ForgeCacheRecordKey(
            repositoryPartition: repositoryPartition,
            kind: .pullRequestDetail,
            identity: identity
        ))
    }

    func entry(
        _ key: ForgeDisposableCacheKey,
        payload: String,
        fetched: TimeInterval,
        accessed: TimeInterval,
        completeness: ForgeSnapshotCompleteness = .complete
    ) throws -> ForgeSQLiteCacheEntry {
        let data = Data(payload.utf8)
        return try ForgeSQLiteCacheEntry(
            record: ForgeDisposableCacheRecord(
                key: key,
                byteCount: UInt64(data.count),
                fetchedAt: date(fetched),
                lastAccessedAt: date(accessed),
                completeness: completeness
            ),
            payload: data
        )
    }

    func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    func record(
        _ kind: ForgeSQLiteDurableKind,
        account: ForgeAccountID? = nil,
        key: String,
        payload: String,
        activity: TimeInterval
    ) throws -> ForgeSQLiteDurableRecord {
        try ForgeSQLiteDurableRecord(
            kind: kind,
            accountID: account ?? firstAccount,
            repository: repository,
            key: Data(key.utf8),
            payload: Data(payload.utf8),
            lastActivityAt: date(activity),
            expiresAt: kind == .watchedRepository
                ? nil
                : date(activity + ForgePolicyConstants.durableRecordExpiration)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum RawSQLite {
    static func execute(_ sql: String, at url: URL) throws {
        let database = try open(url)
        defer { sqlite3_close(database) }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw NSError(domain: "RawSQLite", code: Int(result), userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }

    static func scalar(_ sql: String, at url: URL) throws -> Int64 {
        let database = try open(url)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "RawSQLite", code: 1)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "RawSQLite", code: 2)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private static func open(_ url: URL) throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        let result = sqlite3_open(url.path, &database)
        guard result == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw NSError(domain: "RawSQLite", code: Int(result))
        }
        return database
    }
}
