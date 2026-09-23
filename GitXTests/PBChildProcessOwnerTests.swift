import Darwin
import XCTest

final class PBChildProcessOwnerTests: XCTestCase {
    private final class CompletionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private let expectation: XCTestExpectation
        private var storedStatuses: [Int32] = []

        init(expectation: XCTestExpectation) {
            self.expectation = expectation
        }

        var statuses: [Int32] {
            lock.lock()
            defer { lock.unlock() }
            return storedStatuses
        }

        func record(_ status: Int32) {
            lock.lock()
            storedStatuses.append(status)
            lock.unlock()
            expectation.fulfill()
        }
    }

    private final class FakeExitMonitor: PBChildProcessExitMonitoring, @unchecked Sendable {
        private let lock = NSLock()
        private let handler: @Sendable () -> Void
        private var isActive = false
        private var isCancelled = false

        init(handler: @escaping @Sendable () -> Void) {
            self.handler = handler
        }

        func activate() {
            lock.lock()
            isActive = true
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            lock.unlock()
        }

        func triggerEvenIfCancelled() {
            lock.lock()
            let shouldTrigger = isActive
            lock.unlock()
            if shouldTrigger {
                handler()
            }
        }
    }

    private final class FakeProcessSystem: PBChildProcessSystem, @unchecked Sendable {
        enum Failure: Error {
            case spawn
        }

        private let lock = NSLock()
        private let processIdentifier: pid_t = 4321
        private var storedEvents: [String] = []
        private var storedMonitor: FakeExitMonitor?
        private var leaderExited = false
        private var members: [pid_t] = [4321]
        private var shouldFailSpawn = false
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

        func triggerExitMonitor() {
            lock.lock()
            let monitor = storedMonitor
            lock.unlock()
            monitor?.triggerEvenIfCancelled()
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
            let monitor = FakeExitMonitor(handler: handler)
            lock.lock()
            storedMonitor = monitor
            storedEvents.append("monitor")
            lock.unlock()
            return monitor
        }

        func hasExitedWithoutReaping(processIdentifier: pid_t) throws -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return leaderExited
        }

        func reap(processIdentifier: pid_t) throws -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            storedEvents.append("reap")
            return 0
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
            lock.unlock()
        }

        func processGroupMembers(processGroup: pid_t) throws -> [pid_t] {
            lock.lock()
            defer { lock.unlock() }
            storedEvents.append("members")
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
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "leader reaped")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0) }
        wait(for: [completed], timeout: 1)
        system.triggerExitMonitor()

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertEqual(system.events.filter { $0 == "reap" }, ["reap"])
    }

    func testExitBeforeTerminationDeadlineIsNeverSignalled() throws {
        let system = FakeProcessSystem()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)
        let completed = expectation(description: "leader reaped")
        let recorder = CompletionRecorder(expectation: completed)

        try owner.launch(configuration: configuration()) { recorder.record($0) }
        system.setLeaderExited(true)
        owner.requestTermination(gracePeriod: 0, forceKillDelay: 0.1)
        wait(for: [completed], timeout: 1)

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

        try owner.launch(configuration: configuration()) { recorder.record($0) }
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

    func testSpawnFailureLeavesOwnerAvailableForALaterLaunch() throws {
        let system = FakeProcessSystem()
        system.failNextSpawn()
        let owner = PBChildProcessOwner(system: system, queueLabel: #function)

        XCTAssertThrowsError(try owner.launch(configuration: configuration()) { _ in })

        system.setLeaderExited(true)
        let completed = expectation(description: "second launch completed")
        let recorder = CompletionRecorder(expectation: completed)
        try owner.launch(configuration: configuration()) { recorder.record($0) }
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(recorder.statuses, [0])
        XCTAssertEqual(system.events.filter { $0 == "spawn" }.count, 2)
    }
}
