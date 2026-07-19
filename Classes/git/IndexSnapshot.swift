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
    @objc let path: String
    @objc let status: Int
    @objc let commitBlobMode: String?
    @objc let commitBlobSHA: String?

    init(path: String, status: Int, commitBlobMode: String?, commitBlobSHA: String?) {
        self.path = path
        self.status = status
        self.commitBlobMode = commitBlobMode
        self.commitBlobSHA = commitBlobSHA
        super.init()
    }
}

@objc(PBIndexStatusParser)
final nonisolated class IndexStatusParser: NSObject {
    @objc(parseTrackedData:error:)
    func parseTrackedData(
        _ data: Data?,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> [String: IndexStatusEntry]? {
        do {
            let records = try records(from: data)
            guard records.count.isMultiple(of: 2) else {
                throw IndexSnapshotError.malformed("Tracked index output contains an incomplete record")
            }

            var entries: [String: IndexStatusEntry] = [:]
            for index in stride(from: 0, to: records.count, by: 2) {
                let fields = records[index].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard fields.count >= 5, fields[0].hasPrefix(":") else {
                    throw IndexSnapshotError.malformed("Tracked index output contains a malformed status")
                }
                let path = records[index + 1]
                guard !path.isEmpty else {
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
                entries[path] = IndexStatusEntry(
                    path: path,
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
    ) -> [String: IndexStatusEntry]? {
        do {
            let records = try records(from: data)
            var entries: [String: IndexStatusEntry] = [:]
            for path in records where !path.isEmpty {
                entries[path] = IndexStatusEntry(
                    path: path,
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

    private func records(from data: Data?) throws -> [String] {
        guard let data, !data.isEmpty else { return [] }
        var payload = data
        if payload.last == 0x00 {
            payload.removeLast()
        }
        guard !payload.isEmpty else { return [] }
        // Split on NUL at the byte level and decode each field with a lossy UTF-8 fallback. A single
        // non-UTF-8 path (e.g. latin-1 created on another OS) previously failed the whole-payload decode
        // and silently froze the staged/unstaged/untracked list at its previous contents.
        return payload
            .split(separator: 0x00, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
    }
}

@objc(PBIndexFileSnapshot)
final nonisolated class IndexFileSnapshot: NSObject {
    @objc let path: String
    @objc var status: Int
    @objc var commitBlobMode: String?
    @objc var commitBlobSHA: String?
    @objc var hasStagedChanges: Bool
    @objc var hasUnstagedChanges: Bool

    @objc(initWithPath:status:commitBlobMode:commitBlobSHA:hasStagedChanges:hasUnstagedChanges:)
    init(
        path: String,
        status: Int,
        commitBlobMode: String?,
        commitBlobSHA: String?,
        hasStagedChanges: Bool,
        hasUnstagedChanges: Bool
    ) {
        self.path = path
        self.status = status
        self.commitBlobMode = commitBlobMode
        self.commitBlobSHA = commitBlobSHA
        self.hasStagedChanges = hasStagedChanges
        self.hasUnstagedChanges = hasUnstagedChanges
        super.init()
    }

    convenience init(entry: IndexStatusEntry, staged: Bool, unstaged: Bool) {
        self.init(
            path: entry.path,
            status: entry.status,
            commitBlobMode: entry.commitBlobMode,
            commitBlobSHA: entry.commitBlobSHA,
            hasStagedChanges: staged,
            hasUnstagedChanges: unstaged
        )
    }

    func applying(_ entry: IndexStatusEntry) {
        status = entry.status
        commitBlobMode = entry.commitBlobMode
        commitBlobSHA = entry.commitBlobSHA
    }
}

@objc(PBIndexSnapshotReducer)
final nonisolated class IndexSnapshotReducer: NSObject {
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "IndexSnapshotReducer")

    @objc(reducePrevious:staged:unstaged:untracked:)
    func reduce(
        previous: [IndexFileSnapshot],
        staged: [String: IndexStatusEntry]?,
        unstaged: [String: IndexStatusEntry]?,
        untracked: [String: IndexStatusEntry]?
    ) -> [IndexFileSnapshot] {
        var order = previous.map(\.path)
        var snapshots = Dictionary(uniqueKeysWithValues: previous.map { ($0.path, copy($0)) })

        if let staged {
            for snapshot in snapshots.values {
                snapshot.hasStagedChanges = false
            }
            merge(staged, into: &snapshots, order: &order) { snapshot, entry in
                snapshot.applying(entry)
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
                if !snapshot.hasStagedChanges {
                    snapshot.applying(entry)
                }
                snapshot.hasUnstagedChanges = true
            }
        }

        if let untracked {
            merge(untracked, into: &snapshots, order: &order) { snapshot, _ in
                // Don't let an untracked entry erase a staged change for the same path. `git rm --cached foo`
                // (keeping foo on disk) reports foo as both a staged deletion and an untracked file; clobbering
                // the staged state here hid the staged deletion so the user could neither see nor unstage it.
                if !snapshot.hasStagedChanges {
                    snapshot.status = 0
                }
                snapshot.hasUnstagedChanges = true
            }
        }

        let result = order.compactMap { path -> IndexFileSnapshot? in
            guard let snapshot = snapshots[path],
                  snapshot.hasStagedChanges || snapshot.hasUnstagedChanges else { return nil }
            return snapshot
        }
        logger.debug("Reduced index snapshots to \(result.count) paths")
        return result
    }

    private func merge(
        _ entries: [String: IndexStatusEntry],
        into snapshots: inout [String: IndexFileSnapshot],
        order: inout [String],
        update: (IndexFileSnapshot, IndexStatusEntry) -> Void
    ) {
        for (path, entry) in entries {
            let snapshot: IndexFileSnapshot
            if let existing = snapshots[path] {
                snapshot = existing
            } else {
                snapshot = IndexFileSnapshot(entry: entry, staged: false, unstaged: false)
                snapshots[path] = snapshot
                order.append(path)
            }
            update(snapshot, entry)
        }
    }

    private func copy(_ snapshot: IndexFileSnapshot) -> IndexFileSnapshot {
        IndexFileSnapshot(
            path: snapshot.path,
            status: snapshot.status,
            commitBlobMode: snapshot.commitBlobMode,
            commitBlobSHA: snapshot.commitBlobSHA,
            hasStagedChanges: snapshot.hasStagedChanges,
            hasUnstagedChanges: snapshot.hasUnstagedChanges
        )
    }
}

// swiftlint:enable unused_declaration
