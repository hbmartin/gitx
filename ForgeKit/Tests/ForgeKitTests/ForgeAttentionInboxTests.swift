@testable import ForgeKit
import Foundation
import SQLite3
import XCTest

final class ForgeAttentionInboxTests: XCTestCase {
    func testReconciliationBuildsAccountCurrentStateAndSuppressesFirstBaselineAlerts() throws {
        let fixture = try Fixture()
        let candidate = try fixture.pullRequestCandidate(
            assignees: [fixture.viewer],
            requestedReviewers: [.actor(fixture.viewer)],
            body: "Please review, @viewer.",
            comments: [fixture.activity(id: "own", author: fixture.viewer, body: "@viewer self", at: 10)],
            checkRollup: .failed,
            author: fixture.viewer
        )
        let snapshot = ForgeAttentionRepositorySnapshot(
            watchedRepositoryKey: fixture.watch.key,
            viewer: fixture.viewer,
            candidates: [candidate],
            fetchedAt: fixture.date(20),
            completeness: .complete
        )

        let result = try ForgeAttentionReconciler.reconcile(
            snapshot,
            watchedRepository: fixture.watch,
            existingRecords: []
        )

        XCTAssertEqual(Set(result.records.map(\.item.id.kind)), [
            .reviewRequest, .mention, .assignment, .failedCheck,
        ])
        XCTAssertTrue(result.records.allSatisfy { $0.item.seenState == .unseen })
        XCTAssertTrue(result.newlyActionable.isEmpty)
        XCTAssertEqual(result.watchedRepository.baselineEstablishedAt, fixture.date(20))
        XCTAssertEqual(result.watchedRepository.lastSuccessfulPollAt, fixture.date(20))
        XCTAssertFalse(result.records.contains { $0.sourceIdentifier.value == "own" })
    }

    func testOwnCommentsNeverCreateAttentionAndRepliesRequireParticipationAndBotOptIn() throws {
        let fixture = try Fixture()
        let own = fixture.activity(id: "own", author: fixture.viewer, body: "@viewer", at: 10)
        let human = fixture.activity(id: "human", author: fixture.other, body: "reply", at: 11)
        let bot = fixture.activity(id: "bot", author: fixture.bot, body: "reply", at: 12)
        let unparticipated = try fixture.pullRequestCandidate(
            participants: [],
            comments: [own, human, bot]
        )
        let denied = try reconcile(
            fixture: fixture,
            candidate: unparticipated,
            watch: fixture.watch,
            at: 20
        )
        XCTAssertTrue(denied.records.isEmpty)

        let participated = try fixture.pullRequestCandidate(
            participants: [fixture.viewer],
            comments: [own, human, bot]
        )
        let humanOnly = try reconcile(
            fixture: fixture,
            candidate: participated,
            watch: fixture.watch,
            at: 20
        )
        XCTAssertEqual(humanOnly.records.map(\.sourceIdentifier.value), ["human"])

        let botWatch = ForgeWatchedRepository(
            key: fixture.watch.key,
            addedAt: fixture.watch.addedAt,
            source: fixture.watch.source,
            includesBotReplies: true
        )
        let withBot = try reconcile(
            fixture: fixture,
            candidate: participated,
            watch: botWatch,
            at: 20
        )
        XCTAssertEqual(withBot.records.map(\.sourceIdentifier.value), ["bot"])
    }

    func testReviewThreadRepliesQualifyButTopLevelReviewCommentsDoNot() throws {
        let fixture = try Fixture()
        let topLevel = try fixture.reviewComment(
            id: "top-level",
            author: fixture.other,
            body: "general note",
            at: 10
        )
        let reply = try fixture.reviewComment(
            id: "thread-reply",
            author: fixture.other,
            body: "thread reply",
            at: 12,
            replyTo: "parent"
        )
        let candidate = try fixture.pullRequestCandidate(
            participants: [fixture.viewer],
            reviewComments: [topLevel, reply]
        )

        let result = try reconcile(fixture: fixture, candidate: candidate, watch: fixture.watch, at: 20)

        XCTAssertEqual(result.records.map(\.item.id.kind), [.reply])
        XCTAssertEqual(result.records.map(\.sourceIdentifier.value), ["thread-reply"])
    }

    func testMentionsUseExactLoginBoundariesAndDoNotRequireParticipation() throws {
        let fixture = try Fixture()
        let comments = [
            fixture.activity(id: "email", author: fixture.other, body: "viewer@example.com", at: 8),
            fixture.activity(id: "prefix", author: fixture.other, body: "@viewer-two", at: 9),
            fixture.activity(id: "exact", author: fixture.other, body: "Hi @VIEWER!", at: 10),
        ]
        let candidate = try fixture.issueCandidate(comments: comments)

        let result = try reconcile(fixture: fixture, candidate: candidate, watch: fixture.watch, at: 20)

        XCTAssertEqual(result.records.map(\.item.id.kind), [.mention])
        XCTAssertEqual(result.records.map(\.sourceIdentifier.value), ["exact"])
    }

    func testAttentionErrorsLegacyWatchAndRecordBoundariesRemainExplicit() throws {
        XCTAssertEqual(
            [
                ForgeAttentionInboxError.mismatchedWatch,
                .mismatchedViewerForge,
                .mismatchedSubject,
                .missingWatchedRepository,
                .corruptPersistenceRecord,
                .duplicateAttentionRecord,
                .staleRefreshGeneration,
            ].compactMap(\.errorDescription).count,
            7
        )
        let fixture = try Fixture()
        let encoded = try JSONEncoder().encode(fixture.watch)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "includesBotReplies")
        object.removeValue(forKey: "baselineEstablishedAt")
        object.removeValue(forKey: "lastSuccessfulPollAt")
        let legacy = try JSONDecoder().decode(
            ForgeWatchedRepository.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertFalse(legacy.includesBotReplies)
        XCTAssertNil(legacy.baselineEstablishedAt)
        XCTAssertNil(legacy.lastSuccessfulPollAt)
        XCTAssertNil(
            legacy.recordingSuccessfulPoll(at: fixture.date(5), establishesBaseline: false)
                .baselineEstablishedAt
        )

        let record = try fixture.record(kind: .mention, subject: "expiry", at: 10)
        let resolvedItem = try record.item.resolving(at: fixture.date(20))
        let resolved = record.replacing(item: resolvedItem)
        XCTAssertEqual(
            resolved.expiresAt,
            fixture.date(20).addingTimeInterval(ForgePolicyConstants.durableRecordExpiration)
        )
        let wrongSubject = try Fixture().issueCandidate(subject: "wrong").item
        XCTAssertThrowsError(try ForgeAttentionInboxEntry(record: record, subject: wrongSubject)) {
            XCTAssertEqual($0 as? ForgeAttentionInboxError, .mismatchedSubject)
        }
    }

