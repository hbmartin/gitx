import ForgeKit
import Foundation
import OSLog

/// Adapts the paginated GitHub.com read surface to ForgeKit's account-owned
/// Attention polling boundary. One instance is bound to one current Credential
/// through its `GitHubReadAdapter`.
public actor GitHubAttentionSnapshotFetcher: ForgeAttentionSnapshotFetching {
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
            repository: watchedRepository.key.repository
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

        while let currentCursor = cursor {
            let next = try await adapter.currentAttentionCandidates(
                repository: watchedRepository.key.repository,
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
