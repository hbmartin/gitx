import ForgeKit
@testable import GitX
import XCTest

#if DEBUG
    @MainActor
    final class ForgeHarnessDraftStoreCharacterizationTests: XCTestCase {
        func testHarnessPreservesCreationAndConditionallyDeletesOnlyItsStoredSnapshot() async throws {
            let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
            let repository = try ForgeRepositoryIdentity(forge: forge, owner: "fixture", name: "drafts")
            let identity = try ForgeDraftIdentity(accountID: ForgeAccountID(forge: forge, value: "fixture"),
                                                  destination: .pullRequest(repository: repository, number: ForgeItemNumber(1)))
            let store = GitX.HarnessDraftStore()
            let initial = ForgeDraftContent(title: "First", body: "Initial body")
            let updated = ForgeDraftContent(title: "Submitted", body: "Submitted body")
            try await store.save(identity: identity, content: initial, at: Date(timeIntervalSince1970: 10))
            let first = try await store.load(identity: identity)
            try await store.save(identity: identity, content: updated, at: Date(timeIntervalSince1970: 30))
            let loaded = try await store.load(identity: identity)
            let current = try XCTUnwrap(loaded)
            XCTAssertEqual(current.createdAt, Date(timeIntervalSince1970: 10))
            XCTAssertEqual(current.lastActivityAt, Date(timeIntervalSince1970: 30))
            XCTAssertEqual(current.content, updated)
            let staleDelete = try await store.delete(identity: identity, matching: XCTUnwrap(first))
            XCTAssertFalse(staleDelete)
            let removed = try await store.delete(identity: identity, matching: current)
            XCTAssertTrue(removed)
            let absent = try await store.load(identity: identity)
            XCTAssertNil(absent)
        }
    }

    @MainActor
    final class ForgeDraftSubmissionStoreTests: XCTestCase {
        func testShippedEditorPreservesConcurrentDraftAndRetainsOrdinaryAutosaves() async throws {
            let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
            let repository = try ForgeRepositoryIdentity(forge: forge, owner: "fixture", name: "submission")
            let identity = try ForgeDraftIdentity(accountID: ForgeAccountID(forge: forge, value: "fixture"), destination: .pullRequest(repository: repository, number: ForgeItemNumber(1)))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("shipped-draft-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let configuration = ForgeSQLiteConfiguration(databaseURL: root.appendingPathComponent("drafts.sqlite"), recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            let database = try ForgeSQLiteStore(configuration: configuration)
            let second = try ForgeSQLiteStore(configuration: configuration)
            let store = GitX.ForgeSQLitePullRequestDraftStore(database: database)
            let other = GitX.ForgeSQLitePullRequestDraftStore(database: second)
            let editor = GitX.RepositoryEditDraftSession(identity: identity, observed: nil)
            let original = ForgeDraftContent(title: "Original", body: "Original")
            let saved = await editor.saveSubmission(original, drafts: store, at: Date(timeIntervalSince1970: 10))
            XCTAssertEqual(saved?.content, original)
            let newer = ForgeDraftContent(title: "Newer window", body: "Preserve me")
            try await other.save(identity: identity, content: newer, at: Date(timeIntervalSince1970: 30))
            let refused = await editor.saveSubmission(original, drafts: store, at: Date(timeIntervalSince1970: 40))
            XCTAssertNil(refused)
            let retained = try await store.load(identity: identity)
            XCTAssertEqual(retained?.content, newer)
            await editor.autosave(original, drafts: store, at: Date(timeIntervalSince1970: 20))
            let admitted = await editor.saveSubmission(original, drafts: store, at: Date(timeIntervalSince1970: 25))
            XCTAssertEqual(admitted?.createdAt, Date(timeIntervalSince1970: 10))
            XCTAssertEqual(admitted?.lastActivityAt, Date(timeIntervalSince1970: 30))
            let collision = try await store.saveSnapshot(identity: identity, content: newer, at: .distantFuture, matching: nil)
            XCTAssertNil(collision)
            await database.close()
            await second.close()
        }

        func testShippedEditorDoesNotInventEvidenceFromUnavailableOrNullStorage() async throws {
            let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
            let repository = try ForgeRepositoryIdentity(forge: forge, owner: "fixture", name: "unavailable")
            let identity = try ForgeDraftIdentity(accountID: ForgeAccountID(forge: forge, value: "fixture"), destination: .pullRequest(repository: repository, number: ForgeItemNumber(1)))
            let content = ForgeDraftContent(title: "Draft", body: "Draft")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("unavailable-draft-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let database = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(databaseURL: root.appendingPathComponent("drafts.sqlite"), recoveryDirectoryURL: root.appendingPathComponent("recovery")))
            let store = GitX.ForgeSQLitePullRequestDraftStore(database: database)
            await database.close()
            let editor = GitX.RepositoryEditDraftSession(identity: identity, observed: nil)
            let refused = await editor.saveSubmission(content, drafts: store, at: Date())
            XCTAssertNil(refused)
            await editor.autosave(content, drafts: store, at: Date())
            let null = GitX.NullRepositoryPullRequestDraftStore()
            let other = GitX.RepositoryEditDraftSession(identity: identity, observed: nil)
            await other.autosave(content, drafts: null, at: Date())
            let unavailable = await other.saveSubmission(content, drafts: null, at: Date())
            XCTAssertNil(unavailable)
            let absent = try await null.saveSnapshot(identity: identity, content: content, at: Date(), matching: nil)
            XCTAssertNil(absent)
        }
    }

    @MainActor
    final class ForgeHarnessDraftStoreRegressionTests: XCTestCase {
        func testHarnessSaveKeepsActivityMonotonicForOutOfOrderDates() async throws {
            let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
            let repository = try ForgeRepositoryIdentity(forge: forge, owner: "fixture", name: "drafts")
            let identity = try ForgeDraftIdentity(accountID: ForgeAccountID(forge: forge, value: "fixture"), destination: .pullRequest(repository: repository, number: ForgeItemNumber(1)))
            let store = GitX.HarnessDraftStore()
            for (date, expected) in [(10.0, 10.0), (30, 30), (20, 30), (5, 30)] {
                try await store.save(identity: identity, content: ForgeDraftContent(title: "Date \(date)", body: "Body"), at: Date(timeIntervalSince1970: date))
                let value = try await store.load(identity: identity)
                XCTAssertEqual(value?.createdAt, Date(timeIntervalSince1970: 10))
                XCTAssertEqual(value?.lastActivityAt, Date(timeIntervalSince1970: expected))
            }
        }
    }

#endif
