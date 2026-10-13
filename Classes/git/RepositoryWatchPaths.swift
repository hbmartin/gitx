import Foundation
import GitXCore

/// FSEvents remains Objective-C wiring. This value decides which checkout
/// owns a path and prevents sibling indexes from changing local status.
/// PBGitRepositoryWatcher.m constructs this class through GitX-Swift.h.
@objc(PBRepositoryWatchPaths)
final nonisolated class RepositoryWatchPaths: NSObject { // swiftlint:disable:this unused_declaration
    private let gitDirectory: String
    private let commonDirectory: String
    private let workingDirectory: String?

    @objc(initWithGitDirectory:commonDirectory:workingDirectory:)
    init(gitDirectory: String, commonDirectory: String, workingDirectory: String?) {
        self.gitDirectory = (gitDirectory as NSString).standardizingPath
        self.commonDirectory = (commonDirectory as NSString).standardizingPath
        self.workingDirectory = workingDirectory.map { ($0 as NSString).standardizingPath }
        super.init()
    }

    /// 1 = this checkout's Git data, 2 = shared Git data, 3 = local working data.
    /// The Objective-C FSEvents callback invokes categoryForPath:.
    @objc(categoryForPath:)
    func category(for path: String) -> Int { // swiftlint:disable:this unused_declaration
        if WorktreePaths.contains(path, in: commonDirectory) {
            let relative = String(path.dropFirst(commonDirectory.count + 1))
            if relative.hasPrefix("worktrees/") && !WorktreePaths.contains(path, in: gitDirectory) {
                return path.hasSuffix(".lock") || (path as NSString).lastPathComponent == "index" ? 0 : 2
            }
            if commonDirectory == gitDirectory,
               relative == "worktrees" || relative.hasPrefix("worktrees/") || relative == "refs" || relative.hasPrefix("refs/") || relative == "packed-refs"
            {
                return path.hasSuffix(".lock") || (relative.hasPrefix("worktrees/") && (path as NSString).lastPathComponent == "index") ? 0 : 2
            }
        }
        if WorktreePaths.contains(path, in: gitDirectory) {
            return path.hasSuffix(".lock") ? 0 : 1
        }
        if WorktreePaths.contains(path, in: commonDirectory) {
            if path.hasSuffix(".lock") {
                return 0
            }
            let relative = String(path.dropFirst(commonDirectory.count + 1))
            if relative == "index" || relative.hasPrefix("objects/") || relative == "objects" {
                return 0
            }
            if relative.hasPrefix("worktrees/"), (path as NSString).lastPathComponent == "index" {
                return 0
            }
            return 2
        }
        if let workingDirectory, WorktreePaths.contains(path, in: workingDirectory) {
            return 3
        }
        return 0
    }
}
