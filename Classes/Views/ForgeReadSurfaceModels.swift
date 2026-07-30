import ForgeKit
import Foundation

enum ForgeReadSurfaceKind: String, CaseIterable, Sendable {
    case pullRequests
    case issues

    var displayName: String {
        switch self {
        case .pullRequests: "Pull Requests"
        case .issues: "Issues"
        }
    }

    var emptyDescription: String {
        switch self {
        case .pullRequests: "No pull requests match this view."
        case .issues: "No issues match this view."
        }
    }
}

enum ForgeReadStateFilter: String, CaseIterable, Sendable {
    case open
    case closed
    case all

    var displayName: String {
        switch self {
        case .open: "Open"
        case .closed: "Closed"
        case .all: "All"
        }
    }
}

enum ForgeReadSurfaceColumn: String, CaseIterable, Hashable, Sendable {
    case state
    case number
    case title
    case author
    case updated
}

struct ForgeReadSurfaceQuery: Equatable, Sendable {
    let searchText: String
    let stateFilter: ForgeReadStateFilter

    init(searchText: String = "", stateFilter: ForgeReadStateFilter = .open) {
        self.searchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.stateFilter = stateFilter
    }
}

struct ForgeReadSurfacePage: Sendable {
    let items: [ForgeRepositoryItem]
    let nextCursor: ForgePageCursor?
    let totalCount: Int?
    let fetchedAt: Date
    let isStale: Bool
    let isPartial: Bool

    init(
        items: [ForgeRepositoryItem],
        nextCursor: ForgePageCursor? = nil,
        totalCount: Int? = nil,
        fetchedAt: Date,
        isStale: Bool = false,
        isPartial: Bool = false
    ) {
        self.items = items
        self.nextCursor = nextCursor
        self.totalCount = totalCount
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.isPartial = isPartial
    }
}

enum ForgeReadSurfaceDetails: Sendable {
    case pullRequest(ForgePullRequestDetailsPage)
    case issue(ForgeIssueDetails)

    var item: ForgeRepositoryItem {
        switch self {
        case let .pullRequest(page): .pullRequest(page.details.summary)
        case let .issue(details): .issue(details.summary)
        }
    }
}

struct ForgeReadSurfaceDetailsSnapshot: Sendable {
    let details: ForgeReadSurfaceDetails
    let fetchedAt: Date
    let isStale: Bool
    let isPartial: Bool

    init(
        details: ForgeReadSurfaceDetails,
        fetchedAt: Date,
        isStale: Bool = false,
        isPartial: Bool = false
    ) {
        self.details = details
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.isPartial = isPartial
    }
}

@MainActor
protocol ForgeReadSurfaceServing: AnyObject {
    func loadItems(
        kind: ForgeReadSurfaceKind,
        query: ForgeReadSurfaceQuery,
        after cursor: ForgePageCursor?
    ) async throws -> ForgeReadSurfacePage

    func loadDetails(
        for item: ForgeRepositoryItem,
        timelineAfter: ForgePageCursor?,
        checkAfter: ForgePageCursor?
    ) async throws -> ForgeReadSurfaceDetailsSnapshot
}

enum ForgeReadDetailsContinuation: Equatable, Sendable {
    case timeline
    case checks
}

enum ForgeReadDetailsMergeError: Error, Equatable, LocalizedError, Sendable {
    case mismatchedItem
    case mismatchedDetailsKind
    case unavailableContinuation

    var errorDescription: String? {
        switch self {
        case .mismatchedItem: "GitHub returned a page for a different item."
        case .mismatchedDetailsKind: "GitHub returned the wrong detail kind."
        case .unavailableContinuation: "GitHub did not return the requested continuation."
        }
    }
}

