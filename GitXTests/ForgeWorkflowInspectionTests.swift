import AppKit
import ForgeKit
import GitHubForgeAdapter
import XCTest

/// Workflow inspection (ADR 0015): the access policy, the cached service, the checks view and its sheet,
/// and the pull request inspector's Checks section.
@MainActor
final class ForgeWorkflowInspectionTests: XCTestCase {
    // MARK: Fixtures

    private enum WorkflowFixture {
        static let repository = try! ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            owner: "hbmartin",
            name: "gitx"
        )
        static let other = try! ForgeRepositoryIdentity(forge: repository.forge, owner: "hbmartin", name: "other")
        static let commit = try! ForgeCommitID(String(repeating: "a", count: 40))
        static let credential = try! ForgeCredentialReference(
            accountID: ForgeAccountID(forge: repository.forge, value: "octocat"),
            credentialID: ForgeCredentialID("credential"),
            generation: ForgeCredentialGeneration(1)
        )

        static func id(_ value: String) -> ForgeObjectID {
            try! ForgeObjectID(forge: repository.forge, value: value)
        }

        static func pullRequest(repository: ForgeRepositoryIdentity = repository, head: Bool = true) throws -> ForgePullRequestSummary {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let headReference = try ForgeBranchReference(repository: repository, name: ForgeRefName("feature"), commit: commit)
            let baseReference = try ForgeBranchReference(repository: repository, name: ForgeRefName("main"), commit: ForgeCommitID(String(repeating: "b", count: 40)))
            return try ForgePullRequestSummary(
                repository: repository,
                number: ForgeItemNumber(42),
                state: .open,
                isDraft: false,
                title: "Fix the build",
                author: .available(.deleted),
                head: head ? .available(ForgePullRequestHead(reference: headReference)) : .unavailable(.partialResponse),
                base: .available(baseReference),
                createdAt: date,
                updatedAt: date,
                labels: .available([]),
                checkRollup: .available(.failed),
                reviewRollup: .available(.approved)
            )
        }

        static func job(_ name: String, _ outcome: ForgeWorkflowOutcome, job: Int64? = 555, url: URL? = nil) throws -> ForgeWorkflowJob {
            let destination = try job.map { try ForgeDestination.workflowJob(repository, run: ForgeWorkflowRunID(777), job: ForgeWorkflowJobID($0)) }
            return try ForgeWorkflowJob(repository: repository, id: id("job-\(name)"), destination: destination, name: name, outcome: outcome, detailsURL: url)
        }

        static func runDetails(_ run: Int64 = 777) throws -> ForgeWorkflowRunDetails {
            try ForgeWorkflowRunDetails(destination: .workflowRun(repository, ForgeWorkflowRunID(run)), workflowName: "CI", runNumber: 42, attempt: 1)
        }

        static func suite(
            _ name: String,
            _ outcome: ForgeWorkflowOutcome,
            run: ForgeWorkflowRunSection? = nil,
            jobs: [ForgeWorkflowJob] = [],
            isActions: Bool = true,
            nextJobs: ForgePageCursor? = nil
        ) throws -> ForgeWorkflowRun {
            try ForgeWorkflowRun(
                repository: repository,
                id: id("suite-\(name)"),
                appName: isActions ? "GitHub Actions" : name,
                isActions: isActions,
                run: run ?? (isActions ? .available(runDetails()) : .notRequested),
                outcome: outcome,
                jobs: ForgeWorkflowPage(items: jobs, nextCursor: nextJobs, totalCount: nextJobs == nil ? jobs.count : jobs.count + 5)
            )
        }

        static func snapshot(_ suites: [ForgeWorkflowRun], next: ForgePageCursor? = nil, denied: Bool = false) throws -> ForgeCommitWorkflowSnapshot {
            try ForgeCommitWorkflowSnapshot(
                repository: repository,
                commit: commit,
                suites: ForgeWorkflowPage(items: suites, nextCursor: next, totalCount: suites.count + (next == nil ? 0 : 1)),
                actionsUnavailable: denied
            )
        }

        /// An unverified read, as the evaluator issues it when the credential's Actions permission is unknown.
        static var unverified: ForgeOperationCapability {
            let account = try! ForgeAccount(
                id: credential.accountID,
                login: "octocat",
                currentCredential: ForgeCredentialMetadata(reference: credential, source: .fineGrainedPersonalAccessToken)
            )
            let permissions = try! ForgePermissionEvidence(
                credential: credential,
                repository: repository,
                freshness: .current,
                grants: ForgeRepositoryPermission.allCases.map { ForgePermissionGrant(permission: $0, authority: .unknown) }
            )
            let access = ForgeRepositoryAccessEvidence(
                credential: credential,
                repository: repository,
                freshness: .current,
                status: .granted,
                role: .known(.read)
            )
            let capability = ForgeCapabilityEvaluator.capability(
                account: account,
                repository: repository,
                operation: .readWorkflowRuns,
                operationSupported: true,
                credentialAvailability: .available,
                now: Date(timeIntervalSince1970: 1),
                permissionEvidence: permissions,
                accessEvidence: access,
                promotions: ForgeCapabilityPromotionLedger()
            )
            guard case .unverifiedRead = capability else { preconditionFailure("Expected an unverified read, got \(capability)") }
            return capability
        }

