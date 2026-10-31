import AppKit
@testable import GitX
import ObjectiveGit
import Synchronization
import XCTest

final class GitBinaryReliabilityTests: XCTestCase {
    private final nonisolated class Clock: Sendable {
        struct Job: Sendable { let deadline: TimeInterval; let action: @Sendable () -> Void }
        struct State { var now: TimeInterval = 0; var jobs: [Job] = [] }
        let state = Mutex(State())
        var timing: GitDiscoveryTiming {
            GitDiscoveryTiming(now: { self.state.withLock { $0.now } }, schedule: { delay, action in
                self.state.withLock { $0.jobs.append(Job(deadline: $0.now + delay, action: action)) }
            })
        }

        func elapse(_ duration: TimeInterval) {
            state.withLock { $0.now += duration }
        }

        func advance(_ duration: TimeInterval) {
            elapse(duration)
            while true {
                let actions = state.withLock { state -> [@Sendable () -> Void] in
                    let due = state.jobs.filter { $0.deadline <= state.now }
                    state.jobs.removeAll { $0.deadline <= state.now }
                    return due.map(\.action)
                }
                if actions.isEmpty {
                    return
                }
                actions.forEach { $0() }
            }
        }
    }

    private final nonisolated class Fixture: Sendable {
        struct State { var preference: String?; var outputs: [String: String]; var calls: [String] = [] }
        let state: Mutex<State>
        init(preference: String? = nil, outputs: [String: String] = [:]) {
            state = Mutex(State(preference: preference, outputs: outputs))
        }

        func output(_ path: String, _: [String]) -> String? {
            state.withLock { state in state.calls.append(path); return state.outputs[path] }
        }

        func discovery(notify: @escaping @MainActor @Sendable (GitBinarySelection?, String?) -> Void = { _, _ in }) -> GitBinaryDiscovery {
            GitBinaryDiscovery(preference: { self.state.withLock { $0.preference } }, environment: [:],
                               output: { self.output($0, $1) }, locations: [], notify: notify)
        }
    }

