@_spi(Unsafe) import ApolloAPI
import ForgeKit
import Foundation

/// Maps the on-demand workflow reads (ADR 0015) onto provider-neutral workflow values.
extension GitHubGraphQLDocumentMapper {
    /// The app slug GitHub gives every GitHub Actions check suite.
    static let actionsAppSlug = "github-actions"

    func commitWorkflowRuns(
        data: GitHubAPI.GitHubCommitWorkflowRunsQuery.Data,
        repository: ForgeRepositoryIdentity,
        commit expectedCommit: ForgeCommitID,
        includeWorkflowRuns: Bool,
        problems: [GitHubGraphQLProblem]
    ) throws -> GitHubMappedValue<ForgeCommitWorkflowSnapshot> {
        guard let repositoryNode = data.repository else { throw GitHubReadError.repositoryNotFound }
        try validateRepository(repositoryNode.fragments.gitHubRepositoryIdentity, expected: repository)
        guard let commit = repositoryNode.object?.asCommit else { throw GitHubReadError.objectNotFound }
        guard try ForgeCommitID(commit.oid) == expectedCommit else { throw GitHubReadError.malformedResponse }
        let workflowRunProblems = problems.filter { $0.path.contains("workflowRun") }
        let workflowRunDenied = workflowRunProblems.contains { $0.classification == "FORBIDDEN" }

        guard let connection = commit.checkSuites else {
            let snapshot = try ForgeCommitWorkflowSnapshot(
                repository: repository,
                commit: expectedCommit,
                suites: ForgeWorkflowPage(items: []),
                actionsUnavailable: workflowRunDenied
            )
            return GitHubMappedValue(value: snapshot, isPartial: true)
        }
        var isPartial = !workflowRunProblems.isEmpty && !workflowRunDenied
        var skipped = 0
        let mapped = try mapNodes(connection.nodes) { node -> ForgeWorkflowRun? in
            let jobCount = node.checkRuns?.totalCount ?? 0
            if node.workflowRun == nil, node.checkRuns != nil, jobCount == 0 {
                // GitHub leaves an empty suite for an app that had nothing to run; it is not a run.
                skipped += 1
                return nil
            }
            let suite = node.fragments.gitHubWorkflowCheckSuite
            let isActions = suite.app?.slug == Self.actionsAppSlug
            let run: ForgeWorkflowRunSection
            if !isActions || !includeWorkflowRuns {
                run = .notRequested
            } else if let workflowRun = node.workflowRun {
                guard let details = try workflowRunDetails(workflowRun, repository: repository) else { return nil }
                run = .available(details)
            } else if workflowRunDenied {
                run = .permissionDenied
            } else {
                run = .notRequested
                isPartial = true
            }
            let runID: ForgeWorkflowRunID? = if case let .available(details) = run,
                                                case let .workflowRun(_, identifier) = details.destination
            {
                identifier
            } else {
                nil
            }
            guard let jobs = node.checkRuns else { return nil }
            let jobPage = try workflowJobPage(
                nodes: jobs.nodes?.map { $0?.fragments.gitHubWorkflowJob },
                totalCount: jobs.totalCount,
                pageInfo: jobs.pageInfo.fragments.gitHubPageInfo,
                repository: repository,
                runID: runID
            )
            isPartial = isPartial || jobPage.isPartial
            guard let outcome = workflowOutcome(status: suite.status.value, conclusion: suite.conclusion?.value),
                  let appName = printable(suite.app?.name) ?? (suite.app == nil ? "Checks" : nil)
            else { return nil }
            return try ForgeWorkflowRun(
                repository: repository,
                id: objectID(suite.id),
                appName: appName,
                isActions: isActions,
                run: run,
                outcome: outcome,
                jobs: jobPage.page,
                updatedAt: date(suite.updatedAt)
            )
        }
        let pageInfo = connection.pageInfo.fragments.gitHubPageInfo
        let dropped = mapped.isPartial && mapped.values.count + skipped != (connection.nodes?.count ?? -1)
        let suites = try ForgeWorkflowPage(
            items: mapped.values,
            nextCursor: nextCursor(pageInfo),
            totalCount: connection.totalCount
        )
        let snapshot = try ForgeCommitWorkflowSnapshot(
            repository: repository,
            commit: expectedCommit,
            suites: suites,
            actionsUnavailable: workflowRunDenied
        )
        return GitHubMappedValue(
            value: snapshot,
            isPartial: isPartial || dropped || connectionCountIsInconsistent(
                mappedCount: mapped.values.count + skipped,
                totalCount: connection.totalCount,
                pageInfo: pageInfo
            )
        )
    }

    func checkSuiteJobs(
        data: GitHubAPI.GitHubCheckSuiteJobsQuery.Data,
        repository: ForgeRepositoryIdentity,
        suite: ForgeWorkflowRun
    ) throws -> GitHubMappedValue<ForgeWorkflowPage<ForgeWorkflowJob>> {
        guard let node = data.node?.asCheckSuite else { throw GitHubReadError.objectNotFound }
        try validateRepository(node.repository.fragments.gitHubRepositoryIdentity, expected: repository)
        guard try objectID(node.id) == suite.id, let connection = node.checkRuns else {
            throw GitHubReadError.malformedResponse
        }
        let runID: ForgeWorkflowRunID? = if case let .available(details) = suite.run,
                                            case let .workflowRun(_, identifier) = details.destination
        {
            identifier
        } else {
            nil
        }
        let mapped = try workflowJobPage(
            nodes: connection.nodes?.map { $0?.fragments.gitHubWorkflowJob },
            totalCount: connection.totalCount,
            pageInfo: connection.pageInfo.fragments.gitHubPageInfo,
            repository: repository,
            runID: runID
        )
        return GitHubMappedValue(value: mapped.page, isPartial: mapped.isPartial)
    }

