import ForgeKit
import Foundation
import GitHubForgeAdapter
import OSLog // swiftlint:disable:this unused_import

/// Whether GitX may show which workflow runs a pull request's check suites belong to (ADR 0015).
enum ForgeWorkflowAccess: Equatable, Sendable {
    /// The credential can read GitHub Actions.
    case granted
    /// GitX has not yet learned whether it can; the next read settles it.
    case unverified
    /// GitHub refused, or the credential's evidence says it cannot.
    case denied
}

/// The check suites on a pull request's head commit, and what GitX may say about them.
struct ForgeWorkflowInspection: Equatable, Sendable {
    let pullRequest: ForgeItemNumber
    let commit: ForgeCommitID
    let snapshot: ForgeCommitWorkflowSnapshot
    let access: ForgeWorkflowAccess
    /// Where the person reviews the GitHub App's permissions, when GitHub said.
    let permissionsURL: URL?
    /// Whether GitHub left some of the answer out.
    let isPartial: Bool

    func replacingSnapshot(_ snapshot: ForgeCommitWorkflowSnapshot, isPartial: Bool) -> ForgeWorkflowInspection {
        ForgeWorkflowInspection(
            pullRequest: pullRequest,
            commit: commit,
            snapshot: snapshot,
            access: access,
            permissionsURL: permissionsURL,
            isPartial: self.isPartial || isPartial
        )
    }
}

enum ForgeWorkflowInspectionError: Error, Equatable, LocalizedError {
    /// The pull request's head commit is unknown, so there is nothing to inspect.
    case headUnavailable
    /// A newer request or a credential change replaced this one.
    case superseded
    case rateLimited(until: Date?)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .headUnavailable: "GitHub did not say which commit this pull request is on."
        case .superseded: "A newer request replaced this one."
        case let .rateLimited(until):
            if let until {
                "GitHub is rate limiting requests until \(until.formatted(date: .omitted, time: .shortened))."
            } else {
                "GitHub is rate limiting requests."
            }
        case let .readFailed(message): message
        }
    }
}

/// One answer from the forge, with what the inspection needs to know about it.
struct ForgeWorkflowReadPage<Value: Sendable>: Sendable {
    let value: Value
    let isPartial: Bool
    let permissionsURL: URL?
}

/// The reads a workflow inspection makes, so its decisions are testable without the network.
protocol ForgeWorkflowReading: Sendable {
    /// The repository every read is bound to.
    var repository: ForgeRepositoryIdentity { get }
    func readCapability() async throws -> ForgeOperationCapability
    func record(_ outcome: ForgeCapabilityAttemptOutcome, for attempt: ForgeUnverifiedReadAttempt) async
    func commitWorkflowRuns(
        commit: ForgeCommitID,
        includeWorkflowRuns: Bool,
        after: ForgePageCursor?
    ) async throws -> ForgeWorkflowReadPage<ForgeCommitWorkflowSnapshot>
    func jobs(of suite: ForgeWorkflowRun, after: ForgePageCursor) async throws -> ForgeWorkflowReadPage<ForgeWorkflowPage<ForgeWorkflowJob>>
    func steps(of job: ForgeWorkflowJob) async throws -> ForgeWorkflowReadPage<ForgeWorkflowPage<ForgeWorkflowStep>>
}

/// Decides whether to ask for workflow runs and what the answer proves about the credential.
enum ForgeWorkflowAccessPolicy {
    static func includesWorkflowRuns(_ capability: ForgeOperationCapability) -> Bool {
        switch capability {
        case .verified, .unverifiedRead: true
        case .unverifiedWrite, .unavailable: false
        }
    }

    static func access(
        _ capability: ForgeOperationCapability,
        snapshot: ForgeCommitWorkflowSnapshot
    ) -> ForgeWorkflowAccess {
        if snapshot.actionsUnavailable {
            return .denied
        }
        switch capability {
        case .verified:
            return .granted
        case .unverifiedRead:
            return proves(snapshot) ? .granted : .unverified
        case .unverifiedWrite, .unavailable:
            return .denied
        }
    }

    /// What the read proved about an unverified read, or nil when it proved nothing: a commit without
    /// GitHub Actions suites says nothing about the permission.
    static func outcome(
        _ capability: ForgeOperationCapability,
        snapshot: ForgeCommitWorkflowSnapshot
    ) -> (ForgeCapabilityAttemptOutcome, ForgeUnverifiedReadAttempt)? {
        guard case let .unverifiedRead(attempt) = capability else { return nil }
        if snapshot.actionsUnavailable {
            return (.authorizationDenied, attempt)
        }
        return proves(snapshot) ? (.success, attempt) : nil
    }