        static func inspection(_ snapshot: ForgeCommitWorkflowSnapshot, access: ForgeWorkflowAccess = .granted, partial: Bool = false) -> ForgeWorkflowInspection {
            ForgeWorkflowInspection(
                pullRequest: try! ForgeItemNumber(42),
                commit: commit,
                snapshot: snapshot,
                access: access,
                permissionsURL: nil,
                isPartial: partial
            )
        }
    }

    // swift6-safety-justification: the service awaits each read in turn and tests configure the fake between reads,
    // so its state is never accessed concurrently.
    private final class FakeReader: ForgeWorkflowReading, @unchecked Sendable {
        let repository = WorkflowFixture.repository
        var capability: ForgeOperationCapability = .verified(.knownAuthority)
        var snapshots: [Result<ForgeCommitWorkflowSnapshot, Error>] = []
        var jobPages: [ForgeWorkflowPage<ForgeWorkflowJob>] = []
        var stepPage = try! ForgeWorkflowPage<ForgeWorkflowStep>(items: [])
        var recorded: [ForgeCapabilityAttemptOutcome] = []
        var reads: [(includeWorkflowRuns: Bool, after: ForgePageCursor?)] = []
        var stepReads = 0
        var beforeReturning: (@Sendable () async -> Void)?
        var permissionsURL: URL?

        func readCapability() async throws -> ForgeOperationCapability {
            capability
        }

        func record(_ outcome: ForgeCapabilityAttemptOutcome, for _: ForgeUnverifiedReadAttempt) async {
            recorded.append(outcome)
        }

        func commitWorkflowRuns(commit _: ForgeCommitID, includeWorkflowRuns: Bool, after: ForgePageCursor?) async throws -> ForgeWorkflowReadPage<ForgeCommitWorkflowSnapshot> {
            reads.append((includeWorkflowRuns, after))
            await beforeReturning?()
            let value = try snapshots.removeFirst().get()
            return ForgeWorkflowReadPage(value: value, isPartial: false, permissionsURL: permissionsURL)
        }

        func jobs(of _: ForgeWorkflowRun, after _: ForgePageCursor) async throws -> ForgeWorkflowReadPage<ForgeWorkflowPage<ForgeWorkflowJob>> {
            ForgeWorkflowReadPage(value: jobPages.removeFirst(), isPartial: true, permissionsURL: nil)
        }

        func steps(of _: ForgeWorkflowJob) async throws -> ForgeWorkflowReadPage<ForgeWorkflowPage<ForgeWorkflowStep>> {
            stepReads += 1
            return ForgeWorkflowReadPage(value: stepPage, isPartial: false, permissionsURL: nil)
        }
    }

    private final class RecordingRouter: ForgeReadDestinationRouting, ForgeMarkdownNavigationRouting {
        var browser: [ForgeDestination] = []
        var links: [ForgeMarkdownLinkTarget] = []
        func openNative(destination _: ForgeDestination) {}
        func openInBrowser(destination: ForgeDestination) {
            browser.append(destination)
        }

        func activateMarkdownLink(_ target: ForgeMarkdownLinkTarget) {
            links.append(target)
        }

        func openMarkdownLinkInBrowser(_: URL) {}
    }

    private final class PlainMarkdown: ForgeReadMarkdownRendering {
        func makeView(markdown: String, context _: ForgeMarkdownContext) -> NSView {
            NSTextField(labelWithString: markdown)
        }
    }

    private final class PlainAvatars: ForgeReadAvatarRendering {
        func makeAvatarView(for _: ForgeActor, size: NSSize) -> NSView {
            NSView(frame: NSRect(origin: .zero, size: size))
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "Timed out waiting for an observable state")
    }

    private func host(_ view: NSView, size: NSSize = NSSize(width: 560, height: 320)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: Access policy

    func testAccessPolicyAsksForRunsOnlyWhenAllowedAndLearnsFromTheAnswer() throws {
        let verified = ForgeOperationCapability.verified(.knownAuthority)
        let unverified = WorkflowFixture.unverified
        let unavailable = ForgeOperationCapability.unavailable(.missingPermission(.actions))
        XCTAssertTrue(ForgeWorkflowAccessPolicy.includesWorkflowRuns(verified))
        XCTAssertTrue(ForgeWorkflowAccessPolicy.includesWorkflowRuns(unverified))
        XCTAssertFalse(ForgeWorkflowAccessPolicy.includesWorkflowRuns(unavailable))

        let proven = try WorkflowFixture.snapshot([WorkflowFixture.suite("ci", .failed)])
        let unproven = try WorkflowFixture.snapshot([WorkflowFixture.suite("lint", .failed, isActions: false)])
        let denied = try WorkflowFixture.snapshot([WorkflowFixture.suite("ci", .failed, run: .permissionDenied)], denied: true)

        XCTAssertEqual(ForgeWorkflowAccessPolicy.access(verified, snapshot: proven), .granted)
        XCTAssertEqual(ForgeWorkflowAccessPolicy.access(unverified, snapshot: proven), .granted)
        XCTAssertEqual(ForgeWorkflowAccessPolicy.access(unverified, snapshot: unproven), .unverified)
        XCTAssertEqual(ForgeWorkflowAccessPolicy.access(unverified, snapshot: denied), .denied)
        XCTAssertEqual(ForgeWorkflowAccessPolicy.access(verified, snapshot: denied), .denied)
        XCTAssertEqual(ForgeWorkflowAccessPolicy.access(unavailable, snapshot: unproven), .denied)

        XCTAssertEqual(ForgeWorkflowAccessPolicy.outcome(unverified, snapshot: proven)?.0, .success)
        XCTAssertEqual(ForgeWorkflowAccessPolicy.outcome(unverified, snapshot: denied)?.0, .authorizationDenied)
        XCTAssertNil(ForgeWorkflowAccessPolicy.outcome(unverified, snapshot: unproven), "A commit without Actions suites proves nothing")
        XCTAssertNil(ForgeWorkflowAccessPolicy.outcome(verified, snapshot: denied), "Only unverified reads are recorded")
    }

    // MARK: Service

    func testServiceCachesPerCommitRecordsWhatAnUnverifiedReadProvedAndRefreshes() async throws {
        let reader = FakeReader()
        reader.capability = WorkflowFixture.unverified
        reader.snapshots = try [
            .success(WorkflowFixture.snapshot([WorkflowFixture.suite("ci", .failed)])),
            .success(WorkflowFixture.snapshot([WorkflowFixture.suite("ci", .succeeded)])),
        ]
        let service = ForgeWorkflowInspectionService(reader: reader)
        let pullRequest = try WorkflowFixture.pullRequest()
        XCTAssertEqual(service.repository, WorkflowFixture.repository)
        XCTAssertTrue(service.canInspect(pullRequest))
        XCTAssertNil(service.cachedInspection(for: pullRequest))

        let first = try await service.inspect(pullRequest)
        XCTAssertEqual(first.access, .granted)
        XCTAssertEqual(reader.recorded, [.success])
        XCTAssertEqual(reader.reads.map(\.includeWorkflowRuns), [true])
        let cached = try await service.inspect(pullRequest)
        XCTAssertEqual(cached, first)
        XCTAssertEqual(reader.reads.count, 1, "A cached answer is not read again")
        XCTAssertEqual(service.cachedInspection(for: pullRequest), first)

        let refreshed = try await service.inspect(pullRequest, refresh: true)
        XCTAssertEqual(refreshed.snapshot.suites.items.first?.outcome, .succeeded)
        XCTAssertEqual(reader.reads.count, 2)

        service.invalidate()
        XCTAssertNil(service.cachedInspection(for: pullRequest))
    }

    func testServiceRecordsADenialAndStopsAskingForRunsOnceTheEvidenceSaysNo() async throws {
        let reader = FakeReader()
        reader.capability = WorkflowFixture.unverified
        reader.permissionsURL = URL(string: "https://github.com/settings/installations/1")
        reader.snapshots = try [.success(WorkflowFixture.snapshot([WorkflowFixture.suite("ci", .failed, run: .permissionDenied)], denied: true))]
        let service = ForgeWorkflowInspectionService(reader: reader)
        let denied = try await service.inspect(WorkflowFixture.pullRequest())
        XCTAssertEqual(denied.access, .denied)
        XCTAssertEqual(denied.permissionsURL, reader.permissionsURL)
        XCTAssertEqual(reader.recorded, [.authorizationDenied])

        reader.capability = .unavailable(.missingPermission(.actions))
        reader.snapshots = try [.success(WorkflowFixture.snapshot([WorkflowFixture.suite("ci", .failed, run: .notRequested)]))]
        let later = try await service.inspect(WorkflowFixture.pullRequest(), refresh: true)
        XCTAssertEqual(reader.reads.last?.includeWorkflowRuns, false)
        XCTAssertEqual(later.access, .denied)
        XCTAssertEqual(reader.recorded, [.authorizationDenied], "Evidence-based answers are not recorded again")
    }

    func testServiceRefusesOtherRepositoriesUnknownHeadsAndSupersededReads() async throws {
        let reader = FakeReader()
        let service = ForgeWorkflowInspectionService(reader: reader)
        for pullRequest in try [WorkflowFixture.pullRequest(head: false), WorkflowFixture.pullRequest(repository: WorkflowFixture.other)] {
            XCTAssertFalse(service.canInspect(pullRequest))
            XCTAssertNil(service.cachedInspection(for: pullRequest))
            do {
                _ = try await service.inspect(pullRequest)
                XCTFail("Expected headUnavailable")
            } catch {
                XCTAssertEqual(error as? ForgeWorkflowInspectionError, .headUnavailable)
            }
        }

        reader.snapshots = try [.success(WorkflowFixture.snapshot([]))]
        reader.beforeReturning = { await service.invalidate() }
        do {
            _ = try await service.inspect(WorkflowFixture.pullRequest())
            XCTFail("Expected superseded")
        } catch {
            XCTAssertEqual(error as? ForgeWorkflowInspectionError, .superseded)
        }
        reader.beforeReturning = nil

        let otherCommit = try ForgeCommitWorkflowSnapshot(
            repository: WorkflowFixture.repository,
            commit: ForgeCommitID(String(repeating: "c", count: 40)),
            suites: ForgeWorkflowPage(items: []),
            actionsUnavailable: false
        )
        reader.snapshots = [.success(otherCommit)]
        do {
            _ = try await service.inspect(WorkflowFixture.pullRequest())
            XCTFail("An answer for another commit is never shown")
        } catch {
            XCTAssertEqual(error as? ForgeWorkflowInspectionError, .superseded)
        }
    }

    func testServiceMapsRateLimitsAndFailures() async throws {
        let reader = FakeReader()
        let service = ForgeWorkflowInspectionService(reader: reader)
        let retry = Date(timeIntervalSince1970: 1_800_000_000)
        let limited = GitHubResponseMetadata(
            statusCode: 403,
            rateLimit: GitHubRateLimitParser.parse(
                statusCode: 403,
                headers: [
                    "x-ratelimit-limit": "5000",
                    "x-ratelimit-remaining": "0",
                    "x-ratelimit-used": "5000",
                    "x-ratelimit-resource": "graphql",
                    "retry-after": "60",
                ],
                receivedAt: retry.addingTimeInterval(-60)
            )
        )
        reader.snapshots = [.failure(GitHubReadError.rateLimited(limited)), .failure(GitHubReadError.malformedResponse), .failure(CancellationError())]
        do {
            _ = try await service.inspect(WorkflowFixture.pullRequest())
            XCTFail("Expected a rate limit")
        } catch {
            XCTAssertEqual(error as? ForgeWorkflowInspectionError, .rateLimited(until: retry))
            XCTAssertTrue(error.localizedDescription.contains("rate limiting requests until"))
        }
        do {
            _ = try await service.inspect(WorkflowFixture.pullRequest())
            XCTFail("Expected a failure")
        } catch let ForgeWorkflowInspectionError.readFailed(message) {
            XCTAssertFalse(message.isEmpty)
        }
        do {
            _ = try await service.inspect(WorkflowFixture.pullRequest())
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(ForgeWorkflowInspectionError.rateLimited(until: nil).errorDescription, "GitHub is rate limiting requests.")
        XCTAssertNotNil(ForgeWorkflowInspectionError.headUnavailable.errorDescription)
        XCTAssertNotNil(ForgeWorkflowInspectionError.superseded.errorDescription)
    }

    func testServiceAppendsSuitesJobsAndCachesSteps() async throws {
        let reader = FakeReader()
        let suite = try WorkflowFixture.suite("ci", .failed, jobs: [WorkflowFixture.job("build", .failed)], nextJobs: ForgePageCursor("jobs-1"))
        reader.snapshots = try [
            .success(WorkflowFixture.snapshot([suite], next: ForgePageCursor("suites-1"))),
            .success(WorkflowFixture.snapshot([WorkflowFixture.suite("deploy", .succeeded)])),
        ]
        let service = ForgeWorkflowInspectionService(reader: reader)
        let first = try await service.inspect(WorkflowFixture.pullRequest())
        let more = try await service.loadMoreSuites(first)
        XCTAssertEqual(more.snapshot.suites.items.map(\.id.value), ["suite-ci", "suite-deploy"])
        XCTAssertEqual(reader.reads.last?.after?.value, "suites-1")
        let unchanged = try await service.loadMoreSuites(more)
        XCTAssertEqual(unchanged, more, "Without a cursor there is nothing more to read")

        reader.jobPages = try [ForgeWorkflowPage(items: [WorkflowFixture.job("test", .succeeded, job: 556)])]
        let grown = try await service.loadMoreJobs(of: suite, in: more)
        XCTAssertEqual(grown.snapshot.suites.items.first?.jobs.items.map(\.name), ["build", "test"])
        XCTAssertTrue(grown.isPartial)
        let noCursor = try await service.loadMoreJobs(of: XCTUnwrap(grown.snapshot.suites.items.last), in: grown)
        XCTAssertEqual(noCursor, grown)

        reader.stepPage = try ForgeWorkflowPage(items: [ForgeWorkflowStep(number: 1, name: "Set up job", outcome: .succeeded)])
        let job = try WorkflowFixture.job("build", .failed)
        let steps = try await service.steps(of: job)
        let again = try await service.steps(of: job)
        XCTAssertEqual(steps.map(\.name), ["Set up job"])
        XCTAssertEqual(again, steps)
        XCTAssertEqual(reader.stepReads, 1)

        service.invalidate()
        reader.jobPages = try [ForgeWorkflowPage(items: [])]
        do {
            _ = try await service.loadMoreJobs(of: suite, in: grown)
            XCTFail("A forgotten inspection is not extended")
        } catch {
            XCTAssertEqual(error as? ForgeWorkflowInspectionError, .superseded)
        }
    }

    func testGitHubReaderAsksTheMutationServiceRecordsInTheSharedLedgerAndFailsClosedWithoutAuthentication() async throws {
        let state = ForgeGitHubMutationStateStore()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkflowNoNetworkURLProtocol.self]
        let reader = ForgeGitHubWorkflowReader(
            adapter: GitHubReadAdapter(sessionConfiguration: configuration),
            accountID: WorkflowFixture.credential.accountID,
            repository: WorkflowFixture.repository,
            capabilities: UnavailableRepositoryPullRequestMutationService(),
            state: state
        )
        let capability = try await reader.readCapability()
        XCTAssertEqual(capability, .unavailable(.unsupportedProviderOperation))

        guard case let .unverifiedRead(attempt) = WorkflowFixture.unverified else {
            return XCTFail("Expected an unverified read")
        }
        await reader.record(.authorizationDenied, for: attempt)
        let account = try ForgeAccount(
            id: WorkflowFixture.credential.accountID,
            login: "octocat",
            currentCredential: ForgeCredentialMetadata(reference: WorkflowFixture.credential, source: .fineGrainedPersonalAccessToken)
        )
        let ledger = await state.promotionLedger(for: account)
        XCTAssertTrue(ledger.deniesRead(attempt.key), "Every window's reads share the denial")

        let suite = try WorkflowFixture.suite("ci", .failed)
        let job = try WorkflowFixture.job("build", .failed)
        let cursor = try ForgePageCursor("next")
        let reads: [() async throws -> Void] = [
            { _ = try await reader.commitWorkflowRuns(commit: WorkflowFixture.commit, includeWorkflowRuns: true, after: nil) },
            { _ = try await reader.jobs(of: suite, after: cursor) },
            { _ = try await reader.steps(of: job) },
        ]
        for read in reads {
            do {
                try await read()
                XCTFail("An unauthenticated adapter must not read")
            } catch {
                XCTAssertEqual(error as? GitHubReadError, .authenticationRequired)
            }
        }
    }

    // MARK: Presentation

    func testPresentationExplainsDegradedPartialAndEmptyAnswers() throws {
        let empty = try ForgeWorkflowChecksPresentation(WorkflowFixture.inspection(WorkflowFixture.snapshot([])))
        XCTAssertEqual(empty.note, "No checks have run on this commit.")
        XCTAssertFalse(empty.showsPermissionsButton)
        let degraded = try ForgeWorkflowChecksPresentation(WorkflowFixture.inspection(
            WorkflowFixture.snapshot([WorkflowFixture.suite("ci", .failed, run: .permissionDenied)], next: ForgePageCursor("more"), denied: true),
            access: .denied,
            partial: true
        ))
        XCTAssertTrue(degraded.showsPermissionsButton)
        XCTAssertTrue(degraded.canLoadMoreSuites)
        XCTAssertTrue(degraded.note?.contains("can’t read Actions") == true)
        XCTAssertTrue(degraded.note?.hasSuffix("GitHub left part of this answer out.") == true)
        XCTAssertNil(try ForgeWorkflowChecksPresentation(WorkflowFixture.inspection(WorkflowFixture.snapshot([WorkflowFixture.suite("ci", .succeeded)]))).note)

        let paged = try WorkflowFixture.suite("ci", .failed, jobs: [WorkflowFixture.job("build", .failed)], nextJobs: ForgePageCursor("j"))
        XCTAssertEqual(ForgeWorkflowChecksPresentation.title(paged), "CI #42 · Failed — 1 of 6 jobs")
        XCTAssertEqual(try ForgeWorkflowChecksPresentation.title(WorkflowFixture.job("build", .timedOut)), "build · Timed out")
        XCTAssertEqual(try ForgeWorkflowChecksPresentation.title(ForgeWorkflowStep(number: 3, name: "Test", outcome: .running)), "3. Test · Running")
        for outcome in ForgeWorkflowOutcome.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: ForgeWorkflowChecksPresentation.symbol(outcome).name, accessibilityDescription: nil), "\(outcome)")
        }
    }

    func testRerunOpensTheSelectedOrOnlyEligibleRunAndJobsOpenTheirPages() throws {
        let failed = try WorkflowFixture.suite("ci", .failed, jobs: [WorkflowFixture.job("build", .failed)])
        let alsoFailed = try WorkflowFixture.suite("deploy", .failed, run: .available(WorkflowFixture.runDetails(888)), jobs: [WorkflowFixture.job("ship", .failed)])
        let passed = try WorkflowFixture.suite("lint", .succeeded)
        let single = try WorkflowFixture.inspection(WorkflowFixture.snapshot([failed, passed]))
        XCTAssertEqual(ForgeWorkflowChecksPresentation.rerunDestination(selected: nil, in: single), try .workflowRun(WorkflowFixture.repository, ForgeWorkflowRunID(777)))
        let two = try WorkflowFixture.inspection(WorkflowFixture.snapshot([failed, alsoFailed]))
        XCTAssertNil(ForgeWorkflowChecksPresentation.rerunDestination(selected: nil, in: two), "With two candidates the person picks one")
        XCTAssertEqual(ForgeWorkflowChecksPresentation.rerunDestination(selected: alsoFailed, in: two), try .workflowRun(WorkflowFixture.repository, ForgeWorkflowRunID(888)))
        XCTAssertNil(ForgeWorkflowChecksPresentation.rerunDestination(selected: passed, in: two))

        let actionsJob = try WorkflowFixture.job("build", .failed)
        XCTAssertEqual(ForgeWorkflowChecksPresentation.jobTarget(actionsJob), actionsJob.destination.map(ForgeWorkflowLinkTarget.destination))
        let external = try WorkflowFixture.job("lint", .failed, job: nil, url: URL(string: "https://lint.example/run/1"))
        XCTAssertEqual(ForgeWorkflowChecksPresentation.jobTarget(external), try .url(XCTUnwrap(URL(string: "https://lint.example/run/1"))))
        XCTAssertNil(try ForgeWorkflowChecksPresentation.jobTarget(WorkflowFixture.job("mystery", .failed, job: nil)))
    }

    // MARK: View

    func testChecksViewShowsRunsJobsAndStepsAndOpensGitHubPages() throws {
        let reader = FakeReader()
        reader.stepPage = try ForgeWorkflowPage(items: [
            ForgeWorkflowStep(number: 1, name: "Set up job", outcome: .succeeded),
            ForgeWorkflowStep(number: 2, name: "Run tests", outcome: .failed),
        ])
        let failed = try WorkflowFixture.suite("ci", .failed, jobs: [WorkflowFixture.job("test", .succeeded, job: 556), WorkflowFixture.job("build", .failed)])
        let lint = try WorkflowFixture.suite("Lint App", .succeeded, jobs: [WorkflowFixture.job("lint", .succeeded, job: nil, url: URL(string: "https://lint.example/1"))], isActions: false)
        reader.snapshots = try [.success(WorkflowFixture.snapshot([lint, failed]))]
        let service = ForgeWorkflowInspectionService(reader: reader)
        let view = try ForgeWorkflowChecksView(service: service, pullRequest: WorkflowFixture.pullRequest())
        var opened: [ForgeWorkflowLinkTarget] = []
        view.openTarget = { opened.append($0) }
        let window = host(view)
        XCTAssertEqual(view.accessibilityIdentifier(), "GitX.Workflows.View")
        view.start()
        XCTAssertFalse(view.statusLabel.isHidden)
        XCTAssertEqual(view.statusLabel.stringValue, "Loading checks…")
        try attachScreenshot(of: view, named: "Workflow Checks - Loading")
        waitUntil { view.inspection != nil }

        XCTAssertEqual(view.roots.count, 2)
        XCTAssertEqual(view.outlineView.numberOfRows, 4, "The failed suite opens with its jobs, failures first")
        let firstRow = try XCTUnwrap(view.outlineView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(firstRow.textField?.stringValue, "CI #42 · Failed")
        let failedJobRow = try XCTUnwrap(view.outlineView.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(failedJobRow.textField?.stringValue, "build · Failed")
        XCTAssertTrue(view.rerunButton.isEnabled, "One eligible run needs no selection")
        XCTAssertFalse(view.viewJobButton.isEnabled)
        XCTAssertTrue(view.permissionsButton.isHidden)
        XCTAssertTrue(view.refreshButton.isEnabled)

        view.rerunFailedJobs(nil)
        XCTAssertEqual(opened, try [.destination(.workflowRun(WorkflowFixture.repository, ForgeWorkflowRunID(777)))])

        view.outlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertTrue(view.viewJobButton.isEnabled)
        view.viewJob(nil)
        XCTAssertEqual(opened.last, try .destination(.workflowJob(WorkflowFixture.repository, run: ForgeWorkflowRunID(777), job: ForgeWorkflowJobID(555))))

        let buildNode = try XCTUnwrap(view.selectedNode)
        view.outlineView.expandItem(buildNode)
        waitUntil { buildNode.children.count == 2 }
        XCTAssertEqual(view.outlineView.numberOfRows, 6)
        try attachScreenshot(of: view, named: "Workflow Checks - Runs Jobs and Steps")

        view.outlineView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertTrue(view.viewJobButton.isEnabled, "A step opens its job's page")

        let lintNode = try XCTUnwrap(view.roots.last)
        view.outlineView.expandItem(lintNode)
        let lintJobRow = view.outlineView.row(forItem: lintNode.children.first)
        view.outlineView.selectRowIndexes(IndexSet(integer: lintJobRow), byExtendingSelection: false)
        XCTAssertFalse(view.rerunButton.isEnabled, "Another app's suite has no run to rerun")
        view.viewJob(nil)
        XCTAssertEqual(opened.last, try .url(XCTUnwrap(URL(string: "https://lint.example/1"))))
        window.close()
    }

    func testChecksViewDegradesWithoutActionsAccessAndDisablesRefreshWhileRateLimited() throws {
        let reader = FakeReader()
        reader.snapshots = try [
            .success(WorkflowFixture.snapshot([WorkflowFixture.suite("ci", .failed, run: .permissionDenied, jobs: [WorkflowFixture.job("build", .failed)])], denied: true)),
            .failure(GitHubReadError.rateLimited(GitHubResponseMetadata(
                statusCode: 403,
                rateLimit: GitHubRateLimitParser.parse(
                    statusCode: 403,
                    headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000000", "x-ratelimit-resource": "graphql"],
                    receivedAt: Date(timeIntervalSince1970: 1_799_999_000)
                )
            ))),
        ]
        let service = ForgeWorkflowInspectionService(reader: reader)
        let view = try ForgeWorkflowChecksView(service: service, pullRequest: WorkflowFixture.pullRequest())
        var opened: [ForgeWorkflowLinkTarget] = []
        view.openTarget = { opened.append($0) }
        let window = host(view)
        view.start()
        waitUntil { view.inspection != nil }
        XCTAssertFalse(view.noteLabel.isHidden)
        XCTAssertTrue(view.noteLabel.stringValue.contains("can’t read Actions"))
        XCTAssertFalse(view.permissionsButton.isHidden)
        XCTAssertFalse(view.rerunButton.isEnabled, "Without the run GitX cannot say which to rerun")
        try attachScreenshot(of: view, named: "Workflow Checks - Without Actions Access")
        view.reviewPermissions(nil)
        XCTAssertEqual(opened, [.url(ForgeWorkflowChecksPresentation.fallbackPermissionsURL)])

        view.refresh(nil)
        waitUntil { view.statusLabel.stringValue.hasPrefix("Rate limited until") }
        XCTAssertFalse(view.refreshButton.isEnabled)
        XCTAssertEqual(view.refreshButton.toolTip, view.statusLabel.stringValue)
        try attachScreenshot(of: view, named: "Workflow Checks - Rate Limited")
        window.close()
    }

    func testChecksViewLoadsMoreSuitesAndJobsAndReportsFailures() throws {
        let reader = FakeReader()
        let suite = try WorkflowFixture.suite("ci", .running, jobs: [WorkflowFixture.job("build", .running)], nextJobs: ForgePageCursor("jobs"))
        reader.snapshots = try [
            .success(WorkflowFixture.snapshot([suite], next: ForgePageCursor("suites"))),
            .success(WorkflowFixture.snapshot([WorkflowFixture.suite("deploy", .queued, run: .notRequested)])),
            .failure(GitHubReadError.malformedResponse),
        ]
        reader.jobPages = try [ForgeWorkflowPage(items: [WorkflowFixture.job("test", .queued, job: 556)])]
        let service = ForgeWorkflowInspectionService(reader: reader)
        let view = try ForgeWorkflowChecksView(service: service, pullRequest: WorkflowFixture.pullRequest())
        let window = host(view)
        view.load(refresh: false)
        waitUntil { view.inspection != nil }
        XCTAssertTrue(view.loadMoreButton.isEnabled)
        XCTAssertEqual(view.loadMoreButton.title, "Load More")
        view.loadMore(nil)
        waitUntil { view.roots.count == 2 }

        let ciRow = view.outlineView.row(forItem: view.roots.first { node in
            if case let .suite(value) = node.kind {
                return value.id == suite.id
            }
            return false
        })
        view.outlineView.selectRowIndexes(IndexSet(integer: ciRow), byExtendingSelection: false)
        XCTAssertEqual(view.loadMoreButton.title, "Load More Jobs")
        view.loadMore(nil)
        waitUntil {
            view.roots.contains { node in
                guard case let .suite(value) = node.kind else { return false }
                return value.id == suite.id && value.jobs.items.count == 2
            }
        }

        view.refresh(nil)
        waitUntil { view.statusLabel.stringValue.hasPrefix("Couldn’t load checks") }
        XCTAssertTrue(view.refreshButton.isEnabled)
        window.close()
    }

    func testFailedJobsSheetHostsTheChecksAndCloses() throws {
        let reader = FakeReader()
        reader.snapshots = try [.success(WorkflowFixture.snapshot([WorkflowFixture.suite("ci", .failed, jobs: [WorkflowFixture.job("build", .failed)])]))]
        let service = ForgeWorkflowInspectionService(reader: reader)
        let sheet = try ForgeWorkflowChecksSheet(service: service, pullRequest: WorkflowFixture.pullRequest())
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        var closed = false
        sheet.present(for: parent) { closed = true }
        XCTAssertTrue(parent.attachedSheet === sheet.panel)
        XCTAssertEqual(sheet.panel.accessibilityIdentifier(), "GitX.Workflows.Sheet")
        waitUntil { sheet.checks.inspection != nil }
        try attachScreenshot(of: XCTUnwrap(sheet.panel.contentView), named: "Workflow Checks - Attention Failed Jobs Sheet")
        sheet.done(nil)
        waitUntil { closed }
        XCTAssertNil(parent.attachedSheet)
        parent.close()
    }

    // MARK: Inspector

    func testInspectorReplacesTheChecksRowWithWorkflowRunsForItsRepository() throws {
        let router = RecordingRouter()
        let controller = try ForgeReadInspectorViewController(
            markdownRenderer: PlainMarkdown(),
            avatarRenderer: PlainAvatars(),
            destinationRouter: router,
            defaultRevision: .branch(ForgeRefName("main"))
        )
        func presentation(_ pullRequest: ForgePullRequestSummary) throws -> ForgeReadInspectorPresentation {
            try ForgeReadInspectorPresentation(
                item: .pullRequest(pullRequest),
                title: pullRequest.title,
                subtitle: "Pull Request #42 • Open",
                author: nil,
                metadata: [
                    ForgeReadInspectorMetadata(title: "Author", value: "Deleted user", isUnavailable: false),
                    ForgeReadInspectorMetadata(title: "Checks", value: "build: Failed", isUnavailable: false),
                ],
                bodyMarkdown: nil,
                bodyUnavailableMessage: "No description",
                timeline: [],
                timelineUnavailableMessage: nil,
                nextTimelineCursor: nil,
                nextCheckCursor: ForgePageCursor("checks"),
                isMutationStateFresh: true,
                freshnessMessage: nil
            )
        }
        func texts() -> [String] {
            func collect(_ view: NSView) -> [String] {
                let own = (view as? NSTextField).map { [$0.stringValue] } ?? (view as? NSButton).map { [$0.title] } ?? []
                return own + view.subviews.flatMap(collect)
            }
            return collect(controller.view)
        }

        try controller.apply(presentation(WorkflowFixture.pullRequest()))
        XCTAssertNil(controller.workflowChecksView)
        XCTAssertTrue(texts().contains("build: Failed"), "Without a workflow reader the checks stay one Details row")
        XCTAssertTrue(texts().contains("Load More Checks"))

        let reader = FakeReader()
        reader.snapshots = try [.success(WorkflowFixture.snapshot([WorkflowFixture.suite("ci", .failed, jobs: [WorkflowFixture.job("build", .failed)])]))]
        controller.workflowInspector = ForgeWorkflowInspectionService(reader: reader)
        try controller.apply(presentation(WorkflowFixture.pullRequest()))
        let checks = try XCTUnwrap(controller.workflowChecksView)
        XCTAssertFalse(texts().contains("build: Failed"))
        XCTAssertFalse(texts().contains("Load More Checks"))
        waitUntil { checks.inspection != nil }
        checks.rerunFailedJobs(nil)
        XCTAssertEqual(router.browser, try [.workflowRun(WorkflowFixture.repository, ForgeWorkflowRunID(777))])
        try controller.openWorkflowTarget(.url(XCTUnwrap(URL(string: "https://lint.example/1"))))
        XCTAssertEqual(router.links.count, 1)
        try attachScreenshot(of: controller.view, named: "Workflow Checks - Pull Request Inspector")

        try controller.apply(presentation(WorkflowFixture.pullRequest(repository: WorkflowFixture.other)))
        XCTAssertNil(controller.workflowChecksView, "Another repository's pull request keeps the Details row")
    }
}

/// Fails every request, so a read that unexpectedly reaches the transport never touches the network.
// swift6-safety-justification: URLProtocol owns request delivery, and this protocol keeps no mutable state.
private final class WorkflowNoNetworkURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