    func testFailureLocationsContainOnlyNormalizedNonemptyExecutablesInAttemptOrder() {
        let calls = Mutex<[String]>([])
        let logs = Mutex<[String]>([])
        let discovery = GitBinaryDiscovery(preference: { "/configured git\r\n" }, environment: ["GIT_PATH": "\r\n"], output: { path, arguments in
            calls.withLock { $0.append(path + " " + arguments.joined(separator: " ")) }
            return path == "/usr/bin/which" || path == "/usr/bin/xcrun" ? "/looked up/git\r\n" : nil
        }, locations: ["", "/configured git", "/known/git\n", "/known/git", "\r\n"], log: { message in logs.withLock { $0.append(message) } })
        let finished = expectation(description: "Exhaustion lists executable candidates, never lookup tools")
        discovery.whenAvailable { path, error in
            XCTAssertNil(path)
            XCTAssertEqual(error?.localizedFailureReason, "Could not find a git binary version 1.6.0 or higher.\nPlease make sure there is a git binary in one of the following locations:\n\n\t/configured git\n\t/looked up/git\n\t/known/git")
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
        let attempts = calls.withLock { $0 }
        XCTAssertFalse(attempts.contains(" --version"), "Known empty candidates must never be launched")
        XCTAssertTrue(attempts.contains("/usr/bin/which git"))
        XCTAssertTrue(attempts.contains("/usr/bin/xcrun -f git"))
        XCTAssertTrue(logs.withLock { $0.contains("[GitDiscovery] Attempt /usr/bin/which arguments=[\"git\"]") })
        XCTAssertTrue(logs.withLock { $0.contains("[GitDiscovery] Attempt /usr/bin/xcrun arguments=[\"-f\", \"git\"]") })
        XCTAssertTrue(attempts.contains("/configured git --version"), "Literal filename spaces survive normalization")
    }

    func testIndependentSynchronousProbesRunWithoutDisplacingDiscovery() {
        for queryingVersion in [false, true] {
            let clock = Clock()
            let entered = expectation(description: "Both workers remain owned")
            entered.expectedFulfillmentCount = 2
            let release = DispatchSemaphore(value: 0)
            defer { release.signal(); release.signal() }
            let calls = Mutex<[String]>([])
            let warnings = Mutex<[String]>([])
            let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { path, _, _ in
                calls.withLock { $0.append(path) }
                if path.hasPrefix("/occupied") {
                    entered.fulfill(); _ = release.wait(timeout: .now() + 10)
                }
                return .init(output: { ["/configured", "/direct", "/healthy"].contains(path) ? "git version 2.50.1" : nil }, cancel: {})
            })
            for index in 0 ..< 2 {
                runner.run(path: "/occupied\(index)", arguments: [], timeout: 100) { _ in }
            }
            wait(for: [entered], timeout: 3)
            let discovery = GitBinaryDiscovery(preference: { "/configured" }, environment: [:], locations: ["/healthy"], timing: clock.timing, runner: runner,
                                               notify: {
                                                   _, rejected in if let rejected {
                                                       warnings.withLock { $0.append(rejected) }
                                                   }
                                               })
            let ready = expectation(description: "Discovery and the independent request both settle")
            discovery.whenAvailable { path, error in XCTAssertNotNil(path); XCTAssertNil(error); ready.fulfill() }
            let scheduled = clock.state.withLock { $0.jobs.count }
            let direct = expectation(description: "Accepted direct probe actually executes")
            DispatchQueue.global().async {
                if queryingVersion {
                    XCTAssertEqual(discovery.version(forPath: "/direct"), "2.50.1")
                } else {
                    XCTAssertTrue(discovery.accept("/direct"))
                }
                direct.fulfill()
            }
            let queued = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in clock.state.withLock { $0.jobs.count > scheduled } }, object: nil)
            wait(for: [queued], timeout: 3)
            release.signal(); release.signal()
            wait(for: [direct, ready], timeout: 3)
            XCTAssertEqual(calls.withLock { $0.filter { $0 == "/direct" }.count }, 1)
            XCTAssertTrue(warnings.withLock { $0.isEmpty }, "An unexecuted preference is not a rejected executable")
        }
    }

    func testPendingProbeAdmissionIsFIFOWithoutCancellingIndependentRequests() {
        let clock = Clock()
        let entered = expectation(description: "Two occupied workers")
        entered.expectedFulfillmentCount = 2
        let first = DispatchSemaphore(value: 0)
        let second = DispatchSemaphore(value: 0)
        defer { first.signal(); second.signal() }
        let calls = Mutex<[String]>([])
        let outcomes = Mutex<[String]>([])
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { path, _, _ in
            calls.withLock { $0.append(path) }
            if path == "/occupied0" {
                entered.fulfill(); _ = first.wait(timeout: .now() + 10)
            }
            if path == "/occupied1" {
                entered.fulfill(); _ = second.wait(timeout: .now() + 10)
            }
            return .init(output: { "git version 2.50.1" }, cancel: {})
        })
        for index in 0 ..< 2 {
            runner.run(path: "/occupied\(index)", arguments: [], timeout: 100) { _ in }
        }
        wait(for: [entered], timeout: 3)
        let finished = expectation(description: "All queued callers finish once")
        finished.expectedFulfillmentCount = 3
        finished.assertForOverFulfill = true
        for index in 0 ..< 3 {
            runner.run(path: "/waiting\(index)", arguments: [], timeout: 100) { result in
                outcomes.withLock { $0.append(String(describing: result)) }; finished.fulfill()
            }
        }
        XCTAssertTrue(outcomes.withLock { $0.isEmpty }, "Admission must not evict an existing waiter")
        first.signal()
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(calls.withLock { $0.filter { $0.hasPrefix("/waiting") } }, ["/waiting0", "/waiting1", "/waiting2"])
        XCTAssertTrue(outcomes.withLock { $0.allSatisfy { $0.hasPrefix("output") } })
    }

    func testPendingProbeCapacityRefusesOnlyTheExcessRequestAsBusy() {
        let clock = Clock()
        let entered = expectation(description: "Two occupied workers")
        entered.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let outcomes = Mutex<[String]>([])
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { path, _, _ in
            if path.hasPrefix("/occupied") {
                entered.fulfill(); _ = release.wait(timeout: .now() + 10)
            }
            return .init(output: { nil }, cancel: {})
        })
        for index in 0 ..< 2 {
            runner.run(path: "/occupied\(index)", arguments: [], timeout: 100) { _ in }
        }
        wait(for: [entered], timeout: 3)
        for index in 0 ..< 17 {
            runner.run(path: "/waiting\(index)", arguments: [], timeout: 100) { result in outcomes.withLock { $0.append(String(describing: result)) } }
        }
        XCTAssertEqual(outcomes.withLock { $0 }, ["busy"])
        clock.advance(100)
    }

    func testExecutableCandidatesAreActuallyProbedOnlyOnce() {
        let calls = Mutex<[String]>([])
        let discovery = GitBinaryDiscovery(preference: { "/duplicate\r\n" }, environment: ["GIT_PATH": "/duplicate"], output: { path, _ in
            calls.withLock { $0.append(path) }
            return path == "/usr/bin/which" || path == "/usr/bin/xcrun" ? "/duplicate\n" : nil
        }, locations: ["/duplicate"])
        let finished = expectation(description: "Distinct executable attempts exhaust")
        discovery.whenAvailable { path, error in XCTAssertNil(path); XCTAssertNotNil(error); finished.fulfill() }
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(calls.withLock { $0.filter { $0 == "/duplicate" }.count }, 1)
        XCTAssertTrue(calls.withLock { $0.contains("/usr/bin/which") && $0.contains("/usr/bin/xcrun") })
    }

    func testLineEndingOnlyPreferenceUsesAutomaticDiscoveryWithoutARejection() {
        let finished = expectation(description: "Automatic discovery exhausts without a literal newline preference")
        let warnings = Mutex(0)
        let discovery = GitBinaryDiscovery(preference: { "\r\n" }, environment: [:], output: { _, _ in nil }, locations: [], notify: { _, _ in warnings.withLock { $0 += 1 } })
        discovery.whenAvailable { path, error in XCTAssertNil(path); XCTAssertEqual(error?.code, 1); finished.fulfill() }
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(warnings.withLock { $0 }, 0)
    }

    func testUnexecutedCancellationSettlesWithoutSelfRequeueAndOnlyDemandRetries() {
        let clock = Clock()
        let entered = expectation(description: "Two occupied workers")
        entered.expectedFulfillmentCount = 2
        let drained = expectation(description: "Both occupied workers finish")
        drained.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let admissions = Mutex(0)
        let budgets = Mutex<[TimeInterval]>([])
        let warnings = Mutex<[String]>([])
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { path, _, remaining in
            if path.hasPrefix("/occupied") {
                entered.fulfill(); _ = release.wait(timeout: .now() + 10)
            } else {
                budgets.withLock { $0.append(remaining) }
            }
            return .init(output: { "git version 2.50.1" }, cancel: {})
        }, admissionObserver: { request in
            let index = admissions.withLock { let index = $0; $0 += 1; return index }
            if index == 2 {
                clock.elapse(2); request.cancel()
            }
        })
        for index in 0 ..< 2 {
            runner.run(path: "/occupied\(index)", arguments: [], timeout: 100) { _ in drained.fulfill() }
        }
        wait(for: [entered], timeout: 3)
        let discovery = GitBinaryDiscovery(preference: { "/configured" }, environment: [:], locations: [], timing: clock.timing, runner: runner,
                                           notify: {
                                               _, rejected in if let rejected {
                                                   warnings.withLock { $0.append(rejected) }
                                               }
                                           })
        let unavailable = expectation(description: "Unexpected current cancellation settles without a self-retry loop")
        unavailable.assertForOverFulfill = true
        discovery.whenAvailable { path, error in XCTAssertNil(path); XCTAssertEqual(error?.code, 3); unavailable.fulfill() }
        wait(for: [unavailable], timeout: 3)
        XCTAssertEqual(admissions.withLock { $0 }, 3)
        XCTAssertTrue(budgets.withLock { $0.isEmpty })
        release.signal(); release.signal()
        wait(for: [drained], timeout: 3)
        let ready = expectation(description: "New demand owns a new attempt")
        discovery.whenAvailable { path, error in XCTAssertEqual(path, "/configured"); XCTAssertNil(error); ready.fulfill() }
        wait(for: [ready], timeout: 3)
        XCTAssertEqual(budgets.withLock { $0 }, [5])
        XCTAssertEqual(admissions.withLock { $0 }, 4)
        XCTAssertTrue(warnings.withLock { $0.isEmpty })
    }

    func testAttemptDeadlineIncludesTimeSpentInDiscoveryDiagnosticsBeforeAdmission() {
        let clock = Clock()
        let calls = Mutex(0)
        let delayed = Mutex(false)
        let discovery = GitBinaryDiscovery(preference: { "/configured" }, environment: [:], output: { _, _ in calls.withLock { $0 += 1 }; return "git version 2.50.1" },
                                           locations: [], timing: clock.timing, log: { message in
                                               if message.contains("Attempt /configured"), delayed.withLock({ let first = !$0; $0 = true; return first }) {
                                                   clock.elapse(5)
                                               }
                                           })
        let expired = expectation(description: "The expired attempt never launches")
        discovery.whenAvailable { path, error in XCTAssertNil(path); XCTAssertEqual(error?.code, 3); expired.fulfill() }
        wait(for: [expired], timeout: 3)
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func testExecutedCancellationIsTemporaryAndOnlyANewDemandRetriesIt() {
        let request = Mutex<GitDiscoveryProbeRunner.Request?>(nil)
        let attempts = Mutex(0)
        let warnings = Mutex(0)
        let runner = GitDiscoveryProbeRunner(factory: { _, _, _ in
            .init(output: {
                let index = attempts.withLock { let index = $0; $0 += 1; return index }
                if index == 0 {
                    request.withLock { $0 }?.cancel()
                }
                return "git version 2.50.1"
            }, cancel: {})
        }, admissionObserver: { value in request.withLock { $0 = value } })
        defer { request.withLock { $0 = nil } }
        let discovery = GitBinaryDiscovery(preference: { "/configured" }, environment: [:], locations: ["/fallback"], runner: runner,
                                           notify: { _, _ in warnings.withLock { $0 += 1 } })
        let unavailable = expectation(description: "Executed cancellation settles exactly once without fallback or rejection")
        unavailable.assertForOverFulfill = true
        discovery.whenAvailable { path, error in
            XCTAssertNil(path); XCTAssertEqual(error?.domain, "PBGitBinaryErrorDomain"); XCTAssertEqual(error?.code, 3); unavailable.fulfill()
        }
        wait(for: [unavailable], timeout: 3)
        XCTAssertEqual(attempts.withLock { $0 }, 1)
        XCTAssertEqual(warnings.withLock { $0 }, 0)
        let retried = expectation(description: "A later demand may retry temporary unavailability")
        discovery.whenAvailable { path, error in XCTAssertEqual(path, "/configured"); XCTAssertNil(error); retried.fulfill() }
        wait(for: [retried], timeout: 3)
        XCTAssertEqual(attempts.withLock { $0 }, 2)
    }

    func testQueuedExpiryCanBeRetriedByALaterDemand() {
        let clock = Clock()
        let entered = expectation(description: "Both workers are occupied")
        entered.expectedFulfillmentCount = 2
        let drained = expectation(description: "Both occupied workers finish")
        drained.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let calls = Mutex<[String]>([])
        let warnings = Mutex<[String]>([])
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { path, _, _ in
            calls.withLock { $0.append(path) }
            if path.hasPrefix("/occupied") {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
            return .init(output: { "git version 2.50.1" }, cancel: {})
        })
        for index in 0 ..< 2 {
            runner.run(path: "/occupied\(index)", arguments: [], timeout: 100) { _ in drained.fulfill() }
        }
        wait(for: [entered], timeout: 3)
        let discovery = GitBinaryDiscovery(preference: { "/configured" }, environment: [:], locations: ["/fallback"], timing: clock.timing, runner: runner,
                                           notify: {
                                               _, rejected in if let rejected {
                                                   warnings.withLock { $0.append(rejected) }
                                               }
                                           })
        let unavailable = expectation(description: "Queue expiry is temporary without rejecting the executable")
        unavailable.assertForOverFulfill = true
        discovery.whenAvailable { path, error in
            XCTAssertNil(path)
            XCTAssertEqual(error?.domain, "PBGitBinaryErrorDomain")
            XCTAssertEqual(error?.code, 3)
            unavailable.fulfill()
        }
        clock.advance(5)
        wait(for: [unavailable], timeout: 3)
        release.signal(); release.signal()
        wait(for: [drained], timeout: 3)
        let ready = expectation(description: "A fresh demand executes the original preference")
        ready.assertForOverFulfill = true
        discovery.whenAvailable { path, error in
            XCTAssertEqual(path, "/configured")
            XCTAssertNil(error)
            ready.fulfill()
        }
        wait(for: [ready], timeout: 3)
        XCTAssertEqual(calls.withLock { $0.filter { $0 == "/configured" }.count }, 1)
        XCTAssertFalse(calls.withLock { $0.contains("/fallback") })
        XCTAssertTrue(warnings.withLock { $0.isEmpty })
    }

    func testAutomaticDiscoveryFailureDoesNotRejectNilEmptyOrLineEndingPreferences() {
        for preference: String? in [nil, "", "\r\n"] {
            let warnings = Mutex<[String]>([])
            let discovery = GitBinaryDiscovery(preference: { preference }, environment: [:], output: { _, _ in nil }, locations: [],
                                               notify: {
                                                   _, rejected in if let rejected {
                                                       warnings.withLock { $0.append(rejected) }
                                                   }
                                               })
            let finished = expectation(description: "Automatic discovery exhausts without a configured preference")
            discovery.whenAvailable { path, error in
                XCTAssertNil(path)
                XCTAssertEqual(error?.code, 1)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 3)
            XCTAssertTrue(warnings.withLock { $0.isEmpty }, "Automatic preference \(String(describing: preference)) must not be reported as rejected")
        }
    }

    func testAutomaticPreferenceFailureRetainsAnActiveSelectionWithTheSameWarningIdentity() {
        for automatic: String? in [nil, "", "\r\n"] {
            let preference = Mutex<String?>("/configured")
            let warning = expectation(description: "A failed automatic replacement preserves the usable selection")
            let discovery = GitBinaryDiscovery(preference: { preference.withLock { $0 } }, environment: [:], output: { path, _ in
                path == "/configured" ? "git version 2.50.1" : nil
            }, locations: [], notify: { selection, rejected in
                if let rejected {
                    XCTAssertEqual(rejected, "")
                    XCTAssertEqual(selection?.path, "/configured")
                    warning.fulfill()
                }
            })
            let ready = expectation(description: "The initial preference is validated")
            discovery.whenAvailable { path, error in XCTAssertEqual(path, "/configured"); XCTAssertNil(error); ready.fulfill() }
            wait(for: [ready], timeout: 3)
            preference.withLock { $0 = automatic }
            discovery.start()
            wait(for: [warning], timeout: 3)
            XCTAssertEqual(discovery.currentSelection, GitBinarySelection(path: "/configured", version: "2.50.1"))
        }
    }

    func testExecutedPreferenceRejectionSurvivesLaterBusyAdmission() {
        let release = DispatchSemaphore(value: 0)
        let drained = expectation(description: "All accepted occupied probes finish")
        drained.expectedFulfillmentCount = 17
        defer { for _ in 0 ..< 17 {
            release.signal()
        } }
        let runner = GitDiscoveryProbeRunner(factory: { path, _, _ in
            if path.hasPrefix("/occupied") {
                _ = release.wait(timeout: .now() + 10)
            }
            return .init(output: { nil }, cancel: {})
        })
        let filled = Mutex(false)
        let warnings = Mutex<[String]>([])
        let discovery = GitBinaryDiscovery(preference: { "/configured" }, environment: [:], locations: [], runner: runner,
                                           log: { message in
                                               if message.contains("Attempt /usr/bin/which"), filled.withLock({ let first = !$0; $0 = true; return first }) {
                                                   for index in 0 ..< 17 {
                                                       runner.run(path: "/occupied\(index)", arguments: [], timeout: 100) { _ in drained.fulfill() }
                                                   }
                                               }
                                           }, notify: {
                                               _, rejected in if let rejected {
                                                   warnings.withLock { $0.append(rejected) }
                                               }
                                           })
        let finished = expectation(description: "An executed rejection is retained when fallback admission is busy")
        discovery.whenAvailable { path, error in
            XCTAssertNil(path)
            XCTAssertEqual(error?.code, 3)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(warnings.withLock { $0 }, ["/configured"])
        for _ in 0 ..< 17 {
            release.signal()
        }
        wait(for: [drained], timeout: 3)
    }

    func testQueueExpiryDoesNotRejectOrFallbackFromAnUnexecutedPreference() {
        let clock = Clock()
        let entered = expectation(description: "Both slots stay owned")
        entered.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let calls = Mutex<[String]>([])
        let warnings = Mutex(0)
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { path, _, _ in
            calls.withLock { $0.append(path) }
            entered.fulfill(); _ = release.wait(timeout: .now() + 10)
            return .init(output: { nil }, cancel: {})
        })
        for index in 0 ..< 2 {
            runner.run(path: "/occupied\(index)", arguments: [], timeout: 100) { _ in }
        }
        wait(for: [entered], timeout: 3)
        let discovery = GitBinaryDiscovery(preference: { "/configured" }, environment: [:], locations: ["/fallback"], timing: clock.timing, runner: runner,
                                           notify: { _, _ in warnings.withLock { $0 += 1 } })
        let expired = expectation(description: "An unexecuted preference expires without becoming invalid")
        discovery.whenAvailable { path, error in XCTAssertNil(path); XCTAssertEqual(error?.code, 3); expired.fulfill() }
        clock.advance(5)
        wait(for: [expired], timeout: 3)
        XCTAssertEqual(calls.withLock { Set($0) }, Set(["/occupied0", "/occupied1"]))
        XCTAssertEqual(warnings.withLock { $0 }, 0)
    }

    func testCancelledAndExpiredQueueEntriesImmediatelyReleaseAdmissionCapacity() {
        let clock = Clock()
        let entered = expectation(description: "Two blocked factories retain both workers")
        entered.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { _, _, _ in
            entered.fulfill(); _ = release.wait(timeout: .now() + 10)
            return .init(output: { nil }, cancel: {})
        })
        for index in 0 ..< 2 {
            runner.run(path: "/occupied\(index)", arguments: [], timeout: 100) { _ in }
        }
        wait(for: [entered], timeout: 3)
        let results = Mutex<[String]>([])
        let queued = (0 ..< 16).map { index in
            runner.run(path: "/queued\(index)", arguments: [], timeout: index == 1 ? 1 : 100) { result in
                results.withLock { $0.append(String(describing: result)) }
            }
        }
        queued[0].cancel()
        clock.advance(1)
        for index in 0 ..< 2 {
            runner.run(path: "/replacement\(index)", arguments: [], timeout: 100) { result in
                results.withLock { $0.append(String(describing: result)) }
            }
        }
        XCTAssertEqual(results.withLock { $0 }, ["cancelled(started: false)", "timedOut(started: false)"])
        clock.advance(100)
        XCTAssertEqual(results.withLock { $0.count }, 18)
    }

    func testBusyDiscoveryPreservesPreferenceAndAllowsALaterDemandWithoutAnAutomaticLoop() {
        let clock = Clock()
        let entered = expectation(description: "Both owned workers are blocked")
        entered.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let warnings = Mutex(0)
        let calls = Mutex<[String]>([])
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { path, _, _ in
            calls.withLock { $0.append(path) }
            if path.hasPrefix("/occupied") {
                entered.fulfill(); _ = release.wait(timeout: .now() + 10)
            }
            return .init(output: { "git version 2.50.1" }, cancel: {})
        })
        for index in 0 ..< 2 {
            runner.run(path: "/occupied\(index)", arguments: [], timeout: 100) { _ in }
        }
        wait(for: [entered], timeout: 3)
        let drained = expectation(description: "All accepted independent probes drain")
        drained.expectedFulfillmentCount = 16
        for index in 0 ..< 16 {
            runner.run(path: "/queued\(index)", arguments: [], timeout: 100) { _ in drained.fulfill() }
        }
        let discovery = GitBinaryDiscovery(preference: { "/configured" }, environment: [:], locations: [], timing: clock.timing, runner: runner,
                                           notify: { _, _ in warnings.withLock { $0 += 1 } })
        let busy = expectation(description: "Cold discovery reports temporary unavailability")
        discovery.whenAvailable { path, error in XCTAssertNil(path); XCTAssertEqual(error?.code, 3); busy.fulfill() }
        wait(for: [busy], timeout: 3)
        XCTAssertFalse(discovery.accept("/direct")); XCTAssertNil(discovery.version(forPath: "/direct"))
        XCTAssertEqual(warnings.withLock { $0 }, 0)
        XCTAssertFalse(calls.withLock { $0.contains("/configured") || $0.contains("/direct") })
        release.signal(); release.signal()
        wait(for: [drained], timeout: 3)
        XCTAssertFalse(calls.withLock { $0.contains("/configured") }, "No background retry was scheduled")
        let ready = expectation(description: "A later demand validates the original preference")
        discovery.whenAvailable { path, error in XCTAssertEqual(path, "/configured"); XCTAssertNil(error); ready.fulfill() }
        wait(for: [ready], timeout: 3)
    }

    func testIndependentQueuedProbeDoesNotDisplaceDiscoveryOrItsFallback() {
        let clock = Clock()
        let occupied = expectation(description: "Both owned workers are blocked")
        occupied.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let calls = Mutex<[String]>([])
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { path, _, _ in
            calls.withLock { $0.append(path) }
            if path.hasPrefix("/occupied") {
                occupied.fulfill(); _ = release.wait(timeout: .now() + 10)
            }
            return .init(output: { path == "/healthy" ? "git version 2.50.1" : nil }, cancel: {})
        })
        for index in 0 ..< 2 {
            runner.run(path: "/occupied\(index)", arguments: [], timeout: 100) { _ in }
        }
        wait(for: [occupied], timeout: 3)
        let discovery = GitBinaryDiscovery(preference: { "/configured" }, environment: [:], locations: ["/healthy"], timing: clock.timing, runner: runner)
        let available = expectation(description: "Independent queued work preserves discovery and its healthy fallback")
        available.assertForOverFulfill = true
        discovery.whenAvailable { path, error in XCTAssertEqual(path, "/healthy"); XCTAssertNil(error); available.fulfill() }
        clock.elapse(4)
        // Independent accepted work retains its place while discovery advances.
        runner.run(path: "/interloper", arguments: [], timeout: 100) { _ in }
        release.signal(); release.signal()
        wait(for: [available], timeout: 3)
        clock.advance(30)
        let drained = expectation(description: "Expired timers cannot deliver a second callback")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 3)
        XCTAssertEqual(calls.withLock { $0.filter { $0 == "/healthy" }.count }, 1)
    }

    func testQueuedProbeExpiryKeepsTheOriginalAvailabilityDeadline() {
        let clock = Clock()
        let occupied = expectation(description: "Both worker slots remain owned")
        occupied.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { path, _, _ in
            if path.hasPrefix("/occupied") {
                occupied.fulfill(); _ = release.wait(timeout: .now() + 10)
            }
            return .init(output: { nil }, cancel: {})
        })
        for index in 0 ..< 2 {
            runner.run(path: "/occupied\(index)", arguments: [], timeout: 100) { _ in }
        }
        wait(for: [occupied], timeout: 3)
        let discovery = GitBinaryDiscovery(preference: { "/configured" }, environment: [:], locations: ["/healthy"], timing: clock.timing, runner: runner)
        let expired = expectation(description: "Queued work preserves the original thirty-second availability deadline")
        expired.assertForOverFulfill = true
        discovery.whenAvailable { path, error in XCTAssertNil(path); XCTAssertEqual(error?.code, 2); expired.fulfill() }
        clock.elapse(29)
        runner.run(path: "/interloper", arguments: [], timeout: 100) { _ in }
        clock.advance(1)
        wait(for: [expired], timeout: 3)
        XCTAssertNil(discovery.currentSelection)
    }

    func testColdAvailabilityCallbacksKeepTheirRequestOrder() {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let discovery = GitBinaryDiscovery(preference: { "/validated" }, environment: [:], output: { _, _ in
            _ = release.wait(timeout: .now() + 10)
            return "git version 2.50.1"
        })
        let order = Mutex<[Int]>([])
        let completed = expectation(description: "Each request finishes in registration order")
        completed.expectedFulfillmentCount = 3
        completed.assertForOverFulfill = true
        for index in 0 ..< 3 {
            discovery.whenAvailable { path, error in
                XCTAssertEqual(path, "/validated")
                XCTAssertNil(error)
                order.withLock { $0.append(index) }
                completed.fulfill()
            }
        }
        release.signal()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(order.withLock { $0 }, [0, 1, 2])
    }

    func testFailedReplacementRetainsTheActiveSelectionWithoutSearchingForAnotherFallback() {
        let fixture = Fixture(preference: "/old", outputs: ["/old": "git version 2.50.1"])
        let rejected = expectation(description: "Rejected replacement is observable")
        let discovery = fixture.discovery { selection, preference in
            if preference == "/invalid" {
                XCTAssertEqual(selection, GitBinarySelection(path: "/old", version: "2.50.1"))
                rejected.fulfill()
            }
        }
        XCTAssertTrue(discovery.accept("/old"))
        fixture.state.withLock { $0.preference = "/invalid" }
        let available = expectation(description: "The active executable stays available")
        discovery.whenAvailable { path, error in
            XCTAssertEqual(path, "/old")
            XCTAssertNil(error)
            available.fulfill()
        }
        wait(for: [available, rejected], timeout: 3)
        XCTAssertTrue(discovery.isReady)
        XCTAssertEqual(discovery.version, "2.50.1")
        XCTAssertEqual(fixture.state.withLock { $0.calls }, ["/old", "/invalid"])
    }

    func testExternalPreferenceChangeDuringAnAbortedSearchCannotClearTheCache() {
        let fixture = Fixture(preference: "/old", outputs: ["/old": "git version 2.50.1"])
        let completed = expectation(description: "The newest rejected preference settles")
        let discovery = GitBinaryDiscovery(preference: { fixture.state.withLock { $0.preference } }, environment: [:], output: { path, arguments in
            if path == "/aborted" {
                fixture.state.withLock { $0.preference = "/replacement" }
            }
            return fixture.output(path, arguments)
        }, locations: [], notify: { _, rejected in
            if rejected == "/replacement" {
                completed.fulfill()
            }
        })
        XCTAssertTrue(discovery.accept("/old"))
        fixture.state.withLock { $0.preference = "/aborted" }
        discovery.start()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(discovery.path, "/old")
        XCTAssertEqual(discovery.version, "2.50.1")
    }

    func testActiveSelectionRemainsAvailableWhileAValidReplacementWaits() {
        let fixture = Fixture(preference: "/old", outputs: ["/old": "git version 2.50.1", "/new": "git version 2.51.0"])
        let started = expectation(description: "Replacement probe started")
        let replaced = expectation(description: "Validated replacement published")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let discovery = GitBinaryDiscovery(preference: { fixture.state.withLock { $0.preference } }, environment: [:], output: { path, arguments in
            if path == "/new" {
                started.fulfill(); _ = release.wait(timeout: .now() + 10)
            }
            return fixture.output(path, arguments)
        }, notify: {
            selection, _ in if selection?.path == "/new" {
                replaced.fulfill()
            }
        })
        XCTAssertTrue(discovery.accept("/old"))
        fixture.state.withLock { $0.preference = "/new" }
        discovery.start()
        wait(for: [started], timeout: 3)
        let ready = expectation(description: "Availability does not wait for replacement validation")
        discovery.whenSelectionAvailable { selection, error in
            XCTAssertEqual(selection, GitBinarySelection(path: "/old", version: "2.50.1"))
            XCTAssertNil(error)
            ready.fulfill()
        }
        wait(for: [ready], timeout: 3)
        release.signal()
        wait(for: [replaced], timeout: 3)
        XCTAssertEqual(discovery.path, "/new")
    }

    func testOwnershipSnapshotIncludesAnInFlightPreferenceAfterAnExternalChange() {
        let preference = Mutex("/old")
        let entered = expectation(description: "The pending preference owns a running probe")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let discovery = GitBinaryDiscovery(preference: { preference.withLock { $0 } }, environment: [:], output: { path, _ in
            if path == "/pending" {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
            return "git version 2.50.1"
        })
        XCTAssertTrue(discovery.accept("/old"))
        preference.withLock { $0 = "/pending" }
        discovery.start()
        wait(for: [entered], timeout: 3)
        preference.withLock { $0 = "/outside" }
        let paths = discovery.referencedExecutablePaths
        XCTAssertTrue(paths.contains("/old"))
        XCTAssertTrue(paths.contains("/pending"), "An external preference write cannot hide an owned in-flight executable")
        let finished = expectation(description: "The obsolete probe cannot publish its selection")
        discovery.whenAvailable { selection, error in
            XCTAssertNotNil(selection)
            XCTAssertNotEqual(selection, "/pending")
            XCTAssertNil(error)
            finished.fulfill()
        }
        release.signal()
        wait(for: [finished], timeout: 3)
    }

    func testColdDeadlineSettlesWhileFactoryAndCancellationCannotReturn() {
        let clock = Clock()
        let entered = expectation(description: "Probe factory entered its owned worker")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { _, _, _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 10)
            return .init(output: { XCTFail("Expired factory must not launch its command"); return nil }, cancel: {})
        })
        let discovery = GitBinaryDiscovery(preference: { "/stalled" }, environment: [:], locations: [], timing: clock.timing, runner: runner)
        let settled = expectation(description: "Deadline does not await the blocked worker")
        settled.assertForOverFulfill = true
        discovery.whenAvailable { path, error in
            XCTAssertNil(path)
            XCTAssertEqual(error?.code, 2)
            XCTAssertTrue(error?.localizedFailureReason?.contains("/stalled") == true)
            settled.fulfill()
        }
        wait(for: [entered], timeout: 3)
        clock.advance(30)
        wait(for: [settled], timeout: 3)
        XCTAssertNil(discovery.currentSelection)
    }

    func testPreferenceSupersessionDoesNotRenewAnExistingAvailabilityDeadline() {
        let clock = Clock()
        let fixture = Fixture(preference: "/first")
        let firstEntered = expectation(description: "First generation owns a worker")
        let entered = expectation(description: "Second generation owns the other worker")
        let release = DispatchSemaphore(value: 0)
        defer { clock.advance(60); release.signal(); release.signal() }
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { path, _, _ in
            if path == "/first" {
                firstEntered.fulfill()
            } else if path == "/second" {
                entered.fulfill()
            }
            _ = release.wait(timeout: .now() + 10)
            return .init(output: { nil }, cancel: {})
        })
        let discovery = GitBinaryDiscovery(preference: { fixture.state.withLock { $0.preference } }, environment: [:], locations: [], timing: clock.timing, runner: runner)
        let expired = expectation(description: "Original caller expires at second 30")
        expired.assertForOverFulfill = true
        discovery.whenAvailable { path, error in XCTAssertNil(path); XCTAssertEqual(error?.code, 2); expired.fulfill() }
        wait(for: [firstEntered], timeout: 3)
        clock.elapse(29)
        fixture.state.withLock { $0.preference = "/second" }
        discovery.start()
        wait(for: [entered], timeout: 3)
        clock.advance(1)
        wait(for: [expired], timeout: 3)
    }

    func testProbeTimeoutCanSelectAHealthyColdLaunchFallback() {
        let clock = Clock()
        let entered = expectation(description: "Configured executable is stalled")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { path, _, _ in
            .init(output: {
                if path == "/stalled" {
                    entered.fulfill(); _ = release.wait(timeout: .now() + 10)
                }
                return path == "/healthy" ? "git version 2.50.1" : nil
            }, cancel: {})
        })
        let discovery = GitBinaryDiscovery(preference: { "/stalled" }, environment: [:], locations: ["/healthy"], timing: clock.timing, runner: runner)
        let ready = expectation(description: "Fallback validates after the five-second probe budget")
        discovery.whenAvailable { path, error in XCTAssertEqual(path, "/healthy"); XCTAssertNil(error); ready.fulfill() }
        wait(for: [entered], timeout: 3)
        clock.advance(5)
        wait(for: [ready], timeout: 3)
    }

    func testProbeRunnerBoundsStalledFactoriesAndCompletesEverySupersededRequestOnce() {
        let clock = Clock()
        let entered = expectation(description: "Only two worker slots are admitted")
        entered.expectedFulfillmentCount = 2
        entered.assertForOverFulfill = true
        let count = Mutex(0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { _, _, _ in
            count.withLock { $0 += 1 }
            entered.fulfill()
            _ = release.wait(timeout: .now() + 10)
            return .init(output: { XCTFail("Expired probes cannot run"); return nil }, cancel: {})
        })
        let completed = expectation(description: "All requests finish exactly once")
        completed.expectedFulfillmentCount = 80
        completed.assertForOverFulfill = true
        for _ in 0 ..< 80 {
            runner.run(path: "/stalled", arguments: [], timeout: 5) { _ in completed.fulfill() }
        }
        wait(for: [entered], timeout: 3)
        clock.advance(5)
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(count.withLock { $0 }, 2)
    }

    func testColdExhaustionCanBeRetriedExplicitlyWithoutBackgroundRetryLoops() {
        let fixture = Fixture(preference: "/missing")
        let discovery = fixture.discovery()
        let first = expectation(description: "Initial failure")
        discovery.whenAvailable { path, error in XCTAssertNil(path); XCTAssertEqual(error?.code, 1); first.fulfill() }
        wait(for: [first], timeout: 3)
        let count = fixture.state.withLock { $0.calls.count }
        let cached = expectation(description: "Background request receives the existing failure")
        discovery.whenAvailable { _, _ in cached.fulfill() }
        wait(for: [cached], timeout: 3)
        XCTAssertEqual(fixture.state.withLock { $0.calls.count }, count)
        discovery.start(retryingFailure: true)
        let retried = expectation(description: "Explicit retry completes")
        discovery.whenAvailable { _, _ in retried.fulfill() }
        wait(for: [retried], timeout: 3)
        XCTAssertGreaterThan(fixture.state.withLock { $0.calls.count }, count)
    }

    func testLateProbeOutputIsRejectedEvenWhenItsTimerHasNotFired() {
        let clock = Clock()
        let entered = expectation(description: "Late probe entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { path, _, _ in
            .init(output: {
                if path == "/late" {
                    entered.fulfill(); _ = release.wait(timeout: .now() + 10)
                }
                return path == "/late" || path == "/healthy" ? "git version 2.50.1" : nil
            }, cancel: {})
        })
        let discovery = GitBinaryDiscovery(preference: { "/late" }, environment: [:], locations: ["/healthy"], timing: clock.timing, runner: runner)
        let ready = expectation(description: "A timely fallback replaces late output")
        discovery.whenAvailable { path, error in XCTAssertEqual(path, "/healthy"); XCTAssertNil(error); ready.fulfill() }
        wait(for: [entered], timeout: 3)
        clock.elapse(6)
        release.signal()
        wait(for: [ready], timeout: 3)
    }

    func testAnExpiredWaiterCannotBeRevivedByAnExplicitSelection() {
        let clock = Clock()
        let entered = expectation(description: "Initial validation entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let discovery = GitBinaryDiscovery(preference: { "/old" }, environment: [:], output: { path, _ in
            if path == "/old" {
                entered.fulfill(); _ = release.wait(timeout: .now() + 10)
            }
            return "git version 2.50.1"
        }, timing: clock.timing)
        let expired = expectation(description: "The original request keeps its deadline")
        discovery.whenAvailable { path, error in XCTAssertNil(path); XCTAssertEqual(error?.code, 2); expired.fulfill() }
        wait(for: [entered], timeout: 3)
        clock.elapse(31)
        XCTAssertTrue(discovery.accept("/new"))
        wait(for: [expired], timeout: 3)
        XCTAssertEqual(discovery.path, "/new", "Explicit selection remains valid for subsequent operations")
    }

    func testBlockedCancellationDoesNotDelayTheAvailabilityDeadline() {
        let clock = Clock()
        let entered = expectation(description: "Probe is running")
        let cancellation = expectation(description: "Cancellation worker is blocked")
        let releaseOutput = DispatchSemaphore(value: 0)
        let releaseCancellation = DispatchSemaphore(value: 0)
        defer { releaseOutput.signal(); releaseCancellation.signal() }
        let runner = GitDiscoveryProbeRunner(timing: clock.timing, factory: { _, _, _ in
            .init(output: { entered.fulfill(); _ = releaseOutput.wait(timeout: .now() + 10); return nil },
                  cancel: { cancellation.fulfill(); _ = releaseCancellation.wait(timeout: .now() + 10) })
        })
        let discovery = GitBinaryDiscovery(preference: { "/blocked" }, environment: [:], locations: [], timing: clock.timing, runner: runner)
        let ready = expectation(description: "Deadline completes before cancellation returns")
        discovery.whenAvailable { path, error in XCTAssertNil(path); XCTAssertEqual(error?.code, 2); ready.fulfill() }
        wait(for: [entered], timeout: 3)
        clock.advance(30)
        wait(for: [ready, cancellation], timeout: 3)
    }

    func testLiveProbeCancellationReapsItsOwnedProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let completed = expectation(description: "The actual PBTask probe times out")
        let runner = GitDiscoveryProbeRunner()
        runner.run(path: "/bin/sh", arguments: ["-c", "echo $$ > '\(pidFile.path)'; exec /bin/sleep 30"], timeout: 1) { result in
            guard case .timedOut = result else { XCTFail("Stalled probe must time out"); completed.fulfill(); return }
            completed.fulfill()
        }
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: pidFile.path) }, object: nil)
        wait(for: [started, completed], timeout: 4)
        let pid = try XCTUnwrap(try Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let reaped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in kill(pid, 0) == -1 && errno == ESRCH }, object: nil)
        wait(for: [reaped], timeout: 4)
    }

    @MainActor func testDiscoveryWaitPolicyMergesImmediateRequestsAndKeepsNewLifecyclesIndependent() {
        var policy = AutoFetchDiscoveryWaitState()
        policy.begin(generation: 3, immediate: false)
        for _ in 0 ..< 120 {
            XCTAssertTrue(policy.mergeIfWaiting(generation: 3, immediate: false))
        }
        XCTAssertTrue(policy.mergeIfWaiting(generation: 3, immediate: true))
        XCTAssertFalse(policy.mergeIfWaiting(generation: 4, immediate: false))
        XCTAssertNil(policy.finish(generation: 4))
        XCTAssertEqual(policy.finish(generation: 3), true)
        XCTAssertNil(policy.finish(generation: 3))
        policy.begin(generation: 4, immediate: false)
        XCTAssertNil(policy.finish(generation: 3))
        XCTAssertEqual(policy.finish(generation: 4), false)
        policy.begin(generation: 5, immediate: true)
        policy.cancel()
        XCTAssertNil(policy.finish(generation: 5))
    }
}

