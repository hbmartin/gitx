import ForgeKit
import XCTest

final class ForgeReadSurfaceModelsTests: XCTestCase {
    func testCollaborationSurfaceAvailabilityPreservesReadsWithoutAuthoritativeCapabilities() {
        XCTAssertEqual(
            ForgeCollaborationSurfaceAvailabilityPolicy.availableSurfaces(
                readCapabilities: [.readIssues: .unavailable(.missingPermission(.issues))],
                isAuthenticated: false,
                attentionInstalled: false
            ),
            [.pullRequests, .issues]
        )
        XCTAssertEqual(
            ForgeCollaborationSurfaceAvailabilityPolicy.availableSurfaces(
                readCapabilities: nil,
                isAuthenticated: true,
                attentionInstalled: true
            ),
            [.pullRequests, .issues, .attention]
        )
    }

    func testCollaborationSurfaceAvailabilityHidesOnlyAuthoritativelyUnavailableReads() {
        let capabilities: [ForgeOperation: ForgeOperationCapability] = [
            .readPullRequests: .verified(.knownAuthority),
            .readIssues: .unavailable(.missingPermission(.issues)),
        ]

        XCTAssertEqual(
            ForgeCollaborationSurfaceAvailabilityPolicy.availableSurfaces(
                readCapabilities: capabilities,
                isAuthenticated: true,
                attentionInstalled: true
            ),
            [.pullRequests, .attention]
        )
        XCTAssertEqual(
            ForgeCollaborationSurfaceAvailabilityPolicy.availableSurfaces(
                readCapabilities: [
                    .readPullRequests: .unavailable(.repositoryAccessDenied),
                    .readIssues: .verified(.knownAuthority),
                ],
                isAuthenticated: true,
                attentionInstalled: false
            ),
            [.issues]
        )
    }

    func testCollaborationSurfaceAvailabilityTreatsSparseAndVerifiedEvidenceAsVisible() {
        XCTAssertEqual(
            ForgeCollaborationSurfaceAvailabilityPolicy.availableSurfaces(
                readCapabilities: [:],
                isAuthenticated: true,
                attentionInstalled: false
            ),
            [.pullRequests, .issues]
        )
        XCTAssertEqual(
            ForgeCollaborationSurfaceAvailabilityPolicy.availableSurfaces(
                readCapabilities: [.readIssues: .verified(.knownAuthority)],
                isAuthenticated: true,
                attentionInstalled: false
            ),
            [.pullRequests, .issues]
        )
    }

    func testQueryTrimsSearchAndAccumulatorPresentsLoadingEmptyAndTotals() throws {
        let query = ForgeReadSurfaceQuery(searchText: "  crash fix \n", stateFilter: .all)
        XCTAssertEqual(query.searchText, "crash fix")
        var accumulator = ForgeReadSurfaceAccumulator(kind: .pullRequests)

        let request = accumulator.beginReload(query: query)
        XCTAssertEqual(request.kind, .pullRequests)
        XCTAssertEqual(request.query, query)
        XCTAssertNil(request.cursor)
        var presentation = accumulator.presentation { _ in "date" }
        XCTAssertEqual(presentation.statusMessage, "Loading Pull Requests…")
        XCTAssertTrue(presentation.isLoading)
        XCTAssertFalse(presentation.canLoadNextPage)

        let cursor = try ForgePageCursor("page-two")
        XCTAssertTrue(try accumulator.receive(
            ForgeReadSurfacePage(
                items: [.pullRequest(Fixture.pullRequest(number: 7, title: "Fix crash"))],
                nextCursor: cursor,
                totalCount: 3,
                fetchedAt: Fixture.date(30)
            ),
            for: request
        ))
        presentation = accumulator.presentation { _ in "Jul 30" }
        XCTAssertEqual(presentation.rows.map(\.title), ["Fix crash"])
        XCTAssertEqual(presentation.totalDescription, "Showing 1 of 3")
        XCTAssertNil(presentation.statusMessage)
        XCTAssertTrue(presentation.canLoadNextPage)
    }

    func testPaginationDeduplicatesDestinationsAndRejectsObsoleteResponses() throws {
        var accumulator = ForgeReadSurfaceAccumulator(kind: .issues)
        let obsolete = accumulator.beginReload()
        let current = accumulator.beginReload(query: ForgeReadSurfaceQuery(searchText: "swift"))

        XCTAssertFalse(try accumulator.receive(
            ForgeReadSurfacePage(
                items: [.issue(Fixture.issue(number: 1, title: "Old"))],
                fetchedAt: Fixture.date(1)
            ),
            for: obsolete
        ))
        XCTAssertTrue(try accumulator.receive(
            ForgeReadSurfacePage(
                items: [.issue(Fixture.issue(number: 2, title: "Current"))],
                nextCursor: ForgePageCursor("next"),
                totalCount: 2,
                fetchedAt: Fixture.date(2),
                isPartial: true
            ),
            for: current
        ))

        let next = try XCTUnwrap(accumulator.beginNextPage())
        XCTAssertEqual(next.cursor?.value, "next")
        XCTAssertTrue(try accumulator.receive(
            ForgeReadSurfacePage(
                items: [
                    .issue(Fixture.issue(number: 2, title: "Duplicate")),
                    .issue(Fixture.issue(number: 3, title: "Second page")),
                ],
                fetchedAt: Fixture.date(3)
            ),
            for: next
        ))
        XCTAssertEqual(
            accumulator.presentation { _ in "date" }.rows.map(\.number),
            ["#2", "#3"]
        )
        XCTAssertNil(accumulator.beginNextPage())
        XCTAssertEqual(
            accumulator.presentation { _ in "date" }.freshnessMessage,
            "Some fields are unavailable"
        )
    }

