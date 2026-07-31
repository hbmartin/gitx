import AppKit
import Dispatch
import ForgeKit
import XCTest

@MainActor
// swift6-safety-justification: XCTest owns the case and all assertion state is main-actor confined.
final class ForgeMutationQuitCoordinatorTests: XCTestCase, @unchecked Sendable {
    func testNoActiveMutationsTerminateImmediatelyWithoutPrompt() {
        let choices = ChoiceSpy(choice: .wait)
        let replies = ReplySpy()
        let coordinator = makeCoordinator(choices: choices, replies: replies)

        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateNow)
        XCTAssertEqual(choices.requestCount, 0)
        XCTAssertTrue(replies.values.isEmpty)
    }

    func testWaitDefersTerminationUntilEveryRegisteredMutationFinishes() async throws {
        let choices = ChoiceSpy(choice: .wait)
        let replies = ReplySpy()
        let replied = expectation(description: "termination reply after all mutations finish")
        replies.expectation = replied
        let coordinator = makeCoordinator(choices: choices, replies: replies)
        let fixture = try Fixture()
        let create = try coordinator.register(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .createPullRequest,
            startedAt: fixture.date(1)
        )
        let edit = try coordinator.register(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .editPullRequest,
            startedAt: fixture.date(2)
        )

        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        XCTAssertEqual(choices.requestCount, 1)
        XCTAssertThrowsError(try coordinator.register(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .syncFork
        )) {
            XCTAssertEqual($0 as? ForgeMutationQuitCoordinatorError, .terminationPending)
        }

        XCTAssertTrue(coordinator.finish(create))
        XCTAssertTrue(replies.values.isEmpty)
        XCTAssertTrue(coordinator.finish(edit))
        await fulfillment(of: [replied], timeout: 1)

        XCTAssertEqual(replies.values, [true])
        XCTAssertFalse(coordinator.finish(edit))
        XCTAssertTrue(coordinator.activeMutations().isEmpty)
    }

    func testQuitAnywayDurablyRecordsOnlyReconciliationIdentityBeforeReplying() async throws {
        let persistence = PersistenceDouble()
        let choices = ChoiceSpy(choice: .quitAnyway)
        let replies = ReplySpy()
        let replied = expectation(description: "termination reply after durable record")
        replies.expectation = replied
        let coordinator = makeCoordinator(
            persistence: persistence,
            choices: choices,
            replies: replies
        )
        let fixture = try Fixture()
        _ = try coordinator.register(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .createPullRequest,
            startedAt: fixture.date(3)
        )
        _ = try coordinator.register(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .editPullRequest,
            startedAt: fixture.date(4)
        )

        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        XCTAssertTrue(replies.values.isEmpty)
        await fulfillment(of: [replied], timeout: 1)

        let records = await persistence.recordedRecords()
        XCTAssertEqual(records.map(\.accountID), [fixture.accountID, fixture.accountID])
        XCTAssertEqual(records.map(\.repository), [fixture.repository, fixture.repository])
        XCTAssertEqual(Set(records.map(\.operation)), [.createPullRequest, .editPullRequest])
        XCTAssertEqual(replies.values, [true])
        XCTAssertEqual(choices.requestCount, 1)

        let encoded = try JSONEncoder().encode(XCTUnwrap(records.first))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["accountID", "operation", "recordedAt", "registrationID", "repository", "startedAt"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeUnknownMutationOutcomeRecord.self, from: encoded).scope,
            .repositoryWide
        )
    }

    func testPersistenceFailureCancelsQuitAndAllowsCompletedMutationToClear() async throws {
        let persistence = PersistenceDouble(error: TestFailure.recording)
        let choices = ChoiceSpy(choice: .quitAnyway)
        let replies = ReplySpy()
        let replied = expectation(description: "termination cancelled after recording failure")
        replies.expectation = replied
        let coordinator = makeCoordinator(
            persistence: persistence,
            choices: choices,
            replies: replies
        )
        let fixture = try Fixture()
        let registration = try coordinator.register(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .syncFork
        )

        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(replies.values, [false])

        XCTAssertTrue(coordinator.finish(registration))
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateNow)
        XCTAssertEqual(choices.requestCount, 1)
    }

    func testRegistrationRejectsReadOnlyMismatchedAndInvalidTimestampBoundaries() throws {
        let coordinator = makeCoordinator()
        let fixture = try Fixture()

        XCTAssertThrowsError(try coordinator.register(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .readPullRequests
        )) {
            XCTAssertEqual($0 as? ForgeMutationQuitCoordinatorError, .readOnlyOperation)
        }
        XCTAssertThrowsError(try coordinator.register(
            accountID: fixture.accountID,
            repository: fixture.gitLabRepository,
            operation: .createPullRequest
        )) {
            XCTAssertEqual($0 as? ForgeMutationQuitCoordinatorError, .accountRepositoryMismatch)
        }
        XCTAssertThrowsError(try coordinator.register(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .createPullRequest,
            startedAt: Date(timeIntervalSince1970: .infinity)
        )) {
            XCTAssertEqual($0 as? ForgeMutationQuitCoordinatorError, .invalidTimestamp)
        }
        XCTAssertTrue(coordinator.activeMutations().isEmpty)
    }

    func testLifecycleProtocolDefaultRegistersRepositoryWideAndErrorsRemainActionable() throws {
        let coordinator = makeCoordinator()
        let lifecycle: any ForgeMutationLifecycleCoordinating = coordinator
        let fixture = try Fixture()
        let registration = try lifecycle.register(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .syncFork,
            startedAt: fixture.date(5)
        )

        XCTAssertEqual(registration.mutation.scope, .repositoryWide)
        XCTAssertTrue(lifecycle.finish(registration))
        XCTAssertTrue([
            ForgeMutationQuitCoordinatorError.accountRepositoryMismatch,
            .readOnlyOperation,
            .invalidTimestamp,
            .terminationPending,
            .persistenceUnavailable,
            .invalidPersistedRecord,
        ].allSatisfy { !($0.errorDescription ?? "").isEmpty })
    }

    func testSQLiteRecordsCanBeQueriedAndConsumedByExactApplicableRefresh() async throws {
        let fixture = try Fixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeMutationQuitCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: directory.appendingPathComponent("forge.sqlite3"),
            recoveryDirectoryURL: directory.appendingPathComponent("Recovery", isDirectory: true)
        ))
        let store = ForgeSQLiteUnknownMutationOutcomeStore(database: database)
        let create = try fixture.record(operation: .createPullRequest, offset: 10)
        let edit = try fixture.record(operation: .editPullRequest, offset: 20)
        try await store.record([edit, create])

        let applicable = try await store.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .createPullRequest
        )
        XCTAssertEqual(applicable, [create])

        let consumed = try await store.consume(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .createPullRequest
        )
        XCTAssertEqual(consumed, [create])
        let consumedAgain = try await store.consume(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .createPullRequest
        )
        XCTAssertTrue(consumedAgain.isEmpty)
        let untouched = try await store.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .editPullRequest
        )
        XCTAssertEqual(untouched, [edit])
        await database.close()
    }

    func testPullRequestRefreshConsumesOnlyItsExactScopedOutcome() async throws {
        let fixture = try Fixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeMutationPullRequestScopeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: directory.appendingPathComponent("forge.sqlite3"),
            recoveryDirectoryURL: directory.appendingPathComponent("Recovery", isDirectory: true)
        ))
        let store = ForgeSQLiteUnknownMutationOutcomeStore(database: database)
        let pullRequest42 = try ForgeItemNumber(42)
        let pullRequest43 = try ForgeItemNumber(43)
        let repositoryWide = try fixture.record(operation: .editPullRequest, offset: 10)
        let exact42 = try fixture.record(
            operation: .editPullRequest,
            scope: .pullRequest(pullRequest42),
            offset: 20
        )
        let exact43 = try fixture.record(
            operation: .editPullRequest,
            scope: .pullRequest(pullRequest43),
            offset: 30
        )
        try await store.record([exact43, repositoryWide, exact42])

        let applicable = try await store.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .editPullRequest,
            scope: .pullRequest(pullRequest42)
        )
        XCTAssertEqual(applicable, [exact42])

        let consumed = try await store.consume(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .editPullRequest,
            scope: .pullRequest(pullRequest42)
        )
        XCTAssertEqual(consumed, [exact42])

        let untouchedPullRequest = try await store.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .editPullRequest,
            scope: .pullRequest(pullRequest43)
        )
        XCTAssertEqual(untouchedPullRequest, [exact43])

        let repositoryRefresh: any ForgeUnknownMutationOutcomePersisting = store
        let remaining = try await repositoryRefresh.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .editPullRequest,
            scope: .repositoryWide
        )
        XCTAssertEqual(remaining, [repositoryWide, exact43])
        let consumedByRepositoryRefresh = try await repositoryRefresh.consume(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .editPullRequest,
            scope: .repositoryWide
        )
        XCTAssertEqual(consumedByRepositoryRefresh, remaining)
        let recordsAfterRepositoryRefresh = try await repositoryRefresh.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .editPullRequest,
            scope: .repositoryWide
        )
        XCTAssertTrue(recordsAfterRepositoryRefresh.isEmpty)
        await database.close()
    }

    func testExactPullRequestScopeIsRedactedAndSurvivesQuitRecording() async throws {
        let persistence = PersistenceDouble()
        let replies = ReplySpy()
        let replied = expectation(description: "termination reply after scoped durable record")
        replies.expectation = replied
        let coordinator = makeCoordinator(
            persistence: persistence,
            choices: ChoiceSpy(choice: .quitAnyway),
            replies: replies
        )
        let fixture = try Fixture()
        let number = try ForgeItemNumber(42)
        _ = try coordinator.register(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .publishInlineReviewComment,
            scope: .pullRequest(number),
            startedAt: fixture.date(40)
        )

        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [replied], timeout: 1)

        let recorded = await persistence.recordedRecords()
        let record = try XCTUnwrap(recorded.first)
        XCTAssertEqual(record.scope, .pullRequest(number))
        let encoded = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["accountID", "operation", "recordedAt", "registrationID", "repository", "scope", "startedAt"]
        )
        XCTAssertNil(object["body"])
        XCTAssertNil(object["retry"])
    }

    func testSQLiteRecordPreservesExactIdentityForFractionalTimestamp() async throws {
        let fixture = try Fixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeMutationQuitLiveDateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: directory.appendingPathComponent("forge.sqlite3"),
            recoveryDirectoryURL: directory.appendingPathComponent("Recovery", isDirectory: true)
        ))
        let store = ForgeSQLiteUnknownMutationOutcomeStore(database: database)
        let recordedAt = Date(timeIntervalSince1970: 1_900_000_000.123_456_7)
        let mutation = try ForgeInFlightMutation(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .syncFork,
            startedAt: recordedAt.addingTimeInterval(-1)
        )
        let record = try ForgeUnknownMutationOutcomeRecord(mutation: mutation, recordedAt: recordedAt)

        try await store.record([record])
        let restored = try await store.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operation: .syncFork
        )

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.registrationID, record.registrationID)
        await database.close()
    }

    func testSQLiteQueryFailsClosedForInconsistentPersistedIdentity() async throws {
        let fixture = try Fixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeMutationQuitCorruptionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: directory.appendingPathComponent("forge.sqlite3"),
            recoveryDirectoryURL: directory.appendingPathComponent("Recovery", isDirectory: true)
        ))
        let record = try fixture.record(operation: .createPullRequest, offset: 30)
        let invalid = try ForgeSQLiteDurableRecord(
            kind: .unknownMutationOutcome,
            accountID: fixture.accountID,
            repository: fixture.repository,
            key: Data("not-the-registration-id".utf8),
            payload: JSONEncoder().encode(record),
            lastActivityAt: record.recordedAt
        )
        try await database.saveDurableRecord(invalid)
        let store = ForgeSQLiteUnknownMutationOutcomeStore(database: database)

        do {
            _ = try await store.records(
                accountID: fixture.accountID,
                repository: fixture.repository,
                operation: .createPullRequest
            )
            XCTFail("Expected inconsistent identity metadata to fail closed")
        } catch {
            XCTAssertEqual(error as? ForgeMutationQuitCoordinatorError, .invalidPersistedRecord)
        }
        await database.close()
    }

    private func makeCoordinator(
        persistence: PersistenceDouble = PersistenceDouble(),
        choices: ChoiceSpy = ChoiceSpy(choice: .wait),
        replies: ReplySpy = ReplySpy()
    ) -> ForgeMutationQuitCoordinator {
        ForgeMutationQuitCoordinator(
            persistence: persistence,
            choiceProvider: { mutations in choices.choose(mutations) },
            terminationReply: { value in replies.record(value) }
        )
    }
}