@MainActor
final class GitDiscoveryPresentationTests: XCTestCase {
    private final class ParentWindow: NSWindow {
        var available = true
        override var isVisible: Bool {
            available
        }

        override var canBecomeKey: Bool {
            true
        }
    }

    func testWarningWaitsForAWindowAndNeverBlocksReadinessOrMainQueueWork() {
        let center = NotificationCenter()
        let parent = ParentWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        parent.available = false
        var presentations: [NSAlert] = []
        var completions: [(NSApplication.ModalResponse) -> Void] = []
        let presenter = GitBinaryDiscoveryPresenter(center: center, windows: { [parent] }, presentSheet: { alert, window, completion in
            XCTAssertTrue(window === parent)
            presentations.append(alert)
            completions.append(completion)
        })
        let selection = GitBinarySelection(path: "/validated", version: "2.50.1")
        presenter.publish(selection: selection, rejected: "/invalid")
        XCTAssertTrue(presentations.isEmpty)
        parent.available = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: parent)
        XCTAssertEqual(presentations.count, 1)
        XCTAssertTrue(presentations[0].informativeText.contains("/validated"))
        let responsive = expectation(description: "A pending warning does not block the main queue")
        DispatchQueue.main.async { responsive.fulfill() }
        wait(for: [responsive], timeout: 3)
        presenter.publish(selection: selection, rejected: "/invalid")
        XCTAssertEqual(presentations.count, 1)
        completions[0](.alertFirstButtonReturn)
        center.post(name: NSWindow.didBecomeMainNotification, object: parent)
        XCTAssertEqual(presentations.count, 1, "A dismissed warning is deduplicated")
    }

    func testObsoleteQueuedWarningsAreDiscardedAndSelectionNotificationsAreDeduplicated() {
        let center = NotificationCenter()
        let parent = ParentWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        parent.available = false
        var warnings: [String] = []
        let changes = Mutex(0)
        let observer = center.addObserver(forName: .PBGitBinaryDidChange, object: nil, queue: nil) { _ in changes.withLock { $0 += 1 } }
        defer { center.removeObserver(observer) }
        let presenter = GitBinaryDiscoveryPresenter(center: center, windows: { [parent] }, presentSheet: { alert, _, _ in warnings.append(alert.informativeText) })
        let first = GitBinarySelection(path: "/first", version: "2.50.1")
        let second = GitBinarySelection(path: "/second", version: "2.51.0")
        presenter.publish(selection: first, rejected: "/invalid")
        presenter.invalidateWarning()
        presenter.publish(selection: second, rejected: nil)
        presenter.publishSelection(second)
        parent.available = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: parent)
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(changes.withLock { $0 }, 2)
        presenter.publish(selection: second, rejected: "")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("Automatic Git discovery"))
        XCTAssertTrue(warnings[0].contains("/second"))
        presenter.invalidateWarning()
    }

    func testSelectionNotificationCannotPresentThePreviousPendingWarning() {
        let center = NotificationCenter()
        let parent = ParentWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        parent.available = false
        let warnings = Mutex<[String]>([])
        let presenter = GitBinaryDiscoveryPresenter(center: center, windows: { [parent] }, presentSheet: { alert, _, _ in warnings.withLock { $0.append(alert.informativeText) } })
        presenter.publish(selection: nil, rejected: "/obsolete")
        let observer = center.addObserver(forName: .PBGitBinaryDidChange, object: nil, queue: nil) { _ in
            center.post(name: NSWindow.didBecomeKeyNotification, object: parent)
        }
        defer { center.removeObserver(observer); presenter.invalidateWarning() }
        parent.available = true
        presenter.publish(selection: GitBinarySelection(path: "/validated", version: "2.50.1"), rejected: "/current")
        XCTAssertEqual(warnings.withLock { $0.count }, 1)
        XCTAssertTrue(warnings.withLock { $0.allSatisfy { $0.contains("/current") && !$0.contains("/obsolete") } })
    }

    func testWarningDismissalReentrancySeesOnlyTheCommittedReplacement() {
        let center = NotificationCenter()
        let parent = ParentWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        var warnings: [String] = []
        var completions: [(NSApplication.ModalResponse) -> Void] = []
        let presenter = GitBinaryDiscoveryPresenter(center: center, windows: { [parent] }, presentSheet: { alert, _, complete in
            warnings.append(alert.informativeText); completions.append(complete)
        }, dismissSheet: { _ in center.post(name: NSWindow.didEndSheetNotification, object: parent) })
        presenter.publish(selection: nil, rejected: "/obsolete")
        presenter.publish(selection: GitBinarySelection(path: "/valid", version: "2.50.1"), rejected: "/current")
        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings.last?.contains("/current") == true)
        completions[0](.alertFirstButtonReturn)
        center.post(name: NSWindow.didBecomeKeyNotification, object: parent)
        XCTAssertEqual(warnings.count, 2)
        presenter.publish(selection: GitBinarySelection(path: "/valid", version: "2.50.1"), rejected: nil)
        XCTAssertEqual(warnings.count, 2, "Successful replacement cannot re-present the dismissed warning")
    }

    func testInterruptedWarningsRecurAndStaleCompletionsCannotAcknowledgeANewerPresentation() {
        let center = NotificationCenter()
        let parent = ParentWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        var completions: [(NSApplication.ModalResponse) -> Void] = []
        let presenter = GitBinaryDiscoveryPresenter(center: center, windows: { [parent] }, presentSheet: { _, _, complete in completions.append(complete) })
        let selection = GitBinarySelection(path: "/validated", version: "2.50.1")
        presenter.publish(selection: selection, rejected: "/invalid")
        XCTAssertEqual(completions.count, 1)
        presenter.invalidateWarning()
        presenter.publish(selection: selection, rejected: "/invalid")
        XCTAssertEqual(completions.count, 2, "Programmatic dismissal must not acknowledge a warning")
        guard completions.count == 2 else { return }
        completions[0](.alertFirstButtonReturn)
        presenter.publish(selection: selection, rejected: "/different")
        XCTAssertEqual(completions.count, 3)
        completions[1](.abort)
        center.post(name: NSWindow.didBecomeKeyNotification, object: parent)
        XCTAssertEqual(completions.count, 3, "A stale completion must not clear the active presentation")
        completions[2](.alertFirstButtonReturn)
        presenter.invalidateWarning()
        presenter.publish(selection: selection, rejected: "/different")
        XCTAssertEqual(completions.count, 3, "An acknowledged unchanged warning stays deduplicated across revalidation")
        presenter.publish(selection: selection, rejected: nil)
        presenter.publish(selection: selection, rejected: "/different")
        XCTAssertEqual(completions.count, 4, "Successful validation clears acknowledgement")
        presenter.invalidateWarning()
    }

    func testAbortedPresentationWaitsForAnAvailableOwnerAndCanRecur() {
        let center = NotificationCenter()
        let parent = ParentWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        var completions: [(NSApplication.ModalResponse) -> Void] = []
        let presenter = GitBinaryDiscoveryPresenter(center: center, windows: { [parent] }, presentSheet: { _, _, complete in completions.append(complete) })
        presenter.publish(selection: nil, rejected: "/invalid")
        XCTAssertEqual(completions.count, 1)
        parent.available = false
        completions[0](.abort)
        center.post(name: NSWindow.didBecomeMainNotification, object: parent)
        XCTAssertEqual(completions.count, 1)
        parent.available = true
        center.post(name: NSWindow.didBecomeMainNotification, object: parent)
        XCTAssertEqual(completions.count, 2, "Aborted presentation remains unacknowledged")
        presenter.invalidateWarning()
    }

    func testSharedPresentationSuppressesHostedTestsWhileExplicitInstancesRemainEnabled() {
        XCTAssertFalse(GitDiscoveryWarningPolicy.shouldPresentAutomatically(environment: ["XCTestConfigurationFilePath": "/hosted.xctestconfiguration"]))
        XCTAssertTrue(GitDiscoveryWarningPolicy.shouldPresentAutomatically(environment: [:]))
        XCTAssertTrue(GitDiscoveryWarningPolicy.shouldPresentAutomatically(environment: ["GITX_UITEST_REPO": "/fixture"]))
        XCTAssertFalse(GitBinaryDiscoveryPresenter.shared.automaticPresentationEnabled)
        let center = NotificationCenter()
        let parent = ParentWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let changes = Mutex(0)
        let observer = center.addObserver(forName: .PBGitBinaryDidChange, object: nil, queue: nil) { _ in changes.withLock { $0 += 1 } }
        defer { center.removeObserver(observer) }
        let disabled = GitBinaryDiscoveryPresenter(center: center, windows: { [parent] }, automaticPresentationEnabled: false,
                                                   presentSheet: { _, _, _ in XCTFail("Hosted-test suppression must not present sheets") })
        disabled.publish(selection: GitBinarySelection(path: "/validated", version: "2.50.1"), rejected: "/invalid")
        center.post(name: NSWindow.didBecomeKeyNotification, object: parent)
        XCTAssertEqual(changes.withLock { $0 }, 1, "Sheet suppression must preserve discovery notifications")
        var presented = false
        let explicit = GitBinaryDiscoveryPresenter(center: center, windows: { [parent] }, presentSheet: { _, _, _ in presented = true })
        explicit.publish(selection: nil, rejected: "/invalid")
        XCTAssertTrue(presented, "Explicit instances retain real injectable presentation in hosted tests")
        explicit.invalidateWarning()
    }

    func testAvailabilityCallbacksRunBeforeAnIndependentWarningObserver() {
        let order = Mutex<[String]>([])
        let completed = expectation(description: "Availability and notification both finish")
        completed.expectedFulfillmentCount = 2
        let discovery = GitBinaryDiscovery(preference: { "/invalid" }, environment: [:], output: { path, _ in
            path == "/known" ? "git version 2.50.1" : nil
        }, locations: ["/known"], notify: { _, rejected in
            XCTAssertEqual(rejected, "/invalid")
            order.withLock { $0.append("warning") }
            completed.fulfill()
        })
        discovery.whenAvailable { path, error in
            XCTAssertEqual(path, "/known")
            XCTAssertNil(error)
            order.withLock { $0.append("available") }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(order.withLock { $0 }, ["available", "warning"])
    }
}