    func testRefreshFailureRetainsRowsAndMarksThemStale() throws {
        var accumulator = ForgeReadSurfaceAccumulator(kind: .issues)
        let initial = accumulator.beginReload()
        _ = try accumulator.receive(
            ForgeReadSurfacePage(
                items: [.issue(Fixture.issue(number: 4))],
                fetchedAt: Fixture.date(4)
            ),
            for: initial
        )

        let refresh = accumulator.beginReload()
        XCTAssertTrue(accumulator.fail("The Internet connection appears to be offline.", for: refresh))
        let presentation = accumulator.presentation { _ in "the last successful refresh" }
        XCTAssertEqual(presentation.rows.map(\.number), ["#4"])
        XCTAssertEqual(presentation.statusMessage, "The Internet connection appears to be offline.")
        XCTAssertEqual(
            presentation.freshnessMessage,
            "Stale data from the last successful refresh • Refresh failed: The Internet connection appears to be offline."
        )
    }

    func testFailureWithoutRowsAndSuccessfulEmptyPageHaveDistinctMessages() {
        var failed = ForgeReadSurfaceAccumulator(kind: .issues)
        let failedRequest = failed.beginReload()
        _ = failed.fail("Permission denied.", for: failedRequest)
        XCTAssertEqual(
            failed.presentation { _ in "date" }.statusMessage,
            "Couldn’t load Issues. Permission denied."
        )

        var empty = ForgeReadSurfaceAccumulator(kind: .pullRequests)
        let emptyRequest = empty.beginReload()
        _ = empty.receive(
            ForgeReadSurfacePage(items: [], fetchedAt: Fixture.date(5), isPartial: true),
            for: emptyRequest
        )
        let presentation = empty.presentation { _ in "date" }
        XCTAssertEqual(presentation.statusMessage, "No pull requests match this view.")
        XCTAssertEqual(presentation.freshnessMessage, "Some fields are unavailable")
    }

    func testChangingKindOrQueryClearsMismatchedRows() throws {
        var accumulator = ForgeReadSurfaceAccumulator(kind: .issues)
        let initial = accumulator.beginReload()
        _ = try accumulator.receive(
            ForgeReadSurfacePage(
                items: [.issue(Fixture.issue(number: 9))],
                fetchedAt: Fixture.date(9)
            ),
            for: initial
        )

        _ = accumulator.beginReload(kind: .pullRequests, query: ForgeReadSurfaceQuery(searchText: "new"))
        XCTAssertTrue(accumulator.items.isEmpty)
        XCTAssertNil(accumulator.fetchedAt)
        XCTAssertEqual(accumulator.kind, .pullRequests)
        XCTAssertEqual(accumulator.query.searchText, "new")
    }

    func testRowsExposeDraftDeletedAuthorLabelsAndAccessibleSummary() throws {
        let draft = try Fixture.pullRequest(number: 11, title: "Draft feature", isDraft: true)
        let draftRow = ForgeReadSurfaceRow(item: .pullRequest(draft))
        XCTAssertEqual(draftRow.state, "Draft")
        XCTAssertEqual(draftRow.author, "Ari Engineer")
        XCTAssertEqual(draftRow.labels, ["bug"])
        XCTAssertTrue(draftRow.accessibilityLabel.contains("Draft #11"))
        XCTAssertTrue(draftRow.accessibilityLabel.contains("Labels: bug"))

        let issue = try Fixture.issue(number: 12, author: .available(.deleted), labels: .unavailable(.partialResponse))
        let issueRow = ForgeReadSurfaceRow(item: .issue(issue))
        XCTAssertEqual(issueRow.author, "Deleted user")
        XCTAssertEqual(issueRow.labels, [])
        XCTAssertTrue(issueRow.accessibilityLabel.contains("No labels"))

        let loginOnlyIssue = try Fixture.issue(
            number: 13,
            author: .available(.actor(Fixture.actor(login: "login-only", name: nil)))
        )
        XCTAssertEqual(ForgeReadSurfaceRow(item: .issue(loginOnlyIssue)).author, "login-only")
    }

    func testPullRequestInspectorPresentsAllReadOnlySectionsAndChronologicalTimeline() throws {
        let details = try Fixture.pullRequestDetails()
        let snapshot = ForgeReadSurfaceDetailsSnapshot(
            details: .pullRequest(details),
            fetchedAt: Fixture.date(40),
            isStale: true,
            isPartial: true
        )

        let presentation = ForgeReadInspectorPresenter.present(snapshot) { _ in "Jul 30 at 2:00 AM" }
        XCTAssertEqual(presentation.title, "Fix crash")
        XCTAssertEqual(presentation.subtitle, "Pull Request #7 • Open")
        XCTAssertEqual(presentation.author?.login, "ari")
        XCTAssertEqual(presentation.bodyMarkdown, "## Summary\n\nFixes the crash. ![remote](https://example.com/a.png)")
        XCTAssertEqual(presentation.metadata.first { $0.title == "Branches" }?.value, "feature → main")
        XCTAssertEqual(presentation.metadata.first { $0.title == "Assignees" }?.value, "Ari Engineer")
        XCTAssertEqual(presentation.metadata.first { $0.title == "Milestone" }?.value, "Version 1")
        XCTAssertEqual(presentation.metadata.first { $0.title == "Reviewers" }?.value, "Review Team (requested)")
        XCTAssertEqual(presentation.metadata.first { $0.title == "Linked Issues" }?.value, "#22 Linked issue")
        XCTAssertEqual(presentation.metadata.first { $0.title == "Mergeability" }?.value, "Mergeable")
        XCTAssertEqual(presentation.metadata.first { $0.title == "Checks" }?.value, "build: Passed")
        XCTAssertEqual(presentation.timeline.map(\.summary), ["closed this item", "commented"])
        XCTAssertEqual(presentation.timeline.last?.markdown, "Looks good")
        XCTAssertEqual(presentation.nextTimelineCursor?.value, "timeline-next")
        XCTAssertEqual(presentation.nextCheckCursor?.value, "checks-next")
        XCTAssertEqual(
            presentation.freshnessMessage,
            "Stale data from Jul 30 at 2:00 AM • Some sections are unavailable"
        )
        XCTAssertFalse(presentation.isMutationStateFresh)
    }

