import ForgeKit
import Foundation
import GitHubForgeAdapter
import XCTest

@MainActor
// swift6-safety-justification: XCTest owns this case and every mutable assertion value is main-actor confined.
final class RepositoryForgeOverlaySessionTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testFactsPublishCachedFirstThenReplaceWithFreshRemoteValue() async throws {
        let cachedFacts = try facts(description: "Cached")
        let remoteFacts = try facts(description: "Remote")
        let cache = OverlayCacheDouble(facts: snapshot(cachedFacts, fetchedAt: now.addingTimeInterval(-120)))
        let reader = OverlayReaderDouble(
            factsMode: .success(remote(remoteFacts)),
            history: [:]
        )
        let session = makeSession(reader: reader, cache: cache)
        var observed: [RepositoryForgeOverlaySession.FactsState] = []
        let finished = expectation(description: "fresh repository facts")
        _ = session.observeFacts { state in
            observed.append(state)
            if state.snapshot?.value.description == .available("Remote") {
                finished.fulfill()
            }
        }

        session.start()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertTrue(observed.contains(.loading(previous: snapshot(
            cachedFacts,
            fetchedAt: now.addingTimeInterval(-120)
        ))))
        XCTAssertEqual(session.factsState.snapshot?.value, remoteFacts)
        XCTAssertEqual(session.currentInput.access, .account(login: "octocat"))
        XCTAssertEqual(session.currentInput.freshness, .current(fetchedAt: now))
        let factsRequestCount = await reader.factsRequestCount()
        let factsRequests = await reader.factsRemoteRequests()
        let storedFacts = await cache.storedFacts()
        XCTAssertEqual(factsRequestCount, 1)
        XCTAssertEqual(factsRequests, [RepositoryForgeOverlayRemoteRequest(reason: .repositoryOpened, cycle: 1)])
        XCTAssertEqual(storedFacts, remote(remoteFacts))
        session.invalidate()
    }

    func testOfflineRefreshKeepsCachedFactsVisibleAndMarksStatusOffline() async throws {
        let cachedFacts = try facts(description: "Cached")
        let cache = OverlayCacheDouble(facts: snapshot(cachedFacts, fetchedAt: now.addingTimeInterval(-300)))
        let reader = OverlayReaderDouble(factsMode: .offline, history: [:])
        let session = makeSession(reader: reader, cache: cache)
        let finished = expectation(description: "offline diagnostic")
        session.inputDidChange = { input in
            if input.diagnostic == .offline {
                finished.fulfill()
            }
        }

        session.start()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(session.currentInput.diagnostic, .offline)
        XCTAssertEqual(session.currentInput.freshness, .stale(cachedAt: now.addingTimeInterval(-300)))
        XCTAssertEqual(session.factsState.snapshot?.value, cachedFacts)
        XCTAssertEqual(session.factsState.snapshot?.isStale, true)
        session.invalidate()
    }

    func testHistoryOverlayLoadsOnlyAfterDemandAndCoalescesRepeatedCommitRequests() async throws {
        let overlay = try historyOverlay(checkRollup: .failed)
        let cache = OverlayCacheDouble(facts: nil)
        let reader = try OverlayReaderDouble(
            factsMode: .success(remote(facts(description: "Remote"))),
            history: [commit: .success(remote(overlay))]
        )
        let session = makeSession(reader: reader, cache: cache)
        let factsFinished = expectation(description: "facts bootstrap")
        let historyFinished = expectation(description: "history overlay")
        _ = session.observeFacts { state in
            if case .value = state {
                factsFinished.fulfill()
            }
        }
        _ = session.observeHistory { requestedCommit, state in
            if requestedCommit == self.commit, state.snapshot?.value == overlay {
                historyFinished.fulfill()
            }
        }

        session.start()
        await fulfillment(of: [factsFinished], timeout: 1)
        let requestsBeforeDemand = await reader.historyRequestCount(for: commit)
        XCTAssertEqual(requestsBeforeDemand, 0)

        session.requestHistoryOverlay(commit)
        session.requestHistoryOverlay(commit)
        await fulfillment(of: [historyFinished], timeout: 1)
        session.requestHistoryOverlay(commit)
        await Task.yield()

        let requestsAfterDemand = await reader.historyRequestCount(for: commit)
        let storedHistory = await cache.storedHistory(for: commit)
        XCTAssertEqual(requestsAfterDemand, 1)
        XCTAssertEqual(storedHistory, remote(overlay))
        session.invalidate()
    }

    func testHistoryDemandBeforeBootstrapIsReplayedAfterSessionBecomesReady() async throws {
        let overlay = try historyOverlay(checkRollup: .running)
        let cache = OverlayCacheDouble(facts: nil)
        let reader = try OverlayReaderDouble(
            factsMode: .success(remote(facts(description: "Remote"))),
            history: [commit: .success(remote(overlay))]
        )
        let session = makeSession(reader: reader, cache: cache)
        let finished = expectation(description: "pre-bootstrap History demand")
        _ = session.observeHistory { requestedCommit, state in
            if requestedCommit == self.commit, state.snapshot?.value == overlay {
                finished.fulfill()
            }
        }

        session.requestHistoryOverlay(commit)
        let requestsBeforeStart = await reader.historyRequestCount(for: commit)
        XCTAssertEqual(requestsBeforeStart, 0)
        session.start()
        await fulfillment(of: [finished], timeout: 1)

        let requestsAfterStart = await reader.historyRequestCount(for: commit)
        XCTAssertEqual(requestsAfterStart, 1)
        session.invalidate()
    }

    func testInvalidDisposableCacheDoesNotBlockFreshRepositoryFacts() async throws {
        let remoteFacts = try facts(description: "Fresh despite corrupt cache")
        let cache = OverlayCacheDouble(facts: nil, failsFactsRead: true)
        let reader = OverlayReaderDouble(factsMode: .success(remote(remoteFacts)), history: [:])
        let session = makeSession(reader: reader, cache: cache)
        let finished = expectation(description: "fresh facts after corrupt cache")
        _ = session.observeFacts { state in
            if state.snapshot?.value == remoteFacts {
                finished.fulfill()
            }
        }

        session.start()
        await fulfillment(of: [finished], timeout: 1)

        let requestCount = await reader.factsRequestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(session.factsState.snapshot?.value, remoteFacts)
        session.invalidate()
    }

    func testCredentialCooldownIsSharedAndExpiresAtTheExactDeadline() async throws {
        let registry = ForgeCredentialCooldownRegistry()
        let credential = try credentialReference()
        let deadline = now.addingTimeInterval(60)
        let changes = await registry.changes()
        var changeIterator = changes.makeAsyncIterator()
        await registry.register(ForgeCredentialCooldown(credential: credential, deadline: deadline))

        let changedCredential = await changeIterator.next()
        let activeDeadline = await registry.activeDeadline(for: credential, at: now)
        let deadlineBoundary = await registry.activeDeadline(for: credential, at: deadline)
        let expiredDeadline = await registry.activeDeadline(for: credential, at: deadline.addingTimeInterval(1))
        let retainedDeadline = await registry.retainedDeadline(for: credential)
        let waitingState = await registry.retainedState(for: credential, at: now)
        let retryPendingState = await registry.retainedState(for: credential, at: deadline)
        XCTAssertEqual(changedCredential, credential)
        XCTAssertEqual(activeDeadline, deadline)
        XCTAssertNil(deadlineBoundary)
        XCTAssertNil(expiredDeadline)
        XCTAssertEqual(retainedDeadline, deadline)
        XCTAssertEqual(waitingState, .waiting(until: deadline))
        XCTAssertEqual(retryPendingState, .retryPending(deadline: deadline))
    }

    func testAuthenticatedSchedulerAdaptsToActiveOpenAndBoundActivity() async throws {
        let reader = try OverlayReaderDouble(
            factsMode: .success(remote(facts(description: "Remote"))),
            history: [:]
        )
        let scheduler = OverlaySchedulerDouble()
        let session = makeSession(
            reader: reader,
            cache: OverlayCacheDouble(facts: nil),
            scheduler: scheduler,
            activity: .otherOpenRepository
        )
        let loaded = expectation(description: "initial facts")
        _ = session.observeFacts { state in
            if case .value = state {
                loaded.fulfill()
            }
        }

        session.start()
        await fulfillment(of: [loaded], timeout: 1)
        XCTAssertEqual(scheduler.activeIntervals, [ForgeRefreshPolicy.openRepositoryInterval])

        session.setActivity(.affectedViewActive)
        XCTAssertEqual(scheduler.activeIntervals, [ForgeRefreshPolicy.activeOverlayInterval])
        session.setActivity(.otherBoundRepository)
        XCTAssertEqual(scheduler.activeIntervals, [ForgeRefreshPolicy.boundRepositoryInterval])
        XCTAssertEqual(scheduler.cancelCount, 2)
        session.invalidate()
        XCTAssertEqual(scheduler.cancelCount, 3)
    }

    func testScheduledRefreshUsesOneCycleAndReschedules() async throws {
        let reader = try OverlayReaderDouble(
            factsMode: .success(remote(facts(description: "Remote"))),
            history: [:]
        )
        let scheduler = OverlaySchedulerDouble()
        let session = makeSession(
            reader: reader,
            cache: OverlayCacheDouble(facts: nil),
            scheduler: scheduler
        )
        session.start()
        try await waitForFactsRequests(1, reader: reader)

        scheduler.fireLatest()
        try await waitForFactsRequests(2, reader: reader)

        let requests = await reader.factsRemoteRequests()
        XCTAssertEqual(requests.map(\.reason), [.repositoryOpened, .scheduledOverlay])
        XCTAssertEqual(requests.map(\.cycle), [1, 2])
        XCTAssertEqual(scheduler.activeIntervals, [ForgeRefreshPolicy.openRepositoryInterval])
        session.invalidate()
    }

    func testSessionCoalescesOverlappingFactsRefreshesToLatestCausalReason() async throws {
        let reader = try SuspendingOverlayReaderDouble(snapshot: remote(facts(description: "Remote")))
        let session = makeSession(reader: reader, cache: OverlayCacheDouble(facts: nil))
        session.start()
        try await waitForSuspendingFactsRequests(1, reader: reader)

        session.requestRefresh(reason: .applicationActivated)
        session.requestManualRefresh()
        await Task.yield()
        let initialReasons = await reader.requests().map(\.reason)
        XCTAssertEqual(initialReasons, [.repositoryOpened])

        await reader.releaseNext()
        try await waitForSuspendingFactsRequests(2, reader: reader)
        let coalescedReasons = await reader.requests().map(\.reason)
        XCTAssertEqual(coalescedReasons, [.repositoryOpened, .manual])
        await reader.releaseNext()
        session.invalidate()
    }

    func testNetworkRestorationRefreshesOnlyAfterAnObservedOutage() async throws {
        let reader = try OverlayReaderDouble(
            factsMode: .success(remote(facts(description: "Remote"))),
            history: [:]
        )
        let network = OverlayNetworkMonitorDouble()
        let session = makeSession(
            reader: reader,
            cache: OverlayCacheDouble(facts: nil),
            networkMonitor: network
        )
        session.start()
        try await waitForFactsRequests(1, reader: reader)

        network.emit(available: true)
        await Task.yield()
        let countBeforeOutage = await reader.factsRequestCount()
        XCTAssertEqual(countBeforeOutage, 1)
        network.emit(available: false)
        network.emit(available: true)
        try await waitForFactsRequests(2, reader: reader)

        let restoredReasons = await reader.factsRemoteRequests().map(\.reason)
        XCTAssertEqual(restoredReasons, [.repositoryOpened, .networkRestored])
        session.invalidate()
        XCTAssertEqual(network.cancelCount, 1)
    }

    func testPublicSessionAllowsOnlyOpenAndManualReadsWithNoTimerOrNetworkRefresh() async throws {
        let reader = try OverlayReaderDouble(
            factsMode: .success(remote(facts(description: "Public"))),
            history: [:]
        )
        let scheduler = OverlaySchedulerDouble()
        let network = OverlayNetworkMonitorDouble()
        let session = makeSession(
            reader: reader,
            cache: OverlayCacheDouble(facts: nil),
            access: .publicAccess,
            authentication: .publicAccess,
            scheduler: scheduler,
            networkMonitor: network
        )
        session.start()
        try await waitForFactsRequests(1, reader: reader)

        session.requestRefresh(reason: .applicationActivated)
        network.emit(available: false)
        network.emit(available: true)
        await Task.yield()
        let automaticRequestCount = await reader.factsRequestCount()
        XCTAssertEqual(automaticRequestCount, 1)
        XCTAssertEqual(session.currentInput.access, .publicAccess)
        XCTAssertTrue(scheduler.activeIntervals.isEmpty)
        XCTAssertEqual(network.startCount, 0)

        session.requestManualRefresh()
        try await waitForFactsRequests(2, reader: reader)
        let explicitRequests = await reader.factsRemoteRequests()
        let explicitReasons = explicitRequests.map(\.reason)
        XCTAssertEqual(explicitReasons, [.repositoryOpened, .manual])
        XCTAssertEqual(explicitRequests.map(\.cycle), [1, 2])
        session.invalidate()
    }

    func testApplicationCoordinatorRunsActualAdaptiveOpenActiveAndBoundRefreshPaths() async throws {
        let credential = try credentialReference()
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository,
            preferredAccount: credential.accountID
        )
        let target = try ForgeRefreshTarget(
            authentication: .credential(credential),
            repository: repository
        )
        let bindingProvider = MutableForgeBindingProviderDouble(bindings: [binding])
        let clock = ForgeRefreshClockDouble()
        let recorder = ForgeApplicationRefreshRecorder()
        let coordinator = ForgeApplicationRefreshCoordinator(
            bindingProvider: bindingProvider,
            resolveTarget: { candidate in candidate == binding ? target : nil },
            backgroundRefresh: { refreshedTarget, refreshedBinding, reason in
                await recorder.recordBackground(
                    target: refreshedTarget,
                    binding: refreshedBinding,
                    reason: reason
                )
            },
            sleep: { interval in try await clock.sleep(interval: interval) }
        )

        await coordinator.start()
        try await waitForClockInterval(ForgeRefreshPolicy.boundRepositoryInterval, clock: clock)
        let boundInterval = await coordinator.interval(for: target)
        XCTAssertEqual(boundInterval, ForgeRefreshPolicy.boundRepositoryInterval)

        let optionalRegistration = await coordinator.register(
            binding: binding,
            authentication: .credential(credential),
            activity: .otherOpenRepository,
            refresh: { reason in await recorder.recordClient(reason) }
        )
        let registration = try XCTUnwrap(optionalRegistration)
        try await waitForClockInterval(ForgeRefreshPolicy.openRepositoryInterval, clock: clock)
        let openInterval = await coordinator.interval(for: target)
        XCTAssertEqual(openInterval, ForgeRefreshPolicy.openRepositoryInterval)

        await coordinator.updateActivity(.affectedViewActive, registration: registration)
        try await waitForClockInterval(ForgeRefreshPolicy.activeOverlayInterval, clock: clock)
        let activeInterval = await coordinator.interval(for: target)
        XCTAssertEqual(activeInterval, ForgeRefreshPolicy.activeOverlayInterval)
        await clock.advance(interval: ForgeRefreshPolicy.activeOverlayInterval)
        try await waitForClientRefreshCount(1, recorder: recorder)
        let clientReasons = await recorder.clientReasons()
        XCTAssertEqual(clientReasons, [.scheduledOverlay])

        await coordinator.unregister(registration)
        try await waitForClockInterval(ForgeRefreshPolicy.boundRepositoryInterval, clock: clock)
        await clock.advance(interval: ForgeRefreshPolicy.boundRepositoryInterval)
        try await waitForBackgroundRefreshCount(1, recorder: recorder)
        let background = await recorder.backgroundRefreshes()
        XCTAssertEqual(background.map(\.target), [target])
        XCTAssertEqual(background.map(\.binding), [binding])
        XCTAssertEqual(background.map(\.reason), [.scheduledOverlay])
        await coordinator.requestNetworkRestorationRefresh()
        try await waitForBackgroundRefreshCount(2, recorder: recorder)
        let restored = await recorder.backgroundRefreshes()
        XCTAssertEqual(restored.map(\.reason), [.scheduledOverlay, .networkRestored])

        bindingProvider.replaceBindings([])
        await coordinator.synchronizeBoundRepositories()
        let removedInterval = await coordinator.interval(for: target)
        XCTAssertNil(removedInterval)
        try await waitForNoClockIntervals(clock: clock)
        await coordinator.invalidate()
    }

    func testApplicationCoordinatorCoalescesOverlappingExactTargetRefreshes() async throws {
        let credential = try credentialReference()
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository,
            preferredAccount: credential.accountID
        )
        let gate = ForgeRefreshGateDouble()
        let clock = ForgeRefreshClockDouble()
        let coordinator = ForgeApplicationRefreshCoordinator(
            bindingProvider: nil,
            resolveTarget: { _ in nil },
            backgroundRefresh: { _, _, _ in },
            sleep: { interval in try await clock.sleep(interval: interval) }
        )
        await coordinator.start()
        let optionalRegistration = await coordinator.register(
            binding: binding,
            authentication: .credential(credential),
            activity: .otherOpenRepository,
            refresh: { reason in await gate.begin(reason) }
        )
        let registration = try XCTUnwrap(optionalRegistration)

        await coordinator.requestRefresh(registration: registration, reason: .applicationActivated)
        try await waitForGateStarts(1, gate: gate)
        await coordinator.requestRefresh(registration: registration, reason: .localFetchSucceeded)
        await coordinator.requestRefresh(registration: registration, reason: .localPushSucceeded)
        await Task.yield()
        let initiallyStarted = await gate.startedReasons()
        XCTAssertEqual(initiallyStarted, [.applicationActivated])

        await gate.releaseNext()
        try await waitForGateStarts(2, gate: gate)
        let coalescedReasons = await gate.startedReasons()
        XCTAssertEqual(coalescedReasons, [.applicationActivated, .localPushSucceeded])
        await gate.releaseNext()
        await coordinator.invalidate()
    }

    func testApplicationCoordinatorRejectsAnonymousRegistrationAndUnknownRequests() async throws {
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository
        )
        let coordinator = ForgeApplicationRefreshCoordinator(
            bindingProvider: nil,
            resolveTarget: { _ in nil },
            backgroundRefresh: { _, _, _ in },
            sleep: { _ in throw CancellationError() }
        )
        await coordinator.start()
        await coordinator.start()
        let registration = await coordinator.register(
            binding: binding,
            authentication: .publicAccess,
            activity: .affectedViewActive,
            refresh: { _ in XCTFail("Anonymous targets must not register for automatic refresh") }
        )
        XCTAssertNil(registration)
        let publicTarget = try ForgeRefreshTarget(
            authentication: .publicAccess,
            repository: repository
        )
        let interval = await coordinator.interval(for: publicTarget)
        XCTAssertNil(interval)
        await coordinator.requestNetworkRestorationRefresh()
        await coordinator.invalidate()
    }

    func testAnonymousHistoryReaderSharesOnePullRequestPagePerCycleAndFiltersByCommit() async throws {
        let otherCommit = try ForgeCommitID("fedcba9876543210fedcba9876543210fedcba98")
        let pullRequests = try ForgePage(items: [
            pullRequest(number: 41, commit: commit),
            pullRequest(number: 42, commit: otherCommit),
        ])
        let adapter = try AnonymousRepositoryReaderDouble(
            facts: anonymousResult(facts(description: "Public")),
            pullRequests: anonymousResult(pullRequests)
        )
        let reader = await GitHubAnonymousRepositoryForgeOverlayReader(
            repository: repository,
            adapter: adapter
        )
        let request = RepositoryForgeOverlayRemoteRequest(reason: .repositoryOpened, cycle: 7)

        async let first = reader.historyOverlay(commit: commit, request: request)
        async let second = reader.historyOverlay(commit: otherCommit, request: request)
        let (firstOverlay, secondOverlay) = try await(first, second)

        guard case let .available(firstPage) = firstOverlay.value.pullRequests,
              case let .available(secondPage) = secondOverlay.value.pullRequests
        else {
            return XCTFail("Anonymous History overlays must expose their matching public pull requests")
        }
        XCTAssertEqual(firstPage.items.map(\.number.rawValue), [41])
        XCTAssertEqual(secondPage.items.map(\.number.rawValue), [42])
        let pullRequestCount = await adapter.pullRequestCount()
        XCTAssertEqual(pullRequestCount, 1)
        XCTAssertTrue(firstOverlay.isPartial)
        XCTAssertTrue(secondOverlay.isPartial)
    }

    func testAnonymousReaderLoadsFactsStartsANewCycleAndRejectsWrongPartitions() async throws {
        let otherCommit = try ForgeCommitID("fedcba9876543210fedcba9876543210fedcba98")
        let adapter = try AnonymousRepositoryReaderDouble(
            facts: anonymousResult(facts(description: "Public facts")),
            pullRequests: anonymousResult(ForgePage(items: [pullRequest(number: 43, commit: commit)]))
        )
        let reader = await GitHubAnonymousRepositoryForgeOverlayReader(
            repository: repository,
            adapter: adapter
        )
        let firstRequest = RepositoryForgeOverlayRemoteRequest(reason: .repositoryOpened, cycle: 1)
        let factsSnapshot = try await reader.repositoryFacts(request: firstRequest)
        XCTAssertEqual(factsSnapshot.value.description, .available("Public facts"))
        XCTAssertTrue(factsSnapshot.isPartial)
        _ = try await reader.historyOverlay(commit: commit, request: firstRequest)
        _ = try await reader.historyOverlay(
            commit: otherCommit,
            request: RepositoryForgeOverlayRemoteRequest(reason: .manual, cycle: 2)
        )
        let requestCount = await adapter.pullRequestCount()
        XCTAssertEqual(requestCount, 2)

        let wrongRepository = try ForgeRepositoryIdentity(
            forge: repository.forge,
            owner: "other",
            name: "repository"
        )
        let wrongPartitionAdapter = try AnonymousRepositoryReaderDouble(
            facts: anonymousResult(facts(description: "Wrong partition"), partitionRepository: wrongRepository),
            pullRequests: anonymousResult(
                ForgePage(items: []),
                partitionRepository: wrongRepository
            )
        )
        let wrongPartitionReader = await GitHubAnonymousRepositoryForgeOverlayReader(
            repository: repository,
            adapter: wrongPartitionAdapter
        )
        await XCTAssertThrowsErrorAsync(try await wrongPartitionReader.repositoryFacts(request: firstRequest)) {
            guard let error = $0 as? ForgeSQLiteError,
                  case .mismatchedAccountForge = error
            else {
                return XCTFail("expected an account/forge partition mismatch, got \($0)")
            }
        }
        await XCTAssertThrowsErrorAsync(
            try await wrongPartitionReader.historyOverlay(commit: commit, request: firstRequest)
        ) {
            guard let error = $0 as? ForgeSQLiteError,
                  case .mismatchedAccountForge = error
            else {
                return XCTFail("expected an account/forge partition mismatch, got \($0)")
            }
        }
    }

    func testLoaderPreparesUnboundUnsupportedPublicMissingAndAuthenticatedContexts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryForgeOverlayLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "RepositoryForgeOverlayLoaderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let services = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: root,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
            keychain: OverlayKeychain(),
            cliRunner: OverlayCLIRunner()
        )
        defer { Task { await services.refreshCoordinator?.invalidate() } }
        let serviceLoader = ForgeApplicationServiceLoader { services }
        let fixedNow = now

        let unbound = await RepositoryForgeOverlayLoader(
            binding: nil,
            services: serviceLoader,
            now: { fixedNow }
        ).prepare()
        guard case .unbound = unbound else { return XCTFail("nil binding must remain unbound") }

        let gitLabRepository = try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com")),
            owner: "example",
            name: "project"
        )
        let unsupported = try await RepositoryForgeOverlayLoader(
            binding: ForgeRepositoryBinding(
                localRemoteName: "origin",
                primaryRepository: gitLabRepository
            ),
            services: serviceLoader,
            now: { fixedNow }
        ).prepare()
        guard case let .unsupported(value) = unsupported else {
            return XCTFail("non-GitHub repositories must remain browser-only")
        }
        XCTAssertEqual(value, gitLabRepository)

        let publicBinding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository
        )
        let publicLoader = RepositoryForgeOverlayLoader(
            binding: publicBinding,
            services: serviceLoader,
            now: { fixedNow }
        )
        let publicBootstrap = await publicLoader.prepare()
        guard case let .ready(value, publicContext) = publicBootstrap else {
            return XCTFail("binding without an account must use public access")
        }
        XCTAssertEqual(value, repository)
        XCTAssertEqual(publicContext.access, .publicAccess)
        XCTAssertNil(publicContext.credential)
        guard case .ready = await publicLoader.prepare() else {
            return XCTFail("prepared bootstrap must be reusable")
        }

        let missingAccount = try ForgeAccountID(forge: repository.forge, value: "missing")
        let missingBinding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository,
            preferredAccount: missingAccount
        )
        let missing = await RepositoryForgeOverlayLoader(
            binding: missingBinding,
            services: serviceLoader,
            now: { fixedNow }
        ).prepare()
        guard case let .authenticationRequired(value) = missing else {
            return XCTFail("an unavailable exact account must require authentication")
        }
        XCTAssertEqual(value, repository)

        let accountID = try ForgeAccountID(forge: repository.forge, value: "authenticated")
        _ = try await services.addAccountCoordinator.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("overlay-loader-pat"),
            kind: .fineGrained,
            token: Data("overlay-loader-token".utf8),
            expiresAt: nil
        )
        let authenticatedBinding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository,
            preferredAccount: accountID
        )
        let authenticated = await RepositoryForgeOverlayLoader(
            binding: authenticatedBinding,
            services: serviceLoader,
            now: { fixedNow }
        ).prepare()
        guard case let .ready(value, context) = authenticated else {
            return XCTFail("stored exact account must prepare authenticated reads")
        }
        XCTAssertEqual(value, repository)
        XCTAssertEqual(context.access, .account(login: "octocat"))
        XCTAssertEqual(context.credential?.accountID, accountID)

        let unavailable = await RepositoryForgeOverlayLoader(
            binding: publicBinding,
            services: ForgeApplicationServiceLoader {
                throw NSError(domain: "OverlayLoaderTests", code: 1)
            },
            now: { fixedNow }
        ).prepare()
        guard case let .unavailable(value) = unavailable else {
            return XCTFail("service startup failure must remain explicit")
        }
        XCTAssertEqual(value, repository)
    }

    func testSQLiteOverlayCacheRoundTripsFactsAndHistoryWithinTheExactPartition() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryForgeOverlayCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: directory.appendingPathComponent("forge.sqlite3"),
            recoveryDirectoryURL: directory.appendingPathComponent("recovery", isDirectory: true)
        ))
        let partition = try ForgeRepositoryPartitionKey(
            cachePartition: .publicAccess,
            repository: repository
        )
        let cache = SQLiteRepositoryForgeOverlayCache(database: database, partition: partition)
        let missingFacts = try await cache.cachedRepositoryFacts(accessedAt: now)
        let missingHistory = try await cache.cachedHistoryOverlay(commit: commit, accessedAt: now)
        XCTAssertNil(missingFacts)
        XCTAssertNil(missingHistory)

        let repositoryFacts = try facts(description: "Persisted facts")
        try await cache.putRepositoryFacts(RepositoryForgeRemoteSnapshot(
            value: repositoryFacts,
            fetchedAt: now,
            completeness: .partial(unavailableSections: [.repositoryFacts]),
            cooldownDeadline: nil
        ))
        let cachedFacts = try await cache.cachedRepositoryFacts(accessedAt: now.addingTimeInterval(1))
        let loadedFacts = try XCTUnwrap(cachedFacts)
        XCTAssertEqual(loadedFacts.value, repositoryFacts)
        XCTAssertEqual(loadedFacts.fetchedAt, now)
        XCTAssertTrue(loadedFacts.isPartial)
        XCTAssertFalse(loadedFacts.isStale)

        let overlay = try historyOverlay(checkRollup: .succeeded)
        try await cache.putHistoryOverlay(RepositoryForgeRemoteSnapshot(
            value: overlay,
            fetchedAt: now.addingTimeInterval(2),
            completeness: .complete,
            cooldownDeadline: nil
        ))
        let cachedHistory = try await cache.cachedHistoryOverlay(
            commit: commit,
            accessedAt: now.addingTimeInterval(3)
        )
        let loadedHistory = try XCTUnwrap(cachedHistory)
        XCTAssertEqual(loadedHistory.value, overlay)
        XCTAssertFalse(loadedHistory.isPartial)
        XCTAssertFalse(loadedHistory.isStale)
    }

    func testUnavailableBootstrapStatesPublishFactsHistoryStatusAndDetailsActions() async throws {
        let recovery = ForgeSQLiteRecoveryCopy(
            url: URL(fileURLWithPath: "/tmp/gitx-overlay-recovery.sqlite3"),
            createdAt: now
        )
        let unsupportedRepository = try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com")),
            owner: "example",
            name: "project"
        )
        let cases: [(
            RepositoryForgeOverlayBootstrap,
            RepositoryForgeOverlaySession.FactsState,
            ForgeReadUnavailableReason,
            ForgeStatusDiagnostic
        )] = [
            (.unbound, .unavailable(.unsupported), .unsupported, .none),
            (.unsupported(unsupportedRepository), .unavailable(.unsupported), .unsupported, .unavailable(.other)),
            (
                .authenticationRequired(repository),
                .unavailable(.authenticationRequired),
                .authenticationRequired,
                .authenticationRequired
            ),
            (
                .recoveryRequired(repository, recovery),
                .unavailable(.partialResponse),
                .partialResponse,
                .unavailable(.persistentStorageFailure)
            ),
            (
                .sessionDisabled(repository, recovery),
                .unavailable(.partialResponse),
                .partialResponse,
                .unavailable(.sessionDisabled)
            ),
            (.unavailable(repository), .unavailable(.partialResponse), .partialResponse, .unavailable(.other)),
        ]

        let fixedNow = now
        for (index, fixture) in cases.enumerated() {
            let loader = RepositoryForgeOverlayLoader(bootstrap: fixture.0, now: { fixedNow })
            var detailsActions: [ForgeStatusDetailsAction] = []
            let scheduler = OverlaySchedulerDouble()
            let network = OverlayNetworkMonitorDouble()
            let session = RepositoryForgeOverlaySession(
                repository: index == 0 ? nil : repository,
                loader: loader,
                scheduler: scheduler,
                networkMonitor: network,
                detailsHandler: { detailsActions.append($0) }
            )
            var factsObservations: [RepositoryForgeOverlaySession.FactsState] = []
            let factsToken = session.observeFacts { factsObservations.append($0) }
            session.requestHistoryOverlay(commit)
            var historyObservations: [RepositoryForgeOverlaySession.HistoryState] = []
            let historyToken = session.observeHistory { requestedCommit, state in
                if requestedCommit == self.commit {
                    historyObservations.append(state)
                }
            }
            session.setActivity(.affectedViewActive)
            session.start()
            session.start()
            for _ in 0 ..< 20 where session.factsState != fixture.1 {
                await Task.yield()
            }

            XCTAssertEqual(session.factsState, fixture.1, "bootstrap case \(index)")
            XCTAssertEqual(session.historyStates[commit], .unavailable(fixture.2), "bootstrap case \(index)")
            XCTAssertEqual(session.currentInput.diagnostic, fixture.3, "bootstrap case \(index)")
            XCTAssertEqual(factsObservations.first, .unavailable(.notRequested))
            XCTAssertEqual(historyObservations.first, .loading(previous: nil))
            XCTAssertEqual(historyObservations.last, .unavailable(fixture.2))
            XCTAssertEqual(session.recoveryCopy, [3, 4].contains(index) ? recovery : nil)
            session.showDetails(for: .authenticate)
            XCTAssertEqual(detailsActions, [.authenticate])
            let override = ForgeRepositoryStatusInput(
                repository: repository,
                access: .publicAccess,
                freshness: .notLoaded,
                diagnostic: .none
            )
            session.updateStatus(override)
            XCTAssertEqual(session.currentInput, override)
            session.removeObserver(factsToken)
            session.removeObserver(historyToken)
            session.invalidate()
            XCTAssertEqual(scheduler.activeIntervals, [])
            XCTAssertEqual(network.startCount, 0)
        }
    }

    func testTaskSchedulerRunsImmediateActionAndCancellationSuppressesDeferredAction() async {
        let scheduler = RepositoryForgeOverlayTaskScheduler()
        let immediate = expectation(description: "immediate scheduled overlay action")
        let immediateAction = scheduler.schedule(after: 0) {
            immediate.fulfill()
        }
        await fulfillment(of: [immediate], timeout: 1)
        immediateAction.cancel()

        var deferredDidRun = false
        let deferred = scheduler.schedule(after: 60) {
            deferredDidRun = true
        }
        deferred.cancel()
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        XCTAssertFalse(deferredDidRun)
    }

    func testLoaderEnforcesBudgetsStoresCooldownsAndClassifiesRateLimits() async throws {
        let fixedNow = now
        let request = RepositoryForgeOverlayRemoteRequest(reason: .manual, cycle: 1)
        let unprepared = RepositoryForgeOverlayLoader(bootstrap: .unbound, now: { fixedNow })
        await XCTAssertThrowsErrorAsync(try await unprepared.refreshRepositoryFacts(request: request)) {
            XCTAssertTrue($0 is CancellationError)
        }
        await XCTAssertThrowsErrorAsync(
            try await unprepared.refreshHistoryOverlay(commit: commit, request: request)
        ) {
            XCTAssertTrue($0 is CancellationError)
        }

        let publicContext = try RepositoryForgeOverlayContext(
            access: .publicAccess,
            authentication: .publicAccess,
            reader: OverlayReaderDouble(
                factsMode: .success(remote(facts(description: "Public"))),
                history: [commit: .success(remote(historyOverlay(checkRollup: .succeeded)))]
            ),
            cache: OverlayCacheDouble(facts: nil),
            cooldowns: ForgeCredentialCooldownRegistry()
        )
        let publicLoader = RepositoryForgeOverlayLoader(
            bootstrap: .ready(repository, publicContext),
            now: { fixedNow }
        )
        await XCTAssertThrowsErrorAsync(try await publicLoader.refreshRepositoryFacts(
            request: RepositoryForgeOverlayRemoteRequest(reason: .scheduledOverlay, cycle: 2)
        )) {
            XCTAssertEqual($0 as? GitHubAnonymousRESTError, .explicitRequestRequired)
        }
        _ = try await publicLoader.refreshRepositoryFacts(request: request)
        _ = try await publicLoader.refreshHistoryOverlay(commit: commit, request: request)

        let credential = try credentialReference()
        let registry = ForgeCredentialCooldownRegistry()
        let activeDeadline = now.addingTimeInterval(120)
        await registry.register(ForgeCredentialCooldown(credential: credential, deadline: activeDeadline))
        let authenticatedContext = try RepositoryForgeOverlayContext(
            access: .account(login: "octocat"),
            authentication: .credential(credential),
            reader: OverlayReaderDouble(
                factsMode: .success(remote(facts(description: "Authenticated"))),
                history: [:]
            ),
            cache: OverlayCacheDouble(facts: nil),
            cooldowns: registry
        )
        let limitedLoader = RepositoryForgeOverlayLoader(
            bootstrap: .ready(repository, authenticatedContext),
            now: { fixedNow }
        )
        await XCTAssertThrowsErrorAsync(try await limitedLoader.refreshRepositoryFacts(request: request)) {
            XCTAssertEqual($0 as? RepositoryForgeOverlayLoadError, .rateLimited(until: activeDeadline))
        }

        let storedDeadline = now.addingTimeInterval(240)
        let storingRegistry = ForgeCredentialCooldownRegistry()
        let storingReader = try OverlayReaderDouble(
            factsMode: .success(RepositoryForgeRemoteSnapshot(
                value: facts(description: "Cooldown response"),
                fetchedAt: now,
                completeness: .complete,
                cooldownDeadline: storedDeadline
            )),
            history: [:]
        )
        let storingContext = RepositoryForgeOverlayContext(
            access: .account(login: "octocat"),
            authentication: .credential(credential),
            reader: storingReader,
            cache: OverlayCacheDouble(facts: nil),
            cooldowns: storingRegistry
        )
        _ = try await RepositoryForgeOverlayLoader(
            bootstrap: .ready(repository, storingContext),
            now: { fixedNow }
        ).refreshRepositoryFacts(request: request)
        let registeredDeadline = await storingRegistry.activeDeadline(for: credential, at: now)
        XCTAssertEqual(registeredDeadline, storedDeadline)

        let rateMetadata = GitHubResponseMetadata(
            statusCode: 429,
            rateLimit: GitHubRateLimitParser.parse(
                statusCode: 429,
                headers: ["retry-after": "60"],
                receivedAt: now
            )
        )
        for fixture in [
            OverlayInjectedFailure.githubRateLimited(rateMetadata),
            .anonymousCooldown(now.addingTimeInterval(180)),
            .anonymousRateLimited(nil),
        ] {
            let context = RepositoryForgeOverlayContext(
                access: fixture.isAnonymous ? .publicAccess : .account(login: "octocat"),
                authentication: fixture.isAnonymous ? .publicAccess : .credential(credential),
                reader: FailingOverlayReader(failure: fixture),
                cache: OverlayCacheDouble(facts: nil),
                cooldowns: ForgeCredentialCooldownRegistry()
            )
            let loader = RepositoryForgeOverlayLoader(
                bootstrap: .ready(repository, context),
                now: { fixedNow }
            )
            await XCTAssertThrowsErrorAsync(try await loader.refreshRepositoryFacts(request: request)) {
                guard case RepositoryForgeOverlayLoadError.rateLimited = $0 else {
                    return XCTFail("expected normalized rate-limit error, got \($0)")
                }
            }
        }
    }

    func testSessionMapsEveryRemainingRefreshFailureToAnActionableDiagnostic() async throws {
        let metadata = GitHubResponseMetadata(
            statusCode: 403,
            rateLimit: GitHubRateLimitParser.parse(statusCode: 403, headers: [:], receivedAt: now)
        )
        let cases: [(OverlayInjectedFailure, ForgeStatusDiagnostic)] = [
            (.authenticationRequired, .authenticationRequired),
            (.permissionDenied(metadata), .unavailable(.missingRepositoryAccess)),
            (.transportFailure, .offline),
            (.urlFailure, .offline),
            (.anonymousReserve, .unavailable(.other)),
            (.anonymousExplicit, .unavailable(.other)),
            (.anonymousNotFound, .unavailable(.missingRepositoryAccess)),
            (.sqlite, .unavailable(.persistentStorageFailure)),
            (.other, .unavailable(.other)),
        ]

        for (index, fixture) in cases.enumerated() {
            let session = try makeSession(
                reader: FailingOverlayReader(failure: fixture.0),
                cache: OverlayCacheDouble(facts: nil),
                access: fixture.0.isAnonymous ? .publicAccess : .account(login: "octocat"),
                authentication: fixture.0.isAnonymous ? .publicAccess : .credential(credentialReference())
            )
            let diagnosticArrived = expectation(description: "failure diagnostic \(index)")
            var didObserveDiagnostic = false
            session.inputDidChange = { input in
                guard !didObserveDiagnostic, input.diagnostic == fixture.1 else { return }
                didObserveDiagnostic = true
                diagnosticArrived.fulfill()
            }
            session.start()
            await fulfillment(of: [diagnosticArrived], timeout: 1)
            XCTAssertEqual(session.currentInput.diagnostic, fixture.1, "failure case \(index)")
            session.invalidate()
        }
    }

    func testSessionRegistersWithApplicationCoordinatorAndFinishesFactsAndHistoryRefreshes() async throws {
        let credential = try credentialReference()
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository,
            preferredAccount: credential.accountID
        )
        let target = try ForgeRefreshTarget(
            authentication: .credential(credential),
            repository: repository
        )
        let coordinator = ForgeApplicationRefreshCoordinator(
            bindingProvider: nil,
            resolveTarget: { _ in nil },
            backgroundRefresh: { _, _, _ in },
            sleep: { _ in throw CancellationError() }
        )
        await coordinator.start()
        let reader = try OverlayReaderDouble(
            factsMode: .success(remote(facts(description: "Coordinated"))),
            history: [commit: .success(remote(historyOverlay(checkRollup: .running)))]
        )
        let context = RepositoryForgeOverlayContext(
            access: .account(login: "octocat"),
            authentication: .credential(credential),
            reader: reader,
            cache: OverlayCacheDouble(facts: nil),
            cooldowns: ForgeCredentialCooldownRegistry(),
            binding: binding,
            refreshCoordinator: coordinator
        )
        let fixedNow = now
        let session = RepositoryForgeOverlaySession(
            repository: repository,
            loader: RepositoryForgeOverlayLoader(
                bootstrap: .ready(repository, context),
                now: { fixedNow }
            ),
            scheduler: OverlaySchedulerDouble(),
            networkMonitor: OverlayNetworkMonitorDouble()
        )
        session.requestHistoryOverlay(commit)
        session.start()
        try await waitForFactsRequests(1, reader: reader)
        for _ in 0 ..< 100 where await coordinator.interval(for: target) == nil {
            await Task.yield()
        }
        let openInterval = await coordinator.interval(for: target)
        XCTAssertEqual(openInterval, ForgeRefreshPolicy.openRepositoryInterval)

        session.setActivity(.affectedViewActive)
        for _ in 0 ..< 100 where await coordinator.interval(for: target) != ForgeRefreshPolicy.activeOverlayInterval {
            await Task.yield()
        }
        session.requestManualRefresh()
        try await waitForFactsRequests(2, reader: reader)
        for _ in 0 ..< 100 where await reader.historyRequestCount(for: commit) < 2 {
            await Task.yield()
        }
        let historyRequestCount = await reader.historyRequestCount(for: commit)
        XCTAssertEqual(historyRequestCount, 2)

        session.invalidate()
        await coordinator.invalidate()
    }

    private func makeSession(
        reader: any RepositoryForgeOverlayReading,
        cache: any RepositoryForgeOverlayCaching,
        access: ForgeStatusAccess = .account(login: "octocat"),
        authentication: ForgeRefreshAuthentication? = nil,
        scheduler: (any RepositoryForgeOverlayScheduling)? = nil,
        networkMonitor: (any RepositoryForgeNetworkMonitoring)? = nil,
        activity: ForgeOverlayActivity = .otherOpenRepository
    ) -> RepositoryForgeOverlaySession {
        let fixedNow = now
        let resolvedAuthentication = authentication ?? .credential(try! credentialReference())
        let context = RepositoryForgeOverlayContext(
            access: access,
            authentication: resolvedAuthentication,
            reader: reader,
            cache: cache,
            cooldowns: ForgeCredentialCooldownRegistry()
        )
        let loader = RepositoryForgeOverlayLoader(
            bootstrap: .ready(repository, context),
            now: { fixedNow }
        )
        return RepositoryForgeOverlaySession(
            repository: repository,
            loader: loader,
            scheduler: scheduler ?? OverlaySchedulerDouble(),
            networkMonitor: networkMonitor ?? OverlayNetworkMonitorDouble(),
            activity: activity
        )
    }

    private func waitForFactsRequests(
        _ count: Int,
        reader: OverlayReaderDouble
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        repeat {
            if await reader.factsRequestCount() == count {
                return
            }
            await Task.yield()
        } while ContinuousClock.now < deadline
        XCTFail("Timed out waiting for \(count) Repository Facts requests")
    }

    private func waitForSuspendingFactsRequests(
        _ count: Int,
        reader: SuspendingOverlayReaderDouble
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        repeat {
            if await reader.requests().count == count {
                return
            }
            await Task.yield()
        } while ContinuousClock.now < deadline
        XCTFail("Timed out waiting for \(count) suspended Repository Facts requests")
    }

    private func waitForClockInterval(
        _ interval: TimeInterval,
        clock: ForgeRefreshClockDouble
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        repeat {
            if await clock.activeIntervals() == [interval] {
                return
            }
            await Task.yield()
        } while ContinuousClock.now < deadline
        XCTFail("Timed out waiting for Forge refresh interval \(interval)")
    }

    private func waitForNoClockIntervals(clock: ForgeRefreshClockDouble) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        repeat {
            if await clock.activeIntervals().isEmpty {
                return
            }
            await Task.yield()
        } while ContinuousClock.now < deadline
        XCTFail("Timed out waiting for Forge refresh intervals to cancel")
    }

    private func waitForClientRefreshCount(
        _ count: Int,
        recorder: ForgeApplicationRefreshRecorder
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        repeat {
            if await recorder.clientReasons().count == count {
                return
            }
            await Task.yield()
        } while ContinuousClock.now < deadline
        XCTFail("Timed out waiting for \(count) client Forge refreshes")
    }

    private func waitForBackgroundRefreshCount(
        _ count: Int,
        recorder: ForgeApplicationRefreshRecorder
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        repeat {
            if await recorder.backgroundRefreshes().count == count {
                return
            }
            await Task.yield()
        } while ContinuousClock.now < deadline
        XCTFail("Timed out waiting for \(count) bound Forge refreshes")
    }

    private func waitForGateStarts(
        _ count: Int,
        gate: ForgeRefreshGateDouble
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        repeat {
            if await gate.startedReasons().count == count {
                return
            }
            await Task.yield()
        } while ContinuousClock.now < deadline
        XCTFail("Timed out waiting for \(count) coalesced Forge refreshes")
    }

    private var repository: ForgeRepositoryIdentity {
        try! ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: try! ForgeOrigin(host: "github.com")),
            owner: "hbmartin",
            name: "gitx"
        )
    }

    private var commit: ForgeCommitID {
        try! ForgeCommitID("0123456789abcdef0123456789abcdef01234567")
    }

    private func credentialReference() throws -> ForgeCredentialReference {
        try ForgeCredentialReference(
            accountID: ForgeAccountID(forge: repository.forge, value: "node-1"),
            credentialID: ForgeCredentialID("pat-1"),
            generation: ForgeCredentialGeneration(1)
        )
    }

    private func facts(description: String) throws -> ForgeRepositoryFacts {
        try ForgeRepositoryFacts(
            repository: repository,
            defaultBranch: .available(ForgeRefName("main")),
            description: .available(description),
            topics: .available(["git"]),
            visibility: .available(.public),
            isArchived: .available(false),
            forkRelationship: .available(.standalone)
        )
    }

    private func historyOverlay(checkRollup: ForgeCheckRollup) throws -> ForgeHistoryOverlay {
        try ForgeHistoryOverlay(
            repository: repository,
            commit: commit,
            checkRollup: .available(checkRollup),
            pullRequests: .available(ForgePage(items: []))
        )
    }

    private func pullRequest(
        number: Int,
        commit: ForgeCommitID
    ) throws -> ForgePullRequestSummary {
        try ForgePullRequestSummary(
            repository: repository,
            number: ForgeItemNumber(number),
            state: .open,
            isDraft: false,
            title: "Pull request \(number)",
            author: .unavailable(.notRequested),
            head: .available(ForgePullRequestHead(reference: ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("topic-\(number)"),
                commit: commit
            ))),
            base: .available(ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("main"),
                commit: self.commit
            )),
            createdAt: now,
            updatedAt: now,
            labels: .available([]),
            checkRollup: .unavailable(.authenticationRequired),
            reviewRollup: .unavailable(.authenticationRequired)
        )
    }

    private func anonymousResult<Value: Sendable>(
        _ value: Value,
        partitionRepository: ForgeRepositoryIdentity? = nil
    ) throws -> GitHubAnonymousReadResult<Value> {
        try GitHubAnonymousReadResult(
            value: value,
            completeness: .partial,
            response: GitHubResponseMetadata(
                statusCode: 200,
                rateLimit: GitHubRateLimitParser.parse(
                    statusCode: 200,
                    headers: ["x-ratelimit-remaining": "49"],
                    receivedAt: now
                )
            ),
            partition: ForgeRepositoryPartitionKey(
                cachePartition: .publicAccess,
                repository: partitionRepository ?? repository
            ),
            fetchedAt: now
        )
    }

    private func snapshot<Value: Hashable & Sendable>(
        _ value: Value,
        fetchedAt: Date
    ) -> RepositoryForgeOverlaySnapshot<Value> {
        RepositoryForgeOverlaySnapshot(
            value: value,
            fetchedAt: fetchedAt,
            isPartial: false,
            isStale: false
        )
    }

    private func remote<Value: Hashable & Sendable>(
        _ value: Value
    ) -> RepositoryForgeRemoteSnapshot<Value> {
        RepositoryForgeRemoteSnapshot(
            value: value,
            fetchedAt: now,
            completeness: .complete,
            cooldownDeadline: nil
        )
    }
}

