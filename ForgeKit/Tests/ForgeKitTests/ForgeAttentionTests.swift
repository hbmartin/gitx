@testable import ForgeKit
import Foundation
import XCTest

final class ForgeAttentionTests: XCTestCase {
    func testAcceptedAttentionDefaultsAreExact() throws {
        let policy = ForgeAttentionPolicy.defaultValue
        XCTAssertTrue(policy.includesFailedChecksOnAuthoredPullRequests)
        XCTAssertFalse(policy.includesFailedChecksAwaitingReview)
        let accountID = try makeWatch().key.accountID
        XCTAssertEqual(ForgeAttentionQuery(scope: .all(accountID: accountID)).visibility, .unseenOnly)
    }

    func testDerivationCoversCurrentActionableStatesWithoutNotificationOrQueueSemantics() throws {
        XCTAssertEqual(try derive(.reviewRequested), .init(kind: .reviewRequest))
        XCTAssertEqual(try derive(.mention(actorIsAccount: false)), .init(kind: .mention))
        XCTAssertNil(try derive(.mention(actorIsAccount: true)))
        XCTAssertEqual(
            try derive(.reply(actorIsAccount: false, actorIsBot: false, accountParticipated: true)),
            .init(kind: .reply)
        )
        XCTAssertNil(try derive(.reply(actorIsAccount: true, actorIsBot: false, accountParticipated: true)))
        XCTAssertNil(try derive(.reply(actorIsAccount: false, actorIsBot: false, accountParticipated: false)))
        XCTAssertNil(try derive(.reply(actorIsAccount: false, actorIsBot: true, accountParticipated: true)))
        XCTAssertEqual(try derive(.assigned), .init(kind: .assignment))
        XCTAssertEqual(
            try derive(.checkFailed(authoredByAccount: true, awaitingAccountReview: false)),
            .init(kind: .failedCheck, authoredPullRequestFailedCheck: true)
        )
        XCTAssertNil(try derive(.checkFailed(authoredByAccount: false, awaitingAccountReview: true)))
        XCTAssertEqual(
            try derive(
                .checkFailed(authoredByAccount: false, awaitingAccountReview: true),
                policy: ForgeAttentionPolicy(includesFailedChecksAwaitingReview: true)
            ),
            .init(kind: .failedCheck)
        )
        XCTAssertNil(try derive(.checkFailed(authoredByAccount: false, awaitingAccountReview: false)))
        XCTAssertNil(try derive(.mergeQueueTransition))
    }

    func testBotReplyEligibilityComesFromTheExactWatchedRepository() throws {
        let repository = try TestSupport.repository(owner: "account")
        let otherRepository = try TestSupport.repository(owner: "opposite")
        let deniedWatch = try makeWatch(repository: repository, account: "denied", includesBotReplies: false)
        let otherAccountWatch = try makeWatch(repository: repository, account: "allowed", includesBotReplies: true)
        let otherRepositoryWatch = try makeWatch(
            repository: otherRepository,
            account: "denied",
            includesBotReplies: true
        )
        let event = ForgeAttentionSignal.Event.reply(
            actorIsAccount: false,
            actorIsBot: true,
            accountParticipated: true
        )
        let deniedSignal = ForgeAttentionSignal(
            watchedRepositoryKey: deniedWatch.key,
            event: event
        )

        XCTAssertNil(ForgeAttentionDerivationPolicy.derive(deniedSignal, watchedRepository: deniedWatch))
        XCTAssertNil(ForgeAttentionDerivationPolicy.derive(deniedSignal, watchedRepository: otherAccountWatch))
        XCTAssertNil(ForgeAttentionDerivationPolicy.derive(deniedSignal, watchedRepository: otherRepositoryWatch))
        let allowedSignal = ForgeAttentionSignal(
            watchedRepositoryKey: otherRepositoryWatch.key,
            event: event
        )
        XCTAssertEqual(
            ForgeAttentionDerivationPolicy.derive(allowedSignal, watchedRepository: otherRepositoryWatch),
            .init(kind: .reply)
        )
        XCTAssertFalse(deniedWatch.includesBotReplies)
        XCTAssertTrue(otherAccountWatch.includesBotReplies)
        XCTAssertTrue(otherRepositoryWatch.includesBotReplies)
    }

