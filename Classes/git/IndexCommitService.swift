import Foundation
import OSLog // swiftlint:disable:this unused_import

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

@objc(PBIndexHookRunning)
protocol IndexHookRunning: AnyObject {
    nonisolated func executeHook(
        _ name: String,
        arguments: [String],
        outputHandler: @escaping @Sendable (Data) -> Void
    ) throws
}

// swift6-safety-justification: The immutable hook service is called synchronously on the commit coordinator's serial work queue.
final nonisolated class IndexRepositoryHookRunner: NSObject, IndexHookRunning, @unchecked Sendable {
    private let hookRunner: RepositoryHookRunner

    init(repository: PBGitRepository) {
        hookRunner = RepositoryHookRunner(repository: repository)
        super.init()
    }

    func executeHook(
        _ name: String,
        arguments: [String],
        outputHandler: @escaping @Sendable (Data) -> Void
    ) throws {
        _ = try hookRunner.executeHook(name, arguments: arguments, outputHandler: outputHandler)
    }
}

// swift6-safety-justification: This immutable request snapshot is created before dispatch and consumed on one serial commit queue.
@objc(PBIndexCommitRequest)
final nonisolated class IndexCommitRequest: NSObject, @unchecked Sendable {
    @objc let message: String
    @objc let verify: Bool
    @objc let gpgSign: Bool
    @objc let amend: Bool
    @objc let environment: [String: Any]?
    @objc let parentSHAs: [String]
    @objc let hasHead: Bool

    @objc(initWithMessage:verify:gpgSign:amend:environment:parentSHAs:hasHead:)
    init(
        message: String,
        verify: Bool,
        gpgSign: Bool,
        amend: Bool,
        environment: [String: Any]?,
        parentSHAs: [String],
        hasHead: Bool
    ) {
        self.message = message
        self.verify = verify
        self.gpgSign = gpgSign
        self.amend = amend
        self.environment = environment
        self.parentSHAs = parentSHAs
        self.hasHead = hasHead
        super.init()
    }
}

@objc(PBIndexCommitResultKind)
enum IndexCommitResultKind: Int, Sendable {
    case success
    case failure
    case hookFailure
}

// swift6-safety-justification: Commit result properties are immutable value snapshots.
@objc(PBIndexCommitResult)
final nonisolated class IndexCommitResult: NSObject, @unchecked Sendable {
    @objc let kind: IndexCommitResultKind
    @objc let message: String
    @objc let sha: String?
    @objc let postCommitHookSucceeded: Bool

    init(
        kind: IndexCommitResultKind,
        message: String,
        sha: String? = nil,
        postCommitHookSucceeded: Bool = false
    ) {
        self.kind = kind
        self.message = message
        self.sha = sha
        self.postCommitHookSucceeded = postCommitHookSucceeded
        super.init()
    }
}

@objc(PBIndexCommitPhase)
enum IndexCommitPhase: Int, Sendable {
    case creatingTree
    case creatingCommit
    case runningPreCommitHook
    case runningCommitMessageHook
    case updatingHead
    case runningPostCommitHook

    nonisolated var displayName: String {
        switch self {
        case .creatingTree:
            NSLocalizedString("Creating tree", comment: "Interactive commit progress phase")
        case .creatingCommit:
            NSLocalizedString("Creating commit", comment: "Interactive commit progress phase")
        case .runningPreCommitHook:
            NSLocalizedString("Running pre-commit hook", comment: "Interactive commit progress phase")
        case .runningCommitMessageHook:
            NSLocalizedString("Running commit-msg hook", comment: "Interactive commit progress phase")
        case .updatingHead:
            NSLocalizedString("Updating HEAD", comment: "Interactive commit progress phase")
        case .runningPostCommitHook:
            NSLocalizedString("Running post-commit hook", comment: "Interactive commit progress phase")
        }
    }
}

// swift6-safety-justification: Commit events are immutable after initialization.
@objc(PBIndexCommitEvent)
nonisolated class IndexCommitEvent: NSObject, @unchecked Sendable {}

// swift6-safety-justification: The phase and display name are immutable value snapshots.
@objc(PBIndexCommitPhaseEvent)
final nonisolated class IndexCommitPhaseEvent: IndexCommitEvent, @unchecked Sendable {
    @objc let phase: IndexCommitPhase
    @objc let displayName: String

    init(phase: IndexCommitPhase) {
        self.phase = phase
        displayName = phase.displayName
        super.init()
    }
}

// swift6-safety-justification: The output string is immutable after initialization.
@objc(PBIndexCommitOutputEvent)
final nonisolated class IndexCommitOutputEvent: IndexCommitEvent, @unchecked Sendable {
    @objc let output: String

    init(output: String) {
        self.output = output
        super.init()
    }
}

