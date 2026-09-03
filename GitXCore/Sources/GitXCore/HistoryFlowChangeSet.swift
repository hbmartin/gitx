import Foundation

/// One changed path pair from `git diff --name-status -z`, reduced to the
/// sides a flow analysis can actually load.
public struct HistoryFlowChangedFile: Equatable, Sendable {
    /// The pre-image path; `nil` for an addition or a rename from an unsupported file.
    public let oldPath: String?
    /// The post-image path; `nil` for a deletion or a rename to an unsupported file.
    public let newPath: String?

    public init(oldPath: String?, newPath: String?) {
        precondition(oldPath != nil || newPath != nil, "A changed file needs at least one side")
        self.oldPath = oldPath
        self.newPath = newPath
    }
}

public enum HistoryFlowChangeSetError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidUTF8
    case malformedNameStatus

    public var description: String {
        switch self {
        case .invalidUTF8: "Git returned non-UTF-8 name-status data."
        case .malformedNameStatus: "Git returned malformed NUL-delimited name-status data."
        }
    }
}

/// Parses `git diff --name-status -z --find-renames` output into the files a
/// flow analysis should load.
public enum HistoryFlowChangeSet {
    /// Returns the changed files whose remaining sides all satisfy `isAnalyzable`.
    ///
    /// A rename or copy that straddles the supported-language boundary is
    /// reduced to the side that can be loaded: `Foo.swift -> Foo.swift.bak`
    /// becomes a deletion of `Foo.swift`, and `Foo.txt -> Foo.swift` an addition
    /// of `Foo.swift`. Records with no analyzable side are dropped, so nothing
    /// that is returned can point at a path the caller cannot load.
    public static func changedFiles(
        nameStatus data: Data,
        isAnalyzable: (String) -> Bool
    ) throws -> [HistoryFlowChangedFile] {
        let fields = try data.split(separator: 0, omittingEmptySubsequences: true).map { field in
            guard let text = String(data: field, encoding: .utf8) else {
                throw HistoryFlowChangeSetError.invalidUTF8
            }
            return text
        }

        var index = 0
        var files: [HistoryFlowChangedFile] = []
        while index < fields.count {
            let status = fields[index]
            index += 1
            let record: (oldPath: String?, newPath: String?)
            switch status.first {
            case "R", "C":
                // Renames and copies carry a similarity score and two paths.
                guard index + 1 < fields.count else { throw HistoryFlowChangeSetError.malformedNameStatus }
                record = (fields[index], fields[index + 1])
                index += 2
            case "A":
                guard index < fields.count else { throw HistoryFlowChangeSetError.malformedNameStatus }
                record = (nil, fields[index])
                index += 1
            case "D":
                guard index < fields.count else { throw HistoryFlowChangeSetError.malformedNameStatus }
                record = (fields[index], nil)
                index += 1
            case .some:
                // M, and any single-path status the caller's diff filter lets
                // through (such as a type change), name one path on both sides.
                guard index < fields.count else { throw HistoryFlowChangeSetError.malformedNameStatus }
                record = (fields[index], fields[index])
                index += 1
            case .none:
                throw HistoryFlowChangeSetError.malformedNameStatus
            }

            let oldPath = record.oldPath.flatMap { isAnalyzable($0) ? $0 : nil }
            let newPath = record.newPath.flatMap { isAnalyzable($0) ? $0 : nil }
            guard oldPath != nil || newPath != nil else { continue }
            files.append(HistoryFlowChangedFile(oldPath: oldPath, newPath: newPath))
        }
        return files
    }
}