final class AutoFetchGitSelectionTests: XCTestCase {
    // swift6-safety-justification: Evaluation state stays on MainActor; inherited lifecycle fields use the manager's lock.
    private final nonisolated class EvaluationProbe: GitX.PBAutoFetchManager, @unchecked Sendable {
        @MainActor var evaluations = 0
        @MainActor override func candidateRepositoryURLs() -> [String: URL] {
            evaluations += 1; return [:]
        }
    }

    // swift6-safety-justification: Configuration is immutable, recorded paths use Mutex, and inherited lifecycle state uses the manager's lock.
    private final nonisolated class FetchProbe: GitX.PBAutoFetchManager, @unchecked Sendable {
        let discovery: GitBinaryDiscovery
        let replacement: String
        let paths = Mutex<[String]>([])
        init(discovery: GitBinaryDiscovery, replacement: String) {
            self.discovery = discovery
            self.replacement = replacement
            super.init(gitDiscovery: discovery)
        }

        override func task(forRepositoryURL url: URL, arguments: [String]) -> PBTask {
            let task = super.task(forRepositoryURL: url, arguments: arguments)
            GitXTestGitFixture.prepare(task)
            let first = paths.withLock { paths in paths.append(task.value(forKey: "launchPath") as? String ?? "missing"); return paths.count == 1 }
            if first {
                XCTAssertTrue(discovery.accept(replacement))
            }
            return task
        }
    }

