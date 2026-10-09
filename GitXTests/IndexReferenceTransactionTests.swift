import Foundation
import XCTest

final class IndexReferenceTransactionTests: XCTestCase {
    func testExecutionContextFreezesValidatedInputsWithoutLaunchingTheTask() throws {
        let task = PBTask(launchPath: "/bin/sh", arguments: ["-c", "printf '%s' \"$CONTEXT_VALUE\""], inDirectory: nil)
        task.additionalEnvironment = ["CONTEXT_VALUE": "before"]
        let context = try task.executionContext()
        task.additionalEnvironment = ["CONTEXT_VALUE": "after"]
        XCTAssertEqual(context.launchPath, "/bin/sh")
        XCTAssertNil(context.workingDirectory)
        XCTAssertEqual(context.environment["CONTEXT_VALUE"], "before")
        XCTAssertEqual(context.arguments, ["-c", "printf '%s' \"$CONTEXT_VALUE\""])
        try task.launch()
        XCTAssertEqual(task.standardOutputString(), "after")
    }

    func testExecutionContextKeepsDynamicInputExceptionsInsideObjectiveC() {
        let invalid: [(String, Any)] = [
            ("arguments", [NSNumber(value: 7)]),
            ("additionalEnvironment", ["KEY": NSNumber(value: 7)]),
            ("environment", [NSNumber(value: 7): "value"]),
            ("environment", ["KEY": NSNumber(value: 7)]),
            ("launchPath", NSNumber(value: 7)),
            ("currentDirectoryPath", NSNumber(value: 7)),
        ]
        for (key, value) in invalid {
            let task = PBTask(launchPath: "/usr/bin/true", arguments: [], inDirectory: nil)
            task.setValue(value, forKey: key)
            XCTAssertThrowsError(try task.executionContext(), key) { error in
                XCTAssertEqual((error as NSError).domain, PBTaskErrorDomain)
                XCTAssertNotNil((error as NSError).userInfo[PBTaskUnderlyingExceptionKey])
            }
        }
    }

    func testHeadExpectationsDistinguishSymbolicDetachedUnbornAndRawIdentity() throws {
        let oid = String(repeating: "a", count: 40)
        let main = try PBCommitHeadExpectation(symbolicTarget: "refs/heads/main", expectedOID: oid, objectIDWidth: 40)
        let same = try PBCommitHeadExpectation(symbolicTarget: "refs/heads/main", expectedOID: oid, objectIDWidth: 40)
        XCTAssertTrue(main.matchesExpectation(same))
        let branch = try PBCommitHeadExpectation(symbolicTarget: "refs/heads/other", expectedOID: oid, objectIDWidth: 40)
        let detached = try PBCommitHeadExpectation(symbolicTarget: nil, expectedOID: oid, objectIDWidth: 40)
        let unborn = try PBCommitHeadExpectation(symbolicTarget: "refs/heads/main", expectedOID: nil, objectIDWidth: 40)
        XCTAssertFalse(main.matchesExpectation(branch))
        XCTAssertFalse(main.matchesExpectation(detached))
        XCTAssertFalse(main.matchesExpectation(unborn))
        let nfc = try PBCommitHeadExpectation(symbolicTarget: "refs/heads/é", expectedOID: oid, objectIDWidth: 40)
        let nfd = try PBCommitHeadExpectation(symbolicTarget: "refs/heads/e\u{301}", expectedOID: oid, objectIDWidth: 40)
        XCTAssertFalse(nfc.matchesExpectation(nfd))
        let sha256 = try PBCommitHeadExpectation(symbolicTarget: "refs/heads/main", expectedOID: String(repeating: "b", count: 64), objectIDWidth: 64)
        XCTAssertFalse(main.matchesExpectation(sha256))
        XCTAssertEqual(sha256.objectIDWidth, 64)
    }