    func workflowJobSteps(
        data: GitHubAPI.GitHubWorkflowJobStepsQuery.Data,
        repository: ForgeRepositoryIdentity,
        job: ForgeWorkflowJob
    ) throws -> GitHubMappedValue<ForgeWorkflowPage<ForgeWorkflowStep>> {
        guard let node = data.node?.asCheckRun else { throw GitHubReadError.objectNotFound }
        try validateRepository(node.repository.fragments.gitHubRepositoryIdentity, expected: repository)
        guard try objectID(node.id) == job.id else { throw GitHubReadError.malformedResponse }
        guard let connection = node.steps else {
            return try GitHubMappedValue(value: ForgeWorkflowPage(items: []), isPartial: true)
        }
        let mapped = try mapNodes(connection.nodes) { step -> ForgeWorkflowStep? in
            guard let outcome = workflowOutcome(status: step.status.value, conclusion: step.conclusion?.value),
                  let name = printable(step.name),
                  step.number > 0
            else { return nil }
            return try ForgeWorkflowStep(
                number: step.number,
                name: name,
                outcome: outcome,
                startedAt: optionalDate(step.startedAt),
                completedAt: optionalDate(step.completedAt)
            )
        }
        let pageInfo = connection.pageInfo.fragments.gitHubPageInfo
        let page = try ForgeWorkflowPage(items: mapped.values, nextCursor: nextCursor(pageInfo), totalCount: connection.totalCount)
        return GitHubMappedValue(
            value: page,
            isPartial: mapped.isPartial || connectionCountIsInconsistent(
                mappedCount: mapped.values.count,
                totalCount: connection.totalCount,
                pageInfo: pageInfo
            )
        )
    }

    func workflowOutcome(
        status: GitHubAPI.CheckStatusState?,
        conclusion: GitHubAPI.CheckConclusionState?
    ) -> ForgeWorkflowOutcome? {
        switch status {
        case .queued, .requested, .pending: return .queued
        case .waiting: return .waiting
        case .inProgress: return .running
        case nil: return nil
        case .completed:
            switch conclusion {
            case .success: return .succeeded
            case .failure, .startupFailure: return .failed
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            case .actionRequired: return .actionRequired
            case .skipped: return .skipped
            case .neutral, .stale, nil: return .neutral
            }
        }
    }
}

private extension GitHubGraphQLDocumentMapper {
    struct JobPageMapping {
        let page: ForgeWorkflowPage<ForgeWorkflowJob>
        let isPartial: Bool
    }

    func workflowRunDetails(
        _ node: GitHubAPI.GitHubCommitWorkflowRunsQuery.Data.Repository.Object.AsCommit.CheckSuites.Node.WorkflowRun,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeWorkflowRunDetails? {
        guard let databaseID = node.databaseId,
              let runID = try? ForgeWorkflowRunID(Int64(databaseID)),
              let workflowName = printable(node.workflow.name),
              node.runNumber > 0,
              node.runAttempt > 0
        else { return nil }
        return try ForgeWorkflowRunDetails(
            destination: .workflowRun(repository, runID),
            workflowName: workflowName,
            title: printable(node.displayTitle),
            runNumber: node.runNumber,
            attempt: node.runAttempt,
            event: printable(node.event)
        )
    }

    func workflowJobPage(
        nodes: [GitHubAPI.GitHubWorkflowJob?]?,
        totalCount: Int,
        pageInfo: GitHubAPI.GitHubPageInfo,
        repository: ForgeRepositoryIdentity,
        runID: ForgeWorkflowRunID?
    ) throws -> JobPageMapping {
        let mapped = try mapNodes(nodes) { try workflowJob($0, repository: repository, runID: runID) }
        let page = try ForgeWorkflowPage(items: mapped.values, nextCursor: nextCursor(pageInfo), totalCount: totalCount)
        return JobPageMapping(
            page: page,
            isPartial: mapped.isPartial || connectionCountIsInconsistent(
                mappedCount: mapped.values.count,
                totalCount: totalCount,
                pageInfo: pageInfo
            )
        )
    }

    func workflowJob(
        _ node: GitHubAPI.GitHubWorkflowJob,
        repository: ForgeRepositoryIdentity,
        runID: ForgeWorkflowRunID?
    ) throws -> ForgeWorkflowJob? {
        guard let outcome = workflowOutcome(status: node.status.value, conclusion: node.conclusion?.value),
              let name = printable(node.name)
        else { return nil }
        let detailsURL = node.detailsUrl.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        var destination: ForgeDestination?
        if let runID, let databaseID = node.databaseId, let jobID = try? ForgeWorkflowJobID(Int64(databaseID)) {
            destination = .workflowJob(repository, run: runID, job: jobID)
        } else if let detailsURL,
                  let parsed = try? ForgeDestinationURLCodec.parse(detailsURL, boundTo: repository),
                  case .workflowJob = parsed
        {
            // Without Actions access the job's own page still names its run.
            destination = parsed
        }
        return try ForgeWorkflowJob(
            repository: repository,
            id: objectID(node.id),
            destination: destination,
            name: name,
            outcome: outcome,
            detailsURL: destination == nil ? detailsURL : nil,
            startedAt: optionalDate(node.startedAt),
            completedAt: optionalDate(node.completedAt)
        )
    }

    func printable(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }
}