@MainActor
private final class ChoiceSpy {
    let choice: ForgeMutationQuitChoice
    private(set) var requestCount = 0
    private(set) var requestedMutations: [[ForgeInFlightMutation]] = []

    init(choice: ForgeMutationQuitChoice) {
        self.choice = choice
    }

    func choose(_ mutations: [ForgeInFlightMutation]) -> ForgeMutationQuitChoice {
        requestCount += 1
        requestedMutations.append(mutations)
        return choice
    }
}

@MainActor
private final class ReplySpy {
    var expectation: XCTestExpectation?
    private(set) var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
        expectation?.fulfill()
    }
}

// swift6-safety-justification: the private serial queue protects the recorded outcomes.
private final class PersistenceDouble: ForgeUnknownMutationOutcomePersisting, @unchecked Sendable {
    private let error: Error?
    private let queue = DispatchQueue(label: "com.gitx.tests.forge-mutation-persistence")
    private var recorded: [ForgeUnknownMutationOutcomeRecord] = []

    init(error: Error? = nil) {
        self.error = error
    }

    func record(_ records: [ForgeUnknownMutationOutcomeRecord]) async throws {
        try queue.sync {
            if let error {
                throw error
            }
            recorded.append(contentsOf: records)
        }
    }

    func records(
        accountID _: ForgeAccountID,
        repository _: ForgeRepositoryIdentity,
        operation _: ForgeOperation,
        scope _: ForgeUnknownMutationOutcomeScope
    ) async -> [ForgeUnknownMutationOutcomeRecord] {
        queue.sync { recorded }
    }

