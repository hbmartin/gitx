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