    func testReconciliationRejectsMismatchedWatchAndViewerForge() throws {
        let fixture = try Fixture()
        let otherRepository = try TestSupport.repository(owner: "other")
        let otherKey = try ForgeWatchedRepositoryKey(
            accountID: fixture.accountID,
            repository: otherRepository
        )
        let candidate = try fixture.issueCandidate()
        XCTAssertThrowsError(try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: otherKey,
                viewer: fixture.viewer,
                candidates: [candidate],
                fetchedAt: fixture.date(1),
                completeness: .complete
            ),
            watchedRepository: fixture.watch,
            existingRecords: []
        )) {
            XCTAssertEqual($0 as? ForgeAttentionInboxError, .mismatchedWatch)
        }

        let gitLabRepository = try TestSupport.repository(kind: .gitLab)
        let gitLabViewer = try ForgeActor(
            id: ForgeObjectID(forge: gitLabRepository.forge, value: "viewer"),
            login: "viewer",
            kind: .person
        )
        XCTAssertThrowsError(try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: gitLabViewer,
                candidates: [candidate],
                fetchedAt: fixture.date(1),
                completeness: .complete
            ),
            watchedRepository: fixture.watch,
            existingRecords: []
        )) {
            XCTAssertEqual($0 as? ForgeAttentionInboxError, .mismatchedViewerForge)
        }
    }

    func testReconciliationRejectsDuplicateDurableRecordIdentitiesWithoutTrapping() throws {
        let fixture = try Fixture()
        let duplicate = try fixture.record(kind: .mention, subject: "duplicate", at: 10)
        let conflicting = try ForgeAttentionRecord(
            item: duplicate.item,
            sourceIdentifier: ForgeAttentionSubjectID("conflicting-source"),
            sourceOccurredAt: fixture.date(11)
        )
        let snapshot = ForgeAttentionRepositorySnapshot(
            watchedRepositoryKey: fixture.watch.key,
            viewer: fixture.viewer,
            candidates: [],
            fetchedAt: fixture.date(20),
            completeness: .complete
        )

        for records in [[duplicate, duplicate], [duplicate, conflicting]] {
            XCTAssertThrowsError(try ForgeAttentionReconciler.reconcile(
                snapshot,
                watchedRepository: fixture.watch,
                existingRecords: records
            )) {
                XCTAssertEqual($0 as? ForgeAttentionInboxError, .duplicateAttentionRecord)
            }
        }
    }

    func testAuthoredFailedCheckDoesNotTreatTeamReviewRequestAsViewerRequest() throws {
        let fixture = try Fixture()
        let team = try ForgeTeam(
            id: ForgeObjectID(forge: fixture.repository.forge, value: "team-only"),
            name: "Review Team",
            slug: "review-team"
        )
        let candidate = try fixture.pullRequestCandidate(
            requestedReviewers: [.team(team)],
            checkRollup: .failed,
            author: fixture.viewer
        )

        let result = try reconcile(fixture: fixture, candidate: candidate, watch: fixture.watch, at: 20)

        XCTAssertEqual(result.records.map(\.item.id.kind), [.failedCheck])
        XCTAssertTrue(result.records.allSatisfy(\.item.authoredPullRequestFailedCheck))
    }

    func testReconciliationCoversProviderPartialActorsTeamsTiesAndStableSorting() throws {
        let fixture = try Fixture()
        let team = try ForgeTeam(
            id: ForgeObjectID(forge: fixture.repository.forge, value: "team"),
            name: "Team",
            slug: "team"
        )
        let deleted = try ForgeAttentionActivity(
            id: ForgeObjectID(forge: fixture.repository.forge, value: "deleted"),
            kind: .conversationComment,
            author: .available(.deleted),
            bodyMarkdown: "ordinary comment",
            occurredAt: fixture.date(9)
        )
        let reviewOnly = fixture.activity(
            id: "review",
            author: fixture.other,
            body: "ordinary review",
            at: 10,
            kind: .review
        )
        let tieA = fixture.activity(id: "a", author: fixture.other, body: "reply", at: 11)
        let tieB = fixture.activity(id: "b", author: fixture.other, body: "reply", at: 11)
        let mentionedReview = try fixture.reviewComment(
            id: "review-mention",
            author: fixture.other,
            body: "@viewer",
            at: 12
        )
        let candidate = try fixture.pullRequestCandidate(
            participants: [fixture.viewer],
            requestedReviewers: [.team(team), .actor(fixture.viewer)],
            comments: [deleted, reviewOnly, tieA, tieB],
            reviewComments: [mentionedReview],
            checkRollup: .failed,
            author: fixture.other,
            checkRollupAvailable: false
        )
        let result = try reconcile(fixture: fixture, candidate: candidate, watch: fixture.watch, at: 20)
        XCTAssertEqual(result.records.first { $0.item.id.kind == .reply }?.sourceIdentifier.value, "b")
        XCTAssertEqual(result.records.first { $0.item.id.kind == .mention }?.sourceIdentifier.value, "review-mention")
        XCTAssertFalse(result.records.contains { $0.item.id.kind == .failedCheck })

        let unavailable = try fixture.pullRequestCandidate(
            participants: [fixture.viewer],
            reviewComments: [mentionedReview],
            reviewersAvailable: false,
            threadCommentsAvailable: false
        )
        XCTAssertTrue(try reconcile(
            fixture: fixture,
            candidate: unavailable,
            watch: fixture.watch,
            at: 21
        ).records.isEmpty)

        let later = try fixture.issueCandidate(
            subject: "later",
            comments: [fixture.activity(id: "later", author: fixture.other, body: "@viewer", at: 14)]
        )
        let earlier = try fixture.issueCandidate(
            subject: "earlier",
            comments: [fixture.activity(id: "earlier", author: fixture.other, body: "@viewer", at: 13)]
        )
        let sorted = try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [earlier, later],
                fetchedAt: fixture.date(22),
                completeness: .complete
            ),
            watchedRepository: fixture.watch,
            existingRecords: []
        )
        XCTAssertEqual(sorted.records.map(\.item.id.subjectID.value), ["earlier", "later"])
    }

    func testCompleteSnapshotsResolveMissingItemsWhilePartialSnapshotsRetainThem() throws {
        let fixture = try Fixture()
        let candidate = try fixture.issueCandidate(
            comments: [fixture.activity(id: "mention", author: fixture.other, body: "@viewer", at: 10)]
        )
        let baseline = try reconcile(fixture: fixture, candidate: candidate, watch: fixture.watch, at: 20)
        let establishedWatch = baseline.watchedRepository

        let partial = try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [],
                fetchedAt: fixture.date(30),
                completeness: .partial(unavailableSections: [.timeline])
            ),
            watchedRepository: establishedWatch,
            existingRecords: baseline.records
        )
        XCTAssertEqual(partial.records.first?.item.state, .active)
        XCTAssertTrue(partial.resolved.isEmpty)

        let complete = try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [],
                fetchedAt: fixture.date(40),
                completeness: .complete
            ),
            watchedRepository: partial.watchedRepository,
            existingRecords: partial.records
        )
        XCTAssertEqual(complete.records.first?.item.state, .resolved)
        XCTAssertEqual(complete.resolved.map(\.id), baseline.records.map(\.item.id))
    }

    func testNewSignalAndReappearingCurrentStateBecomeUnseenTransitionsOnlyAfterBaseline() throws {
        let fixture = try Fixture()
        let first = try fixture.issueCandidate(
            comments: [fixture.activity(id: "first", author: fixture.other, body: "@viewer", at: 10)]
        )
        let baseline = try reconcile(fixture: fixture, candidate: first, watch: fixture.watch, at: 20)
        let seenRecord = try XCTUnwrap(baseline.records.first).replacing(
            item: try XCTUnwrap(baseline.records.first).item.markingSeen(at: fixture.date(21))
        )
        let identical = try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [first],
                fetchedAt: fixture.date(30),
                completeness: .complete
            ),
            watchedRepository: baseline.watchedRepository,
            existingRecords: [seenRecord]
        )
        XCTAssertTrue(identical.newlyActionable.isEmpty)
        XCTAssertEqual(identical.records.first?.item.seenState, .seen(at: fixture.date(21)))

        let fresh = try fixture.pullRequestCandidate(
            subject: "fresh",
            assignees: [fixture.viewer],
            requestedReviewers: [.actor(fixture.viewer)]
        )
        let newlyAdded = try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [first, fresh],
                fetchedAt: fixture.date(31),
                completeness: .complete
            ),
            watchedRepository: identical.watchedRepository,
            existingRecords: identical.records
        )
        XCTAssertEqual(
            Set(newlyAdded.newlyActionable.map(\.id.kind)),
            Set([.assignment, .reviewRequest])
        )

        let second = try fixture.issueCandidate(comments: [
            fixture.activity(id: "first", author: fixture.other, body: "@viewer", at: 10),
            fixture.activity(id: "second", author: fixture.other, body: "@viewer", at: 31),
        ])
        let transitioned = try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [second],
                fetchedAt: fixture.date(32),
                completeness: .complete
            ),
            watchedRepository: identical.watchedRepository,
            existingRecords: identical.records
        )
        XCTAssertEqual(transitioned.newlyActionable.map(\.id.kind), [.mention])
        XCTAssertEqual(transitioned.records.first?.item.seenState, .unseen)

        let resolved = try transitioned.records[0].replacing(
            item: transitioned.records[0].item.resolving(at: fixture.date(40))
        )
        let reappeared = try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [second],
                fetchedAt: fixture.date(50),
                completeness: .complete
            ),
            watchedRepository: transitioned.watchedRepository,
            existingRecords: [resolved]
        )
        XCTAssertEqual(reappeared.records.first?.item.state, .active)
        XCTAssertEqual(reappeared.newlyActionable.map(\.id.kind), [.mention])
    }

    func testViewStateDefaultsToUnseenNewestAndFiltersScopeKindsAndColumns() throws {
        let fixture = try Fixture()
        let otherRepository = try TestSupport.repository(owner: "other")
        let defaultState = ForgeAttentionViewState.defaultValue
        XCTAssertEqual(defaultState.scope, .currentRepository)
        XCTAssertEqual(defaultState.visibility, .unseenOnly)
        XCTAssertEqual(defaultState.sortOrder, .newestFirst)
        XCTAssertEqual(defaultState.kinds, Set(ForgeAttentionKind.allCases))
        XCTAssertTrue(defaultState.columns.contains(.title))
        XCTAssertTrue(defaultState.columns.contains(.repository))

        let currentMention = try fixture.entry(kind: .mention, subject: "current", at: 30)
        let currentReply = try fixture.entry(kind: .reply, subject: "reply", at: 20)
        let other = try fixture.entry(
            repository: otherRepository,
            kind: .mention,
            subject: "other",
            at: 40
        )
        let seen = try fixture.entry(kind: .mention, subject: "seen", at: 50, seenAt: 55)
        let state = ForgeAttentionViewState(
            scope: .currentRepository,
            visibility: .unseenOnly,
            sortOrder: .oldestFirst,
            kinds: [.mention],
            columns: [.kind, .title]
        )
        let query = ForgeAttentionInboxQuery(
            accountID: fixture.accountID,
            currentRepository: fixture.repository,
            state: state
        )

        XCTAssertEqual(
            query.applying(to: [other, currentReply, seen, currentMention]).map(\.record.item.id.subjectID.value),
            ["current"]
        )
        XCTAssertEqual(
            ForgeAttentionViewState(
                scope: .all,
                visibility: .active,
                sortOrder: .newestFirst,
                kinds: Set(ForgeAttentionKind.allCases),
                columns: Set(ForgeAttentionColumn.allCases)
            ).columns,
            Set(ForgeAttentionColumn.allCases)
        )
        let newest = ForgeAttentionInboxQuery(
            accountID: fixture.accountID,
            currentRepository: fixture.repository,
            state: ForgeAttentionViewState(visibility: .active)
        )
        XCTAssertEqual(
            newest.applying(to: [currentReply, currentMention]).map(\.record.item.id.subjectID.value),
            ["current", "reply"]
        )
        let oldest = ForgeAttentionInboxQuery(
            accountID: fixture.accountID,
            currentRepository: fixture.repository,
            state: ForgeAttentionViewState(visibility: .active, sortOrder: .oldestFirst)
        )
        XCTAssertEqual(
            oldest.applying(to: [currentMention, currentReply]).map(\.record.item.id.subjectID.value),
            ["reply", "current"]
        )
        let tieA = try fixture.entry(kind: .mention, subject: "a", at: 60)
        let tieB = try fixture.entry(kind: .mention, subject: "b", at: 60)
        XCTAssertEqual(
            newest.applying(to: [tieB, tieA]).map(\.record.item.id.subjectID.value),
            ["a", "b"]
        )
    }

    func testPollingSchedulerUsesPresetTargetsAndFairRoundRobinWithoutCap() throws {
        let fixture = try Fixture()
        let watches = try (0 ..< 120).map { index -> ForgeWatchedRepository in
            let repository = try TestSupport.repository(owner: "owner-\(index)")
            let key = try ForgeWatchedRepositoryKey(accountID: fixture.accountID, repository: repository)
            return ForgeWatchedRepository(
                key: key,
                addedAt: fixture.date(0),
                source: .preferences,
                lastSuccessfulPollAt: fixture.date(0)
            )
        }
        var scheduler = ForgeAttentionPollingScheduler(preset: .balanced)
        XCTAssertNil(scheduler.nextTarget(
            watchedRepositories: [],
            activeOrOpenRepositories: [],
            at: fixture.date(300)
        ))
        let activeKey = watches[0].key
        XCTAssertNil(scheduler.nextTarget(
            watchedRepositories: watches,
            activeOrOpenRepositories: [activeKey],
            at: fixture.date(299)
        ))
        let active = try XCTUnwrap(scheduler.nextTarget(
            watchedRepositories: watches,
            activeOrOpenRepositories: [activeKey],
            at: fixture.date(300)
        ))
        XCTAssertEqual(active.watchedRepository.key, activeKey)
        XCTAssertEqual(active.activity, .activeOrOpen)
        XCTAssertEqual(active.targetInterval, 300)
        scheduler.recordSelection(active)

        var visited: Set<ForgeWatchedRepositoryKey> = []
        for _ in watches.indices {
            let target = try XCTUnwrap(scheduler.nextTarget(
                watchedRepositories: watches,
                activeOrOpenRepositories: [],
                at: fixture.date(900)
            ))
            XCTAssertTrue(visited.insert(target.watchedRepository.key).inserted)
            scheduler.recordSelection(target)
        }
        XCTAssertEqual(visited.count, watches.count)
        XCTAssertNil(ForgeAttentionPollingScheduler(preset: .manual).nextTarget(
            watchedRepositories: watches,
            activeOrOpenRepositories: [activeKey],
            at: fixture.date(10000)
        ))
    }

    func testSQLiteAttentionPersistenceOwnsWatchesSeenStateMarkAllAndExpiry() async throws {
        let fixture = try Fixture()
        let sqliteFixture = try SQLiteFixture()
        let sqlite = try ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        let persistence = ForgeSQLiteAttentionPersistence(store: sqlite)
        try await persistence.save(fixture.watch)

        let unseen = try fixture.record(kind: .mention, subject: "unseen", at: 10)
        let second = try fixture.record(kind: .reply, subject: "second", at: 20)
        try await persistence.save([unseen, second])
        let watches = try await persistence.watchedRepositories(accountID: fixture.accountID)
        XCTAssertEqual(watches, [fixture.watch])
        let stored = try await persistence.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            at: fixture.date(21)
        )
        XCTAssertEqual(Set(stored), Set([unseen, second]))

        let opened = try await persistence.open(unseen.item.id, at: fixture.date(30))
        XCTAssertEqual(opened?.item.seenState, .seen(at: fixture.date(30)))
        let query = ForgeAttentionQuery(scope: .all(accountID: fixture.accountID), visibility: .active)
        let marked = try await persistence.markAllSeen(query: query, at: fixture.date(40))
        XCTAssertEqual(marked.count, 2)
        let unmarked = try await persistence.markUnseen(second.item.id, at: fixture.date(50))
        XCTAssertEqual(unmarked?.item.seenState, .unseen)

        let removed = try await persistence.removeExpired(at: fixture.date(40) + 30 * 24 * 60 * 60)
        XCTAssertEqual(removed, 1)
        let retained = try await persistence.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            at: fixture.date(50) + 30 * 24 * 60 * 60
        )
        XCTAssertEqual(retained.map(\.item.id.subjectID.value), ["second"])

        try await persistence.removeWatchedRepository(fixture.watch.key)
        let remainingWatches = try await persistence.watchedRepositories(accountID: fixture.accountID)
        let remainingRecords = try await persistence.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            at: fixture.date(100)
        )
        XCTAssertTrue(remainingWatches.isEmpty)
        XCTAssertTrue(remainingRecords.isEmpty)
    }

    func testSQLiteAttentionPersistenceCoversPartitionValidationMissingCacheAndCurrentScope() async throws {
        let fixture = try Fixture()
        let sqliteFixture = try SQLiteFixture()
        let store = try ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        let persistence = ForgeSQLiteAttentionPersistence(store: store)
        let otherRepository = try TestSupport.repository(owner: "other")
        let crossForgeRepository = try TestSupport.repository(kind: .gitLab)

        await XCTAssertThrowsErrorAsync {
            _ = try await store.durableRecords(
                kind: .attention,
                accountID: fixture.accountID,
                repository: crossForgeRepository
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await store.removeExpiredDurableRecords(kind: .attention, at: .init(timeIntervalSince1970: .nan))
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await store.deleteDurableRecords(
                kind: .attention,
                accountID: fixture.accountID,
                repository: crossForgeRepository
            )
        }

        let current = try fixture.record(kind: .mention, subject: "current", at: 10)
        let other = try fixture.record(
            repository: otherRepository,
            kind: .reply,
            subject: "other",
            at: 11
        )
        let expired = try fixture.record(kind: .assignment, subject: "expired", at: 12, seenAt: 13)
        try await persistence.save([current, other, expired])
        let filtered = try await persistence.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            at: fixture.date(13).addingTimeInterval(ForgePolicyConstants.durableRecordExpiration + 1)
        )
        XCTAssertEqual(filtered.map(\.item.id.subjectID.value), ["current"])

        let currentQuery = ForgeAttentionQuery(
            scope: .currentRepository(fixture.watch.key),
            visibility: .unseenOnly
        )
        let marked = try await persistence.markAllSeen(query: currentQuery, at: fixture.date(20))
        XCTAssertEqual(marked.map(\.item.id.subjectID.value), ["current"])
        let otherRecord = try await persistence.record(other.item.id)
        XCTAssertEqual(otherRecord?.item.seenState, .unseen)

        let missingID = try ForgeAttentionItemID(
            accountID: fixture.accountID,
            repository: fixture.repository,
            kind: .mention,
            subjectID: ForgeAttentionSubjectID("missing")
        )
        let missingRecord = try await persistence.record(missingID)
        let missingOpen = try await persistence.open(missingID, at: fixture.date(21))
        XCTAssertNil(missingRecord)
        XCTAssertNil(missingOpen)

        let allQuery = ForgeAttentionInboxQuery(
            accountID: fixture.accountID,
            currentRepository: nil,
            state: ForgeAttentionViewState(scope: .all, visibility: .active)
        )
        let missingCache = try await persistence.cachedEntries(query: allQuery, at: fixture.date(22))
        XCTAssertTrue(missingCache.isEmpty)
    }

    func testSQLiteAttentionPersistenceFailsClosedForMismatchedDurableAndCachePayloads() async throws {
        let fixture = try Fixture()
        let sqliteFixture = try SQLiteFixture()
        let store = try ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        let persistence = ForgeSQLiteAttentionPersistence(store: store)
        let current = try fixture.record(kind: .mention, subject: "current", at: 10)
        let replacement = try fixture.record(kind: .reply, subject: "replacement", at: 11)
        try await persistence.save([current])

        let replacementPayload = try JSONEncoder().encode(replacement)
        try await store.saveDurableRecord(ForgeSQLiteDurableRecord(
            kind: .attention,
            accountID: fixture.accountID,
            repository: fixture.repository,
            key: ForgeSQLiteStore.encodedKey(current.item.id),
            payload: replacementPayload,
            lastActivityAt: fixture.date(11)
        ))
        await XCTAssertThrowsErrorAsync {
            _ = try await persistence.record(current.item.id)
        }

        try await persistence.save([current])
        let replacementEntry = try fixture.entry(kind: .reply, subject: "replacement", at: 11)
        let cachePayload = try JSONEncoder().encode(replacementEntry)
        let partition = try ForgeRepositoryPartitionKey(
            cachePartition: .account(fixture.accountID),
            repository: fixture.repository
        )
        let identity = try ForgeSQLiteStore.encodedKey(current.item.id).base64EncodedString()
        let cacheKey = ForgeDisposableCacheKey.snapshot(ForgeCacheRecordKey(
            repositoryPartition: partition,
            kind: .derivedRenderData,
            identity: "attention:\(identity)"
        ))
        try await store.putCacheEntry(ForgeSQLiteCacheEntry(
            record: ForgeDisposableCacheRecord(
                key: cacheKey,
                byteCount: UInt64(cachePayload.count),
                fetchedAt: fixture.date(12),
                lastAccessedAt: fixture.date(12)
            ),
            payload: cachePayload
        ))
        await XCTAssertThrowsErrorAsync {
            _ = try await persistence.cachedEntries(
                query: ForgeAttentionInboxQuery(
                    accountID: fixture.accountID,
                    currentRepository: fixture.repository,
                    state: ForgeAttentionViewState(visibility: .active)
                ),
                at: fixture.date(13)
            )
        }

        let otherRepository = try TestSupport.repository(owner: "other")
        let otherKey = try ForgeWatchedRepositoryKey(
            accountID: fixture.accountID,
            repository: otherRepository
        )
        let otherWatch = ForgeWatchedRepository(key: otherKey, addedAt: fixture.date(1), source: .preferences)
        try await store.saveDurableRecord(ForgeSQLiteDurableRecord(
            kind: .watchedRepository,
            accountID: fixture.accountID,
            repository: fixture.repository,
            key: ForgeSQLiteStore.encodedKey(fixture.watch.key),
            payload: JSONEncoder().encode(otherWatch),
            lastActivityAt: fixture.date(1)
        ))
        await XCTAssertThrowsErrorAsync {
            _ = try await persistence.watchedRepositories(accountID: fixture.accountID)
        }
    }

    func testCoordinatorRequestsPermissionOnceSuppressesBaselineAndDeliversOnlyTransitions() async throws {
        let fixture = try Fixture()
        let sqliteFixture = try SQLiteFixture()
        let sqlite = try ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        let persistence = ForgeSQLiteAttentionPersistence(store: sqlite)
        try await persistence.save(fixture.watch)
        let first = try fixture.issueCandidate(
            comments: [fixture.activity(id: "first", author: fixture.other, body: "@viewer", at: 10)]
        )
        let second = try fixture.issueCandidate(comments: [
            fixture.activity(id: "first", author: fixture.other, body: "@viewer", at: 10),
            fixture.activity(id: "second", author: fixture.other, body: "@viewer", at: 30),
        ])
        let fetcher = SnapshotFetcher(snapshots: [
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [first],
                fetchedAt: fixture.date(20),
                completeness: .complete
            ),
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [second],
                fetchedAt: fixture.date(40),
                completeness: .complete
            ),
        ])
        let alerts = AlertDelivery(authorization: .notDetermined, requestResult: true)
        let coordinator = ForgeAttentionInboxCoordinator(
            persistence: persistence,
            fetcher: fetcher,
            alertDelivery: alerts,
            enabledAlertCategories: []
        )

        let requestedPermission = await coordinator.updateAlertCategories([.mentionsAndReplies])
        let requestedPermissionAgain = await coordinator.updateAlertCategories([.mentionsAndReplies, .assignments])
        let requestCount = await alerts.requestCount
        XCTAssertTrue(requestedPermission)
        XCTAssertFalse(requestedPermissionAgain)
        XCTAssertEqual(requestCount, 1)

        let baseline = try await coordinator.refresh(fixture.watch.key)
        XCTAssertTrue(baseline.newlyActionable.isEmpty)
        let baselineAlerts = await alerts.delivered
        XCTAssertTrue(baselineAlerts.isEmpty)
        let cachedBaseline = try await persistence.cachedEntries(
            query: ForgeAttentionInboxQuery(
                accountID: fixture.accountID,
                currentRepository: fixture.repository
            ),
            at: fixture.date(21)
        )
        XCTAssertEqual(cachedBaseline.map(\.record.item.id.kind), [.mention])
        XCTAssertEqual(cachedBaseline.map(\.subject.destination), [first.item.destination])
        let transition = try await coordinator.refresh(fixture.watch.key)
        XCTAssertEqual(transition.newlyActionable.map(\.id.kind), [.mention])
        let delivered = await alerts.delivered
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].actions, [.open, .markSeen])

        let destination = try await coordinator.handle(
            action: .open,
            itemID: delivered[0].itemID,
            at: fixture.date(50)
        )
        XCTAssertEqual(destination, delivered[0].destination)
        let openedRecord = try await persistence.record(delivered[0].itemID)
        XCTAssertEqual(openedRecord?.item.seenState, .seen(at: fixture.date(50)))
        let activeCached = try await persistence.cachedEntries(
            query: ForgeAttentionInboxQuery(
                accountID: fixture.accountID,
                currentRepository: fixture.repository,
                state: ForgeAttentionViewState(visibility: .active)
            ),
            at: fixture.date(51)
        )
        XCTAssertEqual(activeCached.map(\.record.item.seenState), [.seen(at: fixture.date(50))])
        let markedDestination = try await coordinator.handle(
            action: .markSeen,
            itemID: delivered[0].itemID,
            at: fixture.date(60)
        )
        XCTAssertNil(markedDestination)
    }

    func testCoordinatorRefreshesDueTargetsRoundRobinAndAdvancesPastFailures() async throws {
        let fixture = try Fixture()
        let secondRepository = try TestSupport.repository(owner: "second")
        let secondKey = try ForgeWatchedRepositoryKey(accountID: fixture.accountID, repository: secondRepository)
        let secondWatch = ForgeWatchedRepository(
            key: secondKey,
            addedAt: fixture.date(0),
            source: .preferences
        )
        let sqliteFixture = try SQLiteFixture()
        let persistence = try ForgeSQLiteAttentionPersistence(
            store: ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        )
        try await persistence.save(fixture.watch)
        try await persistence.save(secondWatch)
        let fetcher = KeyedSnapshotFetcher(viewer: fixture.viewer, failing: fixture.watch.key)
        let coordinator = ForgeAttentionInboxCoordinator(
            persistence: persistence,
            fetcher: fetcher,
            alertDelivery: AlertDelivery(authorization: .denied, requestResult: false),
            pollingPreset: .frequent
        )

        do {
            _ = try await coordinator.refreshNextDue(
                accountID: fixture.accountID,
                activeOrOpenRepositories: [],
                at: fixture.date(0)
            )
            XCTFail("Expected the first due repository to fail")
        } catch KeyedSnapshotFetcher.Failure.expected {}
        let second = try await coordinator.refreshNextDue(
            accountID: fixture.accountID,
            activeOrOpenRepositories: [],
            at: fixture.date(0)
        )
        XCTAssertEqual(second?.watchedRepository.key, secondKey)
        let requestedKeys = await fetcher.requestedKeys
        XCTAssertEqual(requestedKeys.count, 2)
    }

    func testInFlightRefreshPreservesSeenStateWrittenThroughAnotherCoordinator() async throws {
        let fixture = try Fixture()
        let sqliteFixture = try SQLiteFixture()
        defer { try? FileManager.default.removeItem(at: sqliteFixture.root) }
        let store = try ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        let refreshPersistence = ForgeSQLiteAttentionPersistence(store: store)
        let mutationPersistence = ForgeSQLiteAttentionPersistence(store: store)
        let establishedWatch = ForgeWatchedRepository(
            key: fixture.watch.key,
            addedAt: fixture.watch.addedAt,
            source: fixture.watch.source,
            baselineEstablishedAt: fixture.date(1),
            lastSuccessfulPollAt: fixture.date(1)
        )
        try await refreshPersistence.save(establishedWatch)
        let candidate = try fixture.issueCandidate(assignees: [fixture.viewer])
        let baseline = try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [candidate],
                fetchedAt: fixture.date(20),
                completeness: .complete
            ),
            watchedRepository: establishedWatch,
            existingRecords: []
        )
        try await refreshPersistence.persist(baseline)
        let itemID = try XCTUnwrap(baseline.records.first?.item.id)
        let fetcher = GatedSnapshotFetcher(snapshot: ForgeAttentionRepositorySnapshot(
            watchedRepositoryKey: fixture.watch.key,
            viewer: fixture.viewer,
            candidates: [candidate],
            fetchedAt: fixture.date(50),
            completeness: .complete
        ))
        let refreshCoordinator = ForgeAttentionInboxCoordinator(
            persistence: refreshPersistence,
            fetcher: fetcher,
            alertDelivery: AlertDelivery(authorization: .denied, requestResult: false)
        )
        let mutationCoordinator = ForgeAttentionInboxCoordinator(
            persistence: mutationPersistence,
            fetcher: SnapshotFetcher(snapshots: []),
            alertDelivery: AlertDelivery(authorization: .denied, requestResult: false)
        )

        let refresh = Task { try await refreshCoordinator.refresh(fixture.watch.key) }
        defer {
            refresh.cancel()
            Task { await fetcher.release() }
        }
        try await fetcher.waitUntilRequested()
        _ = try await mutationCoordinator.handle(action: .markSeen, itemID: itemID, at: fixture.date(40))
        await fetcher.release()
        let reconciliation = try await refresh.value

        let stored = try await mutationPersistence.record(itemID)
        XCTAssertEqual(stored?.item.seenState, .seen(at: fixture.date(40)))
        XCTAssertEqual(reconciliation.records.first?.item.seenState, .seen(at: fixture.date(40)))
    }

    func testInFlightRefreshCannotResurrectWatchRemovedThroughAnotherPersistenceInstance() async throws {
        let fixture = try Fixture()
        let sqliteFixture = try SQLiteFixture()
        defer { try? FileManager.default.removeItem(at: sqliteFixture.root) }
        let store = try ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        let refreshPersistence = ForgeSQLiteAttentionPersistence(store: store)
        let preferencesPersistence = ForgeSQLiteAttentionPersistence(store: store)
        try await refreshPersistence.save(fixture.watch)
        let fetcher = GatedSnapshotFetcher(snapshot: ForgeAttentionRepositorySnapshot(
            watchedRepositoryKey: fixture.watch.key,
            viewer: fixture.viewer,
            candidates: [],
            fetchedAt: fixture.date(20),
            completeness: .complete
        ))
        let coordinator = ForgeAttentionInboxCoordinator(
            persistence: refreshPersistence,
            fetcher: fetcher,
            alertDelivery: AlertDelivery(authorization: .denied, requestResult: false)
        )

        let refresh = Task { try await coordinator.refresh(fixture.watch.key) }
        defer {
            refresh.cancel()
            Task { await fetcher.release() }
        }
        try await fetcher.waitUntilRequested()
        try await preferencesPersistence.removeWatchedRepository(fixture.watch.key)
        await fetcher.release()
        do {
            _ = try await refresh.value
            XCTFail("An unwatched repository must reject its in-flight refresh")
        } catch {
            XCTAssertEqual(error as? ForgeAttentionInboxError, .missingWatchedRepository)
        }

        let watches = try await refreshPersistence.watchedRepositories(accountID: fixture.accountID)
        let records = try await refreshPersistence.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            at: fixture.date(21)
        )
        XCTAssertTrue(watches.isEmpty)
        XCTAssertTrue(records.isEmpty)
    }

    func testInFlightRefreshPreservesBotReplyPolicyWrittenThroughAnotherPersistenceInstance() async throws {
        let fixture = try Fixture()
        let sqliteFixture = try SQLiteFixture()
        defer { try? FileManager.default.removeItem(at: sqliteFixture.root) }
        let store = try ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        let refreshPersistence = ForgeSQLiteAttentionPersistence(store: store)
        let preferencesPersistence = ForgeSQLiteAttentionPersistence(store: store)
        try await refreshPersistence.save(fixture.watch)
        let fetcher = GatedSnapshotFetcher(snapshot: ForgeAttentionRepositorySnapshot(
            watchedRepositoryKey: fixture.watch.key,
            viewer: fixture.viewer,
            candidates: [],
            fetchedAt: fixture.date(20),
            completeness: .complete
        ))
        let coordinator = ForgeAttentionInboxCoordinator(
            persistence: refreshPersistence,
            fetcher: fetcher,
            alertDelivery: AlertDelivery(authorization: .denied, requestResult: false)
        )

        let refresh = Task { try await coordinator.refresh(fixture.watch.key) }
        defer {
            refresh.cancel()
            Task { await fetcher.release() }
        }
        try await fetcher.waitUntilRequested()
        let updated = try await preferencesPersistence.setIncludesBotReplies(true, for: fixture.watch.key)
        XCTAssertTrue(updated.includesBotReplies)
        await fetcher.release()
        _ = try await refresh.value

        let storedWatch = try await refreshPersistence.watchedRepositories(accountID: fixture.accountID).first
        XCTAssertTrue(try XCTUnwrap(storedWatch).includesBotReplies)
        XCTAssertEqual(storedWatch?.lastSuccessfulPollAt, fixture.date(20))
    }

    func testBotReplyPolicyMutationCannotResurrectRemovedWatch() async throws {
        let fixture = try Fixture()
        let sqliteFixture = try SQLiteFixture()
        defer { try? FileManager.default.removeItem(at: sqliteFixture.root) }
        let store = try ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        let persistence = ForgeSQLiteAttentionPersistence(store: store)
        try await persistence.save(fixture.watch)

        try await ForgeSQLiteAttentionPersistence(store: store).removeWatchedRepository(fixture.watch.key)
        do {
            _ = try await persistence.setIncludesBotReplies(true, for: fixture.watch.key)
            XCTFail("A removed watch must not be recreated by a stale preferences mutation")
        } catch {
            XCTAssertEqual(error as? ForgeAttentionInboxError, .missingWatchedRepository)
        }
        let remainingWatches = try await persistence.watchedRepositories(accountID: fixture.accountID)
        XCTAssertTrue(remainingWatches.isEmpty)
    }

    func testPublicPersistKeepsEstablishedBaselineMonotonic() async throws {
        let fixture = try Fixture()
        let sqliteFixture = try SQLiteFixture()
        defer { try? FileManager.default.removeItem(at: sqliteFixture.root) }
        let persistence = try ForgeSQLiteAttentionPersistence(
            store: ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        )
        try await persistence.save(fixture.watch)
        let complete = try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [],
                fetchedAt: fixture.date(20),
                completeness: .complete
            ),
            watchedRepository: fixture.watch,
            existingRecords: []
        )
        let stalePartial = try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [],
                fetchedAt: fixture.date(30),
                completeness: .partial(unavailableSections: [.timeline])
            ),
            watchedRepository: fixture.watch,
            existingRecords: []
        )

        try await persistence.persist(complete)
        try await persistence.persist(stalePartial)

        let storedWatches = try await persistence.watchedRepositories(accountID: fixture.accountID)
        let storedWatch = try XCTUnwrap(storedWatches.first)
        XCTAssertEqual(storedWatch.baselineEstablishedAt, fixture.date(20))
        XCTAssertEqual(storedWatch.lastSuccessfulPollAt, fixture.date(30))
    }

    func testPublicPersistBootstrapsMissingWatchAndRejectsStaleGeneration() async throws {
        let fixture = try Fixture()
        let sqliteFixture = try SQLiteFixture()
        defer { try? FileManager.default.removeItem(at: sqliteFixture.root) }
        let persistence = try ForgeSQLiteAttentionPersistence(
            store: ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        )
        let reconciliation = try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [],
                fetchedAt: fixture.date(20),
                completeness: .complete
            ),
            watchedRepository: fixture.watch,
            existingRecords: []
        )

        try await persistence.persist(reconciliation)
        let bootstrapped = try await persistence.watchedRepositories(accountID: fixture.accountID)
        XCTAssertEqual(bootstrapped, [reconciliation.watchedRepository])

        try await persistence.save(fixture.watch.recordingSuccessfulPoll(
            at: fixture.date(30),
            establishesBaseline: true
        ))
        do {
            try await persistence.persist(reconciliation)
            XCTFail("An older public reconciliation must not overwrite a newer generation")
        } catch {
            XCTAssertEqual(error as? ForgeAttentionInboxError, .staleRefreshGeneration)
        }
    }

    func testPersistenceSortsTiedTransitionsBySubjectAcrossReadsAndReconciliation() async throws {
        let fixture = try Fixture()
        let sqliteFixture = try SQLiteFixture()
        defer { try? FileManager.default.removeItem(at: sqliteFixture.root) }
        let persistence = try ForgeSQLiteAttentionPersistence(
            store: ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        )
        let zulu = try fixture.record(kind: .mention, subject: "zulu", at: 10)
        let alpha = try fixture.record(kind: .reply, subject: "alpha", at: 10)
        try await persistence.save(fixture.watch)
        try await persistence.save([zulu, alpha])

        let loaded = try await persistence.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            at: fixture.date(11)
        )
        XCTAssertEqual(loaded.map(\.item.id.subjectID.value), ["alpha", "zulu"])

        let reconciled = try await persistence.reconcileAndPersist(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [],
                fetchedAt: fixture.date(20),
                completeness: .partial(unavailableSections: [.timeline])
            ),
            policy: .defaultValue
        )
        XCTAssertEqual(reconciled.records.map(\.item.id.subjectID.value), ["alpha", "zulu"])
    }

    func testOlderCrossCoordinatorRefreshCannotOverwriteNewerCommittedGeneration() async throws {
        let fixture = try Fixture()
        let sqliteFixture = try SQLiteFixture()
        defer { try? FileManager.default.removeItem(at: sqliteFixture.root) }
        let store = try ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        let persistence = ForgeSQLiteAttentionPersistence(store: store)
        try await persistence.save(fixture.watch)
        let olderFetcher = GatedSnapshotFetcher(snapshot: ForgeAttentionRepositorySnapshot(
            watchedRepositoryKey: fixture.watch.key,
            viewer: fixture.viewer,
            candidates: [],
            fetchedAt: fixture.date(20),
            completeness: .complete
        ))
        let olderCoordinator = ForgeAttentionInboxCoordinator(
            persistence: ForgeSQLiteAttentionPersistence(store: store),
            fetcher: olderFetcher,
            alertDelivery: AlertDelivery(authorization: .denied, requestResult: false)
        )
        let newerCoordinator = ForgeAttentionInboxCoordinator(
            persistence: ForgeSQLiteAttentionPersistence(store: store),
            fetcher: SnapshotFetcher(snapshots: [ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [],
                fetchedAt: fixture.date(30),
                completeness: .complete
            )]),
            alertDelivery: AlertDelivery(authorization: .denied, requestResult: false)
        )

        let olderRefresh = Task { try await olderCoordinator.refresh(fixture.watch.key) }
        defer {
            olderRefresh.cancel()
            Task { await olderFetcher.release() }
        }
        try await olderFetcher.waitUntilRequested()
        _ = try await newerCoordinator.refresh(fixture.watch.key)
        await olderFetcher.release()
        do {
            _ = try await olderRefresh.value
            XCTFail("An older cross-coordinator generation must not commit after a newer one")
        } catch {
            XCTAssertEqual(error as? ForgeAttentionInboxError, .staleRefreshGeneration)
        }

        let storedWatch = try await persistence.watchedRepositories(accountID: fixture.accountID).first
        XCTAssertEqual(storedWatch?.lastSuccessfulPollAt, fixture.date(30))
        do {
            _ = try await persistence.reconcileAndPersist(
                ForgeAttentionRepositorySnapshot(
                    watchedRepositoryKey: fixture.watch.key,
                    viewer: fixture.viewer,
                    candidates: [],
                    fetchedAt: fixture.date(30),
                    completeness: .complete
                ),
                policy: ForgeAttentionPolicy()
            )
            XCTFail("An equal refresh generation must not overwrite the committed result")
        } catch {
            XCTAssertEqual(error as? ForgeAttentionInboxError, .staleRefreshGeneration)
        }
    }

    func testReconciliationRollsBackBaselineWhenDurableRecordWriteFails() async throws {
        let fixture = try Fixture()
        let sqliteFixture = try SQLiteFixture()
        defer { try? FileManager.default.removeItem(at: sqliteFixture.root) }
        let store = try ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        let persistence = ForgeSQLiteAttentionPersistence(store: store)
        try await persistence.save(fixture.watch)
        let candidate = try fixture.issueCandidate(assignees: [fixture.viewer])
        let snapshot = ForgeAttentionRepositorySnapshot(
            watchedRepositoryKey: fixture.watch.key,
            viewer: fixture.viewer,
            candidates: [candidate],
            fetchedAt: fixture.date(20),
            completeness: .complete
        )
        let reconciliation = try ForgeAttentionReconciler.reconcile(
            snapshot,
            watchedRepository: fixture.watch,
            existingRecords: []
        )
        try executeSQLite(
            """
            CREATE TRIGGER fail_attention_record
            BEFORE INSERT ON forge_durable_records
            WHEN NEW.kind = 3
            BEGIN
                SELECT RAISE(ABORT, 'forced attention record failure');
            END
            """,
            at: sqliteFixture.configuration.databaseURL
        )

        await XCTAssertThrowsErrorAsync {
            try await persistence.persist(reconciliation)
        }
        let watchAfterFailure = try await persistence.watchedRepositories(accountID: fixture.accountID).first
        let recordsAfterFailure = try await persistence.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            at: fixture.date(21)
        )
        XCTAssertNil(watchAfterFailure?.baselineEstablishedAt)
        XCTAssertNil(watchAfterFailure?.lastSuccessfulPollAt)
        XCTAssertTrue(recordsAfterFailure.isEmpty)

        try executeSQLite("DROP TRIGGER fail_attention_record", at: sqliteFixture.configuration.databaseURL)
        let alerts = AlertDelivery(authorization: .authorized, requestResult: true)
        let coordinator = ForgeAttentionInboxCoordinator(
            persistence: persistence,
            fetcher: SnapshotFetcher(snapshots: [ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [candidate],
                fetchedAt: fixture.date(30),
                completeness: .complete
            )]),
            alertDelivery: alerts,
            enabledAlertCategories: [.assignments]
        )
        _ = try await coordinator.refresh(fixture.watch.key)
        let delivered = await alerts.delivered
        XCTAssertTrue(delivered.isEmpty, "A rolled-back first baseline must not become a notification storm")
    }

    func testReconciliationRollsBackWatchAndRecordsWhenCacheWriteFails() async throws {
        let fixture = try Fixture()
        let sqliteFixture = try SQLiteFixture()
        defer { try? FileManager.default.removeItem(at: sqliteFixture.root) }
        let store = try ForgeSQLiteStore(configuration: sqliteFixture.configuration)
        let persistence = ForgeSQLiteAttentionPersistence(store: store)
        try await persistence.save(fixture.watch)
        let candidate = try fixture.issueCandidate(assignees: [fixture.viewer])
        let reconciliation = try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [candidate],
                fetchedAt: fixture.date(20),
                completeness: .complete
            ),
            watchedRepository: fixture.watch,
            existingRecords: []
        )
        try executeSQLite(
            """
            CREATE TRIGGER fail_attention_cache
            BEFORE INSERT ON forge_cache_entries
            BEGIN
                SELECT RAISE(ABORT, 'forced attention cache failure');
            END
            """,
            at: sqliteFixture.configuration.databaseURL
        )

        await XCTAssertThrowsErrorAsync {
            try await persistence.persist(reconciliation)
        }
        let watchAfterFailure = try await persistence.watchedRepositories(accountID: fixture.accountID).first
        let recordsAfterFailure = try await persistence.records(
            accountID: fixture.accountID,
            repository: fixture.repository,
            at: fixture.date(21)
        )
        XCTAssertNil(watchAfterFailure?.baselineEstablishedAt)
        XCTAssertNil(watchAfterFailure?.lastSuccessfulPollAt)
        XCTAssertTrue(recordsAfterFailure.isEmpty)
        XCTAssertEqual(
            try sqliteScalar("SELECT COUNT(*) FROM forge_cache_entries", at: sqliteFixture.configuration.databaseURL),
            0
        )
    }

    func testCoordinatorManualRefreshAttemptsEveryWatchPersistsLaterSuccessAndThrowsFirstFailure() async throws {
        let fixture = try Fixture()
        let secondRepository = try TestSupport.repository(owner: "z-second")
        let secondKey = try ForgeWatchedRepositoryKey(accountID: fixture.accountID, repository: secondRepository)
        let secondWatch = ForgeWatchedRepository(
            key: secondKey,
            addedAt: fixture.date(0),
            source: .preferences
        )
        let persistence = try ForgeSQLiteAttentionPersistence(
            store: ForgeSQLiteStore(configuration: SQLiteFixture().configuration)
        )
        try await persistence.save(fixture.watch)
        try await persistence.save(secondWatch)
        let fetcher = KeyedSnapshotFetcher(viewer: fixture.viewer, failing: fixture.watch.key)
        let coordinator = ForgeAttentionInboxCoordinator(
            persistence: persistence,
            fetcher: fetcher,
            alertDelivery: AlertDelivery(authorization: .denied, requestResult: false)
        )

        do {
            _ = try await coordinator.refreshAllWatched(accountID: fixture.accountID)
            XCTFail("Expected the first repository failure after every watch was attempted")
        } catch KeyedSnapshotFetcher.Failure.expected {}

        let requestedKeys = await fetcher.requestedKeys
        XCTAssertEqual(requestedKeys, [fixture.watch.key, secondKey])
        let persistedWatches = try await persistence.watchedRepositories(accountID: fixture.accountID)
        XCTAssertNil(persistedWatches.first(where: { $0.key == fixture.watch.key })?.lastSuccessfulPollAt)
        XCTAssertEqual(
            persistedWatches.first(where: { $0.key == secondKey })?.lastSuccessfulPollAt,
            fixture.date(0)
        )
    }

    func testCoordinatorManualRefreshPropagatesCancellationWithoutAttemptingLaterWatches() async throws {
        let fixture = try Fixture()
        let secondRepository = try TestSupport.repository(owner: "z-second")
        let secondKey = try ForgeWatchedRepositoryKey(accountID: fixture.accountID, repository: secondRepository)
        let persistence = try ForgeSQLiteAttentionPersistence(
            store: ForgeSQLiteStore(configuration: SQLiteFixture().configuration)
        )
        try await persistence.save(fixture.watch)
        try await persistence.save(ForgeWatchedRepository(
            key: secondKey,
            addedAt: fixture.date(0),
            source: .preferences
        ))
        let fetcher = CancellingSnapshotFetcher()
        let coordinator = ForgeAttentionInboxCoordinator(
            persistence: persistence,
            fetcher: fetcher,
            alertDelivery: AlertDelivery(authorization: .denied, requestResult: false)
        )

        do {
            _ = try await coordinator.refreshAllWatched(accountID: fixture.accountID)
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch {
            XCTFail("Expected CancellationError, received \(type(of: error))")
        }

        let requestedKeys = await fetcher.requestedKeys
        XCTAssertEqual(requestedKeys, [fixture.watch.key])
    }

    func testCoordinatorManualRefreshReturnsEmptyWithoutFetchingWhenAccountHasNoWatches() async throws {
        let fixture = try Fixture()
        let persistence = try ForgeSQLiteAttentionPersistence(
            store: ForgeSQLiteStore(configuration: SQLiteFixture().configuration)
        )
        let fetcher = SnapshotFetcher(snapshots: [])
        let coordinator = ForgeAttentionInboxCoordinator(
            persistence: persistence,
            fetcher: fetcher,
            alertDelivery: AlertDelivery(authorization: .denied, requestResult: false)
        )

        let reconciliations = try await coordinator.refreshAllWatched(accountID: fixture.accountID)

        XCTAssertTrue(reconciliations.isEmpty)
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testCoordinatorSuppressesUnauthorizedTransitionsAndHandlesMissingOrManualTargets() async throws {
        let fixture = try Fixture()
        let establishedWatch = ForgeWatchedRepository(
            key: fixture.watch.key,
            addedAt: fixture.watch.addedAt,
            source: fixture.watch.source,
            baselineEstablishedAt: fixture.date(1),
            lastSuccessfulPollAt: fixture.date(1)
        )
        let persistence = try ForgeSQLiteAttentionPersistence(
            store: ForgeSQLiteStore(configuration: SQLiteFixture().configuration)
        )
        try await persistence.save(establishedWatch)
        let candidate = try fixture.issueCandidate(assignees: [fixture.viewer])
        let alerts = AlertDelivery(authorization: .denied, requestResult: false)
        let coordinator = ForgeAttentionInboxCoordinator(
            persistence: persistence,
            fetcher: SnapshotFetcher(snapshots: [ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: fixture.watch.key,
                viewer: fixture.viewer,
                candidates: [candidate],
                fetchedAt: fixture.date(2),
                completeness: .complete
            )]),
            alertDelivery: alerts,
            enabledAlertCategories: [.assignments],
            pollingPreset: .manual
        )

        let transition = try await coordinator.refresh(fixture.watch.key)
        XCTAssertEqual(transition.newlyActionable.map(\.id.kind), [.assignment])
        let delivered = await alerts.delivered
        XCTAssertTrue(delivered.isEmpty)
        let manualRefresh = try await coordinator.refreshNextDue(
            accountID: fixture.accountID,
            activeOrOpenRepositories: [],
            at: fixture.date(100)
        )
        XCTAssertNil(manualRefresh)

        try await persistence.removeWatchedRepository(fixture.watch.key)
        do {
            _ = try await coordinator.refresh(fixture.watch.key)
            XCTFail("Expected a missing watched repository")
        } catch {
            XCTAssertEqual(error as? ForgeAttentionInboxError, .missingWatchedRepository)
        }
    }

    private func reconcile(
        fixture: Fixture,
        candidate: ForgeAttentionCandidate,
        watch: ForgeWatchedRepository,
        at time: TimeInterval
    ) throws -> ForgeAttentionReconciliation {
        try ForgeAttentionReconciler.reconcile(
            ForgeAttentionRepositorySnapshot(
                watchedRepositoryKey: watch.key,
                viewer: fixture.viewer,
                candidates: [candidate],
                fetchedAt: fixture.date(time),
                completeness: .complete
            ),
            watchedRepository: watch,
            existingRecords: []
        )
    }
}