    func testInvalidHeadIdentitiesAreRefused() {
        for (target, oid, width) in [(nil, nil, 40), ("refs/heads/main", nil, 41), ("invalid", nil, 40), ("refs/heads/bad name", nil, 40), ("refs/heads/main", "short", 40), ("refs/heads/main", String(repeating: "g", count: 40), 40)] as [(String?, String?, Int)] {
            XCTAssertThrowsError(try PBCommitHeadExpectation(symbolicTarget: target, expectedOID: oid, objectIDWidth: width))
        }
    }

    func testPreparedRetryRetainsHeadParentsMessageSigningAndEnvironment() throws {
        let oid = String(repeating: "a", count: 40)
        let head = try PBCommitHeadExpectation(symbolicTarget: "refs/heads/main", expectedOID: oid, objectIDWidth: 40)
        let request = PBIndexCommitRequest(message: "original", verify: true, gpgSign: true, amend: true,
                                           environment: ["GIT_AUTHOR_DATE": "@1234 +0000"], parentSHAs: [], hasHead: false)
        let prepared = request.prepared(head: head, parents: [oid])
        let retry = prepared.withoutVerification()
        XCTAssertTrue(retry.headExpectation === head)
        XCTAssertEqual(retry.parentSHAs, [oid])
        XCTAssertEqual(retry.message, "original")
        XCTAssertTrue(retry.gpgSign)
        XCTAssertTrue(retry.amend)
        XCTAssertTrue(retry.hasHead)
        XCTAssertFalse(retry.verify)
        XCTAssertEqual(retry.environment?["GIT_AUTHOR_DATE"] as? String, "@1234 +0000")
    }