private actor OverlayReaderDouble: RepositoryForgeOverlayReading {
    enum FactsMode: Sendable {
        case success(RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts>)
        case offline
    }

    enum HistoryMode: Sendable {
        case success(RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay>)
        case offline
    }

    private let factsMode: FactsMode
    private let history: [ForgeCommitID: HistoryMode]
    private var factsRequests = 0
    private var historyRequests: [ForgeCommitID: Int] = [:]

    init(factsMode: FactsMode, history: [ForgeCommitID: HistoryMode]) {
        self.factsMode = factsMode
        self.history = history
    }

    private var recordedFactsRequests: [RepositoryForgeOverlayRemoteRequest] = []
    private var recordedHistoryRequests: [ForgeCommitID: [RepositoryForgeOverlayRemoteRequest]] = [:]

    func repositoryFacts(
        request: RepositoryForgeOverlayRemoteRequest
    ) async throws -> RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts> {
        factsRequests += 1
        recordedFactsRequests.append(request)
        return switch factsMode {
        case let .success(snapshot): snapshot
        case .offline: throw GitHubReadError.transportFailure
        }
    }

    func historyOverlay(
        commit: ForgeCommitID,
        request: RepositoryForgeOverlayRemoteRequest
    ) async throws -> RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay> {
        historyRequests[commit, default: 0] += 1
        recordedHistoryRequests[commit, default: []].append(request)
        return switch history[commit] ?? .offline {
        case let .success(snapshot): snapshot
        case .offline: throw GitHubReadError.transportFailure
        }
    }

    func factsRequestCount() -> Int {
        factsRequests
    }

    func factsRemoteRequests() -> [RepositoryForgeOverlayRemoteRequest] {
        recordedFactsRequests.map { $0 }
    }

    func historyRequestCount(for commit: ForgeCommitID) -> Int {
        historyRequests[commit, default: 0]
    }
}

