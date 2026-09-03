import Dispatch
import FlowDeltaCore
import FlowDeltaGit
import Foundation
import GitXCore
import OSLog // swiftlint:disable:this unused_import -- Logger and privacy interpolation require OSLog.
import Synchronization

nonisolated enum HistoryFlowRevisionProviderError: Error, Equatable, Sendable, CustomStringConvertible {
    case launchFailed(executable: String, reason: String)
    case readFailed(reason: String)
    case invalidBlobSize(path: String, value: String)
    case outputLimitExceeded(context: String, limit: Int)
    case unsupportedSourcePath(String)

    var description: String {
        switch self {
        case let .launchFailed(executable, reason):
            "Could not run \(executable): \(reason)"
        case let .readFailed(reason):
            "Could not read git output: \(reason)"
        case let .invalidBlobSize(path, value):
            "Git returned an invalid size for \(path): \(value)"
        case let .outputLimitExceeded(context, limit):
            "Git returned more than \(limit) bytes for \(context)."
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
    private static let maximumRevisionOutputBytes = 4 * 1024
    private static let maximumNameStatusOutputBytes = 8 * 1024 * 1024

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
            in: repositoryURL,
            context: "changed-file list",
            maximumOutputBytes: Self.maximumNameStatusOutputBytes
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
        let data = try await runGit(
            ["rev-parse", "--verify", "\(revision)^{commit}"],
            in: repositoryURL,
            context: context,
            maximumOutputBytes: Self.maximumRevisionOutputBytes
        )
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
        let object = "\(revision):\(path)"
        let sizeData = try await runGit(
            ["cat-file", "-s", object],
            in: repositoryURL,
            context: "blob size for \(path)",
            maximumOutputBytes: Self.maximumRevisionOutputBytes
        )
        guard let sizeText = String(data: sizeData, encoding: .utf8) else {
            throw GitRevisionProviderError.invalidUTF8(context: "blob size for \(path)")
        }
        let trimmedSize = sizeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let blobSize = Int(trimmedSize), blobSize >= 0 else {
            throw HistoryFlowRevisionProviderError.invalidBlobSize(path: path, value: trimmedSize)
        }
        guard blobSize <= limits.maximumBlobBytes else {
            Self.logger.error(
                "Refused \(path, privacy: .private) at \(blobSize) bytes; Flow limit is \(limits.maximumBlobBytes)"
            )
            throw GitRevisionProviderError.blobLimitExceeded(
                path: path,
                limit: limits.maximumBlobBytes,
                actual: blobSize
            )
        }
        let data: Data
        do {
            data = try await runGit(
                ["show", object],
                in: repositoryURL,
                context: "blob \(path)",
                maximumOutputBytes: limits.maximumBlobBytes
            )
        } catch HistoryFlowRevisionProviderError.outputLimitExceeded {
            throw GitRevisionProviderError.blobLimitExceeded(
                path: path,
                limit: limits.maximumBlobBytes,
                actual: max(blobSize, limits.maximumBlobBytes + 1)
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitRevisionProviderError.invalidUTF8(context: path)
        }
        return SourceSnapshot(path: path, revision: RevisionIdentity(revision), language: language, text: text)
    }

    /// Runs one git command, terminating it if the surrounding task is cancelled.
    private func runGit(
        _ arguments: [String],
        in repositoryURL: URL,
        context: String,
        maximumOutputBytes: Int
    ) async throws -> Data {
        try Task.checkCancellation()
        let run = HistoryFlowGitProcessRun(
            executableURL: gitExecutableURL,
            arguments: ["-C", repositoryURL.path] + arguments,
            maximumOutputBytes: maximumOutputBytes
        )
        let result = try await withTaskCancellationHandler {
            try await run.result()
        } onCancel: {
            run.cancel()
        }
        // A terminated process reports a signal status; report the cancellation
        // instead of a misleading git failure.
        try Task.checkCancellation()
        guard !result.didExceedOutputLimit else {
            Self.logger.error(
                "Terminated git after \(context, privacy: .public) exceeded \(maximumOutputBytes) bytes"
            )
            throw HistoryFlowRevisionProviderError.outputLimitExceeded(
                context: context,
                limit: maximumOutputBytes
            )
        }
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
        let didExceedOutputLimit: Bool
    }

    private struct State {
        var isCancelled = false
        var processIdentifier: pid_t?
    }

    private let executableURL: URL
    private let arguments: [String]
    private let maximumOutputBytes: Int
    private let state = Mutex(State())

    init(executableURL: URL, arguments: [String], maximumOutputBytes: Int) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.maximumOutputBytes = max(0, maximumOutputBytes)
    }

    func cancel() {
        state.withLock { state in
            state.isCancelled = true
            if let processIdentifier = state.processIdentifier {
                kill(processIdentifier, SIGTERM)
            }
        }
    }

    private func terminateForOutputLimit() {
        state.withLock { state in
            if let processIdentifier = state.processIdentifier {
                kill(processIdentifier, SIGKILL)
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
        let outputReader = HistoryFlowBoundedPipeReader(
            fileHandle: output.fileHandleForReading,
            maximumBytes: maximumOutputBytes,
            limitExceeded: { self.terminateForOutputLimit() }
        )
        let errorReader = HistoryFlowBoundedPipeReader(
            fileHandle: error.fileHandleForReading,
            maximumBytes: 64 * 1024,
            limitExceeded: { self.terminateForOutputLimit() }
        )
        let readers = [outputReader, errorReader]
        let group = DispatchGroup()
        for reader in readers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                reader.drain()
            }
        }
        group.wait()
        process.waitUntilExit()
        state.withLock { $0.processIdentifier = nil }
        if let failure = readers.compactMap(\.failure).first {
            throw HistoryFlowRevisionProviderError.readFailed(reason: failure)
        }
        return Outcome(
            output: outputReader.data,
            error: errorReader.data,
            status: process.terminationStatus,
            didExceedOutputLimit: readers.contains { $0.didExceedLimit }
        )
    }
}

/// Drains one pipe without allowing a configured or compromised git binary to
/// grow the process indefinitely. Both stdout and stderr are drained in
/// parallel so neither pipe can block the child while the other is read.
private final nonisolated class HistoryFlowBoundedPipeReader: Sendable {
    private struct State {
        var data = Data()
        var didExceedLimit = false
        var failure: String?
    }

    private let fileHandle: FileHandle
    private let maximumBytes: Int
    private let limitExceeded: @Sendable () -> Void
    private let state = Mutex(State())

    init(fileHandle: FileHandle, maximumBytes: Int, limitExceeded: @escaping @Sendable () -> Void) {
        self.fileHandle = fileHandle
        self.maximumBytes = max(0, maximumBytes)
        self.limitExceeded = limitExceeded
    }

    var data: Data {
        state.withLock { $0.data }
    }

    var didExceedLimit: Bool {
        state.withLock { $0.didExceedLimit }
    }

    var failure: String? {
        state.withLock { $0.failure }
    }

    func drain() {
        do {
            while let chunk = try fileHandle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                let exceededNow = state.withLock { state in
                    guard !state.didExceedLimit else { return false }
                    let remaining = max(0, maximumBytes - state.data.count)
                    state.data.append(contentsOf: chunk.prefix(remaining))
                    guard chunk.count > remaining else { return false }
                    state.didExceedLimit = true
                    return true
                }
                if exceededNow {
                    limitExceeded()
                }
            }
        } catch {
            state.withLock { $0.failure = error.localizedDescription }
            limitExceeded()
        }
    }
}