    @MainActor func testRepeatedTimerRequestsInstallOneWaiterAndOneEvaluation() {
        let previous = UserDefaults.standard.object(forKey: "PBAutoFetchScope")
        UserDefaults.standard.set(2, forKey: "PBAutoFetchScope")
        defer { UserDefaults.standard.set(previous, forKey: "PBAutoFetchScope") }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let discovery = GitBinaryDiscovery(preference: { "/delayed" }, environment: [:], output: { _, _ in
            _ = release.wait(timeout: .now() + 10)
            return "git version 2.50.1"
        })
        let manager = EvaluationProbe(gitDiscovery: discovery)
        defer { manager.stop() }
        for _ in 0 ..< 120 {
            manager.evaluateRepositoriesForImmediateFetch(false)
        }
        manager.evaluateRepositoriesForImmediateFetch(true)
        XCTAssertEqual(manager.evaluations, 0)
        let complete = expectation(description: "Discovery and the one pending evaluation finish")
        discovery.whenAvailable { _, _ in
            DispatchQueue.main.async { complete.fulfill() }
        }
        release.signal()
        wait(for: [complete], timeout: 3)
        XCTAssertEqual(manager.evaluations, 1)
    }

    @MainActor func testStopAndRestartRevokeTheOldWaiterWithoutConsumingTheNewOne() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "PBAutoFetchScope")
        defer { defaults.set(previous, forKey: "PBAutoFetchScope") }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let discovery = GitBinaryDiscovery(preference: { "/delayed" }, environment: [:], output: { _, _ in
            _ = release.wait(timeout: .now() + 10)
            return "git version 2.50.1"
        })
        let manager = EvaluationProbe(gitDiscovery: discovery)
        defer { manager.stop() }
        // Starting with scope=none avoids unrelated notification authorization.
        defaults.set(0, forKey: "PBAutoFetchScope")
        manager.start()
        defaults.set(2, forKey: "PBAutoFetchScope")
        manager.evaluateRepositoriesForImmediateFetch(false)
        manager.stop()
        defaults.set(0, forKey: "PBAutoFetchScope")
        manager.start()
        defaults.set(2, forKey: "PBAutoFetchScope")
        manager.evaluateRepositoriesForImmediateFetch(true)
        let completed = expectation(description: "Only the restarted manager generation evaluates")
        discovery.whenAvailable { _, _ in DispatchQueue.main.async { completed.fulfill() } }
        release.signal()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(manager.evaluations, 1)
    }

    @MainActor func testActualFetchCommandsKeepTheirInjectedSelectionAfterItChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try GTRepository.initializeEmpty(atFileURL: repository, options: nil)
        let log = directory.appendingPathComponent("commands")
        let old = directory.appendingPathComponent("old-git")
        let new = directory.appendingPathComponent("new-git")
        for (path, label) in [(old, "old"), (new, "new")] {
            // UUID fixture paths contain no shell metacharacters.
            try "#!/bin/sh\nprintf '\(label)\\n' >> '\(log.path)'\nexec /usr/bin/git \"$@\"\n".write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        let discovery = GitBinaryDiscovery(preference: { nil }, environment: [:], output: { _, _ in "git version 2.50.1" })
        XCTAssertTrue(discovery.accept(old.path))
        let manager = FetchProbe(discovery: discovery, replacement: new.path)
        manager.fetchRepository(at: repository, key: repository.path, generation: 0)
        let drained = expectation(description: "Fetch publication drains before fixture removal")
        DispatchQueue.main.async { manager.stop(); drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(discovery.path, new.path)
        XCTAssertEqual(manager.paths.withLock { $0 }, [old.path, old.path, old.path])
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "old\nold\nold\n")
    }
}

