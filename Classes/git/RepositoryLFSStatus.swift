import Foundation
import GitXCore

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

/// What the status bar knows about a repository's Git LFS content.
nonisolated struct RepositoryLFSStatusSnapshot: Equatable, Sendable {
    let tool: LFSToolStatus
    let summary: LFSWorktreeSummary

    static let none = RepositoryLFSStatusSnapshot(tool: .missing, summary: .empty)

    /// The status bar label, or nil when the repository needs no attention.
    var statusText: String? {
        LFSPresentation.statusText(summary: summary, tool: tool)
    }
}

/// One passive scan of the checkout's LFS-tracked paths. Every command is local and takes no locks:
/// `ls-files` with an attribute pathspec, `cat-file --batch-check` and `--batch` for small index blobs, and
/// `git lfs version` when the tool's state is not yet known.
// swift6-safety-justification: The scan runs once on one background queue; `tasks` is guarded by `lock` so the
// main actor can terminate whichever command is running.
final nonisolated class RepositoryLFSStatusScan: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "LFS")

    private let executablePath: String
    private let workingDirectory: String
    private let knownTool: LFSToolStatus?
    private let lock = NSLock()
    private var currentTask: PBTask?
    private var cancelled = false

    init(executablePath: String, workingDirectory: String, knownTool: LFSToolStatus?) {
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.knownTool = knownTool
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = currentTask
        lock.unlock()
        task?.terminate()
    }

    /// Nil when the scan was cancelled or Git could not list the index.
    func run() -> RepositoryLFSStatusSnapshot? {
        guard let listing = git(["ls-files", "-z", "-s", "--", ":(attr:filter=lfs)"]) else { return nil }
        let entries = Self.indexEntries(in: listing)
        guard !entries.isEmpty else { return RepositoryLFSStatusSnapshot(tool: knownTool ?? .missing, summary: .empty) }
        let truncated = entries.count > LFSWorktreeClassifier.scanLimit
        let scanned = Array(entries.prefix(LFSWorktreeClassifier.scanLimit))
        guard let pointers = indexPointers(for: Set(scanned.map(\.objectID))) else { return nil }
        let observations = scanned.map { entry in
            LFSWorktreeObservation(path: entry.path, pointer: pointers[entry.objectID], worktree: worktreeState(of: entry.path))
        }
        let summary = LFSWorktreeClassifier.summary(of: observations, isTruncated: truncated)
        let tool = knownTool.flatMap { $0.isAvailable ? $0 : nil } ?? toolStatus()
        Self.logger.info(
            "Scanned \(scanned.count) Git LFS paths: \(summary.pointerCount) pointers, \(summary.notDownloadedPaths.count) not downloaded, truncated \(truncated, privacy: .public)"
        )
        return RepositoryLFSStatusSnapshot(tool: tool, summary: summary)
    }

    // MARK: Steps

    struct IndexEntry: Equatable {
        let objectID: String
        let path: String
    }

    /// `<mode> <object> <stage>\t<path>` records; only stage 0 and regular files can hold pointers.
    static func indexEntries(in data: Data) -> [IndexEntry] {
        data.split(separator: 0).compactMap { record in
            guard let tab = record.firstIndex(of: 0x09),
                  let header = String(data: Data(record[record.startIndex ..< tab]), encoding: .utf8),
                  let path = String(data: Data(record[record.index(after: tab)...]), encoding: .utf8)
            else { return nil }
            let fields = header.split(separator: " ")
            guard fields.count == 3, fields[0] == "100644" || fields[0] == "100755", fields[2] == "0" else { return nil }
            return IndexEntry(objectID: String(fields[1]), path: path)
        }
    }

    /// The pointers stored in the index, from the blobs small enough to be one.
    private func indexPointers(for objectIDs: Set<String>) -> [String: LFSPointer]? {
        let ordered = objectIDs.sorted()
        let input = Data((ordered.joined(separator: "\n") + "\n").utf8)
        guard let sizes = git(["cat-file", "--batch-check=%(objectname) %(objectsize)"], input: input) else { return nil }
        let small = String(decoding: sizes, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: " ")
            guard fields.count == 2, let size = Int(fields[1]), size < LFSPointer.maximumSize else { return nil }
            return String(fields[0])
        }
        guard !small.isEmpty else { return [:] }
        guard let blobs = git(["cat-file", "--batch"], input: Data((small.joined(separator: "\n") + "\n").utf8)) else { return nil }
        return Self.pointers(inBatchOutput: blobs)
    }

    /// Parses `<object> <type> <size>\n<bytes>\n` records, skipping `<object> missing` lines.
    static func pointers(inBatchOutput data: Data) -> [String: LFSPointer] {
        var pointers: [String: LFSPointer] = [:]
        var index = data.startIndex
        while index < data.endIndex, let newline = data[index...].firstIndex(of: 0x0A) {
            let header = String(decoding: data[index ..< newline], as: UTF8.self).split(separator: " ")
            if header.count == 2 {
                // A missing or ambiguous object has no contents to skip.
                logger.notice("Git reported \(String(header[1]), privacy: .public) for an index object")
                index = data.index(after: newline)
                continue
            }
            guard header.count == 3, let size = Int(header[2]), size >= 0 else { break }
            let start = data.index(after: newline)
            guard let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) else { break }
            if header[1] == "blob", let pointer = LFSPointer.parse(Data(data[start ..< end])) {
                pointers[String(header[0])] = pointer
            }
            index = end < data.endIndex ? data.index(after: end) : end
        }
        return pointers
    }

    private func worktreeState(of path: String) -> LFSWorktreeObservation.Worktree {
        let url = URL(fileURLWithPath: workingDirectory).appendingPathComponent(path)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .missing }
        let size = Int64(info.st_size)
        guard size < LFSPointer.maximumSize, let data = try? Data(contentsOf: url) else {
            return .file(size: size, pointer: nil)
        }
        return .file(size: size, pointer: LFSPointer.parse(data))
    }

    private func toolStatus() -> LFSToolStatus {
        let task = makeTask(["lfs", "version"], input: nil)
        guard register(task) else { return .missing }
        defer { unregister() }
        do {
            try task.launch()
            return LFSToolPolicy.status(terminationStatus: 0, output: String(decoding: task.standardOutputData, as: UTF8.self))
        } catch {
            Self.logger.notice("git lfs version failed: \(String(decoding: task.standardErrorData, as: UTF8.self), privacy: .public)")
            return .missing
        }
    }

    // MARK: Git

    private func git(_ arguments: [String], input: Data? = nil) -> Data? {
        let task = makeTask(arguments, input: input)
        guard register(task) else { return nil }
        defer { unregister() }
        do {
            try task.launch()
            return task.standardOutputData
        } catch {
            Self.logger.error("Git LFS status read failed: \(arguments.first ?? "", privacy: .public)")
            return nil
        }
    }

    private func makeTask(_ arguments: [String], input: Data?) -> PBTask {
        let task = PBTask(launchPath: executablePath, arguments: arguments, inDirectory: workingDirectory)
        task.timeout = 10
        task.separatesStandardError = true
        task.standardInputData = input
        task.additionalEnvironment = ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]
        return task
    }

    private func register(_ task: PBTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        currentTask = task
        return true
    }

    private func unregister() {
        lock.lock()
        currentTask = nil
        lock.unlock()
    }
}