enum ForgeReadDetailsMerger {
    static func merge(
        _ next: ForgeReadSurfaceDetailsSnapshot,
        into current: ForgeReadSurfaceDetailsSnapshot,
        continuation: ForgeReadDetailsContinuation
    ) throws -> ForgeReadSurfaceDetailsSnapshot {
        guard current.details.item.destination == next.details.item.destination else {
            throw ForgeReadDetailsMergeError.mismatchedItem
        }
        let mergedDetails: ForgeReadSurfaceDetails
        switch (current.details, next.details, continuation) {
        case let (.pullRequest(currentPage), .pullRequest(nextPage), .timeline):
            mergedDetails = try .pullRequest(mergePullRequestTimeline(nextPage, into: currentPage))
        case let (.pullRequest(currentPage), .pullRequest(nextPage), .checks):
            mergedDetails = try .pullRequest(mergePullRequestChecks(nextPage, into: currentPage))
        case let (.issue(currentDetails), .issue(nextDetails), .timeline):
            mergedDetails = try .issue(mergeIssueTimeline(nextDetails, into: currentDetails))
        case (.issue, .issue, .checks):
            throw ForgeReadDetailsMergeError.unavailableContinuation
        default:
            throw ForgeReadDetailsMergeError.mismatchedDetailsKind
        }
        return ForgeReadSurfaceDetailsSnapshot(
            details: mergedDetails,
            fetchedAt: next.fetchedAt,
            isStale: current.isStale || next.isStale,
            isPartial: current.isPartial || next.isPartial
        )
    }

    private static func mergePullRequestTimeline(
        _ next: ForgePullRequestDetailsPage,
        into current: ForgePullRequestDetailsPage
    ) throws -> ForgePullRequestDetailsPage {
        let mergedTimeline = try mergeTimeline(current.details.timeline, next.details.timeline)
        let merged = try ForgePullRequestDetails(
            summary: current.details.summary,
            bodyMarkdown: current.details.bodyMarkdown,
            assignees: current.details.assignees,
            milestone: current.details.milestone,
            reviewers: current.details.reviewers,
            linkedIssues: current.details.linkedIssues,
            mergeability: current.details.mergeability,
            checks: current.details.checks,
            timeline: .available(mergedTimeline)
        )
        return ForgePullRequestDetailsPage(details: merged, nextCheckCursor: current.nextCheckCursor)
    }

    private static func mergePullRequestChecks(
        _ next: ForgePullRequestDetailsPage,
        into current: ForgePullRequestDetailsPage
    ) throws -> ForgePullRequestDetailsPage {
        guard case let .available(currentChecks) = current.details.checks,
              case let .available(nextChecks) = next.details.checks
        else {
            throw ForgeReadDetailsMergeError.unavailableContinuation
        }
        var seen = Set(currentChecks)
        let mergedChecks = currentChecks + nextChecks.filter { seen.insert($0).inserted }
        let merged = try ForgePullRequestDetails(
            summary: current.details.summary,
            bodyMarkdown: current.details.bodyMarkdown,
            assignees: current.details.assignees,
            milestone: current.details.milestone,
            reviewers: current.details.reviewers,
            linkedIssues: current.details.linkedIssues,
            mergeability: current.details.mergeability,
            checks: .available(mergedChecks),
            timeline: current.details.timeline
        )
        return ForgePullRequestDetailsPage(details: merged, nextCheckCursor: next.nextCheckCursor)
    }

    private static func mergeIssueTimeline(
        _ next: ForgeIssueDetails,
        into current: ForgeIssueDetails
    ) throws -> ForgeIssueDetails {
        try ForgeIssueDetails(
            summary: current.summary,
            bodyMarkdown: current.bodyMarkdown,
            assignees: current.assignees,
            milestone: current.milestone,
            timeline: .available(mergeTimeline(current.timeline, next.timeline))
        )
    }