final class RepositoryScriptOpenPolicyTests: XCTestCase {
    func testOptionsUseLiteralExpectedActionsFiltersAndOrderedRevisionArguments() {
        let cases: [([String], RepositoryScriptOpenOptions.Action, Int?, [String])] = [
            ([], .none, nil, []),
            (["-c", "HEAD"], .commit, nil, []),
            (["--commit"], .commit, nil, []),
            (["--all"], .history, 0, []),
            (["--local", "topic"], .history, 1, ["topic"]),
            (["--branch", "--max-count=7", "HEAD"], .history, 2, ["--max-count=7", "HEAD"]),
            (["topic"], .history, nil, ["topic"]),
            (["--max-count=7", "HEAD"], .history, nil, ["--max-count=7", "HEAD"]),
        ]
        for (arguments, action, filter, revisions) in cases {
            let result = RepositoryScriptOpenOptions(arguments)
            XCTAssertEqual(result.action, action)
            XCTAssertEqual(result.branchFilter, filter)
            XCTAssertEqual(result.revisions, revisions)
        }
        XCTAssertTrue(RepositoryScriptOpenOptionsBridge(arguments: nil).isEmpty)
    }
}

final class RepositoryGitLoaderLifecycleTests: XCTestCase {
    func testInstallationRequiresBothLoadersAndRejectsReplacedGenerationsAndRepositories() {
        let firstOwner = NSObject()
        let secondOwner = NSObject()
        let first = RepositoryGitLoaderLifecycle.Identity(repository: ObjectIdentifier(firstOwner), selection: .init(path: "/first", version: "2.50.1"))
        let second = RepositoryGitLoaderLifecycle.Identity(repository: ObjectIdentifier(secondOwner), selection: first.selection)
        let replacement = RepositoryGitLoaderLifecycle.Identity(repository: first.repository, selection: .init(path: "/second", version: "2.51.0"))
        var policy = RepositoryGitLoaderLifecycle()
        XCTAssertTrue(policy.requiresInstallation(first, hasFocus: true, hasStatus: true))
        policy.didInstall(first)
        let original = policy.generation
        XCTAssertFalse(policy.requiresInstallation(first, hasFocus: true, hasStatus: true))
        XCTAssertTrue(policy.requiresInstallation(first, hasFocus: false, hasStatus: true))
        XCTAssertTrue(policy.requiresInstallation(first, hasFocus: true, hasStatus: false))
        XCTAssertTrue(policy.requiresInstallation(second, hasFocus: true, hasStatus: true))
        XCTAssertTrue(policy.requiresInstallation(replacement, hasFocus: true, hasStatus: true))
        XCTAssertTrue(policy.accepts(generation: original, identity: first))
        XCTAssertFalse(policy.accepts(generation: original, identity: second))
        policy.invalidate()
        XCTAssertFalse(policy.accepts(generation: original, identity: first))
        policy.didInstall(replacement)
        XCTAssertFalse(policy.accepts(generation: original, identity: replacement))
        XCTAssertTrue(policy.accepts(generation: policy.generation, identity: replacement))
    }
}

