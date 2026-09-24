import Darwin
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
        private var members: [pid_t] = [4321]
        private var shouldFailSpawn = false
        private var shouldFailObservation = false
        private var shouldFailReap = false
        private var shouldFailSignal = false
        private var shouldFailGroupInspection = false
        private var reapReady = true
        private var signalExpectation: XCTestExpectation?
        var enqueueExitEventOnActivation = false
        var leaderExitsOnTermination = false

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storedEvents
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
            if shouldFailObservation {
                shouldFailObservation = false
                throw Failure.observation
            }
            return leaderExited ? .terminal : .running
        }

        func reapIfExited(processIdentifier: pid_t) throws -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            storedEvents.append("reap")
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
            lock.unlock()
            expectation?.fulfill()
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