    private static func mergeTimeline(
        _ current: ForgeReadSection<ForgePage<ForgeTimelineItem>>,
        _ next: ForgeReadSection<ForgePage<ForgeTimelineItem>>
    ) throws -> ForgePage<ForgeTimelineItem> {
        guard case let .available(currentPage) = current,
              case let .available(nextPage) = next
        else {
            throw ForgeReadDetailsMergeError.unavailableContinuation
        }
        var identifiers = Set(currentPage.items.map(\.id))
        let items = currentPage.items + nextPage.items.filter { identifiers.insert($0.id).inserted }
        return try ForgePage(
            items: items,
            nextCursor: nextPage.nextCursor,
            totalCount: nextPage.totalCount ?? currentPage.totalCount
        )
    }
}

struct ForgeReadSurfaceRequest: Equatable, Sendable {
    let id: UInt64
    let kind: ForgeReadSurfaceKind
    let query: ForgeReadSurfaceQuery
    let cursor: ForgePageCursor?
}

struct ForgeReadSurfaceRow: Equatable, Sendable {
    let item: ForgeRepositoryItem
    let number: String
    let title: String
    let state: String
    let author: String
    let updatedAt: Date
    let labels: [String]
    let accessibilityLabel: String

    var destination: ForgeDestination {
        item.destination
    }

    init(item: ForgeRepositoryItem) {
        self.item = item
        switch item {
        case let .pullRequest(summary):
            number = "#\(summary.number.rawValue)"
            title = summary.title
            state = Self.pullRequestState(summary)
            author = Self.authorName(summary.author)
            updatedAt = summary.updatedAt
            labels = Self.labelNames(summary.labels)
        case let .issue(summary):
            number = "#\(summary.number.rawValue)"
            title = summary.title
            state = summary.state == .open ? "Open" : "Closed"
            author = Self.authorName(summary.author)
            updatedAt = summary.updatedAt
            labels = Self.labelNames(summary.labels)
        }
        let labelDescription = labels.isEmpty ? "No labels" : "Labels: \(labels.joined(separator: ", "))"
        accessibilityLabel = "\(state) \(number), \(title), by \(author), \(labelDescription)"
    }

    private static func pullRequestState(_ summary: ForgePullRequestSummary) -> String {
        if summary.isDraft, summary.state == .open {
            return "Draft"
        }
        switch summary.state {
        case .open: return "Open"
        case .closed: return "Closed"
        case .merged: return "Merged"
        }
    }

    private static func authorName(_ author: ForgeReadSection<ForgeAuthor>) -> String {
        switch author {
        case let .available(.actor(actor)): actor.displayName ?? actor.login
        case .available(.deleted): "Deleted user"
        case .unavailable: "Unavailable"
        }
    }

    private static func labelNames(_ labels: ForgeReadSection<[ForgeLabel]>) -> [String] {
        guard case let .available(values) = labels else { return [] }
        return values.map(\.name)
    }
}

struct ForgeReadListPresentation: Equatable, Sendable {
    let rows: [ForgeReadSurfaceRow]
    let statusMessage: String?
    let freshnessMessage: String?
    let isLoading: Bool
    let canLoadNextPage: Bool
    let totalDescription: String?
}

/// Attention metadata wrapped around the same native repository-item row used
/// by Pull Requests and Issues. This keeps list rendering consistent while the
/// stable Attention identity remains available for seen/unseen actions.
struct ForgeAttentionReadSurfaceRow: Equatable, Sendable {
    let itemID: ForgeAttentionItemID
    let repositoryName: String
    let kindName: String
    let isUnseen: Bool
    let readRow: ForgeReadSurfaceRow
    let accessibilityLabel: String

    init(entry: ForgeAttentionInboxEntry) {
        let item = entry.record.item
        itemID = item.id
        repositoryName = "\(item.id.repository.owner)/\(item.id.repository.name)"
        kindName = Self.kindName(item.id.kind)
        isUnseen = item.seenState == .unseen
        readRow = ForgeReadSurfaceRow(item: entry.subject)
        let seenDescription = isUnseen ? "Unseen" : "Seen"
        accessibilityLabel = "\(seenDescription) \(kindName), \(repositoryName), \(readRow.accessibilityLabel)"
    }