private enum OverlayInjectedFailure: Sendable {
    case githubRateLimited(GitHubResponseMetadata)
    case authenticationRequired
    case permissionDenied(GitHubResponseMetadata)
    case transportFailure
    case urlFailure
    case anonymousReserve
    case anonymousExplicit
    case anonymousNotFound
    case anonymousCooldown(Date)
    case anonymousRateLimited(Date?)
    case sqlite
    case other

    var isAnonymous: Bool {
        switch self {
        case .anonymousReserve, .anonymousExplicit, .anonymousNotFound,
             .anonymousCooldown, .anonymousRateLimited:
            true
        default:
            false
        }
    }
}

private actor FailingOverlayReader: RepositoryForgeOverlayReading {
    private let failure: OverlayInjectedFailure

    init(failure: OverlayInjectedFailure) {
        self.failure = failure
    }

    func repositoryFacts(
        request _: RepositoryForgeOverlayRemoteRequest
    ) async throws -> RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts> {
        try throwFailure()
    }

    func historyOverlay(
        commit _: ForgeCommitID,
        request _: RepositoryForgeOverlayRemoteRequest
    ) async throws -> RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay> {
        try throwFailure()
    }

    private func throwFailure() throws -> Never {
        switch failure {
        case let .githubRateLimited(metadata):
            throw GitHubReadError.rateLimited(metadata)
        case .authenticationRequired:
            throw GitHubReadError.authenticationRequired
        case let .permissionDenied(metadata):
            throw GitHubReadError.permissionDenied(metadata)
        case .transportFailure:
            throw GitHubReadError.transportFailure
        case .urlFailure:
            throw URLError(.notConnectedToInternet)
        case .anonymousReserve:
            throw GitHubAnonymousRESTError.reserveProtected
        case .anonymousExplicit:
            throw GitHubAnonymousRESTError.explicitRequestRequired
        case .anonymousNotFound:
            throw GitHubAnonymousRESTError.notFound
        case let .anonymousCooldown(until):
            throw GitHubAnonymousRESTError.cooldown(until: until)
        case let .anonymousRateLimited(until):
            throw GitHubAnonymousRESTError.rateLimited(until: until)
        case .sqlite:
            throw ForgeSQLiteError.closed
        case .other:
            throw CocoaError(.fileReadUnknown)
        }
    }
}

