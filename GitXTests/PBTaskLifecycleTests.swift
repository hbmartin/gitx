import Darwin
import XCTest

final class PBTaskLifecycleTests: XCTestCase {
    private func temporaryFileURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gitx-pbtask-\(UUID().uuidString)-\(name)")
    }

    func testParentExitSucceedsWhenDescendantKeepsOutputPipeOpen() {
        let task = PBTask(
            launchPath: "/bin/sh",
            arguments: ["-c", "printf parent-complete; (/bin/sleep 1) &"],
            inDirectory: nil
        )
        task.timeout = 0.35

        XCTAssertNoThrow(try task.launch())
        XCTAssertEqual(task.standardOutputString(), "parent-complete")
    }

    func testTerminationHandlerUsesRequestedQueue() {
        let completion = expectation(description: "termination callback")
        let queue = DispatchQueue(label: "org.gitx.tests.pbtask-termination")
        let queueKey = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: queueKey, value: true)
        let task = PBTask(
            launchPath: "/usr/bin/true",
            arguments: [],
            inDirectory: nil
        )

        task.perform(on: queue) { error in
            XCTAssertNil(error)
            XCTAssertEqual(DispatchQueue.getSpecific(key: queueKey), true)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
    }

    func testCompletionObservesMergedOutputInWriteOrderIncludingFinalByte() {
        let completion = expectation(description: "output callback")
        let queue = DispatchQueue(label: "org.gitx.tests.pbtask-output")
        let task = PBTask(
            launchPath: "/bin/sh",
            arguments: [
                "-c",
                "printf 'stdout-one'; printf 'stderr-two' >&2; printf 'terminal-byte'",
            ],
            inDirectory: nil
        )

        task.perform(on: queue) { data, error in
            XCTAssertNil(error)
            XCTAssertEqual(data, Data("stdout-onestderr-twoterminal-byte".utf8))
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
        XCTAssertEqual(task.standardOutputData, Data("stdout-onestderr-twoterminal-byte".utf8))
    }

    func testRawStandardOutputDataPreservesInvalidUTF8() {
        let task = PBTask(
            launchPath: "/bin/sh",
            arguments: ["-c", "printf '\\377'"],
            inDirectory: nil
        )

        XCTAssertNoThrow(try task.launch())
        XCTAssertEqual(task.standardOutputData, Data([0xFF]))
        XCTAssertNil(task.standardOutputString())
    }

    func testFailureCompletionFollowsCompleteMergedOutput() {
        let completion = expectation(description: "failure callback")
        let queue = DispatchQueue(label: "org.gitx.tests.pbtask-failure-output")
        let queueKey = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: queueKey, value: true)
        let task = PBTask(
            launchPath: "/bin/sh",
            arguments: [
                "-c",
                "printf 'stdout-one'; printf 'stderr-two' >&2; printf 'terminal-byte'; exit 17",
            ],
            inDirectory: nil
        )

        task.perform(on: queue) { data, error in
            XCTAssertNil(data)
            XCTAssertEqual(DispatchQueue.getSpecific(key: queueKey), true)
            let taskError = error as NSError?
            XCTAssertEqual(taskError?.domain, PBTaskErrorDomain)
            XCTAssertEqual(taskError?.code, Int(PBTaskErrorCode.nonZeroExitCodeError.rawValue))
            XCTAssertEqual(taskError?.userInfo[PBTaskTerminationStatusKey] as? NSNumber, 17)
            XCTAssertEqual(
                taskError?.userInfo[PBTaskTerminationOutputKey] as? String,
                "stdout-onestderr-twoterminal-byte"
            )
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
    }

    func testTerminationBeforeLaunchReturnsCancellationError() {
        let task = PBTask(
            launchPath: "/usr/bin/true",
            arguments: [],
            inDirectory: nil
        )
        task.terminate()

        XCTAssertThrowsError(try task.launch()) { error in
            let cancellationError = error as NSError
            XCTAssertEqual(cancellationError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(cancellationError.code, NSUserCancelledError)
        }
    }

    func testParentFailureWinsWhenDescendantKeepsOutputPipeOpen() {
        let task = PBTask(
            launchPath: "/bin/sh",
            arguments: ["-c", "printf parent-failure >&2; (/bin/sleep 1) & exit 23"],
            inDirectory: nil
        )
        task.timeout = 0.35

        XCTAssertThrowsError(try task.launch()) { error in
            let taskError = error as NSError
            XCTAssertEqual(taskError.domain, PBTaskErrorDomain)
            XCTAssertEqual(taskError.code, Int(PBTaskErrorCode.nonZeroExitCodeError.rawValue))
            XCTAssertEqual(taskError.userInfo[PBTaskTerminationStatusKey] as? NSNumber, 23)
            XCTAssertEqual(taskError.userInfo[PBTaskTerminationOutputKey] as? String, "parent-failure")
        }
    }

    func testTimeoutCompletionWaitsForChildTermination() throws {
        let markerURL = temporaryFileURL(named: "terminated")
        defer { try? FileManager.default.removeItem(at: markerURL) }
        let task = PBTask(
            launchPath: "/bin/sh",
            arguments: [
                "-c",
                "trap 'sleep 0.12; printf terminated > \"$PB_TASK_MARKER\"; exit 0' TERM; while :; do :; done",
            ],
            inDirectory: nil
        )
        task.additionalEnvironment = ["PB_TASK_MARKER": markerURL.path]
        task.timeout = 0.05

        XCTAssertThrowsError(try task.launch()) { error in
            let taskError = error as NSError
            XCTAssertEqual(taskError.domain, PBTaskErrorDomain)
            XCTAssertEqual(taskError.code, Int(PBTaskErrorCode.timeoutError.rawValue))
        }
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "terminated")
    }

    func testTimeoutEscalatesWhenChildIgnoresTermination() throws {
        let pidURL = temporaryFileURL(named: "pid")
        defer {
            if let contents = try? String(contentsOf: pidURL, encoding: .utf8),
               let processID = pid_t(contents)
            {
                _ = Darwin.kill(processID, SIGKILL)
            }
            try? FileManager.default.removeItem(at: pidURL)
        }
        let task = PBTask(
            launchPath: "/bin/sh",
            arguments: [
                "-c",
                "printf '%d' $$ > \"$PB_TASK_PID_FILE\"; trap '' TERM; while :; do :; done",
            ],
            inDirectory: nil
        )
        task.additionalEnvironment = ["PB_TASK_PID_FILE": pidURL.path]
        task.timeout = 0.05
        let startedAt = Date()

        XCTAssertThrowsError(try task.launch()) { error in
            let taskError = error as NSError
            XCTAssertEqual(taskError.domain, PBTaskErrorDomain)
            XCTAssertEqual(taskError.code, Int(PBTaskErrorCode.timeoutError.rawValue))
        }

        XCTAssertGreaterThan(Date().timeIntervalSince(startedAt), 0.15)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.0)
        let processID = try XCTUnwrap(pid_t(String(contentsOf: pidURL, encoding: .utf8)))
        XCTAssertEqual(Darwin.kill(processID, 0), -1, "PBTask must reap the timed-out child before completion")
    }
}