    private static func kindName(_ kind: ForgeAttentionKind) -> String {
        switch kind {
        case .reviewRequest: "Review request"
        case .mention: "Mention"
        case .reply: "Reply"
        case .assignment: "Assignment"
        case .failedCheck: "Failed check"
        }
    }
}

struct ForgeAttentionReadPresentation: Equatable, Sendable {
    let rows: [ForgeAttentionReadSurfaceRow]
    let visibleColumns: Set<ForgeAttentionColumn>
    let statusMessage: String?
    let unseenCount: Int
}

/// Route carried from an account-wide Attention row into the existing native
/// inspector. The repository travels with the item so All never accidentally
/// reuses the current window's repository-bound service.
struct ForgeAttentionInspectorRoute: Equatable, Sendable {
    let itemID: ForgeAttentionItemID
    let repository: ForgeRepositoryIdentity
    let item: ForgeRepositoryItem
    let destination: ForgeDestination
}

enum ForgeAttentionReadSurfacePresenter {
    static func present(
        entries: [ForgeAttentionInboxEntry],
        query: ForgeAttentionInboxQuery
    ) -> ForgeAttentionReadPresentation {
        let filtered = query.applying(to: entries)
        let rows = filtered.map(ForgeAttentionReadSurfaceRow.init)
        let statusMessage: String?
        if rows.isEmpty {
            statusMessage = query.state.visibility == .unseenOnly
                ? "No unseen items need your attention."
                : "No current items need your attention."
        } else {
            statusMessage = nil
        }
        return ForgeAttentionReadPresentation(
            rows: rows,
            visibleColumns: query.state.columns,
            statusMessage: statusMessage,
            unseenCount: rows.reduce(into: 0) { count, row in
                if row.isUnseen {
                    count += 1
                }
            }
        )
    }

    static func inspectorRoute(
        for itemID: ForgeAttentionItemID,
        in entries: [ForgeAttentionInboxEntry]
    ) -> ForgeAttentionInspectorRoute? {
        guard let entry = entries.first(where: { $0.record.item.id == itemID }) else { return nil }
        return ForgeAttentionInspectorRoute(
            itemID: itemID,
            repository: entry.subject.repository,
            item: entry.subject,
            destination: entry.record.item.destination
        )
    }
}

struct ForgeReadSurfaceAccumulator: Sendable {
    private(set) var kind: ForgeReadSurfaceKind
    private(set) var query: ForgeReadSurfaceQuery
    private(set) var items: [ForgeRepositoryItem] = []
    private(set) var nextCursor: ForgePageCursor?
    private(set) var totalCount: Int?
    private(set) var fetchedAt: Date?
    private(set) var isStale = false
    private(set) var isPartial = false
    private(set) var failureMessage: String?
    private(set) var activeRequest: ForgeReadSurfaceRequest?
    private var nextRequestID: UInt64 = 1

    init(kind: ForgeReadSurfaceKind, query: ForgeReadSurfaceQuery = ForgeReadSurfaceQuery()) {
        self.kind = kind
        self.query = query
    }

    mutating func beginReload(
        kind: ForgeReadSurfaceKind? = nil,
        query: ForgeReadSurfaceQuery? = nil
    ) -> ForgeReadSurfaceRequest {
        let previousKind = self.kind
        let previousQuery = self.query
        if let kind {
            self.kind = kind
        }
        if let query {
            self.query = query
        }
        if self.kind != previousKind || self.query != previousQuery {
            items = []
            nextCursor = nil
            totalCount = nil
            fetchedAt = nil
            isStale = false
            isPartial = false
        }
        failureMessage = nil
        return makeRequest(cursor: nil)
    }

    mutating func beginNextPage() -> ForgeReadSurfaceRequest? {
        guard activeRequest == nil, let nextCursor else { return nil }
        failureMessage = nil
        return makeRequest(cursor: nextCursor)
    }

