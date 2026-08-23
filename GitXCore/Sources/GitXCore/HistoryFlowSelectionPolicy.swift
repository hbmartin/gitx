import Foundation

/// Translates History selection state into one deterministic external-analysis request.
public struct HistoryFlowCommitInput: Equatable, Sendable {
    public let sha: String
    public let firstParentSHA: String?
    public let isWorkingState: Bool

    public init(sha: String, firstParentSHA: String?, isWorkingState: Bool) {
        self.sha = sha
        self.firstParentSHA = firstParentSHA
        self.isWorkingState = isWorkingState
    }
}

public struct HistoryFlowRevisionRequest: Equatable, Sendable {
    public let repositoryURL: URL
    public let base: String
    public let target: String

    public init(repositoryURL: URL, base: String, target: String) {
        self.repositoryURL = repositoryURL
        self.base = base
        self.target = target
    }
}

public enum HistoryFlowSelectionDecision: Equatable, Sendable {
    case inactive
    case message(String)
    case load(HistoryFlowRevisionRequest)
}

public struct HistoryFlowSelectionPolicy: Sendable {
    public static let flowTabIndex = 2

    public init() {}

    public func decision(
        selectedTabIndex: Int,
        repositoryURL: URL?,
        commits: [HistoryFlowCommitInput]
    ) -> HistoryFlowSelectionDecision {
        guard selectedTabIndex == Self.flowTabIndex else { return .inactive }
        guard commits.count == 1, let commit = commits.first else {
            return .message("Select one commit to review its flow delta.")
        }
        guard !commit.isWorkingState else {
            return .message("Flow review is available for committed revisions.")
        }
        guard let base = commit.firstParentSHA else {
            return .message("This root commit has no parent revision to compare.")
        }
        guard let repositoryURL else {
            return .message("The repository working directory is unavailable.")
        }
        return .load(HistoryFlowRevisionRequest(repositoryURL: repositoryURL, base: base, target: commit.sha))
    }
}
