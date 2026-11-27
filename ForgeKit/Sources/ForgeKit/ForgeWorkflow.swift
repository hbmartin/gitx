import Foundation

/// What a workflow run, job or step is doing, or how it ended. Values are provider-neutral; the GitHub adapter
/// maps check statuses and conclusions onto them.
public enum ForgeWorkflowOutcome: String, CaseIterable, Codable, Hashable, Sendable {
    case queued
    case waiting
    case running
    case succeeded
    case failed
    case cancelled
    case timedOut
    case actionRequired
    case skipped
    case neutral

    /// Whether the work has ended.
    public var isFinished: Bool {
        switch self {
        case .queued, .waiting, .running: false
        case .succeeded, .failed, .cancelled, .timedOut, .actionRequired, .skipped, .neutral: true
        }
    }

    /// Whether the work ended in a way that rerunning failed jobs repeats: a failure, cancellation or timeout.
    public var isRerunnableFailure: Bool {
        switch self {
        case .failed, .cancelled, .timedOut: true
        case .queued, .waiting, .running, .succeeded, .actionRequired, .skipped, .neutral: false
        }
    }

    /// The equivalent state in the pull request's check list.
    public var checkState: ForgeCheckState {
        switch self {
        case .succeeded: .succeeded
        case .failed, .cancelled, .timedOut: .failed
        case .queued, .waiting, .running: .running
        case .actionRequired: .attentionRequired
        case .skipped, .neutral: .neutral
        }
    }
}

/// One step of a workflow job. Steps hold no logs; their logs stay on the forge.
public struct ForgeWorkflowStep: Hashable, Sendable {
    public let number: Int
    public let name: String
    public let outcome: ForgeWorkflowOutcome
    public let startedAt: Date?
    public let completedAt: Date?