    func consume(
        accountID _: ForgeAccountID,
        repository _: ForgeRepositoryIdentity,
        operation _: ForgeOperation,
        scope _: ForgeUnknownMutationOutcomeScope
    ) async -> [ForgeUnknownMutationOutcomeRecord] {
        queue.sync {
            let result = recorded
            recorded.removeAll()
            return result
        }
    }

    func recordedRecords() async -> [ForgeUnknownMutationOutcomeRecord] {
        queue.sync { recorded }
    }
}

private enum TestFailure: Error {
    case recording
}

private struct Fixture {
    let forge: ForgeIdentity
    let accountID: ForgeAccountID
    let repository: ForgeRepositoryIdentity
    let gitLabRepository: ForgeRepositoryIdentity

    init() throws {
        forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        accountID = try ForgeAccountID(forge: forge, value: "42")
        repository = try ForgeRepositoryIdentity(forge: forge, owner: "acme", name: "widgets")
        let gitLab = try ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com"))
        gitLabRepository = try ForgeRepositoryIdentity(forge: gitLab, owner: "acme", name: "widgets")
    }

    func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 2_000_000 + offset)
    }

    func record(
        operation: ForgeOperation,
        scope: ForgeUnknownMutationOutcomeScope = .repositoryWide,
        offset: TimeInterval
    ) throws
        -> ForgeUnknownMutationOutcomeRecord
    {
        let mutation = try ForgeInFlightMutation(
            registrationID: UUID(),
            accountID: accountID,
            repository: repository,
            operation: operation,
            scope: scope,
            startedAt: date(offset)
        )
        return try ForgeUnknownMutationOutcomeRecord(
            mutation: mutation,
            recordedAt: date(offset + 1)
        )
    }
}
