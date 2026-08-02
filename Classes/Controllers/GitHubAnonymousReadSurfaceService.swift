import ForgeKit
import Foundation
import GitHubForgeAdapter

/// Explicit-only anonymous adapter for a single public GitHub.com repository.
/// The first request is caused by opening the surface; every later request is
/// an explicit search, filter, pagination, detail selection, or refresh action.
@MainActor
final class ForgeGitHubAnonymousReadSurfaceService: ForgeReadSurfaceServing {
    private let repository: ForgeRepositoryIdentity
    private let adapter: GitHubAnonymousRESTAdapter
    private var hasIssuedRequest = false

    init(
        repository: ForgeRepositoryIdentity,
        adapter: GitHubAnonymousRESTAdapter = ForgeAnonymousRESTProcessRuntime.adapter
    ) {
        self.repository = repository
        self.adapter = adapter
    }

    func loadItems(
        kind: ForgeReadSurfaceKind,
        query: ForgeReadSurfaceQuery,
        after cursor: ForgePageCursor?
    ) async throws -> ForgeReadSurfacePage {
        let reason = nextExplicitReason()
        let result: ForgeReadSurfacePage
        switch kind {
        case .pullRequests:
            let response = try await adapter.pullRequests(
                repository: repository,
                page: cursor,
                states: pullRequestStates(query.stateFilter),
                reason: reason
            )
            result = ForgeReadSurfacePage(
                items: response.value.items.map(ForgeRepositoryItem.pullRequest),
                nextCursor: response.value.nextCursor,
                totalCount: response.value.totalCount,
                fetchedAt: response.fetchedAt,
                isPartial: true
            )
        case .issues:
            let response = try await adapter.issues(
                repository: repository,
                page: cursor,
                states: issueStates(query.stateFilter),
                reason: reason
            )
            result = ForgeReadSurfacePage(
                items: response.value.items.map(ForgeRepositoryItem.issue),
                nextCursor: response.value.nextCursor,
                totalCount: response.value.totalCount,
                fetchedAt: response.fetchedAt,
                isPartial: true
            )
        }
        guard !query.searchText.isEmpty else { return result }
        let needle = query.searchText.localizedLowercase
        return ForgeReadSurfacePage(
            items: result.items.filter { item in
                let row = ForgeReadSurfaceRow(item: item)
                return row.title.localizedLowercase.contains(needle) ||
                    row.number.localizedLowercase.contains(needle) ||
                    row.author.localizedLowercase.contains(needle)
            },
            nextCursor: result.nextCursor,
            fetchedAt: result.fetchedAt,
            isPartial: true
        )
    }

    func loadDetails(
        for item: ForgeRepositoryItem,
        timelineAfter: ForgePageCursor?,
        checkAfter: ForgePageCursor?
    ) async throws -> ForgeReadSurfaceDetailsSnapshot {
        guard item.repository == repository else {
            throw ForgeGitHubReadSurfaceServiceError.repositoryMismatch
        }
        let reason = nextExplicitReason()
        switch item {
        case let .pullRequest(summary):
            let response = try await adapter.pullRequestDetails(
                repository: repository,
                number: summary.number,
                reason: reason
            )
            return ForgeReadSurfaceDetailsSnapshot(
                details: .pullRequest(response.value),
                fetchedAt: response.fetchedAt,
                isPartial: true
            )
        case let .issue(summary):
            let response = try await adapter.issueDetails(
                repository: repository,
                number: summary.number,
                reason: reason
            )
            return ForgeReadSurfaceDetailsSnapshot(
                details: .issue(response.value),
                fetchedAt: response.fetchedAt,
                isPartial: true
            )
        }
    }

    private func nextExplicitReason() -> ForgeRefreshReason {
        defer { hasIssuedRequest = true }
        return hasIssuedRequest ? .manual : .repositoryOpened
    }

    private func pullRequestStates(_ filter: ForgeReadStateFilter) -> Set<ForgePullRequestState>? {
        switch filter {
        case .open: [.open]
        case .closed: [.closed, .merged]
        case .all: nil
        }
    }

    private func issueStates(_ filter: ForgeReadStateFilter) -> Set<ForgeIssueState>? {
        switch filter {
        case .open: [.open]
        case .closed: [.closed]
        case .all: nil
        }
    }
}