// swift6-safety-justification: The completion event retains an immutable commit result.
@objc(PBIndexCommitCompletionEvent)
final nonisolated class IndexCommitCompletionEvent: IndexCommitEvent, @unchecked Sendable {
    @objc let result: IndexCommitResult

    init(result: IndexCommitResult) {
        self.result = result
        super.init()
    }
}

// swift6-safety-justification: PBTask invokes output synchronously before unblocking the serial coordinator, so sink calls cannot overlap.
private final nonisolated class IndexCommitEventSink: @unchecked Sendable {
    private let handler: (IndexCommitEvent) -> Void

    init(handler: @escaping (IndexCommitEvent) -> Void) {
        self.handler = handler
    }

    func send(_ event: IndexCommitEvent) {
        handler(event)
    }
}

// swift6-safety-justification: Service dependencies are immutable and each service instance is consumed synchronously on one commit queue.
@objc(PBIndexCommitService)
final nonisolated class IndexCommitService: NSObject, @unchecked Sendable {
    private let runner: IndexCommandRunning
    private let hookRunner: IndexHookRunning
    private let gitDirectory: URL
    private let temporaryDirectory: URL
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "IndexCommitService")

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        runner = IndexRepositoryCommandRunner(repository: repository)
        hookRunner = IndexRepositoryHookRunner(repository: repository)
        gitDirectory = repository.gitURL() ?? URL(fileURLWithPath: NSTemporaryDirectory())
        temporaryDirectory = FileManager.default.temporaryDirectory
        super.init()
    }

    @objc(initWithRunner:hookRunner:gitDirectory:temporaryDirectory:)
    init(
        runner: IndexCommandRunning,
        hookRunner: IndexHookRunning,
        gitDirectory: URL,
        temporaryDirectory: URL
    ) {
        self.runner = runner
        self.hookRunner = hookRunner
        self.gitDirectory = gitDirectory
        self.temporaryDirectory = temporaryDirectory
        super.init()
    }

    @objc(prepareCommitMessageForAmend:headSHA:existingMessage:error:)
    func prepareCommitMessage(
        forAmend amend: Bool,
        headSHA: String?,
        existingMessage: String?,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> String? {
        let messageURL = temporaryDirectory.appendingPathComponent("commit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: messageURL) }
        var arguments = [messageURL.path]
        if amend {
            arguments += ["commit", headSHA ?? ""]
            do {
                try (existingMessage ?? "").write(to: messageURL, atomically: true, encoding: .utf8)
            } catch {
                outputError?.pointee = error as NSError
                return nil
            }
        }

        do {
            try hookRunner.executeHook("prepare-commit-msg", arguments: arguments) { _ in }
        } catch {
            outputError?.pointee = hookFailureError(prefix: "prepare-commit-msg hook failed", error: error as NSError)
            logger.error("Prepare commit message hook failed")
            return nil
        }
        do {
            var message = try String(contentsOf: messageURL, encoding: .utf8)
            if message.hasSuffix("\n") {
                message.removeLast()
            }
            return message
        } catch {
            outputError?.pointee = error as NSError
            return nil
        }
    }

    @objc(commitWithRequest:progress:)
    func commit(
        with request: IndexCommitRequest,
        progress: @escaping (String) -> Void
    ) -> IndexCommitResult {
        let sink = IndexCommitEventSink { event in
            guard let phaseEvent = event as? IndexCommitPhaseEvent else { return }
            switch phaseEvent.phase {
            case .creatingTree:
                progress("Creating tree")
            case .creatingCommit:
                progress("Creating commit")
            case .runningPreCommitHook:
                progress("Running hooks")
            case .runningCommitMessageHook:
                break
            case .updatingHead:
                progress("Updating HEAD")
            case .runningPostCommitHook:
                progress("Running post-commit hook")
            }
        }
        return performCommit(with: request, sink: sink)
    }

    @objc(commitWithRequest:eventHandler:)
    func commit(
        with request: IndexCommitRequest,
        eventHandler: @escaping @Sendable (IndexCommitEvent) -> Void
    ) -> IndexCommitResult {
        let sink = IndexCommitEventSink(handler: eventHandler)
        let result = performCommit(with: request, sink: sink)
        sink.send(IndexCommitCompletionEvent(result: result))
        return result
    }

    private func performCommit(
        with request: IndexCommitRequest,
        sink: IndexCommitEventSink
    ) -> IndexCommitResult {
        let editMessageURL = gitDirectory.appendingPathComponent("COMMIT_EDITMSG")
        do {
            try request.message.write(to: editMessageURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Writing commit message failed")
        }

        sink.send(IndexCommitPhaseEvent(phase: .creatingTree))
        let tree: String
        do {
            tree = try runner.output(arguments: ["write-tree"], input: nil, environment: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return failure("Failed to lookup tree")
        }
        // Accept SHA-1 (40) and SHA-256 (64) object IDs.
        guard tree.count == 40 || tree.count == 64 else {
            return failure("Creating tree failed")
        }

        var arguments = ["commit-tree", tree]
        if request.amend {
            for parent in request.parentSHAs {
                arguments += ["-p", parent]
            }
        } else if request.hasHead {
            arguments += ["-p", "HEAD"]
        }
        if request.gpgSign {
            arguments.append("--gpg-sign")
        }

        if request.verify {
            sink.send(IndexCommitPhaseEvent(phase: .runningPreCommitHook))
            if let hookFailure = runVerificationHook(
                "pre-commit",
                arguments: [],
                prefix: "Pre-commit hook failed",
                sink: sink
            ) {
                return hookFailure
            }
            sink.send(IndexCommitPhaseEvent(phase: .runningCommitMessageHook))
            if let hookFailure = runVerificationHook(
                "commit-msg",
                arguments: [editMessageURL.path],
                prefix: "Commit-msg hook failed",
                sink: sink
            ) {
                return hookFailure
            }
        }

        sink.send(IndexCommitPhaseEvent(phase: .creatingCommit))
        let editedMessage = (try? String(contentsOf: editMessageURL, encoding: .utf8)) ?? request.message
        let commit: String
        do {
            commit = try runner.output(
                arguments: arguments,
                input: editedMessage,
                environment: request.environment
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            let taskError = error as NSError
            let output = taskError.userInfo[PBTaskTerminationOutputKey] as? String
            if request.gpgSign, output?.hasPrefix("error: cannot run gpg") == true {
                return failure(
                    "GPG signing seems to have failed.\n\nMake sure you have configured your environment correctly and have set gpg.program to point at your gpg binary."
                )
            }
            return failure("Could not create a commit object")
        }
        // Accept SHA-1 (40) and SHA-256 (64) object IDs.
        guard commit.count == 40 || commit.count == 64 else {
            return failure("Could not create a commit object")
        }

        sink.send(IndexCommitPhaseEvent(phase: .updatingHead))
        let subject = request.message.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? ""
        do {
            _ = try runner.output(
                arguments: ["update-ref", "-m", "commit: \(subject)", "HEAD", commit],
                input: nil,
                environment: nil
            )
        } catch {
            return failure("Could not update HEAD")
        }

        sink.send(IndexCommitPhaseEvent(phase: .runningPostCommitHook))
        let postCommitSucceeded: Bool
        do {
            try streamHook("post-commit", arguments: [], sink: sink)
            postCommitSucceeded = true
        } catch {
            postCommitSucceeded = false
        }
        let description = postCommitSucceeded
            ? "Successfully created commit \(commit)"
            : "Post-commit hook failed, but successfully created commit \(commit)"
        logger.debug("Commit orchestration completed")
        return IndexCommitResult(
            kind: .success,
            message: description,
            sha: commit,
            postCommitHookSucceeded: postCommitSucceeded
        )
    }

    private func runVerificationHook(
        _ name: String,
        arguments: [String],
        prefix: String,
        sink: IndexCommitEventSink
    ) -> IndexCommitResult? {
        do {
            try streamHook(name, arguments: arguments, sink: sink)
            return nil
        } catch {
            return IndexCommitResult(
                kind: .hookFailure,
                message: hookFailureError(prefix: prefix, error: error as NSError).localizedDescription
            )
        }
    }

    private func streamHook(
        _ name: String,
        arguments: [String],
        sink: IndexCommitEventSink
    ) throws {
        let decoder = IncrementalUTF8Decoder()
        let emit: @Sendable (String) -> Void = { output in
            guard !output.isEmpty else { return }
            sink.send(IndexCommitOutputEvent(output: output))
        }

        do {
            try hookRunner.executeHook(name, arguments: arguments) { data in
                emit(decoder.append(data))
            }
            emit(decoder.finish())
        } catch {
            emit(decoder.finish())
            throw error
        }
    }

    private func hookFailureError(prefix: String, error: NSError?) -> NSError {
        let taskError = error?.userInfo[NSUnderlyingErrorKey] as? NSError
        let output = taskError?.userInfo[PBTaskTerminationOutputKey] as? String
        let description = prefix + ((output?.isEmpty == false) ? ":\n\(output ?? "")" : "")
        return NSError(
            domain: "PBGitIndexCommitError",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    private func failure(_ message: String) -> IndexCommitResult {
        logger.error("Commit orchestration failed")
        return IndexCommitResult(kind: .failure, message: message)
    }
}

// swiftlint:enable unused_declaration