    @discardableResult
    mutating func receive(
        _ page: ForgeReadSurfacePage,
        for request: ForgeReadSurfaceRequest
    ) -> Bool {
        guard request == activeRequest else { return false }
        if request.cursor == nil {
            items = page.items
        } else {
            var destinations = Set(items.map(\.destination))
            for item in page.items where destinations.insert(item.destination).inserted {
                items.append(item)
            }
        }
        nextCursor = page.nextCursor
        totalCount = page.totalCount ?? totalCount
        fetchedAt = page.fetchedAt
        isStale = page.isStale
        isPartial = page.isPartial
        failureMessage = nil
        activeRequest = nil
        return true
    }

    @discardableResult
    mutating func fail(_ message: String, for request: ForgeReadSurfaceRequest) -> Bool {
        guard request == activeRequest else { return false }
        failureMessage = message
        if !items.isEmpty {
            isStale = true
        }
        activeRequest = nil
        return true
    }

    func presentation(formatDate: (Date) -> String) -> ForgeReadListPresentation {
        let rows = items.map(ForgeReadSurfaceRow.init)
        let statusMessage: String?
        if activeRequest != nil, items.isEmpty {
            statusMessage = "Loading \(kind.displayName)…"
        } else if let failureMessage, items.isEmpty {
            statusMessage = "Couldn’t load \(kind.displayName). \(failureMessage)"
        } else if activeRequest == nil, items.isEmpty, fetchedAt != nil {
            statusMessage = kind.emptyDescription
        } else if activeRequest != nil {
            statusMessage = "Refreshing…"
        } else {
            statusMessage = failureMessage
        }

        var freshnessParts: [String] = []
        if isStale, let fetchedAt {
            freshnessParts.append("Stale data from \(formatDate(fetchedAt))")
        }
        if isPartial {
            freshnessParts.append("Some fields are unavailable")
        }
        if isStale, let failureMessage, !items.isEmpty {
            freshnessParts.append("Refresh failed: \(failureMessage)")
        }

        let totalDescription: String?
        if let totalCount {
            totalDescription = "Showing \(items.count) of \(totalCount)"
        } else if !items.isEmpty {
            totalDescription = "Showing \(items.count)"
        } else {
            totalDescription = nil
        }

        return ForgeReadListPresentation(
            rows: rows,
            statusMessage: statusMessage,
            freshnessMessage: freshnessParts.isEmpty ? nil : freshnessParts.joined(separator: " • "),
            isLoading: activeRequest != nil,
            canLoadNextPage: activeRequest == nil && nextCursor != nil,
            totalDescription: totalDescription
        )
    }

    private mutating func makeRequest(cursor: ForgePageCursor?) -> ForgeReadSurfaceRequest {
        let request = ForgeReadSurfaceRequest(
            id: nextRequestID,
            kind: kind,
            query: query,
            cursor: cursor
        )
        nextRequestID &+= 1
        activeRequest = request
        return request
    }
}

struct ForgeReadInspectorMetadata: Equatable, Sendable {
    let title: String
    let value: String
    let isUnavailable: Bool
}

struct ForgeReadTimelinePresentation: Equatable, Sendable {
    let id: ForgeObjectID
    let actor: String
    let occurredAt: Date
    let summary: String
    let markdown: String?
    let destination: ForgeDestination?
}

struct ForgeReadInspectorPresentation: Equatable, Sendable {
    let item: ForgeRepositoryItem
    let title: String
    let subtitle: String
    let author: ForgeActor?
    let metadata: [ForgeReadInspectorMetadata]
    let bodyMarkdown: String?
    let bodyUnavailableMessage: String?
    let timeline: [ForgeReadTimelinePresentation]
    let timelineUnavailableMessage: String?
    let nextTimelineCursor: ForgePageCursor?
    let nextCheckCursor: ForgePageCursor?
    let freshnessMessage: String?
}

enum ForgeReadInspectorPresenter {
    static func present(
        _ snapshot: ForgeReadSurfaceDetailsSnapshot,
        formatDate: (Date) -> String
    ) -> ForgeReadInspectorPresentation {
        switch snapshot.details {
        case let .pullRequest(page):
            return presentPullRequest(page, snapshot: snapshot, formatDate: formatDate)
        case let .issue(details):
            return presentIssue(details, snapshot: snapshot, formatDate: formatDate)
        }
    }

