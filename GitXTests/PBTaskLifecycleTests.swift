import XCTest

final class PBTaskLifecycleTests: XCTestCase {
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
}
