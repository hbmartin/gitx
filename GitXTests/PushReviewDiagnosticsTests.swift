import Foundation
import ObjectiveC
import XCTest

private final nonisolated class PushReviewTimeoutTask: PBTask {
    private(set) var configuredDeadline: TimeInterval?

    override var timeout: TimeInterval {
        get { super.timeout }
        set {
            configuredDeadline = newValue
            super.timeout = 0.05
        }
    }
}

private final nonisolated class PushReviewReasonlessTask: PBTask {
    override func launch() throws {
        throw NSError(domain: "GitX.PushReview.Fixture", code: 7,
                      userInfo: [NSLocalizedDescriptionKey: "Controlled launch failure"])
    }
}

private final nonisolated class PushReviewTaskRepository: PBGitRepository {
    private(set) var tasks: [PBTask] = []
    var script = "exit 1"
    var forcesShortTimeout = false
    var forcesReasonlessFailure = false
    override func task(withArguments _: [Any]?) -> PBTask {
        let task = forcesReasonlessFailure
            ? PushReviewReasonlessTask(launchPath: "/bin/sh", arguments: [], inDirectory: nil)
            : forcesShortTimeout
            ? PushReviewTimeoutTask(launchPath: "/bin/sh", arguments: ["-c", script], inDirectory: nil)
            : PBTask(launchPath: "/bin/sh", arguments: ["-c", script], inDirectory: nil)
        tasks.append(task)
        return task
    }
}

@MainActor
final class PushReviewDiagnosticsTests: XCTestCase {
    @objc(gitx_pushReviewMissingGitExecutablePath)
    private nonisolated class func missingGitExecutablePath() -> String? {
        nil
    }