    public init(number: Int, name: String, outcome: ForgeWorkflowOutcome, startedAt: Date? = nil, completedAt: Date? = nil) throws {
        guard number > 0 else { throw ForgeCollaborationModelError.invalidWorkflowNumber }
        guard ForgePathComponent.isNonemptyPrintable(name) else { throw ForgeCollaborationModelError.invalidCheckName }
        self.number = number
        self.name = name
        self.outcome = outcome
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// A job of a workflow run, or a check run of another app's check suite. GitHub Actions jobs are check runs.
public struct ForgeWorkflowJob: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    /// The identifier the forge uses to page this job's steps.
    public let id: ForgeObjectID
    /// The job's page, which holds its logs; nil when the forge did not say which run it belongs to.
    public let destination: ForgeDestination?
    public let name: String
    public let outcome: ForgeWorkflowOutcome
    /// The forge's page for a check run of another app; nil for an Actions job, which opens through `destination`.
    public let detailsURL: URL?
    public let startedAt: Date?
    public let completedAt: Date?

    public init(
        repository: ForgeRepositoryIdentity,
        id: ForgeObjectID,
        destination: ForgeDestination? = nil,
        name: String,
        outcome: ForgeWorkflowOutcome,
        detailsURL: URL? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) throws {
        guard id.forge == repository.forge else { throw ForgeCollaborationModelError.mismatchedForge }
        if let destination {
            guard case .workflowJob = destination else { throw ForgeCollaborationModelError.invalidWorkflowDestination }
            guard destination.repository == repository else { throw ForgeCollaborationModelError.mismatchedRepository }
        }
        guard ForgePathComponent.isNonemptyPrintable(name) else { throw ForgeCollaborationModelError.invalidCheckName }
        self.repository = repository
        self.id = id
        self.destination = destination
        self.name = name
        self.outcome = outcome
        self.detailsURL = detailsURL
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// A page of jobs, check runs or steps, and where the next page starts.
public struct ForgeWorkflowPage<Element: Hashable & Sendable>: Hashable, Sendable {
    public let items: [Element]
    public let nextCursor: ForgePageCursor?
    public let totalCount: Int?

    public init(items: [Element], nextCursor: ForgePageCursor? = nil, totalCount: Int? = nil) throws {
        if let totalCount, totalCount < 0 {
            throw ForgeCollaborationModelError.invalidPageTotal
        }
        self.items = items
        self.nextCursor = nextCursor
        self.totalCount = totalCount
    }

    /// Appends the next page, keeping the first occurrence of an item the forge returned twice.
    public func appending(_ next: ForgeWorkflowPage<Element>) -> ForgeWorkflowPage<Element> {
        var seen = Set(items)
        let added = next.items.filter { seen.insert($0).inserted }
        // swiftlint:disable:next force_try
        return try! ForgeWorkflowPage(items: items + added, nextCursor: next.nextCursor, totalCount: next.totalCount ?? totalCount)
    }
}

/// The workflow run behind a GitHub Actions check suite: what the forge knows about it with Actions read access.
public struct ForgeWorkflowRunDetails: Hashable, Sendable {
    public let destination: ForgeDestination
    public let workflowName: String
    public let title: String?
    public let runNumber: Int
    public let attempt: Int
    public let event: String?

    public init(
        destination: ForgeDestination,
        workflowName: String,
        title: String? = nil,
        runNumber: Int,
        attempt: Int,
        event: String? = nil
    ) throws {
        guard case .workflowRun = destination else { throw ForgeCollaborationModelError.invalidWorkflowDestination }
        guard ForgePathComponent.isNonemptyPrintable(workflowName) else { throw ForgeCollaborationModelError.invalidCheckName }
        guard runNumber > 0, attempt > 0 else { throw ForgeCollaborationModelError.invalidWorkflowNumber }
        self.destination = destination
        self.workflowName = workflowName
        self.title = title.flatMap { ForgePathComponent.isNonemptyPrintable($0) ? $0 : nil }
        self.runNumber = runNumber
        self.attempt = attempt
        self.event = event
    }
}

/// What the forge said about the workflow run behind a check suite.
public enum ForgeWorkflowRunSection: Hashable, Sendable {
    case available(ForgeWorkflowRunDetails)
    /// GitX did not ask, because the suite is not an Actions suite or the credential cannot read Actions.
    case notRequested
    /// The forge refused to say; the credential lacks Actions read access.
    case permissionDenied
}

/// One check suite on a commit, grouped by the app that created it. A GitHub Actions suite is one workflow
/// run; its `run` is unavailable when the credential cannot read Actions.
public struct ForgeWorkflowRun: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    /// The identifier the forge uses to page this suite's jobs.
    public let id: ForgeObjectID
    public let appName: String
    public let isActions: Bool
    public let run: ForgeWorkflowRunSection
    public let outcome: ForgeWorkflowOutcome
    public let jobs: ForgeWorkflowPage<ForgeWorkflowJob>
    public let updatedAt: Date?

    public init(
        repository: ForgeRepositoryIdentity,
        id: ForgeObjectID,
        appName: String,
        isActions: Bool,
        run: ForgeWorkflowRunSection,
        outcome: ForgeWorkflowOutcome,
        jobs: ForgeWorkflowPage<ForgeWorkflowJob>,
        updatedAt: Date? = nil
    ) throws {
        guard id.forge == repository.forge else { throw ForgeCollaborationModelError.mismatchedForge }
        guard ForgePathComponent.isNonemptyPrintable(appName) else { throw ForgeCollaborationModelError.invalidCheckName }
        guard jobs.items.allSatisfy({ $0.repository == repository }) else { throw ForgeCollaborationModelError.mismatchedRepository }
        if case let .available(details) = run, details.destination.repository != repository {
            throw ForgeCollaborationModelError.mismatchedRepository
        }
        self.repository = repository
        self.id = id
        self.appName = appName
        self.isActions = isActions
        self.run = run
        self.outcome = outcome
        self.jobs = jobs
        self.updatedAt = updatedAt
    }

    /// The suite's title: its workflow's name when the forge said, otherwise its app's name.
    public var title: String {
        if case let .available(details) = run {
            return details.workflowName
        }
        return appName
    }

    /// The same suite with more jobs.
    public func appendingJobs(_ next: ForgeWorkflowPage<ForgeWorkflowJob>) throws -> ForgeWorkflowRun {
        try ForgeWorkflowRun(
            repository: repository,
            id: id,
            appName: appName,
            isActions: isActions,
            run: run,
            outcome: outcome,
            jobs: jobs.appending(next),
            updatedAt: updatedAt
        )
    }
}

/// Every check suite the forge reported for one commit.
public struct ForgeCommitWorkflowSnapshot: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let commit: ForgeCommitID
    public let suites: ForgeWorkflowPage<ForgeWorkflowRun>
    /// Whether the forge refused to say which workflow runs the suites belong to.
    public let actionsUnavailable: Bool

    public init(
        repository: ForgeRepositoryIdentity,
        commit: ForgeCommitID,
        suites: ForgeWorkflowPage<ForgeWorkflowRun>,
        actionsUnavailable: Bool
    ) throws {
        guard suites.items.allSatisfy({ $0.repository == repository }) else { throw ForgeCollaborationModelError.mismatchedRepository }
        self.repository = repository
        self.commit = commit
        self.suites = suites
        self.actionsUnavailable = actionsUnavailable
    }

    /// The same commit with the next page of suites.
    public func appendingSuites(_ next: ForgeCommitWorkflowSnapshot) throws -> ForgeCommitWorkflowSnapshot {
        guard next.repository == repository, next.commit == commit else { throw ForgeCollaborationModelError.mismatchedRepository }
        return try ForgeCommitWorkflowSnapshot(
            repository: repository,
            commit: commit,
            suites: suites.appending(next.suites),
            actionsUnavailable: actionsUnavailable || next.actionsUnavailable
        )
    }
}

/// What GitX offers for rerunning a workflow run's failed jobs. GitX never reruns natively; it opens the run's
/// page, where the forge asks for confirmation (ADR 0015).
public enum ForgeWorkflowRerunEligibility: Hashable, Sendable {
    case openRun(ForgeDestination)
    case unavailable(ForgeWorkflowRerunUnavailableReason)
}

public enum ForgeWorkflowRerunUnavailableReason: String, CaseIterable, Hashable, Sendable {
    /// The suite is not a GitHub Actions workflow run.
    case notAWorkflowRun
    /// The forge did not say which run the suite belongs to.
    case runUnknown
    /// The run has not finished.
    case stillRunning
    /// No job failed, was cancelled or timed out.
    case nothingFailed
}

public enum ForgeWorkflowPresentationPolicy {
    /// Orders suites so failures come first, then work still running, then everything else; ties keep the
    /// forge's order.
    public static func ordered(_ suites: [ForgeWorkflowRun]) -> [ForgeWorkflowRun] {
        suites.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element.outcome)
            let right = rank(rhs.element.outcome)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// Orders jobs the same way as suites.
    public static func ordered(_ jobs: [ForgeWorkflowJob]) -> [ForgeWorkflowJob] {
        jobs.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element.outcome)
            let right = rank(rhs.element.outcome)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    public static func rerunFailedEligibility(_ suite: ForgeWorkflowRun) -> ForgeWorkflowRerunEligibility {
        guard suite.isActions else { return .unavailable(.notAWorkflowRun) }
        guard case let .available(details) = suite.run else { return .unavailable(.runUnknown) }
        guard suite.outcome.isFinished, suite.jobs.items.allSatisfy(\.outcome.isFinished) else {
            return .unavailable(.stillRunning)
        }
        guard suite.outcome.isRerunnableFailure || suite.jobs.items.contains(where: \.outcome.isRerunnableFailure) else {
            return .unavailable(.nothingFailed)
        }
        return .openRun(details.destination)
    }

    /// A one-line description of a suite for its row, such as "CI #42 · Failed".
    public static func summary(_ suite: ForgeWorkflowRun) -> String {
        var title = suite.title
        if case let .available(details) = suite.run {
            title += " #\(details.runNumber)"
            if details.attempt > 1 {
                title += " (attempt \(details.attempt))"
            }
        }
        return "\(title) · \(outcomeName(suite.outcome))"
    }

    public static func outcomeName(_ outcome: ForgeWorkflowOutcome) -> String {
        switch outcome {
        case .queued: "Queued"
        case .waiting: "Waiting"
        case .running: "Running"
        case .succeeded: "Passed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed out"
        case .actionRequired: "Action required"
        case .skipped: "Skipped"
        case .neutral: "Neutral"
        }
    }

    private static func rank(_ outcome: ForgeWorkflowOutcome) -> Int {
        switch outcome {
        case .failed, .cancelled, .timedOut, .actionRequired: 0
        case .queued, .waiting, .running: 1
        case .succeeded, .skipped, .neutral: 2
        }
    }
}