    func testInspectorMutationFreshnessAllowsCurrentPartialDataButRejectsStaleData() throws {
        let details = try Fixture.pullRequestDetails()
        let current = ForgeReadInspectorPresenter.present(
            ForgeReadSurfaceDetailsSnapshot(
                details: .pullRequest(details),
                fetchedAt: Fixture.date(41)
            )
        ) { _ in "date" }
        let partial = ForgeReadInspectorPresenter.present(
            ForgeReadSurfaceDetailsSnapshot(
                details: .pullRequest(details),
                fetchedAt: Fixture.date(42),
                isPartial: true
            )
        ) { _ in "date" }
        let stale = ForgeReadInspectorPresenter.present(
            ForgeReadSurfaceDetailsSnapshot(
                details: .pullRequest(details),
                fetchedAt: Fixture.date(43),
                isStale: true
            )
        ) { _ in "date" }

        XCTAssertTrue(current.isMutationStateFresh)
        XCTAssertNil(current.freshnessMessage)
        XCTAssertTrue(partial.isMutationStateFresh)
        XCTAssertEqual(partial.freshnessMessage, "Some sections are unavailable")
        XCTAssertFalse(stale.isMutationStateFresh)
        XCTAssertEqual(stale.freshnessMessage, "Stale data from date")
    }

    func testIssueInspectorKeepsPartialSectionsVisibleAndExplainsUnavailableBodyAndTimeline() throws {
        let details = try Fixture.issueDetails(
            body: .unavailable(.permissionDenied),
            assignees: .unavailable(.partialResponse),
            milestone: .available(nil),
            timeline: .unavailable(.authenticationRequired)
        )
        let presentation = ForgeReadInspectorPresenter.present(
            ForgeReadSurfaceDetailsSnapshot(details: .issue(details), fetchedAt: Fixture.date(50))
        ) { _ in "date" }

        XCTAssertEqual(presentation.subtitle, "Issue #19 • Open")
        XCTAssertEqual(presentation.bodyUnavailableMessage, "Permission required")
        XCTAssertEqual(presentation.timelineUnavailableMessage, "Sign in required")
        XCTAssertEqual(presentation.metadata.first { $0.title == "Assignees" }?.value, "Unavailable in partial response")
        XCTAssertTrue(presentation.metadata.first { $0.title == "Assignees" }?.isUnavailable == true)
        XCTAssertEqual(presentation.metadata.first { $0.title == "Milestone" }?.value, "None")
    }

    func testTimelinePresentationCoversNativeDestinationAndBoundaryEventDescriptions() throws {
        let repository = try Fixture.repository()
        let actor = try Fixture.actor()
        let destination = try ForgeDestination.issue(repository, ForgeItemNumber(91))
        let events: [ForgeTimelineEvent] = try [
            .review(state: .changesRequested, bodyMarkdown: "Please revise", commit: nil),
            .reopened,
            .merged(commit: nil),
            .assigned(actor),
            .unassigned(actor),
            .labeled(Fixture.label()),
            .unlabeled(Fixture.label()),
            .milestoneChanged(Fixture.milestone()),
            .milestoneChanged(nil),
            .milestoneTitleChanged("Next"),
            .milestoneTitleChanged(nil),
            .renamed(previousTitle: "Before", currentTitle: "After"),
            .crossReferenced(destination: destination, title: "Issue #91"),
        ]
        let timeline = try events.enumerated().map { offset, event in
            try Fixture.timelineItem(index: offset + 1, event: event)
        }
        let details = try Fixture.issueDetails(
            timeline: .available(ForgePage(items: timeline))
        )
        let presentation = ForgeReadInspectorPresenter.present(
            ForgeReadSurfaceDetailsSnapshot(details: .issue(details), fetchedAt: Fixture.date(60))
        ) { _ in "date" }

        XCTAssertEqual(presentation.timeline.first?.summary, "reviewed: Changes requested")
        XCTAssertEqual(presentation.timeline.first?.markdown, "Please revise")
        XCTAssertEqual(presentation.timeline.last?.summary, "referenced Issue #91")
        XCTAssertEqual(presentation.timeline.last?.destination, destination)
        XCTAssertTrue(presentation.timeline.map(\.summary).contains("removed the milestone"))
        XCTAssertTrue(presentation.timeline.map(\.summary).contains("renamed “Before” to “After”"))
    }

    func testDetailsMergerAppendsAndDeduplicatesTimelineWhileRetainingInitialSections() throws {
        let current = try Fixture.pullRequestDetails()
        let duplicate = try Fixture.timelineItem(index: 2, event: .comment(bodyMarkdown: "Duplicate", updatedAt: nil))
        let appended = try Fixture.timelineItem(index: 3, event: .reopened)
        let next = try Fixture.pullRequestDetails(
            timelineItems: [duplicate, appended],
            timelineCursor: nil,
            checkCursor: nil
        )
        let merged = try ForgeReadDetailsMerger.merge(
            ForgeReadSurfaceDetailsSnapshot(details: .pullRequest(next), fetchedAt: Fixture.date(80), isPartial: true),
            into: ForgeReadSurfaceDetailsSnapshot(details: .pullRequest(current), fetchedAt: Fixture.date(70)),
            continuation: .timeline
        )
        guard case let .pullRequest(page) = merged.details,
              case let .available(timeline) = page.details.timeline
        else {
            return XCTFail("Expected merged pull request timeline")
        }
        XCTAssertEqual(timeline.items.map(\.id.value), ["timeline-2", "timeline-1", "timeline-3"])
        XCTAssertNil(timeline.nextCursor)
        XCTAssertEqual(page.nextCheckCursor?.value, "checks-next")
        XCTAssertTrue(merged.isPartial)
        XCTAssertEqual(merged.fetchedAt, Fixture.date(80))
    }