    private static func proves(_ snapshot: ForgeCommitWorkflowSnapshot) -> Bool {
        snapshot.suites.items.contains {
            if case .available = $0.run {
                return true
            }
            return false
        }
    }
}

/// Reads the workflow runs on pull requests' head commits on demand, for one credential and repository.
/// Answers are cached per commit until Refresh; nothing polls (ADR 0015).
@MainActor
final class ForgeWorkflowInspectionService {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeWorkflows")

    private let reader: any ForgeWorkflowReading
    private var inspections: [ForgeCommitID: ForgeWorkflowInspection] = [:]
    private var steps: [ForgeObjectID: [ForgeWorkflowStep]] = [:]
    private var generation: UInt64 = 0

    init(reader: any ForgeWorkflowReading) {
        self.reader = reader
    }

    /// The repository whose pull requests this service inspects; others are not shown.
    var repository: ForgeRepositoryIdentity {
        reader.repository
    }

    func canInspect(_ pullRequest: ForgePullRequestSummary) -> Bool {
        pullRequest.repository == repository && Self.headCommit(of: pullRequest) != nil
    }

    func cachedInspection(for pullRequest: ForgePullRequestSummary) -> ForgeWorkflowInspection? {
        guard let commit = Self.headCommit(of: pullRequest) else { return nil }
        return inspections[commit]
    }

    /// Reads the check suites on the pull request's head commit, or returns the cached answer.
    func inspect(_ pullRequest: ForgePullRequestSummary, refresh: Bool = false) async throws -> ForgeWorkflowInspection {
        guard pullRequest.repository == repository, let commit = Self.headCommit(of: pullRequest) else {
            throw ForgeWorkflowInspectionError.headUnavailable
        }
        if !refresh, let cached = inspections[commit] {
            return cached
        }
        let started = generation
        Self.logger.info("Reading workflow runs pr=\(pullRequest.number.rawValue) refresh=\(refresh)")
        let capability = try await read { try await reader.readCapability() }
        let includeWorkflowRuns = ForgeWorkflowAccessPolicy.includesWorkflowRuns(capability)
        let page = try await read {
            try await reader.commitWorkflowRuns(commit: commit, includeWorkflowRuns: includeWorkflowRuns, after: nil)
        }
        if let (outcome, attempt) = ForgeWorkflowAccessPolicy.outcome(capability, snapshot: page.value) {
            Self.logger.notice("Recorded unverified Actions read outcome=\(String(describing: outcome), privacy: .public)")
            await reader.record(outcome, for: attempt)
        }
        guard started == generation else { throw ForgeWorkflowInspectionError.superseded }
        guard page.value.commit == commit else { throw ForgeWorkflowInspectionError.superseded }
        let inspection = ForgeWorkflowInspection(
            pullRequest: pullRequest.number,
            commit: commit,
            snapshot: page.value,
            access: ForgeWorkflowAccessPolicy.access(capability, snapshot: page.value),
            permissionsURL: page.permissionsURL,
            isPartial: page.isPartial
        )
        inspections[commit] = inspection
        Self.logger.info("Read workflow runs suites=\(page.value.suites.items.count) access=\(String(describing: inspection.access), privacy: .public) partial=\(page.isPartial)")
        return inspection
    }

    /// Reads the next page of check suites.
    func loadMoreSuites(_ inspection: ForgeWorkflowInspection) async throws -> ForgeWorkflowInspection {
        guard let cursor = inspection.snapshot.suites.nextCursor else { return inspection }
        let started = generation
        let page = try await read {
            try await reader.commitWorkflowRuns(
                commit: inspection.commit,
                includeWorkflowRuns: inspection.access != .denied,
                after: cursor
            )
        }
        guard started == generation, inspections[inspection.commit] != nil else { throw ForgeWorkflowInspectionError.superseded }
        let merged = try inspection.replacingSnapshot(inspection.snapshot.appendingSuites(page.value), isPartial: page.isPartial)
        inspections[inspection.commit] = merged
        return merged
    }

