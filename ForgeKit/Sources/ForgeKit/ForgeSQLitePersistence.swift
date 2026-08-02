import Foundation
import OSLog // swiftlint:disable:this unused_import
import SQLite3

public enum ForgeSQLiteDurableKind: Int, Codable, CaseIterable, Hashable, Sendable {
    case draft = 1
    case watchedRepository = 2
    case attention = 3
    case unknownMutationOutcome = 4
}

public struct ForgeSQLiteCacheEntry: Equatable, Sendable {
    public let record: ForgeDisposableCacheRecord
    public let payload: Data

    public init(record: ForgeDisposableCacheRecord, payload: Data) throws {
        guard record.byteCount == payload.count else {
            throw ForgeSQLiteError.mismatchedByteCount
        }
        guard record.fetchedAt.timeIntervalSince1970.isFinite,
              record.lastAccessedAt.timeIntervalSince1970.isFinite
        else { throw ForgeSQLiteError.invalidTimestamp }
        self.record = record
        self.payload = payload
    }
}

public struct ForgeSQLiteDurableRecord: Equatable, Sendable {
    public let kind: ForgeSQLiteDurableKind
    public let accountID: ForgeAccountID
    public let repository: ForgeRepositoryIdentity
    public let key: Data
    public let payload: Data
    public let lastActivityAt: Date
    public let expiresAt: Date?

    public init(
        kind: ForgeSQLiteDurableKind,
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        key: Data,
        payload: Data,
        lastActivityAt: Date,
        expiresAt: Date? = nil
    ) throws {
        guard accountID.forge == repository.forge else {
            throw ForgeSQLiteError.mismatchedAccountForge
        }
        guard !key.isEmpty else { throw ForgeSQLiteError.emptyKey }
        guard lastActivityAt.timeIntervalSince1970.isFinite else {
            throw ForgeSQLiteError.invalidTimestamp
        }
        guard expiresAt?.timeIntervalSince1970.isFinite != false else {
            throw ForgeSQLiteError.invalidTimestamp
        }
        guard expiresAt.map({ $0 >= lastActivityAt }) != false else {
            throw ForgeSQLiteError.invalidTimestampOrder
        }
        self.kind = kind
        self.accountID = accountID
        self.repository = repository
        self.key = key
        self.payload = payload
        self.lastActivityAt = lastActivityAt
        self.expiresAt = expiresAt
    }
}

public struct ForgeSQLiteRecoveryCopy: Equatable, Sendable {
    public let url: URL
    public let sidecarURLs: [URL]
    public let createdAt: Date

    public init(url: URL, sidecarURLs: [URL] = [], createdAt: Date) {
        self.url = url
        self.sidecarURLs = sidecarURLs
        self.createdAt = createdAt
    }
}

public struct ForgeSQLiteSalvage: Equatable, Sendable {
    public let durableRecords: [ForgeSQLiteDurableRecord]
    public let skippedRecordCount: Int

    public init(durableRecords: [ForgeSQLiteDurableRecord], skippedRecordCount: Int) {
        self.durableRecords = durableRecords
        self.skippedRecordCount = skippedRecordCount
    }
}

public struct ForgeSQLiteConfiguration: Sendable {
    public let databaseURL: URL
    public let recoveryDirectoryURL: URL

    public init(databaseURL: URL, recoveryDirectoryURL: URL) {
        self.databaseURL = databaseURL
        self.recoveryDirectoryURL = recoveryDirectoryURL
    }
}

public enum ForgeSQLiteError: Error, LocalizedError, Sendable {
    case mismatchedAccountForge
    case emptyKey
    case mismatchedByteCount
    case invalidTimestamp
    case invalidTimestampOrder
    case notAvatarCacheEntry
    case missingAvatarOwner
    case unsupportedAvatarOwner
    case closed
    case sqlite(operation: String, code: Int32, message: String)
    case recoveryRequired(copy: ForgeSQLiteRecoveryCopy, reason: String)

    public var errorDescription: String? {
        switch self {
        case .mismatchedAccountForge:
            "The Forge Account and repository belong to different Forges."
        case .emptyKey:
            "SQLite record keys must not be empty."
        case .mismatchedByteCount:
            "The Forge cache payload size differs from its validated byte count."
        case .invalidTimestamp:
            "Forge SQLite timestamps must be finite."
        case .invalidTimestampOrder:
            "Forge SQLite expiration timestamps must not precede their last activity."
        case .notAvatarCacheEntry:
            "The Forge SQLite avatar operation requires an avatar cache entry."
        case .missingAvatarOwner:
            "A persisted Forge avatar must have at least one owner attribution."
        case .unsupportedAvatarOwner:
            "Structured avatar ownership is limited to anonymous or GitHub.com accounts."
        case .closed:
            "The Forge SQLite store is closed."
        case let .sqlite(operation, code, message):
            "SQLite \(operation) failed (\(code)): \(message)"
        case let .recoveryRequired(copy, reason):
            "The Forge database needs recovery from \(copy.url.lastPathComponent): \(reason)"
        }
    }
}