private actor SuspendingOverlayReaderDouble: RepositoryForgeOverlayReading {
    private let snapshot: RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts>
    private var recordedRequests: [RepositoryForgeOverlayRemoteRequest] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(snapshot: RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts>) {
        self.snapshot = snapshot
    }

    func repositoryFacts(
        request: RepositoryForgeOverlayRemoteRequest
    ) async throws -> RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts> {
        recordedRequests.append(request)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        return snapshot
    }

    func historyOverlay(
        commit: ForgeCommitID,
        request: RepositoryForgeOverlayRemoteRequest
    ) async throws -> RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay> {
        throw CancellationError()
    }

    func requests() -> [RepositoryForgeOverlayRemoteRequest] {
        recordedRequests.map { $0 }
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor AnonymousRepositoryReaderDouble: GitHubAnonymousRepositoryReading {
    private let facts: GitHubAnonymousReadResult<ForgeRepositoryFacts>
    private let pullRequests: GitHubAnonymousReadResult<ForgePage<ForgePullRequestSummary>>
    private var pullRequestsRequested = 0

    init(
        facts: GitHubAnonymousReadResult<ForgeRepositoryFacts>,
        pullRequests: GitHubAnonymousReadResult<ForgePage<ForgePullRequestSummary>>
    ) {
        self.facts = facts
        self.pullRequests = pullRequests
    }

    func repositoryFacts(
        repository: ForgeRepositoryIdentity,
        reason: ForgeRefreshReason
    ) async throws -> GitHubAnonymousReadResult<ForgeRepositoryFacts> {
        facts
    }

    func pullRequests(
        repository: ForgeRepositoryIdentity,
        page cursor: ForgePageCursor?,
        states: Set<ForgePullRequestState>?,
        reason: ForgeRefreshReason
    ) async throws -> GitHubAnonymousReadResult<ForgePage<ForgePullRequestSummary>> {
        pullRequestsRequested += 1
        return pullRequests
    }

    func pullRequestCount() -> Int {
        pullRequestsRequested
    }
}

private actor OverlayCacheDouble: RepositoryForgeOverlayCaching {
    private enum Failure: Error, Sendable {
        case invalidDisposablePayload
    }

    private var facts: RepositoryForgeOverlaySnapshot<ForgeRepositoryFacts>?
    private var history: [ForgeCommitID: RepositoryForgeOverlaySnapshot<ForgeHistoryOverlay>] = [:]
    private var putFactsValue: RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts>?
    private var putHistoryValues: [ForgeCommitID: RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay>] = [:]
    private let failsFactsRead: Bool

    init(facts: RepositoryForgeOverlaySnapshot<ForgeRepositoryFacts>?, failsFactsRead: Bool = false) {
        self.facts = facts
        self.failsFactsRead = failsFactsRead
    }

    func cachedRepositoryFacts(accessedAt: Date) async throws -> RepositoryForgeOverlaySnapshot<ForgeRepositoryFacts>? {
        if failsFactsRead {
            throw Failure.invalidDisposablePayload
        }
        return facts
    }

    func putRepositoryFacts(_ snapshot: RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts>) async throws {
        putFactsValue = snapshot
    }

    func cachedHistoryOverlay(
        commit: ForgeCommitID,
        accessedAt: Date
    ) async throws -> RepositoryForgeOverlaySnapshot<ForgeHistoryOverlay>? {
        history[commit]
    }

    func putHistoryOverlay(_ snapshot: RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay>) async throws {
        putHistoryValues[snapshot.value.commit] = snapshot
    }

    func storedFacts() -> RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts>? {
        putFactsValue
    }

    func storedHistory(for commit: ForgeCommitID) -> RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay>? {
        putHistoryValues[commit]
    }
}

extension RepositoryForgeRemoteSnapshot: Equatable where Value: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value &&
            lhs.fetchedAt == rhs.fetchedAt &&
            lhs.completeness == rhs.completeness &&
            lhs.cooldownDeadline == rhs.cooldownDeadline
    }
}

