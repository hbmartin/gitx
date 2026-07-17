import Foundation
import OSLog // swiftlint:disable:this unused_import

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

@objc(PBIndexHookRunning)
protocol IndexHookRunning: AnyObject {
    func executeHook(_ name: String, arguments: [String]) throws
}

final class IndexRepositoryHookRunner: NSObject, IndexHookRunning {
    private unowned let repository: PBGitRepository

    init(repository: PBGitRepository) {
        self.repository = repository
        super.init()
    }

    func executeHook(_ name: String, arguments: [String]) throws {
        try repository.executeHook(name, arguments: arguments)
    }
}

@objc(PBIndexCommitRequest)
final nonisolated class IndexCommitRequest: NSObject {
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
enum IndexCommitResultKind: Int {
    case success
    case failure
    case hookFailure
}

@objc(PBIndexCommitResult)
final nonisolated class IndexCommitResult: NSObject {
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

@objc(PBIndexCommitService)
final class IndexCommitService: NSObject {
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
            try hookRunner.executeHook("prepare-commit-msg", arguments: arguments)
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
        progress: (String) -> Void
    ) -> IndexCommitResult {
        let editMessageURL = gitDirectory.appendingPathComponent("COMMIT_EDITMSG")
        do {
            try request.message.write(to: editMessageURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Writing commit message failed")
        }

        progress("Creating tree")
        let tree: String
        do {
            tree = try runner.output(arguments: ["write-tree"], input: nil, environment: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return failure("Failed to lookup tree")
        }
        guard tree.count == 40 else {
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

        progress("Creating commit")
        if request.verify {
            progress("Running hooks")
            if let hookFailure = runVerificationHook("pre-commit", arguments: [], prefix: "Pre-commit hook failed") {
                return hookFailure
            }
            if let hookFailure = runVerificationHook(
                "commit-msg",
                arguments: [editMessageURL.path],
                prefix: "Commit-msg hook failed"
            ) {
                return hookFailure
            }
        }

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
        guard commit.count == 40 else {
            return failure("Could not create a commit object")
        }

        progress("Updating HEAD")
        let subject = request.message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        do {
            _ = try runner.output(
                arguments: ["update-ref", "-m", "commit: \(subject)", "HEAD", commit],
                input: nil,
                environment: nil
            )
        } catch {
            return failure("Could not update HEAD")
        }

        progress("Running post-commit hook")
        let postCommitSucceeded: Bool
        do {
            try hookRunner.executeHook("post-commit", arguments: [])
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
        prefix: String
    ) -> IndexCommitResult? {
        do {
            try hookRunner.executeHook(name, arguments: arguments)
            return nil
        } catch {
            return IndexCommitResult(
                kind: .hookFailure,
                message: hookFailureError(prefix: prefix, error: error as NSError).localizedDescription
            )
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
