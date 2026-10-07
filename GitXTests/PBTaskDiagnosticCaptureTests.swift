import Foundation
import XCTest

final class PBTaskDiagnosticCaptureTests: XCTestCase {
    func testLegacySeparateReadersDrainConcurrentLargeStreamsBeforeFailureCompletion() {
        let output = "stdout-header\n" + String(repeating: "abcdefgh", count: 18000) + "\nstdout-final"
        let diagnostic = "stderr-header\n" + String(repeating: "ijklmnop", count: 900) + "\nstderr-final"
        let script = """
        /usr/bin/awk 'BEGIN { printf "stdout-header\\n"; for (i = 0; i < 18000; i++) printf "abcdefgh"; printf "\\nstdout-final"; }' &
        /usr/bin/awk 'BEGIN { printf "stderr-header\\n"; for (i = 0; i < 900; i++) printf "ijklmnop"; printf "\\nstderr-final"; }' >&2 &
        wait
        exit 9
        """
        let task = PBTask(launchPath: "/bin/sh", arguments: ["-c", script], inDirectory: nil)
        task.separatesStandardError = true
        let expectedDiagnostic = Data(diagnostic.utf8)

        XCTAssertThrowsError(try task.launch()) { error in
            let taskError = error as NSError
            XCTAssertEqual(taskError.domain, PBTaskErrorDomain)
            XCTAssertEqual(taskError.code, Int(PBTaskErrorCode.nonZeroExitCodeError.rawValue))
            XCTAssertEqual(taskError.userInfo[PBTaskTerminationStatusKey] as? NSNumber, 9)
            XCTAssertEqual(taskError.userInfo[PBTaskTerminationOutputKey] as? String,
                           diagnostic)
        }

        XCTAssertEqual(task.standardOutputData, Data(output.utf8))
        XCTAssertEqual(task.standardErrorData, expectedDiagnostic)
    }

    func testLegacySeparateReadersPreserveBinaryBytesAndKeepInvalidDiagnosticOutOfErrorText() {
        let task = PBTask(launchPath: "/bin/sh", arguments: ["-c", "printf '\\377error\\376' >&2; printf '\\000binary\\377'; exit 4"], inDirectory: nil)
        task.separatesStandardError = true
        let expectedOutput = Data([0] + Array("binary".utf8) + [255])
        let expectedError = Data([255] + Array("error".utf8) + [254])

        XCTAssertThrowsError(try task.launch()) { error in
            let taskError = error as NSError
            XCTAssertEqual(taskError.code, Int(PBTaskErrorCode.nonZeroExitCodeError.rawValue))
            XCTAssertEqual(taskError.userInfo[PBTaskTerminationOutputKey] as? String, "")
        }

        XCTAssertEqual(task.standardOutputData, expectedOutput)
        XCTAssertEqual(task.standardErrorData, expectedError)
        XCTAssertNil(task.standardOutputString())
    }
}