    func testWatchAndItemKeysAreExactToAccountRepositoryKindAndSubject() throws {
        let context = try makeContext()
        let otherAccount = try ForgeAccountID(forge: context.repository.forge, value: "other")
        let otherRepository = try TestSupport.repository(owner: "other")
        let otherSubject = try ForgeAttentionSubjectID("subject-2")
        let keys = try Set([
            context.id,
            ForgeAttentionItemID(
                accountID: otherAccount,
                repository: context.repository,
                kind: .mention,
                subjectID: context.subject
            ),
            ForgeAttentionItemID(
                accountID: context.accountID,
                repository: otherRepository,
                kind: .mention,
                subjectID: context.subject
            ),
            ForgeAttentionItemID(
                accountID: context.accountID,
                repository: context.repository,
                kind: .reply,
                subjectID: context.subject
            ),
            ForgeAttentionItemID(
                accountID: context.accountID,
                repository: context.repository,
                kind: .mention,
                subjectID: otherSubject
            ),
        ])
        XCTAssertEqual(keys.count, 5)

        let watch = try ForgeWatchedRepositoryKey(accountID: context.accountID, repository: context.repository)
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeWatchedRepositoryKey.self, from: JSONEncoder().encode(watch)),
            watch
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeAttentionItemID.self, from: JSONEncoder().encode(context.id)),
            context.id
        )
    }

    func testAttentionIdentitiesRejectCrossForgeAndInvalidSubjectValues() throws {
        let context = try makeContext()
        let gitLabRepository = try TestSupport.repository(kind: .gitLab)
        XCTAssertThrowsError(
            try ForgeWatchedRepositoryKey(accountID: context.accountID, repository: gitLabRepository)
        ) {
            XCTAssertEqual($0 as? ForgeAttentionError, .mismatchedAccountForge)
        }
        XCTAssertThrowsError(
            try ForgeAttentionItemID(
                accountID: context.accountID,
                repository: gitLabRepository,
                kind: .mention,
                subjectID: context.subject
            )
        ) {
            XCTAssertEqual($0 as? ForgeAttentionError, .mismatchedAccountForge)
        }
        for value in ["", " ", "\n"] {
            XCTAssertThrowsError(try ForgeAttentionSubjectID(value)) {
                XCTAssertEqual($0 as? ForgeAttentionError, .invalidSubjectIdentifier)
            }
        }

        let otherRepository = try TestSupport.repository(owner: "other")
        XCTAssertThrowsError(
            try ForgeAttentionItem(
                id: context.id,
                destination: .pullRequest(otherRepository, ForgeItemNumber(1)),
                becameActionableAt: .distantPast
            )
        ) {
            XCTAssertEqual($0 as? ForgeAttentionError, .mismatchedDestinationRepository)
        }
        XCTAssertThrowsError(
            try ForgeAttentionItem(
                id: context.id,
                destination: .pullRequest(context.repository, ForgeItemNumber(1)),
                authoredPullRequestFailedCheck: true,
                becameActionableAt: .distantPast
            )
        ) {
            XCTAssertEqual($0 as? ForgeAttentionError, .invalidFailedCheckContext)
        }
    }

    func testOpeningSeenUnseenResolveAndReactivateTransitions() throws {
        let item = try makeItem(time: 10)
        XCTAssertEqual(item.state, .active)
        XCTAssertEqual(item.seenState, .unseen)
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeAttentionItem.self, from: JSONEncoder().encode(item)),
            item
        )

        let seen = try item.opening(at: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(seen.seenState, .seen(at: Date(timeIntervalSince1970: 20)))
        XCTAssertEqual(
            try seen.markingUnseen(at: Date(timeIntervalSince1970: 25)).seenState,
            .unseen
        )

        let resolved = try seen.resolving(at: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(resolved.state, .resolved)
        XCTAssertEqual(resolved.lastTransitionAt, Date(timeIntervalSince1970: 30))
        let stillResolved = try resolved.resolving(at: Date(timeIntervalSince1970: 40))
        XCTAssertEqual(stillResolved.state, .resolved)
        XCTAssertEqual(stillResolved.lastUpdatedAt, Date(timeIntervalSince1970: 40))

        let reactivated = try stillResolved.reactivating(at: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(reactivated.state, .active)
        XCTAssertEqual(reactivated.seenState, .unseen)
        XCTAssertEqual(reactivated.lastTransitionAt, Date(timeIntervalSince1970: 50))
        let stillActive = try reactivated.reactivating(at: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(stillActive.state, .active)
        XCTAssertEqual(stillActive.lastUpdatedAt, Date(timeIntervalSince1970: 60))
    }

    func testAttentionRejectsEveryStaleTransition() throws {
        let item = try makeItem(time: 10)
        for operation in [
            { try item.markingSeen(at: Date(timeIntervalSince1970: 9)) },
            { try item.markingUnseen(at: Date(timeIntervalSince1970: 9)) },
            { try item.resolving(at: Date(timeIntervalSince1970: 9)) },
            { try item.reactivating(at: Date(timeIntervalSince1970: 9)) },
        ] {
            XCTAssertThrowsError(try operation()) {
                XCTAssertEqual($0 as? ForgeAttentionError, .staleTransition)
            }
        }
    }

    func testAttentionDecodingRejectsInvalidTimestampOrders() throws {
        struct UnvalidatedItem: Encodable {
            let id: ForgeAttentionItemID
            let destination: ForgeDestination
            let state: ForgeAttentionItemState
            let seenState: ForgeAttentionSeenState
            let authoredPullRequestFailedCheck: Bool
            let firstBecameActionableAt: Date
            let lastTransitionAt: Date
            let lastUpdatedAt: Date
        }

        let item = try makeItem(time: 10)
        let otherRepository = try TestSupport.repository(owner: "other")
        let itemNumber = try ForgeItemNumber(1)
        let invalidContextValues = [
            UnvalidatedItem(
                id: item.id,
                destination: .pullRequest(otherRepository, itemNumber),
                state: .active,
                seenState: .unseen,
                authoredPullRequestFailedCheck: false,
                firstBecameActionableAt: item.firstBecameActionableAt,
                lastTransitionAt: item.lastTransitionAt,
                lastUpdatedAt: item.lastUpdatedAt
            ),
            UnvalidatedItem(
                id: item.id,
                destination: item.destination,
                state: .active,
                seenState: .unseen,
                authoredPullRequestFailedCheck: true,
                firstBecameActionableAt: item.firstBecameActionableAt,
                lastTransitionAt: item.lastTransitionAt,
                lastUpdatedAt: item.lastUpdatedAt
            ),
        ]
        let expectedErrors: [ForgeAttentionError] = [
            .mismatchedDestinationRepository,
            .invalidFailedCheckContext,
        ]
        for (value, expectedError) in zip(invalidContextValues, expectedErrors) {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    ForgeAttentionItem.self,
                    from: JSONEncoder().encode(value)
                )
            ) {
                XCTAssertEqual($0 as? ForgeAttentionError, expectedError)
            }
        }

        let invalidValues = [
            UnvalidatedItem(
                id: item.id,
                destination: item.destination,
                state: .active,
                seenState: .unseen,
                authoredPullRequestFailedCheck: false,
                firstBecameActionableAt: Date(timeIntervalSince1970: 20),
                lastTransitionAt: Date(timeIntervalSince1970: 10),
                lastUpdatedAt: Date(timeIntervalSince1970: 30)
            ),
            UnvalidatedItem(
                id: item.id,
                destination: item.destination,
                state: .active,
                seenState: .unseen,
                authoredPullRequestFailedCheck: false,
                firstBecameActionableAt: Date(timeIntervalSince1970: 10),
                lastTransitionAt: Date(timeIntervalSince1970: 30),
                lastUpdatedAt: Date(timeIntervalSince1970: 20)
            ),
            UnvalidatedItem(
                id: item.id,
                destination: item.destination,
                state: .active,
                seenState: .seen(at: Date(timeIntervalSince1970: 40)),
                authoredPullRequestFailedCheck: false,
                firstBecameActionableAt: Date(timeIntervalSince1970: 10),
                lastTransitionAt: Date(timeIntervalSince1970: 20),
                lastUpdatedAt: Date(timeIntervalSince1970: 30)
            ),
        ]
        for value in invalidValues {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    ForgeAttentionItem.self,
                    from: JSONEncoder().encode(value)
                )
            ) {
                XCTAssertEqual($0 as? ForgeAttentionError, .invalidTimestampOrder)
            }
        }
    }

    func testAttentionErrorsHaveSafeDescriptions() {
        for error in [
            ForgeAttentionError.invalidSubjectIdentifier,
            .mismatchedAccountForge,
            .mismatchedDestinationRepository,
            .invalidFailedCheckContext,
            .invalidTimestampOrder,
            .staleTransition,
        ] {
            XCTAssertNotNil(error.errorDescription)
        }
    }

    func testOnlySeenActiveOrResolvedItemsExpire() throws {
        let base = try makeItem(time: 0)
        let expiry = ForgePolicyConstants.durableRecordExpiration
        XCTAssertFalse(base.isExpired(at: Date(timeIntervalSince1970: expiry * 2)))

        let seen = try base.markingSeen(at: Date(timeIntervalSince1970: 10))
        XCTAssertFalse(seen.isExpired(at: Date(timeIntervalSince1970: 10 + expiry - 0.001)))
        XCTAssertTrue(seen.isExpired(at: Date(timeIntervalSince1970: 10 + expiry)))

        let resolved = try base.resolving(at: Date(timeIntervalSince1970: 20))
        XCTAssertFalse(resolved.isExpired(at: Date(timeIntervalSince1970: 20 + expiry - 0.001)))
        XCTAssertTrue(resolved.isExpired(at: Date(timeIntervalSince1970: 20 + expiry)))
    }

    func testDefaultQueryIsCurrentStateUnseenNewestAndMarkAllSeenIsScoped() throws {
        let current = try TestSupport.repository(owner: "current")
        let other = try TestSupport.repository(owner: "other")
        let newest = try makeItem(repository: current, subject: "newest", time: 30)
        let older = try makeItem(repository: current, subject: "older", time: 20)
        let seen = try makeItem(repository: current, subject: "seen", time: 40)
            .markingSeen(at: Date(timeIntervalSince1970: 50))
        let resolved = try makeItem(repository: current, subject: "resolved", time: 10)
            .resolving(at: Date(timeIntervalSince1970: 15))
        let outside = try makeItem(repository: other, subject: "outside", time: 60)
        let otherAccount = try makeItem(
            repository: current,
            account: "other-account",
            subject: "other-account",
            time: 70
        )
        let items = [older, seen, resolved, outside, otherAccount, newest]
        let currentKey = try ForgeWatchedRepositoryKey(accountID: newest.id.accountID, repository: current)
        let query = ForgeAttentionQuery(scope: .currentRepository(currentKey))

        XCTAssertEqual(query.applying(to: items).map(\.id.subjectID.value), ["newest", "older"])
        XCTAssertEqual(
            ForgeAttentionQuery(scope: .currentRepository(currentKey), visibility: .active)
                .applying(to: items).map(\.id.subjectID.value),
            ["seen", "newest", "older"]
        )
        let allQuery = ForgeAttentionQuery(scope: .currentRepository(currentKey), visibility: .all)
        XCTAssertEqual(allQuery.applying(to: items).count, 3)
        let accountQuery = ForgeAttentionQuery(scope: .all(accountID: newest.id.accountID), visibility: .all)
        XCTAssertFalse(
            accountQuery.applying(to: items).contains { $0.id == resolved.id || $0.id == otherAccount.id }
        )
        let marked = try allQuery.markingAllSeen(items, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(
            Set(marked.filter { $0.seenState == .seen(at: Date(timeIntervalSince1970: 100)) }.map(\.id)),
            Set([newest.id, older.id, seen.id])
        )
        XCTAssertEqual(try XCTUnwrap(marked.first { $0.id == resolved.id }).seenState, .unseen)
        XCTAssertEqual(try XCTUnwrap(marked.first { $0.id == outside.id }).seenState, .unseen)
        XCTAssertEqual(try XCTUnwrap(marked.first { $0.id == otherAccount.id }).seenState, .unseen)

        let accountMarked = try accountQuery.markingAllSeen(items, at: Date(timeIntervalSince1970: 110))
        XCTAssertEqual(
            Set(accountMarked.filter { $0.seenState == .seen(at: Date(timeIntervalSince1970: 110)) }.map(\.id)),
            Set([newest.id, older.id, seen.id, outside.id])
        )
        XCTAssertEqual(try XCTUnwrap(accountMarked.first { $0.id == otherAccount.id }).seenState, .unseen)

        let tiedB = try makeItem(repository: current, subject: "b", time: 70)
        let tiedA = try makeItem(repository: current, subject: "a", time: 70)
        XCTAssertEqual(
            ForgeAttentionQuery(scope: .all(accountID: tiedA.id.accountID), visibility: .all)
                .applying(to: [tiedB, tiedA]).map(\.id.subjectID.value),
            ["a", "b"]
        )
    }

    func testAlertsRequireRunningTransitionPermissionAndOptInButNotFirstBaseline() throws {
        let item = try makeItem(kind: .mention)
        let enabled: Set<ForgeAttentionAlertCategory> = [.mentionsAndReplies]
        XCTAssertEqual(
            ForgeAttentionAlertPolicy.decision(
                forNewlyActionable: item,
                baselineAlreadyEstablished: true,
                applicationIsRunning: true,
                enabledCategories: enabled,
                systemPermissionGranted: true
            ),
            .deliver(category: .mentionsAndReplies, actions: [.open, .markSeen])
        )
        XCTAssertEqual(alertDecision(item, baseline: false, running: true, enabled: enabled, permission: true), .suppressed)
        XCTAssertEqual(alertDecision(item, baseline: true, running: false, enabled: enabled, permission: true), .suppressed)
        XCTAssertEqual(alertDecision(item, baseline: true, running: true, enabled: [], permission: true), .suppressed)
        XCTAssertEqual(alertDecision(item, baseline: true, running: true, enabled: enabled, permission: false), .suppressed)
    }

    func testAlertCategoriesAreExactAndAwaitingReviewCheckDoesNotAlert() throws {
        XCTAssertEqual(try ForgeAttentionAlertPolicy.category(for: makeItem(kind: .reviewRequest)), .reviewRequests)
        XCTAssertEqual(try ForgeAttentionAlertPolicy.category(for: makeItem(kind: .mention)), .mentionsAndReplies)
        XCTAssertEqual(try ForgeAttentionAlertPolicy.category(for: makeItem(kind: .reply)), .mentionsAndReplies)
        XCTAssertEqual(try ForgeAttentionAlertPolicy.category(for: makeItem(kind: .assignment)), .assignments)
        XCTAssertEqual(
            try ForgeAttentionAlertPolicy.category(for: makeItem(kind: .failedCheck, authoredCheck: true)),
            .failedChecksOnAuthoredPullRequests
        )
        XCTAssertNil(try ForgeAttentionAlertPolicy.category(for: makeItem(kind: .failedCheck, authoredCheck: false)))
        XCTAssertEqual(Set(ForgeAttentionAlertAction.allCases), [.open, .markSeen])
        XCTAssertTrue(
            ForgeAttentionAlertPolicy.shouldRequestSystemPermission(
                previous: [],
                updated: [.reviewRequests]
            )
        )
        XCTAssertFalse(
            ForgeAttentionAlertPolicy.shouldRequestSystemPermission(
                previous: [.reviewRequests],
                updated: [.reviewRequests, .assignments]
            )
        )
        XCTAssertFalse(ForgeAttentionAlertPolicy.shouldRequestSystemPermission(previous: [], updated: []))
    }

    func testRoundRobinPollingIsDeterministicFairAndHasNoHardCap() throws {
        let repository = try TestSupport.repository()
        let watches = try (0 ..< 100).map { index -> ForgeWatchedRepository in
            let account = try ForgeAccountID(forge: repository.forge, value: "account-\(index)")
            return try ForgeWatchedRepository(
                key: ForgeWatchedRepositoryKey(accountID: account, repository: repository),
                addedAt: Date(timeIntervalSince1970: Double(index)),
                source: .preferences
            )
        }
        var cursor = ForgeAttentionPollingCursor()
        var visited: Set<ForgeWatchedRepositoryKey> = []
        for _ in watches.indices {
            let next = try XCTUnwrap(cursor.next(in: watches))
            XCTAssertTrue(visited.insert(next.key).inserted)
            cursor = ForgeAttentionPollingCursor(lastPolled: next.key)
        }
        XCTAssertEqual(visited.count, watches.count)
        XCTAssertEqual(cursor.next(in: watches)?.key, ForgeAttentionPollingCursor().next(in: watches)?.key)
        XCTAssertNil(ForgeAttentionPollingCursor().next(in: []))
    }

    private struct Context {
        let repository: ForgeRepositoryIdentity
        let accountID: ForgeAccountID
        let subject: ForgeAttentionSubjectID
        let id: ForgeAttentionItemID
    }

    private func makeContext(
        repository: ForgeRepositoryIdentity? = nil,
        account: String = "account",
        kind: ForgeAttentionKind = .mention,
        subject: String = "subject"
    ) throws -> Context {
        let repository = try repository ?? TestSupport.repository()
        let accountID = try ForgeAccountID(forge: repository.forge, value: account)
        let subjectID = try ForgeAttentionSubjectID(subject)
        return try Context(
            repository: repository,
            accountID: accountID,
            subject: subjectID,
            id: ForgeAttentionItemID(
                accountID: accountID,
                repository: repository,
                kind: kind,
                subjectID: subjectID
            )
        )
    }

    private func makeItem(
        repository: ForgeRepositoryIdentity? = nil,
        account: String = "account",
        kind: ForgeAttentionKind = .mention,
        subject: String = "subject",
        authoredCheck: Bool = false,
        time: TimeInterval = 0
    ) throws -> ForgeAttentionItem {
        let context = try makeContext(repository: repository, account: account, kind: kind, subject: subject)
        return try ForgeAttentionItem(
            id: context.id,
            destination: .pullRequest(context.repository, ForgeItemNumber(1)),
            authoredPullRequestFailedCheck: authoredCheck,
            becameActionableAt: Date(timeIntervalSince1970: time)
        )
    }

    private func derive(
        _ event: ForgeAttentionSignal.Event,
        policy: ForgeAttentionPolicy = .defaultValue
    ) throws -> ForgeAttentionDerivation? {
        let watch = try makeWatch()
        return ForgeAttentionDerivationPolicy.derive(
            ForgeAttentionSignal(watchedRepositoryKey: watch.key, event: event),
            watchedRepository: watch,
            policy: policy
        )
    }

    private func makeWatch(
        repository: ForgeRepositoryIdentity? = nil,
        account: String = "account",
        includesBotReplies: Bool = false
    ) throws -> ForgeWatchedRepository {
        let context = try makeContext(repository: repository, account: account)
        return try ForgeWatchedRepository(
            key: ForgeWatchedRepositoryKey(
                accountID: context.accountID,
                repository: context.repository
            ),
            addedAt: .distantPast,
            source: .preferences,
            includesBotReplies: includesBotReplies
        )
    }

    private func alertDecision(
        _ item: ForgeAttentionItem,
        baseline: Bool,
        running: Bool,
        enabled: Set<ForgeAttentionAlertCategory>,
        permission: Bool
    ) -> ForgeAttentionAlertDecision {
        ForgeAttentionAlertPolicy.decision(
            forNewlyActionable: item,
            baselineAlreadyEstablished: baseline,
            applicationIsRunning: running,
            enabledCategories: enabled,
            systemPermissionGranted: permission
        )
    }
}