final class RepositoryWindowOwnershipTests: XCTestCase {
    func testEveryOwnerChangeRevokesPreviousResultsAndCloseIsTerminal() {
        let repository = NSObject()
        let otherRepository = NSObject()
        let window = NSObject()
        let otherWindow = NSObject()
        let document = NSObject()
        let initial = RepositoryWindowOwnership.Identity(repository: ObjectIdentifier(repository), window: ObjectIdentifier(window), document: nil)
        var policy = RepositoryWindowOwnership()
        XCTAssertNil(policy.identity)
        policy.install(initial)
        let generation = policy.generation
        XCTAssertTrue(policy.accepts(initial, generation: generation))
        for replacement in [
            RepositoryWindowOwnership.Identity(repository: ObjectIdentifier(otherRepository), window: ObjectIdentifier(window), document: nil),
            RepositoryWindowOwnership.Identity(repository: ObjectIdentifier(repository), window: ObjectIdentifier(otherWindow), document: nil),
            RepositoryWindowOwnership.Identity(repository: ObjectIdentifier(repository), window: ObjectIdentifier(window), document: ObjectIdentifier(document)),
        ] {
            XCTAssertFalse(policy.accepts(replacement, generation: generation))
            policy.revoke()
            XCTAssertNil(policy.identity)
            XCTAssertFalse(policy.accepts(initial, generation: generation))
            policy.install(replacement)
            XCTAssertTrue(policy.accepts(replacement, generation: policy.generation))
        }
        policy.revoke()
        policy.install(initial)
        XCTAssertFalse(policy.accepts(initial, generation: generation), "Restoring the same objects cannot restore old consent")
        policy.revoke(closing: true)
        policy.install(initial)
        XCTAssertTrue(policy.closed)
        XCTAssertNil(policy.identity)
        XCTAssertFalse(policy.accepts(initial, generation: policy.generation))
        policy.revoke()
        XCTAssertTrue(policy.closed)
    }

