@_spi(Unsafe) import ApolloAPI
import ForgeKit
import Foundation

struct GitHubMappedValue<Value> {
    let value: Value
    let isPartial: Bool
    let accessEvidence: ForgeRepositoryAccessEvidence?

    init(value: Value, isPartial: Bool, accessEvidence: ForgeRepositoryAccessEvidence? = nil) {
        self.value = value
        self.isPartial = isPartial
        self.accessEvidence = accessEvidence
    }
}

struct GitHubGraphQLDocumentMapper {
    let forge: ForgeIdentity

    func repositoryFacts(
        data: GitHubAPI.GitHubRepositoryFactsQuery.Data,
        expectedRepository: ForgeRepositoryIdentity,
        credential: ForgeCredentialReference
    ) throws -> GitHubMappedValue<ForgeRepositoryFacts> {
        guard let node = data.repository else { throw GitHubReadError.repositoryNotFound }
        try validateRepository(node.fragments.gitHubRepositoryIdentity, expected: expectedRepository)
        let topics = try completeValues(
            nodes: node.repositoryTopics.nodes,
            totalCount: node.repositoryTopics.totalCount,
            pageInfo: node.repositoryTopics.pageInfo.fragments.gitHubPageInfo
        ) { $0.topic.name }
        let forkRelationship: ForgeReadSection<ForgeForkRelationship>
        if !node.isFork {
            forkRelationship = .available(.standalone)
        } else if let parent = node.parent {
            forkRelationship = try .available(.fork(parent: repository(parent.fragments.gitHubRepositoryIdentity)))
        } else {
            forkRelationship = .unavailable(.partialResponse)
        }
        let role = repositoryRole(node.viewerPermission?.value)
        let access = try GitHubCapabilityMapper.repositoryAccessEvidence(
            credential: credential,
            repository: expectedRepository,
            viewerPermission: node.viewerPermission?.value?.rawValue
        )
        let value = try ForgeRepositoryFacts(
            repository: expectedRepository,
            defaultBranch: node.defaultBranchRef.map { try .available(ForgeRefName($0.name)) }
                ?? .unavailable(.partialResponse),
            description: .available(node.description),
            topics: topics.section,
            visibility: .available(repositoryVisibility(node.visibility.value)),
            isArchived: .available(node.isArchived),
            forkRelationship: forkRelationship,
            viewerCapabilities: .available(ForgeRepositoryViewerCapabilities(
                role: role,
                canAdminister: node.viewerCanAdminister,
                canCreateIssues: node.viewerCanCreateIssues,
                canUpdateTopics: node.viewerCanUpdateTopics
            ))
        )
        return GitHubMappedValue(
            value: value,
            isPartial: topics.isPartial || forkRelationship.isUnavailable,
            accessEvidence: access
        )
    }

    func pullRequestList(
        data: GitHubAPI.GitHubPullRequestListQuery.Data,
        repository: ForgeRepositoryIdentity
    ) throws -> GitHubMappedValue<ForgePage<ForgePullRequestSummary>> {
        guard let repositoryNode = data.repository else { throw GitHubReadError.repositoryNotFound }
        let connection = repositoryNode.pullRequests
        let mapped = try mapNodes(connection.nodes) {
            try pullRequestSummary($0.fragments.gitHubPullRequestSummary, repository: repository)
        }
        let page = try pageMapping(
            items: mapped.values,
            totalCount: connection.totalCount,
            pageInfo: connection.pageInfo.fragments.gitHubPageInfo,
            hasDroppedNodes: mapped.isPartial
        )
        return GitHubMappedValue(
            value: page.value,
            isPartial: page.isPartial || mapped.values.contains(where: pullRequestSummaryIsPartial)
        )
    }

    func issueList(
        data: GitHubAPI.GitHubIssueListQuery.Data,
        repository: ForgeRepositoryIdentity
    ) throws -> GitHubMappedValue<ForgePage<ForgeIssueSummary>> {
        guard let repositoryNode = data.repository else { throw GitHubReadError.repositoryNotFound }
        let connection = repositoryNode.issues
        let mapped = try mapNodes(connection.nodes) {
            try issueSummary($0.fragments.gitHubIssueSummary, repository: repository)
        }
        let page = try pageMapping(
            items: mapped.values,
            totalCount: connection.totalCount,
            pageInfo: connection.pageInfo.fragments.gitHubPageInfo,
            hasDroppedNodes: mapped.isPartial
        )
        return GitHubMappedValue(
            value: page.value,
            isPartial: page.isPartial || mapped.values.contains(where: issueSummaryIsPartial)
        )
    }

    func historyOverlay(
        data: GitHubAPI.GitHubHistoryOverlayQuery.Data,
        repository: ForgeRepositoryIdentity,
        commit expectedCommit: ForgeCommitID
    ) throws -> GitHubMappedValue<ForgeHistoryOverlay> {
        guard let repositoryNode = data.repository else { throw GitHubReadError.repositoryNotFound }
        guard let commit = repositoryNode.object?.asCommit else { throw GitHubReadError.objectNotFound }
        guard try ForgeCommitID(commit.oid) == expectedCommit else { throw GitHubReadError.malformedResponse }
        let checkRollup = checkRollupSection(commit.statusCheckRollup?.state.value)
        let pullRequests: ForgeReadSection<ForgePage<ForgePullRequestSummary>>
        let pullRequestPartial: Bool
        if let connection = commit.associatedPullRequests {
            let mapped = try mapNodes(connection.nodes) {
                try pullRequestSummary($0.fragments.gitHubPullRequestSummary, repository: repository)
            }
            let page = try pageMapping(
                items: mapped.values,
                totalCount: connection.totalCount,
                pageInfo: connection.pageInfo.fragments.gitHubPageInfo,
                hasDroppedNodes: mapped.isPartial
            )
            pullRequests = .available(page.value)
            pullRequestPartial = page.isPartial
                || mapped.values.contains(where: pullRequestSummaryIsPartial)
        } else {
            pullRequests = .unavailable(.partialResponse)
            pullRequestPartial = true
        }
        return GitHubMappedValue(
            value: ForgeHistoryOverlay(
                repository: repository,
                commit: expectedCommit,
                checkRollup: checkRollup,
                pullRequests: pullRequests
            ),
            isPartial: checkRollup.isUnavailable || pullRequestPartial
        )
    }