    func testMissingExecutableIdentityUsesTheUnavailablePathBoundary() throws {
        #if DEBUG
            let original = try XCTUnwrap(class_getClassMethod(PBGitBinary.self, NSSelectorFromString("path")))
            let replacement = try XCTUnwrap(class_getClassMethod(Self.self, #selector(Self.missingGitExecutablePath)))
            method_exchangeImplementations(original, replacement)
            defer { method_exchangeImplementations(original, replacement) }
            let repository = PushReviewTaskRepository()
            let identity = PBMilestone2ProductCoverageHarness.reviewEvidenceExecutableIdentity(repository: repository)
            XCTAssertFalse(identity.isEmpty)
            XCTAssertEqual(identity.components(separatedBy: "|").first,
                           URL(fileURLWithPath: "").resolvingSymlinksInPath().path)
        #else
            throw XCTSkip("Shipped runner boundary is exposed by the Debug harness")
        #endif
    }

    func testReasonlessLaunchFailureUsesSafeDescriptionAndIncompleteArtifact() throws {
        #if DEBUG
            let repository = PushReviewTaskRepository()
            repository.forcesReasonlessFailure = true
            let result = PBMilestone2ProductCoverageHarness.reviewPushCommandResult(repository: repository, arguments: ["push"])
            let error = try XCTUnwrap(result.error) as NSError
            XCTAssertEqual(error.localizedFailureReason, "Controlled launch failure")
            XCTAssertNil(result.terminationStatus)
            XCTAssertFalse(try XCTUnwrap(result.diagnosticArtifact).captureComplete)
        #else
            throw XCTSkip("Shipped runner boundary is exposed by the Debug harness")
        #endif
    }

    func testCaptureFailuresRetainBoundedGitDiagnosticsAndReadablePorcelain() throws {
        #if DEBUG
            for fault in ["createDirectory", "createReport", "redactionWrite"] {
                let repository = PushReviewTaskRepository()
                repository.script = "printf '!\\trefs/heads/main:refs/heads/main\\t[rejected] (protected branch)\\n'; printf 'remote: permission denied for https://user:secret@example.invalid/repo\\n' >&2; exit 1"
                let result = PBMilestone2ProductCoverageHarness.reviewPushCommandResult(repository: repository, arguments: ["push", "--porcelain"], captureFault: fault)
                let artifact = try XCTUnwrap(result.diagnosticArtifact)
                defer { artifact.discard() }
                XCTAssertTrue(result.standardOutput.contains("[rejected]"), fault)
                XCTAssertFalse(result.standardErrorComplete, "Failed diagnostic capture must not claim complete evidence")
                XCTAssertEqual(result.standardOutputComplete, fault != "createDirectory")
                let taskError = try XCTUnwrap(result.error) as NSError
                let outer = NSError(domain: "GitX.PushReview.Fixture", code: 1, userInfo: [NSUnderlyingErrorKey: taskError])
                let text = PBErrorMessagePresentation.infoText(for: outer)
                XCTAssertTrue(text.contains("refs/heads/main → refs/heads/main: [rejected] (protected branch)"), fault)
                XCTAssertTrue(text.contains("permission denied"), fault)
                XCTAssertFalse(text.contains("secret"), fault)
            }
            let repository = PushReviewTaskRepository()
            repository.script = "printf '!\\thttps://user:secret@example.invalid/repo\\trejected\\n'; exit 1"
            let result = PBMilestone2ProductCoverageHarness.reviewPushCommandResult(repository: repository, arguments: ["push", "--porcelain"])
            defer { result.diagnosticArtifact?.discard() }
            let task = try XCTUnwrap(result.error) as NSError
            let outer = NSError(domain: "GitX.PushReview.Fixture", code: 1, userInfo: [NSUnderlyingErrorKey: task])
            XCTAssertFalse(PBErrorMessagePresentation.infoText(for: outer).contains("secret"), "Formatting must not obscure a URL before redaction")
        #else
            throw XCTSkip("Shipped runner boundary is exposed by the Debug harness")
        #endif
    }

    func testReadablePushFailureRedactsBeforeTheStandardErrorTailIsSelected() throws {
        #if DEBUG
            let repository = PushReviewTaskRepository()
            // The retained suffix starts inside userinfo, after its scheme has gone.
            repository.script = "printf 'remote: https://user:' >&2; /usr/bin/awk 'BEGIN { for (i = 0; i < 65536; i++) printf \"x\"; }' >&2; printf 'FAKE-SECRET@example.invalid/repo\\npermission denied\\n' >&2; exit 1"
            let result = PBMilestone2ProductCoverageHarness.reviewPushCommandResult(repository: repository, arguments: ["push"])
            let artifact = try XCTUnwrap(result.diagnosticArtifact)
            defer { artifact.discard() }
            let error = try XCTUnwrap(result.error) as NSError
            let displayed = PBErrorMessagePresentation.infoText(for: error)
            XCTAssertTrue(displayed.contains("permission denied"))
            XCTAssertFalse(displayed.contains("FAKE-SECRET"))
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            try artifact.writeRedactedReport(to: destination)
            XCTAssertFalse(try String(contentsOf: destination, encoding: .utf8).contains("FAKE-SECRET"))
        #else
            throw XCTSkip("Shipped runner boundary is exposed by the Debug harness")
        #endif
    }

    func testCapturePreparationFailureNeverPresentsAClippedCredentialSuffix() throws {
        #if DEBUG
            for fault in ["createDirectory", "createReport", "redactionWrite", "partialAppend"] {
                let repository = PushReviewTaskRepository()
                repository.script = "printf 'remote: https://user:' >&2; /usr/bin/awk 'BEGIN { for (i = 0; i < 65536; i++) printf \"x\"; }' >&2; printf 'FAKE-SECRET@example.invalid/repo\\npermission denied\\n' >&2; exit 7"
                let result = PBMilestone2ProductCoverageHarness.reviewPushCommandResult(repository: repository, arguments: ["push"], captureFault: fault)
                let artifact = try XCTUnwrap(result.diagnosticArtifact)
                defer { artifact.discard() }
                let error = try XCTUnwrap(result.error) as NSError
                let text = PBErrorMessagePresentation.infoText(for: error)
                XCTAssertFalse(text.contains("FAKE-SECRET"), fault)
                XCTAssertEqual(result.terminationStatus, 7)
                XCTAssertTrue(try XCTUnwrap(repository.tasks.first).standardErrorTruncated)
                if fault != "partialAppend" {
                    XCTAssertTrue(text.contains("original beginning was discarded"), fault)
                }
                XCTAssertFalse(artifact.captureComplete)
            }
        #else
            throw XCTSkip("Fault injection belongs to the Debug harness")
        #endif
    }

    func testReportFailureAfterTimeoutUpdatesStreamEvidenceStatus() throws {
        #if DEBUG
            let repository = PushReviewTaskRepository()
            repository.forcesShortTimeout = true
            repository.script = "trap 'exit 0' TERM; printf diagnostic >&2; while :; do :; done"
            let result = PBMilestone2ProductCoverageHarness.reviewPushCommandResult(repository: repository, arguments: ["push"], captureFault: "createReport")
            defer { result.diagnosticArtifact?.discard() }
            XCTAssertEqual(try (XCTUnwrap(result.error) as NSError).code, Int(PBTaskErrorCode.timeoutError.rawValue))
            XCTAssertFalse(result.standardErrorComplete)
            XCTAssertFalse(try XCTUnwrap(result.diagnosticArtifact).captureComplete)
        #else
            throw XCTSkip("Fault injection belongs to the Debug harness")
        #endif
    }

    func testRedactedReadableExcerptsRemainBoundedAndReportTruncation() throws {
        #if DEBUG
            for payload in [String(repeating: "x", count: 70000), String(repeating: "🙂", count: 18000)] {
                let capture = PBTaskDiagnosticCapture()
                capture.appendStandardOutput(Data(("output-head\n" + payload).utf8))
                capture.appendStandardError(Data((payload + "\nerror-tail").utf8))
                capture.finishStandardOutput(reachedEOF: true)
                capture.finishStandardError(reachedEOF: true)
                let artifact = capture.seal()
                defer { artifact.discard() }
                let excerpts = try XCTUnwrap(PBTaskDiagnosticCaptureTestHarness.readableExcerpts(for: artifact))
                XCTAssertEqual(excerpts.count, 2)
                XCTAssertTrue(excerpts.allSatisfy { $0.utf8.count <= 64 * 1024 && $0.contains("truncated display excerpt") })
                XCTAssertTrue(excerpts[0].hasPrefix("output-head"))
                XCTAssertTrue(excerpts[1].hasSuffix("error-tail"))
                XCTAssertFalse(excerpts.contains { $0.contains("�") })
            }
        #else
            throw XCTSkip("Shipped excerpt boundary is exposed by the Debug harness")
        #endif
    }

    func testShippedGeneralLaunchPreservesMutationAndFailureWithoutStoredOutput() throws {
        #if DEBUG
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try GitXTestGitFixture.run(["init", "--quiet"], in: directory)
            let repository = try RepositoryTestGitRepository(url: directory)
            defer { repository.revisionList?.cleanup() }
            try PBMilestone2ProductCoverageHarness.reviewGeneralLaunch(repository: repository, arguments: ["config", "--local", "fixture.value", "saved"])
            XCTAssertEqual(try GitXTestGitFixture.run(["config", "--get", "fixture.value"], in: directory).standardOutput, "saved\n")
            XCTAssertThrowsError(try PBMilestone2ProductCoverageHarness.reviewGeneralLaunch(repository: repository, arguments: ["config", "--get", "missing.fixture-key"])) { error in
                XCTAssertEqual((error as NSError).domain, PBTaskErrorDomain)
            }
        #else
            throw XCTSkip("Shipped runner boundary is exposed by the Debug harness")
        #endif
    }

    func testShippedRejectedPushBoundsStatusButRetainsBothCompleteStreams() throws {
        #if DEBUG
            let repository = PushReviewTaskRepository()
            repository.script = """
            /usr/bin/awk 'BEGIN { for(i=0;i<70000;i++) printf "o"; printf "stdout-final\\n"; }' &
            /usr/bin/awk 'BEGIN { printf "stderr-head\\n"; for(i=0;i<70000;i++) printf "e"; printf "stderr-final\\n"; }' >&2 &
            wait
            exit 1
            """
            let result = PBMilestone2ProductCoverageHarness.reviewPushCommandResult(repository: repository, arguments: ["push"])
            XCTAssertNotNil(result.error)
            XCTAssertEqual(result.standardOutput.utf8.count, 64 * 1024)
            XCTAssertFalse(result.standardOutputComplete)
            XCTAssertTrue(result.standardErrorComplete)
            let artifact = try XCTUnwrap(result.diagnosticArtifact)
            defer { artifact.discard() }
            XCTAssertTrue(artifact.captureComplete)
            XCTAssertTrue(artifact.redactedSummary.contains("stdout-final"))
            XCTAssertTrue(artifact.redactedSummary.contains("stderr-head"))
            XCTAssertTrue(artifact.redactedSummary.contains("stderr-final"))
            XCTAssertLessThanOrEqual(artifact.redactedSummary.utf8.count, 16 * 1024)
        #else
            throw XCTSkip("Shipped runner boundary is exposed by the Debug harness")
        #endif
    }

    func testSuccessfulPushUsesServerHintAndDiscardsPrivateCapture() throws {
        #if DEBUG
            let repository = PushReviewTaskRepository()
            repository.script = "printf 'Done\\n'; printf 'To https://example.invalid/team/repo.git\\nremote: https://user:secret@example.invalid/unsafe\\nremote: https://example.invalid/team/repo/pull/new/feature\\n' >&2"
            let result = PBMilestone2ProductCoverageHarness.reviewPushCommandResult(repository: repository, arguments: ["push"])
            XCTAssertNil(result.error)
            XCTAssertEqual(result.standardOutput, "Done\n")
            XCTAssertTrue(result.standardOutputComplete)
            XCTAssertEqual(result.browserHintOutput, "remote: https://example.invalid/team/repo/pull/new/feature")
            XCTAssertEqual(PBRepositoryRemoteURLCoordinator.shared.firstHTTPURL(in: result.browserHintOutput)?.absoluteString,
                           "https://example.invalid/team/repo/pull/new/feature", "The browser consumer must accept the filtered server hint")
            XCTAssertNil(result.diagnosticArtifact)
            let retainedCapture = try XCTUnwrap(repository.tasks.last?.diagnosticCapture?.artifact)
            XCTAssertFalse(retainedCapture.captureComplete, "Successful output is discarded after extracting the browser hint")
            XCTAssertThrowsError(try retainedCapture.writeRedactedReport(to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        #else
            throw XCTSkip("Shipped runner boundary is exposed by the Debug harness")
        #endif
    }

    func testTimedOutPushRetainsOutputAndReportsUnknownRemoteCompletion() throws {
        #if DEBUG
            let repository = PushReviewTaskRepository()
            repository.forcesShortTimeout = true
            repository.script = "printf 'started\\n'; /bin/sleep 5"
            let result = PBMilestone2ProductCoverageHarness.reviewPushCommandResult(repository: repository, arguments: ["push"])
            let error = try XCTUnwrap(result.error) as NSError
            XCTAssertEqual(error.domain, PBTaskErrorDomain)
            XCTAssertEqual(error.code, Int(PBTaskErrorCode.timeoutError.rawValue))
            XCTAssertTrue(error.localizedFailureReason?.contains("may have completed") == true)
            XCTAssertTrue(error.localizedRecoverySuggestion?.contains("fetch") == true)
            XCTAssertEqual((repository.tasks.last as? PushReviewTimeoutTask)?.configuredDeadline, 600)
            XCTAssertTrue(try XCTUnwrap(result.diagnosticArtifact).redactedSummary.contains("started"))
        #else
            throw XCTSkip("Shipped runner boundary is exposed by the Debug harness")
        #endif
    }

    func testMissingCommitTreeAndOptionalReferencesBridgeAsNil() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try GitXTestGitFixture.run(["init", "--quiet"], in: directory)
        let missingTree = String(repeating: "0", count: 40)
        let object = "tree \(missingTree)\nauthor GitX Tests <gitx-tests@example.invalid> 1000000000 +0000\ncommitter GitX Tests <gitx-tests@example.invalid> 1000000000 +0000\n\nMissing tree fixture\n"
        let oid = try GitXTestGitFixture.run(["hash-object", "--literally", "-t", "commit", "-w", "--stdin"], in: directory, standardInput: Data(object.utf8)).standardOutput.trimmingCharacters(in: .newlines)
        let repository = try RepositoryTestGitRepository(url: directory)
        defer { repository.revisionList?.cleanup() }
        let gitRepository = try XCTUnwrap(repository.gtRepo)
        let gtCommit = try XCTUnwrap(try gitRepository.lookUpObject(byRevParse: oid) as? GTCommit)
        let commit = PBGitCommit(repository: repository, andCommit: gtCommit)
        XCTAssertNil(commit.treeContents)
        XCTAssertNil(commit.refs)
    }

    func testCapturedTimeoutShowsSafeDetailsAndAuxiliaryExportControl() throws {
        #if DEBUG
            let capture = PBTaskDiagnosticCapture()
            capture.appendStandardOutput(Data("early status\n".utf8))
            capture.appendStandardError(Data(("remote: initial diagnostic\n" + String(repeating: "remote: detailed push output\n", count: 5000) + "remote: final diagnostic\n").utf8))
            capture.finishStandardOutput(reachedEOF: true)
            capture.finishStandardError(reachedEOF: false)
            let artifact = capture.seal()
            defer { artifact.discard() }
            let taskError = NSError(domain: PBTaskErrorDomain, code: Int(PBTaskErrorCode.timeoutError.rawValue),
                                    userInfo: [NSLocalizedDescriptionKey: "Push timed out", "PBTaskDiagnosticArtifact": artifact])
            let error = NSError(domain: "PBGitXErrorDomain", code: 0,
                                userInfo: [NSLocalizedDescriptionKey: "Push failed", NSUnderlyingErrorKey: taskError])
            XCTAssertTrue(PBErrorMessagePresentation.infoText(for: error).contains("final diagnostic"))
            let window = PBMilestone2ProductCoverageHarness.reviewPushFailureWindow(error: error)
            defer {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                }
                window.close()
            }
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in window.attachedSheet != nil }, object: nil)
            wait(for: [ready], timeout: 5)
            let sheet = try XCTUnwrap(window.attachedSheet)
            let buttons = try descendants(of: XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }
            XCTAssertTrue(buttons.contains { $0.title == "Save Push Output…" && $0.action != nil && $0.target != nil })
            let closeButton = try XCTUnwrap(buttons.first { $0.action == NSSelectorFromString("closeMessageSheet:") },
                                            buttons.map { "\($0.title): \($0.action.map(NSStringFromSelector) ?? "nil")" }.joined(separator: ", "))
            let exportButton = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "GitX.Push.SaveOutput" })
            var visited = Set<ObjectIdentifier>()
            var next: NSView? = closeButton
            while let view = next, visited.insert(ObjectIdentifier(view)).inserted {
                next = view.nextKeyView
            }
            XCTAssertTrue(visited.contains(ObjectIdentifier(exportButton)), "Export must be reachable through the sheet's key view loop")
            try attachScreenshot(of: sheet, named: "Review-Fixes-Push-Output-Summary-And-Export")
            closeButton.performClick(nil)
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in window.attachedSheet == nil }, object: nil)
            wait(for: [closed], timeout: 5)
        #else
            throw XCTSkip("Diagnostic sheet is exposed by the Debug harness")
        #endif
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    func testRepeatedProgressAndRetryCallbacksDoNotStartOrFinishAnotherPush() throws {
        #if DEBUG
            XCTAssertEqual(PBMilestone2ProductCoverageHarness.reviewPushRepeatedCallbacksProof(), (1 << 6) - 1)
        #else
            throw XCTSkip("Shipped workflow boundary is exposed by the Debug harness")
        #endif
    }

    func testNormalAndFrozenPushesHaveTenMinuteDeadline() throws {
        #if DEBUG
            let repository = PushReviewTaskRepository()
            for arguments in [["push", "--porcelain", "--", "origin", "refs/heads/main"],
                              ["push", "--porcelain", "--force-with-lease=refs/heads/main:" + String(repeating: "a", count: 40), "--", "origin", String(repeating: "b", count: 40) + ":refs/heads/main"]]
            {
                let result = PBMilestone2ProductCoverageHarness.reviewPushCommandResult(repository: repository, arguments: arguments)
                XCTAssertEqual(result.terminationStatus, 1)
                XCTAssertEqual(repository.tasks.last?.timeout, 600)
            }
            XCTAssertEqual(PBTask(launchPath: "/bin/sh", arguments: [], inDirectory: nil).timeout, 30)
        #else
            throw XCTSkip("Shipped runner boundary is exposed by the Debug harness")
        #endif
    }

    func testBrowserHintExcludesPorcelainTransportURL() {
        let output = "To https://example.invalid/team/repo.git\nDone\nremote: Create a pull request:\nremote: https://example.invalid/team/repo/pull/new/feature\n"
        XCTAssertEqual(PBRepositoryRemoteURLCoordinator.shared.firstHTTPURL(in: output)?.absoluteString,
                       "https://example.invalid/team/repo/pull/new/feature")
        XCTAssertNil(PBRepositoryRemoteURLCoordinator.shared.firstHTTPURL(in: "To https://example.invalid/team/repo.git\nDone\n"))
        XCTAssertNil(PBRepositoryRemoteURLCoordinator.shared.firstHTTPURL(in: "client hook: https://example.invalid/arbitrary\n"))
        XCTAssertEqual(PBRepositoryRemoteURLCoordinator.shared.firstHTTPURL(in: "remote:\t https://example.invalid/pull/new/feature\n")?.absoluteString,
                       "https://example.invalid/pull/new/feature")
        XCTAssertEqual(PBRepositoryRemoteURLCoordinator.shared.firstHTTPURL(in: "remote: ftp://example.invalid/unsupported\nremote: http://example.invalid/pull/new/feature\n")?.absoluteString,
                       "http://example.invalid/pull/new/feature")
        XCTAssertEqual(PBRepositoryRemoteURLCoordinator.shared.firstHTTPURL(in: "client: https://example.invalid/wrong\nremote: https://user:secret@example.invalid/unsafe https://example.invalid/pull/new/feature\n")?.absoluteString,
                       "https://example.invalid/pull/new/feature")
    }

    func testMalformedCredentialAuthorityDoesNotExposeSecrets() {
        for secret in ["secret/with/slashes", "secret?with=query", "secret#with-fragment", "secret with spaces", "密碼/secret"] {
            let input = "Push failed for https://user:\(secret)@example.invalid/repo"
            XCTAssertEqual(PBTaskDiagnostics.redacted(input), "Push failed for https://[redacted]@example.invalid/repo")
        }
    }

    func testProtectedHistoryOutputContainsOnlyStandardOutput() throws {
        #if DEBUG
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try GitXTestGitFixture.run(["init", "--quiet"], in: directory)
            try GitXTestGitFixture.run(["commit", "--quiet", "--allow-empty", "-m", "Fixture"], in: directory)
            let expected = try GitXTestGitFixture.run(["rev-parse", "HEAD"], in: directory).standardOutput
            let repository = try RepositoryTestGitRepository(url: directory)
            defer { repository.revisionList?.cleanup() }
            XCTAssertEqual(try PBMilestone2ProductCoverageHarness.reviewHistoryOutput(repository: repository, arguments: ["log", "--format=%H", "-1"]), expected)
            let controlled = PushReviewTaskRepository()
            controlled.script = "printf 'machine-readable-stdout\\n'; printf 'warning on stderr\\n' >&2"
            XCTAssertEqual(try PBMilestone2ProductCoverageHarness.reviewHistoryOutput(repository: controlled, arguments: ["log"]), "machine-readable-stdout\n")
            XCTAssertEqual(controlled.tasks.last?.standardErrorData, Data("warning on stderr\n".utf8))
        #else
            throw XCTSkip("Shipped runner boundary is exposed by the Debug harness")
        #endif
    }
}
