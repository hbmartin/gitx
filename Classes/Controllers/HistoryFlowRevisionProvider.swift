import Darwin
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
    case errorOutputLimitExceeded(context: String, limit: Int)
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
        case let .errorOutputLimitExceeded(context, limit):
            "Git returned more than \(limit) bytes of error output for \(context)."
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
    private static let maximumErrorOutputBytes = 64 * 1024

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
            maximumOutputBytes: maximumOutputBytes,
            maximumErrorOutputBytes: Self.maximumErrorOutputBytes
        )
        let result = try await withTaskCancellationHandler {
            try await run.result()
        } onCancel: {
            run.cancel()
        }
        // A terminated process reports a signal status; report the cancellation
        // instead of a misleading git failure.
        try Task.checkCancellation()
        guard !result.didExceedErrorOutputLimit else {
            Self.logger.error(
                "Terminated git after error output for \(context, privacy: .private) exceeded \(Self.maximumErrorOutputBytes) bytes"
            )
            throw HistoryFlowRevisionProviderError.errorOutputLimitExceeded(
                context: context,
                limit: Self.maximumErrorOutputBytes
            )
        }
        guard !result.didExceedOutputLimit else {
            Self.logger.error(
                "Terminated git after \(context, privacy: .private) exceeded \(maximumOutputBytes) bytes"
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

#if DEBUG
    // swift6-safety-justification: The mutex protects the only mutable task reference shared with cancellation callers.
    @objc(PBHistoryFlowRevisionProviderTestOperation)
    final nonisolated class HistoryFlowRevisionProviderTestOperation: NSObject, @unchecked Sendable {
        private let task = Mutex<Task<Void, Never>?>(nil)

        fileprivate func install(_ task: Task<Void, Never>) {
            self.task.withLock { $0 = task }
        }

        @objc func cancel() {
            task.withLock { $0?.cancel() }
        }
    }

    @objc(PBHistoryFlowRevisionProviderTestHarness)
    // swiftlint:disable:next unused_declaration -- Objective-C XCTest reaches this DEBUG-only bridge by runtime name.
    final nonisolated class HistoryFlowRevisionProviderTestHarness: NSObject {
        @objc(unsupportedPathDescription:)
        // swiftlint:disable:next unused_declaration -- The DEBUG-only XCTest bridge exercises this error boundary.
        static func unsupportedPathDescription(_ path: String) -> String {
            HistoryFlowRevisionProviderError.unsupportedSourcePath(path).description
        }

        @objc(
            compareRepositoryAtURL:gitExecutableURL:base:target:maximumChangedFiles:maximumBlobBytes:completionHandler:
        )
        // swiftlint:disable:next unused_declaration -- The manual XCTest compatibility declaration invokes this selector.
        static func compare(
            repositoryURL: URL,
            gitExecutableURL: URL,
            base: String,
            target: String,
            maximumChangedFiles: Int,
            maximumBlobBytes: Int,
            completionHandler: @escaping @Sendable (Data?, String?) -> Void
        ) -> HistoryFlowRevisionProviderTestOperation {
            let operation = HistoryFlowRevisionProviderTestOperation()
            let task = Task.detached {
                do {
                    let comparison = try await HistoryFlowRevisionProvider(gitExecutableURL: gitExecutableURL)
                        .comparison(
                            repositoryURL: repositoryURL,
                            base: base,
                            target: target,
                            limits: AnalysisLimits(
                                maximumChangedFiles: maximumChangedFiles,
                                maximumBlobBytes: maximumBlobBytes
                            )
                        )
                    let data = try JSONEncoder().encode(comparison)
                    completionHandler(data, nil)
                } catch {
                    completionHandler(nil, String(describing: error))
                }
            }
            operation.install(task)
            return operation
        }

        @objc(cancelledBeforeLaunchWithGitExecutableURL:completionHandler:)
        // swiftlint:disable:next unused_declaration -- The test-only compatibility header reaches this selector.
        static func cancelledBeforeLaunch(
            gitExecutableURL: URL,
            completionHandler: @escaping @Sendable (String?) -> Void
        ) -> HistoryFlowRevisionProviderTestOperation {
            let operation = HistoryFlowRevisionProviderTestOperation()
            let run = HistoryFlowGitProcessRun(
                executableURL: gitExecutableURL,
                arguments: [],
                maximumOutputBytes: 0,
                maximumErrorOutputBytes: 0
            )
            run.cancel()
            let task = Task.detached {
                do {
                    _ = try await run.result()
                    completionHandler(nil)
                } catch {
                    completionHandler(String(describing: error))
                }
            }
            operation.install(task)
            return operation
        }

        @objc(drainPipeWithFileDescriptor:)
        // swiftlint:disable:next unused_declaration -- The test-only compatibility header reaches this selector.
        static func drainPipe(fileDescriptor: Int32) -> [String: Any] {
            let stopCount = Mutex(0)
            let reader = HistoryFlowBoundedPipeReader(
                fileHandle: FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false),
                maximumBytes: 1024,
                shouldStop: { false },
                stopProcess: { stopCount.withLock { $0 += 1 } }
            )
            reader.drain()
            return [
                "data": reader.data,
                "didExceedLimit": reader.didExceedLimit,
                "stopCount": stopCount.withLock { $0 },
                "failure": reader.failure.map { HistoryFlowRevisionProviderError.readFailed(reason: $0).description } ?? "",
            ]
        }
    }
#endif

/// One git invocation whose process group remains owned until its pipes drain.
/// Blocking I/O runs on dispatch queues, outside Swift's cooperative pool.
private final nonisolated class HistoryFlowGitProcessRun: Sendable {
    struct Outcome: Sendable {
        let output: Data
        let error: Data
        let status: Int32
        let didExceedOutputLimit: Bool
        let didExceedErrorOutputLimit: Bool
    }

    private struct State {
        var isCancelled = false
        var shouldStopReading = false
        var hasLaunched = false
    }

    private struct Exit: Sendable {
        let rawStatus: Int32
        let error: NSError?

        var status: Int32 {
            let signal = rawStatus & 0x7F
            return signal == 0 ? (rawStatus >> 8) & 0xFF : signal
        }
    }

    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "FlowGitProcess")
    private let executableURL: URL
    private let arguments: [String]
    private let maximumOutputBytes: Int
    private let maximumErrorOutputBytes: Int
    private let owner = PBChildProcessOwner(queueLabel: "com.gitx.flow-git-process")
    private let state = Mutex(State())
    private let exit = Mutex<Exit?>(nil)

    init(
        executableURL: URL,
        arguments: [String],
        maximumOutputBytes: Int,
        maximumErrorOutputBytes: Int
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.maximumOutputBytes = max(0, maximumOutputBytes)
        self.maximumErrorOutputBytes = max(0, maximumErrorOutputBytes)
    }

    func cancel() {
        state.withLock { state in
            state.isCancelled = true
            state.shouldStopReading = true
            guard state.hasLaunched else { return }
            Self.logger.notice("Cancelling Flow git process group")
            // Readers cannot observe the stop flag until group cleanup has
            // been scheduled, so their lease release cannot race cancellation.
            owner.requestTermination(gracePeriod: 0, forceKillDelay: 0.25)
        }
    }

    private func stopForReadFailureOrLimit() {
        state.withLock { $0.shouldStopReading = true }
        Self.logger.error("Stopping Flow git process group after a pipe failure or byte limit")
        owner.requestTermination(gracePeriod: 0, forceKillDelay: 0)
    }

    private var shouldStopReading: Bool {
        state.withLock { $0.shouldStopReading } || exit.withLock { $0?.error != nil }
    }

    func result() async throws -> Outcome {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.runBlocking() })
            }
        }
    }

    private func runBlocking() throws -> Outcome {
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let output = Pipe()
        let error = Pipe()
        var writeEndsAreClosed = false
        defer {
            try? output.fileHandleForReading.close()
            try? error.fileHandleForReading.close()
            if !writeEndsAreClosed {
                try? output.fileHandleForWriting.close()
                try? error.fileHandleForWriting.close()
            }
        }
        let exited = DispatchGroup()
        try state.withLock { state in
            guard !state.isCancelled else { throw CancellationError() }
            exited.enter()
            do {
                try owner.launch(
                    configuration: PBChildProcessConfiguration(
                        launchPath: executableURL.path,
                        arguments: arguments,
                        environment: environment,
                        workingDirectory: nil,
                        standardInputFileDescriptor: nil,
                        standardOutputFileDescriptor: output.fileHandleForWriting.fileDescriptor,
                        standardErrorFileDescriptor: error.fileHandleForWriting.fileDescriptor
                    ),
                    retainLeaderUntilReleased: true
                ) { rawStatus, supervisionError in
                    self.exit.withLock { $0 = Exit(rawStatus: rawStatus, error: supervisionError) }
                    exited.leave()
                }
            } catch {
                exited.leave()
                throw HistoryFlowRevisionProviderError.launchFailed(
                    executable: executableURL.path,
                    reason: error.localizedDescription
                )
            }
            state.hasLaunched = true
        }
        // Only the spawned group may keep the write ends open. Keeping a parent
        // write end would prevent EOF even after every child has exited.
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        writeEndsAreClosed = true
        let outputReader = HistoryFlowBoundedPipeReader(
            fileHandle: output.fileHandleForReading,
            maximumBytes: maximumOutputBytes,
            shouldStop: { self.shouldStopReading },
            stopProcess: { self.stopForReadFailureOrLimit() }
        )
        let errorReader = HistoryFlowBoundedPipeReader(
            fileHandle: error.fileHandleForReading,
            maximumBytes: maximumErrorOutputBytes,
            shouldStop: { self.shouldStopReading },
            stopProcess: { self.stopForReadFailureOrLimit() }
        )
        let readers = [outputReader, errorReader]
        let drained = DispatchGroup()
        for reader in readers {
            drained.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { drained.leave() }
                reader.drain()
            }
        }
        drained.wait()
        owner.releaseLeaderRetention()
        exited.wait()
        // Keep the read endpoints open through termination, even when readers
        // stop early, so SIGTERM handlers can finish without receiving SIGPIPE.
        state.withLock { $0.hasLaunched = false }
        guard !state.withLock({ $0.isCancelled }) else { throw CancellationError() }
        guard let completion = exit.withLock({ $0 }) else {
            throw HistoryFlowRevisionProviderError.readFailed(reason: "Git process completion was missing.")
        }
        if let supervisionError = completion.error {
            throw HistoryFlowRevisionProviderError.readFailed(reason: supervisionError.localizedDescription)
        }
        if let failure = readers.compactMap(\.failure).first {
            throw HistoryFlowRevisionProviderError.readFailed(reason: failure)
        }
        Self.logger.debug(
            "Flow git finished status=\(completion.status) stdout=\(outputReader.data.count) stderr=\(errorReader.data.count)"
        )
        return Outcome(
            output: outputReader.data,
            error: errorReader.data,
            status: completion.status,
            didExceedOutputLimit: outputReader.didExceedLimit,
            didExceedErrorOutputLimit: errorReader.didExceedLimit
        )
    }
}