/// System-SQLite persistence for disposable Forge cache entries and durable Forge state.
///
/// Opening performs filesystem and migration work. Composition roots must construct the
/// store off the main thread, then retain the actor for serialized access.
///
/// The store deliberately accepts opaque keys and payloads. Cache-policy values such as
/// `ForgeDraftIdentity`, `ForgeWatchedRepositoryKey`, and `ForgeAttentionItemID` remain the
/// canonical owners of those semantics and can be encoded with `encodedKey(_:)`.
public actor ForgeSQLiteStore {
    public static let schemaVersion = 3

    private static let logger = Logger(subsystem: "com.gitx.ForgeKit", category: "SQLiteStore")
    private static let recoveryPrefix = "ForgeKit-recovery-"
    private static let recoverySuffix = ".sqlite3"

    private let configuration: ForgeSQLiteConfiguration
    private var connection: ForgeSQLiteConnection?

    public init(configuration: ForgeSQLiteConfiguration) throws {
        self.configuration = configuration
        try Self.prepareDirectory(configuration.databaseURL.deletingLastPathComponent())
        try Self.prepareDirectory(configuration.recoveryDirectoryURL)
        if !FileManager.default.fileExists(atPath: configuration.databaseURL.path) {
            _ = FileManager.default.createFile(
                atPath: configuration.databaseURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
        }
        try Self.secureFile(configuration.databaseURL, excludedFromBackup: false)

        do {
            let connection = try ForgeSQLiteConnection(url: configuration.databaseURL)
            do {
                try connection.configure()
                try connection.verifyIntegrity()
                try connection.migrate(to: Self.schemaVersion)
                try connection.verifySchema(version: Self.schemaVersion)
                self.connection = connection
                try Self.secureFile(configuration.databaseURL, excludedFromBackup: false)
                Self.logger.info("Opened Forge database at schema version \(Self.schemaVersion)")
            } catch {
                let backup = try? Self.makeRecoveryBackup(
                    using: connection,
                    in: configuration.recoveryDirectoryURL,
                    at: Date()
                )
                connection.close()
                if let backup {
                    Self.logger.error("Preserved a consistent Forge database recovery backup after open failure")
                    throw ForgeSQLiteError.recoveryRequired(
                        copy: backup,
                        reason: String(describing: error)
                    )
                }
                throw error
            }
        } catch {
            if let sqliteError = error as? ForgeSQLiteError,
               case .recoveryRequired = sqliteError
            {
                throw sqliteError
            }
            let copy = try Self.makeRecoveryCopy(
                of: configuration.databaseURL,
                in: configuration.recoveryDirectoryURL,
                at: Date()
            )
            Self.logger.error("Preserved a Forge database recovery copy after open failure")
            throw ForgeSQLiteError.recoveryRequired(copy: copy, reason: String(describing: error))
        }
    }

    public static func encodedKey<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public func close() {
        connection?.close()
        connection = nil
        Self.logger.info("Closed Forge database")
    }

    public func putCacheEntry(_ entry: ForgeSQLiteCacheEntry) throws {
        let connection = try activeConnection()
        if case .avatar = entry.record.key {
            try connection.transaction {
                try Self.upsertCacheEntry(entry, using: connection)
                try Self.associateAvatarOwner(
                    .anonymous,
                    recordKey: Self.cacheFields(entry.record.key).recordKey,
                    using: connection
                )
            }
        } else {
            try Self.upsertCacheEntry(entry, using: connection)
        }
        Self.logger.debug("Stored Forge cache record")
    }

    /// Stores credential-free avatar bytes and all accounts whose views caused
    /// the entry to be used. The cache payload remains shared; only attribution
    /// is account-specific.
    public func putAvatarCacheEntry(
        _ entry: ForgeSQLiteCacheEntry,
        owners: Set<ForgeAvatarCacheOwner>
    ) throws {
        guard case .avatar = entry.record.key else {
            throw ForgeSQLiteError.notAvatarCacheEntry
        }
        guard !owners.isEmpty else {
            throw ForgeSQLiteError.missingAvatarOwner
        }
        let connection = try activeConnection()
        let recordKey = try Self.cacheFields(entry.record.key).recordKey
        try connection.transaction {
            try Self.upsertCacheEntry(entry, using: connection)
            for owner in owners {
                try Self.associateAvatarOwner(owner, recordKey: recordKey, using: connection)
            }
        }
        Self.logger.debug("Stored attributed Forge avatar cache record")
    }

    public func avatarCacheEntry(
        for key: ForgeAvatarCacheKey,
        owner: ForgeAvatarCacheOwner,
        accessedAt: Date
    ) throws -> ForgeSQLiteCacheEntry? {
        let disposableKey = ForgeDisposableCacheKey.avatar(key)
        guard let entry = try cacheEntry(for: disposableKey, accessedAt: accessedAt) else {
            return nil
        }
        try Self.associateAvatarOwner(
            owner,
            recordKey: Self.cacheFields(disposableKey).recordKey,
            using: activeConnection()
        )
        return entry
    }

    public func associateAvatarCacheEntry(
        _ key: ForgeAvatarCacheKey,
        owner: ForgeAvatarCacheOwner
    ) throws {
        let disposableKey = ForgeDisposableCacheKey.avatar(key)
        try Self.associateAvatarOwner(
            owner,
            recordKey: Self.cacheFields(disposableKey).recordKey,
            using: activeConnection()
        )
    }

    @discardableResult
    public func removeAvatarCacheEntry(_ key: ForgeAvatarCacheKey) throws -> Bool {
        let recordKey = try Self.cacheFields(.avatar(key)).recordKey
        let connection = try activeConnection()
        return try connection.changeCount {
            try connection.execute(
                "DELETE FROM forge_cache_entries WHERE cache_kind = 1 AND record_key = ?",
                bindings: [.blob(recordKey)]
            )
        } > 0
    }

    @discardableResult
    public func removeAvatarAssociations(for accountID: ForgeAccountID) throws -> Int {
        let connection = try activeConnection()
        guard Self.isSupportedAvatarAccount(accountID) else { return 0 }
        return try connection.transaction {
            try Self.removeAvatarAssociations(for: accountID, using: connection)
        }
    }

    @discardableResult
    public func removeAllAvatarCacheEntries() throws -> Int {
        let connection = try activeConnection()
        let removed = try connection.changeCount {
            try connection.execute("DELETE FROM forge_cache_entries WHERE cache_kind = 1")
        }
        Self.logger.info("Removed \(removed) structured avatar cache records")
        return removed
    }

    private static func upsertCacheEntry(
        _ entry: ForgeSQLiteCacheEntry,
        using connection: ForgeSQLiteConnection
    ) throws {
        let fields = try Self.cacheFields(entry.record.key)
        let completeness = try Self.encodedKey(entry.record.completeness)
        try connection.execute(
            """
            INSERT INTO forge_cache_entries
                (cache_kind, partition_kind, account_key, repository_key, record_key,
                 payload, byte_count, fetched_at, accessed_at, completeness)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(record_key)
            DO UPDATE SET cache_kind = excluded.cache_kind,
                          partition_kind = excluded.partition_kind,
                          account_key = excluded.account_key,
                          repository_key = excluded.repository_key,
                          payload = excluded.payload,
                          byte_count = excluded.byte_count,
                          fetched_at = excluded.fetched_at,
                          accessed_at = excluded.accessed_at,
                          completeness = excluded.completeness
            """,
            bindings: [
                .integer(Int64(fields.cacheKind)), .integer(Int64(fields.partitionKind)),
                .blob(fields.accountKey), .blob(fields.repositoryKey), .blob(fields.recordKey),
                .blob(entry.payload), .integer(Int64(entry.record.byteCount)),
                .double(entry.record.fetchedAt.timeIntervalSince1970),
                .double(entry.record.lastAccessedAt.timeIntervalSince1970), .blob(completeness),
            ]
        )
    }

    public func cacheEntry(
        for key: ForgeDisposableCacheKey,
        accessedAt: Date
    ) throws -> ForgeSQLiteCacheEntry? {
        guard accessedAt.timeIntervalSince1970.isFinite else {
            throw ForgeSQLiteError.invalidTimestamp
        }
        let connection = try activeConnection()
        let fields = try Self.cacheFields(key)
        return try connection.transaction {
            let rows = try connection.query(
                """
                SELECT cache_kind, partition_kind, account_key, repository_key,
                       payload, byte_count, fetched_at, accessed_at, completeness
                FROM forge_cache_entries WHERE record_key = ?
                """,
                bindings: [.blob(fields.recordKey)]
            )
            guard let row = rows.first else { return nil }
            guard try row.integer(0) == Int64(fields.cacheKind),
                  try row.integer(1) == Int64(fields.partitionKind),
                  try row.blob(2) == fields.accountKey,
                  try row.blob(3) == fields.repositoryKey
            else {
                throw ForgeSQLiteError.sqlite(
                    operation: "validate cache partition",
                    code: SQLITE_CORRUPT,
                    message: "stored cache partition differs from its canonical key"
                )
            }
            let previousAccess = try row.date(7)
            let effectiveAccess = max(previousAccess, accessedAt)
            try connection.execute(
                "UPDATE forge_cache_entries SET accessed_at = ? WHERE record_key = ?",
                bindings: [.double(effectiveAccess.timeIntervalSince1970), .blob(fields.recordKey)]
            )
            let completeness = try JSONDecoder().decode(
                ForgeSnapshotCompleteness.self,
                from: row.blob(8)
            )
            let storedByteCount = try row.integer(5)
            guard storedByteCount >= 0 else {
                throw ForgeSQLiteError.sqlite(
                    operation: "read cache byte count",
                    code: SQLITE_CORRUPT,
                    message: "negative byte count"
                )
            }
            let record = try ForgeDisposableCacheRecord(
                key: key,
                byteCount: UInt64(storedByteCount),
                fetchedAt: row.date(6),
                lastAccessedAt: effectiveAccess,
                completeness: completeness
            )
            return try ForgeSQLiteCacheEntry(record: record, payload: row.blob(4))
        }
    }

    @discardableResult
    public func enforceCacheLimits(
        totalByteLimit: UInt64 = ForgePolicyConstants.disposableCacheByteLimit,
        avatarByteLimit: UInt64 = ForgePolicyConstants.avatarCacheByteLimit
    ) throws -> Int {
        let connection = try activeConnection()
        return try connection.transaction {
            var removed = 0
            removed += try connection.evictOldestCacheRows(
                where: "cache_kind = 1",
                byteLimit: avatarByteLimit
            )
            removed += try connection.evictOldestCacheRows(
                where: nil,
                byteLimit: totalByteLimit
            )
            Self.logger.info("Evicted \(removed) Forge cache records")
            return removed
        }
    }

    @discardableResult
    public func removeIdleCacheRepositories(notAccessedSince cutoff: Date) throws -> Int {
        guard cutoff.timeIntervalSince1970.isFinite else {
            throw ForgeSQLiteError.invalidTimestamp
        }
        let connection = try activeConnection()
        let before = try connection.changeCount {
            try connection.execute(
                """
                DELETE FROM forge_cache_entries
                WHERE cache_kind = 0 AND (partition_kind, account_key, repository_key) IN (
                    SELECT partition_kind, account_key, repository_key
                    FROM forge_cache_entries
                    WHERE cache_kind = 0
                    GROUP BY partition_kind, account_key, repository_key
                    HAVING MAX(accessed_at) <= ?
                )
                """,
                bindings: [.double(cutoff.timeIntervalSince1970)]
            )
        }
        Self.logger.info("Removed \(before) records from idle Forge cache repositories")
        return before
    }

    public func saveDurableRecord(_ record: ForgeSQLiteDurableRecord) throws {
        let connection = try activeConnection()
        let account = try Self.encodedKey(record.accountID)
        let repository = try Self.encodedKey(record.repository)
        try connection.execute(
            """
            INSERT INTO forge_durable_records
                (kind, account_key, repository_key, record_key, payload, last_activity_at, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(kind, account_key, repository_key, record_key)
            DO UPDATE SET payload = excluded.payload,
                          last_activity_at = excluded.last_activity_at,
                          expires_at = excluded.expires_at
            """,
            bindings: [
                .integer(Int64(record.kind.rawValue)), .blob(account), .blob(repository),
                .blob(record.key), .blob(record.payload),
                .double(record.lastActivityAt.timeIntervalSince1970),
                record.expiresAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            ]
        )
        Self.logger.debug("Stored durable Forge record of kind \(record.kind.rawValue)")
    }

    public func durableRecord(
        kind: ForgeSQLiteDurableKind,
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        key: Data
    ) throws -> ForgeSQLiteDurableRecord? {
        let probe = try ForgeSQLiteDurableRecord(
            kind: kind,
            accountID: accountID,
            repository: repository,
            key: key,
            payload: Data(),
            lastActivityAt: .distantPast
        )
        let connection = try activeConnection()
        let account = try Self.encodedKey(probe.accountID)
        let repositoryKey = try Self.encodedKey(probe.repository)
        let rows = try connection.query(
            """
            SELECT payload, last_activity_at, expires_at FROM forge_durable_records
            WHERE kind = ? AND account_key = ? AND repository_key = ? AND record_key = ?
            """,
            bindings: [
                .integer(Int64(kind.rawValue)), .blob(account), .blob(repositoryKey), .blob(key),
            ]
        )
        guard let row = rows.first else { return nil }
        return try ForgeSQLiteDurableRecord(
            kind: kind,
            accountID: accountID,
            repository: repository,
            key: key,
            payload: row.blob(0),
            lastActivityAt: row.date(1),
            expiresAt: row.optionalDate(2)
        )
    }

    /// Enumerates one durable kind inside an exact Account partition. Callers
    /// still validate decoded payload identity before treating rows as domain
    /// values; this method only establishes the SQLite partition boundary.
    public func durableRecords(
        kind: ForgeSQLiteDurableKind,
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity? = nil
    ) throws -> [ForgeSQLiteDurableRecord] {
        if let repository, repository.forge != accountID.forge {
            throw ForgeSQLiteError.mismatchedAccountForge
        }
        let connection = try activeConnection()
        let account = try Self.encodedKey(accountID)
        let rows: [ForgeSQLiteRow]
        if let repository {
            rows = try connection.query(
                """
                SELECT repository_key, record_key, payload, last_activity_at, expires_at
                FROM forge_durable_records
                WHERE kind = ? AND account_key = ? AND repository_key = ?
                ORDER BY repository_key, record_key
                """,
                bindings: [
                    .integer(Int64(kind.rawValue)), .blob(account),
                    .blob(Self.encodedKey(repository)),
                ]
            )
        } else {
            rows = try connection.query(
                """
                SELECT repository_key, record_key, payload, last_activity_at, expires_at
                FROM forge_durable_records
                WHERE kind = ? AND account_key = ?
                ORDER BY repository_key, record_key
                """,
                bindings: [.integer(Int64(kind.rawValue)), .blob(account)]
            )
        }
        let decoder = JSONDecoder()
        return try rows.map { row in
            try ForgeSQLiteDurableRecord(
                kind: kind,
                accountID: accountID,
                repository: decoder.decode(ForgeRepositoryIdentity.self, from: row.blob(0)),
                key: row.blob(1),
                payload: row.blob(2),
                lastActivityAt: row.date(3),
                expiresAt: row.optionalDate(4)
            )
        }
    }

    @discardableResult
    public func deleteDurableRecord(
        kind: ForgeSQLiteDurableKind,
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        key: Data
    ) throws -> Bool {
        _ = try ForgeSQLiteDurableRecord(
            kind: kind,
            accountID: accountID,
            repository: repository,
            key: key,
            payload: Data(),
            lastActivityAt: .distantPast
        )
        let connection = try activeConnection()
        let account = try Self.encodedKey(accountID)
        let repository = try Self.encodedKey(repository)
        return try connection.changeCount {
            try connection.execute(
                """
                DELETE FROM forge_durable_records
                WHERE kind = ? AND account_key = ? AND repository_key = ? AND record_key = ?
                """,
                bindings: [
                    .integer(Int64(kind.rawValue)), .blob(account), .blob(repository), .blob(key),
                ]
            )
        } > 0
    }

    @discardableResult
    public func removeExpiredDurableRecords(at date: Date) throws -> Int {
        guard date.timeIntervalSince1970.isFinite else {
            throw ForgeSQLiteError.invalidTimestamp
        }
        let connection = try activeConnection()
        let removed = try connection.changeCount {
            try connection.execute(
                """
                DELETE FROM forge_durable_records
                WHERE expires_at IS NOT NULL AND expires_at <= ?
                """,
                bindings: [.double(date.timeIntervalSince1970)]
            )
        }
        Self.logger.info("Removed \(removed) expired durable Forge records")
        return removed
    }

    @discardableResult
    public func removeExpiredDurableRecords(
        kind: ForgeSQLiteDurableKind,
        at date: Date
    ) throws -> Int {
        guard date.timeIntervalSince1970.isFinite else {
            throw ForgeSQLiteError.invalidTimestamp
        }
        let connection = try activeConnection()
        let removed = try connection.changeCount {
            try connection.execute(
                """
                DELETE FROM forge_durable_records
                WHERE kind = ? AND expires_at IS NOT NULL AND expires_at <= ?
                """,
                bindings: [
                    .integer(Int64(kind.rawValue)), .double(date.timeIntervalSince1970),
                ]
            )
        }
        Self.logger.info("Removed \(removed) expired durable Forge records of kind \(kind.rawValue)")
        return removed
    }

    @discardableResult
    public func deleteDurableRecords(
        kind: ForgeSQLiteDurableKind,
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity
    ) throws -> Int {
        guard accountID.forge == repository.forge else {
            throw ForgeSQLiteError.mismatchedAccountForge
        }
        let connection = try activeConnection()
        let account = try Self.encodedKey(accountID)
        let repositoryKey = try Self.encodedKey(repository)
        return try connection.changeCount {
            try connection.execute(
                """
                DELETE FROM forge_durable_records
                WHERE kind = ? AND account_key = ? AND repository_key = ?
                """,
                bindings: [
                    .integer(Int64(kind.rawValue)), .blob(account), .blob(repositoryKey),
                ]
            )
        }
    }

    public func removeAccount(_ accountID: ForgeAccountID) throws {
        let connection = try activeConnection()
        let account = try Self.encodedKey(accountID)
        try connection.transaction {
            try connection.execute(
                "DELETE FROM forge_cache_entries WHERE partition_kind = 1 AND account_key = ?",
                bindings: [.blob(account)]
            )
            try connection.execute(
                "DELETE FROM forge_durable_records WHERE account_key = ?",
                bindings: [.blob(account)]
            )
            if Self.isSupportedAvatarAccount(accountID) {
                _ = try Self.removeAvatarAssociations(for: accountID, using: connection)
            }
        }
        Self.logger.info("Removed one Forge Account persistence partition")
    }

    public func restore(_ salvage: ForgeSQLiteSalvage) throws {
        let connection = try activeConnection()
        try connection.transaction {
            for record in salvage.durableRecords {
                let account = try Self.encodedKey(record.accountID)
                let repository = try Self.encodedKey(record.repository)
                try connection.execute(
                    """
                    INSERT INTO forge_durable_records
                        (kind, account_key, repository_key, record_key, payload, last_activity_at, expires_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(kind, account_key, repository_key, record_key)
                    DO UPDATE SET payload = excluded.payload,
                                  last_activity_at = excluded.last_activity_at,
                                  expires_at = excluded.expires_at
                    """,
                    bindings: [
                        .integer(Int64(record.kind.rawValue)), .blob(account), .blob(repository),
                        .blob(record.key), .blob(record.payload),
                        .double(record.lastActivityAt.timeIntervalSince1970),
                        record.expiresAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    ]
                )
            }
        }
        Self.logger.info("Restored \(salvage.durableRecords.count) durable Forge records")
    }

    public static func salvageDurableRecords(from recoveryCopy: URL) throws -> ForgeSQLiteSalvage {
        let connection = try ForgeSQLiteConnection(url: recoveryCopy, readOnly: true)
        defer { connection.close() }
        guard try connection.hasTable("forge_durable_records") else {
            return ForgeSQLiteSalvage(durableRecords: [], skippedRecordCount: 0)
        }
        let rows = try connection.query(
            """
            SELECT kind, account_key, repository_key, record_key, payload, last_activity_at, expires_at
            FROM forge_durable_records
            """
        )
        let decoder = JSONDecoder()
        var records: [ForgeSQLiteDurableRecord] = []
        var skipped = 0
        for row in rows {
            do {
                guard let kind = try ForgeSQLiteDurableKind(rawValue: Int(row.integer(0))) else {
                    throw ForgeSQLiteError.sqlite(operation: "salvage kind", code: SQLITE_MISMATCH, message: "unknown kind")
                }
                try records.append(ForgeSQLiteDurableRecord(
                    kind: kind,
                    accountID: decoder.decode(ForgeAccountID.self, from: row.blob(1)),
                    repository: decoder.decode(ForgeRepositoryIdentity.self, from: row.blob(2)),
                    key: row.blob(3),
                    payload: row.blob(4),
                    lastActivityAt: row.date(5),
                    expiresAt: row.optionalDate(6)
                ))
            } catch {
                skipped += 1
            }
        }
        logger.info("Salvaged \(records.count) durable Forge records; skipped \(skipped)")
        return ForgeSQLiteSalvage(durableRecords: records, skippedRecordCount: skipped)
    }

    public static func recoveryCopies(
        in directory: URL,
        now: Date,
        maximumAge: TimeInterval = ForgePolicyConstants.recoveryCopyExpiration
    ) throws -> [ForgeSQLiteRecoveryCopy] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )
        let fileManager = FileManager.default
        let baseURLs = urls.filter(isRecoveryDatabaseURL)
        var retained: [ForgeSQLiteRecoveryCopy] = []
        for url in baseURLs {
            let createdAt = try url.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            if now.timeIntervalSince(createdAt) >= maximumAge {
                for sidecar in recoverySidecarURLs(for: url)
                    where fileManager.fileExists(atPath: sidecar.path)
                {
                    try fileManager.removeItem(at: sidecar)
                }
                try fileManager.removeItem(at: url)
            } else {
                let sidecars = recoverySidecarURLs(for: url)
                    .filter { fileManager.fileExists(atPath: $0.path) }
                retained.append(ForgeSQLiteRecoveryCopy(url: url, sidecarURLs: sidecars, createdAt: createdAt))
            }
        }

        let basePaths = Set(baseURLs.map(\.standardizedFileURL.path))
        for sidecar in urls where isRecoverySidecarURL(sidecar) {
            let baseURL = recoveryDatabaseURL(for: sidecar)
            guard !basePaths.contains(baseURL.standardizedFileURL.path) else { continue }
            let createdAt = try sidecar.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            if now.timeIntervalSince(createdAt) >= maximumAge {
                try fileManager.removeItem(at: sidecar)
            }
        }
        return retained.sorted { $0.createdAt < $1.createdAt }
    }

    public static func deleteRecoveryCopy(_ copy: ForgeSQLiteRecoveryCopy, in directory: URL) throws {
        let expectedParent = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = copy.url.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.deletingLastPathComponent() == expectedParent,
              candidate.lastPathComponent.hasPrefix(recoveryPrefix),
              candidate.pathExtension == String(recoverySuffix.dropFirst())
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        var resolvedSidecars: [URL] = []
        for sidecar in copy.sidecarURLs {
            let resolved = sidecar.standardizedFileURL.resolvingSymlinksInPath()
            let allowedPaths = ["-wal", "-shm", "-journal"].map { candidate.path + $0 }
            guard resolved.deletingLastPathComponent() == expectedParent,
                  allowedPaths.contains(resolved.path)
            else { throw CocoaError(.fileNoSuchFile) }
            resolvedSidecars.append(resolved)
        }
        let fileManager = FileManager.default
        let discoveredSidecars = recoverySidecarURLs(for: candidate)
            .filter { fileManager.fileExists(atPath: $0.path) }
        for sidecar in Set(resolvedSidecars + discoveredSidecars)
            where fileManager.fileExists(atPath: sidecar.path)
        {
            try fileManager.removeItem(at: sidecar)
        }
        if fileManager.fileExists(atPath: candidate.path) {
            try fileManager.removeItem(at: candidate)
        }
    }

    private static func isRecoveryDatabaseURL(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(recoveryPrefix)
            && url.pathExtension == String(recoverySuffix.dropFirst())
    }

    private static func isRecoverySidecarURL(_ url: URL) -> Bool {
        let baseURL = recoveryDatabaseURL(for: url)
        return baseURL != url && isRecoveryDatabaseURL(baseURL)
    }

    private static func recoveryDatabaseURL(for sidecar: URL) -> URL {
        for suffix in ["-wal", "-shm", "-journal"] where sidecar.path.hasSuffix(suffix) {
            return URL(fileURLWithPath: String(sidecar.path.dropLast(suffix.count)))
        }
        return sidecar
    }

    private static func recoverySidecarURLs(for database: URL) -> [URL] {
        ["-wal", "-shm", "-journal"].map { URL(fileURLWithPath: database.path + $0) }
    }

    private func activeConnection() throws -> ForgeSQLiteConnection {
        guard let connection else { throw ForgeSQLiteError.closed }
        return connection
    }

    private static func cacheFields(
        _ key: ForgeDisposableCacheKey
    ) throws -> (cacheKind: Int, partitionKind: Int, accountKey: Data, repositoryKey: Data, recordKey: Data) {
        switch key {
        case .avatar:
            return try (1, 0, Data(), Data(), encodedKey(key))
        case let .snapshot(snapshotKey):
            let accountKey: Data
            let partitionKind: Int
            switch snapshotKey.repositoryPartition.cachePartition {
            case .publicAccess:
                partitionKind = 0
                accountKey = Data()
            case let .account(accountID):
                partitionKind = 1
                accountKey = try encodedKey(accountID)
            }
            return try (
                0,
                partitionKind,
                accountKey,
                encodedKey(snapshotKey.repositoryPartition.repository),
                encodedKey(key)
            )
        }
    }

    private static func avatarOwnerKey(_ owner: ForgeAvatarCacheOwner) throws -> Data {
        switch owner {
        case .anonymous:
            return Data()
        case let .account(accountID):
            guard isSupportedAvatarAccount(accountID) else {
                throw ForgeSQLiteError.unsupportedAvatarOwner
            }
            return try encodedKey(accountID)
        }
    }

    private static func isSupportedAvatarAccount(_ accountID: ForgeAccountID) -> Bool {
        accountID.forge.kind == .github &&
            accountID.forge.origin.host == "github.com" &&
            accountID.forge.origin.effectivePort == 443
    }

    private static func associateAvatarOwner(
        _ owner: ForgeAvatarCacheOwner,
        recordKey: Data,
        using connection: ForgeSQLiteConnection
    ) throws {
        try connection.execute(
            "INSERT OR IGNORE INTO forge_avatar_cache_owners (record_key, account_key) VALUES (?, ?)",
            bindings: [.blob(recordKey), .blob(avatarOwnerKey(owner))]
        )
    }

    private static func removeAvatarAssociations(
        for accountID: ForgeAccountID,
        using connection: ForgeSQLiteConnection
    ) throws -> Int {
        let accountKey = try avatarOwnerKey(.account(accountID))
        let rows = try connection.query(
            "SELECT record_key FROM forge_avatar_cache_owners WHERE account_key = ?",
            bindings: [.blob(accountKey)]
        )
        let recordKeys = try rows.map { try $0.blob(0) }
        try connection.execute(
            "DELETE FROM forge_avatar_cache_owners WHERE account_key = ?",
            bindings: [.blob(accountKey)]
        )
        var removed = 0
        for recordKey in recordKeys {
            let remainingOwners = try connection.scalarInt(
                "SELECT COUNT(*) FROM forge_avatar_cache_owners WHERE record_key = ?",
                bindings: [.blob(recordKey)]
            )
            guard remainingOwners == 0 else { continue }
            removed += try connection.changeCount {
                try connection.execute(
                    "DELETE FROM forge_cache_entries WHERE cache_kind = 1 AND record_key = ?",
                    bindings: [.blob(recordKey)]
                )
            }
        }
        return removed
    }

    private static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func secureFile(_ url: URL, excludedFromBackup: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if excludedFromBackup {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        }
    }

    static func makeRecoveryCopy(of database: URL, in directory: URL, at date: Date) throws -> ForgeSQLiteRecoveryCopy {
        try prepareDirectory(directory)
        let copyURL = recoveryURL(in: directory, at: date)
        try FileManager.default.copyItem(at: database, to: copyURL)
        try secureFile(copyURL, excludedFromBackup: true)
        var copiedSidecars: [URL] = []
        for suffix in ["-wal", "-shm", "-journal"] {
            let source = URL(fileURLWithPath: database.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: copyURL.path + suffix)
            try FileManager.default.copyItem(at: source, to: destination)
            try secureFile(destination, excludedFromBackup: true)
            copiedSidecars.append(destination)
        }
        return ForgeSQLiteRecoveryCopy(url: copyURL, sidecarURLs: copiedSidecars, createdAt: date)
    }

    private static func makeRecoveryBackup(
        using connection: ForgeSQLiteConnection,
        in directory: URL,
        at date: Date
    ) throws -> ForgeSQLiteRecoveryCopy {
        let copyURL = recoveryURL(in: directory, at: date)
        do {
            try connection.backup(to: copyURL)
            try secureFile(copyURL, excludedFromBackup: true)
            return ForgeSQLiteRecoveryCopy(url: copyURL, createdAt: date)
        } catch {
            try? FileManager.default.removeItem(at: copyURL)
            throw error
        }
    }

    private static func recoveryURL(in directory: URL, at date: Date) -> URL {
        let name = "\(recoveryPrefix)\(Int(date.timeIntervalSince1970))-\(UUID().uuidString)\(recoverySuffix)"
        return directory.appendingPathComponent(name, isDirectory: false)
    }
}