/// Loads the LFS status for a window, off the main actor, keeping only the newest result.
@MainActor
final class RepositoryLFSStatusLoader: NSObject {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "LFS")

    private unowned let repository: PBGitRepository
    private let gitExecutablePath: String
    private let update: (RepositoryLFSStatusSnapshot) -> Void
    private var generation = 0
    private var scan: RepositoryLFSStatusScan?
    /// An available tool stays available for this executable; a missing one is checked again on each refresh, so
    /// installing git-lfs needs no relaunch.
    private var knownTool: LFSToolStatus?
    private(set) var snapshot = RepositoryLFSStatusSnapshot.none

    init(repository: PBGitRepository, gitExecutablePath: String, update: @escaping (RepositoryLFSStatusSnapshot) -> Void) {
        self.repository = repository
        self.gitExecutablePath = gitExecutablePath
        self.update = update
        super.init()
    }

    func refresh() {
        cancel()
        let requested = generation
        guard let directory = repository.workingDirectoryURL()?.path else {
            publish(.none)
            return
        }
        let scan = RepositoryLFSStatusScan(executablePath: gitExecutablePath, workingDirectory: directory, knownTool: knownTool)
        self.scan = scan
        Self.logger.debug("Loading Git LFS status generation=\(requested, privacy: .public)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = scan.run()
            DispatchQueue.main.async { [weak self] in
                // swift6-safety-justification: DispatchQueue.main runs this block on the main thread.
                MainActor.assumeIsolated {
                    guard let self, requested == self.generation else { return }
                    self.scan = nil
                    guard let result else { return }
                    if result.tool.isAvailable {
                        self.knownTool = result.tool
                    }
                    self.publish(result)
                }
            }
        }
    }

    func cancel() {
        generation += 1
        scan?.cancel()
        scan = nil
    }

    private func publish(_ snapshot: RepositoryLFSStatusSnapshot) {
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        Self.logger.info("Git LFS status is now \(snapshot.statusText ?? "quiet", privacy: .public)")
        update(snapshot)
    }
}