    func testDetailsMergerAppendsChecksAndUsesNextCheckCursor() throws {
        let repository = try Fixture.repository()
        let secondCheck = try ForgeCheck(
            repository: repository,
            kind: .check,
            name: "tests",
            state: .running
        )
        let current = try Fixture.pullRequestDetails()
        let next = try Fixture.pullRequestDetails(
            timelineCursor: nil,
            checks: [secondCheck],
            checkCursor: ForgePageCursor("checks-three")
        )
        let merged = try ForgeReadDetailsMerger.merge(
            ForgeReadSurfaceDetailsSnapshot(details: .pullRequest(next), fetchedAt: Fixture.date(81)),
            into: ForgeReadSurfaceDetailsSnapshot(details: .pullRequest(current), fetchedAt: Fixture.date(80)),
            continuation: .checks
        )
        guard case let .pullRequest(page) = merged.details,
              case let .available(checks) = page.details.checks
        else {
            return XCTFail("Expected merged pull request checks")
        }
        XCTAssertEqual(checks.map(\.name), ["build", "tests"])
        XCTAssertEqual(page.nextCheckCursor?.value, "checks-three")
    }

    func testDetailsMergerRejectsMismatchesAndUnavailableContinuation() throws {
        let current = try Fixture.issueDetails()
        let otherSummary = try Fixture.issue(number: 99)
        let other = try ForgeIssueDetails(
            summary: otherSummary,
            bodyMarkdown: .available("Other"),
            assignees: .available([]),
            milestone: .available(nil),
            timeline: .available(ForgePage(items: []))
        )
        XCTAssertThrowsError(try ForgeReadDetailsMerger.merge(
            ForgeReadSurfaceDetailsSnapshot(details: .issue(other), fetchedAt: Fixture.date(90)),
            into: ForgeReadSurfaceDetailsSnapshot(details: .issue(current), fetchedAt: Fixture.date(89)),
            continuation: .timeline
        )) { error in
            XCTAssertEqual(error as? ForgeReadDetailsMergeError, .mismatchedItem)
        }
        XCTAssertThrowsError(try ForgeReadDetailsMerger.merge(
            ForgeReadSurfaceDetailsSnapshot(details: .issue(current), fetchedAt: Fixture.date(90)),
            into: ForgeReadSurfaceDetailsSnapshot(details: .issue(current), fetchedAt: Fixture.date(89)),
            continuation: .checks
        )) { error in
            XCTAssertEqual(error as? ForgeReadDetailsMergeError, .unavailableContinuation)
        }
    }

    func testAttentionPresentationReusesReadRowsAndRoutesAccountWideInspectorByRepository() throws {
        let repository = try Fixture.repository()
        let accountID = try ForgeAccountID(forge: repository.forge, value: "account")
        let summary = try Fixture.pullRequest(number: 41, title: "Review native Attention")
        let itemID = try ForgeAttentionItemID(
            accountID: accountID,
            repository: repository,
            kind: .reviewRequest,
            subjectID: ForgeAttentionSubjectID("subject-41")
        )
        let item = try ForgeAttentionItem(
            id: itemID,
            destination: .pullRequest(repository, summary.number),
            becameActionableAt: Fixture.date(41)
        )
        let entry = try ForgeAttentionInboxEntry(
            record: ForgeAttentionRecord(
                item: item,
                sourceIdentifier: ForgeAttentionSubjectID("review-request-subject-41"),
                sourceOccurredAt: Fixture.date(40)
            ),
            subject: .pullRequest(summary)
        )
        let query = ForgeAttentionInboxQuery(
            accountID: accountID,
            currentRepository: repository
        )

        let presentation = ForgeAttentionReadSurfacePresenter.present(
            entries: [entry],
            query: query
        )
        XCTAssertEqual(presentation.rows.map(\.readRow.title), ["Review native Attention"])
        XCTAssertEqual(presentation.rows.map(\.kindName), ["Review request"])
        XCTAssertEqual(presentation.rows.map(\.repositoryName), ["hbmartin/gitx"])
        XCTAssertEqual(presentation.unseenCount, 1)
        XCTAssertTrue(presentation.visibleColumns.contains(.repository))
        XCTAssertTrue(presentation.rows[0].accessibilityLabel.contains("Unseen Review request"))

        let route = try XCTUnwrap(ForgeAttentionReadSurfacePresenter.inspectorRoute(
            for: itemID,
            in: [entry]
        ))
        XCTAssertEqual(route.repository, repository)
        XCTAssertEqual(route.item.destination, item.destination)
        XCTAssertEqual(route.destination, item.destination)
    }

    func testCollaborationAccessRequiresExplicitChoiceAndUsesOnlyExactPreferredAccount() throws {
        let repository = try Fixture.repository()
        let first = try Fixture.account(login: "zoe", value: "account-z")
        let second = try Fixture.account(login: "ari", value: "account-a")
        let unbound = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository
        )

        XCTAssertEqual(
            ForgeCollaborationAccessPolicy.resolve(
                binding: unbound,
                availableAccounts: [first, second]
            ),
            .requiresExplicitChoice(
                accounts: [second, first],
                preferredAccountUnavailable: false
            )
        )
        XCTAssertEqual(
            ForgeCollaborationAccessPolicy.resolve(
                binding: unbound,
                availableAccounts: [first, second],
                explicitAccountID: first.id
            ),
            .authenticated(first)
        )

