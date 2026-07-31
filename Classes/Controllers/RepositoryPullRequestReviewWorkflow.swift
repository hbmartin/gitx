import ForgeKit
import Foundation
import OSLog // swiftlint:disable:this unused_import

// MARK: - Exact mutation identity and provider-neutral workspace

nonisolated struct RepositoryPullRequestReviewIdentity: Hashable, Sendable {
    let accountID: ForgeAccountID
    let repository: ForgeRepositoryIdentity
    let number: ForgeItemNumber

    init(accountID: ForgeAccountID, repository: ForgeRepositoryIdentity, number: ForgeItemNumber) throws {
        guard accountID.forge == repository.forge else {
            throw ForgeReviewMutationError.mismatchedForge
        }
        self.accountID = accountID
        self.repository = repository
        self.number = number
    }
}

nonisolated struct RepositoryPullRequestReviewThreadRecord: Hashable, Sendable {
    let pullRequest: ForgeItemNumber
    let presentation: ForgeReviewThreadPresentation
    /// A local display hint for an outdated thread. The immutable server anchor
    /// remains in `presentation.thread.anchor` and is never rewritten.
    let exactOutdatedLocalAnchor: ForgeReviewAnchor?
    let suggestedChanges: [ForgeSuggestedChange]

    init(
        pullRequest: ForgeItemNumber,
        presentation: ForgeReviewThreadPresentation,
        exactOutdatedLocalAnchor: ForgeReviewAnchor? = nil,
        suggestedChanges: [ForgeSuggestedChange] = []
    ) throws {
        let thread = presentation.thread
        let commentsMatchRepository: Bool = switch thread.comments {
        case let .available(page):
            page.items.allSatisfy {
                $0.repository == thread.repository && $0.id.forge == thread.repository.forge
            }
        case .unavailable:
            true
        }
        guard suggestedChanges.allSatisfy({
            $0.repository == thread.repository && $0.pullRequest == pullRequest
        }), commentsMatchRepository else {
            throw ForgeReviewMutationError.mismatchedPullRequest
        }
        let serverAnchor: ForgeReviewAnchor? = switch thread.anchor {
        case let .available(anchor): anchor
        case .unavailable: nil
        }
        if let exactOutdatedLocalAnchor {
            guard thread.isOutdated,
                  exactOutdatedLocalAnchor.subject == .line,
                  let serverAnchor,
                  exactOutdatedLocalAnchor.path == serverAnchor.path
            else {
                throw ForgeReviewMutationError.invalidContext
            }
        }
        if !suggestedChanges.isEmpty {
            guard !thread.isOutdated,
                  let serverAnchor,
                  suggestedChanges.allSatisfy({ $0.path == serverAnchor.path })
            else {
                throw ForgeReviewMutationError.invalidContext
            }
        }
        self.pullRequest = pullRequest
        self.presentation = presentation
        self.exactOutdatedLocalAnchor = thread.isOutdated ? exactOutdatedLocalAnchor : nil
        self.suggestedChanges = suggestedChanges
    }
}

nonisolated struct RepositoryPullRequestReviewWorkspace: Hashable, Sendable {
    let identity: RepositoryPullRequestReviewIdentity
    let displayedHead: ForgeCommitID
    let base: ForgeBranchReference
    let title: String
    let isDraft: Bool
    let threads: [RepositoryPullRequestReviewThreadRecord]
    let reviewers: ForgeReadSection<[ForgeReviewer]>
    let mutationContext: ForgePullRequestMutationContext
    let mergeSnapshot: ForgePullRequestMergeSnapshot
    let headBranchDeletionSnapshot: ForgeHeadBranchDeletionSnapshot?
    let canOfferHeadBranchDeletionAfterMerge: Bool
    let canUpdateBranch: Bool
    /// False only when a caller deliberately presents cached read data. No
    /// mutation control may be enabled until an authoritative refresh.
    let isMutationStateFresh: Bool
    let browserDestination: ForgeDestination
    let fetchedAt: Date

    init(
        identity: RepositoryPullRequestReviewIdentity,
        displayedHead: ForgeCommitID,
        base: ForgeBranchReference,
        title: String,
        isDraft: Bool,
        threads: [RepositoryPullRequestReviewThreadRecord],
        reviewers: ForgeReadSection<[ForgeReviewer]>,
        mutationContext: ForgePullRequestMutationContext,
        mergeSnapshot: ForgePullRequestMergeSnapshot,
        headBranchDeletionSnapshot: ForgeHeadBranchDeletionSnapshot? = nil,
        canUpdateBranch: Bool,
        isMutationStateFresh: Bool = true,
        fetchedAt: Date
    ) throws {
        guard identity.repository == mutationContext.repository,
              identity.number == mutationContext.number,
              identity.accountID == mutationContext.accountID,
              displayedHead == mutationContext.head.commit,
              base == mutationContext.base,
              isDraft == mutationContext.isDraft,
              mergeSnapshot.context == mutationContext,
              threads.allSatisfy({
                  $0.presentation.thread.repository == identity.repository
                      && $0.pullRequest == identity.number
                      && $0.suggestedChanges.allSatisfy { $0.displayedHead == displayedHead }
              })
        else {
            throw ForgeReviewMutationError.mismatchedPullRequest
        }
        if let headBranchDeletionSnapshot,
           headBranchDeletionSnapshot.mergeSnapshot.context != mutationContext
        {
            throw ForgeReviewMutationError.mismatchedPullRequest
        }
        guard !canUpdateBranch || (
            mutationContext.allowedOperations.contains(.updatePullRequestBranch)
                && mergeSnapshot.warnings.contains(.branchBehind)
        ) else {
            throw ForgeReviewMutationError.invalidContext
        }
        self.identity = identity
        self.displayedHead = displayedHead
        self.base = base
        self.title = title
        self.isDraft = isDraft
        self.threads = threads
        self.reviewers = reviewers
        self.mutationContext = mutationContext
        self.mergeSnapshot = mergeSnapshot
        self.headBranchDeletionSnapshot = headBranchDeletionSnapshot
        canOfferHeadBranchDeletionAfterMerge = headBranchDeletionSnapshot.map(
            RepositoryPullRequestHeadDeletionOfferPolicy.canOfferAfterMerge
        ) ?? false
        self.canUpdateBranch = canUpdateBranch
        self.isMutationStateFresh = isMutationStateFresh
        browserDestination = .pullRequest(identity.repository, identity.number)
        self.fetchedAt = fetchedAt
    }

    func markingMutationStateFresh(_ isFresh: Bool) throws -> Self {
        try Self(
            identity: identity,
            displayedHead: displayedHead,
            base: base,
            title: title,
            isDraft: isDraft,
            threads: threads,
            reviewers: reviewers,
            mutationContext: mutationContext,
            mergeSnapshot: mergeSnapshot,
            headBranchDeletionSnapshot: headBranchDeletionSnapshot,
            canUpdateBranch: canUpdateBranch,
            isMutationStateFresh: isFresh,
            fetchedAt: fetchedAt
        )
    }
}

nonisolated enum RepositoryPullRequestHeadDeletionDispatchPolicy {
    static func validate(
        request: ForgeHeadBranchDeletionRequest,
        workspace: RepositoryPullRequestReviewWorkspace,
        checkedOutHead: ForgeCommitID?
    ) throws {
        guard workspace.isMutationStateFresh,
              workspace.identity.accountID == request.accountID,
              workspace.identity.repository == request.repository,
              workspace.identity.number == request.pullRequest,
              workspace.mutationContext.state == .merged,
              workspace.mutationContext.head.name == request.branch,
              workspace.displayedHead == request.expectedHead
        else {
            throw RepositoryPullRequestReviewServiceError.stalePullRequest
        }
        guard checkedOutHead != request.expectedHead else {
            throw RepositoryPullRequestReviewServiceError.authoritative(
                RepositoryPullRequestMutationUnavailablePresenter.message(.checkedOutBranch)
            )
        }
    }
}

/// Determines only whether the merge confirmation may offer a remembered
/// post-merge deletion choice. Actual deletion remains unavailable until the
/// merge is authoritative and repeats the complete destructive preflight.
nonisolated enum RepositoryPullRequestHeadDeletionOfferPolicy {
    static func canOfferAfterMerge(_ snapshot: ForgeHeadBranchDeletionSnapshot) -> Bool {
        let context = snapshot.mergeSnapshot.context
        return context.environment == .available
            && context.state == .open
            && context.allowedOperations.contains(.deleteHeadBranch)
            && snapshot.isSameRepository
            && !snapshot.isDefaultBranch
            && !snapshot.isProtected
            && snapshot.viewerCanDelete
            && !snapshot.hasCheckedOutSafetyConflict
    }
}

nonisolated enum RepositoryPullRequestMergeCompletion: Equatable, Sendable {
    case merged
    case mergedAndDeletedHeadBranch
    case mergedWithHeadBranchDeletionFailure(String)
}

// MARK: - Mutation, draft, local Git, and preferences boundaries

nonisolated enum RepositoryPullRequestReviewServiceError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case offline
    case rateLimited(until: Date)
    case authoritative(String)
    case outcomeUnknown
    case stalePullRequest
    case invalidWorkspace
    case unsafeLocalEdit

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "This Pull Request operation is unavailable."
        case .offline:
            "GitX is offline. The mutation was not queued."
        case let .rateLimited(until):
            "Rate limited until \(until.formatted(date: .abbreviated, time: .shortened))."
        case let .authoritative(message):
            message
        case .outcomeUnknown:
            "The server outcome is unknown. GitX will reconcile it on refresh without retrying."
        case .stalePullRequest:
            "The Pull Request changed. Refresh and confirm again."
        case .invalidWorkspace:
            "GitX rejected Forge state for a different account, repository, or Pull Request."
        case .unsafeLocalEdit:
            "The local file is not eligible for this suggested change."
        }
    }
}

