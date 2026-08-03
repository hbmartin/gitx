import ForgeKit
import Foundation
import OSLog // swiftlint:disable:this unused_import

/// Adapts the paginated GitHub.com read surface to ForgeKit's account-owned
/// Attention polling boundary. One instance is bound to one current Credential
/// through its `GitHubReadAdapter`.
public actor GitHubAttentionSnapshotFetcher: ForgeAttentionSnapshotFetching {
    /// GitHub prices nested connections against the requested outer page size,
    /// even when a repository returns only one candidate. Paging one candidate
    /// at a time keeps the accepted 40-activity/40-thread depth and complete
    /// cursor traversal while making GraphQL point cost follow actual results.
    private static let candidatePageSize = 1

    private static let logger = Logger(
        subsystem: "com.gitx.gitx",
        category: "github-attention-fetch"
    )

    private let adapter: GitHubReadAdapter
    private let now: @Sendable () -> Date

    public init(
        adapter: GitHubReadAdapter,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.adapter = adapter
        self.now = now
    }

    public func snapshot(
        for watchedRepository: ForgeWatchedRepository
    ) async throws -> ForgeAttentionRepositorySnapshot {
        let first = try await adapter.currentAttentionCandidates(
            repository: watchedRepository.key.repository,
            pageSize: Self.candidatePageSize
        )
        guard first.ownership.credential.accountID == watchedRepository.key.accountID else {
            throw GitHubReadError.authenticationRequired
        }
        let viewer = first.value.viewer
        var candidates = first.value.candidates.items
        var cursor = first.value.candidates.nextCursor
        var completeness: ForgeSnapshotCompleteness = first.completeness == .complete
            ? .complete
            : .partial(unavailableSections: [])
        var pageCount = 1
        var requestedCursors = Set<ForgePageCursor>()

        while let currentCursor = cursor {
            guard requestedCursors.insert(currentCursor).inserted else {
                Self.logger.error("Rejected cyclic Attention pagination cursor")
                throw GitHubReadError.malformedResponse
            }
            let next = try await adapter.currentAttentionCandidates(
                repository: watchedRepository.key.repository,
                pageSize: Self.candidatePageSize,
                after: currentCursor
            )
            guard next.ownership.credential.accountID == watchedRepository.key.accountID else {
                throw GitHubReadError.authenticationRequired
            }
            guard next.value.viewer == viewer else {
                throw GitHubReadError.malformedResponse
            }
            candidates.append(contentsOf: next.value.candidates.items)
            cursor = next.value.candidates.nextCursor
            if next.completeness == .partial {
                completeness = .partial(unavailableSections: [])
            }
            pageCount += 1
        }
        Self.logger.info(
            "Fetched current Attention candidates across \(pageCount) page(s); partial=\(completeness != .complete)"
        )
        return ForgeAttentionRepositorySnapshot(
            watchedRepositoryKey: watchedRepository.key,
            viewer: viewer,
            candidates: candidates,
            fetchedAt: now(),
            completeness: completeness
        )
    }
}