        let preferred = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository,
            preferredAccount: second.id
        )
        XCTAssertEqual(
            ForgeCollaborationAccessPolicy.resolve(
                binding: preferred,
                availableAccounts: [first, second]
            ),
            .authenticated(second)
        )
        XCTAssertEqual(
            ForgeCollaborationAccessPolicy.resolve(
                binding: preferred,
                availableAccounts: [first]
            ),
            .requiresExplicitChoice(
                accounts: [first],
                preferredAccountUnavailable: true
            )
        )
    }

    func testCollaborationAccessRequiresExplicitPublicChoiceAndRejectsNonGitHubDotCom() throws {
        let repository = try Fixture.repository()
        let account = try Fixture.account(login: "ari", value: "account-a")
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository,
            preferredAccount: account.id
        )
        XCTAssertEqual(
            ForgeCollaborationAccessPolicy.resolve(
                binding: binding,
                availableAccounts: [account],
                explicitlyContinuesPublicly: true
            ),
            .publicAccess
        )

        let enterpriseForge = try ForgeIdentity(
            kind: .github,
            origin: ForgeOrigin(host: "github.example.com")
        )
        let enterprise = try ForgeRepositoryBinding(
            localRemoteName: "enterprise",
            primaryRepository: ForgeRepositoryIdentity(
                forge: enterpriseForge,
                owner: "team",
                name: "project"
            )
        )
        XCTAssertEqual(
            ForgeCollaborationAccessPolicy.resolve(
                binding: enterprise,
                availableAccounts: [],
                explicitlyContinuesPublicly: true
            ),
            .browserOnly
        )
    }

    func testForgeSidebarPresentationDistinguishesPrimaryPersonalForkParentAndUpstream() throws {
        let primary = try Fixture.repository()
        let parent = try ForgeRepositoryIdentity(
            forge: primary.forge,
            owner: "gitx",
            name: "gitx"
        )
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: primary
        )
        let candidates = try [
            ForgeRepositoryCandidate(
                remoteName: "origin",
                repository: primary,
                confidence: .high,
                relationship: .fork
            ),
            ForgeRepositoryCandidate(
                remoteName: "upstream",
                repository: parent,
                confidence: .high,
                relationship: .upstream
            ),
        ]

        let rows = RepositoryForgeSidebarPresenter.repositories(
            binding: binding,
            candidates: candidates,
            accountLogin: "hbmartin",
            primaryIsFork: true,
            parentRepository: parent
        )

        XCTAssertEqual(rows.map(\.repositoryName), ["hbmartin/gitx", "gitx/gitx"])
        XCTAssertEqual(rows[0].relationships, [.primary, .fork, .personal])
        XCTAssertEqual(rows[1].relationships, [.parent, .upstream])
        XCTAssertEqual(rows[0].detailText, "hbmartin/gitx — Primary, Fork, Personal (origin)")

        let organizationRows = RepositoryForgeSidebarPresenter.repositories(
            binding: binding,
            candidates: candidates,
            accountLogin: "organization-member"
        )
        XCTAssertEqual(organizationRows[0].relationships, [.primary, .organization])
    }
}

private enum Fixture {
    static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    static func repository() throws -> ForgeRepositoryIdentity {
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        return try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
    }

    static func account(login: String, value: String) throws -> ForgeAccount {
        let repository = try repository()
        let accountID = try ForgeAccountID(forge: repository.forge, value: value)
        return try ForgeAccount(
            id: accountID,
            login: login,
            currentCredential: ForgeCredentialMetadata(
                reference: ForgeCredentialReference(
                    accountID: accountID,
                    credentialID: ForgeCredentialID("credential-\(value)"),
                    generation: ForgeCredentialGeneration(1)
                ),
                source: .fineGrainedPersonalAccessToken
            )
        )
    }

    static func actor(login: String = "ari", name: String? = "Ari Engineer") throws -> ForgeActor {
        let repository = try repository()
        return try ForgeActor(
            id: ForgeObjectID(forge: repository.forge, value: "actor-\(login)"),
            login: login,
            displayName: name,
            avatarURL: URL(string: "https://avatars.githubusercontent.com/u/7?v=4"),
            kind: .person
        )
    }

