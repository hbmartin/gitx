import Darwin
import Foundation
import ObjectiveC
import XCTest

final class PBTaskDiagnosticCaptureTests: XCTestCase {
    // swift6-safety-justification: The lock protects the one-time gate and DispatchSemaphore is thread-safe.
    private final nonisolated class ShortReadHandle: FileHandle, @unchecked Sendable {
        let gate: DispatchSemaphore
        private let underlying: FileHandle
        private let lock = NSLock()
        private var firstRead = true

        init(descriptor: Int32, gate: DispatchSemaphore) {
            self.gate = gate
            underlying = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            super.init()
        }

        required init?(coder _: NSCoder) {
            nil
        }

        override var fileDescriptor: Int32 {
            underlying.fileDescriptor
        }

        override var readabilityHandler: (@Sendable (FileHandle) -> Void)? {
            get { underlying.readabilityHandler }
            set {
                if let newValue {
                    underlying.readabilityHandler = { [weak self] _ in
                        if let self {
                            newValue(self)
                        }
                    }
                } else {
                    underlying.readabilityHandler = nil
                }
            }
        }

        override func closeFile() {
            underlying.closeFile()
        }

        override var availableData: Data {
            lock.lock()
            let wait = firstRead
            firstRead = false
            lock.unlock()
            if wait {
                gate.wait()
            }
            var byte: UInt8 = 0
            let count = Darwin.read(fileDescriptor, &byte, 1)
            return count > 0 ? Data([byte]) : Data()
        }
    }

    // swift6-safety-justification: Pipe construction happens once before transfer to PBTask's readers.
    private final nonisolated class ShortReadPipe: Pipe, @unchecked Sendable {
        private let underlying: Pipe
        private let reader: ShortReadHandle

        init(gate: DispatchSemaphore) {
            let pipe = Pipe()
            underlying = pipe
            let descriptor = dup(pipe.fileHandleForReading.fileDescriptor)
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            reader = ShortReadHandle(descriptor: descriptor, gate: gate)
            super.init()
        }

        override var fileHandleForReading: FileHandle {
            reader
        }

        override var fileHandleForWriting: FileHandle {
            underlying.fileHandleForWriting
        }
    }

    private final nonisolated class ShortReaderTask: PBTask {
        /// PBTask's Objective-C factory bypasses Swift subclass initialization.
        /// Each fixture configures its gate explicitly before launching readers.
        var readerGate: DispatchSemaphore!

        @objc(makePipe)
        func makePipe() -> Pipe? {
            ShortReadPipe(gate: readerGate)
        } // swiftlint:disable:this unused_declaration
    }

    private class HeldOutputWriterTask: PBTask {
        private var pipeCount = 0
        // PBTask's test-only Objective-C initializer can leave Swift subclass
        // fields zero-initialized. Zero deliberately selects stdout.
        var heldPipeNumber = 0
        private(set) var heldOutputDescriptor: Int32 = -1
        private var ownsHeldWriter = false

        @objc(makePipe)
        func makePipe() -> Pipe? { // swiftlint:disable:this unused_declaration
            // Keep one parent-only writer open to exercise a pipe that cannot reach EOF.
            let pipe = Pipe()
            pipeCount += 1
            if pipeCount == (heldPipeNumber == 0 ? 1 : heldPipeNumber) {
                heldOutputDescriptor = dup(pipe.fileHandleForWriting.fileDescriptor)
                if heldOutputDescriptor >= 0 {
                    ownsHeldWriter = true
                    _ = fcntl(heldOutputDescriptor, F_SETFD, FD_CLOEXEC)
                }
            }
            return pipe
        }

        func releaseWriter() {
            guard ownsHeldWriter else { return }
            ownsHeldWriter = false
            _ = Darwin.close(heldOutputDescriptor)
            heldOutputDescriptor = -1
        }

        deinit { releaseWriter() }
    }

    /// Reader ownership tests release their own gates; the separate real-drain
    /// tests exercise the production post-exit deadline and descendant cleanup.
    private final class HeldOutputAndDrainTask: HeldOutputWriterTask {
        @objc(scheduleOutputDrainAfterTaskExit)
        func holdPostExitDrain() {} // swiftlint:disable:this unused_declaration
    }

    private final class HeldPostExitDrainTask: PBTask {
        @objc(scheduleOutputDrainAfterTaskExit)
        func holdPostExitDrain() {} // swiftlint:disable:this unused_declaration
    }

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

    func testCapturedFiniteStreamsSupportShortReadsBeforeTheDeadline() throws {
        let task = ShortReaderTask(launchPath: "/bin/sh", arguments: ["-c", "printf a; printf b >&2"], inDirectory: nil)
        task.readerGate = DispatchSemaphore(value: 0)
        let capture = PBTaskDiagnosticCapture()
        task.diagnosticCapture = capture
        task.readerGate.signal()
        task.readerGate.signal()
        try task.launch()
        XCTAssertEqual(task.standardOutputData, Data("a".utf8))
        XCTAssertEqual(task.standardErrorData, Data("b".utf8))
        let artifact = try XCTUnwrap(capture.artifact)
        defer { artifact.discard() }
        XCTAssertTrue(artifact.captureComplete)
    }

    func testDrainPolicyResetsIdleDeadlineWithoutExtendingHardOrTaskDeadlines() {
        XCTAssertEqual(PBTaskDrainPolicy.deadline(leaderExit: 10, lastProgress: 9, taskDeadline: 0), 11)
        XCTAssertEqual(PBTaskDrainPolicy.deadline(leaderExit: 10, lastProgress: 15, taskDeadline: 0), 16)
        XCTAssertEqual(PBTaskDrainPolicy.deadline(leaderExit: 10, lastProgress: 25, taskDeadline: 0), 20)
        XCTAssertEqual(PBTaskDrainPolicy.deadline(leaderExit: 10, lastProgress: 15, taskDeadline: 14), 14)
    }