enum ForgeSQLiteBinding {
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

struct ForgeSQLiteRow {
    let values: [ForgeSQLiteValue]

    func integer(_ index: Int) throws -> Int64 {
        guard case let .integer(value) = values[index] else { throw typeMismatch("INTEGER") }
        return value
    }

    func double(_ index: Int) throws -> Double {
        guard case let .double(value) = values[index] else { throw typeMismatch("REAL") }
        guard value.isFinite else { throw typeMismatch("finite REAL") }
        return value
    }

    func date(_ index: Int) throws -> Date {
        try Date(timeIntervalSince1970: double(index))
    }

    func optionalDate(_ index: Int) throws -> Date? {
        if case .null = values[index] {
            return nil
        }
        return try date(index)
    }

    func text(_ index: Int) throws -> String {
        guard case let .text(value) = values[index] else { throw typeMismatch("TEXT") }
        return value
    }

    func blob(_ index: Int) throws -> Data {
        guard case let .blob(value) = values[index] else { throw typeMismatch("BLOB") }
        return value
    }

    private func typeMismatch(_ expected: String) -> ForgeSQLiteError {
        .sqlite(
            operation: "read \(expected) column",
            code: SQLITE_MISMATCH,
            message: "unexpected SQLite storage class"
        )
    }
}

enum ForgeSQLiteValue {
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

final class ForgeSQLiteConnection {
    private var database: OpaquePointer?
    // swift6-safety-justification: SQLite defines SQLITE_TRANSIENT as the destructor
    // sentinel whose C function-pointer bit pattern is -1; SQLite copies each bound value.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let opened = try Self.open(url: url, flags: flags)
        database = opened
        sqlite3_extended_result_codes(opened, 1)
    }