    static func label() throws -> ForgeLabel {
        let repository = try repository()
        return try ForgeLabel(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: "label-bug"),
            name: "bug",
            color: ForgeLabelColor("ff0000")
        )
    }

    static func milestone() throws -> ForgeMilestone {
        let repository = try repository()
        return try ForgeMilestone(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: "milestone-1"),
            number: 1,
            title: "Version 1",
            state: .open
        )
    }

    static func pullRequest(
        number: Int,
        title: String = "Fix crash",
        isDraft: Bool = false,
        state: ForgePullRequestState = .open,
        author: ForgeReadSection<ForgeAuthor>? = nil,
        labels: ForgeReadSection<[ForgeLabel]>? = nil
    ) throws -> ForgePullRequestSummary {
        let repository = try repository()
        return try ForgePullRequestSummary(
            repository: repository,
            number: ForgeItemNumber(number),
            state: state,
            isDraft: isDraft,
            title: title,
            author: author ?? .available(.actor(actor())),
            head: .available(ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("feature"),
                commit: ForgeCommitID("1111111")
            )),
            base: .available(ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("main"),
                commit: ForgeCommitID("2222222")
            )),
            createdAt: date(1),
            updatedAt: date(2),
            labels: labels ?? .available([label()]),
            checkRollup: .available(.succeeded),
            reviewRollup: .available(.approved)
        )
    }

    static func issue(
        number: Int,
        title: String = "Issue title",
        state: ForgeIssueState = .open,
        author: ForgeReadSection<ForgeAuthor>? = nil,
        labels: ForgeReadSection<[ForgeLabel]>? = nil
    ) throws -> ForgeIssueSummary {
        try ForgeIssueSummary(
            repository: repository(),
            number: ForgeItemNumber(number),
            state: state,
            title: title,
            author: author ?? .available(.actor(actor())),
            createdAt: date(3),
            updatedAt: date(4),
            labels: labels ?? .available([label()])
        )
    }

    static func timelineItem(index: Int, event: ForgeTimelineEvent) throws -> ForgeTimelineItem {
        let repository = try repository()
        return try ForgeTimelineItem(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: "timeline-\(index)"),
            occurredAt: date(TimeInterval(index)),
            actor: .actor(actor()),
            event: event
        )
    }

    static func pullRequestDetails(
        timelineItems: [ForgeTimelineItem]? = nil,
        timelineCursor: ForgePageCursor? = try? ForgePageCursor("timeline-next"),
        checks: [ForgeCheck]? = nil,
        checkCursor: ForgePageCursor? = try? ForgePageCursor("checks-next")
    ) throws -> ForgePullRequestDetailsPage {
        let repository = try repository()
        let team = try ForgeTeam(
            id: ForgeObjectID(forge: repository.forge, value: "team-review"),
            name: "Review Team",
            slug: "review-team"
        )
        let check = try ForgeCheck(
            repository: repository,
            kind: .check,
            name: "build",
            state: .succeeded
        )
        let defaultTimelineItems = try [
            timelineItem(index: 2, event: .comment(bodyMarkdown: "Looks good", updatedAt: nil)),
            timelineItem(index: 1, event: .closed),
        ]
        let timeline = try ForgePage(
            items: timelineItems ?? defaultTimelineItems,
            nextCursor: timelineCursor
        )
        let details = try ForgePullRequestDetails(
            summary: pullRequest(number: 7),
            bodyMarkdown: .available("## Summary\n\nFixes the crash. ![remote](https://example.com/a.png)"),
            assignees: .available([actor()]),
            milestone: .available(milestone()),
            reviewers: .available([ForgeReviewer(participant: .team(team), isRequested: true)]),
            linkedIssues: .available([
                ForgeLinkedIssue(
                    repository: repository,
                    number: ForgeItemNumber(22),
                    state: .open,
                    title: "Linked issue"
                ),
            ]),
            mergeability: .available(.mergeable),
            checks: .available(checks ?? [check]),
            timeline: .available(timeline)
        )
        return ForgePullRequestDetailsPage(details: details, nextCheckCursor: checkCursor)
    }

    static func issueDetails(
        body: ForgeReadSection<String> = .available("Issue body"),
        assignees: ForgeReadSection<[ForgeActor]>? = nil,
        milestone: ForgeReadSection<ForgeMilestone?>? = nil,
        timeline: ForgeReadSection<ForgePage<ForgeTimelineItem>>? = nil
    ) throws -> ForgeIssueDetails {
        try ForgeIssueDetails(
            summary: issue(number: 19, title: "Issue details"),
            bodyMarkdown: body,
            assignees: assignees ?? .available([actor()]),
            milestone: milestone ?? .available(self.milestone()),
            timeline: timeline ?? .available(ForgePage(items: [
                timelineItem(index: 1, event: .comment(bodyMarkdown: "Comment", updatedAt: nil)),
            ]))
        )
    }
}

@MainActor
final class ForgeGitHubReadSurfaceServiceTests: XCTestCase {
    func testServiceCoversEveryListAndDefensiveSearchStateFilter() async throws {
        let repository = try Fixture.repository()
        let openPullRequest = try Fixture.pullRequest(number: 1, state: .open)
        let closedPullRequest = try Fixture.pullRequest(number: 2, state: .closed)
        let openIssue = try Fixture.issue(number: 3, state: .open)
        let closedIssue = try Fixture.issue(number: 4, state: .closed)
        let adapter = try ForgeReadSurfaceAdapterStub(
            pullRequests: ForgeGitHubSurfaceRead(value: ForgePage(items: [openPullRequest, closedPullRequest])),
            issues: ForgeGitHubSurfaceRead(value: ForgePage(items: [openIssue, closedIssue])),
            search: ForgeGitHubSurfaceRead(value: ForgePage(items: [
                .pullRequest(openPullRequest),
                .pullRequest(closedPullRequest),
                .issue(openIssue),
                .issue(closedIssue),
            ])),
            pullRequestDetails: ForgeGitHubSurfaceRead(value: Fixture.pullRequestDetails()),
            issueDetails: ForgeGitHubSurfaceRead(value: Fixture.issueDetails())
        )
        let service = ForgeGitHubReadSurfaceService(repository: repository, adapter: adapter)

        for filter in ForgeReadStateFilter.allCases {
            let pullRequests = try await service.loadItems(
                kind: .pullRequests,
                query: ForgeReadSurfaceQuery(stateFilter: filter),
                after: nil
            )
            let issues = try await service.loadItems(
                kind: .issues,
                query: ForgeReadSurfaceQuery(stateFilter: filter),
                after: nil
            )
            XCTAssertEqual(pullRequests.items.count, 2, "list filtering is delegated for \(filter)")
            XCTAssertEqual(issues.items.count, 2, "list filtering is delegated for \(filter)")

            let searchedPullRequests = try await service.loadItems(
                kind: .pullRequests,
                query: ForgeReadSurfaceQuery(searchText: "literal", stateFilter: filter),
                after: nil
            )
            let searchedIssues = try await service.loadItems(
                kind: .issues,
                query: ForgeReadSurfaceQuery(searchText: "literal", stateFilter: filter),
                after: nil
            )
            let expectedCount = filter == .all ? 2 : 1
            XCTAssertEqual(searchedPullRequests.items.count, expectedCount)
            XCTAssertEqual(searchedIssues.items.count, expectedCount)
            XCTAssertTrue(searchedPullRequests.items.allSatisfy { item in
                if case .pullRequest = item {
                    return true
                }
                return false
            })
            XCTAssertTrue(searchedIssues.items.allSatisfy { item in
                if case .issue = item {
                    return true
                }
                return false
            })
        }

        let calls = await adapter.snapshot()
        XCTAssertEqual(calls.pullRequests.map(\.states), [[.open], [.closed, .merged], nil])
        XCTAssertEqual(calls.issues.map(\.states), [[.open], [.closed], nil])
    }