private struct Fixture {
    let repository: ForgeRepositoryIdentity
    let accountID: ForgeAccountID
    let viewer: ForgeActor
    let other: ForgeActor
    let bot: ForgeActor
    let watch: ForgeWatchedRepository

    init() throws {
        repository = try TestSupport.repository()
        accountID = try ForgeAccountID(forge: repository.forge, value: "account")
        viewer = try Self.actor(repository: repository, id: "viewer", login: "viewer", kind: .person)
        other = try Self.actor(repository: repository, id: "other", login: "other", kind: .person)
        bot = try Self.actor(repository: repository, id: "bot", login: "dependabot", kind: .bot)
        watch = try ForgeWatchedRepository(
            key: ForgeWatchedRepositoryKey(accountID: accountID, repository: repository),
            addedAt: Date(timeIntervalSince1970: 0),
            source: .repositoryOpened
        )
    }

    func pullRequestCandidate(
        repository: ForgeRepositoryIdentity? = nil,
        subject: String = "pull-request",
        assignees: [ForgeActor] = [],
        participants: [ForgeActor] = [],
        requestedReviewers: [ForgeReviewParticipant] = [],
        body: String = "",
        comments: [ForgeAttentionActivity] = [],
        reviewComments: [ForgeReviewComment] = [],
        checkRollup: ForgeCheckRollup = .succeeded,
        author: ForgeActor? = nil,
        checkRollupAvailable: Bool = true,
        reviewersAvailable: Bool = true,
        threadCommentsAvailable: Bool = true
    ) throws -> ForgeAttentionCandidate {
        let repository = repository ?? self.repository
        let summary = try ForgePullRequestSummary(
            repository: repository,
            number: ForgeItemNumber(7),
            state: .open,
            isDraft: false,
            title: "Attention subject",
            author: .available(.actor(author ?? other)),
            head: .unavailable(.notRequested),
            base: .unavailable(.notRequested),
            createdAt: date(1),
            updatedAt: date(15),
            labels: .available([]),
            checkRollup: checkRollupAvailable ? .available(checkRollup) : .unavailable(.partialResponse),
            reviewRollup: .available(.reviewRequired)
        )
        let threads: [ForgeReviewThread]
        if reviewComments.isEmpty {
            threads = []
        } else {
            threads = try [ForgeReviewThread(
                repository: repository,
                id: ForgeObjectID(forge: repository.forge, value: "thread"),
                isResolved: false,
                isOutdated: false,
                anchor: .unavailable(.notRequested),
                comments: threadCommentsAvailable
                    ? .available(ForgePage(items: reviewComments))
                    : .unavailable(.partialResponse)
            )]
        }
        return try ForgeAttentionCandidate(
            subjectID: ForgeAttentionSubjectID(subject),
            item: .pullRequest(summary),
            bodyMarkdown: .available(body),
            assignees: .available(assignees),
            participants: .available(participants),
            requestedReviewers: reviewersAvailable
                ? .available(requestedReviewers)
                : .unavailable(.partialResponse),
            activities: .available(comments),
            reviewThreads: .available(threads)
        )
    }