// swift6-safety-justification: The lock serializes the loader fixture's in-memory Credential state.
private final nonisolated class OverlayKeychain: ForgeCredentialKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func data(for accountKey: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[accountKey]
    }

    func allItems() throws -> [ForgeKeychainItem] {
        lock.lock()
        defer { lock.unlock() }
        return storage.map(ForgeKeychainItem.init(accountKey:data:))
    }

    func replace(_ data: Data, for accountKey: String) throws {
        lock.lock()
        storage[accountKey] = data
        lock.unlock()
    }

    func remove(accountKey: String) throws {
        lock.lock()
        storage.removeValue(forKey: accountKey)
        lock.unlock()
    }
}

private actor OverlayCLIRunner: ForgeCLICommandRunning {
    func run(_: ForgeCLICommand) async throws -> ForgeCLICommandResult {
        throw ForgeCLIBrokerError.commandLaunchFailed
    }
}

@MainActor
private final class OverlayScheduledActionDouble: RepositoryForgeOverlayScheduledAction {
    let interval: TimeInterval
    let action: @MainActor @Sendable () -> Void
    private(set) var isCancelled = false
    private let didCancel: () -> Void

    init(
        interval: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void,
        didCancel: @escaping () -> Void
    ) {
        self.interval = interval
        self.action = action
        self.didCancel = didCancel
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        didCancel()
    }

