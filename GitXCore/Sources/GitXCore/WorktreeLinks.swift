import Foundation

/// Link inspection follows Git's administrative `gitdir` backlinks, never a
/// guessed folder name. A copied repository may still point into its original;
/// those existing foreign targets are deliberately left alone.
public enum WorktreePaths {
    public static func canonical(_ path: String) -> String {
        var existing = (path as NSString).standardizingPath
        var missing: [String] = []
        while existing.count > 1, !FileManager.default.fileExists(atPath: existing) {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        let resolved = existing.withCString { realpath($0, nil) }
        var result = resolved.map { String(cString: $0) } ?? existing
        if let resolved {
            free(resolved)
        }
        for component in missing {
            result = (result as NSString).appendingPathComponent(component)
        }
        return result
    }

    public static func identity(_ path: String) -> Data {
        Data(canonical(path).utf8)
    }

    public static func contains(_ path: String, in directory: String) -> Bool {
        let path = Data(path.utf8)
        let directory = Data(directory.utf8)
        return path == directory || path.starts(with: directory + Data([47]))
    }
}

public enum WorktreeLinkInspector {
    public static func inspect(_ records: [GitWorktree], commonDirectory: String, currentPath: String?) -> [GitWorktree] {
        let administrative = (commonDirectory as NSString).appendingPathComponent("worktrees")
        var identifiers: [Data: String] = [:]
        for identifier in (try? FileManager.default.contentsOfDirectory(atPath: administrative)) ?? [] {
            let folder = (administrative as NSString).appendingPathComponent(identifier)
            guard let backlink = firstLine((folder as NSString).appendingPathComponent("gitdir")), !backlink.isEmpty else { continue }
            let dotGit = resolve(backlink, relativeTo: folder)
            identifiers[WorktreePaths.identity((dotGit as NSString).deletingLastPathComponent)] = identifier
        }
        let currentIdentity = currentPath.map(WorktreePaths.identity)
        return records.map { record in
            let identity = WorktreePaths.identity(record.path)
            let exists = FileManager.default.fileExists(atPath: record.path)
            var style = WorktreeLinkStyle.unknown
            var broken = false
            var moved: String?
            var foreign = false
            if !record.isMain, let identifier = identifiers[identity] {
                let ownAdministrative = (administrative as NSString).appendingPathComponent(identifier)
                if !exists {
                    if let main = records.first, main.isMain {
                        moved = movedPath(record.path, identifier: identifier, mainPath: main.path, commonDirectory: commonDirectory)
                        if let moved, let link = link(at: moved) {
                            style = link.style
                        }
                        broken = moved != nil
                    }
                } else if let link = link(at: record.path) {
                    style = link.style
                    if WorktreePaths.identity(link.target) != WorktreePaths.identity(ownAdministrative) {
                        foreign = FileManager.default.fileExists(atPath: link.target)
                        broken = !foreign
                    }
                }
            }
            return GitWorktree(path: record.path, head: record.head, branchRefName: record.branchRefName,
                               isMain: record.isMain, isBare: record.isBare, isDetached: record.isDetached,
                               isLocked: record.isLocked, lockReason: record.lockReason,
                               isPrunable: record.isPrunable, prunableReason: record.prunableReason,
                               isCurrent: identity == currentIdentity, linkStyle: style, hasBrokenLink: broken,
                               movedPath: moved, folderExists: exists, hasForeignLink: foreign)
        }
    }

    /// Locate must verify the administrative identity before Git can write a
    /// link. With an explicit --git-dir, Git otherwise accepts an unrelated
    /// checkout with the same administrative identifier.
    public static func canRepair(_ record: GitWorktree, at path: String, commonDirectory: String) -> Bool {
        guard !record.hasForeignLink, let selected = link(at: path) else { return false }
        let administrative = (commonDirectory as NSString).appendingPathComponent("worktrees")
        for identifier in (try? FileManager.default.contentsOfDirectory(atPath: administrative)) ?? [] {
            let folder = (administrative as NSString).appendingPathComponent(identifier)
            guard let backlink = firstLine((folder as NSString).appendingPathComponent("gitdir")), !backlink.isEmpty else { continue }
            let original = (resolve(backlink, relativeTo: folder) as NSString).deletingLastPathComponent
            guard WorktreePaths.identity(original) == WorktreePaths.identity(record.path) else { continue }
            if WorktreePaths.identity(selected.target) == WorktreePaths.identity(folder) {
                return true
            }
            return record.movedPath.map(WorktreePaths.identity) == WorktreePaths.identity(path)
                && !FileManager.default.fileExists(atPath: selected.target)
        }
        return false
    }

    private static func firstLine(_ path: String) -> String? {
        guard var contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        if contents.last == "\n" {
            contents.removeLast()
        }
        return contents
    }

    private static func resolve(_ target: String, relativeTo folder: String) -> String {
        let path = (target as NSString).isAbsolutePath ? target : (folder as NSString).appendingPathComponent(target)
        return (path as NSString).standardizingPath
    }

    private static func link(at path: String) -> (target: String, style: WorktreeLinkStyle)? {
        guard let line = firstLine((path as NSString).appendingPathComponent(".git")), line.hasPrefix("gitdir: ") else { return nil }
        let target = String(line.dropFirst(8))
        guard !target.isEmpty else { return nil }
        return (resolve(target, relativeTo: path), (target as NSString).isAbsolutePath ? .absolute : .relative)
    }

    private static func movedPath(_ path: String, identifier: String, mainPath: String, commonDirectory: String) -> String? {
        let main = WorktreePaths.canonical(mainPath)
        let common = WorktreePaths.canonical(commonDirectory)
        guard WorktreePaths.contains(common, in: main) else { return nil }
        let suffix = common == main ? "" : String(common.dropFirst(main.count + 1))
        let path = (path as NSString).standardizingPath
        var formerMain = (path as NSString).deletingLastPathComponent
        while formerMain.count > 1 {
            let relative = String(path.dropFirst(formerMain.count + 1))
            let candidate = (mainPath as NSString).appendingPathComponent(relative)
            let formerCommon = (formerMain as NSString).appendingPathComponent(suffix)
            let formerAdministrative = ((formerCommon as NSString).appendingPathComponent("worktrees") as NSString).appendingPathComponent(identifier)
            if let link = link(at: candidate), Data(link.target.utf8) == Data((formerAdministrative as NSString).standardizingPath.utf8),
               !FileManager.default.fileExists(atPath: link.target)
            {
                return candidate
            }
            formerMain = (formerMain as NSString).deletingLastPathComponent
        }
        return nil
    }
}
