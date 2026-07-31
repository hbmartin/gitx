import ForgeKit
import Foundation

nonisolated struct ForgeInFlightMutation: Codable, Hashable, Sendable {
    let registrationID: UUID
    let accountID: ForgeAccountID
    let repository: ForgeRepositoryIdentity
    let operation: ForgeOperation
    let startedAt: Date

    init(
        registrationID: UUID = UUID(),
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation,
        startedAt: Date = Date()
    ) throws {
        guard accountID.forge == repository.forge else {
            throw ForgeMutationQuitCoordinatorError.accountRepositoryMismatch
        }
        guard operation.isWrite else {
            throw ForgeMutationQuitCoordinatorError.readOnlyOperation
        }
        guard startedAt.timeIntervalSince1970.isFinite else {
            throw ForgeMutationQuitCoordinatorError.invalidTimestamp
        }
        self.registrationID = registrationID
        self.accountID = accountID
        self.repository = repository
        self.operation = operation
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case registrationID
        case accountID
        case repository
        case operation
        case startedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            registrationID: container.decode(UUID.self, forKey: .registrationID),
            accountID: container.decode(ForgeAccountID.self, forKey: .accountID),
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            operation: container.decode(ForgeOperation.self, forKey: .operation),
            startedAt: container.decode(Date.self, forKey: .startedAt)
        )
    }
}

nonisolated struct ForgeMutationRegistration: Hashable, Sendable {
    let mutation: ForgeInFlightMutation
}

/// Redacted by construction: this stores only the exact reconciliation identity.
/// It intentionally cannot retain request arguments, content, credentials, or a retry closure.
nonisolated struct ForgeUnknownMutationOutcomeRecord: Codable, Hashable, Sendable {
    let registrationID: UUID
    let accountID: ForgeAccountID
    let repository: ForgeRepositoryIdentity
    let operation: ForgeOperation
    let startedAt: Date
    let recordedAt: Date

    init(mutation: ForgeInFlightMutation, recordedAt: Date) throws {
        guard recordedAt.timeIntervalSince1970.isFinite else {
            throw ForgeMutationQuitCoordinatorError.invalidTimestamp
        }
        registrationID = mutation.registrationID
        accountID = mutation.accountID
        repository = mutation.repository
        operation = mutation.operation
        startedAt = mutation.startedAt
        self.recordedAt = recordedAt
    }

    fileprivate var persistenceKey: Data {
        Data(registrationID.uuidString.lowercased().utf8)
    }

    private enum CodingKeys: String, CodingKey {
        case registrationID
        case accountID
        case repository
        case operation
        case startedAt
        case recordedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mutation = try ForgeInFlightMutation(
            registrationID: container.decode(UUID.self, forKey: .registrationID),
            accountID: container.decode(ForgeAccountID.self, forKey: .accountID),
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            operation: container.decode(ForgeOperation.self, forKey: .operation),
            startedAt: container.decode(Date.self, forKey: .startedAt)
        )
        try self.init(
            mutation: mutation,
            recordedAt: container.decode(Date.self, forKey: .recordedAt)
        )
    }
}

nonisolated protocol ForgeUnknownMutationOutcomePersisting: Sendable {
    func record(_ records: [ForgeUnknownMutationOutcomeRecord]) async throws
    func records(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) async throws -> [ForgeUnknownMutationOutcomeRecord]
    func consume(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) async throws -> [ForgeUnknownMutationOutcomeRecord]
}

/// Durable unknown-outcome storage partitioned by exact Account and repository.
/// Consumers call `consume` from the next applicable refresh after reconciling
/// server state. This type deliberately exposes no operation-retry API.
final nonisolated class ForgeSQLiteUnknownMutationOutcomeStore: ForgeUnknownMutationOutcomePersisting, Sendable {
    typealias DatabaseProvider = @Sendable () async throws -> ForgeSQLiteStore

    private let databaseProvider: DatabaseProvider

    init(database: ForgeSQLiteStore) {
        databaseProvider = { database }
    }

    init(databaseProvider: @escaping DatabaseProvider) {
        self.databaseProvider = databaseProvider
    }

    func record(_ records: [ForgeUnknownMutationOutcomeRecord]) async throws {
        guard !records.isEmpty else { return }
        let database = try await databaseProvider()
        let encoder = JSONEncoder()
        for record in records {
            let payload = try encoder.encode(record)
            let durableRecord = try ForgeSQLiteDurableRecord(
                kind: .unknownMutationOutcome,
                accountID: record.accountID,
                repository: record.repository,
                key: record.persistenceKey,
                payload: payload,
                lastActivityAt: record.recordedAt
            )
            try await database.saveDurableRecord(durableRecord)
        }
    }

    func records(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) async throws -> [ForgeUnknownMutationOutcomeRecord] {
        try Self.validate(accountID: accountID, repository: repository, operation: operation)
        let database = try await databaseProvider()
        let durableRecords = try await database.durableRecords(
            kind: .unknownMutationOutcome,
            accountID: accountID,
            repository: repository
        )
        return try durableRecords
            .map(Self.decode)
            .filter { $0.operation == operation }
            .sorted(by: Self.sortsBefore)
    }

    func consume(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) async throws -> [ForgeUnknownMutationOutcomeRecord] {
        let matchingRecords = try await records(
            accountID: accountID,
            repository: repository,
            operation: operation
        )
        guard !matchingRecords.isEmpty else { return [] }
        let database = try await databaseProvider()
        var consumed: [ForgeUnknownMutationOutcomeRecord] = []
        for record in matchingRecords {
            let removed = try await database.deleteDurableRecord(
                kind: .unknownMutationOutcome,
                accountID: accountID,
                repository: repository,
                key: record.persistenceKey
            )
            if removed {
                consumed.append(record)
            }
        }
        return consumed
    }

    private static func validate(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) throws {
        guard accountID.forge == repository.forge else {
            throw ForgeMutationQuitCoordinatorError.accountRepositoryMismatch
        }
        guard operation.isWrite else {
            throw ForgeMutationQuitCoordinatorError.readOnlyOperation
        }
    }

    private static func decode(_ durableRecord: ForgeSQLiteDurableRecord) throws
        -> ForgeUnknownMutationOutcomeRecord
    {
        let record = try JSONDecoder().decode(
            ForgeUnknownMutationOutcomeRecord.self,
            from: durableRecord.payload
        )
        guard durableRecord.kind == .unknownMutationOutcome,
              durableRecord.accountID == record.accountID,
              durableRecord.repository == record.repository,
              durableRecord.key == record.persistenceKey,
              Self.timestampsMatch(durableRecord.lastActivityAt, record.recordedAt)
        else {
            throw ForgeMutationQuitCoordinatorError.invalidPersistedRecord
        }
        return record
    }

    /// SQLite stores Unix-epoch doubles while Codable's Date representation
    /// converts through Apple's reference epoch. A live subsecond timestamp can
    /// differ by a few ulps after those independent round trips.
    private static func timestampsMatch(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) <= 0.000_001
    }

    private static func sortsBefore(
        _ lhs: ForgeUnknownMutationOutcomeRecord,
        _ rhs: ForgeUnknownMutationOutcomeRecord
    ) -> Bool {
        if lhs.recordedAt != rhs.recordedAt {
            return lhs.recordedAt < rhs.recordedAt
        }
        return lhs.registrationID.uuidString < rhs.registrationID.uuidString
    }
}
