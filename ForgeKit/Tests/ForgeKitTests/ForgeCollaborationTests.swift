@testable import ForgeKit
import Foundation
import XCTest

final class ForgeCollaborationTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    func testModelErrorsDescribeEveryInvalidBoundary() {
        let errors: [ForgeCollaborationModelError] = [
            .invalidObjectIdentifier,
            .invalidPageCursor,
            .invalidPageTotal,
            .invalidActorLogin,
            .invalidTeamName,
            .invalidTeamSlug,
            .invalidLabelName,
            .invalidLabelColor,
            .invalidMilestoneNumber,
            .invalidCheckName,
            .mismatchedForge,
            .mismatchedRepository,
        ]
        XCTAssertEqual(Set(errors.compactMap(\.errorDescription)).count, errors.count)
    }

    func testOpaqueIdentifiersAndCursorsValidateAndRevalidateWhenDecoded() throws {
        let repository = try TestSupport.repository()
        let identifier = try ForgeObjectID(forge: repository.forge, value: "node:naïve")
        XCTAssertEqual(try roundTrip(identifier), identifier)
        XCTAssertThrowsError(try ForgeObjectID(forge: repository.forge, value: " ")) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .invalidObjectIdentifier)
        }
        let badIdentifier = try JSONSerialization.data(withJSONObject: [
            "forge": jsonObject(repository.forge),
            "value": "\n",
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeObjectID.self, from: badIdentifier))

        let cursor = try ForgePageCursor("cursor:α")
        XCTAssertEqual(try roundTrip(cursor), cursor)
        XCTAssertThrowsError(try ForgePageCursor("")) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .invalidPageCursor)
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(ForgePageCursor.self, from: Data("\" \"".utf8))
        )
    }

    func testPagesPreserveOrderAndRejectNegativeTotalsIncludingDuringDecode() throws {
        let page = try ForgePage(items: [3, 1, 2], nextCursor: ForgePageCursor("next"), totalCount: 9)
        XCTAssertEqual(page.items, [3, 1, 2])
        XCTAssertEqual(try roundTrip(page), page)
        XCTAssertEqual(try ForgePage<Int>(items: []).totalCount, nil)
        XCTAssertThrowsError(try ForgePage(items: [1], totalCount: -1)) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .invalidPageTotal)
        }
        let invalid = Data(#"{"items":[1],"totalCount":-2}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgePage<Int>.self, from: invalid))
    }

    func testReadSectionsDistinguishLegitimateAbsenceFromEveryUnavailableReason() throws {
        let absent: ForgeReadSection<String?> = .available(nil)
        XCTAssertEqual(try roundTrip(absent), absent)
        for reason in ForgeReadUnavailableReason.allCases {
            let section: ForgeReadSection<String?> = .unavailable(reason)
            XCTAssertEqual(try roundTrip(section), section)
        }
    }

    func testActorsAuthorsTeamsAndParticipantsRoundTripAndValidateNames() throws {
        let repository = try TestSupport.repository()
        let actor = try makeActor(repository: repository, kind: .person)
        XCTAssertEqual(try roundTrip(actor), actor)
        XCTAssertThrowsError(
            try ForgeActor(id: actor.id, login: "", kind: .person)
        ) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .invalidActorLogin)
        }
        let invalidActor = try replacingJSONValue(in: actor, key: "login", value: " ")
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeActor.self, from: invalidActor))

        XCTAssertEqual(try roundTrip(ForgeAuthor.actor(actor)), .actor(actor))
        XCTAssertEqual(try roundTrip(ForgeAuthor.deleted), .deleted)

        let team = try makeTeam(repository: repository)
        XCTAssertEqual(try roundTrip(team), team)
        XCTAssertThrowsError(try ForgeTeam(id: team.id, name: "", slug: "core")) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .invalidTeamName)
        }
        XCTAssertThrowsError(try ForgeTeam(id: team.id, name: "Core", slug: "\n")) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .invalidTeamSlug)
        }
        XCTAssertEqual(try roundTrip(ForgeReviewParticipant.actor(actor)), .actor(actor))
        XCTAssertEqual(try roundTrip(ForgeReviewParticipant.team(team)), .team(team))
        XCTAssertEqual(Set(ForgeActorKind.allCases), [.person, .organization, .bot, .unknown])
    }

    func testLabelsColorsAndMilestonesValidateAndRoundTrip() throws {
        let repository = try TestSupport.repository()
        let otherForge = try TestSupport.repository(kind: .gitLab)
        let otherForgeID = try ForgeObjectID(forge: otherForge.forge, value: "other")
        let color = try ForgeLabelColor("A0b1C2")
        XCTAssertEqual(color.hexRGB, "a0b1c2")
        XCTAssertEqual(try roundTrip(color), color)
        for invalid in ["", "12345", "1234567", "zzzzzz", "åbcdef"] {
            XCTAssertThrowsError(try ForgeLabelColor(invalid), invalid)
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(ForgeLabelColor.self, from: Data("\"oops\"".utf8))
        )

        let label = try makeLabel(repository: repository)
        XCTAssertEqual(try roundTrip(label), label)
        XCTAssertThrowsError(try ForgeLabel(repository: repository, id: label.id, name: " ")) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .invalidLabelName)
        }
        XCTAssertThrowsError(try ForgeLabel(repository: repository, id: otherForgeID, name: "cross-forge")) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedForge)
        }

        let milestone = try makeMilestone(repository: repository)
        XCTAssertEqual(try roundTrip(milestone), milestone)
        XCTAssertThrowsError(
            try ForgeMilestone(
                repository: repository,
                id: milestone.id,
                number: 0,
                title: "Zero",
                state: .open
            )
        ) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .invalidMilestoneNumber)
        }
        XCTAssertThrowsError(
            try ForgeMilestone(
                repository: repository,
                id: otherForgeID,
                number: 1,
                title: "Cross Forge",
                state: .open
            )
        ) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedForge)
        }
        XCTAssertEqual(Set(ForgeMilestoneState.allCases), [.open, .closed])
    }

    func testRepositoryFactsPreservePartialFieldsAndValidateForkOrigin() throws {
        let repository = try TestSupport.repository()
        let parent = try TestSupport.repository(owner: "parent")
        let facts = try ForgeRepositoryFacts(
            repository: repository,
            defaultBranch: .available(TestSupport.main),
            description: .available(nil),
            topics: .available(["swift", "git"]),
            visibility: .available(.public),
            isArchived: .available(false),
            forkRelationship: .available(.fork(parent: parent))
        )
        XCTAssertEqual(try roundTrip(facts), facts)

        let partial = try ForgeRepositoryFacts(
            repository: repository,
            defaultBranch: .unavailable(.partialResponse),
            description: .unavailable(.permissionDenied),
            topics: .unavailable(.notRequested),
            visibility: .unavailable(.unsupported),
            isArchived: .unavailable(.authenticationRequired),
            forkRelationship: .available(.standalone)
        )
        XCTAssertEqual(try roundTrip(partial), partial)
        XCTAssertEqual(
            Set(ForgeRepositoryVisibility.allCases),
            [.public, .private, .internal, .unknown]
        )

        let otherForgeParent = try TestSupport.repository(kind: .gitLab)
        XCTAssertThrowsError(
            try ForgeRepositoryFacts(
                repository: repository,
                defaultBranch: .available(TestSupport.main),
                description: .available(nil),
                topics: .available([]),
                visibility: .available(.unknown),
                isArchived: .available(false),
                forkRelationship: .available(.fork(parent: otherForgeParent))
            )
        ) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedForge)
        }
    }

    func testChecksRoundTripValidateNamesAndRollUpWithDocumentedPrecedence() throws {
        let repository = try TestSupport.repository()
        let full = try makeCheck(repository: repository, state: .succeeded)
        XCTAssertEqual(try roundTrip(full), full)
        let status = try ForgeCheck(repository: repository, kind: .commitStatus, name: "deploy", state: .neutral)
        XCTAssertEqual(try roundTrip(status), status)
        XCTAssertThrowsError(try ForgeCheck(repository: repository, kind: .check, name: "", state: .running)) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .invalidCheckName)
        }
        XCTAssertThrowsError(
            try ForgeCheck(
                repository: repository,
                id: ForgeObjectID(forge: TestSupport.repository(kind: .gitLab).forge, value: "other"),
                kind: .check,
                name: "Other",
                state: .running
            )
        ) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedForge)
        }

        func check(_ state: ForgeCheckState) throws -> ForgeCheck {
            try ForgeCheck(repository: repository, kind: .check, name: state.rawValue, state: state)
        }
        XCTAssertEqual(ForgeCheckRollupPolicy.rollup([]), .neutral)
        XCTAssertEqual(try ForgeCheckRollupPolicy.rollup([check(.neutral)]), .neutral)
        XCTAssertEqual(try ForgeCheckRollupPolicy.rollup([check(.neutral), check(.succeeded)]), .succeeded)
        XCTAssertEqual(try ForgeCheckRollupPolicy.rollup([check(.succeeded), check(.running)]), .running)
        XCTAssertEqual(
            try ForgeCheckRollupPolicy.rollup([check(.running), check(.attentionRequired)]),
            .attentionRequired
        )
        XCTAssertEqual(
            try ForgeCheckRollupPolicy.rollup([check(.attentionRequired), check(.failed)]),
            .failed
        )
        XCTAssertEqual(Set(ForgeCheckKind.allCases), [.check, .commitStatus])
        XCTAssertEqual(Set(ForgeCheckState.allCases.map(\.rawValue)), Set(ForgeCheckRollup.allCases.map(\.rawValue)))
    }

    func testReviewAndStateEnumsAndReviewerValuesRoundTrip() throws {
        let repository = try TestSupport.repository()
        let actor = try makeActor(repository: repository)
        let team = try makeTeam(repository: repository)
        for state in ForgeReviewState.allCases {
            let reviewer = ForgeReviewer(
                participant: .actor(actor),
                isRequested: state == .commented,
                latestReviewState: state
            )
            XCTAssertEqual(try roundTrip(reviewer), reviewer)
        }
        let requestedTeam = ForgeReviewer(participant: .team(team), isRequested: true)
        XCTAssertEqual(try roundTrip(requestedTeam), requestedTeam)
        XCTAssertEqual(Set(ForgeReviewRollup.allCases), [.approved, .changesRequested, .reviewRequired, .noDecision])
        XCTAssertEqual(Set(ForgeMergeability.allCases), [.mergeable, .conflicting, .unknown])
        XCTAssertEqual(Set(ForgePullRequestState.allCases), [.open, .closed, .merged])
        XCTAssertEqual(Set(ForgeIssueState.allCases), [.open, .closed])
    }

    func testTimelineEverySupportedEventRoundTrips() throws {
        let repository = try TestSupport.repository()
        let actor = try makeActor(repository: repository)
        let label = try makeLabel(repository: repository)
        let milestone = try makeMilestone(repository: repository)
        let issueNumber = try ForgeItemNumber(9)
        let events: [ForgeTimelineEvent] = [
            .comment(bodyMarkdown: "**untrusted**", updatedAt: timestamp.addingTimeInterval(1)),
            .review(state: .approved, bodyMarkdown: "ship it", commit: TestSupport.commit),
            .closed,
            .reopened,
            .merged(commit: TestSupport.commit),
            .assigned(actor),
            .unassigned(actor),
            .labeled(label),
            .unlabeled(label),
            .milestoneChanged(milestone),
            .milestoneChanged(nil),
            .renamed(previousTitle: "Old", currentTitle: "New"),
            .crossReferenced(destination: .issue(repository, issueNumber), title: "Issue 9"),
        ]
        for (offset, event) in events.enumerated() {
            let item = try ForgeTimelineItem(
                repository: repository,
                id: ForgeObjectID(forge: repository.forge, value: "event-\(offset)"),
                occurredAt: timestamp.addingTimeInterval(Double(offset)),
                actor: offset == 2 ? .deleted : .actor(actor),
                event: event
            )
            XCTAssertEqual(try roundTrip(item), item)
        }
        let systemItem = try ForgeTimelineItem(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: "system"),
            occurredAt: timestamp,
            event: .closed
        )
        XCTAssertNil(systemItem.actor)
    }

    func testTimelineRejectsEveryCrossForgeIdentitySurface() throws {
        let repository = try TestSupport.repository()
        let sameForgeOther = try TestSupport.repository(owner: "other")
        let other = try TestSupport.repository(kind: .gitLab)
        let id = try ForgeObjectID(forge: repository.forge, value: "event")
        let otherID = try ForgeObjectID(forge: other.forge, value: "other")
        let otherActor = try makeActor(repository: other)
        let otherLabel = try makeLabel(repository: other)
        let otherMilestone = try makeMilestone(repository: other)

        XCTAssertThrowsError(
            try ForgeTimelineItem(repository: repository, id: otherID, occurredAt: timestamp, event: .closed)
        )
        XCTAssertThrowsError(
            try ForgeTimelineItem(
                repository: repository,
                id: id,
                occurredAt: timestamp,
                actor: .actor(otherActor),
                event: .closed
            )
        )
        for event in try [
            ForgeTimelineEvent.labeled(makeLabel(repository: sameForgeOther)),
            .unlabeled(makeLabel(repository: sameForgeOther)),
            .milestoneChanged(makeMilestone(repository: sameForgeOther)),
        ] {
            XCTAssertThrowsError(
                try ForgeTimelineItem(repository: repository, id: id, occurredAt: timestamp, event: event)
            ) {
                XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedRepository)
            }
        }
        for event in [ForgeTimelineEvent.assigned(otherActor), .unassigned(otherActor)] {
            XCTAssertThrowsError(
                try ForgeTimelineItem(repository: repository, id: id, occurredAt: timestamp, event: event)
            )
        }
        for event in [ForgeTimelineEvent.labeled(otherLabel), .unlabeled(otherLabel)] {
            XCTAssertThrowsError(
                try ForgeTimelineItem(repository: repository, id: id, occurredAt: timestamp, event: event)
            )
        }
        XCTAssertThrowsError(
            try ForgeTimelineItem(
                repository: repository,
                id: id,
                occurredAt: timestamp,
                event: .milestoneChanged(otherMilestone)
            )
        )
        XCTAssertThrowsError(
            try ForgeTimelineItem(
                repository: repository,
                id: id,
                occurredAt: timestamp,
                event: .crossReferenced(destination: .repository(other), title: "Other")
            )
        )
    }

    func testPullRequestCompleteAndPartialModelsRoundTrip() throws {
        let repository = try TestSupport.repository()
        let fork = try TestSupport.repository(owner: "contributor", name: repository.name)
        let summary = try makePullRequestSummary(repository: repository, headRepository: fork)
        let timelineItem = try makeTimelineItem(repository: repository)
        let details = try ForgePullRequestDetails(
            summary: summary,
            bodyMarkdown: .available("# Untrusted body"),
            assignees: .available([makeActor(repository: repository)]),
            milestone: .available(makeMilestone(repository: repository)),
            reviewers: .available([
                ForgeReviewer(participant: .actor(makeActor(repository: repository)), isRequested: true),
                ForgeReviewer(participant: .team(makeTeam(repository: repository)), isRequested: false, latestReviewState: .approved),
            ]),
            linkedIssues: .available([
                ForgeLinkedIssue(
                    repository: repository,
                    number: ForgeItemNumber(2),
                    state: .closed,
                    title: "Linked"
                ),
            ]),
            mergeability: .available(.mergeable),
            checks: .available([makeCheck(repository: repository, state: .succeeded)]),
            timeline: .available(ForgePage(items: [timelineItem], totalCount: 1))
        )
        XCTAssertEqual(try roundTrip(details), details)

        let partialSummary = try makePullRequestSummary(
            repository: repository,
            author: .available(.deleted),
            head: .unavailable(.partialResponse),
            base: .unavailable(.partialResponse),
            labels: .unavailable(.permissionDenied)
        )
        let partial = try ForgePullRequestDetails(
            summary: partialSummary,
            bodyMarkdown: .unavailable(.partialResponse),
            assignees: .unavailable(.permissionDenied),
            milestone: .available(nil),
            reviewers: .unavailable(.authenticationRequired),
            linkedIssues: .unavailable(.notRequested),
            mergeability: .unavailable(.unsupported),
            checks: .unavailable(.partialResponse),
            timeline: .unavailable(.notRequested)
        )
        XCTAssertEqual(try roundTrip(partial), partial)
    }

    func testPullRequestSummaryRejectsCrossIdentityValues() throws {
        let repository = try TestSupport.repository()
        let sameForgeOther = try TestSupport.repository(owner: "other")
        let otherForge = try TestSupport.repository(kind: .gitLab)
        let otherActor = try makeActor(repository: otherForge)
        let otherLabel = try makeLabel(repository: otherForge)

        XCTAssertThrowsError(
            try makePullRequestSummary(repository: repository, author: .available(.actor(otherActor)))
        )
        XCTAssertThrowsError(
            try makePullRequestSummary(repository: repository, headRepository: otherForge)
        )
        XCTAssertThrowsError(
            try makePullRequestSummary(
                repository: repository,
                base: .available(makeBranch(repository: sameForgeOther))
            )
        ) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedRepository)
        }
        XCTAssertThrowsError(
            try makePullRequestSummary(repository: repository, labels: .available([otherLabel]))
        )
        XCTAssertThrowsError(
            try makePullRequestSummary(repository: repository, labels: .available([makeLabel(repository: sameForgeOther)]))
        ) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedRepository)
        }
    }

    func testPullRequestDetailsRejectEveryCrossIdentitySection() throws {
        let repository = try TestSupport.repository()
        let other = try TestSupport.repository(kind: .gitLab)
        let otherSameForge = try TestSupport.repository(owner: "other")
        let summary = try makePullRequestSummary(repository: repository)
        let unavailable = ForgeReadSection<[ForgeActor]>.unavailable(.notRequested)
        let baseArguments = try makePullRequestDetailSections(repository: repository)

        XCTAssertThrowsError(
            try makePullRequestDetails(
                summary: summary,
                assignees: .available([makeActor(repository: other)]),
                sections: baseArguments
            )
        )
        XCTAssertThrowsError(
            try makePullRequestDetails(
                summary: summary,
                assignees: unavailable,
                milestone: .available(makeMilestone(repository: otherSameForge)),
                sections: baseArguments
            )
        ) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedRepository)
        }
        XCTAssertThrowsError(
            try makePullRequestDetails(
                summary: summary,
                assignees: unavailable,
                milestone: .available(makeMilestone(repository: other)),
                sections: baseArguments
            )
        )
        XCTAssertThrowsError(
            try makePullRequestDetails(
                summary: summary,
                assignees: unavailable,
                checks: .available([makeCheck(repository: otherSameForge, state: .failed)]),
                sections: baseArguments
            )
        ) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedRepository)
        }
        XCTAssertThrowsError(
            try makePullRequestDetails(
                summary: summary,
                assignees: unavailable,
                reviewers: .available([
                    ForgeReviewer(participant: .actor(makeActor(repository: other)), isRequested: true),
                ]),
                sections: baseArguments
            )
        )
        XCTAssertThrowsError(
            try makePullRequestDetails(
                summary: summary,
                assignees: unavailable,
                linkedIssues: .available([
                    ForgeLinkedIssue(repository: other, number: ForgeItemNumber(1), state: .open, title: "Other"),
                ]),
                sections: baseArguments
            )
        )
        XCTAssertThrowsError(
            try makePullRequestDetails(
                summary: summary,
                assignees: unavailable,
                checks: .available([makeCheck(repository: other, state: .failed)]),
                sections: baseArguments
            )
        )
        XCTAssertThrowsError(
            try makePullRequestDetails(
                summary: summary,
                assignees: unavailable,
                timeline: .available(ForgePage(items: [makeTimelineItem(repository: otherSameForge)])),
                sections: baseArguments
            )
        ) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedRepository)
        }
    }

    func testIssueCompletePartialAndCrossIdentityModels() throws {
        let repository = try TestSupport.repository()
        let summary = try makeIssueSummary(repository: repository)
        let details = try ForgeIssueDetails(
            summary: summary,
            bodyMarkdown: .available("Issue body"),
            assignees: .available([makeActor(repository: repository)]),
            milestone: .available(makeMilestone(repository: repository)),
            timeline: .available(ForgePage(items: [makeTimelineItem(repository: repository)], totalCount: 1))
        )
        XCTAssertEqual(try roundTrip(details), details)

        let partialSummary = try makeIssueSummary(
            repository: repository,
            author: .available(.deleted),
            labels: .unavailable(.partialResponse)
        )
        let partial = try ForgeIssueDetails(
            summary: partialSummary,
            bodyMarkdown: .unavailable(.partialResponse),
            assignees: .unavailable(.permissionDenied),
            milestone: .available(nil),
            timeline: .unavailable(.notRequested)
        )
        XCTAssertEqual(try roundTrip(partial), partial)

        let other = try TestSupport.repository(kind: .gitLab)
        let otherSameForge = try TestSupport.repository(owner: "other")
        XCTAssertThrowsError(
            try makeIssueSummary(repository: repository, author: .available(.actor(makeActor(repository: other))))
        )
        XCTAssertThrowsError(
            try makeIssueSummary(repository: repository, labels: .available([makeLabel(repository: other)]))
        )
        XCTAssertThrowsError(
            try makeIssueSummary(repository: repository, labels: .available([makeLabel(repository: otherSameForge)]))
        ) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedRepository)
        }
        XCTAssertThrowsError(
            try ForgeIssueDetails(
                summary: summary,
                bodyMarkdown: .available(""),
                assignees: .available([makeActor(repository: other)]),
                milestone: .available(nil),
                timeline: .unavailable(.notRequested)
            )
        )
        XCTAssertThrowsError(
            try ForgeIssueDetails(
                summary: summary,
                bodyMarkdown: .available(""),
                assignees: .available([]),
                milestone: .available(makeMilestone(repository: otherSameForge)),
                timeline: .unavailable(.notRequested)
            )
        ) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedRepository)
        }
        XCTAssertThrowsError(
            try ForgeIssueDetails(
                summary: summary,
                bodyMarkdown: .available(""),
                assignees: .available([]),
                milestone: .available(makeMilestone(repository: other)),
                timeline: .unavailable(.notRequested)
            )
        )
        XCTAssertThrowsError(
            try ForgeIssueDetails(
                summary: summary,
                bodyMarkdown: .available(""),
                assignees: .available([]),
                milestone: .available(nil),
                timeline: .available(ForgePage(items: [makeTimelineItem(repository: otherSameForge)]))
            )
        )
    }

    private func makeActor(
        repository: ForgeRepositoryIdentity,
        kind: ForgeActorKind = .person
    ) throws -> ForgeActor {
        try ForgeActor(
            id: ForgeObjectID(forge: repository.forge, value: "actor-\(kind.rawValue)"),
            login: "octo-\(kind.rawValue)",
            displayName: "Octo Person",
            avatarURL: URL(string: "https://avatars.githubusercontent.com/u/1"),
            kind: kind
        )
    }

    private func makeTeam(repository: ForgeRepositoryIdentity) throws -> ForgeTeam {
        try ForgeTeam(
            id: ForgeObjectID(forge: repository.forge, value: "team-core"),
            name: "Core Team",
            slug: "core",
            avatarURL: URL(string: "https://avatars.githubusercontent.com/t/1")
        )
    }

    private func makeLabel(repository: ForgeRepositoryIdentity) throws -> ForgeLabel {
        try ForgeLabel(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: "label-bug"),
            name: "bug",
            description: "Something is wrong",
            color: ForgeLabelColor("ff0000")
        )
    }

    private func makeMilestone(repository: ForgeRepositoryIdentity) throws -> ForgeMilestone {
        try ForgeMilestone(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: "milestone-1"),
            number: 1,
            title: "1.0",
            description: "First release",
            state: .open,
            dueAt: timestamp
        )
    }

    private func makeBranch(repository: ForgeRepositoryIdentity) -> ForgeBranchReference {
        ForgeBranchReference(repository: repository, name: TestSupport.main, commit: TestSupport.commit)
    }

    private func makeCheck(
        repository: ForgeRepositoryIdentity,
        state: ForgeCheckState
    ) throws -> ForgeCheck {
        try ForgeCheck(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: "check-\(state.rawValue)"),
            kind: .check,
            name: "Tests",
            summary: "Summary",
            state: state,
            detailsURL: URL(string: "https://ci.example.test/check"),
            startedAt: timestamp,
            completedAt: timestamp.addingTimeInterval(5)
        )
    }

    private func makeTimelineItem(repository: ForgeRepositoryIdentity) throws -> ForgeTimelineItem {
        try ForgeTimelineItem(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: "timeline-1"),
            occurredAt: timestamp,
            actor: .actor(makeActor(repository: repository)),
            event: .comment(bodyMarkdown: "Hello", updatedAt: nil)
        )
    }

    private func makePullRequestSummary(
        repository: ForgeRepositoryIdentity,
        headRepository: ForgeRepositoryIdentity? = nil,
        author: ForgeReadSection<ForgeAuthor>? = nil,
        head: ForgeReadSection<ForgeBranchReference>? = nil,
        base: ForgeReadSection<ForgeBranchReference>? = nil,
        labels: ForgeReadSection<[ForgeLabel]>? = nil
    ) throws -> ForgePullRequestSummary {
        try ForgePullRequestSummary(
            repository: repository,
            number: ForgeItemNumber(7),
            state: .open,
            isDraft: false,
            title: "Improve collaboration",
            author: author ?? .available(.actor(makeActor(repository: repository))),
            head: head ?? .available(makeBranch(repository: headRepository ?? repository)),
            base: base ?? .available(makeBranch(repository: repository)),
            createdAt: timestamp,
            updatedAt: timestamp.addingTimeInterval(10),
            labels: labels ?? .available([makeLabel(repository: repository)]),
            checkRollup: .available(.succeeded),
            reviewRollup: .available(.approved)
        )
    }

    private func makeIssueSummary(
        repository: ForgeRepositoryIdentity,
        author: ForgeReadSection<ForgeAuthor>? = nil,
        labels: ForgeReadSection<[ForgeLabel]>? = nil
    ) throws -> ForgeIssueSummary {
        try ForgeIssueSummary(
            repository: repository,
            number: ForgeItemNumber(3),
            state: .closed,
            title: "Issue",
            author: author ?? .available(.actor(makeActor(repository: repository))),
            createdAt: timestamp,
            updatedAt: timestamp.addingTimeInterval(10),
            closedAt: timestamp.addingTimeInterval(9),
            labels: labels ?? .available([makeLabel(repository: repository)])
        )
    }

    private struct PullRequestDetailSections {
        let milestone: ForgeReadSection<ForgeMilestone?>
        let reviewers: ForgeReadSection<[ForgeReviewer]>
        let linkedIssues: ForgeReadSection<[ForgeLinkedIssue]>
        let checks: ForgeReadSection<[ForgeCheck]>
        let timeline: ForgeReadSection<ForgePage<ForgeTimelineItem>>
    }

    private func makePullRequestDetailSections(
        repository: ForgeRepositoryIdentity
    ) throws -> PullRequestDetailSections {
        try PullRequestDetailSections(
            milestone: .available(nil),
            reviewers: .available([]),
            linkedIssues: .available([]),
            checks: .available([]),
            timeline: .available(ForgePage(items: []))
        )
    }

    private func makePullRequestDetails(
        summary: ForgePullRequestSummary,
        assignees: ForgeReadSection<[ForgeActor]>,
        milestone: ForgeReadSection<ForgeMilestone?>? = nil,
        reviewers: ForgeReadSection<[ForgeReviewer]>? = nil,
        linkedIssues: ForgeReadSection<[ForgeLinkedIssue]>? = nil,
        checks: ForgeReadSection<[ForgeCheck]>? = nil,
        timeline: ForgeReadSection<ForgePage<ForgeTimelineItem>>? = nil,
        sections: PullRequestDetailSections
    ) throws -> ForgePullRequestDetails {
        try ForgePullRequestDetails(
            summary: summary,
            bodyMarkdown: .available(""),
            assignees: assignees,
            milestone: milestone ?? sections.milestone,
            reviewers: reviewers ?? sections.reviewers,
            linkedIssues: linkedIssues ?? sections.linkedIssues,
            mergeability: .available(.unknown),
            checks: checks ?? sections.checks,
            timeline: timeline ?? sections.timeline
        )
    }

    private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func replacingJSONValue<Value: Encodable>(
        in value: Value,
        key: String,
        value replacement: Any
    ) throws -> Data {
        var object = try XCTUnwrap(jsonObject(value) as? [String: Any])
        object[key] = replacement
        return try JSONSerialization.data(withJSONObject: object)
    }
}