    func repositoryItemSearch(
        data: GitHubAPI.GitHubRepositoryItemSearchQuery.Data,
        repository expectedRepository: ForgeRepositoryIdentity
    ) throws -> GitHubMappedValue<ForgePage<ForgeRepositoryItem>> {
        let connection = data.search
        let mapped = try mapNodes(connection.nodes) { node -> ForgeRepositoryItem? in
            if let pullRequest = node.asPullRequest {
                try validateRepository(
                    pullRequest.repository.fragments.gitHubRepositoryIdentity,
                    expected: expectedRepository
                )
                let summary = try pullRequestSummary(
                    pullRequest.fragments.gitHubPullRequestSummary,
                    repository: expectedRepository
                )
                guard case let .available(base) = summary.base,
                      base.repository == expectedRepository
                else { throw GitHubReadError.malformedResponse }
                return .pullRequest(summary)
            }
            if let issue = node.asIssue {
                try validateRepository(
                    issue.repository.fragments.gitHubRepositoryIdentity,
                    expected: expectedRepository
                )
                return try .issue(issueSummary(issue.fragments.gitHubIssueSummary, repository: expectedRepository))
            }
            return nil
        }
        let page = try pageMapping(
            items: mapped.values,
            totalCount: connection.totalCount,
            pageInfo: connection.pageInfo.fragments.gitHubPageInfo,
            hasDroppedNodes: mapped.isPartial
        )
        return GitHubMappedValue(
            value: page.value,
            isPartial: page.isPartial || mapped.values.contains(where: repositoryItemIsPartial)
        )
    }

    func pullRequestDetails(
        data: GitHubAPI.GitHubPullRequestDetailsQuery.Data,
        repository: ForgeRepositoryIdentity
    ) throws -> GitHubMappedValue<ForgePullRequestDetailsPage> {
        guard let repositoryNode = data.repository else { throw GitHubReadError.repositoryNotFound }
        guard let pullRequest = repositoryNode.pullRequest else { throw GitHubReadError.objectNotFound }
        let summary = try pullRequestSummary(
            pullRequest.fragments.gitHubPullRequestSummary,
            repository: repository
        )
        let assignees = try completeValues(
            nodes: pullRequest.assignedActors.nodes,
            totalCount: pullRequest.assignedActors.totalCount,
            pageInfo: pullRequest.assignedActors.pageInfo.fragments.gitHubPageInfo
        ) { try assignee($0.fragments.gitHubAssignee) }
        let milestoneSection: ForgeReadSection<ForgeMilestone?> = try .available(
            pullRequest.milestone.map {
                try milestone($0.fragments.gitHubMilestone, repository: repository)
            }
        )
        let reviewers = try reviewers(pullRequest)
        let linkedIssues = try linkedIssues(pullRequest, repository: repository)
        let checkMapping = try checks(pullRequest.statusCheckRollup, repository: repository)
        let timelineMapping = try pullRequestTimeline(pullRequest.timelineItems, repository: repository)
        let details = try ForgePullRequestDetails(
            summary: summary,
            bodyMarkdown: .available(pullRequest.body),
            assignees: assignees.section,
            milestone: milestoneSection,
            reviewers: reviewers.section,
            linkedIssues: linkedIssues.section,
            mergeability: .available(mergeability(pullRequest.mergeable.value)),
            checks: checkMapping.section,
            timeline: timelineMapping.section
        )
        return GitHubMappedValue(
            value: ForgePullRequestDetailsPage(
                details: details,
                nextCheckCursor: checkMapping.nextCursor
            ),
            isPartial: pullRequestSummaryIsPartial(summary)
                || assignees.isPartial || reviewers.isPartial || linkedIssues.isPartial
                || checkMapping.isPartial || timelineMapping.isPartial
        )
    }

    func issueDetails(
        data: GitHubAPI.GitHubIssueDetailsQuery.Data,
        repository: ForgeRepositoryIdentity
    ) throws -> GitHubMappedValue<ForgeIssueDetails> {
        guard let repositoryNode = data.repository else { throw GitHubReadError.repositoryNotFound }
        guard let issue = repositoryNode.issue else { throw GitHubReadError.objectNotFound }
        let summary = try issueSummary(issue.fragments.gitHubIssueSummary, repository: repository)
        let assignees = try completeValues(
            nodes: issue.assignedActors.nodes,
            totalCount: issue.assignedActors.totalCount,
            pageInfo: issue.assignedActors.pageInfo.fragments.gitHubPageInfo
        ) { try assignee($0.fragments.gitHubAssignee) }
        let timeline = try issueTimeline(issue.timelineItems, repository: repository)
        let details = try ForgeIssueDetails(
            summary: summary,
            bodyMarkdown: .available(issue.body),
            assignees: assignees.section,
            milestone: .available(issue.milestone.map {
                try milestone($0.fragments.gitHubMilestone, repository: repository)
            }),
            timeline: timeline.section
        )
        return GitHubMappedValue(
            value: details,
            isPartial: issueSummaryIsPartial(summary) || assignees.isPartial || timeline.isPartial
        )
    }

    func reviewThreads(
        data: GitHubAPI.GitHubPullRequestReviewThreadsQuery.Data,
        repository: ForgeRepositoryIdentity
    ) throws -> GitHubMappedValue<ForgePage<ForgeReviewThread>> {
        guard let repositoryNode = data.repository else { throw GitHubReadError.repositoryNotFound }
        guard let pullRequest = repositoryNode.pullRequest else { throw GitHubReadError.objectNotFound }
        let connection = pullRequest.reviewThreads
        let mapped = try mapNodes(connection.nodes) {
            try reviewThread($0, repository: repository)
        }
        let threads = mapped.values.map(\.value)
        let page = try pageMapping(
            items: threads,
            totalCount: connection.totalCount,
            pageInfo: connection.pageInfo.fragments.gitHubPageInfo,
            hasDroppedNodes: mapped.isPartial
        )
        return GitHubMappedValue(
            value: page.value,
            isPartial: page.isPartial || mapped.values.contains(where: \.isPartial)
        )
    }

    func reviewThreadComments(
        data: GitHubAPI.GitHubPullRequestReviewThreadCommentsQuery.Data,
        repository: ForgeRepositoryIdentity
    ) throws -> GitHubMappedValue<ForgePage<ForgeReviewComment>> {
        guard let thread = data.node?.asPullRequestReviewThread else {
            throw GitHubReadError.objectNotFound
        }
        try validateRepository(
            thread.pullRequest.repository.fragments.gitHubRepositoryIdentity,
            expected: repository
        )
        let connection = thread.comments
        let mapped = try mapNodes(connection.nodes) {
            try reviewComment($0.fragments.gitHubReviewComment, repository: repository)
        }
        let page = try pageMapping(
            items: mapped.values,
            totalCount: connection.totalCount,
            pageInfo: connection.pageInfo.fragments.gitHubPageInfo,
            hasDroppedNodes: mapped.isPartial
        )
        return GitHubMappedValue(
            value: page.value,
            isPartial: page.isPartial
        )
    }