    func fire() {
        guard !isCancelled else { return }
        isCancelled = true
        action()
    }
}

@MainActor
private final class OverlaySchedulerDouble: RepositoryForgeOverlayScheduling {
    private var scheduled: [OverlayScheduledActionDouble] = []
    private(set) var cancelCount = 0

    var activeIntervals: [TimeInterval] {
        scheduled.filter { !$0.isCancelled }.map(\.interval)
    }

    func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> any RepositoryForgeOverlayScheduledAction {
        let scheduledAction = OverlayScheduledActionDouble(
            interval: interval,
            action: action,
            didCancel: { [weak self] in self?.cancelCount += 1 }
        )
        scheduled.append(scheduledAction)
        return scheduledAction
    }

    func fireLatest() {
        scheduled.last(where: { !$0.isCancelled })?.fire()
    }
}

@MainActor
private final class OverlayNetworkMonitorDouble: RepositoryForgeNetworkMonitoring {
    private var handler: (@MainActor @Sendable (Bool) -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func start(handler: @escaping @MainActor @Sendable (Bool) -> Void) {
        startCount += 1
        self.handler = handler
    }

    func cancel() {
        guard handler != nil else { return }
        cancelCount += 1
        handler = nil
    }

    func emit(available: Bool) {
        handler?(available)
    }
}

// swift6-safety-justification: The lock serializes every read and mutation of the fixture's bindings.
private final nonisolated class MutableForgeBindingProviderDouble: ForgeRepositoryBindingProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var bindings: [ForgeRepositoryBinding]

