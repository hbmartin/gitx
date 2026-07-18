import Darwin
import XCTest

final class PBTaskLifecycleTests: XCTestCase {
    // swift6-safety-justification: `lock` protects every access to recorded events and output data.
    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedEvents: [String] = []
        private var storedData = Data()

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storedEvents
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storedData
        }

        func recordChunk(_ data: Data) {
            lock.lock()
            storedEvents.append("chunk")
            storedData.append(data)
            lock.unlock()
        }

        func recordCompletion() {
            lock.lock()
            storedEvents.append("completion")
            lock.unlock()
        }
    }

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

    func testRawOutputChunksAreOrderedBeforeCompletion() {
        let completion = expectation(description: "streaming completion")
        let queue = DispatchQueue(label: "org.gitx.tests.pbtask-streaming")
        let recorder = EventRecorder()
        let task = PBTask(
            launchPath: "/bin/sh",
            arguments: [
                "-c",
                "printf 'stdout-one'; printf 'stderr-two' >&2; printf 'terminal-byte'",
            ],
            inDirectory: nil
        )

        task.perform(
            on: queue,
            outputChunkHandler: { recorder.recordChunk($0) },
            completionHandler: { data, error in
                XCTAssertNil(error)
                XCTAssertEqual(data, recorder.data)
                recorder.recordCompletion()
                completion.fulfill()
            }
        )

        wait(for: [completion], timeout: 5)
        XCTAssertEqual(recorder.data, Data("stdout-onestderr-twoterminal-byte".utf8))
        XCTAssertEqual(recorder.events.last, "completion")
        XCTAssertTrue(recorder.events.dropLast().allSatisfy { $0 == "chunk" })
    }

    func testSynchronousStreamingPreservesNonZeroExitErrorAndOutput() {
        let recorder = EventRecorder()
        let task = PBTask(
            launchPath: "/bin/sh",
            arguments: ["-c", "printf 'streamed failure'; exit 23"],
            inDirectory: nil
        )

        XCTAssertThrowsError(
            try task.launch(outputChunkHandler: recorder.recordChunk)
        ) { error in
            let taskError = error as NSError
            XCTAssertEqual(taskError.domain, PBTaskErrorDomain)
            XCTAssertEqual(taskError.code, Int(PBTaskErrorCode.nonZeroExitCodeError.rawValue))
            XCTAssertEqual(taskError.userInfo[PBTaskTerminationStatusKey] as? NSNumber, 23)
            XCTAssertEqual(
                taskError.userInfo[PBTaskTerminationOutputKey] as? String,
                "streamed failure"
            )
        }
        XCTAssertEqual(recorder.data, Data("streamed failure".utf8))
    }

    func testSynchronousStreamingExecutableScriptPreservesFailure() throws {
        let scriptURL = temporaryFileURL(named: "streaming-failure-hook")
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try "#!/bin/sh\nprintf 'script failure'\nexit 23\n".write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        let recorder = EventRecorder()
        let task = PBTask(
            launchPath: scriptURL.path,
            arguments: [],
            inDirectory: nil
        )

        XCTAssertThrowsError(
            try task.launch(outputChunkHandler: recorder.recordChunk)
        ) { error in
            let taskError = error as NSError
            XCTAssertEqual(taskError.userInfo[PBTaskTerminationStatusKey] as? NSNumber, 23)
            XCTAssertEqual(
                taskError.userInfo[PBTaskTerminationOutputKey] as? String,
                "script failure"
            )
        }
        XCTAssertEqual(recorder.data, Data("script failure".utf8))
    }

    func testIncrementalUTF8DecoderBuffersSplitScalarsAndFlushesFinalBytes() {
        let decoder = PBIncrementalUTF8Decoder()

        XCTAssertEqual(decoder.append(Data([0x41, 0xE2])), "A")
        XCTAssertEqual(decoder.append(Data([0x82])), "")
        XCTAssertEqual(decoder.append(Data([0xAC, 0x20, 0xF0, 0x9F])), "€ ")
        XCTAssertEqual(decoder.append(Data([0x98, 0x80])), "😀")
        XCTAssertEqual(decoder.finish(), "")

        XCTAssertEqual(decoder.append(Data([0xE2, 0x82])), "")
        XCTAssertEqual(decoder.finish(), "�")
        XCTAssertEqual(decoder.finish(), "")

        XCTAssertEqual(decoder.append(Data([0xC2, 0xA2])), "¢")
        XCTAssertEqual(decoder.append(Data([0xE2, 0x41])), "�A")
        XCTAssertEqual(decoder.append(Data([0xFF])), "�")
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