nonisolated enum RepositoryPullRequestReviewAnchorPolicy {
    static func lineSelection(_ anchor: ForgeReviewAnchor) throws -> ForgeLineSelection {
        guard anchor.subject == .line,
              let side = anchor.side,
              (anchor.startSide == nil) == (anchor.startLine == nil),
              anchor.startSide == nil || anchor.startSide == side
        else {
            throw ForgeReviewMutationError.anchorUnavailable
        }

        let start: Int
        let end: Int
        switch side {
        case .right:
            guard let line = anchor.line else {
                throw ForgeReviewMutationError.anchorUnavailable
            }
            start = anchor.startLine ?? line
            end = line
        case .left:
            guard let line = anchor.originalLine ?? anchor.line else {
                throw ForgeReviewMutationError.anchorUnavailable
            }
            start = anchor.originalStartLine ?? anchor.startLine ?? line
            end = line
        }

        do {
            return try ForgeLineSelection(start: start, end: end)
        } catch {
            throw ForgeReviewMutationError.anchorUnavailable
        }
    }

    static func validateInlineAnchor(
        _ anchor: ForgeReviewAnchor,
        context: ForgeReviewContext
    ) throws -> ForgeLineSelection {
        guard anchor.path == context.path else {
            throw ForgeReviewMutationError.anchorUnavailable
        }
        let selection = try lineSelection(anchor)
        guard selection.end - selection.start + 1 == context.lines.count else {
            throw ForgeReviewMutationError.invalidContext
        }
        return selection
    }
}