    /// Reads the next page of one suite's jobs.
    func loadMoreJobs(of suite: ForgeWorkflowRun, in inspection: ForgeWorkflowInspection) async throws -> ForgeWorkflowInspection {
        guard let cursor = suite.jobs.nextCursor else { return inspection }
        let started = generation
        let page = try await read { try await reader.jobs(of: suite, after: cursor) }
        guard started == generation, let current = inspections[inspection.commit] else { throw ForgeWorkflowInspectionError.superseded }
        let suites = try current.snapshot.suites.items.map { $0.id == suite.id ? try $0.appendingJobs(page.value) : $0 }
        let snapshot = try ForgeCommitWorkflowSnapshot(
            repository: current.snapshot.repository,
            commit: current.commit,
            suites: ForgeWorkflowPage(
                items: suites,
                nextCursor: current.snapshot.suites.nextCursor,
                totalCount: current.snapshot.suites.totalCount
            ),
            actionsUnavailable: current.snapshot.actionsUnavailable
        )
        let merged = current.replacingSnapshot(snapshot, isPartial: page.isPartial)
        inspections[inspection.commit] = merged
        return merged
    }

    /// Reads a job's steps, all of them, once.
    func steps(of job: ForgeWorkflowJob) async throws -> [ForgeWorkflowStep] {
        if let cached = steps[job.id] {
            return cached
        }
        let started = generation
        let page = try await read { try await reader.steps(of: job) }
        guard started == generation else { throw ForgeWorkflowInspectionError.superseded }
        steps[job.id] = page.value.items
        return page.value.items
    }

    /// Forgets every answer, for example after the credential changes.
    func invalidate() {
        generation &+= 1
        inspections.removeAll()
        steps.removeAll()
        Self.logger.info("Invalidated workflow inspection cache")
    }

    static func headCommit(of pullRequest: ForgePullRequestSummary) -> ForgeCommitID? {
        guard case let .available(head) = pullRequest.head else { return nil }
        return head.commit
    }

    private func read<Value>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ForgeWorkflowInspectionError {
            throw error
        } catch let GitHubReadError.rateLimited(response) {
            Self.logger.error("Workflow read rate limited")
            throw ForgeWorkflowInspectionError.rateLimited(until: response.rateLimit.retryAt ?? response.rateLimit.resetAt)
        } catch {
            Self.logger.error("Workflow read failed: \(error.localizedDescription, privacy: .public)")
            throw ForgeWorkflowInspectionError.readFailed(error.localizedDescription)
        }
    }
}

/// Reads workflow runs from GitHub with the window's credential and records what an unverified read proved
/// in the credential's shared promotion ledger.
struct ForgeGitHubWorkflowReader: ForgeWorkflowReading {
    let adapter: GitHubReadAdapter
    let accountID: ForgeAccountID
    let repository: ForgeRepositoryIdentity
    let capabilities: any RepositoryPullRequestMutationServing
    let state: ForgeGitHubMutationStateStore

    func readCapability() async throws -> ForgeOperationCapability {
        let evaluated = try await capabilities.capabilities(
            accountID: accountID,
            repository: repository,
            operations: [.readWorkflowRuns]
        )
        return evaluated[.readWorkflowRuns] ?? .unavailable(.unsupportedProviderOperation)
    }

    func record(_ outcome: ForgeCapabilityAttemptOutcome, for attempt: ForgeUnverifiedReadAttempt) async {
        await state.recordUnverifiedRead(outcome, for: attempt)
    }

    func commitWorkflowRuns(
        commit: ForgeCommitID,
        includeWorkflowRuns: Bool,
        after: ForgePageCursor?
    ) async throws -> ForgeWorkflowReadPage<ForgeCommitWorkflowSnapshot> {
        let result = try await adapter.commitWorkflowRuns(
            repository: repository,
            commit: commit,
            includeWorkflowRuns: includeWorkflowRuns,
            after: after
        )
        return page(result)
    }

    func jobs(of suite: ForgeWorkflowRun, after: ForgePageCursor) async throws -> ForgeWorkflowReadPage<ForgeWorkflowPage<ForgeWorkflowJob>> {
        try await page(adapter.checkSuiteJobs(repository: repository, suite: suite, after: after))
    }

    func steps(of job: ForgeWorkflowJob) async throws -> ForgeWorkflowReadPage<ForgeWorkflowPage<ForgeWorkflowStep>> {
        try await page(adapter.workflowJobSteps(repository: repository, job: job))
    }

    private func page<Value>(_ result: GitHubReadResult<Value>) -> ForgeWorkflowReadPage<Value> {
        ForgeWorkflowReadPage(
            value: result.value,
            isPartial: result.completeness == .partial,
            permissionsURL: result.response.installation?.configurationURL
        )
    }
}