/// Drains stdout and stderr concurrently without unbounded allocation. A normal
/// process exit still drains through EOF; only cancellation or failure stops early.
private final nonisolated class HistoryFlowBoundedPipeReader: Sendable {
    private struct State {
        var data = Data()
        var didExceedLimit = false
        var failure: String?
    }

    private let fileHandle: FileHandle
    private let maximumBytes: Int
    private let shouldStop: @Sendable () -> Bool
    private let stopProcess: @Sendable () -> Void
    private let state = Mutex(State())

    init(
        fileHandle: FileHandle,
        maximumBytes: Int,
        shouldStop: @escaping @Sendable () -> Bool,
        stopProcess: @escaping @Sendable () -> Void
    ) {
        self.fileHandle = fileHandle
        self.maximumBytes = max(0, maximumBytes)
        self.shouldStop = shouldStop
        self.stopProcess = stopProcess
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
        let descriptor = fileHandle.fileDescriptor
        let existingFlags = fcntl(descriptor, F_GETFL)
        guard existingFlags >= 0, fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK) >= 0 else {
            recordFailure(errno)
            return
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !shouldStop() {
            let byteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if byteCount > 0 {
                let exceededNow = state.withLock { state in
                    let remaining = max(0, maximumBytes - state.data.count)
                    state.data.append(contentsOf: buffer.prefix(byteCount).prefix(remaining))
                    guard byteCount > remaining else { return false }
                    state.didExceedLimit = true
                    return true
                }
                if exceededNow {
                    stopProcess()
                    return
                }
                continue
            }
            if byteCount == 0 {
                return
            }
            let readError = errno
            if readError == EINTR {
                continue
            }
            if readError == EAGAIN || readError == EWOULDBLOCK {
                var descriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
                let result = poll(&descriptor, 1, 100)
                if result >= 0 || errno == EINTR {
                    continue
                }
                recordFailure(errno)
            } else {
                recordFailure(readError)
            }
            return
        }
    }

    private func recordFailure(_ errorCode: Int32) {
        state.withLock { $0.failure = String(cString: strerror(errorCode)) }
        stopProcess()
    }
}