    func issueCandidate(
        subject: String = "issue",
        assignees: [ForgeActor] = [],
        participants: [ForgeActor] = [],
        body: String = "",
        comments: [ForgeAttentionActivity] = [],
        author: ForgeActor? = nil
    ) throws -> ForgeAttentionCandidate {
        let summary = try ForgeIssueSummary(
            repository: repository,
            number: ForgeItemNumber(9),
            state: .open,
            title: "Issue subject",
            author: .available(.actor(author ?? other)),
            createdAt: date(1),
            updatedAt: date(15),
            labels: .available([])
        )
        return try ForgeAttentionCandidate(
            subjectID: ForgeAttentionSubjectID(subject),
            item: .issue(summary),
            bodyMarkdown: .available(body),
            assignees: .available(assignees),
            participants: .available(participants),
            requestedReviewers: .available([]),
            activities: .available(comments),
            reviewThreads: .available([])
        )
    }

    func activity(
        id: String,
        author: ForgeActor,
        body: String,
        at time: TimeInterval,
        kind: ForgeAttentionActivityKind = .conversationComment
    ) -> ForgeAttentionActivity {
        try! ForgeAttentionActivity(
            id: ForgeObjectID(forge: repository.forge, value: id),
            kind: kind,
            author: .available(.actor(author)),
            bodyMarkdown: body,
            occurredAt: date(time)
        )
    }

