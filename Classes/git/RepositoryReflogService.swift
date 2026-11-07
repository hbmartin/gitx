import CryptoKit
import Foundation
import GitXCore
import OSLog // swiftlint:disable:this unused_import -- Logger requires OSLog; removing it fails Debug compilation.

nonisolated struct RepositoryReflogPage: Sendable {
    let entries: [ReflogEntry]
    let hasMore: Bool
    let fingerprint: WorktreeFileFingerprint?
}

nonisolated struct RepositoryRecoveryPreview: Equatable, Sendable {
    let target: String
    let previousHead: String
    let branch: String
    let mode: ReflogResetMode
    let affectedPaths: [String]
    let discardedPaths: [String]
    fileprivate let evidence: Data
}

nonisolated enum RepositoryReflogError: Error, LocalizedError {
    case unavailable(String)
    case changed
    case resetFailed(backup: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason): reason
        case .changed: "The repository changed. Refresh the reflog or prepare a new reset preview, then confirm again."
        case let .resetFailed(backup, reason): "Reset did not complete. The previous commit is preserved in \(backup).\n\n\(reason)"
        }
    }
}

/// Immutable process configuration; the lock owns cancellation and the active
/// task. Repository/index mutation ownership remains with IndexWriterCoordinator.
// swift6-safety-justification: Configuration is immutable; the lock protects cancellation and active process access.
final nonisolated class RepositoryReflogService: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "ReflogRecovery")
    private let context: PBTaskExecutionContext
    private let writer: IndexWriterCoordinator
    private let lock = NSRecursiveLock()
    private var cancelled = false
    private var activeTask: PBTask?

    init(repository: PBGitRepository) throws {
        context = try repository.task(withArguments: []).executionContext()
        writer = IndexWriterCoordinator.coordinator(for: repository)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        activeTask?.terminate()
        lock.unlock()
    }

    private func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled {
            throw CancellationError()
        }
    }

    private func data(_ arguments: [String], allowTruncation: Bool = false) throws -> Data {
        let task = PBTask(launchPath: context.launchPath, arguments: context.arguments + arguments, inDirectory: context.workingDirectory)
        task.additionalEnvironment = context.environment.merging([
            "GIT_NO_REPLACE_OBJECTS": "1", "GIT_GRAFT_FILE": "/dev/null/gitx-recovery-grafts",
            "GIT_NO_LAZY_FETCH": "1", "GIT_OPTIONAL_LOCKS": "0",
        ]) { _, value in value }
        task.separatesStandardError = true
        task.timeout = 60
        lock.lock()
        if cancelled {
            lock.unlock(); throw CancellationError()
        }
        activeTask = task
        lock.unlock()
        defer {
            lock.lock()
            if activeTask === task {
                activeTask = nil
            }
            lock.unlock()
        }
        try task.launch()
        try checkCancellation()
        guard allowTruncation || !task.standardOutputTruncated else { throw ReflogReadError.incompleteOutput }
        return task.standardOutputData
    }

    private func text(_ arguments: [String]) throws -> String {
        let bytes = try data(arguments)
        guard let value = IndexFilenameUTF8.decode(bytes) else { throw ReflogReadError.invalidRecord }
        return value.trimmingCharacters(in: .newlines)
    }

    func branches() throws -> [String] {
        try text(["for-each-ref", "--format=%(refname)", "refs/heads/"])
            .components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    func page(reference: String = "HEAD", offset: Int = 0,
              expectedFingerprint: WorktreeFileFingerprint? = nil) throws -> RepositoryReflogPage
    {
        guard offset >= 0, try reference == "HEAD" || branches().contains(reference) else {
            throw RepositoryReflogError.unavailable("Choose a current local branch or this checkout’s HEAD reflog.")
        }
        let logPath = try text(["rev-parse", "--path-format=absolute", "--git-path", "logs/" + reference])
        let before = try fingerprintIfPresent(logPath)
        if offset > 0, before != expectedFingerprint {
            throw RepositoryReflogError.changed
        }
        guard before != nil else { return RepositoryReflogPage(entries: [], hasMore: false, fingerprint: nil) }
        let bytes = try data(["reflog", "show", "--no-show-signature", "--date=iso-strict",
                              "--format=%H%x00%gD%x00%gs%x00%gn%x00%ge%x00%s%x00", "--max-count=201",
                              "--skip=\(offset)", reference, "--"])
        guard try fingerprintIfPresent(logPath) == before else { throw RepositoryReflogError.changed }
        let entries = try ReflogParser.entries(from: bytes)
        Self.logger.debug("Read reflog page count=\(entries.count) offset=\(offset)")
        return RepositoryReflogPage(entries: Array(entries.prefix(200)), hasMore: entries.count > 200, fingerprint: before)
    }

    private func fingerprintIfPresent(_ path: String) throws -> WorktreeFileFingerprint? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw RepositoryReflogError.unavailable("The reflog is not a regular file and cannot be inspected safely.")
            }
            // Git may silently omit an unreadable reflog. Prove read access so
            // permissions errors cannot masquerade as an empty history.
            let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            try reader.close()
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
            return nil
        }
        return try WorktreeFileFingerprint.capture(path: path)
    }

    private func validateCommit(_ objectID: String) throws {
        guard ReflogParser.isObjectID(objectID) else {
            throw RepositoryReflogError.unavailable("The selected commit is no longer available locally.")
        }
        do {
            guard try text(["cat-file", "-t", objectID]) == "commit" else {
                throw RepositoryReflogError.unavailable("The selected object is not a commit.")
            }
        } catch let error as NSError where error.domain == PBTaskErrorDomain && error.code == 4 {
            throw RepositoryReflogError.unavailable("The selected commit is no longer available locally. Git may have expired its object; recovery requires an available commit.")
        }
    }

    func details(objectID: String, compareWithHead: Bool = false) throws -> String {
        try validateCommit(objectID)
        let arguments = compareWithHead
            ? ["diff", "--no-ext-diff", "--no-textconv", "--stat", "--patch", "HEAD", objectID, "--"]
            : ["show", "--no-ext-diff", "--no-textconv", "--no-show-signature", "--format=fuller", "--stat", "--patch", objectID, "--"]
        return try String(decoding: data(arguments), as: UTF8.self)
    }

    func createRecoveryBranch(objectID: String, name: String) throws {
        try writer.perform("create-recovery-branch") {
            try validateCommit(objectID)
            guard !name.hasPrefix("-"), !name.isEmpty else { throw RepositoryReflogError.unavailable("Enter a valid branch name.") }
            _ = try data(["check-ref-format", "--branch", name])
            _ = try data(["branch", "--", name, objectID])
            Self.logger.info("Created recovery branch")
        }
    }

    func preview(target: String, mode: ReflogResetMode) throws -> RepositoryRecoveryPreview {
        try validateCommit(target)
        let bare = try text(["rev-parse", "--is-bare-repository"]) == "true"
        let gitDirectory = try text(["rev-parse", "--absolute-git-dir"])
        let operationPaths = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer", "BISECT_LOG"]
        let inProgress = operationPaths.contains { FileManager.default.fileExists(atPath: gitDirectory + "/" + $0) }
        let head = try text(["rev-parse", "--verify", "HEAD"])
        if let reason = ReflogRecoveryPolicy.blocker(isBare: bare, operationInProgress: inProgress, hasHead: ReflogParser.isObjectID(head), targetAvailable: true, previewComplete: true) {
            throw RepositoryReflogError.unavailable(reason)
        }
        let root = try text(["rev-parse", "--show-toplevel"])
        let branch = try text(["rev-parse", "--abbrev-ref", "HEAD"])
        let indexPath = try text(["rev-parse", "--path-format=absolute", "--git-path", "index"])
        let index = try Data(contentsOf: URL(fileURLWithPath: indexPath))
        let unmerged = try data(["ls-files", "--unmerged", "-z"])
        guard unmerged.isEmpty else { throw RepositoryReflogError.unavailable("Resolve the unmerged index before resetting.") }

        let current = try treePaths(["ls-files", "--stage", "-z"])
        if mode == .hard {
            let flags = try data(["ls-files", "-v", "-z"]).split(separator: 0)
            guard flags.allSatisfy({ record in
                guard let flag = record.first else { return false }
                return flag != 83 && !(97 ... 122).contains(flag)
            }) else {
                throw RepositoryReflogError.unavailable("A complete hard-reset preview is unavailable while files are marked assume-unchanged or skip-worktree. Review these index flags and sparse-checkout settings in Terminal first.")
            }
        }
        let destination = try treePaths(["ls-tree", "-r", "-z", "--full-tree", target])
        let changed = try paths(["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--ignore-submodules=none", "--name-only", "-z", "HEAD", target, "--"])
        let staged = try paths(["diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-renames", "--ignore-submodules=none", "--name-only", "-z", "--"])
        let unstaged = try paths(["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z", "--"])
        var affected = Set(changed + staged + unstaged)
        var discarded = Set(staged + unstaged)
        var evidence = SHA256()
        func record(_ value: Data) {
            evidence.update(data: Data("\(value.count):".utf8)); evidence.update(data: value)
        }
        record(Data(target.utf8)); record(Data(head.utf8)); record(Data(branch.utf8)); record(index)
        record(Data(context.launchPath.utf8))
        try record(Data(String(describing: WorktreeFileFingerprint.capture(path: context.launchPath)).utf8))
        let commonDirectory = try text(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        for directory in [root, gitDirectory, commonDirectory] {
            record(Data(directory.utf8))
            try record(Data(String(describing: WorktreeFileIdentity.capture(path: directory)).utf8))
        }
        var visited = Set<String>()
        for path in Set(current.keys).union(destination.keys).sorted() {
            try checkCancellation()
            if current[path] == "160000" || destination[path] == "160000" {
                if mode == .hard, current[path] != destination[path] || changed.contains(path) {
                    throw RepositoryReflogError.unavailable("This reset changes a submodule. Use Git in Terminal to inspect its working state first.")
                }
                if mode == .hard {
                    let existingDirectory = try captureSubmodulePath(root: root, path: path, affected: &affected, discarded: &discarded, record: record)
                    if existingDirectory, !staged.contains(path) {
                        affected.remove(path)
                        discarded.remove(path)
                    }
                }
                continue
            }
            let components = path.split(separator: "/").map(String.init)
            for index in components.indices {
                let candidate = components[...index].joined(separator: "/")
                let url = URL(fileURLWithPath: root).appendingPathComponent(candidate)
                let isTarget = destination[candidate] != nil
                var capturedPaths = Set<String>()
                if visited.insert(candidate).inserted {
                    try capture(url: url, relative: candidate, descend: isTarget, capturedPaths: &capturedPaths, record: record)
                }
                if destination[path] != nil,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   current[candidate] == nil || (isTarget && attrs[.type] as? FileAttributeType == .typeDirectory),
                   isTarget || attrs[.type] as? FileAttributeType != .typeDirectory
                {
                    affected.insert(candidate); discarded.insert(candidate)
                    affected.formUnion(capturedPaths); discarded.formUnion(capturedPaths)
                }
                // A symlink or regular ancestor can obstruct a target directory; do not follow it.
                if index != components.indices.last,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   attrs[.type] as? FileAttributeType != .typeDirectory
                {
                    break
                }
            }
        }
        guard try text(["rev-parse", "--verify", "HEAD"]) == head,
              try Data(contentsOf: URL(fileURLWithPath: indexPath)) == index else { throw RepositoryReflogError.changed }
        Self.logger.debug("Prepared recovery preview paths=\(affected.count) mode=\(mode.rawValue, privacy: .public)")
        return RepositoryRecoveryPreview(target: target, previousHead: head, branch: branch, mode: mode,
                                         affectedPaths: affected.sorted(), discardedPaths: discarded.sorted(), evidence: Data(evidence.finalize()))
    }

    private func paths(_ arguments: [String]) throws -> [String] {
        try data(arguments).split(separator: 0).map { bytes in
            guard let path = IndexFilenameUTF8.decode(Data(bytes)), WorkingTreePaths.validatedHierarchyPath(path) != nil else {
                throw RepositoryReflogError.unavailable("A path cannot be represented safely in the reset preview.")
            }
            return path
        }
    }

    private func treePaths(_ arguments: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for record in try data(arguments).split(separator: 0) {
            guard let tab = record.firstIndex(of: 9),
                  let path = IndexFilenameUTF8.decode(Data(record[record.index(after: tab)...])),
                  WorkingTreePaths.validatedHierarchyPath(path) != nil,
                  let mode = String(data: Data(record[..<tab]), encoding: .utf8)?.split(separator: " ").first
            else { throw ReflogReadError.invalidRecord }
            result[path] = String(mode)
        }
        return result
    }

    private func captureSubmodulePath(root: String, path: String, affected: inout Set<String>, discarded: inout Set<String>, record: (Data) -> Void) throws -> Bool {
        // --no-recurse-submodules preserves existing directories, but reset
        // still creates missing directories and removes files in their way.
        let components = path.split(separator: "/").map(String.init)
        for index in components.indices {
            let candidate = components[...index].joined(separator: "/")
            let url = URL(fileURLWithPath: root).appendingPathComponent(candidate)
            var capturedPaths = Set<String>()
            let kind = try capture(url: url, relative: candidate, descend: false, capturedPaths: &capturedPaths, record: record)
            if kind == .typeDirectory {
                continue
            }
            affected.insert(path)
            if kind != nil {
                affected.insert(candidate)
                discarded.insert(candidate)
            }
            // Never follow a symlink ancestor into another working copy.
            return false
        }
        return true
    }

    @discardableResult
    private func capture(url: URL, relative: String, descend: Bool, capturedPaths: inout Set<String>, record: (Data) -> Void) throws -> FileAttributeType? {
        try checkCancellation()
        record(Data(relative.utf8))
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
            record(Data("missing".utf8)); return nil
        }
        capturedPaths.insert(relative)
        guard let kind = attributes[.type] as? FileAttributeType else { throw ReflogReadError.invalidRecord }
        record(Data(kind.rawValue.utf8))
        switch kind {
        case .typeRegular:
            let before = try WorktreeFileFingerprint.capture(path: url.path)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let bytes = try handle.read(upToCount: 262_144), !bytes.isEmpty {
                try checkCancellation(); record(bytes)
            }
            guard try WorktreeFileFingerprint.capture(path: url.path) == before else { throw RepositoryReflogError.changed }
            record(Data(String(describing: before).utf8))
        case .typeSymbolicLink:
            try record(Data(FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8))
        case .typeDirectory:
            try record(Data(String(describing: WorktreeFileIdentity.capture(path: url.path)).utf8))
            if descend {
                let children = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
                guard !children.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else {
                    throw RepositoryReflogError.unavailable("A nested repository obstructs this reset. Inspect it in Terminal first.")
                }
                for child in children {
                    try capture(url: url.appendingPathComponent(child), relative: relative + "/" + child, descend: true, capturedPaths: &capturedPaths, record: record)
                }
            }
        default:
            throw RepositoryReflogError.unavailable("A special filesystem object prevents a complete reset preview.")
        }
        return kind
    }

    func reset(confirmed preview: RepositoryRecoveryPreview, discardConfirmed: Bool) throws -> String {
        try writer.perform("reflog-reset") {
            guard preview.mode != .hard || discardConfirmed else {
                throw RepositoryReflogError.unavailable("Confirm discarding local changes before a hard reset.")
            }
            guard try self.preview(target: preview.target, mode: preview.mode) == preview else { throw RepositoryReflogError.changed }
            let backup = "recovery/" + String(preview.previousHead.prefix(12)) + "-" + UUID().uuidString.lowercased()
            try createRecoveryBranch(objectID: preview.previousHead, name: backup)
            do {
                try checkCancellation()
                guard try self.preview(target: preview.target, mode: preview.mode) == preview else { throw RepositoryReflogError.changed }
                _ = try data(["reset", "--" + preview.mode.rawValue, "--no-recurse-submodules", preview.target])
                guard try text(["rev-parse", "--verify", "HEAD"]) == preview.target else { throw RepositoryReflogError.changed }
            } catch {
                Self.logger.error("Recovery reset failed after backup creation backup=\(backup, privacy: .public)")
                throw RepositoryReflogError.resetFailed(backup: backup, reason: error.localizedDescription)
            }
            Self.logger.info("Recovery reset completed mode=\(preview.mode.rawValue, privacy: .public) backup=\(backup, privacy: .public)")
            return backup
        }
    }
}