    func testServiceRoutesListFiltersAndPreservesPartialPaginationMetadata() async throws {
        let repository = try Fixture.repository()
        let next = try ForgePageCursor("next")
        let openPullRequest = try Fixture.pullRequest(number: 1, title: "Open")
        let mergedPullRequest = try Fixture.pullRequest(number: 2, title: "Merged", state: .merged)
        let openIssue = try Fixture.issue(number: 3, title: "Issue")
        let adapter = try ForgeReadSurfaceAdapterStub(
            pullRequests: ForgeGitHubSurfaceRead(
                value: ForgePage(items: [mergedPullRequest], nextCursor: next, totalCount: 7),
                isPartial: true
            ),
            issues: ForgeGitHubSurfaceRead(value: ForgePage(items: [openIssue], totalCount: 1)),
            search: ForgeGitHubSurfaceRead(value: ForgePage(
                items: [
                    .pullRequest(openPullRequest),
                    .pullRequest(mergedPullRequest),
                    .issue(openIssue),
                ],
                nextCursor: next,
                totalCount: 3
            )),
            pullRequestDetails: ForgeGitHubSurfaceRead(value: Fixture.pullRequestDetails()),
            issueDetails: ForgeGitHubSurfaceRead(value: Fixture.issueDetails())
        )
        let service = ForgeGitHubReadSurfaceService(
            repository: repository,
            adapter: adapter,
            now: { Fixture.date(200) }
        )

        let pullRequests = try await service.loadItems(
            kind: .pullRequests,
            query: ForgeReadSurfaceQuery(stateFilter: .closed),
            after: nil
        )
        XCTAssertEqual(
            pullRequests.items.map(\.destination),
            [ForgeRepositoryItem.pullRequest(mergedPullRequest).destination]
        )
        XCTAssertEqual(pullRequests.nextCursor, next)
        XCTAssertEqual(pullRequests.totalCount, 7)
        XCTAssertEqual(pullRequests.fetchedAt, Fixture.date(200))
        XCTAssertTrue(pullRequests.isPartial)

        let search = try await service.loadItems(
            kind: .pullRequests,
            query: ForgeReadSurfaceQuery(searchText: "  release crash  ", stateFilter: .closed),
            after: next
        )
        XCTAssertEqual(
            search.items.map(\.destination),
            [ForgeRepositoryItem.pullRequest(mergedPullRequest).destination]
        )
        XCTAssertEqual(search.nextCursor, next)
        XCTAssertNil(search.totalCount, "mixed-kind search totals must not be presented as filtered totals")

        _ = try await service.loadItems(
            kind: .issues,
            query: ForgeReadSurfaceQuery(stateFilter: .all),
            after: nil
        )
        let calls = await adapter.snapshot()
        XCTAssertEqual(calls.pullRequests, [
            .init(cursor: nil, states: [.closed, .merged]),
        ])
        XCTAssertEqual(calls.searches, [
            .init(text: "release crash", cursor: next),
        ])
        XCTAssertEqual(calls.issues, [
            .init(cursor: nil, states: nil),
        ])
    }

    func testServiceRoutesDetailContinuationsAndRejectsCrossRepositoryItemsBeforeAdapterEntry() async throws {
        let repository = try Fixture.repository()
        let timelineCursor = try ForgePageCursor("timeline")
        let checkCursor = try ForgePageCursor("checks")
        let pullRequestDetails = try Fixture.pullRequestDetails()
        let issueDetails = try Fixture.issueDetails()
        let adapter = try ForgeReadSurfaceAdapterStub(
            pullRequests: ForgeGitHubSurfaceRead(value: ForgePage(items: [])),
            issues: ForgeGitHubSurfaceRead(value: ForgePage(items: [])),
            search: ForgeGitHubSurfaceRead(value: ForgePage(items: [])),
            pullRequestDetails: ForgeGitHubSurfaceRead(value: pullRequestDetails, isPartial: true),
            issueDetails: ForgeGitHubSurfaceRead(value: issueDetails)
        )
        let service = ForgeGitHubReadSurfaceService(
            repository: repository,
            adapter: adapter,
            now: { Fixture.date(300) }
        )

        let pullRequestSnapshot = try await service.loadDetails(
            for: .pullRequest(pullRequestDetails.details.summary),
            timelineAfter: timelineCursor,
            checkAfter: checkCursor
        )
        XCTAssertEqual(pullRequestSnapshot.fetchedAt, Fixture.date(300))
        XCTAssertTrue(pullRequestSnapshot.isPartial)
        guard case .pullRequest = pullRequestSnapshot.details else {
            return XCTFail("Expected pull request details")
        }

        let issueSnapshot = try await service.loadDetails(
            for: .issue(issueDetails.summary),
            timelineAfter: timelineCursor,
            checkAfter: checkCursor
        )
        XCTAssertFalse(issueSnapshot.isPartial)
        guard case .issue = issueSnapshot.details else {
            return XCTFail("Expected issue details")
        }

        let otherRepository = try ForgeRepositoryIdentity(
            forge: repository.forge,
            owner: repository.owner,
            name: "another-repository"
        )
        let mismatchedService = ForgeGitHubReadSurfaceService(
            repository: otherRepository,
            adapter: adapter
        )
        do {
            _ = try await mismatchedService.loadDetails(
                for: .issue(issueDetails.summary),
                timelineAfter: nil,
                checkAfter: nil
            )
            XCTFail("Cross-repository details must fail closed")
        } catch {
            XCTAssertEqual(error as? ForgeGitHubReadSurfaceServiceError, .repositoryMismatch)
        }

        let calls = await adapter.snapshot()
        XCTAssertEqual(calls.pullRequestDetails, [
            .init(number: pullRequestDetails.details.summary.number, timeline: timelineCursor, checks: checkCursor),
        ])
        XCTAssertEqual(calls.issueDetails, [
            .init(number: issueDetails.summary.number, timeline: timelineCursor),
        ])
        XCTAssertEqual(
            ForgeGitHubReadSurfaceServiceError.repositoryMismatch.errorDescription,
            "The selected GitHub item belongs to a different repository."
        )
    }
}