    func testExecutionEvidenceDoesNotTreatQueueOutcomesAsExecutedFailures() {
        XCTAssertFalse(GitDiscoveryProbeResult.busy.executionBegan)
        XCTAssertFalse(GitDiscoveryProbeResult.cancelled(started: false).executionBegan)
        XCTAssertFalse(GitDiscoveryProbeResult.timedOut(started: false).executionBegan)
        XCTAssertTrue(GitDiscoveryProbeResult.cancelled(started: true).executionBegan)
        XCTAssertTrue(GitDiscoveryProbeResult.timedOut(started: true).executionBegan)
        XCTAssertTrue(GitDiscoveryProbeResult.output(nil).executionBegan)
    }
}

@MainActor
final class RepositoryGitDirectoryIdentityTests: XCTestCase {
    func testOneDecisionReusesSuccessfulAndMissingLookupsButANewDecisionRevalidates() {
        let root = URL(fileURLWithPath: "/fixture/repository")
        let missing = URL(fileURLWithPath: "/fixture/missing")
        var calls: [URL] = []
        var gitDirectory = root.appendingPathComponent(".git")
        var decision = RepositoryGitDirectoryIdentity { url in calls.append(url); return url == root ? gitDirectory : nil }
        XCTAssertEqual(decision.discover(for: root), gitDirectory)
        gitDirectory = root.appendingPathComponent("replacement.git")
        XCTAssertEqual(decision.discover(for: root), root.appendingPathComponent(".git"))
        XCTAssertNil(decision.discover(for: missing))
        XCTAssertNil(decision.discover(for: missing))
        XCTAssertEqual(calls, [root, missing])
        var afterWait = RepositoryGitDirectoryIdentity { url in calls.append(url); return gitDirectory }
        XCTAssertEqual(afterWait.discover(for: root), gitDirectory)
        XCTAssertEqual(calls, [root, missing, root])
        XCTAssertNil(RepositoryGitDirectoryIdentity.normalized(nil))
    }
}
