import Dispatch
import FlowDeltaCore
import FlowDeltaGit
import Foundation
import GitXCore
import OSLog // swiftlint:disable:this unused_import -- Logger and privacy interpolation require OSLog.
import Synchronization

nonisolated enum HistoryFlowRevisionProviderError: Error, Equatable, Sendable, CustomStringConvertible {
    case launchFailed(executable: String, reason: String)
    case unsupportedSourcePath(String)

    var description: String {
        switch self {
        case let .launchFailed(executable, reason):
            "Could not run \(executable): \(reason)"
        case let .unsupportedSourcePath(path):
            "\(path) is not in a language Flow can analyze."
        }
    }
}

/// Loads the changed source files of one revision pair through GitX's
/// configured git binary.
///
/// FlowDelta's own `GitCLIRevisionProvider` keeps a rename when either side is
/// a supported language and then traps when it loads the unsupported side, it
/// always runs `/usr/bin/git`, and a cancelled analysis leaves its git
/// processes running to completion. This provider owns those three behaviours
/// and reuses FlowDelta's error type so failures read the same either way.
nonisolated struct HistoryFlowRevisionProvider: RevisionProvider {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "FlowDelta")

    let gitExecutableURL: URL

    func comparison(
        repositoryURL: URL,
        base: String,
        target: String,
        limits: AnalysisLimits
    ) async throws -> RevisionComparison {
        let repositoryURL = repositoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repositoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw GitRevisionProviderError.repositoryNotFound(repositoryURL.path)
        }

        let canonicalBase = try await canonicalRevision(base, context: "base revision", in: repositoryURL)
        let canonicalTarget = try await canonicalRevision(target, context: "target revision", in: repositoryURL)
        let nameStatus = try await runGit(
            [
                "diff", "--name-status", "-z", "--find-renames", "--diff-filter=ACDMR",
                canonicalBase, canonicalTarget, "--",
            ],
            in: repositoryURL
        )
        let changedFiles: [HistoryFlowChangedFile]
        do {
            changedFiles = try HistoryFlowChangeSet.changedFiles(nameStatus: nameStatus) { path in
                SourceLanguage(path: path) != nil
            }
        } catch HistoryFlowChangeSetError.invalidUTF8 {
            throw GitRevisionProviderError.invalidUTF8(context: "name status")
        } catch {
            throw GitRevisionProviderError.malformedNameStatus
        }
        guard changedFiles.count <= limits.maximumChangedFiles else {
            throw GitRevisionProviderError.changedFileLimitExceeded(
                limit: limits.maximumChangedFiles,
                actual: changedFiles.count
            )
        }

        // FlowDelta 0.2.2 stores `FileComparison.unifiedDiff` but nothing reads
        // it, so the per-file `git diff` its own provider runs is skipped here.
        var files: [FileComparison] = []
        files.reserveCapacity(changedFiles.count)
        for file in changedFiles {
            var oldSnapshot: SourceSnapshot?
            if let path = file.oldPath {
                oldSnapshot = try await snapshot(path: path, revision: canonicalBase, in: repositoryURL, limits: limits)
            }
            var newSnapshot: SourceSnapshot?
            if let path = file.newPath {
                newSnapshot = try await snapshot(path: path, revision: canonicalTarget, in: repositoryURL, limits: limits)
            }
            files.append(FileComparison(old: oldSnapshot, new: newSnapshot))
        }

        Self.logger.notice(
            "Loaded \(files.count) changed source files from \(canonicalBase, privacy: .public) to \(canonicalTarget, privacy: .public)"
        )
        return RevisionComparison(
            base: RevisionIdentity(canonicalBase),
            target: RevisionIdentity(canonicalTarget),
            files: files
        )
    }

    private func canonicalRevision(_ revision: String, context: String, in repositoryURL: URL) async throws -> String {
        let data = try await runGit(["rev-parse", "--verify", "\(revision)^{commit}"], in: repositoryURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitRevisionProviderError.invalidUTF8(context: context)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func snapshot(
        path: String,
        revision: String,
        in repositoryURL: URL,
        limits: AnalysisLimits
    ) async throws -> SourceSnapshot {
        // HistoryFlowChangeSet only keeps analyzable sides; failing softly here
        // keeps a future filter change from becoming a trap.
        guard let language = SourceLanguage(path: path) else {
            throw HistoryFlowRevisionProviderError.unsupportedSourcePath(path)
        }
        let data = try await runGit(["show", "\(revision):\(path)"], in: repositoryURL)
        guard data.count <= limits.maximumBlobBytes else {
            throw GitRevisionProviderError.blobLimitExceeded(
                path: path,
                limit: limits.maximumBlobBytes,
                actual: data.count
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitRevisionProviderError.invalidUTF8(context: path)
        }
        return SourceSnapshot(path: path, revision: RevisionIdentity(revision), language: language, text: text)
    }

    /// Runs one git command, terminating it if the surrounding task is cancelled.
    private func runGit(_ arguments: [String], in repositoryURL: URL) async throws -> Data {
        try Task.checkCancellation()
        let run = HistoryFlowGitProcessRun(
            executableURL: gitExecutableURL,
            arguments: ["-C", repositoryURL.path] + arguments
        )
        let result = try await withTaskCancellationHandler {
            try await run.result()
        } onCancel: {
            run.cancel()
        }
        // A terminated process reports a signal status; report the cancellation
        // instead of a misleading git failure.
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw GitRevisionProviderError.gitFailed(
                arguments: arguments,
                status: result.status,
                message: String(data: result.error, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            )
        }
        return result.output
    }
}

/// One git invocation whose process can be terminated from a cancellation
/// handler. The blocking launch, read and wait run on a dispatch queue so they
/// never pin a thread of the Swift cooperative pool.
private final nonisolated class HistoryFlowGitProcessRun: Sendable {
    struct Outcome: Sendable {
        let output: Data
        let error: Data
        let status: Int32
    }

    private struct State {
        var isCancelled = false
        var processIdentifier: pid_t?
    }

    private let executableURL: URL
    private let arguments: [String]
    private let state = Mutex(State())

    init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    func cancel() {
        state.withLock { state in
            state.isCancelled = true
            if let processIdentifier = state.processIdentifier {
                kill(processIdentifier, SIGTERM)
            }
        }
    }

    func result() async throws -> Outcome {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.runBlocking() })
            }
        }
    }

    private func runBlocking() throws -> Outcome {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try state.withLock { state in
            guard !state.isCancelled else { throw CancellationError() }
            do {
                try process.run()
            } catch {
                throw HistoryFlowRevisionProviderError.launchFailed(
                    executable: executableURL.path,
                    reason: error.localizedDescription
                )
            }
            state.processIdentifier = process.processIdentifier
        }
        // git writes at most a few lines to stderr for these commands, so
        // draining stdout first cannot deadlock on a full stderr pipe.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        state.withLock { $0.processIdentifier = nil }
        return Outcome(output: outputData, error: errorData, status: process.terminationStatus)
    }
}