    private static func open(url: URL, flags: Int32) throws -> OpaquePointer {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to allocate SQLite connection"
            _ = opened.map(sqlite3_close)
            throw ForgeSQLiteError.sqlite(operation: "open", code: result, message: message)
        }
        return opened
    }

    func close() {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
    }

    func backup(to url: URL, sourceName: String = "main") throws {
        _ = FileManager.default.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let destination = try Self.open(
            url: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        )
        defer { sqlite3_close(destination) }
        guard let backup = try sqlite3_backup_init(destination, "main", handle(), sourceName) else {
            throw failure(operation: "start recovery backup", code: sqlite3_errcode(destination))
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw ForgeSQLiteError.sqlite(
                operation: "create recovery backup",
                code: stepResult == SQLITE_DONE ? finishResult : stepResult,
                message: "could not complete recovery backup"
            )
        }
    }

    func configure() throws {
        try sqlite3_busy_timeout(handle(), 5000)
        try execute("PRAGMA trusted_schema = OFF")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = DELETE")
        try execute("PRAGMA synchronous = FULL")
    }

    func verifyIntegrity() throws {
        try verifyIntegrity(query("PRAGMA quick_check(1)"))
    }

    func verifyIntegrity(_ rows: [ForgeSQLiteRow]) throws {
        guard rows.count == 1, try rows[0].text(0) == "ok" else {
            throw ForgeSQLiteError.sqlite(operation: "integrity check", code: SQLITE_CORRUPT, message: "database is corrupt")
        }
    }

