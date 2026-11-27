@testable import ForgeKit
import Foundation
import XCTest

final class ForgeWorkflowTests: XCTestCase {
    private func identifier(_ value: String, kind: ForgeKind = .github) throws -> ForgeObjectID {
        try ForgeObjectID(forge: TestSupport.repository(kind: kind).forge, value: value)
    }

    private func job(
        _ name: String,
        _ outcome: ForgeWorkflowOutcome,
        run: Int64 = 10,
        job: Int64? = nil
    ) throws -> ForgeWorkflowJob {
        let repository = try TestSupport.repository()
        let destination = try job.map { try ForgeDestination.workflowJob(repository, run: ForgeWorkflowRunID(run), job: ForgeWorkflowJobID($0)) }
        return try ForgeWorkflowJob(repository: repository, id: identifier("job-\(name)"), destination: destination, name: name, outcome: outcome)
    }

    private func details(run: Int64 = 10, number: Int = 42, attempt: Int = 1) throws -> ForgeWorkflowRunDetails {
        try ForgeWorkflowRunDetails(
            destination: .workflowRun(TestSupport.repository(), ForgeWorkflowRunID(run)),
            workflowName: "CI",
            title: "Fix the build",
            runNumber: number,
            attempt: attempt,
            event: "pull_request"
        )
    }

    private func suite(
        _ name: String,
        _ outcome: ForgeWorkflowOutcome,
        jobs: [ForgeWorkflowJob] = [],
        isActions: Bool = true,
        run: ForgeWorkflowRunSection? = nil
    ) throws -> ForgeWorkflowRun {
        try ForgeWorkflowRun(
            repository: TestSupport.repository(),
            id: identifier("suite-\(name)"),
            appName: isActions ? "GitHub Actions" : name,
            isActions: isActions,
            run: run ?? (isActions ? .available(details()) : .notRequested),
            outcome: outcome,
            jobs: ForgeWorkflowPage(items: jobs)
        )
    }

    func testOutcomesSayWhetherTheyFinishedFailedAndHowTheyRollUp() {
        let finished = Set(ForgeWorkflowOutcome.allCases.filter(\.isFinished))
        XCTAssertEqual(finished, [.succeeded, .failed, .cancelled, .timedOut, .actionRequired, .skipped, .neutral])
        XCTAssertEqual(Set(ForgeWorkflowOutcome.allCases.filter(\.isRerunnableFailure)), [.failed, .cancelled, .timedOut])
        let states = Dictionary(uniqueKeysWithValues: ForgeWorkflowOutcome.allCases.map { ($0, $0.checkState) })
        XCTAssertEqual(states, [
            .queued: .running, .waiting: .running, .running: .running,
            .succeeded: .succeeded,
            .failed: .failed, .cancelled: .failed, .timedOut: .failed,
            .actionRequired: .attentionRequired,
            .skipped: .neutral, .neutral: .neutral,
        ])
        XCTAssertEqual(
            ForgeWorkflowOutcome.allCases.map(ForgeWorkflowPresentationPolicy.outcomeName),
            ["Queued", "Waiting", "Running", "Passed", "Failed", "Cancelled", "Timed out", "Action required", "Skipped", "Neutral"]
        )
    }