    func testProductionDrainPreservesFiniteBufferedStreamsWithDelayedShortReaders() throws {
        let task = ShortReaderTask(launchPath: "/bin/sh", arguments: ["-c", "printf finite-output; printf finite-error >&2"], inDirectory: nil)
        task.readerGate = DispatchSemaphore(value: 0)
        let capture = PBTaskDiagnosticCapture()
        task.diagnosticCapture = capture
        task.timeout = 15
        let completed = expectation(description: "finite short-reader completion")
        task.perform(on: .global(qos: .userInitiated)) { error in
            XCTAssertNil(error)
            completed.fulfill()
        }
        defer { task.readerGate.signal(); task.readerGate.signal(); task.terminate() }
        waitForCondition("leader exited while both finite streams await reader delivery") {
            task.value(forKey: "leaderExitObserved") as? Bool == true &&
                (task.value(forKey: "outputReadsInFlight") as? Int ?? 0) > 0 &&
                (task.value(forKey: "errorReadsInFlight") as? Int ?? 0) > 0
        }
        // Hold actual reader work until the production deadline requests closure.
        // There is no descendant and all bytes are already buffered in the pipes.
        waitForCondition("production drain deadline reached") { task.value(forKey: "outputDrainExpired") as? Bool == true }
        task.readerGate.signal()
        task.readerGate.signal()
        wait(for: [completed], timeout: 15)
        XCTAssertEqual(task.standardOutputData, Data("finite-output".utf8))
        XCTAssertEqual(task.standardErrorData, Data("finite-error".utf8))
        XCTAssertEqual(task.value(forKey: "terminationStatus") as? Int, 0)
        let artifact = try XCTUnwrap(capture.artifact)
        defer { artifact.discard() }
        XCTAssertTrue(artifact.captureComplete)
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

    func testOptInCapturePreservesCompleteLargeSeparateStreamsBeforeFailureCompletion() throws {
        let capture = PBTaskDiagnosticCapture()
        let task = PBTask(launchPath: "/bin/sh", arguments: ["-c", """
        /usr/bin/awk 'BEGIN { printf "stdout-header\\n"; for (i = 0; i < 18000; i++) printf "abcdefgh"; printf "\\nstdout-final"; }' &
        /usr/bin/awk 'BEGIN { printf "stderr-header\\n"; for (i = 0; i < 18000; i++) printf "ijklmnop"; printf "\\nstderr-final"; }' >&2 &
        wait
        exit 9
        """], inDirectory: nil)
        task.separatesStandardError = true
        task.capturesStandardOutput = false
        task.diagnosticCapture = capture

        XCTAssertThrowsError(try task.launch())

        let artifact = try XCTUnwrap(capture.artifact, "Task completion must publish a sealed capture")
        defer { artifact.discard() }
        XCTAssertTrue(artifact.captureComplete)
        XCTAssertTrue(task.standardOutputData.isEmpty)
        XCTAssertLessThanOrEqual(artifact.redactedSummary.utf8.count, 16 * 1024)
        let report = try savedReport(artifact)
        XCTAssertTrue(report.contains("stdout-header\n" + String(repeating: "abcdefgh", count: 18000) + "\nstdout-final"))
        XCTAssertTrue(report.contains("stderr-header\n" + String(repeating: "ijklmnop", count: 18000) + "\nstderr-final"))
        XCTAssertFalse(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).complete)
    }