private actor ForgeReadSurfaceAdapterStub: ForgeGitHubReadSurfaceAdapter {
    struct ListCall<State: Hashable & Sendable>: Equatable, Sendable {
        let cursor: ForgePageCursor?
        let states: Set<State>?
    }

    struct SearchCall: Equatable, Sendable {
        let text: String
        let cursor: ForgePageCursor?
    }

    struct PullRequestDetailsCall: Equatable, Sendable {
        let number: ForgeItemNumber
        let timeline: ForgePageCursor?
        let checks: ForgePageCursor?
    }

    struct IssueDetailsCall: Equatable, Sendable {
        let number: ForgeItemNumber
        let timeline: ForgePageCursor?
    }

    struct Snapshot: Sendable {
        let pullRequests: [ListCall<ForgePullRequestState>]
        let issues: [ListCall<ForgeIssueState>]
        let searches: [SearchCall]
        let pullRequestDetails: [PullRequestDetailsCall]
        let issueDetails: [IssueDetailsCall]
    }

    private let pullRequestResult: ForgeGitHubSurfaceRead<ForgePage<ForgePullRequestSummary>>
    private let issueResult: ForgeGitHubSurfaceRead<ForgePage<ForgeIssueSummary>>
    private let searchResult: ForgeGitHubSurfaceRead<ForgePage<ForgeRepositoryItem>>
    private let pullRequestDetailsResult: ForgeGitHubSurfaceRead<ForgePullRequestDetailsPage>
    private let issueDetailsResult: ForgeGitHubSurfaceRead<ForgeIssueDetails>
    private var pullRequestCalls: [ListCall<ForgePullRequestState>] = []
    private var issueCalls: [ListCall<ForgeIssueState>] = []
    private var searchCalls: [SearchCall] = []
    private var pullRequestDetailCalls: [PullRequestDetailsCall] = []
    private var issueDetailCalls: [IssueDetailsCall] = []

    init(
        pullRequests: ForgeGitHubSurfaceRead<ForgePage<ForgePullRequestSummary>>,
        issues: ForgeGitHubSurfaceRead<ForgePage<ForgeIssueSummary>>,
        search: ForgeGitHubSurfaceRead<ForgePage<ForgeRepositoryItem>>,
        pullRequestDetails: ForgeGitHubSurfaceRead<ForgePullRequestDetailsPage>,
        issueDetails: ForgeGitHubSurfaceRead<ForgeIssueDetails>
    ) {
        pullRequestResult = pullRequests
        issueResult = issues
        searchResult = search
        pullRequestDetailsResult = pullRequestDetails
        issueDetailsResult = issueDetails
    }

    func pullRequests(
        repository _: ForgeRepositoryIdentity,
        after: ForgePageCursor?,
        states: Set<ForgePullRequestState>?
    ) async throws -> ForgeGitHubSurfaceRead<ForgePage<ForgePullRequestSummary>> {
        pullRequestCalls.append(ListCall(cursor: after, states: states))
        return pullRequestResult
    }

    func issues(
        repository _: ForgeRepositoryIdentity,
        after: ForgePageCursor?,
        states: Set<ForgeIssueState>?
    ) async throws -> ForgeGitHubSurfaceRead<ForgePage<ForgeIssueSummary>> {
        issueCalls.append(ListCall(cursor: after, states: states))
        return issueResult
    }

    func searchRepositoryItems(
        repository _: ForgeRepositoryIdentity,
        text: String,
        after: ForgePageCursor?
    ) async throws -> ForgeGitHubSurfaceRead<ForgePage<ForgeRepositoryItem>> {
        searchCalls.append(SearchCall(text: text, cursor: after))
        return searchResult
    }

    func pullRequestDetails(
        repository _: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        timelineAfter: ForgePageCursor?,
        checkAfter: ForgePageCursor?
    ) async throws -> ForgeGitHubSurfaceRead<ForgePullRequestDetailsPage> {
        pullRequestDetailCalls.append(PullRequestDetailsCall(
            number: number,
            timeline: timelineAfter,
            checks: checkAfter
        ))
        return pullRequestDetailsResult
    }

    func issueDetails(
        repository _: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        timelineAfter: ForgePageCursor?
    ) async throws -> ForgeGitHubSurfaceRead<ForgeIssueDetails> {
        issueDetailCalls.append(IssueDetailsCall(number: number, timeline: timelineAfter))
        return issueDetailsResult
    }

    func snapshot() -> Snapshot {
        Snapshot(
            pullRequests: pullRequestCalls,
            issues: issueCalls,
            searches: searchCalls,
            pullRequestDetails: pullRequestDetailCalls,
            issueDetails: issueDetailCalls
        )
    }
}
