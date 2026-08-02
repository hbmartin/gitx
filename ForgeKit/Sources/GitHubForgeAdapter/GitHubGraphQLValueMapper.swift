import ForgeKit

// This normalization boundary is exercised by its package test target; SwiftLint
// analyzes production and test targets separately and cannot observe those uses.
// swiftlint:disable unused_declaration
enum GitHubGraphQLValueMapper {
    static func repositoryVisibility(
        _ value: GitHubAPI.RepositoryVisibility?
    ) -> ForgeRepositoryVisibility {
        switch value {
        case .public: .public
        case .private: .private
        case .internal: .internal
        case nil: .unknown
        }
    }

    static func pullRequestState(_ value: GitHubAPI.PullRequestState?) -> ForgePullRequestState? {
        switch value {
        case .open: .open
        case .closed: .closed
        case .merged: .merged
        case nil: nil
        }
    }

    static func issueState(_ value: GitHubAPI.IssueState?) -> ForgeIssueState? {
        switch value {
        case .open: .open
        case .closed: .closed
        case nil: nil
        }
    }

    static func reviewRollup(
        _ value: GitHubAPI.PullRequestReviewDecision?
    ) -> ForgeReviewRollup {
        switch value {
        case .approved: .approved
        case .changesRequested: .changesRequested
        case .reviewRequired: .reviewRequired
        case nil: .noDecision
        }
    }

    static func mergeability(_ value: GitHubAPI.MergeableState?) -> ForgeMergeability {
        switch value {
        case .mergeable: .mergeable
        case .conflicting: .conflicting
        case .unknown, nil: .unknown
        }
    }

    static func checkState(
        status: GitHubAPI.CheckStatusState?,
        conclusion: GitHubAPI.CheckConclusionState?
    ) -> ForgeCheckState {
        guard status == .completed else {
            return status == nil ? .attentionRequired : .running
        }

        return switch conclusion {
        case .success: .succeeded
        case .failure, .startupFailure, .timedOut: .failed
        case .actionRequired, nil: .attentionRequired
        case .cancelled, .neutral, .skipped, .stale: .neutral
        }
    }

    static func statusContextState(_ value: GitHubAPI.StatusState?) -> ForgeCheckState {
        switch value {
        case .success: .succeeded
        case .error, .failure: .failed
        case .expected, .pending: .running
        case nil: .attentionRequired
        }
    }
}

// swiftlint:enable unused_declaration