    func testOptInCaptureSeparatesStreamsWithoutAdditionalCallerConfiguration() throws {
        let capture = PBTaskDiagnosticCapture()
        let task = PBTask(launchPath: "/bin/sh", arguments: ["-c", "printf status; printf diagnostic >&2"], inDirectory: nil)
        task.diagnosticCapture = capture
        XCTAssertFalse(task.separatesStandardError)

        try task.launch()

        XCTAssertEqual(task.standardOutputData, Data("status".utf8))
        XCTAssertEqual(task.standardErrorData, Data("diagnostic".utf8))
        let artifact = try XCTUnwrap(capture.artifact)
        defer { artifact.discard() }
        XCTAssertEqual(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).data, Data("status".utf8))
        XCTAssertTrue(artifact.captureComplete)
    }

    func testOptInDefaultOutputCaptureKeepsBothMemoryStreamsBounded() throws {
        let capture = PBTaskDiagnosticCapture()
        let task = PBTask(launchPath: "/bin/sh", arguments: ["-c", """
        /usr/bin/awk 'BEGIN { for (i = 0; i < 18000; i++) printf "abcdefgh"; }'
        /usr/bin/awk 'BEGIN { for (i = 0; i < 18000; i++) printf "ijklmnop"; }' >&2
        """], inDirectory: nil)
        task.separatesStandardError = true
        task.diagnosticCapture = capture
        XCTAssertTrue(task.capturesStandardOutput)

        try task.launch()

        XCTAssertLessThanOrEqual(task.standardOutputData.count, 64 * 1024)
        XCTAssertLessThanOrEqual(task.standardErrorData.count, 64 * 1024)
        let artifact = try XCTUnwrap(capture.artifact)
        defer { artifact.discard() }
        XCTAssertTrue(artifact.captureComplete)
        XCTAssertFalse(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).complete)
        XCTAssertTrue(try savedReport(artifact).contains(String(repeating: "abcdefgh", count: 18000)))
    }

    func testOptInEmptySuccessSealsBothEOFsWithoutChangingGitResult() throws {
        let capture = PBTaskDiagnosticCapture()
        let task = PBTask(launchPath: "/usr/bin/true", arguments: [], inDirectory: nil)
        task.separatesStandardError = true
        task.diagnosticCapture = capture

        try task.launch()

        let artifact = try XCTUnwrap(capture.artifact)
        defer { artifact.discard() }
        XCTAssertTrue(artifact.captureComplete)
        XCTAssertTrue(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).complete)
        XCTAssertTrue(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).data.isEmpty)
    }

    // Fault injection and lifetime probes are available only in Debug app builds.
    #if DEBUG
        func testOptInCaptureCreationFailureLeavesSuccessfulGitResultSuccessful() throws {
            let capture = PBTaskDiagnosticCaptureTestHarness.capture(fault: "createOutput")
            let task = PBTask(launchPath: "/usr/bin/true", arguments: [], inDirectory: nil)
            task.separatesStandardError = true
            task.diagnosticCapture = capture

            try task.launch()

            let artifact = try XCTUnwrap(capture.artifact)
            XCTAssertFalse(artifact.captureComplete)
            XCTAssertNotNil(artifact.captureFailureDescription)
            XCTAssertThrowsError(try artifact.writeRedactedReport(to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        }

    #endif

    func testOptInLeaderLeaseWaitsForInheritedStreamsAndPublishesFinalBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = directory.appendingPathComponent("gate")
        XCTAssertEqual(mkfifo(gate.path, 0o600), 0)
        let descriptor = Darwin.open(gate.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return XCTFail("Could not open fixture gate") }
        defer { _ = Darwin.close(descriptor) }
        let capture = PBTaskDiagnosticCapture()
        let task = HeldPostExitDrainTask(launchPath: "/bin/sh", arguments: ["-c", """
        printf '%s' "$$" > "$1/leader"
        (printf ready > "$1/ready"; read permit < "$1/gate"; printf final-output; printf final-error >&2) &
        exit 0
        """, "fixture", directory.path], inDirectory: nil)
        task.diagnosticCapture = capture
        task.timeout = 15
        defer { task.terminate() }
        let completion = expectation(description: "leased leader completion")
        task.perform(on: .global(qos: .userInitiated)) { error in
            XCTAssertNil(error)
            XCTAssertTrue(capture.artifact?.captureComplete == true)
            completion.fulfill()
        }
        waitForCondition("descendant ready and leader retained") {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path),
                  let pid = self.processIdentifier(at: directory.appendingPathComponent("leader"))
            else { return false }
            return self.processIsZombie(pid)
        }
        XCTAssertNil(capture.artifact, "The leader must remain leased until both inherited streams reach EOF")
        let permit = Data("continue\n".utf8)
        XCTAssertEqual(permit.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }, permit.count)
        wait(for: [completion], timeout: 15)

        let artifact = try XCTUnwrap(capture.artifact)
        defer { artifact.discard() }
        XCTAssertTrue(artifact.captureComplete)
        XCTAssertEqual(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).data, Data("final-output".utf8))
        XCTAssertEqual(task.standardErrorData, Data("final-error".utf8))
        XCTAssertTrue(task.value(forKey: "outputHandleClosed") as? Bool == true)
        XCTAssertTrue(task.value(forKey: "errorHandleClosed") as? Bool == true)
    }

    func testProductionDrainPreservesDescendantOutputReleasedAfterLeaderExit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = directory.appendingPathComponent("gate")
        XCTAssertEqual(mkfifo(gate.path, 0o600), 0)
        let descriptor = Darwin.open(gate.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return XCTFail("Could not open descendant gate") }
        defer { _ = Darwin.close(descriptor) }
        let capture = PBTaskDiagnosticCapture()
        let task = PBTask(launchPath: "/bin/sh", arguments: ["-c", """
        (printf ready > "$1/ready"; read permit < "$1/gate"; printf delayed-output; printf delayed-error >&2) &
        exit 9
        """, "fixture", directory.path], inDirectory: nil)
        task.diagnosticCapture = capture
        task.timeout = 5
        defer { task.terminate() }
        let completed = expectation(description: "descendant output after leader exit")
        task.perform(on: .global(qos: .userInitiated)) { error in
            XCTAssertEqual((error as NSError?)?.userInfo[PBTaskTerminationStatusKey] as? Int, 9)
            completed.fulfill()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        func ready() -> Bool {
            task.value(forKey: "leaderExitObserved") as? Bool == true && FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path)
        }
        while !ready(), ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        XCTAssertTrue(ready(), "Release the descendant from observed exit state, before the idle deadline")
        let permit = Data("continue\n".utf8)
        XCTAssertEqual(permit.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }, permit.count)
        wait(for: [completed], timeout: 10)
        let artifact = try XCTUnwrap(capture.artifact)
        defer { artifact.discard() }
        XCTAssertTrue(artifact.captureComplete)
        XCTAssertEqual(task.standardOutputData, Data("delayed-output".utf8))
        XCTAssertEqual(task.standardErrorData, Data("delayed-error".utf8))
    }

    func testOptInCooperativeTerminationDrainsBothTrapMarkersBeforeCompletion() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = PBTaskDiagnosticCapture()
        let task = PBTask(launchPath: "/bin/sh", arguments: ["-c", """
        trap 'printf term-output; printf term-error >&2; exit 0' TERM
        printf ready > "$1/ready"
        while :; do :; done
        """, "fixture", directory.path], inDirectory: nil)
        task.diagnosticCapture = capture
        task.timeout = 15
        defer { task.terminate() }
        let completion = expectation(description: "cooperative termination")
        task.perform(on: .global(qos: .userInitiated)) { error in
            XCTAssertNil(error)
            XCTAssertTrue(capture.artifact?.captureComplete == true)
            completion.fulfill()
        }
        waitForCondition("TERM trap installed") { FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) }
        task.terminate(afterGracePeriod: 0, forceKillAfter: 1)
        wait(for: [completion], timeout: 15)

        let artifact = try XCTUnwrap(capture.artifact)
        defer { artifact.discard() }
        XCTAssertEqual(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).data, Data("term-output".utf8))
        XCTAssertEqual(task.standardErrorData, Data("term-error".utf8))
        XCTAssertTrue(artifact.captureComplete)
        task.terminate()
        XCTAssertTrue(capture.artifact === artifact)
    }

    func testOptInExitedLeaderKillsResistantDescendantWithoutTimeoutAndMarksIncompleteDrain() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = PBTaskDiagnosticCapture()
        let task = PBTask(launchPath: "/bin/sh", arguments: ["-c", """
        (trap '' TERM; printf ready >&2; while :; do :; done) &
        printf '%s' "$!" > "$1/descendant"
        exit 0
        """, "fixture", directory.path], inDirectory: nil)
        task.diagnosticCapture = capture
        task.timeout = 1
        defer { task.terminate() }

        try task.launch()
        XCTAssertEqual(task.value(forKey: "terminationStatus") as? Int, 0)
        let artifact = try XCTUnwrap(capture.artifact)
        defer { artifact.discard() }
        XCTAssertFalse(artifact.captureComplete)
        XCTAssertEqual(task.standardErrorData, Data("ready".utf8))
        let descendant = try XCTUnwrap(processIdentifier(at: directory.appendingPathComponent("descendant")))
        waitForCondition("resistant descendant terminated") { self.processHasTerminated(descendant) }
        XCTAssertTrue(task.value(forKey: "outputHandleClosed") as? Bool == true)
        XCTAssertTrue(task.value(forKey: "errorHandleClosed") as? Bool == true)
    }

    func testOptInCancellationBeforeLaunchSealsWithoutRunningChild() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = PBTaskDiagnosticCapture()
        let task = PBTask(launchPath: "/bin/sh", arguments: ["-c", "printf launched > \"$1/marker\"", "fixture", directory.path], inDirectory: nil)
        task.diagnosticCapture = capture
        task.terminate()
        XCTAssertThrowsError(try task.launch()) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, NSUserCancelledError)
        }
        let artifact = try XCTUnwrap(capture.artifact)
        defer { artifact.discard() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("marker").path))
        XCTAssertTrue(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).data.isEmpty)
        task.terminate()
        XCTAssertTrue(capture.artifact === artifact)
    }

    #if DEBUG
        func testOptInAppendFailureDoesNotChangeSuccessfulProcessStatus() throws {
            let capture = PBTaskDiagnosticCaptureTestHarness.capture(fault: "partialAppend")
            let task = PBTask(launchPath: "/usr/bin/printf", arguments: ["captured-prefix"], inDirectory: nil)
            task.diagnosticCapture = capture
            try task.launch()
            let artifact = try XCTUnwrap(capture.artifact)
            defer { artifact.discard() }
            XCTAssertFalse(artifact.captureComplete)
            XCTAssertNotNil(artifact.captureFailureDescription)
            XCTAssertEqual(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).data, Data("c".utf8))
            XCTAssertFalse(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).complete)
        }

    #endif

    func testOptInExitedLeaderBoundsDrainWithoutReportingTimeoutWhenAParentWriterPreventsEOF() throws {
        let capture = PBTaskDiagnosticCapture()
        let task = HeldOutputWriterTask(launchPath: "/usr/bin/printf", arguments: ["retained-prefix"], inDirectory: nil)
        task.diagnosticCapture = capture
        task.timeout = 0.25
        defer { task.releaseWriter(); task.terminate() }

        try task.launch()
        XCTAssertEqual(task.value(forKey: "terminationStatus") as? Int, 0)

        XCTAssertGreaterThanOrEqual(task.heldOutputDescriptor, 0)
        let artifact = try XCTUnwrap(capture.artifact)
        defer { artifact.discard() }
        XCTAssertFalse(artifact.captureComplete)
        XCTAssertEqual(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).data, Data("retained-prefix".utf8))
        XCTAssertFalse(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).complete)
        XCTAssertTrue(artifact.redactedSummary.contains("Standard output: 15 bytes; EOF: no"))
        XCTAssertTrue(task.value(forKey: "outputHandleClosed") as? Bool == true)
        XCTAssertTrue(task.value(forKey: "errorHandleClosed") as? Bool == true)
    }

    func testOptInStopsEachReaderAtItsOwnEOFWhileOtherStreamRemainsOpen() throws {
        for heldPipeNumber in [1, 2] {
            let capture = PBTaskDiagnosticCapture()
            let task = HeldOutputAndDrainTask(launchPath: "/bin/sh", arguments: ["-c", "printf output; printf error >&2"], inDirectory: nil)
            task.heldPipeNumber = heldPipeNumber
            task.diagnosticCapture = capture
            task.timeout = 15
            defer { task.releaseWriter(); task.terminate() }
            let completion = expectation(description: "both streams complete after releasing parent writer")
            task.perform(on: .global(qos: .userInitiated)) { error in
                XCTAssertNil(error)
                XCTAssertTrue(capture.artifact?.captureComplete == true)
                completion.fulfill()
            }
            let stateQueue = try XCTUnwrap(task.value(forKey: "stateQueue") as? DispatchQueue)
            let finishedStream = heldPipeNumber == 1 ? "error" : "output"
            waitForCondition("unheld stream reached real EOF") {
                stateQueue.sync { task.value(forKey: finishedStream + "Finished") as? Bool == true }
            }
            let closed = stateQueue.sync {
                (task.value(forKey: finishedStream + "ReaderStopped") as? Bool == true,
                 task.value(forKey: finishedStream + "HandleClosed") as? Bool == true)
            }
            XCTAssertTrue(closed.0, "EOF must stop its own reader without waiting for the other stream")
            XCTAssertTrue(closed.1, "EOF must close its own endpoint exactly once")
            XCTAssertNil(capture.artifact, "The other stream still prevents overall capture completion")
            task.releaseWriter()
            wait(for: [completion], timeout: 15)
            let artifact = try XCTUnwrap(capture.artifact)
            defer { artifact.discard() }
            XCTAssertTrue(artifact.captureComplete)
            XCTAssertEqual(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).data, Data("output".utf8))
            XCTAssertEqual(task.standardErrorData, Data("error".utf8))
        }
    }

    func testOptInForcedErrorCompletesAfterTheLastAcceptedNonemptyRead() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = PBTaskDiagnosticCapture()
        let task = HeldOutputAndDrainTask(launchPath: "/bin/sh", arguments: ["-c", "printf '%s' \"$$\" > \"$1/leader\"; exit 0", "fixture", directory.path], inDirectory: nil)
        task.diagnosticCapture = capture
        task.timeout = 15
        defer { task.releaseWriter(); task.terminate() }
        let completed = DispatchSemaphore(value: 0)
        let expected = NSError(domain: "AcceptedReadFixture", code: 17)
        task.perform(on: .global(qos: .userInitiated)) { error in
            XCTAssertEqual(error as NSError?, expected)
            XCTAssertNotNil(capture.artifact, "A forced error still publishes the accepted bytes before completion")
            completed.signal()
        }
        waitForCondition("leader terminal while parent writer retains pipe") {
            guard let identifier = self.processIdentifier(at: directory.appendingPathComponent("leader")) else { return false }
            return self.processIsZombie(identifier)
        }
        let stateQueue = try XCTUnwrap(task.value(forKey: "stateQueue") as? DispatchQueue)
        waitForCondition("stderr EOF already accepted before pending stdout read") {
            stateQueue.sync { task.value(forKey: "errorFinished") as? Bool == true }
        }
        let entered = expectation(description: "state queue held before forcing error")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        stateQueue.async {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 15)
        }
        wait(for: [entered], timeout: 10)
        task.perform(NSSelectorFromString("finishWithError:"), with: expected)
        let bytes = Data("pending-read".utf8)
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(task.heldOutputDescriptor, $0.baseAddress, $0.count) }, bytes.count)
        waitForCondition("nonempty reader accepted before forced error executes") {
            objc_sync_enter(task)
            defer { objc_sync_exit(task) }
            return (task.value(forKey: "outputReadsInFlight") as? NSNumber)?.intValue == 1
        }
        release.signal()
        let result = completed.wait(timeout: .now() + 2)
        XCTAssertEqual(result, .success, "The final accepted read must reevaluate forced-error completion without requiring EOF")
        if result != .success {
            // The RED implementation needs bounded cleanup; never leave a leased fixture behind.
            task.terminate()
            XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        }
        let artifact = try XCTUnwrap(capture.artifact)
        defer { artifact.discard() }
        XCTAssertEqual(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).data, bytes)
        XCTAssertFalse(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).complete)
        XCTAssertFalse(artifact.captureComplete)
    }

    func testCoreCaptureSealsOnceAndPreservesRedactedCompleteReport() throws {
        let capture = PBTaskDiagnosticCapture()
        capture.appendStandardOutput(Data("status\n".utf8))
        capture.appendStandardError(Data("header\nhttps://user:secret@early/remaining-secret@example.invalid/repo\nfinal".utf8))
        capture.finishStandardOutput(reachedEOF: true)
        capture.finishStandardError(reachedEOF: true)
        let artifact = capture.seal()
        defer { artifact.discard() }

        XCTAssertTrue(artifact === capture.seal())
        XCTAssertTrue(artifact === capture.artifact)
        XCTAssertTrue(artifact.captureComplete)
        XCTAssertEqual(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).data, Data("status\n".utf8))
        XCTAssertTrue(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).complete)
        let report = try savedReport(artifact)
        XCTAssertTrue(report.contains("https://[redacted]@example.invalid/repo"))
        XCTAssertFalse(report.contains("secret"))
        XCTAssertFalse(artifact.redactedSummary.contains("secret"))
        capture.appendStandardError(Data("late-secret".utf8))
        capture.finishStandardError(reachedEOF: false)
        XCTAssertEqual(try savedReport(artifact), report)
        XCTAssertTrue(artifact.captureComplete)
    }

    func testCoreSummaryRedactsBeforeCutoffAndExportRetainsMiddle() throws {
        let capture = PBTaskDiagnosticCapture()
        let secret = String(repeating: "secret/密碼@early/", count: 18000)
        capture.appendStandardError(Data(("header\nhttps://user:" + secret).utf8))
        capture.appendStandardError(Data("@example.invalid/repo\n".utf8))
        capture.appendStandardError(Data((String(repeating: "safe-line\n", count: 18000) + "final-marker").utf8))
        capture.finishStandardOutput(reachedEOF: true)
        capture.finishStandardError(reachedEOF: true)
        let artifact = capture.seal()
        defer { artifact.discard() }

        XCTAssertLessThanOrEqual(artifact.redactedSummary.utf8.count, 16 * 1024)
        XCTAssertTrue(artifact.redactedSummary.contains("header"))
        XCTAssertTrue(artifact.redactedSummary.contains("final-marker"))
        XCTAssertFalse(artifact.redactedSummary.contains("secret"))
        let report = try savedReport(artifact)
        XCTAssertTrue(report.contains(String(repeating: "safe-line\n", count: 18000)))
        XCTAssertFalse(report.contains("secret"))
    }

    func testCoreIncompleteCaptureMasksUnfinishedAuthorityAndKeepsStdoutEligibilityIndependent() throws {
        let capture = PBTaskDiagnosticCapture()
        capture.appendStandardOutput(Data("Done\n".utf8))
        capture.appendStandardError(Data("https://user:secret/unfinished".utf8))
        capture.finishStandardOutput(reachedEOF: true)
        capture.finishStandardError(reachedEOF: false)
        let artifact = capture.seal()
        defer { artifact.discard() }

        XCTAssertFalse(artifact.captureComplete)
        XCTAssertTrue(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).complete)
        XCTAssertTrue(artifact.redactedSummary.contains("before end-of-file"))
        XCTAssertFalse(artifact.redactedSummary.contains("secret"))
        XCTAssertFalse(try savedReport(artifact).contains("secret"))
    }

    func testCoreCompleteCaptureRedactsMalformedAuthorityInSummaryAndExport() throws {
        let capture = PBTaskDiagnosticCapture()
        capture.appendStandardError(Data("https://user:secret\nnext-line".utf8))
        capture.finishStandardOutput(reachedEOF: true)
        capture.finishStandardError(reachedEOF: true)
        let artifact = capture.seal()
        defer { artifact.discard() }
        XCTAssertTrue(artifact.captureComplete)
        XCTAssertFalse(artifact.redactedSummary.contains("secret"))
        XCTAssertFalse(try savedReport(artifact).contains("secret"))
        XCTAssertTrue(artifact.redactedSummary.contains("next-line"))
    }

    func testCoreBinaryPrefixAndLargeInvalidUTF8SummaryStayBounded() {
        let capture = PBTaskDiagnosticCapture()
        let output = Data([0, 255, 254])
        capture.appendStandardOutput(output)
        capture.appendStandardError(Data(repeating: 255, count: 144 * 1024))
        capture.finishStandardOutput(reachedEOF: true)
        capture.finishStandardError(reachedEOF: true)
        let artifact = capture.seal()
        defer { artifact.discard() }

        XCTAssertEqual(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).data, output)
        XCTAssertTrue(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).complete)
        XCTAssertFalse(artifact.rawStandardOutputPrefix(maximumBytes: 2).complete)
        XCTAssertTrue(artifact.rawStandardOutputPrefix(maximumBytes: -1).data.isEmpty)
        XCTAssertLessThanOrEqual(artifact.redactedSummary.utf8.count, 16 * 1024)
    }

    func testCoreExportEscapesInvalidAndControlBytesWhileRawPrefixStaysExact() throws {
        let capture = PBTaskDiagnosticCapture()
        let bytes = Data([0, 255, 254, 27, 9, 195, 177])
        capture.appendStandardOutput(bytes)
        capture.finishStandardOutput(reachedEOF: true)
        capture.finishStandardError(reachedEOF: true)
        let artifact = capture.seal()
        defer { artifact.discard() }

        XCTAssertEqual(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).data, bytes)
        let report = try savedReport(artifact)
        XCTAssertTrue(report.contains("\\x00\\xFF\\xFE\\x1B\tñ"))
        XCTAssertFalse(report.contains("�"))
    }

    func testCoreSummaryIncludesMediumStreamOnceWithoutOverlappingHeadAndTail() {
        for count in [4097, 5000, 6143, 6144] {
            let capture = PBTaskDiagnosticCapture()
            let payload = String(String(repeating: "0123456789abcdef", count: 400).prefix(count))
            capture.appendStandardError(Data(payload.utf8))
            capture.finishStandardOutput(reachedEOF: true)
            capture.finishStandardError(reachedEOF: true)
            let artifact = capture.seal()
            defer { artifact.discard() }

            XCTAssertTrue(artifact.redactedSummary.contains(payload), "\(count) bytes must remain contiguous")
            XCTAssertFalse(artifact.redactedSummary.contains("omitted"), "\(count) bytes fit without omission")
            XCTAssertLessThanOrEqual(artifact.redactedSummary.utf8.count, 16 * 1024)
        }
    }

    func testCoreSummaryLabelsNonoverlappingHeadTailAndExactOmittedDisplayByteCount() throws {
        let capture = PBTaskDiagnosticCapture()
        let payload = String(repeating: "x", count: 10000)
        capture.appendStandardError(Data(payload.utf8))
        capture.finishStandardOutput(reachedEOF: true)
        capture.finishStandardError(reachedEOF: true)
        let artifact = capture.seal()
        defer { artifact.discard() }

        XCTAssertTrue(artifact.redactedSummary.contains("Head (2048 display bytes):"))
        XCTAssertTrue(artifact.redactedSummary.contains("[3856 display bytes omitted]"))
        XCTAssertTrue(artifact.redactedSummary.contains("Tail (4096 display bytes):"))
        let report = try savedReport(artifact)
        XCTAssertTrue(report.contains("Standard output: 0 bytes; EOF: yes"))
        XCTAssertTrue(report.contains("Standard error: 10000 bytes; EOF: yes"))
        XCTAssertTrue(report.contains(payload))
    }

    func testCoreSummaryCutsValidUnicodeOnlyAtScalarBoundaries() throws {
        let payloads = [
            String(repeating: "x", count: 2047) + "🙂" + String(repeating: "y", count: 10000) + "final",
            "header" + String(repeating: "y", count: 10000) + "🙂" + String(repeating: "z", count: 4094),
            String(repeating: "x", count: 2047) + "🙂" + String(repeating: "y", count: 3000),
        ]
        for payload in payloads {
            let capture = PBTaskDiagnosticCapture()
            capture.appendStandardError(Data(payload.utf8))
            capture.finishStandardOutput(reachedEOF: true)
            capture.finishStandardError(reachedEOF: true)
            let artifact = capture.seal()
            defer { artifact.discard() }
            XCTAssertFalse(artifact.redactedSummary.contains("�"))
            XCTAssertTrue(try savedReport(artifact).contains(payload))
            XCTAssertLessThanOrEqual(artifact.redactedSummary.utf8.count, 16 * 1024)
        }
    }

    #if DEBUG
        func testCorePrivateFilesCloseAtSealAndSurviveOnlyWhileArtifactIsOwned() throws {
            var artifact: PBTaskDiagnosticArtifact?
            var probe: PBTaskDiagnosticCaptureLifetimeProbe?
            autoreleasepool {
                let capture = PBTaskDiagnosticCapture()
                probe = PBTaskDiagnosticCaptureTestHarness.lifetimeProbe(for: capture)
                XCTAssertEqual(probe?.directoryMode, 0o700)
                XCTAssertEqual(probe?.rawFileModes, [0o600, 0o600, 0o600].map { NSNumber(value: $0) })
                XCTAssertTrue(probe?.writerDescriptorsAreCloseOnExec == true)
                XCTAssertFalse(probe?.writersClosed == true)
                capture.finishStandardOutput(reachedEOF: true)
                capture.finishStandardError(reachedEOF: true)
                artifact = capture.seal()
                XCTAssertTrue(probe?.writersClosed == true)
            }
            let retainedProbe = try XCTUnwrap(probe)
            XCTAssertTrue(retainedProbe.directoryExists)
            PBTaskDiagnosticCapture.cleanupStaleCaptures()
            XCTAssertTrue(retainedProbe.directoryExists, "A leased artifact must survive startup cleanup")
            autoreleasepool { artifact = nil }
            XCTAssertFalse(retainedProbe.directoryExists)
            XCTAssertTrue(retainedProbe.writersClosed)
            XCTAssertNil(artifact)
        }

        func testCoreAbandonedUnsealedCaptureRemovesPrivateFilesAndKeepsItsIdentityOpaque() throws {
            var probe: PBTaskDiagnosticCaptureLifetimeProbe?
            autoreleasepool {
                let capture = PBTaskDiagnosticCapture()
                capture.appendStandardOutput(Data("unpublished-status".utf8))
                capture.appendStandardError(Data("https://user:secret@example.invalid/repo".utf8))
                probe = PBTaskDiagnosticCaptureTestHarness.lifetimeProbe(for: capture)
                XCTAssertNotNil(probe)
                XCTAssertTrue(probe?.directoryExists == true)
                XCTAssertFalse(probe?.writersClosed == true)
                XCTAssertNil(capture.artifact, "Abandoning a capture must not require sealing or publishing raw output")
                XCTAssertEqual(capture.description, "<private push diagnostic capture>")
                XCTAssertEqual(probe?.description, "<private capture lifetime probe>")
            }
            let releasedProbe = try XCTUnwrap(probe)
            XCTAssertFalse(releasedProbe.directoryExists, "Last-owner release must remove an unsealed private capture")
            XCTAssertTrue(releasedProbe.writersClosed)
        }

        func testCoreCleanupRemovesOldLeaseLessOrphansAndPreservesFreshCreationGap() throws {
            let old = try PBTaskDiagnosticCaptureTestHarness.orphanProbe(age: 2 * 24 * 60 * 60)
            let fresh = try PBTaskDiagnosticCaptureTestHarness.orphanProbe(age: 0)
            defer { old.discardFixture(); fresh.discardFixture() }
            XCTAssertTrue(old.directoryExists)
            XCTAssertTrue(fresh.directoryExists)
            PBTaskDiagnosticCapture.cleanupStaleCaptures()
            XCTAssertFalse(old.directoryExists)
            XCTAssertTrue(fresh.directoryExists)
        }

        func testCoreCleanupRemovesUnlockedLeasedOrphanWhileLiveCaptureSurvives() throws {
            let orphan = try PBTaskDiagnosticCaptureTestHarness.unlockedLeasedOrphanProbe(age: 48 * 60 * 60)
            let capture = PBTaskDiagnosticCapture()
            let live = try XCTUnwrap(PBTaskDiagnosticCaptureTestHarness.lifetimeProbe(for: capture))
            defer { orphan.discardFixture(); capture.seal().discard() }
            try live.markStaleForCleanup()
            XCTAssertTrue(orphan.directoryExists)
            XCTAssertEqual(orphan.directoryMode, 0o700)
            XCTAssertEqual(orphan.rawFileModes.last, NSNumber(value: 0o600))
            XCTAssertTrue(live.directoryExists)

            PBTaskDiagnosticCapture.cleanupStaleCaptures()

            XCTAssertFalse(orphan.directoryExists, "An old unlocked lease identifies an abandoned capture")
            XCTAssertTrue(live.directoryExists, "Cleanup must preserve an actively locked capture")
            XCTAssertFalse(live.writersClosed)
            XCTAssertNil(capture.artifact)
            PBTaskDiagnosticCapture.cleanupStaleCaptures()
            XCTAssertFalse(orphan.directoryExists)
            XCTAssertTrue(live.directoryExists)
        }

        func testCleanupPreservesFreshUnlockedLeaseDuringCaptureRegistration() throws {
            let fresh = try PBTaskDiagnosticCaptureTestHarness.unlockedLeasedOrphanProbe(age: 0)
            defer { fresh.discardFixture() }
            PBTaskDiagnosticCapture.cleanupStaleCaptures()
            XCTAssertTrue(fresh.directoryExists)
        }

        func testCoreCaptureFailureModesKeepSafeStaticFallbackAndPartialIntegrity() {
            for fault in ["createDirectory", "createLease", "createOutput", "createError", "append", "partialAppend", "close", "closeError", "createReport", "read", "redactionWrite"] {
                let capture = PBTaskDiagnosticCaptureTestHarness.capture(fault: fault)
                capture.appendStandardOutput(Data("https://user:secret@example.invalid/repo".utf8))
                capture.finishStandardOutput(reachedEOF: true)
                capture.finishStandardError(reachedEOF: true)
                let artifact = capture.seal()
                defer { artifact.discard() }
                let summary = artifact.redactedSummary
                XCTAssertFalse(artifact.captureComplete, fault)
                XCTAssertNotNil(artifact.captureFailureDescription, fault)
                XCTAssertFalse(summary.contains("secret"), fault)
                XCTAssertLessThanOrEqual(summary.utf8.count, 16 * 1024, fault)
            }
        }

        func testSealingDoesNotPrepareAReportUntilSummaryOrExportIsRequested() {
            let capture = PBTaskDiagnosticCaptureTestHarness.capture(fault: "createReport")
            capture.appendStandardError(Data("remote: useful diagnostic\n".utf8))
            capture.finishStandardOutput(reachedEOF: true)
            capture.finishStandardError(reachedEOF: true)
            let artifact = capture.seal()
            defer { artifact.discard() }
            XCTAssertTrue(artifact.captureComplete)
            XCTAssertNil(artifact.captureFailureDescription)
            XCTAssertTrue(artifact.redactedSummary.contains("could not be prepared"))
            XCTAssertFalse(artifact.captureComplete)
        }

        func testCoreShortAndInterruptedWritesPreserveEveryByte() throws {
            for fault in ["shortWrite", "interruptedWrite"] {
                let capture = PBTaskDiagnosticCaptureTestHarness.capture(fault: fault)
                let expected = Data("header\n".utf8) + Data(repeating: 65, count: 144 * 1024)
                capture.appendStandardOutput(expected)
                capture.finishStandardOutput(reachedEOF: true)
                capture.finishStandardError(reachedEOF: true)
                let artifact = capture.seal()
                defer { artifact.discard() }
                XCTAssertTrue(artifact.captureComplete)
                XCTAssertTrue(try savedReport(artifact).contains(String(decoding: expected, as: UTF8.self)))
            }
        }

        func testCoreFailedExportPreservesExistingDestinationAndAllowsRetry() throws {
            for fault in ["exportOpen", "exportWrite", "exportSync"] {
                let capture = PBTaskDiagnosticCaptureTestHarness.capture(fault: fault)
                capture.appendStandardError(Data("saved-diagnostics".utf8))
                capture.finishStandardOutput(reachedEOF: true)
                capture.finishStandardError(reachedEOF: true)
                let artifact = capture.seal()
                defer { artifact.discard() }
                let directory = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let destination = directory.appendingPathComponent("push.txt")
                try Data("original".utf8).write(to: destination)

                XCTAssertThrowsError(try artifact.writeRedactedReport(to: destination))
                XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
                XCTAssertTrue(artifact.captureComplete)
                try artifact.writeRedactedReport(to: destination)
                XCTAssertTrue(try String(contentsOf: destination, encoding: .utf8).contains("saved-diagnostics"))
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["push.txt"])
            }
        }

    #endif

    func testCoreRawLineIterationSkipsOversizeLinesAndAllowsReentrantInspection() {
        let capture = PBTaskDiagnosticCapture()
        capture.appendStandardError(Data(("first\n" + String(repeating: "x", count: 70 * 1024) + "\nlast").utf8))
        capture.finishStandardOutput(reachedEOF: true)
        capture.finishStandardError(reachedEOF: true)
        let artifact = capture.seal()
        defer { artifact.discard() }
        var lines: [String] = []
        artifact.forEachRawStandardErrorLine(maximumLineBytes: 128) { line in
            XCTAssertTrue(artifact.captureComplete)
            lines.append(line)
        }
        XCTAssertEqual(lines, ["first", "last"])
        artifact.forEachRawStandardErrorLine(maximumLineBytes: 0) { _ in XCTFail("Invalid line limit must not deliver data") }
        artifact.discard()
        XCTAssertFalse(artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024).complete)
    }

    func testMatchingErrorLineStopsAtTheFirstCandidateAndSkipsIncompleteFinalLines() {
        for reachedEOF in [true, false] {
            let capture = PBTaskDiagnosticCapture()
            capture.appendStandardError(Data("first\nmatch\nfinal".utf8))
            capture.finishStandardOutput(reachedEOF: true)
            capture.finishStandardError(reachedEOF: reachedEOF)
            let artifact = capture.seal()
            defer { artifact.discard() }
            var visited: [String] = []
            XCTAssertEqual(artifact.firstRawStandardErrorLine(maximumLineBytes: 128) { line in
                visited.append(line)
                return line == "match"
            }, "match")
            XCTAssertEqual(visited, ["first", "match"])
            XCTAssertEqual(artifact.firstRawStandardErrorLine(maximumLineBytes: 128) { $0 == "final" }, reachedEOF ? "final" : nil)
        }
    }

    func testCoreRawLineIteratorRequiresCompleteCaptureForUnterminatedFinalHint() {
        let finalHint = "https://example.invalid/push"
        for (outputEOF, reachedEOF) in [(true, false), (true, true), (false, true)] {
            let capture = PBTaskDiagnosticCapture()
            capture.appendStandardError(Data(("prefix-line\n" + finalHint).utf8))
            capture.finishStandardOutput(reachedEOF: outputEOF)
            capture.finishStandardError(reachedEOF: reachedEOF)
            let artifact = capture.seal()
            defer { artifact.discard() }
            var lines: [String] = []
            artifact.forEachRawStandardErrorLine(maximumLineBytes: 64 * 1024) { lines.append($0) }
            XCTAssertEqual(lines, reachedEOF ? ["prefix-line", finalHint] : ["prefix-line"])
        }
        #if DEBUG
            let partial = PBTaskDiagnosticCaptureTestHarness.capture(fault: "partialAppend")
            partial.appendStandardError(Data(finalHint.utf8))
            partial.finishStandardOutput(reachedEOF: true)
            partial.finishStandardError(reachedEOF: true)
            let artifact = partial.seal()
            defer { artifact.discard() }
            artifact.forEachRawStandardErrorLine(maximumLineBytes: 64 * 1024) { _ in
                XCTFail("A failed write does not establish a complete final line, even if the pipe later reaches EOF")
            }
        #endif
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gitx-capture-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func waitForCondition(_ description: String, body: @escaping () -> Bool) {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in body() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 10), .completed, description)
    }

    private func processIdentifier(at url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pid_t(text)
    }

    private func processIsZombie(_ identifier: pid_t) -> Bool {
        // libproc may withhold zombie metadata; WNOWAIT observes our child
        // without releasing the lease or racing the owner's eventual reap.
        var status = siginfo_t()
        if waitid(P_PID, id_t(identifier), &status, WEXITED | WNOHANG | WNOWAIT) == 0,
           status.si_pid == identifier
        {
            return [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(status.si_code)
        }
        var information = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &information) {
            proc_pidinfo(identifier, PROC_PIDTBSDINFO, 0, $0, Int32(size))
        }
        return result == Int32(size) && information.pbi_status == SZOMB
    }

    private func processHasTerminated(_ identifier: pid_t) -> Bool {
        kill(identifier, 0) != 0 || processIsZombie(identifier)
    }

    private func savedReport(_ artifact: PBTaskDiagnosticArtifact) throws -> String {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = directory.appendingPathComponent("push.txt")
        try artifact.writeRedactedReport(to: report)
        return try String(contentsOf: report, encoding: .utf8)
    }
}
