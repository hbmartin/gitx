import Darwin
import Synchronization
import XCTest

final class PBChildProcessOwnerTests: XCTestCase {
    // swift6-safety-justification: The lock protects every access to mutable recorded state.
    private final class CompletionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private let expectation: XCTestExpectation
        private var storedStatuses: [Int32] = []
        private var storedErrors: [NSError] = []

        init(expectation: XCTestExpectation) {
            self.expectation = expectation
        }

        var statuses: [Int32] {
            lock.lock()
            defer { lock.unlock() }
            return storedStatuses
        }

        var errors: [NSError] {
            lock.lock()
            defer { lock.unlock() }
            return storedErrors
        }

        func record(_ status: Int32, error: NSError?) {
            lock.lock()
            storedStatuses.append(status)
            if let error {
                storedErrors.append(error)
            }
            lock.unlock()
            expectation.fulfill()
        }
    }

    // swift6-safety-justification: The lock protects the clock's sequence position.
    private final class CrossedDeadlineClock: @unchecked Sendable {
        private let lock = NSLock()
        private let initialUptime = DispatchTime.now().uptimeNanoseconds
        private var reads = 0

        var terminationDeadline: DispatchTime {
            DispatchTime(uptimeNanoseconds: initialUptime + 10_000_000)
        }

        func uptimeNanoseconds() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            return initialUptime + (reads < 3 ? 0 : 20_000_000)
        }
    }

    // swift6-safety-justification: The lock protects the fake monitor's mutable flags.
    private final class FakeExitMonitor: PBChildProcessExitMonitoring, @unchecked Sendable {
        private let lock = NSLock()
        private let queue: DispatchQueue
        private let handler: @Sendable () -> Void
        private let enqueueEventOnActivation: Bool
        private var isActive = false
        private var isCancelled = false

        init(
            queue: DispatchQueue,
            enqueueEventOnActivation: Bool,
            handler: @escaping @Sendable () -> Void
        ) {
            self.queue = queue
            self.enqueueEventOnActivation = enqueueEventOnActivation
            self.handler = handler
        }

        func activate() {
            lock.lock()
            isActive = true
            lock.unlock()
            if enqueueEventOnActivation {
                queue.async(execute: handler)
            }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            lock.unlock()
        }

        func trigger() {
            lock.lock()
            let shouldTrigger = isActive && !isCancelled
            lock.unlock()
            if shouldTrigger {
                queue.async(execute: handler)
            }
        }

        func performSynchronously(_ operation: () -> Void) {
            queue.sync(execute: operation)
        }

        func notifyAfterDeadline(_ deadline: DispatchTime, expectation: XCTestExpectation) {
            queue.asyncAfter(deadline: deadline) {
                self.queue.async { expectation.fulfill() }
            }
        }
    }

    // swift6-safety-justification: The lock protects all mutable fake process-system state.
    private final class FakeProcessSystem: PBChildProcessSystem, @unchecked Sendable {
        enum Failure: Error {
            case spawn
            case observation
            case reap
            case signal
            case groupInspection
        }

        private let lock = NSLock()
        private let processIdentifier: pid_t = 4321
        private var storedEvents: [String] = []
        private var storedMonitor: FakeExitMonitor?
        private var leaderExited = false
        private var leaderExitsAfterNextRunningObservation = false
        private var members: [pid_t] = [4321]
        private var shouldFailSpawn = false
        private var shouldFailObservation = false
        private var shouldFailReap = false
        private var persistentReapError: Int32?
        private var persistentObservationError: Int32?
        private var shouldFailSignal = false
        private var nextSignalPOSIXError: Int32?
        private var shouldFailGroupInspection = false
        private var reapReady = true
        private var signalExpectation: XCTestExpectation?
        private var reapExpectation: XCTestExpectation?
        private var remainingExpectedReaps = 0
        var enqueueExitEventOnActivation = false
        var leaderExitsOnTermination = false

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            // Assertions may iterate after the lock is released while probes append.
            // Materialize their snapshot under the lock instead of sharing array storage.
            return storedEvents.map { $0 }
        }

        func setLeaderExited(_ exited: Bool) {
            lock.lock()
            leaderExited = exited
            lock.unlock()
        }

        func setProcessGroupMembers(_ processIdentifiers: [pid_t]) {
            lock.lock()
            members = processIdentifiers
            lock.unlock()
        }

        func exitAfterNextRunningObservation() {
            lock.lock()
            leaderExitsAfterNextRunningObservation = true
            lock.unlock()
        }

        func performOnMonitorQueue(_ operation: () -> Void) {
            lock.lock()
            let monitor = storedMonitor
            lock.unlock()
            guard let monitor else { preconditionFailure("Launch must install the exit monitor first") }
            monitor.performSynchronously(operation)
        }

        func expectMonitorQueueAfterDeadline(_ deadline: DispatchTime, expectation: XCTestExpectation) {
            lock.lock()
            let monitor = storedMonitor
            lock.unlock()
            guard let monitor else { preconditionFailure("Launch must install the exit monitor first") }
            monitor.notifyAfterDeadline(deadline, expectation: expectation)
        }

        func failNextSpawn() {
            lock.lock()
            shouldFailSpawn = true
            lock.unlock()
        }

        func failNextSignal() {
            lock.lock()
            shouldFailSignal = true
            lock.unlock()
        }

        func failNextSignal(withPOSIXError code: Int32) {
            lock.lock()
            nextSignalPOSIXError = code
            lock.unlock()
        }

        func failGroupInspection() {
            lock.lock()
            shouldFailGroupInspection = true
            lock.unlock()
        }

        func failNextObservation() {
            lock.lock()
            shouldFailObservation = true
            lock.unlock()
        }

        func failNextReap() {
            lock.lock()
            shouldFailReap = true
            lock.unlock()
        }

        func failEveryReap(withPOSIXError code: Int32) {
            lock.lock()
            persistentReapError = code
            lock.unlock()
        }

        func failEveryObservation(withPOSIXError code: Int32) {
            lock.lock()
            persistentObservationError = code
            lock.unlock()
        }

        func setReapReady(_ ready: Bool) {
            lock.lock()
            reapReady = ready
            lock.unlock()
        }

        func expectSignal(_ expectation: XCTestExpectation) {
            lock.lock()
            signalExpectation = expectation
            lock.unlock()
        }

        func expectReap(_ expectation: XCTestExpectation) {
            lock.lock()
            reapExpectation = expectation
            remainingExpectedReaps = expectation.expectedFulfillmentCount
            lock.unlock()
        }

        func triggerExitMonitor() {
            lock.lock()
            let monitor = storedMonitor
            lock.unlock()
            monitor?.trigger()
        }

        func spawn(configuration: PBChildProcessConfiguration) throws -> pid_t {
            lock.lock()
            defer { lock.unlock() }
            storedEvents.append("spawn")
            if shouldFailSpawn {
                shouldFailSpawn = false
                throw Failure.spawn
            }
            return processIdentifier
        }

        func makeExitMonitor(
            processIdentifier: pid_t,
            queue: DispatchQueue,
            handler: @escaping @Sendable () -> Void
        ) -> any PBChildProcessExitMonitoring {
            let monitor = FakeExitMonitor(
                queue: queue,
                enqueueEventOnActivation: enqueueExitEventOnActivation,
                handler: handler
            )
            lock.lock()
            storedMonitor = monitor
            storedEvents.append("monitor")
            lock.unlock()
            return monitor
        }

        func exitStateWithoutReaping(processIdentifier: pid_t) throws -> PBChildProcessExitState {
            lock.lock()
            defer { lock.unlock() }
            storedEvents.append("observe")
            if let persistentObservationError {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(persistentObservationError))
            }
            if shouldFailObservation {
                shouldFailObservation = false
                throw Failure.observation
            }
            let result: PBChildProcessExitState = leaderExited ? .terminal : .running
            if result == .running, leaderExitsAfterNextRunningObservation {
                leaderExitsAfterNextRunningObservation = false
                leaderExited = true
            }
            return result
        }

        func reapIfExited(processIdentifier: pid_t) throws -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            storedEvents.append("reap")
            if remainingExpectedReaps > 0 {
                remainingExpectedReaps -= 1
                reapExpectation?.fulfill()
            }
            if let persistentReapError {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(persistentReapError))
            }
            if shouldFailReap {
                shouldFailReap = false
                throw Failure.reap
            }
            return reapReady ? 0 : nil
        }

        func send(signal: Int32, toProcessGroup processGroup: pid_t) throws {
            lock.lock()
            storedEvents.append("signal:\(signal)")
            if signal == SIGTERM, leaderExitsOnTermination {
                leaderExited = true
            }
            if signal == SIGKILL {
                leaderExited = true
                members = [processIdentifier]
            }
            let expectation = signalExpectation
            let shouldFail = shouldFailSignal
            shouldFailSignal = false
            let posixError = nextSignalPOSIXError
            nextSignalPOSIXError = nil
            lock.unlock()
            expectation?.fulfill()
            if let posixError {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(posixError))
            }
            if shouldFail {
                throw Failure.signal
            }
        }

        func processGroupMembers(processGroup: pid_t) throws -> [pid_t] {
            lock.lock()
            defer { lock.unlock() }
            storedEvents.append("members")
            if shouldFailGroupInspection {
                throw Failure.groupInspection
            }
            return members
        }
    }

    private func configuration() -> PBChildProcessConfiguration {
        PBChildProcessConfiguration(
            launchPath: "/usr/bin/true",
            arguments: [],
            environment: [:],
            workingDirectory: nil,
            standardInputFileDescriptor: nil,
            standardOutputFileDescriptor: -1
        )
    }

    func testTerminationScheduleOnlyMovesDeadlinesEarlier() {
        var schedule = PBChildProcessTerminationSchedule()
        schedule.mergeRequest(
            now: 100,
            gracePeriod: 10,
            forceKillDelay: 20,
            terminationWasSent: false
        )
        XCTAssertEqual(schedule.terminationDeadline, 10_000_000_100)
        XCTAssertEqual(schedule.forceKillDeadline, 30_000_000_100)

        schedule.mergeRequest(
            now: 200,
            gracePeriod: 40,
            forceKillDelay: nil,
            terminationWasSent: false
        )
        XCTAssertEqual(schedule.terminationDeadline, 10_000_000_100)
        XCTAssertEqual(schedule.forceKillDeadline, 30_000_000_100)

        schedule.mergeRequest(
            now: 300,
            gracePeriod: 0,
            forceKillDelay: 1,
            terminationWasSent: false
        )
        XCTAssertEqual(schedule.terminationDeadline, 300)
        XCTAssertEqual(schedule.forceKillDeadline, 1_000_000_300)

        schedule.mergeRequest(
            now: 400,
            gracePeriod: 0,
            forceKillDelay: nil,
            terminationWasSent: true
        )
        XCTAssertEqual(schedule.terminationDeadline, 300)
        XCTAssertEqual(schedule.forceKillDeadline, 1_000_000_300)
    }

    func testFastExitDuringMonitorRegistrationIsReapedExactlyOnce() throws {
        let system = FakeProcessSystem()
        system.setLeaderExited(true)
        system.enqueueExitEventOnActivation = true
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "leader reaped")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        wait(for: [completed], timeout: 1)
        system.triggerExitMonitor()

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertEqual(system.events.filter { $0 == "reap" }, ["reap"])
    }

    func testRetainedFastExitWaitsForAnIdempotentLeaseRelease() throws {
        let system = FakeProcessSystem()
        system.setLeaderExited(true)
        system.enqueueExitEventOnActivation = true
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "retained leader reaped after pipe drain")
        completed.assertForOverFulfill = true
        let recorder = CompletionRecorder(expectation: completed)

        let observed = expectation(description: "leader exit observed while its lease remains held")
        observed.assertForOverFulfill = true
        try owner.launch(configuration: configuration(), retainLeaderUntilReleased: true, leaderExitHandler: { observed.fulfill() }) {
            recorder.record($0, error: $1)
        }
        wait(for: [observed], timeout: 1)
        XCTAssertTrue(recorder.statuses.isEmpty)
        XCTAssertFalse(system.events.contains("reap"))

        owner.releaseLeaderRetention()
        owner.releaseLeaderRetention()
        wait(for: [completed], timeout: 1)
        system.triggerExitMonitor()

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertEqual(system.events.filter { $0 == "reap" }, ["reap"])
    }

    func testLeaseReleasedBeforeExitRestoresOrdinaryCompletion() throws {
        let system = FakeProcessSystem()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "leader exited after early pipe EOF")
        let recorder = CompletionRecorder(expectation: completed)
        owner.releaseLeaderRetention()
        try owner.launch(configuration: configuration(), retainLeaderUntilReleased: true) {
            recorder.record($0, error: $1)
        }

        owner.releaseLeaderRetention()
        owner.releaseLeaderRetention()
        XCTAssertTrue(recorder.statuses.isEmpty)
        system.setLeaderExited(true)
        system.triggerExitMonitor()
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertFalse(system.events.contains { $0.hasPrefix("signal:") })
    }

    func testReleasingRetainedExitedLeaderStillCompletesDescendantEscalation() throws {
        let system = FakeProcessSystem()
        system.setLeaderExited(true)
        system.setProcessGroupMembers([4321, 4322])
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "descendant killed before retained leader reaped")
        let recorder = CompletionRecorder(expectation: completed)
        try owner.launch(configuration: configuration(), retainLeaderUntilReleased: true) {
            recorder.record($0, error: $1)
        }

        XCTAssertTrue(owner.requestTermination(gracePeriod: 0, forceKillDelay: 0.03))
        owner.releaseLeaderRetention()
        wait(for: [completed], timeout: 1)

        let events = system.events
        let termIndex = try XCTUnwrap(events.firstIndex(of: "signal:\(SIGTERM)"))
        let killIndex = try XCTUnwrap(events.firstIndex(of: "signal:\(SIGKILL)"))
        let reapIndex = try XCTUnwrap(events.firstIndex(of: "reap"))
        XCTAssertLessThan(termIndex, killIndex)
        XCTAssertLessThan(killIndex, reapIndex)
        XCTAssertEqual(recorder.statuses, [0])
    }

    func testRetainedLiveLeaderReceivesImmediateForceKillAfterLeaseRelease() throws {
        let system = FakeProcessSystem()
        system.setProcessGroupMembers([4321, 4322])
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "output-limit group killed")
        let recorder = CompletionRecorder(expectation: completed)
        try owner.launch(configuration: configuration(), retainLeaderUntilReleased: true) {
            recorder.record($0, error: $1)
        }

        XCTAssertTrue(owner.requestTermination(gracePeriod: 0, forceKillDelay: 0))
        XCTAssertTrue(recorder.statuses.isEmpty)
        owner.releaseLeaderRetention()
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertEqual(system.events.filter { $0.hasPrefix("signal:") }, ["signal:\(SIGTERM)", "signal:\(SIGKILL)"])
    }

    func testDeadlineCrossedDuringTimerSchedulingSendsTermBeforeKillAndReapsOnceAfterLeaseRelease() throws {
        let system = FakeProcessSystem()
        system.setProcessGroupMembers([4321, 4322])
        let clock = CrossedDeadlineClock()
        let owner = PBChildProcessOwner(
            system: system, queueLabel: #function, uptimeNanoseconds: { clock.uptimeNanoseconds() }
        )
        let completed = expectation(description: "crossed-deadline leader reaped after lease release")
        completed.assertForOverFulfill = true
        let recorder = CompletionRecorder(expectation: completed)
        try owner.launch(configuration: configuration(), retainLeaderUntilReleased: true) {
            recorder.record($0, error: $1)
        }

        XCTAssertTrue(owner.requestTermination(gracePeriod: 0.01, forceKillDelay: 0))
        XCTAssertEqual(system.events.filter { $0.hasPrefix("signal:") }, ["signal:\(SIGTERM)", "signal:\(SIGKILL)"])
        XCTAssertTrue(recorder.statuses.isEmpty)
        XCTAssertFalse(system.events.contains("reap"))

        owner.releaseLeaderRetention()
        wait(for: [completed], timeout: 1)
        let staleTimerDrained = expectation(description: "serial queue passed the stale termination deadline")
        system.expectMonitorQueueAfterDeadline(clock.terminationDeadline, expectation: staleTimerDrained)
        wait(for: [staleTimerDrained], timeout: 1)

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertTrue(recorder.errors.isEmpty)
        XCTAssertEqual(system.events.filter { $0 == "reap" }, ["reap"])
        XCTAssertEqual(system.events.filter { $0.hasPrefix("signal:") }, ["signal:\(SIGTERM)", "signal:\(SIGKILL)"])
        XCTAssertFalse(owner.requestTermination(gracePeriod: 0, forceKillDelay: 0))
    }

    func testRetainedExitedLeaderSkipsForceKillWhenTheGroupHasNoDescendants() throws {
        let system = FakeProcessSystem()
        system.setLeaderExited(true)
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "retained terminal group no longer needs escalation")
        completed.assertForOverFulfill = true
        let recorder = CompletionRecorder(expectation: completed)
        try owner.launch(configuration: configuration(), retainLeaderUntilReleased: true) {
            recorder.record($0, error: $1)
        }

        XCTAssertTrue(owner.requestTermination(gracePeriod: 0, forceKillDelay: 0))
        wait(for: [completed], timeout: 1)
        owner.releaseLeaderRetention()
        owner.releaseLeaderRetention()

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertTrue(recorder.errors.isEmpty)
        XCTAssertEqual(system.events.filter { $0.hasPrefix("signal:") }, ["signal:\(SIGTERM)"])
        XCTAssertEqual(system.events.filter { $0 == "reap" }, ["reap"])
    }

    func testRetainedObservationFailureKillsTheGroupBeforeCompletingWithTheOriginalError() throws {
        let system = FakeProcessSystem()
        system.setProcessGroupMembers([4321, 4322])
        system.failNextObservation()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "observation failure cleaned up the retained group")
        completed.assertForOverFulfill = true
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration(), retainLeaderUntilReleased: true) {
            recorder.record($0, error: $1)
        }
        wait(for: [completed], timeout: 1)
        owner.releaseLeaderRetention()
        system.triggerExitMonitor()

        XCTAssertEqual(system.events.filter { $0.hasPrefix("signal:") }, ["signal:\(SIGTERM)", "signal:\(SIGKILL)"])
        XCTAssertEqual(system.events.filter { $0 == "reap" }, ["reap"])
        XCTAssertEqual(recorder.errors.count, 1)
        let originalError = FakeProcessSystem.Failure.observation as NSError
        XCTAssertEqual(recorder.errors.first?.domain, originalError.domain)
        XCTAssertEqual(recorder.errors.first?.code, originalError.code)
        XCTAssertEqual(recorder.statuses.count, 1)
    }

    func testRetainedReapFailureRetriesAfterKillingDescendantsAndPreservesTheOriginalError() throws {
        let system = FakeProcessSystem()
        system.setLeaderExited(true)
        system.setProcessGroupMembers([4321, 4322])
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "reap failure cleaned up the retained group")
        completed.assertForOverFulfill = true
        let recorder = CompletionRecorder(expectation: completed)
        try owner.launch(configuration: configuration(), retainLeaderUntilReleased: true) {
            recorder.record($0, error: $1)
        }
        system.failNextReap()

        owner.releaseLeaderRetention()
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(system.events.filter { $0.hasPrefix("signal:") }, ["signal:\(SIGTERM)", "signal:\(SIGKILL)"])
        XCTAssertGreaterThanOrEqual(system.events.filter { $0 == "reap" }.count, 2)
        XCTAssertEqual(recorder.errors.count, 1)
        let originalError = FakeProcessSystem.Failure.reap as NSError
        XCTAssertEqual(recorder.errors.first?.domain, originalError.domain)
        XCTAssertEqual(recorder.errors.first?.code, originalError.code)
        XCTAssertEqual(recorder.statuses.count, 1)
    }

    func testPermanentReapFailureStopsCleanupWithinABoundedTime() throws {
        let system = FakeProcessSystem()
        system.setLeaderExited(true)
        system.setProcessGroupMembers([4321, 4322])
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "permanent reap failure reported exactly once")
        completed.assertForOverFulfill = true
        let recorder = CompletionRecorder(expectation: completed)
        try owner.launch(configuration: configuration(), retainLeaderUntilReleased: true) {
            recorder.record($0, error: $1)
        }
        system.failEveryReap(withPOSIXError: EIO)

        owner.releaseLeaderRetention()
        wait(for: [completed], timeout: 2)
        owner.releaseLeaderRetention()
        system.triggerExitMonitor()

        XCTAssertEqual(system.events.filter { $0.hasPrefix("signal:") }, ["signal:\(SIGTERM)", "signal:\(SIGKILL)"])
        XCTAssertGreaterThan(system.events.filter { $0 == "reap" }.count, 1)
        XCTAssertEqual(recorder.errors.first?.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(recorder.errors.first?.code, Int(EIO))
        XCTAssertEqual(recorder.statuses.count, 1)
    }

    func testQueuedOrdinaryReapRetryCannotEraseASupervisionError() throws {
        let system = FakeProcessSystem()
        system.setLeaderExited(true)
        system.setReapReady(false)
        let reapedTwice = expectation(description: "ordinary reap and cleanup reap both attempted")
        reapedTwice.expectedFulfillmentCount = 2
        system.expectReap(reapedTwice)
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "queued retry preserves the supervision error")
        let recorder = CompletionRecorder(expectation: completed)
        try owner.launch(configuration: configuration(), retainLeaderUntilReleased: true) {
            recorder.record($0, error: $1)
        }
        owner.releaseLeaderRetention()
        system.failNextObservation()
        system.triggerExitMonitor()
        wait(for: [reapedTwice], timeout: 1)

        system.setReapReady(true)
        wait(for: [completed], timeout: 1)

        let originalError = FakeProcessSystem.Failure.observation as NSError
        XCTAssertEqual(recorder.errors.first?.domain, originalError.domain)
        XCTAssertEqual(recorder.errors.first?.code, originalError.code)
        XCTAssertEqual(recorder.statuses.count, 1)
    }

    func testLostChildOwnershipNeverSignalsAReusedProcessGroup() throws {
        let system = FakeProcessSystem()
        system.failEveryObservation(withPOSIXError: ECHILD)
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "lost child ownership reported")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration(), retainLeaderUntilReleased: true) {
            recorder.record($0, error: $1)
        }
        wait(for: [completed], timeout: 1)
        owner.releaseLeaderRetention()

        XCTAssertFalse(system.events.contains { $0.hasPrefix("signal:") })
        XCTAssertEqual(recorder.errors.first?.code, Int(ECHILD))
        XCTAssertEqual(recorder.statuses.count, 1)
    }

    func testSupervisionCleanupPreservesTheOriginalErrorWhenTheChildIsAlreadyReaped() throws {
        let system = FakeProcessSystem()
        system.failNextObservation()
        system.failEveryReap(withPOSIXError: ECHILD)
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "cleanup reported the original observation error")
        completed.assertForOverFulfill = true
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration(), retainLeaderUntilReleased: true) {
            recorder.record($0, error: $1)
        }
        wait(for: [completed], timeout: 1)
        owner.releaseLeaderRetention()
        system.triggerExitMonitor()

        let originalError = FakeProcessSystem.Failure.observation as NSError
        XCTAssertEqual(recorder.errors.first?.domain, originalError.domain)
        XCTAssertEqual(recorder.errors.first?.code, originalError.code)
        XCTAssertEqual(recorder.statuses.count, 1)
        XCTAssertEqual(system.events.filter { $0.hasPrefix("signal:") }, ["signal:\(SIGTERM)", "signal:\(SIGKILL)"])
        XCTAssertEqual(system.events.filter { $0 == "reap" }.count, 1)
    }

    func testCompletionCanReleaseTheLeaseAndRequestTerminationWithoutDeadlock() throws {
        let system = FakeProcessSystem()
        system.setLeaderExited(true)
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "completion safely called the owner's lifecycle APIs")
        completed.assertForOverFulfill = true
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration(), retainLeaderUntilReleased: true) { status, error in
            owner.releaseLeaderRetention()
            XCTAssertFalse(owner.requestTermination(gracePeriod: 0, forceKillDelay: 0))
            recorder.record(status, error: error)
        }
        owner.releaseLeaderRetention()
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertTrue(recorder.errors.isEmpty)
        XCTAssertEqual(system.events.filter { $0 == "reap" }.count, 1)
        XCTAssertFalse(system.events.contains { $0.hasPrefix("signal:") })
    }

    func testLiveChildReceivesOnlyTheOneShotRegistrationProbeWhileExitMonitorIsQuiet() throws {
        let system = FakeProcessSystem()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "exit monitor observed the leader exit")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        let unexpectedlyCompleted = expectation(description: "live child stayed running")
        unexpectedlyCompleted.isInverted = true
        wait(for: [unexpectedlyCompleted], timeout: 0.15)
        XCTAssertEqual(system.events.filter { $0 == "observe" }.count, 2)

        system.setLeaderExited(true)
        system.triggerExitMonitor()
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertEqual(system.events.filter { $0 == "reap" }, ["reap"])
    }

    func testOneShotRegistrationProbeReapsAnExitMissedByTheMonitor() throws {
        let system = FakeProcessSystem()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "deferred registration probe observed the leader exit")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        system.setLeaderExited(true)
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertEqual(system.events.filter { $0 == "observe" }.count, 2)
        XCTAssertEqual(system.events.filter { $0 == "reap" }, ["reap"])
    }

    func testTerminalObservationRetriesAReapThatIsNotReadyWithoutBlocking() throws {
        let system = FakeProcessSystem()
        system.setLeaderExited(true)
        system.setReapReady(false)
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "leader reaped after nonblocking retry")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        system.setReapReady(true)
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertTrue(recorder.errors.isEmpty)
        XCTAssertGreaterThanOrEqual(system.events.filter { $0 == "reap" }.count, 2)
    }

    func testObservationFailureCompletesExactlyOnceWithAnError() throws {
        let system = FakeProcessSystem()
        system.failNextObservation()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "observation failure completed")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        wait(for: [completed], timeout: 1)
        system.triggerExitMonitor()

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertEqual(recorder.errors.count, 1)
    }

    func testReapFailureCompletesExactlyOnceWithAnError() throws {
        let system = FakeProcessSystem()
        system.setLeaderExited(true)
        system.failNextReap()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "reap failure completed")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        wait(for: [completed], timeout: 1)
        system.triggerExitMonitor()

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertEqual(recorder.errors.count, 1)
    }

    func testSecondLaunchIsRejectedAfterOwnerLeavesIdleState() throws {
        let system = FakeProcessSystem()
        system.setLeaderExited(true)
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "first child reaped")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        wait(for: [completed], timeout: 1)

        XCTAssertThrowsError(try owner.launch(configuration: configuration()) { _, _ in }) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(error.code, Int(EALREADY))
        }
    }

    func testSignalFailureDoesNotPreventLaterExitObservation() throws {
        let system = FakeProcessSystem()
        system.failNextSignal()
        let signalAttempted = expectation(description: "termination signal attempted")
        system.expectSignal(signalAttempted)
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "leader reaped after signal failure")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        owner.requestTermination(gracePeriod: 0, forceKillDelay: nil)
        wait(for: [signalAttempted], timeout: 1)
        system.setLeaderExited(true)
        system.triggerExitMonitor()
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(system.events.filter { $0 == "signal:\(SIGTERM)" }, ["signal:\(SIGTERM)"])
        XCTAssertEqual(system.events.filter { $0 == "reap" }, ["reap"])
    }

    func testDisappearingProcessGroupIsBenignDuringTermination() throws {
        let system = FakeProcessSystem()
        system.failNextSignal(withPOSIXError: ESRCH)
        let signalAttempted = expectation(description: "termination signal attempted")
        system.expectSignal(signalAttempted)
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "leader eventually reaped")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        XCTAssertTrue(owner.requestTermination(gracePeriod: 0, forceKillDelay: nil))
        wait(for: [signalAttempted], timeout: 1)
        system.setLeaderExited(true)
        system.triggerExitMonitor()
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(recorder.statuses.count, 1)
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testPermissionDeniedWhileLeaderIsLiveStillAllowsLaterExitCompletion() throws {
        let system = FakeProcessSystem()
        system.failNextSignal(withPOSIXError: EPERM)
        let signalAttempted = expectation(description: "permission-denied termination attempted")
        system.expectSignal(signalAttempted)
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "leader reaped after permission-denied signal")
        let recorder = CompletionRecorder(expectation: completed)
        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        XCTAssertTrue(owner.requestTermination(gracePeriod: 0, forceKillDelay: nil))
        wait(for: [signalAttempted], timeout: 1)
        system.setLeaderExited(true)
        system.triggerExitMonitor()
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(recorder.statuses.count, 1)
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testPermissionDeniedAfterLeaderExitIsBenignDuringDescendantCleanup() throws {
        let system = FakeProcessSystem()
        system.setProcessGroupMembers([4321, 4322])
        system.failNextSignal(withPOSIXError: EPERM)
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "descendant cleanup after permission-denied signal")
        let recorder = CompletionRecorder(expectation: completed)
        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        XCTAssertTrue(owner.requestTermination(gracePeriod: 0.03, forceKillDelay: 0.03))
        system.setLeaderExited(true)
        system.triggerExitMonitor()
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(recorder.statuses.count, 1)
        XCTAssertTrue(recorder.errors.isEmpty)
        XCTAssertTrue(system.events.contains("signal:\(SIGKILL)"))
    }

    func testImmediateTerminationAttemptsSIGTERMBeforeReturning() throws {
        let system = FakeProcessSystem()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)

        try owner.launch(configuration: configuration()) { _, _ in }
        XCTAssertTrue(owner.requestTermination(gracePeriod: 0, forceKillDelay: nil))

        XCTAssertEqual(system.events.filter { $0 == "signal:\(SIGTERM)" }, ["signal:\(SIGTERM)"])
    }

    func testTimeoutRequestDoesNotOverrideAChildThatAlreadyExited() throws {
        let system = FakeProcessSystem()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "already exited child completed")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        system.setLeaderExited(true)
        let didRequestTermination = owner.requestTermination(gracePeriod: 0, forceKillDelay: 0.1)
        wait(for: [completed], timeout: 1)

        XCTAssertFalse(didRequestTermination)
        XCTAssertFalse(system.events.contains { $0.hasPrefix("signal:") })
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testTimeoutRequestDoesNotOverrideExitedLeaderWithDescendants() throws {
        let system = FakeProcessSystem()
        system.setProcessGroupMembers([4321, 4322])
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "exited leader completed normally")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        system.setLeaderExited(true)
        let didRequestTermination = owner.requestTermination(gracePeriod: 0, forceKillDelay: 0.1)
        wait(for: [completed], timeout: 1)

        XCTAssertFalse(didRequestTermination)
        XCTAssertFalse(system.events.contains { $0.hasPrefix("signal:") })
        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testExitEventBeforeTerminalStateEventuallyReapsLeader() throws {
        let system = FakeProcessSystem()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "leader becomes terminal after its exit event")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        system.triggerExitMonitor()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) {
            system.setLeaderExited(true)
        }
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testExitedLeaderCompletesWhenDescendantsLeaveBeforeGraceDeadline() throws {
        let system = FakeProcessSystem()
        system.setProcessGroupMembers([4321, 4322])
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "process group empties during grace period")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        XCTAssertTrue(owner.requestTermination(gracePeriod: 2, forceKillDelay: 2))
        system.setLeaderExited(true)
        system.triggerExitMonitor()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            system.setProcessGroupMembers([4321])
        }
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertFalse(system.events.contains { $0.hasPrefix("signal:") })
    }

    func testExitBetweenTerminationRequestAndImmediateSignalIsReapedWithoutSignalling() throws {
        let system = FakeProcessSystem()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "leader exits before the immediate signal check")
        let recorder = CompletionRecorder(expectation: completed)
        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }

        // Keep the one-shot registration probe from consuming the scripted transition.
        system.performOnMonitorQueue {
            system.exitAfterNextRunningObservation()
            XCTAssertTrue(owner.requestTermination(gracePeriod: 0, forceKillDelay: 0))
        }
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertTrue(recorder.errors.isEmpty)
        XCTAssertEqual(system.events.filter { $0 == "reap" }, ["reap"])
        XCTAssertFalse(system.events.contains { $0.hasPrefix("signal:") })
        XCTAssertFalse(owner.requestTermination(gracePeriod: 0, forceKillDelay: 0))
    }

    func testExitBeforeTerminationDeadlineIsNeverSignalled() throws {
        let system = FakeProcessSystem()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "leader reaped")
        let unexpectedSignal = expectation(description: "no delayed signal after reaping")
        unexpectedSignal.isInverted = true
        system.expectSignal(unexpectedSignal)
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        system.setLeaderExited(true)
        owner.requestTermination(gracePeriod: 0, forceKillDelay: 0.1)
        wait(for: [completed], timeout: 1)
        wait(for: [unexpectedSignal], timeout: 0.2)

        XCTAssertFalse(system.events.contains { $0.hasPrefix("signal:") })
        XCTAssertEqual(system.events.filter { $0 == "reap" }, ["reap"])
    }

    func testLeaderRemainsUnreapedUntilDescendantReceivesForceKill() throws {
        let system = FakeProcessSystem()
        system.leaderExitsOnTermination = true
        system.setProcessGroupMembers([4321, 4322])
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "process group escalation completed")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        owner.requestTermination(gracePeriod: 0, forceKillDelay: 0.05)
        wait(for: [completed], timeout: 1)

        let events = system.events
        let termIndex = try XCTUnwrap(events.firstIndex(of: "signal:\(SIGTERM)"))
        let killIndex = try XCTUnwrap(events.firstIndex(of: "signal:\(SIGKILL)"))
        let reapIndex = try XCTUnwrap(events.firstIndex(of: "reap"))
        XCTAssertLessThan(termIndex, killIndex)
        XCTAssertLessThan(killIndex, reapIndex)
        XCTAssertTrue(events[termIndex ..< killIndex].contains("members"))
    }

    func testLeaderExitDuringGraceRetainsOwnershipUntilDescendantEscalation() throws {
        let system = FakeProcessSystem()
        system.setProcessGroupMembers([4321, 4322])
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "descendant escalation completed")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        XCTAssertTrue(owner.requestTermination(gracePeriod: 0.03, forceKillDelay: 0.03))
        system.setLeaderExited(true)
        system.triggerExitMonitor()
        wait(for: [completed], timeout: 1)

        let events = system.events
        let termIndex = try XCTUnwrap(events.firstIndex(of: "signal:\(SIGTERM)"))
        let killIndex = try XCTUnwrap(events.firstIndex(of: "signal:\(SIGKILL)"))
        let reapIndex = try XCTUnwrap(events.firstIndex(of: "reap"))
        XCTAssertLessThan(termIndex, killIndex)
        XCTAssertLessThan(killIndex, reapIndex)
    }

    func testGroupInspectionFailureDoesNotSuppressForceKill() throws {
        let system = FakeProcessSystem()
        system.leaderExitsOnTermination = true
        system.failGroupInspection()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "force kill followed inspection failure")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        XCTAssertTrue(owner.requestTermination(gracePeriod: 0, forceKillDelay: 0.03))
        wait(for: [completed], timeout: 1)

        XCTAssertTrue(system.events.contains("members"))
        XCTAssertTrue(system.events.contains("signal:\(SIGKILL)"))
    }

    func testSpawnFailureLeavesOwnerAvailableForALaterLaunch() throws {
        let system = FakeProcessSystem()
        system.failNextSpawn()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)

        XCTAssertThrowsError(try owner.launch(configuration: configuration()) { _, _ in })

        system.setLeaderExited(true)
        let completed = expectation(description: "second launch completed")
        let recorder = CompletionRecorder(expectation: completed)
        try owner.launch(configuration: configuration()) { recorder.record($0, error: $1) }
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertEqual(system.events.filter { $0 == "spawn" }.count, 2)
    }

    func testPosixSpawnAttachesNullInputWhenStandardInputIsClosed() throws {
        let outputPipe = try makePOSIXPipe()
        defer { Darwin.close(outputPipe.read) }
        let savedStandardInput = try duplicateStandardInput()
        var standardInputWasRestored = false
        defer {
            if !standardInputWasRestored {
                restoreStandardInput(from: savedStandardInput)
            }
        }
        XCTAssertEqual(Darwin.close(STDIN_FILENO), 0)

        let processIdentifier = try PBPosixChildProcessSystem().spawn(
            configuration: PBChildProcessConfiguration(
                launchPath: "/bin/sh",
                arguments: ["-c", "read value || printf no-input"],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: nil,
                standardInputFileDescriptor: nil,
                standardOutputFileDescriptor: outputPipe.write
            )
        )
        restoreStandardInput(from: savedStandardInput)
        standardInputWasRestored = true
        XCTAssertEqual(Darwin.close(outputPipe.write), 0)
        let status = try waitForProcess(processIdentifier)
        let output = FileHandle(fileDescriptor: outputPipe.read, closeOnDealloc: false).readDataToEndOfFile()

        XCTAssertEqual(status, 0)
        XCTAssertEqual(String(data: output, encoding: .utf8), "no-input")
    }

    func testPosixReapWaitsForExitAndReportsAlreadyReapedChild() throws {
        let system = PBPosixChildProcessSystem()
        let processIdentifier = try system.spawn(configuration: PBChildProcessConfiguration(
            launchPath: "/bin/sleep",
            arguments: ["60"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: nil,
            standardInputFileDescriptor: nil,
            standardOutputFileDescriptor: STDOUT_FILENO
        ))
        var wasReaped = false
        defer {
            if !wasReaped {
                _ = kill(processIdentifier, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(processIdentifier, &status, 0)
            }
        }

        XCTAssertNil(try system.reapIfExited(processIdentifier: processIdentifier))
        XCTAssertEqual(kill(processIdentifier, SIGTERM), 0)
        var status: Int32?
        for _ in 0 ..< 200 {
            status = try system.reapIfExited(processIdentifier: processIdentifier)
            if status != nil {
                break
            }
            usleep(10000)
        }
        XCTAssertNotNil(status)
        wasReaped = status != nil
        XCTAssertThrowsError(try system.reapIfExited(processIdentifier: processIdentifier)) { error in
            XCTAssertEqual((error as NSError).code, Int(ECHILD))
        }
        XCTAssertThrowsError(try system.exitStateWithoutReaping(processIdentifier: processIdentifier)) { error in
            XCTAssertEqual((error as NSError).code, Int(ECHILD))
        }
    }

    func testPosixSpawnRunsInConfiguredWorkingDirectory() throws {
        try assertSpawnRunsInConfiguredWorkingDirectory(system: PBPosixChildProcessSystem())
    }

    func testPosixSpawnLegacyWorkingDirectoryRunsInConfiguredDirectory() throws {
        try assertSpawnRunsInConfiguredWorkingDirectory(
            system: PBPosixChildProcessSystem(usesLegacyWorkingDirectoryAPI: true)
        )
    }

    func testPosixSpawnLegacyWorkingDirectoryRejectsANonDirectoryWithoutClosingStdout() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let regularFile = directory.appendingPathComponent("regular-file")
        try Data("not a directory".utf8).write(to: regularFile)
        let output = Pipe()
        defer { try? output.fileHandleForReading.close() }
        defer { try? output.fileHandleForWriting.close() }
        let descriptor = output.fileHandleForWriting.fileDescriptor
        let system = PBPosixChildProcessSystem(usesLegacyWorkingDirectoryAPI: true)

        let configuration = PBChildProcessConfiguration(
            launchPath: "/bin/pwd",
            arguments: [],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: regularFile.path,
            standardInputFileDescriptor: nil,
            standardOutputFileDescriptor: descriptor
        )
        do {
            let processIdentifier = try system.spawn(configuration: configuration)
            _ = kill(processIdentifier, SIGKILL)
            _ = try waitForProcess(processIdentifier)
            XCTFail("A regular file cannot become the child working directory")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOTDIR))
        }
        XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0, "Spawn failure retains the caller's pipe ownership")
        try output.fileHandleForWriting.close()
        XCTAssertEqual(output.fileHandleForReading.readDataToEndOfFile(), Data())
    }

    private func assertSpawnRunsInConfiguredWorkingDirectory(system: PBPosixChildProcessSystem) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputPipe = try makePOSIXPipe()
        defer { Darwin.close(outputPipe.read) }
        var outputWriteIsOpen = true
        defer {
            if outputWriteIsOpen {
                Darwin.close(outputPipe.write)
            }
        }

        let processIdentifier = try system.spawn(configuration: PBChildProcessConfiguration(
            launchPath: "/bin/pwd",
            arguments: [],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: directory.path,
            standardInputFileDescriptor: nil,
            standardOutputFileDescriptor: outputPipe.write
        ))
        XCTAssertEqual(Darwin.close(outputPipe.write), 0)
        outputWriteIsOpen = false
        XCTAssertEqual(try waitForProcess(processIdentifier), 0)
        let output = FileHandle(fileDescriptor: outputPipe.read, closeOnDealloc: false).readDataToEndOfFile()
        let outputPath = try XCTUnwrap(String(data: output, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var actual: stat = .init()
        var expected: stat = .init()
        XCTAssertEqual(Darwin.lstat(outputPath, &actual), 0)
        XCTAssertEqual(Darwin.lstat(directory.path, &expected), 0)
        XCTAssertEqual(actual.st_dev, expected.st_dev)
        XCTAssertEqual(actual.st_ino, expected.st_ino)
    }

    func testPosixSignalReportsMissingProcessGroup() {
        XCTAssertThrowsError(try PBPosixChildProcessSystem().send(signal: SIGTERM, toProcessGroup: Int32.max)) { error in
            XCTAssertEqual((error as NSError).code, Int(ESRCH))
        }
    }

    func testPosixGroupInspectionReportsAnAbsentGroupAsEmpty() throws {
        XCTAssertEqual(try PBPosixChildProcessSystem().processGroupMembers(processGroup: Int32.max), [])
    }

    func testPosixExitObservationRetriesInterruptionBeforeReportingTerminalState() throws {
        let calls = Mutex(0)
        let system = PBPosixChildProcessSystem(observeExit: { identifier, information in
            calls.withLock { count in
                count += 1
                if count == 1 {
                    errno = EINTR
                    return -1
                }
                information.pointee.si_pid = identifier
                information.pointee.si_code = CLD_EXITED
                return 0
            }
        })
        XCTAssertEqual(try system.exitStateWithoutReaping(processIdentifier: 42), .terminal)
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testPosixGroupInspectionPropagatesSystemFailure() {
        let system = PBPosixChildProcessSystem(inspectGroup: { _, _, _ in
            errno = EIO
            return -1
        })
        XCTAssertThrowsError(try system.processGroupMembers(processGroup: 42)) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EIO))
        }
    }

    func testAppSupervisorRejectsInvalidStderrWithoutClosingConfiguredStdout() {
        let supervisor = PBChildProcessSupervisor(
            launchPath: "/usr/bin/true", arguments: [], environment: [:], workingDirectory: nil,
            standardInputFileDescriptor: nil, standardOutputFileDescriptor: STDOUT_FILENO,
            standardErrorFileDescriptor: NSNumber(value: -1), terminationHandler: { _, _ in
                XCTFail("Descriptor preparation must fail before a child launches")
            }
        )

        XCTAssertThrowsError(try supervisor.launch()) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EBADF))
        }
        XCTAssertGreaterThanOrEqual(fcntl(STDOUT_FILENO, F_GETFD), 0)
    }

    func testAppSupervisorSchedulesTerminationWithOptionalForceKillDelay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        for resistsTermination in [false, true] {
            let record = directory.appendingPathComponent("pid-\(resistsTermination)")
            let ready = directory.appendingPathComponent("ready-\(resistsTermination)")
            let completed = expectation(description: "supervisor reaped the \(resistsTermination ? "resistant" : "cooperative") child")
            completed.assertForOverFulfill = true
            let recorder = CompletionRecorder(expectation: completed)
            let supervisor = PBChildProcessSupervisor(
                launchPath: "/bin/sh",
                arguments: ["-eu", "-c", """
                trap '\(resistsTermination ? "" : "exit 143")' TERM
                printf '%s\\n' "$$" > '\(record.path)'
                : > '\(ready.path)'
                while :; do :; done
                """],
                environment: ProcessInfo.processInfo.environment, workingDirectory: nil,
                standardInputFileDescriptor: nil, standardOutputFileDescriptor: STDOUT_FILENO,
                standardErrorFileDescriptor: NSNumber(value: STDERR_FILENO), terminationHandler: { recorder.record($0, error: $1.map { $0 as NSError }) }
            )
            defer { supervisor.requestTermination(gracePeriod: 0, forceKillDelay: 0) }
            try supervisor.launch()
            let readiness = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: ready.path)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [readiness], timeout: 2), .completed)

            supervisor.requestTermination(gracePeriod: 0.01, forceKillDelay: resistsTermination ? NSNumber(value: 0.02) : nil)
            wait(for: [completed], timeout: 2)

            XCTAssertEqual(recorder.statuses, [resistsTermination ? SIGKILL : 143 << 8])
            XCTAssertTrue(recorder.errors.isEmpty)
            let processIdentifier = try XCTUnwrap(pid_t(String(contentsOf: record, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertNotEqual(kill(processIdentifier, 0), 0, "The supervisor must reap its terminal leader")
        }
    }

    func testPosixGroupInspectionIncludesMoreThanInitialCapacity() throws {
        let system = PBPosixChildProcessSystem()
        let outputPipe = try makePOSIXPipe()
        defer { Darwin.close(outputPipe.read) }
        let processIdentifier = try system.spawn(configuration: PBChildProcessConfiguration(
            launchPath: "/bin/sh",
            arguments: ["-c", "i=0; while [ \"$i\" -lt 20 ]; do /bin/sleep 60 & i=$((i+1)); done; printf ready; wait"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: nil,
            standardInputFileDescriptor: nil,
            standardOutputFileDescriptor: outputPipe.write
        ))
        defer {
            _ = killpg(processIdentifier, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(processIdentifier, &status, 0)
        }
        XCTAssertEqual(Darwin.close(outputPipe.write), 0)
        let readiness = try FileHandle(fileDescriptor: outputPipe.read, closeOnDealloc: false).read(upToCount: 5)
        XCTAssertEqual(readiness, Data("ready".utf8))

        let members = try system.processGroupMembers(processGroup: processIdentifier)
        XCTAssertTrue(members.contains(processIdentifier))
        XCTAssertEqual(members.count, 21)
    }

    func testPosixSpawnRejectsInvalidConfigurationBeforeLaunching() {
        let system = PBPosixChildProcessSystem()
        let base = PBChildProcessConfiguration(
            launchPath: "/bin/echo",
            arguments: [],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: nil,
            standardInputFileDescriptor: nil,
            standardOutputFileDescriptor: STDOUT_FILENO
        )
        let invalidPath = PBChildProcessConfiguration(
            launchPath: "/bin/echo\0invalid",
            arguments: base.arguments,
            environment: base.environment,
            workingDirectory: nil,
            standardInputFileDescriptor: nil,
            standardOutputFileDescriptor: base.standardOutputFileDescriptor
        )
        XCTAssertThrowsError(try system.spawn(configuration: invalidPath)) { error in
            XCTAssertEqual((error as NSError).code, Int(EINVAL))
        }

        let invalidDescriptor = PBChildProcessConfiguration(
            launchPath: base.launchPath,
            arguments: base.arguments,
            environment: base.environment,
            workingDirectory: nil,
            standardInputFileDescriptor: nil,
            standardOutputFileDescriptor: -1
        )
        XCTAssertThrowsError(try system.spawn(configuration: invalidDescriptor)) { error in
            XCTAssertEqual((error as NSError).code, Int(EBADF))
        }

        let missingDirectory = PBChildProcessConfiguration(
            launchPath: base.launchPath, arguments: base.arguments, environment: base.environment,
            workingDirectory: "/private/tmp/gitx-missing-\(UUID().uuidString)",
            standardInputFileDescriptor: nil, standardOutputFileDescriptor: STDOUT_FILENO
        )
        XCTAssertThrowsError(try system.spawn(configuration: missingDirectory)) { error in
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }
    }

    func testPosixSpawnDoesNotInheritInteractiveStandardInput() throws {
        let inputPipe = try makePOSIXPipe()
        let outputPipe = try makePOSIXPipe()
        defer { Darwin.close(outputPipe.read) }
        let savedStandardInput = try duplicateStandardInput()
        var standardInputWasRestored = false
        defer {
            if !standardInputWasRestored {
                restoreStandardInput(from: savedStandardInput)
            }
        }
        let inheritedInput = Data("inherited-input\n".utf8)
        try FileHandle(fileDescriptor: inputPipe.write, closeOnDealloc: false).write(contentsOf: inheritedInput)
        XCTAssertEqual(Darwin.close(inputPipe.write), 0)
        XCTAssertEqual(dup2(inputPipe.read, STDIN_FILENO), STDIN_FILENO)
        XCTAssertEqual(Darwin.close(inputPipe.read), 0)

        let processIdentifier = try PBPosixChildProcessSystem().spawn(
            configuration: PBChildProcessConfiguration(
                launchPath: "/bin/sh",
                arguments: ["-c", "read value && printf inherited || printf no-input"],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: nil,
                standardInputFileDescriptor: nil,
                standardOutputFileDescriptor: outputPipe.write
            )
        )
        restoreStandardInput(from: savedStandardInput)
        standardInputWasRestored = true
        XCTAssertEqual(Darwin.close(outputPipe.write), 0)
        let status = try waitForProcess(processIdentifier)
        let output = FileHandle(fileDescriptor: outputPipe.read, closeOnDealloc: false).readDataToEndOfFile()

        XCTAssertEqual(status, 0)
        XCTAssertEqual(String(data: output, encoding: .utf8), "no-input")
    }

    func testPosixSpawnPreservesOutputWhenItsSourceOccupiesStandardInput() throws {
        let outputPipe = try makePOSIXPipe()
        defer { Darwin.close(outputPipe.read) }
        let savedStandardInput = try duplicateStandardInput()
        var standardInputWasRestored = false
        defer {
            if !standardInputWasRestored {
                restoreStandardInput(from: savedStandardInput)
            }
        }
        XCTAssertEqual(dup2(outputPipe.write, STDIN_FILENO), STDIN_FILENO)
        XCTAssertEqual(Darwin.close(outputPipe.write), 0)

        let processIdentifier = try PBPosixChildProcessSystem().spawn(
            configuration: PBChildProcessConfiguration(
                launchPath: "/usr/bin/printf",
                arguments: ["descriptor-zero-output"],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: nil,
                standardInputFileDescriptor: nil,
                standardOutputFileDescriptor: STDIN_FILENO
            )
        )
        restoreStandardInput(from: savedStandardInput)
        standardInputWasRestored = true
        let status = try waitForProcess(processIdentifier)
        let output = FileHandle(fileDescriptor: outputPipe.read, closeOnDealloc: false).readDataToEndOfFile()

        XCTAssertEqual(status, 0)
        XCTAssertEqual(String(data: output, encoding: .utf8), "descriptor-zero-output")
    }

    private func makePOSIXPipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return (descriptors[0], descriptors[1])
    }

    private func duplicateStandardInput() throws -> Int32 {
        let descriptor = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard descriptor != -1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return descriptor
    }

    private func restoreStandardInput(from savedDescriptor: Int32) {
        guard savedDescriptor >= 0 else { return }
        XCTAssertEqual(dup2(savedDescriptor, STDIN_FILENO), STDIN_FILENO)
        XCTAssertEqual(Darwin.close(savedDescriptor), 0)
    }

    private func waitForProcess(_ processIdentifier: pid_t) throws -> Int32 {
        var status: Int32 = 0
        while waitpid(processIdentifier, &status, 0) == -1 {
            guard errno == EINTR else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        return status
    }
}