    func migrate(to supportedVersion: Int) throws {
        let version = try Int(scalarInt("PRAGMA user_version"))
        guard version <= supportedVersion else {
            throw ForgeSQLiteError.sqlite(
                operation: "migration",
                code: SQLITE_ERROR,
                message: "schema version \(version) is newer than supported version \(supportedVersion)"
            )
        }
        guard version < supportedVersion else { return }
        try transaction {
            if version == 0 {
                try execute(
                    """
                    CREATE TABLE forge_cache_entries (
                        cache_kind INTEGER NOT NULL CHECK(cache_kind IN (0, 1)),
                        partition_kind INTEGER NOT NULL CHECK(partition_kind IN (0, 1)),
                        account_key BLOB NOT NULL,
                        repository_key BLOB NOT NULL,
                        record_key BLOB NOT NULL CHECK(length(record_key) > 0),
                        payload BLOB NOT NULL,
                        byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
                        fetched_at REAL NOT NULL,
                        accessed_at REAL NOT NULL,
                        completeness BLOB NOT NULL,
                        CHECK(accessed_at >= fetched_at),
                        CHECK(byte_count = length(payload)),
                        CHECK(
                            (partition_kind = 0 AND length(account_key) = 0)
                            OR (partition_kind = 1 AND length(account_key) > 0)
                        ),
                        CHECK(
                            (cache_kind = 1 AND partition_kind = 0
                                AND length(account_key) = 0 AND length(repository_key) = 0)
                            OR (cache_kind = 0 AND length(repository_key) > 0)
                        ),
                        PRIMARY KEY(record_key)
                    )
                    """
                )
                try execute(
                    "CREATE INDEX forge_cache_lru ON forge_cache_entries(accessed_at)"
                )
                try execute(
                    """
                    CREATE TABLE forge_durable_records (
                        kind INTEGER NOT NULL CHECK(kind IN (1, 2, 3, 4)),
                        account_key BLOB NOT NULL CHECK(length(account_key) > 0),
                        repository_key BLOB NOT NULL CHECK(length(repository_key) > 0),
                        record_key BLOB NOT NULL CHECK(length(record_key) > 0),
                        payload BLOB NOT NULL,
                        last_activity_at REAL NOT NULL,
                        expires_at REAL,
                        CHECK(expires_at IS NULL OR expires_at >= last_activity_at),
                        PRIMARY KEY(kind, account_key, repository_key, record_key)
                    )
                    """
                )
                try execute(
                    "CREATE INDEX forge_durable_expiration ON forge_durable_records(expires_at) WHERE expires_at IS NOT NULL"
                )
                try execute("PRAGMA user_version = 1")
            }
            if version <= 1, supportedVersion >= 2 {
                try execute(
                    """
                    CREATE TABLE forge_avatar_cache_owners (
                        record_key BLOB NOT NULL CHECK(length(record_key) > 0),
                        account_key BLOB NOT NULL,
                        PRIMARY KEY(record_key, account_key),
                        FOREIGN KEY(record_key) REFERENCES forge_cache_entries(record_key) ON DELETE CASCADE
                    )
                    """
                )
                try execute(
                    "CREATE INDEX forge_avatar_owner_accounts ON forge_avatar_cache_owners(account_key)"
                )
                try execute(
                    """
                    INSERT INTO forge_avatar_cache_owners (record_key, account_key)
                    SELECT record_key, X'' FROM forge_cache_entries WHERE cache_kind = 1
                    """
                )
                try execute("PRAGMA user_version = 2")
            }
            if version <= 2, supportedVersion >= 3 {
                try execute("ALTER TABLE forge_durable_records RENAME TO forge_durable_records_v2")
                try execute("DROP INDEX forge_durable_expiration")
                try execute(
                    """
                    CREATE TABLE forge_durable_records (
                        kind INTEGER NOT NULL CHECK(kind IN (1, 2, 3, 4)),
                        account_key BLOB NOT NULL CHECK(length(account_key) > 0),
                        repository_key BLOB NOT NULL CHECK(length(repository_key) > 0),
                        record_key BLOB NOT NULL CHECK(length(record_key) > 0),
                        payload BLOB NOT NULL,
                        last_activity_at REAL NOT NULL,
                        expires_at REAL,
                        CHECK(expires_at IS NULL OR expires_at >= last_activity_at),
                        PRIMARY KEY(kind, account_key, repository_key, record_key)
                    )
                    """
                )
                try execute(
                    """
                    INSERT INTO forge_durable_records
                        (kind, account_key, repository_key, record_key, payload, last_activity_at, expires_at)
                    SELECT kind, account_key, repository_key, record_key, payload, last_activity_at, expires_at
                    FROM forge_durable_records_v2
                    """
                )
                try execute("DROP TABLE forge_durable_records_v2")
                try execute(
                    "CREATE INDEX forge_durable_expiration ON forge_durable_records(expires_at) WHERE expires_at IS NOT NULL"
                )
                try execute("PRAGMA user_version = 3")
            }
        }
    }

