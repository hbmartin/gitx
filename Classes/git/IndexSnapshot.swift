import Foundation
import OSLog // swiftlint:disable:this unused_import

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

private enum IndexSnapshotError {
    nonisolated static func malformed(_ description: String) -> NSError {
        NSError(
            domain: "PBGitIndexSnapshotError",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

@objc(PBIndexStatusEntry)
final nonisolated class IndexStatusEntry: NSObject {
    @objc let rawPath: Data
    @objc let path: String
    @objc let status: Int
    @objc let commitBlobMode: String?
    @objc let commitBlobSHA: String?

    init(rawPath: Data, status: Int, commitBlobMode: String?, commitBlobSHA: String?) {
        self.rawPath = rawPath
        path = IndexPathDisplayName.string(for: rawPath)
        self.status = status
        self.commitBlobMode = commitBlobMode
        self.commitBlobSHA = commitBlobSHA
        super.init()
    }
}

/// Foundation's encoding initializer consumes a leading UTF-8 BOM. Filename
/// decoding must preserve every byte, including a BOM-only name.
nonisolated enum IndexFilenameUTF8 {
    static func decode(_ bytes: Data) -> String? {
        let value = String(decoding: bytes, as: UTF8.self)
        return Data(value.utf8) == bytes ? value : nil
    }
}

/// Keeps byte identity in Swift collections so common-prefix paths do not use
/// Foundation's NSData hashing when assembling the working tree.
@objc(PBWorkingTreePaths)
final nonisolated class WorkingTreePaths: NSObject {
    @objc private(set) var rawPaths: [Data] = []
    private var seen = Set<Data>()
    private var files: [Data: PBChangedFile] = [:]

    @objc(initWithFiles:)
    init(files: [PBChangedFile]) {
        super.init()
        for file in files {
            self.files[file.rawPath] = file
        }
    }

    @objc(appendData:)
    func append(data: Data) {
        for path in IndexFilePresentation.rawPaths(data: data) where seen.insert(path).inserted {
            rawPaths.append(path)
        }
    }

    @objc(fileForRawPath:)
    func file(for rawPath: Data) -> PBChangedFile? {
        files[rawPath]
    }

    @objc(validatedHierarchyPath:)
    static func validatedHierarchyPath(_ path: String) -> String? {
        let components = path.components(separatedBy: "/")
        guard !path.contains("\0"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return path
    }
}

nonisolated enum IndexPathDisplayName {
    static func string(for rawPath: Data) -> String {
        if let path = IndexFilenameUTF8.decode(rawPath) {
            return path
        }
        return rawPath.map { byte in
            if (0x20 ... 0x7E).contains(byte), byte != 0x5C {
                return String(UnicodeScalar(byte))
            }
            return String(format: "\\x%02X", byte)
        }.joined()
    }
}

@objc(PBIndexStatusParser)
final nonisolated class IndexStatusParser: NSObject {
    @objc(parseTrackedData:error:)
    func parseTrackedData(
        _ data: Data?,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> [Data: IndexStatusEntry]? {
        do {
            let records = try records(from: data)
            guard records.count.isMultiple(of: 2) else {
                throw IndexSnapshotError.malformed("Tracked index output contains an incomplete record")
            }

            var entries: [Data: IndexStatusEntry] = [:]
            for index in stride(from: 0, to: records.count, by: 2) {
                guard let statusRecord = String(data: records[index], encoding: .utf8) else {
                    throw IndexSnapshotError.malformed("Tracked index output contains non-UTF-8 metadata")
                }
                let fields = statusRecord.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard fields.count >= 5, fields[0].hasPrefix(":") else {
                    throw IndexSnapshotError.malformed("Tracked index output contains a malformed status")
                }
                let rawPath = records[index + 1]
                guard !rawPath.isEmpty else {
                    throw IndexSnapshotError.malformed("Tracked index output contains an empty path")
                }
                let status: Int
                if fields[4].hasPrefix("U") {
                    // Unmerged (conflicted) entries carry mode :000000 like additions, so they must be
                    // classified before the ":000000" NEW check or they display as brand-new untracked files.
                    // PBChangedFileStatus has no dedicated conflict case, so surface them as MODIFIED.
                    status = 1
                } else if fields[4].hasPrefix("D") {
                    status = 2
                } else if fields[0] == ":000000" {
                    status = 0
                } else {
                    status = 1
                }
                entries[rawPath] = IndexStatusEntry(
                    rawPath: rawPath,
                    status: status,
                    commitBlobMode: String(fields[0].dropFirst()),
                    commitBlobSHA: fields[2]
                )
            }
            return entries
        } catch {
            outputError?.pointee = error as NSError
            return nil
        }
    }

    @objc(parseUntrackedData:error:)
    func parseUntrackedData(
        _ data: Data?,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> [Data: IndexStatusEntry]? {
        do {
            let records = try records(from: data)
            var entries: [Data: IndexStatusEntry] = [:]
            for rawPath in records where !rawPath.isEmpty {
                entries[rawPath] = IndexStatusEntry(
                    rawPath: rawPath,
                    status: 0,
                    commitBlobMode: nil,
                    commitBlobSHA: nil
                )
            }
            return entries
        } catch {
            outputError?.pointee = error as NSError
            return nil
        }
    }

    private func records(from data: Data?) throws -> [Data] {
        guard let data, !data.isEmpty else { return [] }
        guard data.last == 0 else {
            throw IndexSnapshotError.malformed("Index output contains an unterminated NUL record")
        }
        var payload = data
        payload.removeLast()
        guard !payload.isEmpty else { return [] }
        return payload.split(separator: 0, omittingEmptySubsequences: false).map { Data($0) }
    }
}

@objc(PBIndexFileSnapshot)
final nonisolated class IndexFileSnapshot: NSObject {
    @objc let rawPath: Data
    @objc let path: String
    @objc var status: Int
    @objc var stagedStatus: Int
    @objc var worktreeStatus: Int
    @objc var commitBlobMode: String?
    @objc var commitBlobSHA: String?
    @objc var hasStagedChanges: Bool
    @objc var hasUnstagedChanges: Bool

    @objc(initWithPath:status:commitBlobMode:commitBlobSHA:hasStagedChanges:hasUnstagedChanges:)
    convenience init(
        path: String,
        status: Int,
        commitBlobMode: String?,
        commitBlobSHA: String?,
        hasStagedChanges: Bool,
        hasUnstagedChanges: Bool
    ) {
        self.init(
            path: path,
            rawPath: Data(path.utf8),
            status: status,
            stagedStatus: status,
            worktreeStatus: status,
            commitBlobMode: commitBlobMode,
            commitBlobSHA: commitBlobSHA,
            hasStagedChanges: hasStagedChanges,
            hasUnstagedChanges: hasUnstagedChanges
        )
    }

    @objc(initWithPath:rawPath:status:stagedStatus:worktreeStatus:commitBlobMode:commitBlobSHA:hasStagedChanges:hasUnstagedChanges:)
    init(
        path: String,
        rawPath: Data,
        status: Int,
        stagedStatus: Int,
        worktreeStatus: Int,
        commitBlobMode: String?,
        commitBlobSHA: String?,
        hasStagedChanges: Bool,
        hasUnstagedChanges: Bool
    ) {
        self.path = path
        self.rawPath = rawPath
        self.status = status
        self.stagedStatus = stagedStatus
        self.worktreeStatus = worktreeStatus
        self.commitBlobMode = commitBlobMode
        self.commitBlobSHA = commitBlobSHA
        self.hasStagedChanges = hasStagedChanges
        self.hasUnstagedChanges = hasUnstagedChanges
        super.init()
    }

    convenience init(entry: IndexStatusEntry, staged: Bool, unstaged: Bool) {
        self.init(
            path: entry.path,
            rawPath: entry.rawPath,
            status: entry.status,
            stagedStatus: entry.status,
            worktreeStatus: entry.status,
            commitBlobMode: entry.commitBlobMode,
            commitBlobSHA: entry.commitBlobSHA,
            hasStagedChanges: staged,
            hasUnstagedChanges: unstaged
        )
    }

    func applyingStaged(_ entry: IndexStatusEntry) {
        status = entry.status
        stagedStatus = entry.status
        commitBlobMode = entry.commitBlobMode
        commitBlobSHA = entry.commitBlobSHA
    }

    func applyingWorktree(_ entry: IndexStatusEntry) {
        worktreeStatus = entry.status
        if !hasStagedChanges {
            status = entry.status
            commitBlobMode = entry.commitBlobMode
            commitBlobSHA = entry.commitBlobSHA
        }
    }
}

@objc(PBIndexSnapshotReducer)
final nonisolated class IndexSnapshotReducer: NSObject {
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "IndexSnapshotReducer")

    @objc(reducePrevious:staged:unstaged:untracked:)
    func reduce(
        previous: [IndexFileSnapshot],
        staged: [Data: IndexStatusEntry]?,
        unstaged: [Data: IndexStatusEntry]?,
        untracked: [Data: IndexStatusEntry]?
    ) -> [IndexFileSnapshot] {
        var order: [Data] = []
        var snapshots: [Data: IndexFileSnapshot] = [:]
        for snapshot in previous where snapshots[snapshot.rawPath] == nil {
            order.append(snapshot.rawPath)
            snapshots[snapshot.rawPath] = copy(snapshot)
        }

        if let staged {
            for snapshot in snapshots.values {
                snapshot.hasStagedChanges = false
            }
            merge(staged, into: &snapshots, order: &order) { snapshot, entry in
                snapshot.applyingStaged(entry)
                snapshot.hasStagedChanges = true
            }
        }

        if unstaged != nil, untracked != nil {
            for snapshot in snapshots.values {
                snapshot.hasUnstagedChanges = false
            }
        }

        if let unstaged {
            merge(unstaged, into: &snapshots, order: &order) { snapshot, entry in
                snapshot.applyingWorktree(entry)
                snapshot.hasUnstagedChanges = true
            }
        }

        if let untracked {
            merge(untracked, into: &snapshots, order: &order) { snapshot, entry in
                snapshot.applyingWorktree(entry)
                snapshot.hasUnstagedChanges = true
            }
        }

        let result = order.compactMap { rawPath -> IndexFileSnapshot? in
            guard let snapshot = snapshots[rawPath],
                  snapshot.hasStagedChanges || snapshot.hasUnstagedChanges else { return nil }
            snapshot.status = snapshot.hasStagedChanges ? snapshot.stagedStatus : snapshot.worktreeStatus
            return snapshot
        }
        logger.debug("Reduced index snapshots to \(result.count) paths")
        return result
    }

    private func merge(
        _ entries: [Data: IndexStatusEntry],
        into snapshots: inout [Data: IndexFileSnapshot],
        order: inout [Data],
        update: (IndexFileSnapshot, IndexStatusEntry) -> Void
    ) {
        for rawPath in entries.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard let entry = entries[rawPath] else { continue }
            let snapshot: IndexFileSnapshot
            if let existing = snapshots[rawPath] {
                snapshot = existing
            } else {
                snapshot = IndexFileSnapshot(entry: entry, staged: false, unstaged: false)
                snapshots[rawPath] = snapshot
                order.append(rawPath)
            }
            update(snapshot, entry)
        }
    }

    private func copy(_ snapshot: IndexFileSnapshot) -> IndexFileSnapshot {
        IndexFileSnapshot(
            path: snapshot.path,
            rawPath: snapshot.rawPath,
            status: snapshot.status,
            stagedStatus: snapshot.stagedStatus,
            worktreeStatus: snapshot.worktreeStatus,
            commitBlobMode: snapshot.commitBlobMode,
            commitBlobSHA: snapshot.commitBlobSHA,
            hasStagedChanges: snapshot.hasStagedChanges,
            hasUnstagedChanges: snapshot.hasUnstagedChanges
        )
    }
}

// swiftlint:enable unused_declaration

/// Objective-C retains atomic model properties and Cocoa wiring. These
/// decisions consume snapshots and never treat an escaped label as a path.
// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration
@objc(PBIndexFilePresentation)
final nonisolated class IndexFilePresentation: NSObject {
    @objc(displayPathForRawPath:)
    static func displayPath(rawPath: Data) -> String {
        IndexPathDisplayName.string(for: rawPath)
    }

    @objc(safePathForRawPath:)
    static func safePath(rawPath: Data) -> String? {
        guard !rawPath.isEmpty, !rawPath.contains(0) else { return nil }
        return IndexFilenameUTF8.decode(rawPath)
    }

    @objc(rawPathsFromData:)
    static func rawPaths(data: Data) -> [Data] {
        guard data.isEmpty || data.last == 0 else { return [] }
        return data.split(separator: 0).map { Data($0) }
    }

    @objc(pathMatchesRawPath:fullPath:)
    static func pathMatches(rawPath: Data?, fullPath: String?) -> Bool {
        guard let rawPath, let fullPath, let decoded = safePath(rawPath: rawPath) else { return false }
        return decoded == fullPath && Data(fullPath.utf8) == rawPath
    }

    @objc(imageNameForStatus:)
    static func imageName(status: Int) -> String {
        switch status {
        case 0: "new_file"
        case 2: "deleted_file"
        default: "empty_file"
        }
    }

    @objc(workingStatusForFile:)
    static func workingStatus(file: PBChangedFile) -> String {
        var states: [String] = []
        if file.hasStagedChanges {
            states.append("staged")
        }
        if file.hasUnstagedChanges {
            states.append(file.worktreeStatus == .NEW ? "untracked" : "unstaged")
        }
        if file.hasStagedChanges, file.stagedStatus == .DELETED {
            states.append("deleted")
        } else if file.hasUnstagedChanges, file.worktreeStatus == .DELETED {
            states.append("deleted")
        }
        return states.joined(separator: ", ")
    }

    @objc(discardableFilesFromFiles:)
    static func discardableFiles(files: [PBChangedFile]) -> [PBChangedFile] {
        files.filter { $0.hasUnstagedChanges && $0.worktreeStatus != .NEW }
    }
}

@objc(PBIndexWorkingStateSummary)
final nonisolated class IndexWorkingStateSummary: NSObject {
    @objc let stagedCount: UInt
    @objc let unstagedCount: UInt
    @objc let untrackedCount: UInt

    @objc(initWithFiles:)
    init(files: [PBChangedFile]) {
        stagedCount = UInt(files.filter(\.hasStagedChanges).count)
        unstagedCount = UInt(files.filter { $0.hasUnstagedChanges && $0.worktreeStatus != .NEW }.count)
        untrackedCount = UInt(files.filter { $0.hasUnstagedChanges && $0.worktreeStatus == .NEW }.count)
        super.init()
    }
}

@objc(PBIndexOperationErrorPresentation)
final nonisolated class IndexOperationErrorPresentation: NSObject {
    @objc(messageForOperation:error:)
    static func message(operation: String, error: NSError?) -> String {
        guard let error else { return operation }
        return operation + "\n" + detail(for: error)
    }

    @objc(detailForError:)
    static func detail(for error: NSError) -> String {
        var parts = [error.localizedDescription]
        if let reason = error.localizedFailureReason, reason != error.localizedDescription {
            parts.append(reason)
        }
        if let status = error.userInfo[PBTaskTerminationStatusKey] as? NSNumber {
            parts.append(String(format: NSLocalizedString("Exit status: %@", comment: "Git process exit status in an index operation failure"), status))
        }
        if let output = error.userInfo[PBTaskTerminationOutputKey] as? String {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }
        return parts.joined(separator: "\n")
    }
}

@objc(PBIndexFileReconciliation)
final nonisolated class IndexFileReconciliation: NSObject {
    @objc let files: [PBChangedFile]
    @objc let membershipChanged: Bool

    @objc(initWithFiles:result:reducer:)
    init(files: [PBChangedFile], result: IndexRefreshResult, reducer: IndexSnapshotReducer) {
        let previous = files.map {
            IndexFileSnapshot(
                path: $0.path, rawPath: $0.rawPath, status: $0.status.rawValue,
                stagedStatus: $0.stagedStatus.rawValue, worktreeStatus: $0.worktreeStatus.rawValue,
                commitBlobMode: $0.commitBlobMode, commitBlobSHA: $0.commitBlobSHA,
                hasStagedChanges: $0.hasStagedChanges, hasUnstagedChanges: $0.hasUnstagedChanges
            )
        }
        let snapshots = reducer.reduce(
            previous: previous, staged: result.staged, unstaged: result.unstaged, untracked: result.untracked
        )
        var existing: [Data: PBChangedFile] = [:]
        for file in files where existing[file.rawPath] == nil {
            existing[file.rawPath] = file
        }
        let reconciled = snapshots.map { snapshot in
            let file = existing[snapshot.rawPath] ?? PBChangedFile(path: snapshot.path, rawPath: snapshot.rawPath)
            file.status = PBChangedFileStatus(rawValue: snapshot.status) ?? .MODIFIED
            file.stagedStatus = PBChangedFileStatus(rawValue: snapshot.stagedStatus) ?? .MODIFIED
            file.worktreeStatus = PBChangedFileStatus(rawValue: snapshot.worktreeStatus) ?? .MODIFIED
            file.commitBlobMode = snapshot.commitBlobMode
            file.commitBlobSHA = snapshot.commitBlobSHA
            file.hasStagedChanges = snapshot.hasStagedChanges
            file.hasUnstagedChanges = snapshot.hasUnstagedChanges
            return file
        }
        let survivingPaths = Set(snapshots.map(\.rawPath))
        for file in files where !survivingPaths.contains(file.rawPath) {
            // Retained row references receive the same accepted clean state
            // as the list that removes them. Pending/failed phases still keep
            // their previous membership through the reducer above.
            file.hasStagedChanges = false
            file.hasUnstagedChanges = false
            file.status = .MODIFIED
            file.stagedStatus = .MODIFIED
            file.worktreeStatus = .MODIFIED
            file.commitBlobMode = nil
            file.commitBlobSHA = nil
        }
        self.files = reconciled
        membershipChanged = files.map { ObjectIdentifier($0) } != reconciled.map { ObjectIdentifier($0) }
        super.init()
    }
}

/// Captured on main before a history view queues work. Every field is an
/// immutable copy, so refreshes cannot change the selected file underneath it.
@objc(PBIndexPreviewImageSource)
final nonisolated class IndexPreviewImageSource: NSObject {
    @objc(sourceFromWorkingSource:staged:)
    static func source(workingSource: [String: Any], staged: Bool) -> [String: Any] {
        guard staged else { return workingSource }
        var source = workingSource
        source[PBNativeImageSourceWorkingTreeKey] = false
        source[PBNativeImageSourceRevisionsKey] = [":"]
        return source
    }
}

@objc(PBIndexFileViewSnapshot)
final nonisolated class IndexFileViewSnapshot: NSObject {
    @objc let rawPath: Data
    @objc let path: String
    @objc let stagedStatus: Int
    @objc let worktreeStatus: Int
    @objc let hasStagedChanges: Bool
    @objc let hasUnstagedChanges: Bool
    private let status: PBChangedFileStatus
    private let commitBlobMode: String?
    private let commitBlobSHA: String?

    init(file: PBChangedFile) {
        rawPath = file.rawPath
        path = file.path
        status = file.status
        stagedStatus = file.stagedStatus.rawValue
        worktreeStatus = file.worktreeStatus.rawValue
        hasStagedChanges = file.hasStagedChanges
        hasUnstagedChanges = file.hasUnstagedChanges
        commitBlobMode = file.commitBlobMode
        commitBlobSHA = file.commitBlobSHA
        super.init()
    }

    @objc(snapshotsForFiles:)
    static func snapshots(files: [PBChangedFile]) -> [IndexFileViewSnapshot] {
        assert(Thread.isMainThread)
        return files.map(IndexFileViewSnapshot.init)
    }

    @objc(snapshotsForFiles:rawPaths:)
    static func snapshots(files: [PBChangedFile], rawPaths: [Data]) -> [IndexFileViewSnapshot] {
        assert(Thread.isMainThread)
        let selected = Set(rawPaths)
        return files.compactMap { selected.contains($0.rawPath) ? IndexFileViewSnapshot(file: $0) : nil }
    }

    @objc func materializedFile() -> PBChangedFile {
        let file = PBChangedFile(path: path, rawPath: rawPath)
        file.status = status
        file.stagedStatus = PBChangedFileStatus(rawValue: stagedStatus) ?? .MODIFIED
        file.worktreeStatus = PBChangedFileStatus(rawValue: worktreeStatus) ?? .MODIFIED
        file.hasStagedChanges = hasStagedChanges
        file.hasUnstagedChanges = hasUnstagedChanges
        file.commitBlobMode = commitBlobMode
        file.commitBlobSHA = commitBlobSHA
        return file
    }
}

/// Immutable lookup transferred with the captured preview values.
@objc(PBIndexFileViewSnapshotLookup)
final nonisolated class IndexFileViewSnapshotLookup: NSObject {
    private let byRawPath: [Data: IndexFileViewSnapshot]

    @objc(initWithSnapshots:)
    init(snapshots: [IndexFileViewSnapshot]) {
        var lookup: [Data: IndexFileViewSnapshot] = [:]
        for snapshot in snapshots where lookup[snapshot.rawPath] == nil {
            lookup[snapshot.rawPath] = snapshot
        }
        byRawPath = lookup
        super.init()
    }

    @objc(snapshotForRawPath:)
    func snapshot(rawPath: Data) -> IndexFileViewSnapshot? {
        byRawPath[rawPath]
    }
}

// swiftlint:enable unused_declaration