    func reviewComment(
        id: String,
        author: ForgeActor,
        body: String,
        at time: TimeInterval,
        replyTo: String? = nil
    ) throws -> ForgeReviewComment {
        try ForgeReviewComment(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: id),
            bodyMarkdown: body,
            createdAt: date(time),
            updatedAt: date(time),
            author: .available(.actor(author)),
            replyToID: replyTo.map { try ForgeObjectID(forge: repository.forge, value: $0) }
        )
    }

    func record(
        repository: ForgeRepositoryIdentity? = nil,
        kind: ForgeAttentionKind,
        subject: String,
        at time: TimeInterval,
        seenAt: TimeInterval? = nil
    ) throws -> ForgeAttentionRecord {
        let repository = repository ?? self.repository
        let id = try ForgeAttentionItemID(
            accountID: accountID,
            repository: repository,
            kind: kind,
            subjectID: ForgeAttentionSubjectID(subject)
        )
        var item = try ForgeAttentionItem(
            id: id,
            destination: .pullRequest(repository, ForgeItemNumber(1)),
            authoredPullRequestFailedCheck: kind == .failedCheck,
            becameActionableAt: date(time)
        )
        if let seenAt {
            item = try item.markingSeen(at: date(seenAt))
        }
        return try ForgeAttentionRecord(
            item: item,
            sourceIdentifier: ForgeAttentionSubjectID("source-\(subject)"),
            sourceOccurredAt: date(time)
        )
    }

    func entry(
        repository: ForgeRepositoryIdentity? = nil,
        kind: ForgeAttentionKind,
        subject: String,
        at time: TimeInterval,
        seenAt: TimeInterval? = nil
    ) throws -> ForgeAttentionInboxEntry {
        let repository = repository ?? self.repository
        let record = try record(
            repository: repository,
            kind: kind,
            subject: subject,
            at: time,
            seenAt: seenAt
        )
        let summary = try ForgePullRequestSummary(
            repository: repository,
            number: ForgeItemNumber(1),
            state: .open,
            isDraft: false,
            title: subject,
            author: .available(.actor(other)),
            head: .unavailable(.notRequested),
            base: .unavailable(.notRequested),
            createdAt: date(0),
            updatedAt: date(time),
            labels: .available([]),
            checkRollup: .unavailable(.notRequested),
            reviewRollup: .unavailable(.notRequested)
        )
        return try ForgeAttentionInboxEntry(record: record, subject: .pullRequest(summary))
    }

    func date(_ time: TimeInterval) -> Date {
        Date(timeIntervalSince1970: time)
    }

    private static func actor(
        repository: ForgeRepositoryIdentity,
        id: String,
        login: String,
        kind: ForgeActorKind
    ) throws -> ForgeActor {
        try ForgeActor(
            id: ForgeObjectID(forge: repository.forge, value: id),
            login: login,
            kind: kind
        )
    }
}