    func verifySchema(version: Int) throws {
        guard try scalarInt("PRAGMA user_version") == version else {
            throw ForgeSQLiteError.sqlite(
                operation: "verify schema",
                code: SQLITE_SCHEMA,
                message: "unexpected schema version"
            )
        }
        _ = try query(
            """
            SELECT cache_kind, partition_kind, account_key, repository_key, record_key,
                   payload, byte_count, fetched_at, accessed_at, completeness
            FROM forge_cache_entries LIMIT 0
            """
        )
        _ = try query(
            """
            SELECT kind, account_key, repository_key, record_key, payload, last_activity_at, expires_at
            FROM forge_durable_records LIMIT 0
            """
        )
        if version >= 2 {
            _ = try query(
                "SELECT record_key, account_key FROM forge_avatar_cache_owners LIMIT 0"
            )
        }
    }

    func hasTable(_ name: String) throws -> Bool {
        try scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            bindings: [.text(name)]
        ) == 1
    }

    func execute(_ sql: String, bindings: [ForgeSQLiteBinding] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw failure(operation: "execute", code: result)
        }
    }

    func query(_ sql: String, bindings: [ForgeSQLiteBinding] = []) throws -> [ForgeSQLiteRow] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [ForgeSQLiteRow] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let count = sqlite3_column_count(statement)
            var values: [ForgeSQLiteValue] = []
            for index in 0 ..< count {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    values.append(.integer(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT:
                    values.append(.double(sqlite3_column_double(statement, index)))
                case SQLITE_TEXT:
                    values.append(.text(String(cString: sqlite3_column_text(statement, index))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if count == 0 {
                        values.append(.blob(Data()))
                    } else {
                        values.append(.blob(Data(bytes: sqlite3_column_blob(statement, index), count: count)))
                    }
                default:
                    values.append(.null)
                }
            }
            rows.append(ForgeSQLiteRow(values: values))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw failure(operation: "query", code: result) }
        return rows
    }

    func scalarInt(_ sql: String, bindings: [ForgeSQLiteBinding] = []) throws -> Int64 {
        guard let row = try query(sql, bindings: bindings).first else { return 0 }
        return try row.integer(0)
    }

    func evictOldestCacheRows(where predicate: String?, byteLimit: UInt64) throws -> Int {
        let condition = predicate.map { " WHERE \($0)" } ?? ""
        return try changeCount {
            try execute(
                """
                WITH ranked AS (
                    SELECT record_key,
                           SUM(byte_count) OVER (
                               ORDER BY accessed_at DESC, record_key DESC
                           ) AS cumulative_bytes
                    FROM forge_cache_entries\(condition)
                )
                DELETE FROM forge_cache_entries
                WHERE record_key IN (
                    SELECT record_key FROM ranked WHERE cumulative_bytes > ?
                )
                """,
                bindings: [.integer(Int64(clamping: byteLimit))]
            )
        }
    }

    func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func changeCount(_ body: () throws -> Void) throws -> Int {
        try body()
        return try Int(sqlite3_changes(handle()))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = try sqlite3_prepare_v2(handle(), sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw failure(operation: "prepare", code: result)
        }
        return statement
    }

    private func bind(_ bindings: [ForgeSQLiteBinding], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch binding {
            case let .integer(value):
                sqlite3_bind_int64(statement, index, value)
            case let .double(value):
                sqlite3_bind_double(statement, index, value)
            case let .text(value):
                value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
            case let .blob(value):
                if value.isEmpty {
                    sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    value.withUnsafeBytes {
                        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
                    }
                }
            case .null:
                sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw failure(operation: "bind", code: result) }
        }
    }

    private func handle() throws -> OpaquePointer {
        guard let database else { throw ForgeSQLiteError.closed }
        return database
    }

    private func failure(operation: String, code: Int32) -> ForgeSQLiteError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "connection closed"
        return .sqlite(operation: operation, code: code, message: message)
    }
}