    private static func presentPullRequest(
        _ page: ForgePullRequestDetailsPage,
        snapshot: ForgeReadSurfaceDetailsSnapshot,
        formatDate: (Date) -> String
    ) -> ForgeReadInspectorPresentation {
        let details = page.details
        let summary = details.summary
        var metadata = summaryMetadata(summary, formatDate: formatDate)
        metadata += [
            readMetadata("Assignees", section: details.assignees, value: actorList),
            readMetadata("Milestone", section: details.milestone) { $0?.title ?? "None" },
            readMetadata("Reviewers", section: details.reviewers, value: reviewerList),
            readMetadata("Linked Issues", section: details.linkedIssues) { issues in
                issues.isEmpty ? "None" : issues.map { "#\($0.number.rawValue) \($0.title)" }.joined(separator: ", ")
            },
            readMetadata("Mergeability", section: details.mergeability) { mergeability in
                switch mergeability {
                case .mergeable: "Mergeable"
                case .conflicting: "Conflicts"
                case .unknown: "Unknown"
                }
            },
            readMetadata("Checks", section: details.checks, value: checkList),
        ]
        let body = markdown(details.bodyMarkdown)
        let timeline = timeline(details.timeline)
        return ForgeReadInspectorPresentation(
            item: .pullRequest(summary),
            title: summary.title,
            subtitle: "Pull Request #\(summary.number.rawValue) • \(pullRequestState(summary))",
            author: actor(summary.author),
            metadata: metadata,
            bodyMarkdown: body.value,
            bodyUnavailableMessage: body.unavailable,
            timeline: timeline.items,
            timelineUnavailableMessage: timeline.unavailable,
            nextTimelineCursor: timeline.nextCursor,
            nextCheckCursor: page.nextCheckCursor,
            freshnessMessage: freshness(snapshot, formatDate: formatDate)
        )
    }

    private static func presentIssue(
        _ details: ForgeIssueDetails,
        snapshot: ForgeReadSurfaceDetailsSnapshot,
        formatDate: (Date) -> String
    ) -> ForgeReadInspectorPresentation {
        let summary = details.summary
        var metadata = issueSummaryMetadata(summary, formatDate: formatDate)
        metadata += [
            readMetadata("Assignees", section: details.assignees, value: actorList),
            readMetadata("Milestone", section: details.milestone) { $0?.title ?? "None" },
        ]
        let body = markdown(details.bodyMarkdown)
        let timeline = timeline(details.timeline)
        return ForgeReadInspectorPresentation(
            item: .issue(summary),
            title: summary.title,
            subtitle: "Issue #\(summary.number.rawValue) • \(summary.state == .open ? "Open" : "Closed")",
            author: actor(summary.author),
            metadata: metadata,
            bodyMarkdown: body.value,
            bodyUnavailableMessage: body.unavailable,
            timeline: timeline.items,
            timelineUnavailableMessage: timeline.unavailable,
            nextTimelineCursor: timeline.nextCursor,
            nextCheckCursor: nil,
            freshnessMessage: freshness(snapshot, formatDate: formatDate)
        )
    }

    private static func summaryMetadata(
        _ summary: ForgePullRequestSummary,
        formatDate: (Date) -> String
    ) -> [ForgeReadInspectorMetadata] {
        [
            readMetadata("Author", section: summary.author, value: authorName),
            branchesMetadata(head: summary.head, base: summary.base),
            readMetadata("Labels", section: summary.labels, value: labelList),
            readMetadata("Check Rollup", section: summary.checkRollup, value: checkRollup),
            readMetadata("Review", section: summary.reviewRollup, value: reviewRollup),
            ForgeReadInspectorMetadata(title: "Updated", value: formatDate(summary.updatedAt), isUnavailable: false),
        ]
    }