    init(bindings: [ForgeRepositoryBinding]) {
        self.bindings = bindings
    }

    func forgeRepositoryBindings() -> [ForgeRepositoryBinding] {
        lock.lock()
        defer { lock.unlock() }
        return bindings
    }

    func replaceBindings(_ bindings: [ForgeRepositoryBinding]) {
        lock.lock()
        self.bindings = bindings
        lock.unlock()
    }
}

private actor ForgeRefreshClockDouble {
    private struct Waiter {
        let interval: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [UUID: Waiter] = [:]
    private var cancelled: Set<UUID> = []

    func sleep(interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(interval: interval, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func activeIntervals() -> [TimeInterval] {
        waiters.values.map(\.interval).sorted()
    }

    func advance(interval: TimeInterval) {
        guard let pair = waiters.first(where: { $0.value.interval == interval }) else { return }
        waiters.removeValue(forKey: pair.key)?.continuation.resume()
    }

    private func cancel(_ id: UUID) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            cancelled.insert(id)
        }
    }
}

private actor ForgeApplicationRefreshRecorder {
    struct BackgroundRefresh: Equatable {
        let target: ForgeRefreshTarget
        let binding: ForgeRepositoryBinding
        let reason: ForgeRefreshReason
    }

    private var recordedClientReasons: [ForgeRefreshReason] = []
    private var recordedBackgroundRefreshes: [BackgroundRefresh] = []

    func recordClient(_ reason: ForgeRefreshReason) {
        recordedClientReasons.append(reason)
    }

    func recordBackground(
        target: ForgeRefreshTarget,
        binding: ForgeRepositoryBinding,
        reason: ForgeRefreshReason
    ) {
        recordedBackgroundRefreshes.append(BackgroundRefresh(
            target: target,
            binding: binding,
            reason: reason
        ))
    }

    func clientReasons() -> [ForgeRefreshReason] {
        recordedClientReasons.map { $0 }
    }

    func backgroundRefreshes() -> [BackgroundRefresh] {
        recordedBackgroundRefreshes.map { $0 }
    }
}

private actor ForgeRefreshGateDouble {
    private var reasons: [ForgeRefreshReason] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func begin(_ reason: ForgeRefreshReason) async {
        reasons.append(reason)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func startedReasons() -> [ForgeRefreshReason] {
        reasons.map { $0 }
    }
}