    func attentionCandidates(
        data: GitHubAPI.GitHubAttentionCandidatesQuery.Data,
        repository: ForgeRepositoryIdentity
    ) throws -> GitHubMappedValue<ForgeAttentionCandidatePage> {
        guard let viewer = try actor(data.viewer.fragments.gitHubActor) else {
            throw GitHubReadError.malformedResponse
        }
        let connection = data.search
        let mapped = try mapNodes(connection.nodes) { node -> ForgeAttentionCandidate? in
            if let pullRequest = node.asPullRequest {
                try validateRepository(
                    pullRequest.repository.fragments.gitHubRepositoryIdentity,
                    expected: repository
                )
                return try attentionPullRequest(pullRequest, repository: repository)
            }
            if let issue = node.asIssue {
                try validateRepository(
                    issue.repository.fragments.gitHubRepositoryIdentity,
                    expected: repository
                )
                return try attentionIssue(issue, repository: repository)
            }
            return nil
        }
        let page = try pageMapping(
            items: mapped.values,
            totalCount: connection.totalCount,
            pageInfo: connection.pageInfo.fragments.gitHubPageInfo,
            hasDroppedNodes: mapped.isPartial
        )
        return GitHubMappedValue(
            value: ForgeAttentionCandidatePage(viewer: viewer, candidates: page.value),
            isPartial: page.isPartial || mapped.values.contains(where: attentionCandidateIsPartial)
        )
    }
}

private extension GitHubGraphQLDocumentMapper {
    struct NodeMapping<Value> {
        let values: [Value]
        let isPartial: Bool
    }

    struct PageMapping<Value: Codable & Hashable & Sendable> {
        let value: ForgePage<Value>
        let isPartial: Bool
    }

    struct ReviewThreadMapping {
        let value: ForgeReviewThread
        let isPartial: Bool
    }

    struct SectionMapping<Value: Codable & Hashable & Sendable> {
        let section: ForgeReadSection<Value>
        let isPartial: Bool
    }

    struct CursorSectionMapping<Value: Codable & Hashable & Sendable> {
        let section: ForgeReadSection<Value>
        let nextCursor: ForgePageCursor?
        let isPartial: Bool
    }

    func objectID(_ value: String) throws -> ForgeObjectID {
        try ForgeObjectID(forge: forge, value: value)
    }

    func repository(_ fragment: GitHubAPI.GitHubRepositoryIdentity) throws -> ForgeRepositoryIdentity {
        try ForgeRepositoryIdentity(forge: forge, owner: fragment.owner.login, name: fragment.name)
    }

    func validateRepository(
        _ fragment: GitHubAPI.GitHubRepositoryIdentity,
        expected: ForgeRepositoryIdentity
    ) throws {
        guard try repository(fragment) == expected else { throw GitHubReadError.malformedResponse }
    }

    func mapNodes<Node, Value>(
        _ nodes: [Node?]?,
        transform: (Node) throws -> Value?
    ) throws -> NodeMapping<Value> {
        guard let nodes else { return NodeMapping(values: [], isPartial: true) }
        var values: [Value] = []
        var isPartial = false
        for node in nodes {
            guard let node, let value = try transform(node) else {
                isPartial = true
                continue
            }
            values.append(value)
        }
        return NodeMapping(values: values, isPartial: isPartial)
    }

    func page<Value: Codable & Hashable & Sendable>(
        items: [Value],
        totalCount: Int,
        pageInfo: GitHubAPI.GitHubPageInfo
    ) throws -> ForgePage<Value> {
        let nextCursor: ForgePageCursor?
        if pageInfo.hasNextPage {
            guard let endCursor = pageInfo.endCursor else { throw GitHubReadError.malformedResponse }
            nextCursor = try ForgePageCursor(endCursor)
        } else {
            nextCursor = nil
        }
        return try ForgePage(items: items, nextCursor: nextCursor, totalCount: totalCount)
    }

    func pageMapping<Value: Codable & Hashable & Sendable>(
        items: [Value],
        totalCount: Int,
        pageInfo: GitHubAPI.GitHubPageInfo,
        hasDroppedNodes: Bool
    ) throws -> PageMapping<Value> {
        let value = try page(items: items, totalCount: totalCount, pageInfo: pageInfo)
        return PageMapping(
            value: value,
            isPartial: hasDroppedNodes || connectionCountIsInconsistent(
                mappedCount: items.count,
                totalCount: totalCount,
                pageInfo: pageInfo
            )
        )
    }

    func connectionCountIsInconsistent(
        mappedCount: Int,
        totalCount: Int,
        pageInfo: GitHubAPI.GitHubPageInfo
    ) -> Bool {
        if totalCount < mappedCount {
            return true
        }
        return !pageInfo.hasPreviousPage && !pageInfo.hasNextPage
            && totalCount != mappedCount
    }

    func completeValues<Node, Value: Codable & Hashable & Sendable>(
        nodes: [Node?]?,
        totalCount: Int,
        pageInfo: GitHubAPI.GitHubPageInfo,
        transform: (Node) throws -> Value?
    ) throws -> SectionMapping<[Value]> {
        let mapped = try mapNodes(nodes, transform: transform)
        guard !pageInfo.hasNextPage,
              !pageInfo.hasPreviousPage,
              !mapped.isPartial,
              mapped.values.count == totalCount
        else {
            return SectionMapping(section: .unavailable(.partialResponse), isPartial: true)
        }
        return SectionMapping(section: .available(mapped.values), isPartial: false)
    }