    private static func issueSummaryMetadata(
        _ summary: ForgeIssueSummary,
        formatDate: (Date) -> String
    ) -> [ForgeReadInspectorMetadata] {
        [
            readMetadata("Author", section: summary.author, value: authorName),
            readMetadata("Labels", section: summary.labels, value: labelList),
            ForgeReadInspectorMetadata(title: "Updated", value: formatDate(summary.updatedAt), isUnavailable: false),
        ]
    }

    private static func branchesMetadata(
        head: ForgeReadSection<ForgeBranchReference>,
        base: ForgeReadSection<ForgeBranchReference>
    ) -> ForgeReadInspectorMetadata {
        switch (head, base) {
        case let (.available(head), .available(base)):
            ForgeReadInspectorMetadata(
                title: "Branches",
                value: "\(head.name.value) → \(base.name.value)",
                isUnavailable: false
            )
        case let (.unavailable(reason), _), let (_, .unavailable(reason)):
            ForgeReadInspectorMetadata(
                title: "Branches",
                value: unavailableDescription(reason),
                isUnavailable: true
            )
        }
    }

    private static func readMetadata<Value: Codable & Hashable & Sendable>(
        _ title: String,
        section: ForgeReadSection<Value>,
        value: (Value) -> String
    ) -> ForgeReadInspectorMetadata {
        switch section {
        case let .available(content):
            ForgeReadInspectorMetadata(title: title, value: value(content), isUnavailable: false)
        case let .unavailable(reason):
            ForgeReadInspectorMetadata(
                title: title,
                value: unavailableDescription(reason),
                isUnavailable: true
            )
        }
    }

    private static func markdown(
        _ section: ForgeReadSection<String>
    ) -> (value: String?, unavailable: String?) {
        switch section {
        case let .available(markdown): (markdown, nil)
        case let .unavailable(reason): (nil, unavailableDescription(reason))
        }
    }

    private static func timeline(
        _ section: ForgeReadSection<ForgePage<ForgeTimelineItem>>
    ) -> (items: [ForgeReadTimelinePresentation], unavailable: String?, nextCursor: ForgePageCursor?) {
        switch section {
        case let .available(page):
            let items = page.items.sorted { $0.occurredAt < $1.occurredAt }.map(timelineItem)
            return (items, nil, page.nextCursor)
        case let .unavailable(reason):
            return ([], unavailableDescription(reason), nil)
        }
    }

    private static func timelineItem(_ item: ForgeTimelineItem) -> ForgeReadTimelinePresentation {
        let actor = item.actor.map(authorName) ?? "GitHub"
        let summary: String
        let markdown: String?
        let destination: ForgeDestination?
        switch item.event {
        case let .comment(bodyMarkdown, _):
            summary = "commented"
            markdown = bodyMarkdown
            destination = nil
        case let .review(state, bodyMarkdown, _):
            summary = "reviewed: \(reviewState(state))"
            markdown = bodyMarkdown.isEmpty ? nil : bodyMarkdown
            destination = nil
        case .closed:
            summary = "closed this item"
            markdown = nil
            destination = nil
        case .reopened:
            summary = "reopened this item"
            markdown = nil
            destination = nil
        case .merged:
            summary = "merged this pull request"
            markdown = nil
            destination = nil
        case let .assigned(assigned):
            summary = "assigned \(assigned.login)"
            markdown = nil
            destination = nil
        case let .unassigned(unassigned):
            summary = "unassigned \(unassigned.login)"
            markdown = nil
            destination = nil
        case let .labeled(label):
            summary = "added label \(label.name)"
            markdown = nil
            destination = nil
        case let .unlabeled(label):
            summary = "removed label \(label.name)"
            markdown = nil
            destination = nil
        case let .milestoneChanged(milestone):
            summary = milestone.map { "set milestone \($0.title)" } ?? "removed the milestone"
            markdown = nil
            destination = nil
        case let .milestoneTitleChanged(title):
            summary = title.map { "renamed the milestone to \($0)" } ?? "updated the milestone"
            markdown = nil
            destination = nil
        case let .renamed(previousTitle, currentTitle):
            summary = "renamed “\(previousTitle)” to “\(currentTitle)”"
            markdown = nil
            destination = nil
        case let .crossReferenced(target, title):
            summary = "referenced \(title)"
            markdown = nil
            destination = target
        }
        return ForgeReadTimelinePresentation(
            id: item.id,
            actor: actor,
            occurredAt: item.occurredAt,
            summary: summary,
            markdown: markdown,
            destination: destination
        )
    }