    #if DEBUG
        func testCancelledAndFailedLaunchCapabilityProbesRemainRetryable() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("peer")
            try "#!/bin/sh\nprintf 'probe\\n' >> probes\nwhile read command; do printf '%s: ok\\n' \"$command\"; done\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            func task() -> PBTask {
                PBTask(launchPath: executable.path, arguments: [], inDirectory: directory.path)
            }
            XCTAssertThrowsError(try PBIndexReferenceCapabilityTestHarness.require(task: task(), cancelled: true)) { error in
                XCTAssertEqual((error as NSError).code, 3)
            }
            try PBIndexReferenceCapabilityTestHarness.require(task: task())
            let probes = try String(contentsOf: directory.appendingPathComponent("probes"), encoding: .utf8)
            try PBIndexReferenceCapabilityTestHarness.require(task: task())
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("probes"), encoding: .utf8), probes)
            for _ in 0 ..< 2 {
                XCTAssertThrowsError(try PBIndexReferenceCapabilityTestHarness.require(task: PBTask(launchPath: "/gitx-missing-peer", arguments: [], inDirectory: nil))) { error in
                    XCTAssertEqual((error as NSError).code, 4)
                }
            }
        }

        func testMergeCleanupRemovesOnlyUnchangedCapturedMarkers() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            for replacement in [nil, "newer merge\n"] as [String?] {
                try Data("parent\n".utf8).write(to: directory.appendingPathComponent("MERGE_HEAD"))
                try Data("captured merge\n".utf8).write(to: directory.appendingPathComponent("MERGE_MSG"))
                try PBIndexReferenceCapabilityTestHarness.clearCapturedMergeState(directory: directory.path, replacementMessage: replacement)
                XCTAssertEqual(FileManager.default.fileExists(atPath: directory.appendingPathComponent("MERGE_HEAD").path), replacement != nil)
                if let replacement {
                    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("MERGE_MSG"), encoding: .utf8), replacement)
                } else {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("MERGE_MSG").path))
                }
            }
        }

        func testFinalAcknowledgementWrittenBetweenReadAndExitObservationIsAccepted() throws {
            try PBIndexReferenceTransactionTestHarness.exerciseTerminalReadRace(acknowledgement: true)
        }

        func testFinalDiagnosticWrittenBetweenReadAndExitObservationIsReported() {
            XCTAssertThrowsError(try PBIndexReferenceTransactionTestHarness.exerciseTerminalReadRace(acknowledgement: false)) { error in
                XCTAssertEqual((error as NSError).userInfo[NSLocalizedFailureReasonErrorKey] as? String, "final diagnostic\n")
            }
        }

        func testFailedCapabilityProbesAreRetriedAndSuccessIsCachedByExecutableIdentity() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitXCapability-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("peer")
            func install(_ script: String) throws {
                try ("#!/bin/sh\nprintf 'probe\\n' >> probes\n" + script).write(to: executable, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            }
            func probe() throws {
                try PBIndexReferenceCapabilityTestHarness.require(task: PBTask(launchPath: executable.path, arguments: [], inDirectory: directory.path))
            }
            try install("read command; printf 'unsupported\\n'; exit 1\n")
            for _ in 0 ..< 2 {
                XCTAssertThrowsError(try probe()) { error in
                    XCTAssertEqual((error as NSError).code, 4)
                    XCTAssertTrue(error.localizedDescription.contains("retry"))
                }
            }
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("probes"), encoding: .utf8), "probe\nprobe\n")
            try install("while read command; do printf '%s: ok\\n' \"$command\"; done\n")
            try probe()
            try probe()
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("probes"), encoding: .utf8), "probe\nprobe\nprobe\n")
        }

        func testCancellationAfterCommitAcknowledgementStillSettlesPublication() throws {
            try exercise("while read command; do printf '%s: ok\\n' \"$command\"; done", commands: ["commit\n"], acknowledgements: ["commit: ok"], cancelAfter: 0)
        }

        func testCancellationBetweenCommitSendAndAcknowledgementStillSettlesPublication() throws {
            try exercise("read command; /bin/sleep 0.05; printf 'commit: ok\\n'", commands: ["commit\n"], acknowledgements: ["commit: ok"], cancelAfter: -2)
        }

        func testAbortAllowsCooperativePeerCleanupBeforeEscalation() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitXAbort-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = "read command; printf 'wrong\\n'; read command; test \"$command\" = abort || exit 7; /bin/sleep 0.3; printf cleaned > cleanup"
            XCTAssertThrowsError(try PBIndexReferenceTransactionTestHarness.exercise(launchPath: "/bin/sh", arguments: ["-c", script], workingDirectory: directory.path, commands: ["prepare\n"], acknowledgements: ["prepare: ok"], timeout: 3, cancelAfterAcknowledgement: -1))
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("cleanup"), encoding: .utf8), "cleaned")
        }

        func testPublishedCommitDoesNotFailWhenAnOwnedDescendantRetainsStderr() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitXPublished-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = "read command; printf 'commit: ok\\n'; /bin/sh -c 'trap \"\" TERM; printf \"%s\" \"$$\" > writer.pid; exec /bin/sleep 30' >&2 & exit 0"
            try PBIndexReferenceTransactionTestHarness.exercise(launchPath: "/bin/bash", arguments: ["-c", script], workingDirectory: directory.path, commands: ["commit\n"], acknowledgements: ["commit: ok"], timeout: 5, cancelAfterAcknowledgement: -1)
            let pid = try XCTUnwrap(Int32(String(contentsOf: directory.appendingPathComponent("writer.pid"), encoding: .utf8)))
            let limit = Date().addingTimeInterval(3)
            while kill(pid, 0) == 0, Date() < limit {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(kill(pid, 0), -1)
        }

        func testOwnedProtocolAcknowledgementsAndFiniteDiagnosticsComplete() throws {
            try exercise("while IFS= read -r command; do printf '%s: ok\\n' \"$command\"; printf 'diagnostic\\n' >&2; done",
                         commands: ["start\n", "prepare\n", "commit\n"], acknowledgements: ["start: ok", "prepare: ok", "commit: ok"])
        }

        func testUnexpectedAcknowledgementRefusesPublicationAndClosesThePeer() {
            XCTAssertThrowsError(try exercise("read command; printf 'wrong: ok\\n'; read remaining", commands: ["start\n"], acknowledgements: ["start: ok"]))
        }

        func testMissingAcknowledgementAndNonzeroExitAreFailures() {
            XCTAssertThrowsError(try exercise("read command; exit 7", commands: ["start\n"], acknowledgements: ["start: ok"]))
            XCTAssertThrowsError(try exercise("read command; printf 'start: ok\\n'; exit 7", commands: ["start\n"], acknowledgements: ["start: ok"]))
        }

        func testExcessiveAcknowledgementOutputIsBounded() {
            XCTAssertThrowsError(try exercise("read command; /usr/bin/yes x | /usr/bin/head -c 100000", commands: ["start\n"], acknowledgements: ["start: ok"]))
        }

        func testPeerBackpressureAcceptsTheCompleteCommand() throws {
            let command = String(repeating: "x", count: 128 * 1024) + "\n"
            try exercise("IFS= read -r command; printf 'accepted\\n'", commands: [command], acknowledgements: ["accepted"], timeout: 10)
        }

        func testStuckPeerHasAnIndependentDeadline() {
            XCTAssertThrowsError(try exercise("read command; /bin/sleep 30", commands: ["start\n"], acknowledgements: ["start: ok"], timeout: 0.1))
        }

        func testCancellationAfterPreparationStopsTheOwnedPeer() {
            XCTAssertThrowsError(try exercise("while read command; do printf '%s: ok\\n' \"$command\"; done", commands: ["prepare\n", "commit\n"], acknowledgements: ["prepare: ok", "commit: ok"], cancelAfter: 0)) { error in
                XCTAssertEqual((error as NSError).code, 3)
            }
        }

        func testFailedLaunchReleasesPreparedDescriptors() {
            XCTAssertThrowsError(try PBIndexReferenceTransactionTestHarness.exercise(launchPath: "/gitx-missing-executable", arguments: [], workingDirectory: nil, commands: [], acknowledgements: [], timeout: 1, cancelAfterAcknowledgement: -1))
            XCTAssertThrowsError(try PBIndexReferenceTransactionTestHarness.exercise(launchPath: "/usr/bin/true", arguments: [], workingDirectory: "/gitx-missing-working-directory", commands: [], acknowledgements: [], timeout: 1, cancelAfterAcknowledgement: -1))
        }

        func testAWriterInheritedFromAnExitedPeerCannotKeepPublicationOpen() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitXReferencePeer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = "read command; printf 'ready\\n'; /bin/sh -c 'trap \"\" TERM; printf \"%s\" \"$$\" > writer.pid; exec /bin/sleep 30' & exit 0"
            XCTAssertThrowsError(try PBIndexReferenceTransactionTestHarness.exercise(launchPath: "/bin/bash", arguments: ["-c", script], workingDirectory: directory.path, commands: ["start\n"], acknowledgements: ["ready"], timeout: 0.3, cancelAfterAcknowledgement: -1))
            let pidText = try String(contentsOf: directory.appendingPathComponent("writer.pid"), encoding: .utf8)
            let pid = try XCTUnwrap(Int32(pidText))
            let limit = Date().addingTimeInterval(3)
            while kill(pid, 0) == 0, Date() < limit {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(kill(pid, 0), -1)
        }

        private func exercise(_ script: String, commands: [String], acknowledgements: [String], timeout: TimeInterval = 2, cancelAfter: Int = -1) throws {
            try PBIndexReferenceTransactionTestHarness.exercise(launchPath: "/bin/sh", arguments: ["-c", script], workingDirectory: nil,
                                                                commands: commands, acknowledgements: acknowledgements, timeout: timeout, cancelAfterAcknowledgement: cancelAfter)
        }
    #endif
}