    func date(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) {
            return parsed
        }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        guard let parsed = whole.date(from: value) else { throw GitHubReadError.malformedResponse }
        return parsed
    }

    func optionalDate(_ value: String?) throws -> Date? {
        try value.map(date)
    }

    func repositoryVisibility(_ value: GitHubAPI.RepositoryVisibility?) -> ForgeRepositoryVisibility {
        switch value {
        case .public: .public
        case .private: .private
        case .internal: .internal
        case nil: .unknown
        }
    }

    func repositoryRole(_ value: GitHubAPI.RepositoryPermission?) -> ForgeRepositoryRoleEvidence {
        switch value {
        case .read: .known(.read)
        case .triage: .known(.triage)
        case .write: .known(.write)
        case .maintain: .known(.maintain)
        case .admin: .known(.admin)
        case nil: .unknown
        }
    }

    func checkRollup(_ value: GitHubAPI.StatusState?) -> ForgeCheckRollup? {
        switch value {
        case .success: .succeeded
        case .failure, .error: .failed
        case .pending, .expected: .running
        case nil: nil
        }
    }

    func checkRollupSection(_ value: GitHubAPI.StatusState?) -> ForgeReadSection<ForgeCheckRollup> {
        guard let value = checkRollup(value) else { return .unavailable(.partialResponse) }
        return .available(value)
    }

    func actor(_ fragment: GitHubAPI.GitHubActor) throws -> ForgeActor? {
        guard let id = fragment.asNode?.id else { return nil }
        let kind: ForgeActorKind
        let displayName: String?
        if let user = fragment.asUser {
            kind = .person
            displayName = user.name
        } else if let organization = fragment.asOrganization {
            kind = .organization
            displayName = organization.name
        } else if fragment.__typename == "Bot" {
            kind = .bot
            displayName = nil
        } else {
            kind = .unknown
            displayName = nil
        }
        return try ForgeActor(
            id: objectID(id),
            login: fragment.login,
            displayName: displayName,
            avatarURL: URL(string: fragment.avatarUrl),
            kind: kind
        )
    }

    func author(_ fragment: GitHubAPI.GitHubActor?) throws -> ForgeReadSection<ForgeAuthor> {
        guard let fragment else { return .available(.deleted) }
        guard let actor = try actor(fragment) else { return .unavailable(.partialResponse) }
        return .available(.actor(actor))
    }

    func timelineAuthor(_ fragment: GitHubAPI.GitHubActor?) throws -> ForgeAuthor? {
        guard let fragment else { return nil }
        guard let value = try actor(fragment) else { throw GitHubReadError.malformedResponse }
        return .actor(value)
    }

    func assignee(_ fragment: GitHubAPI.GitHubAssignee) throws -> ForgeActor? {
        if let mannequin = fragment.asMannequin {
            return try ForgeActor(
                id: objectID(mannequin.mannequinID),
                login: mannequin.mannequinLogin,
                avatarURL: URL(string: mannequin.mannequinAvatarURL),
                kind: .unknown
            )
        }
        if let actorFragment = fragment.asActor?.fragments.gitHubActor {
            return try actor(actorFragment)
        }
        return nil
    }

    func reviewParticipant(_ fragment: GitHubAPI.GitHubRequestedReviewer) throws -> ForgeReviewParticipant? {
        if let mannequin = fragment.asMannequin {
            return try .actor(ForgeActor(
                id: objectID(mannequin.mannequinID),
                login: mannequin.mannequinLogin,
                avatarURL: URL(string: mannequin.mannequinAvatarURL),
                kind: .unknown
            ))
        }
        if let actorFragment = fragment.asActor?.fragments.gitHubActor,
           let mappedActor = try actor(actorFragment)
        {
            return .actor(mappedActor)
        }
        if let team = fragment.asTeam {
            return try .team(ForgeTeam(
                id: objectID(team.teamID),
                name: team.teamName,
                slug: team.teamSlug,
                avatarURL: team.teamAvatarURL.flatMap(URL.init(string:))
            ))
        }
        return nil
    }

    func milestone(
        _ fragment: GitHubAPI.GitHubMilestone,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeMilestone {
        let state: ForgeMilestoneState
        switch fragment.state.value {
        case .open: state = .open
        case .closed: state = .closed
        case nil: throw GitHubReadError.malformedResponse
        }
        return try ForgeMilestone(
            repository: repository,
            id: objectID(fragment.id),
            number: fragment.number,
            title: fragment.title,
            description: fragment.description,
            state: state,
            dueAt: optionalDate(fragment.dueOn)
        )
    }

    func reviewState(_ state: GitHubAPI.PullRequestReviewState?) -> ForgeReviewState? {
        switch state {
        case .approved: .approved
        case .changesRequested: .changesRequested
        case .commented: .commented
        case .dismissed: .dismissed
        case .pending, nil: nil
        }
    }

    func mergeability(_ state: GitHubAPI.MergeableState?) -> ForgeMergeability {
        switch state {
        case .mergeable: .mergeable
        case .conflicting: .conflicting
        case .unknown, nil: .unknown
        }
    }

    func reviewers(
        _ pullRequest: GitHubAPI.GitHubPullRequestDetailsQuery.Data.Repository.PullRequest
    ) throws -> SectionMapping<[ForgeReviewer]> {
        guard let requests = pullRequest.reviewRequests,
              let latest = pullRequest.latestReviews
        else {
            return SectionMapping(section: .unavailable(.partialResponse), isPartial: true)
        }
        let requested = try mapNodes(requests.nodes) { node -> ForgeReviewer? in
            guard let reviewer = node.requestedReviewer,
                  let participant = try reviewParticipant(reviewer.fragments.gitHubRequestedReviewer)
            else { return nil }
            return ForgeReviewer(participant: participant, isRequested: true)
        }
        let reviewed = try mapNodes(latest.nodes) { node -> ForgeReviewer? in
            guard let authorFragment = node.author?.fragments.gitHubActor,
                  let mappedActor = try actor(authorFragment)
            else { return nil }
            return ForgeReviewer(
                participant: .actor(mappedActor),
                isRequested: false,
                latestReviewState: reviewState(node.state.value)
            )
        }
        guard connectionIsComplete(
            mappedCount: requested.values.count,
            totalCount: requests.totalCount,
            pageInfo: requests.pageInfo.fragments.gitHubPageInfo,
            hasDroppedNodes: requested.isPartial
        ), connectionIsComplete(
            mappedCount: reviewed.values.count,
            totalCount: latest.totalCount,
            pageInfo: latest.pageInfo.fragments.gitHubPageInfo,
            hasDroppedNodes: reviewed.isPartial
        ) else {
            return SectionMapping(section: .unavailable(.partialResponse), isPartial: true)
        }
        var values = requested.values
        for latestReviewer in reviewed.values {
            if let index = values.firstIndex(where: {
                $0.participant == latestReviewer.participant
            }) {
                values[index] = ForgeReviewer(
                    participant: latestReviewer.participant,
                    isRequested: true,
                    latestReviewState: latestReviewer.latestReviewState
                )
            } else {
                values.append(latestReviewer)
            }
        }
        return SectionMapping(section: .available(values), isPartial: false)
    }

    func linkedIssues(
        _ pullRequest: GitHubAPI.GitHubPullRequestDetailsQuery.Data.Repository.PullRequest,
        repository expectedRepository: ForgeRepositoryIdentity
    ) throws -> SectionMapping<[ForgeLinkedIssue]> {
        guard let connection = pullRequest.closingIssuesReferences else {
            return SectionMapping(section: .unavailable(.partialResponse), isPartial: true)
        }
        return try completeValues(
            nodes: connection.nodes,
            totalCount: connection.totalCount,
            pageInfo: connection.pageInfo.fragments.gitHubPageInfo
        ) { node in
            let linkedRepository = try repository(
                node.repository.fragments.gitHubRepositoryIdentity
            )
            let state: ForgeIssueState
            switch node.state.value {
            case .open: state = .open
            case .closed: state = .closed
            case nil: throw GitHubReadError.malformedResponse
            }
            return try ForgeLinkedIssue(
                repository: linkedRepository,
                number: ForgeItemNumber(node.number),
                state: state,
                title: node.title
            )
        }
    }

    func connectionIsComplete(
        mappedCount: Int,
        totalCount: Int,
        pageInfo: GitHubAPI.GitHubPageInfo,
        hasDroppedNodes: Bool
    ) -> Bool {
        !pageInfo.hasNextPage && !pageInfo.hasPreviousPage
            && !hasDroppedNodes && mappedCount == totalCount
    }

    func checks(
        _ rollup: GitHubAPI.GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.StatusCheckRollup?,
        repository: ForgeRepositoryIdentity
    ) throws -> CursorSectionMapping<[ForgeCheck]> {
        guard let rollup else {
            return CursorSectionMapping(
                section: .unavailable(.partialResponse),
                nextCursor: nil,
                isPartial: true
            )
        }
        let connection = rollup.contexts
        let mapped = try mapNodes(connection.nodes) { node -> ForgeCheck? in
            if let run = node.asCheckRun {
                guard let state = checkRunState(
                    status: run.status.value,
                    conclusion: run.conclusion?.value
                ) else { return nil }
                return try ForgeCheck(
                    repository: repository,
                    id: objectID(run.id),
                    kind: .check,
                    name: run.name,
                    summary: run.summary,
                    state: state,
                    detailsURL: run.detailsUrl.flatMap(URL.init(string:)),
                    startedAt: optionalDate(run.startedAt),
                    completedAt: optionalDate(run.completedAt)
                )
            }
            if let status = node.asStatusContext {
                guard let state = statusContextState(status.state.value) else { return nil }
                return try ForgeCheck(
                    repository: repository,
                    id: objectID(status.id),
                    kind: .commitStatus,
                    name: status.context,
                    summary: status.description,
                    state: state,
                    detailsURL: status.targetUrl.flatMap(URL.init(string:)),
                    startedAt: date(status.createdAt),
                    completedAt: date(status.updatedAt)
                )
            }
            return nil
        }
        guard !mapped.isPartial,
              !connectionCountIsInconsistent(
                  mappedCount: mapped.values.count,
                  totalCount: connection.totalCount,
                  pageInfo: connection.pageInfo.fragments.gitHubPageInfo
              )
        else {
            return try CursorSectionMapping(
                section: .unavailable(.partialResponse),
                nextCursor: nextCursor(connection.pageInfo.fragments.gitHubPageInfo),
                isPartial: true
            )
        }
        let next = try nextCursor(connection.pageInfo.fragments.gitHubPageInfo)
        return CursorSectionMapping(
            section: .available(mapped.values),
            nextCursor: next,
            isPartial: next != nil
        )
    }

    func checkRunState(
        status: GitHubAPI.CheckStatusState?,
        conclusion: GitHubAPI.CheckConclusionState?
    ) -> ForgeCheckState? {
        guard let status else { return nil }
        guard status == .completed else { return .running }
        switch conclusion {
        case .success: return .succeeded
        case .neutral, .skipped: return .neutral
        case .actionRequired: return .attentionRequired
        case .cancelled, .failure, .stale, .startupFailure, .timedOut: return .failed
        case nil: return nil
        }
    }

    func statusContextState(_ state: GitHubAPI.StatusState?) -> ForgeCheckState? {
        switch state {
        case .success: .succeeded
        case .failure, .error: .failed
        case .pending, .expected: .running
        case nil: nil
        }
    }

    func nextCursor(_ pageInfo: GitHubAPI.GitHubPageInfo) throws -> ForgePageCursor? {
        guard pageInfo.hasNextPage else { return nil }
        guard let endCursor = pageInfo.endCursor else { throw GitHubReadError.malformedResponse }
        return try ForgePageCursor(endCursor)
    }

    func pullRequestTimeline(
        _ connection: GitHubAPI.GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems,
        repository: ForgeRepositoryIdentity
    ) throws -> CursorSectionMapping<ForgePage<ForgeTimelineItem>> {
        let mapped = try mapNodes(connection.nodes) {
            try pullRequestTimelineItem($0, repository: repository)
        }
        let page = try pageMapping(
            items: mapped.values,
            totalCount: connection.totalCount,
            pageInfo: connection.pageInfo.fragments.gitHubPageInfo,
            hasDroppedNodes: mapped.isPartial
        )
        return CursorSectionMapping(
            section: .available(page.value),
            nextCursor: page.value.nextCursor,
            isPartial: page.isPartial || page.value.nextCursor != nil
        )
    }

    func pullRequestTimelineItem(
        _ node: GitHubAPI.GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeTimelineItem? {
        if let comment = node.asIssueComment {
            let fragment = comment.fragments.gitHubIssueComment
            return try timelineItem(
                id: fragment.id,
                occurredAt: fragment.createdAt,
                actor: authorValue(fragment.author?.fragments.gitHubActor),
                event: .comment(
                    bodyMarkdown: fragment.body,
                    updatedAt: date(fragment.updatedAt)
                ),
                repository: repository
            )
        }
        if let review = node.asPullRequestReview,
           let state = reviewState(review.state.value),
           let submittedAt = review.submittedAt
        {
            return try timelineItem(
                id: review.id,
                occurredAt: submittedAt,
                actor: authorValue(review.author?.fragments.gitHubActor),
                event: .review(
                    state: state,
                    bodyMarkdown: review.body,
                    commit: review.commit.map { try ForgeCommitID($0.oid) }
                ),
                repository: repository
            )
        }
        if let event = node.asClosedEvent {
            return try timelineItem(event.id, event.createdAt, event.actor, .closed, repository)
        }
        if let event = node.asReopenedEvent {
            return try timelineItem(event.id, event.createdAt, event.actor, .reopened, repository)
        }
        if let event = node.asMergedEvent {
            return try timelineItem(
                event.id,
                event.createdAt,
                event.actor,
                .merged(commit: event.commit.map { try ForgeCommitID($0.oid) }),
                repository
            )
        }
        if let event = node.asAssignedEvent,
           let assigned = event.assignee,
           let mappedAssignee = try assignee(assigned.fragments.gitHubAssignee)
        {
            return try timelineItem(
                event.id, event.createdAt, event.actor, .assigned(mappedAssignee), repository
            )
        }
        if let event = node.asUnassignedEvent,
           let assigned = event.assignee,
           let mappedAssignee = try assignee(assigned.fragments.gitHubAssignee)
        {
            return try timelineItem(
                event.id, event.createdAt, event.actor, .unassigned(mappedAssignee), repository
            )
        }
        if let event = node.asLabeledEvent {
            return try timelineItem(
                event.id,
                event.createdAt,
                event.actor,
                .labeled(label(event.label.fragments.gitHubLabel, repository: repository)),
                repository
            )
        }
        if let event = node.asUnlabeledEvent {
            return try timelineItem(
                event.id,
                event.createdAt,
                event.actor,
                .unlabeled(label(event.label.fragments.gitHubLabel, repository: repository)),
                repository
            )
        }
        if let event = node.asMilestonedEvent {
            return try timelineItem(
                event.id,
                event.createdAt,
                event.actor,
                .milestoneTitleChanged(event.milestoneTitle),
                repository
            )
        }
        if let event = node.asDemilestonedEvent {
            return try timelineItem(
                event.id, event.createdAt, event.actor, .milestoneTitleChanged(nil), repository
            )
        }
        if let event = node.asRenamedTitleEvent {
            return try timelineItem(
                event.id,
                event.createdAt,
                event.actor,
                .renamed(previousTitle: event.previousTitle, currentTitle: event.currentTitle),
                repository
            )
        }
        if let event = node.asCrossReferencedEvent,
           let reference = try crossReference(event.source)
        {
            return try timelineItem(
                event.id,
                event.createdAt,
                event.actor,
                .crossReferenced(destination: reference.destination, title: reference.title),
                repository
            )
        }
        return nil
    }

    func timelineItem(
        id: String,
        occurredAt: String,
        actor: ForgeAuthor?,
        event: ForgeTimelineEvent,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeTimelineItem {
        try ForgeTimelineItem(
            repository: repository,
            id: objectID(id),
            occurredAt: date(occurredAt),
            actor: actor,
            event: event
        )
    }

    func timelineItem<Actor: SelectionSet>(
        _ id: String,
        _ occurredAt: String,
        _ actorSelection: Actor?,
        _ event: ForgeTimelineEvent,
        _ repository: ForgeRepositoryIdentity
    ) throws -> ForgeTimelineItem where Actor.Schema == GitHubAPI.SchemaMetadata {
        let fragment: GitHubAPI.GitHubActor? = actorSelection.map { GitHubAPI.GitHubActor(_dataDict: $0.__data) }
        return try timelineItem(
            id: id,
            occurredAt: occurredAt,
            actor: timelineAuthor(fragment),
            event: event,
            repository: repository
        )
    }

    func authorValue(_ fragment: GitHubAPI.GitHubActor?) throws -> ForgeAuthor {
        switch try author(fragment) {
        case let .available(value): return value
        case .unavailable: throw GitHubReadError.malformedResponse
        }
    }

    func crossReference(
        _ source: GitHubAPI.GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node
            .AsCrossReferencedEvent.Source
    ) throws -> (destination: ForgeDestination, title: String)? {
        if let pullRequest = source.asPullRequest {
            let linkedRepository = try repository(
                pullRequest.repository.fragments.gitHubRepositoryIdentity
            )
            return try (
                .pullRequest(linkedRepository, ForgeItemNumber(pullRequest.number)),
                pullRequest.title
            )
        }
        if let issue = source.asIssue {
            let linkedRepository = try repository(issue.repository.fragments.gitHubRepositoryIdentity)
            return try (.issue(linkedRepository, ForgeItemNumber(issue.number)), issue.title)
        }
        return nil
    }

    func reviewThread(
        _ node: GitHubAPI.GitHubPullRequestReviewThreadsQuery.Data.Repository.PullRequest
            .ReviewThreads.Node,
        repository: ForgeRepositoryIdentity
    ) throws -> ReviewThreadMapping {
        let anchor: ForgeReadSection<ForgeReviewAnchor>
        if let subject = reviewSubject(node.subjectType.value),
           let side = reviewSide(node.diffSide.value),
           node.startDiffSide == nil || node.startDiffSide?.value != nil
        {
            anchor = try .available(ForgeReviewAnchor(
                path: ForgeFilePath(node.path),
                subject: subject,
                side: side,
                startSide: reviewSide(node.startDiffSide?.value),
                startLine: node.startLine,
                line: node.line,
                originalStartLine: node.originalStartLine,
                originalLine: node.originalLine
            ))
        } else {
            anchor = .unavailable(.partialResponse)
        }
        let comments = try mapNodes(node.comments.nodes) {
            try reviewComment($0.fragments.gitHubReviewComment, repository: repository)
        }
        let commentPage = try pageMapping(
            items: comments.values,
            totalCount: node.comments.totalCount,
            pageInfo: node.comments.pageInfo.fragments.gitHubPageInfo,
            hasDroppedNodes: comments.isPartial
        )
        return try ReviewThreadMapping(
            value: ForgeReviewThread(
                repository: repository,
                id: objectID(node.id),
                isResolved: node.isResolved,
                isOutdated: node.isOutdated,
                anchor: anchor,
                comments: .available(commentPage.value)
            ),
            isPartial: anchor.isUnavailable || commentPage.isPartial
                || commentPage.value.nextCursor != nil
        )
    }

    func reviewComment(
        _ fragment: GitHubAPI.GitHubReviewComment,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeReviewComment {
        try ForgeReviewComment(
            repository: repository,
            id: objectID(fragment.id),
            bodyMarkdown: fragment.body,
            createdAt: date(fragment.createdAt),
            updatedAt: date(fragment.updatedAt),
            author: author(fragment.author?.fragments.gitHubActor),
            replyToID: fragment.replyTo.map { try objectID($0.id) }
        )
    }

    func reviewSubject(_ value: GitHubAPI.PullRequestReviewThreadSubjectType?) -> ForgeReviewSubject? {
        switch value {
        case .file: .file
        case .line: .line
        case nil: nil
        }
    }

    func reviewSide(_ value: GitHubAPI.DiffSide?) -> ForgeReviewDiffSide? {
        switch value {
        case .left: .left
        case .right: .right
        case nil: nil
        }
    }

    func attentionPullRequest(
        _ node: GitHubAPI.GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeAttentionCandidate {
        let assignees = try completeValues(
            nodes: node.assignedActors.nodes,
            totalCount: node.assignedActors.totalCount,
            pageInfo: node.assignedActors.pageInfo.fragments.gitHubPageInfo
        ) { try assignee($0.fragments.gitHubAssignee) }
        let participants = try completeValues(
            nodes: node.participants.nodes,
            totalCount: node.participants.totalCount,
            pageInfo: node.participants.pageInfo.fragments.gitHubPageInfo
        ) { try actor($0.fragments.gitHubActor) }
        let requestedReviewers: SectionMapping<[ForgeReviewParticipant]>
        if let requests = node.reviewRequests {
            requestedReviewers = try completeValues(
                nodes: requests.nodes,
                totalCount: requests.totalCount,
                pageInfo: requests.pageInfo.fragments.gitHubPageInfo
            ) { request in
                guard let reviewer = request.requestedReviewer else { return nil }
                return try reviewParticipant(reviewer.fragments.gitHubRequestedReviewer)
            }
        } else {
            requestedReviewers = SectionMapping(
                section: .unavailable(.partialResponse),
                isPartial: true
            )
        }
        let activities = try pullRequestActivities(node)
        let threads = try attentionReviewThreads(node.reviewThreads, repository: repository)
        return try ForgeAttentionCandidate(
            item: .pullRequest(pullRequestSummary(
                node.fragments.gitHubPullRequestSummary,
                repository: repository
            )),
            bodyMarkdown: .available(node.body),
            assignees: assignees.section,
            participants: participants.section,
            requestedReviewers: requestedReviewers.section,
            activities: activities.section,
            reviewThreads: threads.section
        )
    }

    func attentionIssue(
        _ node: GitHubAPI.GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeAttentionCandidate {
        let assignees = try completeValues(
            nodes: node.assignedActors.nodes,
            totalCount: node.assignedActors.totalCount,
            pageInfo: node.assignedActors.pageInfo.fragments.gitHubPageInfo
        ) { try assignee($0.fragments.gitHubAssignee) }
        let participants = try completeValues(
            nodes: node.participants.nodes,
            totalCount: node.participants.totalCount,
            pageInfo: node.participants.pageInfo.fragments.gitHubPageInfo
        ) { try actor($0.fragments.gitHubActor) }
        let activities = try issueActivities(node)
        return try ForgeAttentionCandidate(
            item: .issue(issueSummary(node.fragments.gitHubIssueSummary, repository: repository)),
            bodyMarkdown: .available(node.body),
            assignees: assignees.section,
            participants: participants.section,
            requestedReviewers: .available([]),
            activities: activities.section,
            reviewThreads: .available([])
        )
    }

    func pullRequestActivities(
        _ node: GitHubAPI.GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest
    ) throws -> SectionMapping<[ForgeAttentionActivity]> {
        let comments = try completeValues(
            nodes: node.comments.nodes,
            totalCount: node.comments.totalCount,
            pageInfo: node.comments.pageInfo.fragments.gitHubPageInfo
        ) { try attentionComment($0.fragments.gitHubIssueComment) }
        guard let latestReviews = node.latestReviews else {
            return SectionMapping(section: .unavailable(.partialResponse), isPartial: true)
        }
        let reviews = try completeValues(
            nodes: latestReviews.nodes,
            totalCount: latestReviews.totalCount,
            pageInfo: latestReviews.pageInfo.fragments.gitHubPageInfo
        ) { review -> ForgeAttentionActivity? in
            guard let submittedAt = review.submittedAt else { return nil }
            return try ForgeAttentionActivity(
                id: objectID(review.id),
                kind: .review,
                author: author(review.author?.fragments.gitHubActor),
                bodyMarkdown: review.body,
                occurredAt: date(submittedAt)
            )
        }
        guard case let .available(commentValues) = comments.section,
              case let .available(reviewValues) = reviews.section
        else {
            return SectionMapping(section: .unavailable(.partialResponse), isPartial: true)
        }
        return SectionMapping(
            section: .available(sortActivities(commentValues + reviewValues)),
            isPartial: false
        )
    }

    func issueActivities(
        _ node: GitHubAPI.GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue
    ) throws -> SectionMapping<[ForgeAttentionActivity]> {
        try completeValues(
            nodes: node.comments.nodes,
            totalCount: node.comments.totalCount,
            pageInfo: node.comments.pageInfo.fragments.gitHubPageInfo
        ) { try attentionComment($0.fragments.gitHubIssueComment) }
    }

    func attentionComment(_ fragment: GitHubAPI.GitHubIssueComment) throws -> ForgeAttentionActivity {
        try ForgeAttentionActivity(
            id: objectID(fragment.id),
            kind: .conversationComment,
            author: author(fragment.author?.fragments.gitHubActor),
            bodyMarkdown: fragment.body,
            occurredAt: date(fragment.createdAt)
        )
    }

    func sortActivities(_ values: [ForgeAttentionActivity]) -> [ForgeAttentionActivity] {
        values.sorted {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt < $1.occurredAt
            }
            return $0.id.value < $1.id.value
        }
    }

    func attentionReviewThreads(
        _ connection: GitHubAPI.GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewThreads,
        repository: ForgeRepositoryIdentity
    ) throws -> SectionMapping<[ForgeReviewThread]> {
        let mapped = try mapNodes(connection.nodes) { node -> ForgeReviewThread? in
            let comments = try completeValues(
                nodes: node.comments.nodes,
                totalCount: node.comments.totalCount,
                pageInfo: node.comments.pageInfo.fragments.gitHubPageInfo
            ) { try reviewComment($0.fragments.gitHubReviewComment, repository: repository) }
            let commentPage: ForgeReadSection<ForgePage<ForgeReviewComment>>
            switch comments.section {
            case let .available(values):
                commentPage = try .available(ForgePage(
                    items: values,
                    nextCursor: nil,
                    totalCount: values.count
                ))
            case let .unavailable(reason):
                commentPage = .unavailable(reason)
            }
            return try ForgeReviewThread(
                repository: repository,
                id: objectID(node.id),
                isResolved: node.isResolved,
                isOutdated: node.isOutdated,
                anchor: .unavailable(.notRequested),
                comments: commentPage
            )
        }
        guard connectionIsComplete(
            mappedCount: mapped.values.count,
            totalCount: connection.totalCount,
            pageInfo: connection.pageInfo.fragments.gitHubPageInfo,
            hasDroppedNodes: mapped.isPartial
        ) else {
            return SectionMapping(section: .unavailable(.partialResponse), isPartial: true)
        }
        return SectionMapping(
            section: .available(mapped.values),
            isPartial: mapped.values.contains { $0.comments.isUnavailable }
        )
    }

    func attentionCandidateIsPartial(_ candidate: ForgeAttentionCandidate) -> Bool {
        let hasPartialThreads: Bool
        if case let .available(threads) = candidate.reviewThreads {
            hasPartialThreads = threads.contains { $0.comments.isUnavailable }
        } else {
            hasPartialThreads = false
        }
        return repositoryItemIsPartial(candidate.item)
            || candidate.assignees.isUnavailable || candidate.participants.isUnavailable
            || candidate.requestedReviewers.isUnavailable || candidate.activities.isUnavailable
            || candidate.reviewThreads.isUnavailable
            || hasPartialThreads
    }

    func issueTimeline(
        _ connection: GitHubAPI.GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems,
        repository: ForgeRepositoryIdentity
    ) throws -> CursorSectionMapping<ForgePage<ForgeTimelineItem>> {
        let mapped = try mapNodes(connection.nodes) {
            try issueTimelineItem($0, repository: repository)
        }
        let page = try pageMapping(
            items: mapped.values,
            totalCount: connection.totalCount,
            pageInfo: connection.pageInfo.fragments.gitHubPageInfo,
            hasDroppedNodes: mapped.isPartial
        )
        return CursorSectionMapping(
            section: .available(page.value),
            nextCursor: page.value.nextCursor,
            isPartial: page.isPartial || page.value.nextCursor != nil
        )
    }

    func issueTimelineItem(
        _ node: GitHubAPI.GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeTimelineItem? {
        if let comment = node.asIssueComment {
            let fragment = comment.fragments.gitHubIssueComment
            return try timelineItem(
                id: fragment.id,
                occurredAt: fragment.createdAt,
                actor: authorValue(fragment.author?.fragments.gitHubActor),
                event: .comment(bodyMarkdown: fragment.body, updatedAt: date(fragment.updatedAt)),
                repository: repository
            )
        }
        if let event = node.asClosedEvent {
            return try timelineItem(event.id, event.createdAt, event.actor, .closed, repository)
        }
        if let event = node.asReopenedEvent {
            return try timelineItem(event.id, event.createdAt, event.actor, .reopened, repository)
        }
        if let event = node.asAssignedEvent,
           let assigned = event.assignee,
           let mappedAssignee = try assignee(assigned.fragments.gitHubAssignee)
        {
            return try timelineItem(
                event.id, event.createdAt, event.actor, .assigned(mappedAssignee), repository
            )
        }
        if let event = node.asUnassignedEvent,
           let assigned = event.assignee,
           let mappedAssignee = try assignee(assigned.fragments.gitHubAssignee)
        {
            return try timelineItem(
                event.id, event.createdAt, event.actor, .unassigned(mappedAssignee), repository
            )
        }
        if let event = node.asLabeledEvent {
            return try timelineItem(
                event.id,
                event.createdAt,
                event.actor,
                .labeled(label(event.label.fragments.gitHubLabel, repository: repository)),
                repository
            )
        }
        if let event = node.asUnlabeledEvent {
            return try timelineItem(
                event.id,
                event.createdAt,
                event.actor,
                .unlabeled(label(event.label.fragments.gitHubLabel, repository: repository)),
                repository
            )
        }
        if let event = node.asMilestonedEvent {
            return try timelineItem(
                event.id,
                event.createdAt,
                event.actor,
                .milestoneTitleChanged(event.milestoneTitle),
                repository
            )
        }
        if let event = node.asDemilestonedEvent {
            return try timelineItem(
                event.id, event.createdAt, event.actor, .milestoneTitleChanged(nil), repository
            )
        }
        if let event = node.asRenamedTitleEvent {
            return try timelineItem(
                event.id,
                event.createdAt,
                event.actor,
                .renamed(previousTitle: event.previousTitle, currentTitle: event.currentTitle),
                repository
            )
        }
        if let event = node.asCrossReferencedEvent,
           let reference = try crossReference(event.source)
        {
            return try timelineItem(
                event.id,
                event.createdAt,
                event.actor,
                .crossReferenced(destination: reference.destination, title: reference.title),
                repository
            )
        }
        return nil
    }

    func crossReference(
        _ source: GitHubAPI.GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node
            .AsCrossReferencedEvent.Source
    ) throws -> (destination: ForgeDestination, title: String)? {
        if let pullRequest = source.asPullRequest {
            let linkedRepository = try repository(
                pullRequest.repository.fragments.gitHubRepositoryIdentity
            )
            return try (
                .pullRequest(linkedRepository, ForgeItemNumber(pullRequest.number)),
                pullRequest.title
            )
        }
        if let issue = source.asIssue {
            let linkedRepository = try repository(issue.repository.fragments.gitHubRepositoryIdentity)
            return try (.issue(linkedRepository, ForgeItemNumber(issue.number)), issue.title)
        }
        return nil
    }

    func label(
        _ fragment: GitHubAPI.GitHubLabel,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeLabel {
        try ForgeLabel(
            repository: repository,
            id: objectID(fragment.id),
            name: fragment.name,
            description: fragment.description,
            color: ForgeLabelColor(fragment.color)
        )
    }

    func repositoryItemIsPartial(_ item: ForgeRepositoryItem) -> Bool {
        switch item {
        case let .pullRequest(summary): pullRequestSummaryIsPartial(summary)
        case let .issue(summary): issueSummaryIsPartial(summary)
        }
    }

    func issueSummaryIsPartial(_ summary: ForgeIssueSummary) -> Bool {
        summary.labels.isUnavailable
    }

    func pullRequestSummaryIsPartial(_ summary: ForgePullRequestSummary) -> Bool {
        summary.head.isUnavailable || summary.base.isUnavailable
            || summary.labels.isUnavailable || summary.checkRollup.isUnavailable
            || summary.reviewRollup.isUnavailable
    }

    func pullRequestSummary(
        _ fragment: GitHubAPI.GitHubPullRequestSummary,
        repository expectedRepository: ForgeRepositoryIdentity
    ) throws -> ForgePullRequestSummary {
        let state: ForgePullRequestState
        switch fragment.pullRequestState.value {
        case .open: state = .open
        case .closed: state = .closed
        case .merged: state = .merged
        case nil: throw GitHubReadError.malformedResponse
        }
        let head: ForgeReadSection<ForgeBranchReference>
        if let headRepository = fragment.headRepository {
            head = try .available(ForgeBranchReference(
                repository: repository(headRepository.fragments.gitHubRepositoryIdentity),
                name: ForgeRefName(fragment.headRefName),
                commit: ForgeCommitID(fragment.headRefOid)
            ))
        } else {
            head = .unavailable(.partialResponse)
        }
        let base: ForgeReadSection<ForgeBranchReference>
        if let baseRepository = fragment.baseRepository {
            let reference = try ForgeBranchReference(
                repository: repository(baseRepository.fragments.gitHubRepositoryIdentity),
                name: ForgeRefName(fragment.baseRefName),
                commit: ForgeCommitID(fragment.baseRefOid)
            )
            guard reference.repository == expectedRepository else { throw GitHubReadError.malformedResponse }
            base = .available(reference)
        } else {
            base = .unavailable(.partialResponse)
        }
        let labels: ForgeReadSection<[ForgeLabel]>
        if let connection = fragment.labels {
            labels = try completeValues(
                nodes: connection.nodes,
                totalCount: connection.totalCount,
                pageInfo: connection.pageInfo.fragments.gitHubPageInfo
            ) { try label($0.fragments.gitHubLabel, repository: expectedRepository) }.section
        } else {
            labels = .unavailable(.partialResponse)
        }
        let check = checkRollupSection(fragment.statusCheckRollup?.state.value)
        let review: ForgeReadSection<ForgeReviewRollup>
        switch fragment.reviewDecision?.value {
        case .approved: review = .available(.approved)
        case .changesRequested: review = .available(.changesRequested)
        case .reviewRequired: review = .available(.reviewRequired)
        case nil: review = fragment.reviewDecision == nil ? .available(.noDecision) : .unavailable(.partialResponse)
        }
        return try ForgePullRequestSummary(
            repository: expectedRepository,
            number: ForgeItemNumber(fragment.number),
            state: state,
            isDraft: fragment.isDraft,
            title: fragment.title,
            author: author(fragment.author?.fragments.gitHubActor),
            head: head,
            base: base,
            createdAt: date(fragment.createdAt),
            updatedAt: date(fragment.updatedAt),
            closedAt: optionalDate(fragment.closedAt),
            mergedAt: optionalDate(fragment.mergedAt),
            labels: labels,
            checkRollup: check,
            reviewRollup: review
        )
    }

    func issueSummary(
        _ fragment: GitHubAPI.GitHubIssueSummary,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeIssueSummary {
        let state: ForgeIssueState
        switch fragment.issueState.value {
        case .open: state = .open
        case .closed: state = .closed
        case nil: throw GitHubReadError.malformedResponse
        }
        let labels: ForgeReadSection<[ForgeLabel]>
        if let connection = fragment.labels {
            labels = try completeValues(
                nodes: connection.nodes,
                totalCount: connection.totalCount,
                pageInfo: connection.pageInfo.fragments.gitHubPageInfo
            ) { try label($0.fragments.gitHubLabel, repository: repository) }.section
        } else {
            labels = .unavailable(.partialResponse)
        }
        return try ForgeIssueSummary(
            repository: repository,
            number: ForgeItemNumber(fragment.number),
            state: state,
            title: fragment.title,
            author: author(fragment.author?.fragments.gitHubActor),
            createdAt: date(fragment.createdAt),
            updatedAt: date(fragment.updatedAt),
            closedAt: optionalDate(fragment.closedAt),
            labels: labels
        )
    }
}

private extension ForgeReadSection {
    var isUnavailable: Bool {
        if case .unavailable = self {
            return true
        }
        return false
    }
}