    private static func unavailableDescription(_ reason: ForgeReadUnavailableReason) -> String {
        switch reason {
        case .notRequested: "Not loaded"
        case .partialResponse: "Unavailable in partial response"
        case .authenticationRequired: "Sign in required"
        case .permissionDenied: "Permission required"
        case .unsupported: "Not supported"
        }
    }

    private static func authorName(_ author: ForgeAuthor) -> String {
        switch author {
        case let .actor(actor): actor.displayName ?? actor.login
        case .deleted: "Deleted user"
        }
    }

    private static func actor(_ section: ForgeReadSection<ForgeAuthor>) -> ForgeActor? {
        guard case let .available(.actor(actor)) = section else { return nil }
        return actor
    }

    private static func actorList(_ actors: [ForgeActor]) -> String {
        actors.isEmpty ? "None" : actors.map { $0.displayName ?? $0.login }.joined(separator: ", ")
    }

    private static func reviewerList(_ reviewers: [ForgeReviewer]) -> String {
        guard !reviewers.isEmpty else { return "None" }
        return reviewers.map { reviewer in
            let name: String = switch reviewer.participant {
            case let .actor(actor): actor.displayName ?? actor.login
            case let .team(team): team.name
            }
            if reviewer.isRequested {
                return "\(name) (requested)"
            }
            if let state = reviewer.latestReviewState {
                return "\(name) (\(reviewState(state)))"
            }
            return name
        }.joined(separator: ", ")
    }

    private static func labelList(_ labels: [ForgeLabel]) -> String {
        labels.isEmpty ? "None" : labels.map(\.name).joined(separator: ", ")
    }

    private static func checkList(_ checks: [ForgeCheck]) -> String {
        guard !checks.isEmpty else { return "None" }
        return checks.map { "\($0.name): \(checkState($0.state))" }.joined(separator: ", ")
    }

    private static func pullRequestState(_ summary: ForgePullRequestSummary) -> String {
        if summary.isDraft, summary.state == .open {
            return "Draft"
        }
        switch summary.state {
        case .open: return "Open"
        case .closed: return "Closed"
        case .merged: return "Merged"
        }
    }

    private static func checkState(_ state: ForgeCheckState) -> String {
        switch state {
        case .succeeded: "Passed"
        case .failed: "Failed"
        case .running: "Running"
        case .attentionRequired: "Attention required"
        case .neutral: "Neutral"
        }
    }

    private static func checkRollup(_ rollup: ForgeCheckRollup) -> String {
        switch rollup {
        case .succeeded: "Passed"
        case .failed: "Failed"
        case .running: "Running"
        case .attentionRequired: "Attention required"
        case .neutral: "Neutral"
        }
    }

    private static func reviewRollup(_ rollup: ForgeReviewRollup) -> String {
        switch rollup {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Review required"
        case .noDecision: "No decision"
        }
    }

    private static func reviewState(_ state: ForgeReviewState) -> String {
        switch state {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .commented: "Commented"
        case .dismissed: "Dismissed"
        }
    }

    private static func freshness(
        _ snapshot: ForgeReadSurfaceDetailsSnapshot,
        formatDate: (Date) -> String
    ) -> String? {
        var parts: [String] = []
        if snapshot.isStale {
            parts.append("Stale data from \(formatDate(snapshot.fetchedAt))")
        }
        if snapshot.isPartial {
            parts.append("Some sections are unavailable")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}