nonisolated protocol RepositoryPullRequestReviewMutationServing: Sendable {
    func loadWorkspace(
        identity: RepositoryPullRequestReviewIdentity
    ) async throws -> RepositoryPullRequestReviewWorkspace

    func publishInlineReview(
        _ publication: ForgeInlineReviewPublication
    ) async throws -> RepositoryPullRequestReviewWorkspace

    func replyToReviewThread(
        _ publication: ForgeReviewThreadReplyPublication
    ) async throws -> RepositoryPullRequestReviewWorkspace

    func setReviewThreadResolution(
        identity: RepositoryPullRequestReviewIdentity,
        threadID: ForgeObjectID,
        mutation: ForgeReviewThreadResolutionMutation
    ) async throws

    func submitFormalReview(
        _ submission: ForgeFormalReviewSubmission
    ) async throws -> RepositoryPullRequestReviewWorkspace

    func performLifecycle(
        _ request: ForgePullRequestLifecycleRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace

    /// Must refetch from GitHub immediately; cached state is not eligible.
    func freshMergeSnapshot(
        identity: RepositoryPullRequestReviewIdentity
    ) async throws -> ForgePullRequestMergeSnapshot

    func mergePullRequest(
        _ request: ForgePullRequestMergeRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace

    func changeMergeQueue(
        _ request: ForgePullRequestMergeQueueRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace

    /// Must revalidate the merged PR, exact head ref OID, protection/default
    /// state, permission, and current local checkout conflict immediately
    /// before the destructive request is constructed.
    func freshHeadBranchDeletionSnapshot(
        identity: RepositoryPullRequestReviewIdentity
    ) async throws -> ForgeHeadBranchDeletionSnapshot

    func deleteHeadBranch(_ request: ForgeHeadBranchDeletionRequest) async throws
}

nonisolated struct UnavailableRepositoryPullRequestReviewMutationService:
    RepositoryPullRequestReviewMutationServing
{
    private func fail<T>() throws -> T {
        throw RepositoryPullRequestReviewServiceError.unavailable
    }

    func loadWorkspace(
        identity _: RepositoryPullRequestReviewIdentity
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        try fail()
    }

    func publishInlineReview(
        _: ForgeInlineReviewPublication
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        try fail()
    }

    func replyToReviewThread(
        _: ForgeReviewThreadReplyPublication
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        try fail()
    }

    func setReviewThreadResolution(
        identity _: RepositoryPullRequestReviewIdentity,
        threadID _: ForgeObjectID,
        mutation _: ForgeReviewThreadResolutionMutation
    ) async throws {
        let _: Void = try fail()
    }

    func submitFormalReview(
        _: ForgeFormalReviewSubmission
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        try fail()
    }

    func performLifecycle(
        _: ForgePullRequestLifecycleRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        try fail()
    }

    func freshMergeSnapshot(
        identity _: RepositoryPullRequestReviewIdentity
    ) async throws -> ForgePullRequestMergeSnapshot {
        try fail()
    }

    func mergePullRequest(
        _: ForgePullRequestMergeRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        try fail()
    }

    func changeMergeQueue(
        _: ForgePullRequestMergeQueueRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        try fail()
    }

    func freshHeadBranchDeletionSnapshot(
        identity _: RepositoryPullRequestReviewIdentity
    ) async throws -> ForgeHeadBranchDeletionSnapshot {
        try fail()
    }

    func deleteHeadBranch(_: ForgeHeadBranchDeletionRequest) async throws {
        let _: Void = try fail()
    }
}

nonisolated protocol RepositoryPullRequestLocalReviewServing: Sendable {
    func reanchorCandidates(
        for context: ForgeReviewContext,
        currentHead: ForgeCommitID
    ) async throws -> [ForgeReviewReanchorCandidate]

    func checkedOutHead() async throws -> ForgeCommitID?
    func filesWithUncommittedEdits() async throws -> Set<ForgeFilePath>
    func contents(of path: ForgeFilePath) async throws -> String
    func writeUnstaged(contents: String, to path: ForgeFilePath) async throws
    /// Revalidates checkout and dirty-file state, then compares the exact file
    /// bytes again immediately before one replacement so a changed target
    /// fails closed.
    func applySuggestedChange(_ change: ForgeSuggestedChange) async throws
    func fetchBase(_ base: ForgeBranchReference) async throws
    func checkOutBase(_ base: ForgeBranchReference) async throws
}

nonisolated struct UnavailableRepositoryPullRequestLocalReviewService: RepositoryPullRequestLocalReviewServing {
    private func fail<T>() throws -> T {
        throw RepositoryPullRequestReviewServiceError.unavailable
    }

    func reanchorCandidates(
        for _: ForgeReviewContext,
        currentHead _: ForgeCommitID
    ) async throws -> [ForgeReviewReanchorCandidate] {
        try fail()
    }

    func checkedOutHead() async throws -> ForgeCommitID? {
        try fail()
    }

    func filesWithUncommittedEdits() async throws -> Set<ForgeFilePath> {
        try fail()
    }

    func contents(of _: ForgeFilePath) async throws -> String {
        try fail()
    }

    func writeUnstaged(contents _: String, to _: ForgeFilePath) async throws {
        let _: Void = try fail()
    }

    func applySuggestedChange(_: ForgeSuggestedChange) async throws {
        let _: Void = try fail()
    }

    func fetchBase(_: ForgeBranchReference) async throws {
        let _: Void = try fail()
    }

    func checkOutBase(_: ForgeBranchReference) async throws {
        let _: Void = try fail()
    }
}

/// Keeps every thread and comment that was received before a connection page
/// failed. A synthetic missing-count slot lets the presenter render an
/// explicit unavailable-comment tombstone without inventing comment data.
nonisolated enum RepositoryPullRequestReviewPartialDataPolicy {
    static func mergingKnownComments(
        fresh: [ForgeReviewComment],
        previous thread: ForgeReviewThread?
    ) -> [ForgeReviewComment] {
        guard let thread,
              case let .available(page) = thread.comments
        else { return fresh }
        var seen: Set<ForgeObjectID> = []
        return (fresh + page.items).filter { seen.insert($0.id).inserted }
    }

    static func markingCommentsPartial(
        in thread: ForgeReviewThread,
        knownComments: [ForgeReviewComment]? = nil
    ) throws -> ForgeReviewThread {
        let comments: [ForgeReviewComment]
        let reportedTotal: Int?
        switch thread.comments {
        case let .available(page):
            comments = knownComments ?? page.items
            reportedTotal = page.totalCount
        case .unavailable:
            guard let knownComments else { return thread }
            comments = knownComments
            reportedTotal = nil
        }
        let explicitPartialTotal = max(reportedTotal ?? 0, comments.count + 1)
        return try ForgeReviewThread(
            repository: thread.repository,
            id: thread.id,
            isResolved: thread.isResolved,
            isOutdated: thread.isOutdated,
            anchor: thread.anchor,
            comments: .available(ForgePage(
                items: comments,
                totalCount: explicitPartialTotal
            ))
        )
    }

    static func preservingMissingThreads(
        fresh: [ForgeReviewThread],
        previous: [RepositoryPullRequestReviewThreadRecord]
    ) throws -> [ForgeReviewThread] {
        var seen = Set(fresh.map(\.id))
        let stale = try previous.compactMap { record -> ForgeReviewThread? in
            let thread = record.presentation.thread
            guard seen.insert(thread.id).inserted else { return nil }
            return try markingCommentsPartial(in: thread)
        }
        return fresh + stale
    }
}

nonisolated enum RepositoryPullRequestReviewLocalRefreshPolicy {
    static func remoteTrackingBranch(
        after action: ForgePullRequestLifecycleAction,
        updatedHead: ForgeBranchReference
    ) -> ForgeBranchReference? {
        action == .updateBranch ? updatedHead : nil
    }
}

/// Serializes every review-local observation and edit. Suggested-change
/// eligibility and the resulting replacement are one actor operation, so
/// another GitX review action cannot invalidate the checked-out-head, dirty
/// file, or exact-context preflight between calls.
actor RepositoryPullRequestLocalReviewService: RepositoryPullRequestLocalReviewServing {
    private let runner: any RepositoryPullRequestGitCommandRunning
    private let workingDirectory: URL?
    private let binding: ForgeRepositoryBinding?
    private let currentBinding: @Sendable () -> ForgeRepositoryBinding?
    private let beforeSuggestedChangeReplacement: (@Sendable () throws -> Void)?

    init(repository: PBGitRepository) {
        runner = RepositoryPullRequestObjectiveGitRunner(repository: repository)
        workingDirectory = repository.workingDirectoryURL()?
            .resolvingSymlinksInPath()
            .standardizedFileURL
        binding = nil
        currentBinding = { nil }
        beforeSuggestedChangeReplacement = nil
    }

    init(
        repository: PBGitRepository,
        binding: ForgeRepositoryBinding,
        currentBinding: (@Sendable () -> ForgeRepositoryBinding?)? = nil
    ) {
        runner = RepositoryPullRequestObjectiveGitRunner(repository: repository)
        workingDirectory = repository.workingDirectoryURL()?
            .resolvingSymlinksInPath()
            .standardizedFileURL
        self.binding = binding
        self.currentBinding = currentBinding ?? { binding }
        beforeSuggestedChangeReplacement = nil
    }

    init(
        runner: any RepositoryPullRequestGitCommandRunning,
        workingDirectory: URL?,
        binding: ForgeRepositoryBinding? = nil,
        currentBinding: (@Sendable () -> ForgeRepositoryBinding?)? = nil,
        beforeSuggestedChangeReplacement: (@Sendable () throws -> Void)? = nil
    ) {
        self.runner = runner
        self.workingDirectory = workingDirectory?
            .resolvingSymlinksInPath()
            .standardizedFileURL
        self.binding = binding
        self.currentBinding = currentBinding ?? { binding }
        self.beforeSuggestedChangeReplacement = beforeSuggestedChangeReplacement
    }

    func reanchorCandidates(
        for context: ForgeReviewContext,
        currentHead: ForgeCommitID
    ) async throws -> [ForgeReviewReanchorCandidate] {
        let contents = try runner.run(["show", "\(currentHead.value):\(context.path.value)"])
        let fileLines = contents.components(separatedBy: .newlines)
        guard !context.lines.isEmpty, context.lines.count <= fileLines.count else { return [] }
        return try fileLines.indices.compactMap { index in
            let end = index + context.lines.count
            guard end <= fileLines.count,
                  Array(fileLines[index ..< end]) == context.lines
            else { return nil }
            let firstLine = index + 1
            let lastLine = firstLine + context.lines.count - 1
            let anchor = ForgeReviewAnchor(
                path: context.path,
                subject: .line,
                side: .right,
                startSide: context.lines.count > 1 ? .right : nil,
                startLine: context.lines.count > 1 ? firstLine : nil,
                line: lastLine
            )
            return try ForgeReviewReanchorCandidate(
                repository: context.repository,
                pullRequest: context.pullRequest,
                displayedHead: currentHead,
                anchor: anchor,
                contextLines: context.lines
            )
        }
    }

    func checkedOutHead() async throws -> ForgeCommitID? {
        let value = try runner.run(["rev-parse", "--verify", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try ForgeCommitID(value)
    }

    func filesWithUncommittedEdits() async throws -> Set<ForgeFilePath> {
        let output = try runner.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        return Set(output.split(separator: "\0").compactMap { entry in
            guard entry.count > 3 else { return nil }
            return try? ForgeFilePath(String(entry.dropFirst(3)))
        })
    }

    func contents(of path: ForgeFilePath) async throws -> String {
        try regularFileContents(for: path).text
    }

    func writeUnstaged(contents: String, to path: ForgeFilePath) async throws {
        try Data(contents.utf8).write(to: regularFileURL(for: path), options: .atomic)
    }

    func applySuggestedChange(_ change: ForgeSuggestedChange) async throws {
        try validateCurrentBindingIfConfigured()
        let selectedHead = try await checkedOutHead()
        let status = try runner.run([
            "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", change.path.value,
        ])
        let currentContents = try regularFileContents(for: change.path)
        switch ForgeSuggestedChangePolicy.decision(
            change: change,
            checkedOutHead: selectedHead,
            filesWithUncommittedEdits: status.isEmpty ? [] : [change.path],
            currentContents: currentContents.text
        ) {
        case let .apply(updatedContents):
            try validateCurrentBindingIfConfigured()
            try beforeSuggestedChangeReplacement?()
            try validateCurrentBindingIfConfigured()
            let finalStatus = try runner.run([
                "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", change.path.value,
            ])
            guard finalStatus.isEmpty else {
                throw ForgeReviewMutationError.uncommittedTargetFile
            }
            try replaceUnchangedFile(
                at: change.path,
                expectedContents: currentContents.data,
                with: Data(updatedContents.utf8)
            )
        case let .unavailable(error):
            throw error
        }
    }

    func fetchBase(_ branch: ForgeBranchReference) async throws {
        let remoteName = try exactRemoteName(for: branch.repository)
        let remoteTrackingRef = "refs/remotes/\(remoteName)/\(branch.name.value)"
        let refspec = "+refs/heads/\(branch.name.value):\(remoteTrackingRef)"
        try validateCurrentBindingIfConfigured()
        _ = try runner.run(["fetch", "--no-tags", remoteName, refspec])
        try validateCurrentBindingIfConfigured()
        guard try commit(at: remoteTrackingRef) == branch.commit else {
            throw RepositoryPullRequestReviewServiceError.stalePullRequest
        }
    }

    func checkOutBase(_ base: ForgeBranchReference) async throws {
        guard let binding, base.repository == binding.primaryRepository else {
            throw RepositoryPullRequestReviewServiceError.invalidWorkspace
        }
        let remoteName = try exactRemoteName(for: base.repository)
        let remoteTrackingRef = "refs/remotes/\(remoteName)/\(base.name.value)"
        guard try commit(at: remoteTrackingRef) == base.commit else {
            throw RepositoryPullRequestReviewServiceError.stalePullRequest
        }
        let status = try runner.run(["status", "--porcelain=v2", "-z", "--untracked-files=normal"])
        guard status.isEmpty else {
            throw RepositoryPullRequestReviewServiceError.unsafeLocalEdit
        }

        let localRef = "refs/heads/\(base.name.value)"
        if let localCommit = try commit(at: localRef) {
            guard localCommit == base.commit else {
                throw RepositoryPullRequestReviewServiceError.stalePullRequest
            }
            try validateCurrentBindingIfConfigured()
            _ = try runner.run(["checkout", base.name.value])
        } else {
            try validateCurrentBindingIfConfigured()
            _ = try runner.run([
                "checkout", "--track", "-b", base.name.value, remoteTrackingRef,
            ])
        }
    }

    private func exactRemoteName(for repository: ForgeRepositoryIdentity) throws -> String {
        try validateCurrentBindingIfConfigured()
        guard binding != nil else { throw RepositoryPullRequestReviewServiceError.invalidWorkspace }
        let remoteNames = try runner.run(["remote"])
            .components(separatedBy: .newlines)
            .filter(Self.isSafeRemoteName)
        let matching = try remoteNames.filter { remoteName in
            let rawURL = try runner.run(["remote", "get-url", remoteName])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (try? ForgeRemoteParser.parse(rawURL).repository) == repository
        }
        if let binding, repository == binding.primaryRepository {
            guard matching.contains(binding.localRemoteName) else {
                throw RepositoryPullRequestReviewServiceError.unavailable
            }
            return binding.localRemoteName
        }
        guard matching.count == 1, let remoteName = matching.first else {
            throw RepositoryPullRequestReviewServiceError.unavailable
        }
        return remoteName
    }

    private func validateCurrentBindingIfConfigured() throws {
        if let binding, currentBinding() != binding {
            throw RepositoryPullRequestReviewServiceError.invalidWorkspace
        }
    }

    private func regularFileContents(for path: ForgeFilePath) throws -> (data: Data, text: String) {
        let data = try Data(contentsOf: regularFileURL(for: path))
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return (data, text)
    }

    /// Foundation does not expose an atomic compare-and-swap replacement for
    /// regular files. Keep the exact byte comparison adjacent to the atomic
    /// replacement so any edit observed after validation fails closed.
    private func replaceUnchangedFile(
        at path: ForgeFilePath,
        expectedContents: Data,
        with updatedContents: Data
    ) throws {
        let fileURL = try regularFileURL(for: path)
        guard try Data(contentsOf: fileURL) == expectedContents else {
            throw RepositoryPullRequestReviewServiceError.unsafeLocalEdit
        }
        try updatedContents.write(to: fileURL, options: .atomic)
    }

    private func commit(at reference: String) throws -> ForgeCommitID? {
        do {
            let value = try runner.run(["rev-parse", "--verify", reference])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return try ForgeCommitID(value)
        } catch let error as ForgeDestinationValidationError {
            throw error
        } catch {
            return nil
        }
    }

    private static func isSafeRemoteName(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII, first.isLetter || first.isNumber else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._/-".unicodeScalars.contains($0)
        }
    }

    /// Returns only an existing regular file reached entirely through real
    /// directories. Rejecting every symbolic-link component prevents a
    /// repository-controlled link from escaping the checkout, even when its
    /// resolved destination would otherwise share the same string prefix.
    private func regularFileURL(for path: ForgeFilePath) throws -> URL {
        guard let workingDirectory else {
            throw RepositoryPullRequestReviewServiceError.unsafeLocalEdit
        }
        let result = workingDirectory.appendingPathComponent(path.value).standardizedFileURL
        let rootComponents = workingDirectory.pathComponents
        let resultComponents = result.pathComponents
        guard resultComponents.count > rootComponents.count,
              Array(resultComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw RepositoryPullRequestReviewServiceError.unsafeLocalEdit
        }

        var candidate = workingDirectory
        for (offset, component) in resultComponents.dropFirst(rootComponents.count).enumerated() {
            candidate.appendPathComponent(component)
            let values: URLResourceValues
            do {
                values = try candidate.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ])
            } catch {
                throw RepositoryPullRequestReviewServiceError.unsafeLocalEdit
            }
            guard values.isSymbolicLink == false else {
                throw RepositoryPullRequestReviewServiceError.unsafeLocalEdit
            }
            let isTarget = offset == resultComponents.count - rootComponents.count - 1
            guard isTarget ? values.isRegularFile == true : values.isDirectory == true else {
                throw RepositoryPullRequestReviewServiceError.unsafeLocalEdit
            }
        }
        return result
    }
}

nonisolated protocol RepositoryPullRequestMutationPreferencePersisting: Sendable {
    func preferredMergeMethod(
        repository: ForgeRepositoryIdentity,
        enabled: Set<ForgePullRequestMergeMethod>
    ) async -> ForgePullRequestMergeMethod?
    func recordSuccessfulMerge(repository: ForgeRepositoryIdentity, method: ForgePullRequestMergeMethod) async
    func rememberedDeleteBranchChoice(repository: ForgeRepositoryIdentity) async -> Bool
    func recordSuccessfulDeleteBranchChoice(repository: ForgeRepositoryIdentity, selected: Bool) async
}

nonisolated struct NullRepositoryPullRequestMutationPreferenceStore:
    RepositoryPullRequestMutationPreferencePersisting
{
    func preferredMergeMethod(
        repository _: ForgeRepositoryIdentity,
        enabled _: Set<ForgePullRequestMergeMethod>
    ) async -> ForgePullRequestMergeMethod? {
        nil
    }

    func recordSuccessfulMerge(repository _: ForgeRepositoryIdentity, method _: ForgePullRequestMergeMethod) async {}
    func rememberedDeleteBranchChoice(repository _: ForgeRepositoryIdentity) async -> Bool {
        false
    }

    func recordSuccessfulDeleteBranchChoice(repository _: ForgeRepositoryIdentity, selected _: Bool) async {}
}

// MARK: - Durable presentation decisions

nonisolated struct RepositoryReviewCommentPresentation: Hashable, Sendable {
    let id: ForgeObjectID?
    let bodyMarkdown: String?
    let statusText: String?
    let reactionsText: String?
}

nonisolated struct RepositoryReviewThreadPresentation: Hashable, Sendable {
    let id: ForgeObjectID
    let title: String
    let anchorText: String
    let accessibilityLabel: String
    let isExpanded: Bool
    let isResolved: Bool
    let isOutdated: Bool
    let usesBestEffortLocalAnchor: Bool
    let comments: [RepositoryReviewCommentPresentation]
    let suggestedChanges: [ForgeSuggestedChange]

    func updating(isExpanded: Bool? = nil, isResolved: Bool? = nil) -> Self {
        let resolved = isResolved ?? self.isResolved
        let previousState = self.isResolved ? "Resolved" : "Unresolved"
        let state = resolved ? "Resolved" : "Unresolved"
        return Self(
            id: id,
            title: "\(state) review thread",
            anchorText: anchorText,
            accessibilityLabel: accessibilityLabel.replacingOccurrences(
                of: "\(previousState) review thread",
                with: "\(state) review thread"
            ),
            isExpanded: isExpanded ?? self.isExpanded,
            isResolved: resolved,
            isOutdated: isOutdated,
            usesBestEffortLocalAnchor: usesBestEffortLocalAnchor,
            comments: comments,
            suggestedChanges: suggestedChanges
        )
    }
}

nonisolated enum RepositoryReviewThreadPresenter {
    static func present(_ record: RepositoryPullRequestReviewThreadRecord) -> RepositoryReviewThreadPresentation {
        let value = record.presentation
        let thread = value.thread
        let serverAnchor: ForgeReviewAnchor? = switch thread.anchor {
        case let .available(anchor): anchor
        case .unavailable: nil
        }
        let displayAnchor = record.exactOutdatedLocalAnchor ?? serverAnchor
        let anchorText = displayAnchor.map(anchorDescription) ?? "Location unavailable"
        let state = thread.isResolved ? "Resolved" : "Unresolved"
        let outdated = thread.isOutdated ? ", outdated" : ""
        let localHint = record.exactOutdatedLocalAnchor == nil ? "" : ", exact local context match"
        let comments: [RepositoryReviewCommentPresentation]
        switch thread.comments {
        case let .available(page):
            let mapped = page.items.map { comment in
                let visibility: ForgeReviewCommentVisibility = comment.isMinimized
                    ? .minimized(reason: comment.minimizedReason ?? "Reason unavailable")
                    : value.commentVisibility[comment.id] ?? .ordinary
                let body: String?
                let statusText: String?
                switch visibility {
                case .ordinary:
                    body = comment.bodyMarkdown
                    statusText = nil
                case let .minimized(reason):
                    body = nil
                    statusText = "Minimized: \(reason)"
                case .deleted:
                    body = nil
                    statusText = "Deleted comment"
                case .unavailable:
                    body = nil
                    statusText = "Comment unavailable"
                }
                return RepositoryReviewCommentPresentation(
                    id: comment.id,
                    bodyMarkdown: body,
                    statusText: statusText,
                    reactionsText: reactionsDescription(
                        value.commentReactions[comment.id] ?? comment.reactions
                    )
                )
            }
            let unavailableCount = max((page.totalCount ?? page.items.count) - page.items.count, 0)
            let unavailable = (0 ..< unavailableCount).map { _ in
                RepositoryReviewCommentPresentation(
                    id: nil,
                    bodyMarkdown: nil,
                    statusText: "Deleted or unavailable comment",
                    reactionsText: nil
                )
            }
            comments = mapped + unavailable
        case .unavailable:
            comments = [RepositoryReviewCommentPresentation(
                id: nil,
                bodyMarkdown: nil,
                statusText: "Comments unavailable",
                reactionsText: nil
            )]
        }
        return RepositoryReviewThreadPresentation(
            id: thread.id,
            title: "\(state) review thread",
            anchorText: anchorText,
            accessibilityLabel: "\(state) review thread at \(anchorText)\(outdated)\(localHint)",
            isExpanded: value.expansion == .expanded,
            isResolved: thread.isResolved,
            isOutdated: thread.isOutdated,
            usesBestEffortLocalAnchor: record.exactOutdatedLocalAnchor != nil,
            comments: comments,
            suggestedChanges: record.suggestedChanges
        )
    }

    static func anchorDescription(_ anchor: ForgeReviewAnchor) -> String {
        switch anchor.subject {
        case .file:
            return anchor.path.value
        case .line:
            let start = anchor.side == .left
                ? anchor.originalStartLine ?? anchor.startLine
                : anchor.startLine ?? anchor.originalStartLine
            let end = anchor.side == .left
                ? anchor.originalLine ?? anchor.line
                : anchor.line ?? anchor.originalLine
            if let start, let end, start != end {
                return "\(anchor.path.value):\(start)–\(end)"
            } else if let line = end ?? start {
                return "\(anchor.path.value):\(line)"
            } else {
                return "\(anchor.path.value), line unavailable"
            }
        }
    }

    private static func reactionsDescription(_ values: [ForgeReviewReactionSummary]) -> String? {
        let nonempty = values.filter { $0.count >= 1 }
        guard !nonempty.isEmpty else { return nil }
        return nonempty
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
            .map { "\(reactionSymbol($0.kind)) \($0.count)" }
            .joined(separator: "  ")
    }

    private static func reactionSymbol(_ kind: ForgeReviewReactionKind) -> String {
        switch kind {
        case .thumbsUp: "👍"
        case .thumbsDown: "👎"
        case .laugh: "😄"
        case .hooray: "🎉"
        case .confused: "😕"
        case .heart: "❤️"
        case .rocket: "🚀"
        case .eyes: "👀"
        }
    }
}

nonisolated struct RepositoryReviewThreadResolutionPresentation: Hashable, Sendable {
    let isResolved: Bool
    let canUndo: Bool
}

nonisolated enum RepositoryReviewThreadResolutionPresenter {
    static func present(
        _ state: ForgeReviewThreadResolutionState
    ) -> RepositoryReviewThreadResolutionPresentation {
        switch state {
        case let .confirmed(isResolved):
            RepositoryReviewThreadResolutionPresentation(isResolved: isResolved, canUndo: false)
        case let .optimistic(mutation, _, _):
            RepositoryReviewThreadResolutionPresentation(
                isResolved: mutation == .resolve,
                canUndo: true
            )
        case let .unknownOutcome(lastKnownValue):
            RepositoryReviewThreadResolutionPresentation(isResolved: lastKnownValue, canUndo: false)
        }
    }
}

nonisolated enum RepositoryPullRequestMutationUnavailablePresenter {
    static func message(_ reason: ForgePullRequestMutationUnavailableReason) -> String {
        switch reason {
        case .offline: "Offline — mutations are never queued"
        case let .rateLimited(until): "Rate limited until \(until.formatted(date: .abbreviated, time: .shortened))"
        case let .capabilityUnavailable(operation): "Permission unavailable for \(operation.rawValue)"
        case .pullRequestNotOpen: "Pull Request is not open"
        case .pullRequestIsDraft: "Pull Request is a draft"
        case .pullRequestIsReady: "Pull Request is already ready"
        case .pullRequestNotClosed: "Pull Request is not closed"
        case .pullRequestAlreadyMerged: "Pull Request is already merged"
        case .updateBranchUnavailable: "Update Branch is unavailable"
        case .viewerCannotMerge: "You cannot merge this Pull Request"
        case .mergeMethodDisabled: "This merge method is disabled"
        case .mergeQueueAlreadyEntered: "Pull Request is already in the merge queue"
        case .mergeQueueNotEntered: "Pull Request is not in the merge queue"
        case .branchDeletionUnavailable: "Head branch deletion is unavailable"
        case .forkHeadBranch: "Fork head branches are never deleted here"
        case .defaultBranch: "The default branch cannot be deleted"
        case .protectedBranch: "Protected branches cannot be deleted"
        case .checkedOutBranch: "The checked-out branch cannot be deleted"
        }
    }
}

// MARK: - Stateful workflow coordinator

@MainActor
final class RepositoryPullRequestReviewSession {
    private enum ImmediateWriteDestination: Hashable {
        case inline(context: ForgeReviewContext, anchor: ForgeReviewAnchor)
        case reply(threadID: ForgeObjectID)
    }

    enum State: Equatable {
        case idle
        case loading
        case loaded(RepositoryPullRequestReviewWorkspace)
        case stale(RepositoryPullRequestReviewWorkspace, message: String)
        case failed(String)
    }

    struct PendingReanchor: Hashable, Sendable {
        let originalContext: ForgeReviewContext
        let publication: ForgeInlineReviewPublication
        let confirmation: ForgeReviewReanchorConfirmation

        var proposedAnchor: ForgeReviewAnchor {
            confirmation.anchor
        }
    }

    struct UpdateBranchConfirmation: Hashable, Sendable {
        let identity: RepositoryPullRequestReviewIdentity
        let head: ForgeCommitID
        let base: ForgeCommitID
        let updatedAt: Date
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    private(set) var resolutionStates: [ForgeObjectID: ForgeReviewThreadResolutionState] = [:]
    var onStateChange: ((State) -> Void)?
    var onResolutionChange: ((ForgeObjectID, ForgeReviewThreadResolutionState) -> Void)?
    var onMutationError: ((String) -> Void)?
    var onOutcomeUnknown: (() -> Void)?

    let identity: RepositoryPullRequestReviewIdentity
    private let service: any RepositoryPullRequestReviewMutationServing
    private let localService: any RepositoryPullRequestLocalReviewServing
    private let drafts: any RepositoryPullRequestDraftPersisting
    private let preferences: any RepositoryPullRequestMutationPreferencePersisting
    private let now: @Sendable () -> Date
    private let undoInterval: TimeInterval
    private var task: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var undoTasks: [ForgeObjectID: Task<Void, Never>] = [:]
    private var resolutionGenerations: [ForgeObjectID: UInt64] = [:]
    private var resolutionReconciliations: [ForgeObjectID: (generation: UInt64, isResolved: Bool)] = [:]
    /// The head shown by the active formal-review sheet. Draft autosaves and
    /// submission retain this value even if a background refresh installs a
    /// newer workspace while the sheet remains open.
    private var formalReviewDisplayedHead: ForgeCommitID?
    private var reanchorsInFlight: Set<PendingReanchor> = []
    private var consumedReanchors: Set<PendingReanchor> = []
    private var immediateWritesInFlight: Set<ImmediateWriteDestination> = []
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "PullRequestReview")

    init(
        identity: RepositoryPullRequestReviewIdentity,
        service: any RepositoryPullRequestReviewMutationServing,
        localService: any RepositoryPullRequestLocalReviewServing = UnavailableRepositoryPullRequestLocalReviewService(),
        drafts: any RepositoryPullRequestDraftPersisting = NullRepositoryPullRequestDraftStore(),
        preferences: any RepositoryPullRequestMutationPreferencePersisting = NullRepositoryPullRequestMutationPreferenceStore(),
        now: @escaping @Sendable () -> Date = Date.init,
        undoInterval: TimeInterval = 8
    ) {
        self.identity = identity
        self.service = service
        self.localService = localService
        self.drafts = drafts
        self.preferences = preferences
        self.now = now
        self.undoInterval = undoInterval
    }

    deinit {
        task?.cancel()
        undoTasks.values.forEach { $0.cancel() }
    }

    var workspace: RepositoryPullRequestReviewWorkspace? {
        switch state {
        case let .loaded(workspace):
            workspace
        case let .stale(workspace, _):
            workspace
        case .idle, .loading, .failed:
            nil
        }
    }

    func load() {
        let previousWorkspace = workspace
        task?.cancel()
        loadGeneration = loadGeneration == .max ? 1 : loadGeneration + 1
        let generation = loadGeneration
        if let previousWorkspace,
           let stale = try? previousWorkspace.markingMutationStateFresh(false)
        {
            state = .stale(stale, message: "Refreshing Pull Request…")
        } else {
            state = .loading
        }
        logger.info("Loading native Pull Request review workspace")
        task = Task { [weak self, service, identity] in
            do {
                let workspace = try await service.loadWorkspace(identity: identity)
                guard let self, generation == loadGeneration else { return }
                try validate(workspace)
                install(workspace)
                logger.info("Installed native Pull Request review workspace")
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == loadGeneration else { return }
                failLoad(error, preserving: previousWorkspace)
            }
        }
    }

    func prepareInlinePublication(
        context: ForgeReviewContext,
        anchor: ForgeReviewAnchor,
        bodyMarkdown: String
    ) async throws -> PendingReanchor? {
        guard let workspace else { throw RepositoryPullRequestReviewServiceError.unavailable }
        try requireFresh(workspace)
        try requireOperation(.publishInlineReviewComment, workspace: workspace)
        guard context.repository == identity.repository else {
            throw ForgeReviewMutationError.mismatchedRepository
        }
        guard context.pullRequest == identity.number else {
            throw ForgeReviewMutationError.mismatchedPullRequest
        }
        guard context.path == anchor.path else {
            throw ForgeReviewMutationError.invalidContext
        }
        guard !context.isTruncated else {
            throw ForgeReviewMutationError.truncatedAnchor
        }
        _ = try RepositoryPullRequestReviewAnchorPolicy.validateInlineAnchor(anchor, context: context)
        let destination = ImmediateWriteDestination.inline(context: context, anchor: anchor)
        guard immediateWritesInFlight.insert(destination).inserted else {
            throw ForgeReviewMutationError.invalidTransition
        }
        defer { immediateWritesInFlight.remove(destination) }
        let publication = try ForgeInlineReviewPublication(
            accountID: identity.accountID,
            repository: identity.repository,
            pullRequest: identity.number,
            displayedHead: context.displayedHead,
            anchor: anchor,
            bodyMarkdown: bodyMarkdown
        )
        // Persist before any asynchronous head or re-anchor decision. A
        // declined confirmation therefore preserves the exact head-bound
        // text instead of only claiming that it was preserved.
        try await saveInlineDraft(publication: publication, context: context)
        if context.displayedHead == workspace.displayedHead {
            try await publishInline(publication, draftContext: context)
            return nil
        }
        let candidates = try await localService.reanchorCandidates(
            for: context,
            currentHead: workspace.displayedHead
        )
        switch ForgeReviewReanchorPolicy.decision(
            original: context,
            currentHead: workspace.displayedHead,
            candidates: candidates
        ) {
        case .unchanged:
            try await publishInline(publication, draftContext: context)
            return nil
        case let .requiresConfirmation(confirmation):
            logger.info("Inline review draft requires an exact re-anchor confirmation")
            return PendingReanchor(
                originalContext: context,
                publication: publication,
                confirmation: confirmation
            )
        case let .unavailable(error):
            logger.notice("Inline review draft cannot be re-anchored")
            throw error
        }
    }

    func confirmReanchor(_ pending: PendingReanchor) async throws {
        guard !reanchorsInFlight.contains(pending), !consumedReanchors.contains(pending) else {
            throw ForgeReviewMutationError.invalidTransition
        }
        reanchorsInFlight.insert(pending)
        defer { reanchorsInFlight.remove(pending) }
        guard let workspace else { throw RepositoryPullRequestReviewServiceError.unavailable }
        try requireFresh(workspace)
        try requireOperation(.publishInlineReviewComment, workspace: workspace)
        let replacement = try pending.confirmation.publication(replacing: pending.publication)
        _ = try replacement.validating(currentHead: workspace.displayedHead)
        try await saveInlineDraft(publication: replacement, context: pending.originalContext)
        try await publishInline(replacement, draftContext: pending.originalContext)
        consumedReanchors.insert(pending)
        try await deletePublishedDraft(identity: inlineDraftIdentity(
            context: pending.originalContext,
            anchor: pending.publication.anchor
        ))
    }

    func loadInlineDraft(context: ForgeReviewContext, anchor: ForgeReviewAnchor) async throws -> String {
        try await drafts.load(identity: inlineDraftIdentity(context: context, anchor: anchor))?.content.body ?? ""
    }

    func saveInlineDraft(context: ForgeReviewContext, anchor: ForgeReviewAnchor, bodyMarkdown: String) async throws {
        let publication = try ForgeInlineReviewPublication(
            accountID: identity.accountID,
            repository: identity.repository,
            pullRequest: identity.number,
            displayedHead: context.displayedHead,
            anchor: anchor,
            bodyMarkdown: bodyMarkdown
        )
        try await saveInlineDraft(publication: publication, context: context)
    }

    func discardInlineDraft(context: ForgeReviewContext, anchor: ForgeReviewAnchor) async throws {
        try await drafts.delete(identity: inlineDraftIdentity(context: context, anchor: anchor))
    }

    func loadReplyDraft(threadID: ForgeObjectID) async throws -> String {
        try await drafts.load(identity: replyDraftIdentity(threadID: threadID))?.content.body ?? ""
    }

    func saveReplyDraft(threadID: ForgeObjectID, bodyMarkdown: String) async throws {
        try await drafts.save(
            identity: replyDraftIdentity(threadID: threadID),
            content: ForgeDraftContent(body: bodyMarkdown),
            at: now()
        )
    }

    func loadFormalReviewDraft() async throws -> String {
        guard let workspace else { throw RepositoryPullRequestReviewServiceError.unavailable }
        return try await loadFormalReviewDraft(displayedHead: workspace.displayedHead)
    }

    func loadFormalReviewDraft(displayedHead: ForgeCommitID) async throws -> String {
        guard let workspace else { throw RepositoryPullRequestReviewServiceError.unavailable }
        try requireFresh(workspace)
        guard workspace.displayedHead == displayedHead else {
            throw ForgeReviewMutationError.displayedHeadChanged
        }
        // Calling this method is the explicit preparation boundary for a new
        // sheet, so replacing an older pin requires the caller to have just
        // confirmed the currently displayed head.
        formalReviewDisplayedHead = displayedHead
        return try await drafts.load(identity: formalReviewDraftIdentity(head: displayedHead))?.content.body ?? ""
    }

    func saveFormalReviewDraft(bodyMarkdown: String) async throws {
        let displayedHead = try activeFormalReviewHead()
        try await saveFormalReviewDraft(displayedHead: displayedHead, bodyMarkdown: bodyMarkdown)
    }

    func saveFormalReviewDraft(displayedHead: ForgeCommitID, bodyMarkdown: String) async throws {
        try requireActiveFormalReviewHead(displayedHead)
        try await drafts.save(
            identity: formalReviewDraftIdentity(head: displayedHead),
            content: ForgeDraftContent(body: bodyMarkdown),
            at: now()
        )
    }

    func discardFormalReviewDraft() async throws {
        let displayedHead = try activeFormalReviewHead()
        try await discardFormalReviewDraft(displayedHead: displayedHead)
    }

    func discardFormalReviewDraft(displayedHead: ForgeCommitID) async throws {
        try requireActiveFormalReviewHead(displayedHead)
        try await drafts.delete(identity: formalReviewDraftIdentity(head: displayedHead))
        formalReviewDisplayedHead = nil
    }

    func reply(threadID: ForgeObjectID, bodyMarkdown: String) async throws {
        guard let workspace else { throw RepositoryPullRequestReviewServiceError.unavailable }
        try requireFresh(workspace)
        try requireOperation(.replyToReviewThread, workspace: workspace)
        guard workspace.threads.contains(where: { $0.presentation.thread.id == threadID }) else {
            throw ForgeReviewMutationError.mismatchedPullRequest
        }
        let destination = ImmediateWriteDestination.reply(threadID: threadID)
        guard immediateWritesInFlight.insert(destination).inserted else {
            throw ForgeReviewMutationError.invalidTransition
        }
        defer { immediateWritesInFlight.remove(destination) }
        let publication = try ForgeReviewThreadReplyPublication(
            accountID: identity.accountID,
            repository: identity.repository,
            pullRequest: identity.number,
            threadID: threadID,
            bodyMarkdown: bodyMarkdown
        )
        let draftIdentity = try replyDraftIdentity(threadID: threadID)
        try await drafts.save(
            identity: draftIdentity,
            content: ForgeDraftContent(body: bodyMarkdown),
            at: now()
        )
        guard let currentWorkspace = self.workspace else {
            throw RepositoryPullRequestReviewServiceError.unavailable
        }
        try requireFresh(currentWorkspace)
        try requireOperation(.replyToReviewThread, workspace: currentWorkspace)
        guard currentWorkspace.threads.contains(where: { $0.presentation.thread.id == threadID }) else {
            throw ForgeReviewMutationError.mismatchedPullRequest
        }
        do {
            let updated = try await service.replyToReviewThread(publication)
            try validate(updated)
            install(updated)
            await deletePublishedDraft(identity: draftIdentity)
            logger.notice("Published an immediate review-thread reply")
        } catch {
            logger.error("Review-thread reply failed; preserved Forge Draft")
            reconcileIfUnknown(error)
            throw error
        }
    }

    func setResolution(
        threadID: ForgeObjectID,
        mutation: ForgeReviewThreadResolutionMutation,
        at eventDate: Date? = nil
    ) {
        guard let workspace,
              workspace.isMutationStateFresh,
              workspace.mutationContext.environment == .available,
              workspace.mutationContext.allowedOperations.contains(
                  mutation == .resolve ? .resolveReviewThread : .unresolveReviewThread
              ),
              let thread = workspace.threads.first(where: { $0.presentation.thread.id == threadID })
        else { return }
        let date = eventDate ?? now()
        do {
            let current = resolutionStates[threadID] ?? .confirmed(isResolved: thread.presentation.thread.isResolved)
            let optimistic = try current.applying(.begin(mutation, now: date, undoInterval: undoInterval))
            setResolutionState(optimistic, threadID: threadID)
            sendResolution(threadID: threadID, mutation: mutation)
        } catch {
            failMutation(error)
        }
    }

    func undoResolution(threadID: ForgeObjectID, at eventDate: Date? = nil) {
        guard let current = resolutionStates[threadID] else { return }
        do {
            let undone = try current.applying(.undo(now: eventDate ?? now()))
            setResolutionState(undone, threadID: threadID)
            guard case let .optimistic(mutation, _, _) = undone else { return }
            sendResolution(threadID: threadID, mutation: mutation)
        } catch {
            failMutation(error)
        }
    }

    func expireResolutionUndo(threadID: ForgeObjectID, at date: Date? = nil) {
        guard case let .optimistic(_, _, deadline) = resolutionStates[threadID],
              (date ?? now()) >= deadline,
              let reconciliation = resolutionReconciliations[threadID],
              reconciliation.generation == resolutionGenerations[threadID]
        else { return }
        resolutionReconciliations[threadID] = nil
        setResolutionState(.confirmed(isResolved: reconciliation.isResolved), threadID: threadID)
    }

    func submitFormalReview(kind: ForgeFormalReviewKind, bodyMarkdown: String) async throws {
        try await submitFormalReview(
            displayedHead: activeFormalReviewHead(allowingCurrentWorkspaceFallback: true),
            kind: kind,
            bodyMarkdown: bodyMarkdown
        )
    }

    func submitFormalReview(
        displayedHead: ForgeCommitID,
        kind: ForgeFormalReviewKind,
        bodyMarkdown: String
    ) async throws {
        guard let workspace else { throw RepositoryPullRequestReviewServiceError.unavailable }
        try requireFresh(workspace)
        if formalReviewDisplayedHead == nil {
            formalReviewDisplayedHead = displayedHead
        }
        try requireActiveFormalReviewHead(displayedHead)
        guard workspace.displayedHead == displayedHead else {
            formalReviewDisplayedHead = nil
            throw ForgeReviewMutationError.displayedHeadChanged
        }
        let operation: ForgeOperation = switch kind {
        case .approve: .submitApproveReview
        case .comment: .submitCommentReview
        case .requestChanges: .submitRequestChangesReview
        }
        try requireOperation(operation, workspace: workspace)
        let submission = try ForgeFormalReviewSubmission(
            accountID: identity.accountID,
            repository: identity.repository,
            pullRequest: identity.number,
            displayedHead: displayedHead,
            kind: kind,
            bodyMarkdown: bodyMarkdown
        )
        let draftIdentity = try formalReviewDraftIdentity(head: displayedHead)
        try await drafts.save(
            identity: draftIdentity,
            content: ForgeDraftContent(body: bodyMarkdown),
            at: now()
        )
        do {
            let fresh = try await service.loadWorkspace(identity: identity)
            try validate(fresh)
            install(fresh)
            try requireFresh(fresh)
            try requireOperation(operation, workspace: fresh)
            do {
                _ = try submission.validating(currentHead: fresh.displayedHead)
            } catch ForgeReviewMutationError.displayedHeadChanged {
                // Install the refetched head but do not submit. The next sheet
                // is therefore a new explicit confirmation bound to that head.
                formalReviewDisplayedHead = nil
                throw ForgeReviewMutationError.displayedHeadChanged
            }
            let updated = try await service.submitFormalReview(submission)
            try validate(updated)
            install(updated)
            await deletePublishedDraft(identity: draftIdentity)
            formalReviewDisplayedHead = nil
            logger.notice("Submitted a formal Pull Request review")
        } catch {
            logger.error("Formal review failed or head changed; preserved Forge Draft")
            reconcileIfUnknown(error)
            throw error
        }
    }

    func applySuggestedChange(_ change: ForgeSuggestedChange) async throws {
        guard let workspace,
              workspace.isMutationStateFresh,
              change.repository == identity.repository,
              change.pullRequest == identity.number,
              change.displayedHead == workspace.displayedHead
        else { throw RepositoryPullRequestReviewServiceError.stalePullRequest }
        try await localService.applySuggestedChange(change)
        logger.notice("Applied one suggested change after one atomic local preflight")
    }

    func performLifecycle(_ action: ForgePullRequestLifecycleAction) async throws {
        guard let workspace else { throw RepositoryPullRequestReviewServiceError.unavailable }
        try requireFresh(workspace)
        switch ForgePullRequestLifecyclePolicy.decision(
            context: workspace.mutationContext,
            action: action,
            canUpdateBranch: workspace.canUpdateBranch
        ) {
        case let .available(request):
            do {
                let updated = try await service.performLifecycle(request)
                try validate(updated)
                install(updated)
                logger.notice("Completed Pull Request lifecycle action=\(action.rawValue, privacy: .public)")
            } catch {
                reconcileIfUnknown(error)
                throw error
            }
        case let .unavailable(reason):
            throw RepositoryPullRequestReviewServiceError.authoritative(
                RepositoryPullRequestMutationUnavailablePresenter.message(reason)
            )
        }
    }

    func prepareUpdateBranch() async throws -> UpdateBranchConfirmation {
        guard workspace != nil else { throw RepositoryPullRequestReviewServiceError.unavailable }
        let fresh = try await service.loadWorkspace(identity: identity)
        try validate(fresh)
        install(fresh)
        try requireFresh(fresh)
        switch ForgePullRequestLifecyclePolicy.decision(
            context: fresh.mutationContext,
            action: .updateBranch,
            canUpdateBranch: fresh.canUpdateBranch
        ) {
        case .available:
            break
        case let .unavailable(reason):
            throw RepositoryPullRequestReviewServiceError.authoritative(
                RepositoryPullRequestMutationUnavailablePresenter.message(reason)
            )
        }
        return UpdateBranchConfirmation(
            identity: fresh.identity,
            head: fresh.displayedHead,
            base: fresh.base.commit,
            updatedAt: fresh.mutationContext.updatedAt
        )
    }

    func confirmUpdateBranch(_ confirmation: UpdateBranchConfirmation) async throws {
        guard let workspace,
              workspace.identity == confirmation.identity,
              workspace.displayedHead == confirmation.head,
              workspace.base.commit == confirmation.base,
              workspace.mutationContext.updatedAt == confirmation.updatedAt
        else {
            throw RepositoryPullRequestReviewServiceError.stalePullRequest
        }
        try await performLifecycle(.updateBranch)
    }

    func preferredMergeMethod() async -> ForgePullRequestMergeMethod? {
        guard let workspace else { return nil }
        return await preferences.preferredMergeMethod(
            repository: identity.repository,
            enabled: workspace.mergeSnapshot.enabledMethods
        )
    }

    func prepareMerge(
        method: ForgePullRequestMergeMethod
    ) async throws -> ForgePullRequestMergeConfirmation {
        guard let workspace else { throw RepositoryPullRequestReviewServiceError.unavailable }
        try requireFresh(workspace)
        let fresh = try await service.freshMergeSnapshot(identity: identity)
        try validate(fresh)
        switch ForgePullRequestMergePolicy.confirmationDecision(snapshot: fresh, method: method) {
        case let .available(confirmation):
            logger.info("Prepared merge confirmation from a fresh server snapshot")
            return confirmation
        case let .unavailable(reason):
            throw RepositoryPullRequestReviewServiceError.authoritative(
                RepositoryPullRequestMutationUnavailablePresenter.message(reason)
            )
        }
    }

    func confirmMerge(
        _ confirmation: ForgePullRequestMergeConfirmation,
        title: String?,
        message: String?,
        deleteHeadBranchChoice: Bool
    ) async throws -> RepositoryPullRequestMergeCompletion {
        guard let workspace else { throw RepositoryPullRequestReviewServiceError.unavailable }
        try requireFresh(workspace)
        let deletionChoiceIsEligible = deleteHeadBranchChoice
            && workspace.canOfferHeadBranchDeletionAfterMerge
        let fresh = try await service.freshMergeSnapshot(identity: identity)
        try validate(fresh)
        _ = try ForgePullRequestMergePolicy.validate(confirmation: confirmation, fresh: fresh)
        let request = try ForgePullRequestMergeRequest(
            confirmation: confirmation,
            title: title,
            message: message
        )
        do {
            let updated = try await service.mergePullRequest(request)
            try validate(updated)
            install(updated)
            await preferences.recordSuccessfulMerge(
                repository: identity.repository,
                method: confirmation.method
            )
            await preferences.recordSuccessfulDeleteBranchChoice(
                repository: identity.repository,
                selected: deleteHeadBranchChoice
            )
            logger.notice("Merged Pull Request method=\(confirmation.method.rawValue, privacy: .public)")
        } catch {
            reconcileIfUnknown(error)
            throw error
        }
        guard deletionChoiceIsEligible else { return .merged }
        do {
            try await deleteHeadBranch()
            return .mergedAndDeletedHeadBranch
        } catch {
            let message = error.localizedDescription
            logger.error("Merge succeeded, but separate head-branch deletion failed: \(message, privacy: .public)")
            return .mergedWithHeadBranchDeletionFailure(message)
        }
    }

    func changeMergeQueue(_ action: ForgePullRequestMergeQueueAction) async throws {
        guard let workspace else { throw RepositoryPullRequestReviewServiceError.unavailable }
        try requireFresh(workspace)
        switch ForgePullRequestMergeQueuePolicy.decision(snapshot: workspace.mergeSnapshot, action: action) {
        case let .available(request):
            do {
                let updated = try await service.changeMergeQueue(request)
                try validate(updated)
                install(updated)
                logger.notice("Changed merge queue action=\(action.rawValue, privacy: .public)")
            } catch {
                reconcileIfUnknown(error)
                throw error
            }
        case let .unavailable(reason):
            throw RepositoryPullRequestReviewServiceError.authoritative(
                RepositoryPullRequestMutationUnavailablePresenter.message(reason)
            )
        }
    }

    func rememberedDeleteBranchChoice() async -> Bool {
        await preferences.rememberedDeleteBranchChoice(repository: identity.repository)
    }

    func deleteHeadBranch() async throws {
        guard let workspace else { throw RepositoryPullRequestReviewServiceError.unavailable }
        try requireFresh(workspace)
        let snapshot = try await service.freshHeadBranchDeletionSnapshot(identity: identity)
        try validate(snapshot.mergeSnapshot)
        // This is always an explicit post-merge action. Queue entry never calls
        // it automatically, while prior queue history never disables it once
        // the merge is observed and the fresh destructive preflight is safe.
        switch ForgeHeadBranchDeletionPolicy.decision(snapshot: snapshot, mergeWasQueued: false) {
        case let .available(request):
            do {
                try await service.deleteHeadBranch(request)
                await preferences.recordSuccessfulDeleteBranchChoice(repository: identity.repository, selected: true)
                logger.notice("Deleted same-repository Pull Request head branch as a separate mutation")
                load()
            } catch {
                reconcileIfUnknown(error)
                throw error
            }
        case let .unavailable(reason):
            throw RepositoryPullRequestReviewServiceError.authoritative(
                RepositoryPullRequestMutationUnavailablePresenter.message(reason)
            )
        }
    }

    func fetchBase() async throws {
        guard let workspace else { throw RepositoryPullRequestReviewServiceError.unavailable }
        try requirePostMergeLocalAction(workspace)
        try await localService.fetchBase(workspace.base)
        logger.notice("Fetched Pull Request base after merge by explicit user action")
    }

    func checkOutBase() async throws {
        guard let workspace else { throw RepositoryPullRequestReviewServiceError.unavailable }
        try requirePostMergeLocalAction(workspace)
        try await localService.checkOutBase(workspace.base)
        logger.notice("Checked out Pull Request base after merge by explicit user action")
    }

    private func publishInline(
        _ publication: ForgeInlineReviewPublication,
        draftContext: ForgeReviewContext
    ) async throws {
        guard let workspace else { throw RepositoryPullRequestReviewServiceError.unavailable }
        try requireFresh(workspace)
        try requireOperation(.publishInlineReviewComment, workspace: workspace)
        let draftIdentity = try inlineDraftIdentity(
            context: draftContext,
            anchor: publication.anchor,
            displayedHead: publication.displayedHead
        )
        do {
            _ = try publication.validating(currentHead: workspace.displayedHead)
            let updated = try await service.publishInlineReview(publication)
            try validate(updated)
            install(updated)
            await deletePublishedDraft(identity: draftIdentity)
            logger.notice("Published an immediate inline review comment")
        } catch {
            logger.error("Inline review publication failed; preserved head-bound Forge Draft")
            reconcileIfUnknown(error)
            throw error
        }
    }

    private func sendResolution(
        threadID: ForgeObjectID,
        mutation: ForgeReviewThreadResolutionMutation
    ) {
        let generation = nextResolutionGeneration(threadID: threadID)
        resolutionReconciliations[threadID] = nil
        let previousTask = undoTasks[threadID]
        previousTask?.cancel()
        logger.info("Starting review-thread resolution generation \(generation, privacy: .public)")
        undoTasks[threadID] = Task { [weak self, service, identity, undoInterval] in
            // GitHub applies resolution mutations in arrival order, while a
            // cancelled URL request may already have reached the server. Wait
            // for the preceding generation to finish before dispatching its
            // inverse so Resolve -> Undo cannot land out of order remotely.
            await previousTask?.value
            guard !Task.isCancelled else { return }
            do {
                try await service.setReviewThreadResolution(
                    identity: identity,
                    threadID: threadID,
                    mutation: mutation
                )
                guard let self,
                      !Task.isCancelled,
                      isCurrentResolutionGeneration(generation, threadID: threadID)
                else { return }

                do {
                    let refreshed = try await service.loadWorkspace(identity: identity)
                    try validate(refreshed)
                    guard refreshed.isMutationStateFresh else {
                        install(refreshed)
                        throw RepositoryPullRequestReviewServiceError.stalePullRequest
                    }
                    guard let thread = refreshed.threads.first(where: {
                        $0.presentation.thread.id == threadID
                    }) else {
                        throw RepositoryPullRequestReviewServiceError.invalidWorkspace
                    }
                    let authoritativeValue = thread.presentation.thread.isResolved
                    install(refreshed)
                    guard !Task.isCancelled,
                          isCurrentResolutionGeneration(generation, threadID: threadID)
                    else { return }

                    let requestedValue = mutation == .resolve
                    guard authoritativeValue == requestedValue else {
                        setResolutionState(.confirmed(isResolved: authoritativeValue), threadID: threadID)
                        failMutation(RepositoryPullRequestReviewServiceError.authoritative(
                            "GitHub reported a different review-thread resolution state."
                        ))
                        return
                    }
                    resolutionReconciliations[threadID] = (
                        generation: generation,
                        isResolved: authoritativeValue
                    )
                    logger.info("Reconciled review-thread resolution generation \(generation, privacy: .public)")
                } catch {
                    guard !Task.isCancelled,
                          isCurrentResolutionGeneration(generation, threadID: threadID)
                    else { return }
                    // The receipt-verified mutation succeeded. A failed
                    // authoritative read makes the workspace stale, but it
                    // cannot retroactively make the write outcome unknown.
                    setResolutionState(.confirmed(isResolved: mutation == .resolve), threadID: threadID)
                    markWorkspaceStaleAfterAcknowledgedMutation(error)
                    failMutation(error)
                    return
                }

                try await Task.sleep(for: .seconds(undoInterval))
                guard !Task.isCancelled,
                      isCurrentResolutionGeneration(generation, threadID: threadID)
                else { return }
                expireResolutionUndo(threadID: threadID)
            } catch is CancellationError {
                return
            } catch RepositoryPullRequestReviewServiceError.outcomeUnknown {
                guard let self,
                      !Task.isCancelled,
                      isCurrentResolutionGeneration(generation, threadID: threadID)
                else {
                    self?.logger.info("Ignored stale unknown review-thread resolution outcome")
                    return
                }
                let lastKnown: Bool = switch resolutionStates[threadID] {
                case let .optimistic(_, priorValue, _): priorValue
                default: false
                }
                setResolutionState(.unknownOutcome(lastKnownValue: lastKnown), threadID: threadID)
                onOutcomeUnknown?()
                load()
            } catch {
                guard let self,
                      !Task.isCancelled,
                      isCurrentResolutionGeneration(generation, threadID: threadID),
                      let current = resolutionStates[threadID]
                else {
                    self?.logger.info("Ignored stale review-thread resolution failure")
                    return
                }
                if let reverted = try? current.applying(.failed) {
                    setResolutionState(reverted, threadID: threadID)
                }
                failMutation(error)
            }
        }
    }

    private func nextResolutionGeneration(threadID: ForgeObjectID) -> UInt64 {
        let previous = resolutionGenerations[threadID] ?? 0
        let generation = previous == .max ? 1 : previous + 1
        resolutionGenerations[threadID] = generation
        return generation
    }

    private func isCurrentResolutionGeneration(
        _ generation: UInt64,
        threadID: ForgeObjectID
    ) -> Bool {
        resolutionGenerations[threadID] == generation
    }

    private func install(_ workspace: RepositoryPullRequestReviewWorkspace) {
        for record in workspace.threads {
            let thread = record.presentation.thread
            if case .optimistic = resolutionStates[thread.id] {
                continue
            }
            resolutionStates[thread.id] = .confirmed(isResolved: thread.isResolved)
        }
        state = .loaded(workspace)
    }

    private func validate(_ workspace: RepositoryPullRequestReviewWorkspace) throws {
        guard workspace.identity == identity else {
            throw RepositoryPullRequestReviewServiceError.invalidWorkspace
        }
    }

    private func activeFormalReviewHead(
        allowingCurrentWorkspaceFallback: Bool = false
    ) throws -> ForgeCommitID {
        if let formalReviewDisplayedHead {
            return formalReviewDisplayedHead
        }
        guard allowingCurrentWorkspaceFallback, let workspace else {
            throw ForgeReviewMutationError.displayedHeadChanged
        }
        formalReviewDisplayedHead = workspace.displayedHead
        return workspace.displayedHead
    }

    private func requireActiveFormalReviewHead(_ displayedHead: ForgeCommitID) throws {
        guard formalReviewDisplayedHead == displayedHead else {
            throw ForgeReviewMutationError.displayedHeadChanged
        }
    }

    private func requireFresh(_ workspace: RepositoryPullRequestReviewWorkspace) throws {
        guard workspace.isMutationStateFresh else {
            throw RepositoryPullRequestReviewServiceError.stalePullRequest
        }
    }

    private func requirePostMergeLocalAction(_ workspace: RepositoryPullRequestReviewWorkspace) throws {
        try requireFresh(workspace)
        guard workspace.mutationContext.state == .merged else {
            throw RepositoryPullRequestReviewServiceError.stalePullRequest
        }
    }

    private func requireOperation(
        _ operation: ForgeOperation,
        workspace: RepositoryPullRequestReviewWorkspace
    ) throws {
        guard workspace.mutationContext.environment == .available,
              workspace.mutationContext.allowedOperations.contains(operation)
        else {
            throw RepositoryPullRequestReviewServiceError.unavailable
        }
    }

    private func validate(_ snapshot: ForgePullRequestMergeSnapshot) throws {
        let context = snapshot.context
        guard context.accountID == identity.accountID,
              context.repository == identity.repository,
              context.number == identity.number
        else {
            throw RepositoryPullRequestReviewServiceError.invalidWorkspace
        }
    }

    private func setResolutionState(
        _ value: ForgeReviewThreadResolutionState,
        threadID: ForgeObjectID
    ) {
        resolutionStates[threadID] = value
        onResolutionChange?(threadID, value)
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        state = .failed(message)
        logger.error("Pull Request review workspace failed: \(message, privacy: .public)")
    }

    private func failLoad(
        _ error: Error,
        preserving previousWorkspace: RepositoryPullRequestReviewWorkspace?
    ) {
        guard let previousWorkspace,
              let stale = try? previousWorkspace.markingMutationStateFresh(false)
        else {
            fail(error)
            return
        }
        let message = error.localizedDescription
        state = .stale(stale, message: message)
        logger.error("Pull Request refresh failed; preserved stale workspace: \(message, privacy: .public)")
        onMutationError?(message)
    }

    private func failMutation(_ error: Error) {
        let message = error.localizedDescription
        logger.error("Pull Request mutation failed: \(message, privacy: .public)")
        onMutationError?(message)
    }

    private func markWorkspaceStaleAfterAcknowledgedMutation(_ error: Error) {
        guard let workspace,
              let stale = try? workspace.markingMutationStateFresh(false)
        else { return }
        state = .stale(stale, message: error.localizedDescription)
        logger.error("Acknowledged mutation refresh failed; preserved a stale workspace")
    }

    private func reconcileIfUnknown(_ error: Error) {
        guard error as? RepositoryPullRequestReviewServiceError == .outcomeUnknown else { return }
        logger.error("Mutation outcome unknown; scheduling reconciliation without retry")
        onOutcomeUnknown?()
        load()
    }

    private func deletePublishedDraft(identity: ForgeDraftIdentity) async {
        do {
            try await drafts.delete(identity: identity)
        } catch {
            // Publication is already authoritative. A local cleanup failure
            // must not make the user retry and duplicate the mutation.
            logger.error("Published mutation succeeded, but Forge Draft cleanup failed")
        }
    }

    private func saveInlineDraft(
        publication: ForgeInlineReviewPublication,
        context: ForgeReviewContext
    ) async throws {
        try await drafts.save(
            identity: inlineDraftIdentity(
                context: context,
                anchor: publication.anchor,
                displayedHead: publication.displayedHead
            ),
            content: ForgeDraftContent(body: publication.bodyMarkdown),
            at: now()
        )
    }

    private func inlineDraftIdentity(
        context: ForgeReviewContext,
        anchor: ForgeReviewAnchor,
        displayedHead: ForgeCommitID? = nil
    ) throws -> ForgeDraftIdentity {
        guard context.repository == identity.repository else {
            throw ForgeReviewMutationError.mismatchedRepository
        }
        guard context.pullRequest == identity.number else {
            throw ForgeReviewMutationError.mismatchedPullRequest
        }
        let selection = try RepositoryPullRequestReviewAnchorPolicy.validateInlineAnchor(
            anchor,
            context: context
        )
        return try ForgeDraftIdentity(
            accountID: identity.accountID,
            destination: .inlineReview(
                repository: identity.repository,
                pullRequest: identity.number,
                path: context.path,
                selection: selection
            ),
            displayedPullRequestHead: displayedHead ?? context.displayedHead
        )
    }

    private func replyDraftIdentity(threadID: ForgeObjectID) throws -> ForgeDraftIdentity {
        try ForgeDraftIdentity(
            accountID: identity.accountID,
            destination: .reviewThread(
                repository: identity.repository,
                pullRequest: identity.number,
                thread: ForgeDraftDestinationIdentifier(threadID.value)
            )
        )
    }

    private func formalReviewDraftIdentity(head: ForgeCommitID) throws -> ForgeDraftIdentity {
        try ForgeDraftIdentity(
            accountID: identity.accountID,
            destination: .formalReview(repository: identity.repository, pullRequest: identity.number),
            displayedPullRequestHead: head
        )
    }
}