    func testValuesRejectInvalidNumbersNamesAndMismatchedRepositories() throws {
        let repository = try TestSupport.repository()
        let other = try TestSupport.repository(name: "other")
        let gitLab = try TestSupport.repository(kind: .gitLab)
        XCTAssertThrowsError(try ForgeWorkflowStep(number: 0, name: "Build", outcome: .succeeded)) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .invalidWorkflowNumber)
        }
        XCTAssertThrowsError(try ForgeWorkflowStep(number: 1, name: " ", outcome: .succeeded))
        let step = try ForgeWorkflowStep(number: 1, name: "Build", outcome: .succeeded, startedAt: Date(timeIntervalSince1970: 1), completedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(step.completedAt, Date(timeIntervalSince1970: 2))

        XCTAssertThrowsError(try ForgeWorkflowJob(repository: repository, id: identifier("j", kind: .gitLab), name: "build", outcome: .failed)) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedForge)
        }
        XCTAssertThrowsError(try ForgeWorkflowJob(repository: repository, id: identifier("j"), destination: .repository(repository), name: "build", outcome: .failed)) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .invalidWorkflowDestination)
        }
        let otherJob = try ForgeDestination.workflowJob(other, run: ForgeWorkflowRunID(1), job: ForgeWorkflowJobID(2))
        XCTAssertThrowsError(try ForgeWorkflowJob(repository: repository, id: identifier("j"), destination: otherJob, name: "build", outcome: .failed)) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedRepository)
        }
        XCTAssertThrowsError(try ForgeWorkflowJob(repository: repository, id: identifier("j"), name: "", outcome: .failed))

        XCTAssertThrowsError(try ForgeWorkflowPage<ForgeWorkflowStep>(items: [], totalCount: -1))
        let runDestination = try ForgeDestination.workflowRun(repository, ForgeWorkflowRunID(1))
        XCTAssertThrowsError(try ForgeWorkflowRunDetails(destination: .repository(repository), workflowName: "CI", runNumber: 1, attempt: 1)) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .invalidWorkflowDestination)
        }
        XCTAssertThrowsError(try ForgeWorkflowRunDetails(destination: runDestination, workflowName: "\n", runNumber: 1, attempt: 1))
        XCTAssertThrowsError(try ForgeWorkflowRunDetails(destination: runDestination, workflowName: "CI", runNumber: 0, attempt: 1))
        XCTAssertThrowsError(try ForgeWorkflowRunDetails(destination: runDestination, workflowName: "CI", runNumber: 1, attempt: 0))
        XCTAssertNil(try ForgeWorkflowRunDetails(destination: runDestination, workflowName: "CI", title: " padded ", runNumber: 1, attempt: 1).title)

        let page = try ForgeWorkflowPage(items: [job("a", .failed)])
        XCTAssertThrowsError(try ForgeWorkflowRun(repository: gitLab, id: identifier("s"), appName: "CI", isActions: true, run: .notRequested, outcome: .failed, jobs: page)) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedForge)
        }
        XCTAssertThrowsError(try ForgeWorkflowRun(repository: repository, id: identifier("s"), appName: "", isActions: true, run: .notRequested, outcome: .failed, jobs: page))
        XCTAssertThrowsError(try ForgeWorkflowRun(repository: other, id: identifier("s"), appName: "CI", isActions: true, run: .notRequested, outcome: .failed, jobs: page)) {
            XCTAssertEqual($0 as? ForgeCollaborationModelError, .mismatchedRepository)
        }
        let otherRun = try ForgeWorkflowRunDetails(destination: .workflowRun(other, ForgeWorkflowRunID(1)), workflowName: "CI", runNumber: 1, attempt: 1)
        XCTAssertThrowsError(try ForgeWorkflowRun(repository: repository, id: identifier("s"), appName: "CI", isActions: true, run: .available(otherRun), outcome: .failed, jobs: ForgeWorkflowPage(items: [])))

        let snapshotSuites = try ForgeWorkflowPage(items: [suite("a", .failed)])
        XCTAssertThrowsError(try ForgeCommitWorkflowSnapshot(repository: other, commit: TestSupport.commit, suites: snapshotSuites, actionsUnavailable: false))
        XCTAssertNotNil(ForgeCollaborationModelError.invalidWorkflowNumber.errorDescription)
        XCTAssertNotNil(ForgeCollaborationModelError.invalidWorkflowDestination.errorDescription)
    }

    func testPagesAppendWithoutDuplicatesAndKeepTheLatestCursor() throws {
        let first = try ForgeWorkflowPage(items: [job("a", .failed), job("b", .running)], nextCursor: ForgePageCursor("c1"), totalCount: 3)
        let second = try ForgeWorkflowPage(items: [job("b", .running), job("c", .succeeded)])
        let merged = first.appending(second)
        XCTAssertEqual(merged.items.map(\.name), ["a", "b", "c"])
        XCTAssertNil(merged.nextCursor)
        XCTAssertEqual(merged.totalCount, 3, "A page without a total keeps the earlier total")

        let suiteValue = try suite("ci", .failed, jobs: [job("a", .failed)])
        let grown = try suiteValue.appendingJobs(ForgeWorkflowPage(items: [job("b", .succeeded)], totalCount: 2))
        XCTAssertEqual(grown.jobs.items.map(\.name), ["a", "b"])
        XCTAssertEqual(grown.jobs.totalCount, 2)
        XCTAssertEqual(grown.id, suiteValue.id)

        let repository = try TestSupport.repository()
        let snapshot = try ForgeCommitWorkflowSnapshot(
            repository: repository,
            commit: TestSupport.commit,
            suites: ForgeWorkflowPage(items: [suite("one", .succeeded)], nextCursor: ForgePageCursor("s1")),
            actionsUnavailable: false
        )
        let nextPage = try ForgeCommitWorkflowSnapshot(
            repository: repository,
            commit: TestSupport.commit,
            suites: ForgeWorkflowPage(items: [suite("two", .failed)]),
            actionsUnavailable: true
        )
        let combined = try snapshot.appendingSuites(nextPage)
        XCTAssertEqual(combined.suites.items.count, 2)
        XCTAssertNil(combined.suites.nextCursor)
        XCTAssertTrue(combined.actionsUnavailable)
        let otherCommit = try ForgeCommitWorkflowSnapshot(
            repository: repository,
            commit: ForgeCommitID(String(repeating: "b", count: 40)),
            suites: ForgeWorkflowPage(items: []),
            actionsUnavailable: false
        )
        XCTAssertThrowsError(try snapshot.appendingSuites(otherCommit))
    }

    func testPolicyOrdersFailuresThenRunningWorkAndKeepsTheForgeOrderOtherwise() throws {
        let suites = try [
            suite("passed", .succeeded),
            suite("running", .running),
            suite("failed", .failed),
            suite("skipped", .skipped),
            suite("queued", .queued),
            suite("attention", .actionRequired),
        ]
        XCTAssertEqual(
            ForgeWorkflowPresentationPolicy.ordered(suites).map(\.id.value),
            ["suite-failed", "suite-attention", "suite-running", "suite-queued", "suite-passed", "suite-skipped"]
        )
        let jobs = try [job("ok", .succeeded), job("timeout", .timedOut), job("wait", .waiting), job("cancel", .cancelled)]
        XCTAssertEqual(ForgeWorkflowPresentationPolicy.ordered(jobs).map(\.name), ["timeout", "cancel", "wait", "ok"])
    }

    func testRerunFailedOpensTheRunOnlyWhenItFinishedWithAFailedJob() throws {
        let failed = try suite("ci", .failed, jobs: [job("a", .failed), job("b", .succeeded)])
        XCTAssertEqual(
            ForgeWorkflowPresentationPolicy.rerunFailedEligibility(failed),
            try .openRun(.workflowRun(TestSupport.repository(), ForgeWorkflowRunID(10)))
        )
        let cancelledJob = try suite("ci", .neutral, jobs: [job("a", .cancelled)])
        XCTAssertEqual(ForgeWorkflowPresentationPolicy.rerunFailedEligibility(cancelledJob), try .openRun(.workflowRun(TestSupport.repository(), ForgeWorkflowRunID(10))))
        let failedWithoutJobs = try suite("ci", .timedOut)
        XCTAssertEqual(ForgeWorkflowPresentationPolicy.rerunFailedEligibility(failedWithoutJobs), try .openRun(.workflowRun(TestSupport.repository(), ForgeWorkflowRunID(10))))

        XCTAssertEqual(
            try ForgeWorkflowPresentationPolicy.rerunFailedEligibility(suite("lint", .failed, isActions: false)),
            .unavailable(.notAWorkflowRun)
        )
        XCTAssertEqual(
            try ForgeWorkflowPresentationPolicy.rerunFailedEligibility(suite("ci", .failed, run: .permissionDenied)),
            .unavailable(.runUnknown)
        )
        XCTAssertEqual(
            try ForgeWorkflowPresentationPolicy.rerunFailedEligibility(suite("ci", .running, jobs: [job("a", .failed)])),
            .unavailable(.stillRunning)
        )
        XCTAssertEqual(
            try ForgeWorkflowPresentationPolicy.rerunFailedEligibility(suite("ci", .failed, jobs: [job("a", .failed), job("b", .queued)])),
            .unavailable(.stillRunning),
            "A job still queued means the run has not finished"
        )
        XCTAssertEqual(
            try ForgeWorkflowPresentationPolicy.rerunFailedEligibility(suite("ci", .succeeded, jobs: [job("a", .succeeded), job("b", .skipped)])),
            .unavailable(.nothingFailed)
        )
        XCTAssertEqual(ForgeWorkflowRerunUnavailableReason.allCases.count, 4)
    }

    func testSummaryNamesTheWorkflowRunNumberAndAttempt() throws {
        XCTAssertEqual(try ForgeWorkflowPresentationPolicy.summary(suite("ci", .failed)), "CI #42 · Failed")
        XCTAssertEqual(
            try ForgeWorkflowPresentationPolicy.summary(suite("ci", .running, run: .available(details(attempt: 3)))),
            "CI #42 (attempt 3) · Running"
        )
        let denied = try suite("ci", .succeeded, run: .permissionDenied)
        XCTAssertEqual(denied.title, "GitHub Actions")
        XCTAssertEqual(ForgeWorkflowPresentationPolicy.summary(denied), "GitHub Actions · Passed")
        XCTAssertEqual(try ForgeWorkflowPresentationPolicy.summary(suite("Lint App", .skipped, isActions: false)), "Lint App · Skipped")
        XCTAssertEqual(try details().title, "Fix the build")
        XCTAssertEqual(try details().event, "pull_request")
    }
}