private struct SQLiteFixture {
    let root: URL
    let configuration: ForgeSQLiteConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeAttentionInboxTests-\(UUID().uuidString)", isDirectory: true)
        configuration = ForgeSQLiteConfiguration(
            databaseURL: root.appendingPathComponent("Forge.sqlite3"),
            recoveryDirectoryURL: root.appendingPathComponent("Recovery", isDirectory: true)
        )
    }
}

private actor SnapshotFetcher: ForgeAttentionSnapshotFetching {
    enum Failure: Error {
        case exhausted
    }

    private var snapshots: [ForgeAttentionRepositorySnapshot]
    private(set) var requestCount = 0

    init(snapshots: [ForgeAttentionRepositorySnapshot]) {
        self.snapshots = snapshots
    }

    func snapshot(for _: ForgeWatchedRepository) async throws -> ForgeAttentionRepositorySnapshot {
        requestCount += 1
        guard !snapshots.isEmpty else { throw Failure.exhausted }
        return snapshots.removeFirst()
    }
}

private actor GatedSnapshotFetcher: ForgeAttentionSnapshotFetching {
    private enum Failure: Error {
        case requestTimedOut
    }

    private let value: ForgeAttentionRepositorySnapshot
    private var requested = false
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(snapshot: ForgeAttentionRepositorySnapshot) {
        value = snapshot
    }

    func snapshot(for _: ForgeWatchedRepository) async throws -> ForgeAttentionRepositorySnapshot {
        requested = true
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return value
    }

    func waitUntilRequested() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !requested {
            guard clock.now < deadline else {
                release()
                throw Failure.requestTimedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor CancellingSnapshotFetcher: ForgeAttentionSnapshotFetching {
    private(set) var requestedKeys: [ForgeWatchedRepositoryKey] = []

    func snapshot(for watch: ForgeWatchedRepository) async throws -> ForgeAttentionRepositorySnapshot {
        requestedKeys.append(watch.key)
        throw CancellationError()
    }
}

private actor KeyedSnapshotFetcher: ForgeAttentionSnapshotFetching {
    enum Failure: Error {
        case expected
    }

    let viewer: ForgeActor
    let failing: ForgeWatchedRepositoryKey
    private(set) var requestedKeys: [ForgeWatchedRepositoryKey] = []

    init(viewer: ForgeActor, failing: ForgeWatchedRepositoryKey) {
        self.viewer = viewer
        self.failing = failing
    }

    func snapshot(for watch: ForgeWatchedRepository) async throws -> ForgeAttentionRepositorySnapshot {
        requestedKeys.append(watch.key)
        if watch.key == failing {
            throw Failure.expected
        }
        return ForgeAttentionRepositorySnapshot(
            watchedRepositoryKey: watch.key,
            viewer: viewer,
            candidates: [],
            fetchedAt: Date(timeIntervalSince1970: 0),
            completeness: .complete
        )
    }
}

private actor AlertDelivery: ForgeAttentionAlertDelivering {
    private var authorization: ForgeAttentionSystemAuthorization
    private let requestResult: Bool
    private(set) var requestCount = 0
    private(set) var delivered: [ForgeAttentionAlert] = []

    init(authorization: ForgeAttentionSystemAuthorization, requestResult: Bool) {
        self.authorization = authorization
        self.requestResult = requestResult
    }

    func authorizationStatus() async -> ForgeAttentionSystemAuthorization {
        authorization
    }

    func requestAuthorization() async -> Bool {
        requestCount += 1
        authorization = requestResult ? .authorized : .denied
        return requestResult
    }

    func deliver(_ alert: ForgeAttentionAlert) async {
        delivered.append(alert)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}

private func executeSQLite(_ sql: String, at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw SQLiteTestError.open
    }
    defer { sqlite3_close(database) }
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    defer { sqlite3_free(message) }
    guard result == SQLITE_OK else {
        throw SQLiteTestError.execute(message.map { String(cString: $0) } ?? "SQLite error \(result)")
    }
}

private func sqliteScalar(_ sql: String, at url: URL) throws -> Int64 {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw SQLiteTestError.open
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw SQLiteTestError.prepare
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw SQLiteTestError.step
    }
    return sqlite3_column_int64(statement, 0)
}

private enum SQLiteTestError: Error {
    case open
    case execute(String)
    case prepare
    case step
}
