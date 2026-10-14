import Foundation

/// Link inspection follows Git's administrative `gitdir` backlinks, never a
/// guessed folder name. A copied repository may still point into its original;
/// those existing foreign targets are deliberately left alone.
public enum WorktreePaths {
    public static func canonical(_ path: String) -> String {
        // Resolve the existing prefix before handling missing components.
        // Lexical normalization can change the meaning of symlink/.. paths.
        var existing = path
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
        inspect(records, commonDirectory: commonDirectory, currentPath: currentPath, fileSystem: .live)
    }

    static func inspect(_ records: [GitWorktree], commonDirectory: String, currentPath: String?, fileSystem: WorktreeEvidenceFileSystem) -> [GitWorktree] {
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
                        broken = moved.map { hasRepairableGitfile(at: $0, fileSystem: fileSystem) } ?? false
                    }
                } else if let link = link(at: record.path) {
                    style = link.style
                    if WorktreePaths.identity(link.target) != WorktreePaths.identity(ownAdministrative) {
                        foreign = FileManager.default.fileExists(atPath: link.target)
                        broken = !foreign && hasRepairableGitfile(at: record.path, fileSystem: fileSystem)
                    }
                } else {
                    broken = hasRepairableGitfile(at: record.path, fileSystem: fileSystem)
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
        (try? captureRepairTarget(record, at: path, commonDirectory: commonDirectory)) != nil
    }

    private static func hasRepairableGitfile(at path: String, fileSystem: WorktreeEvidenceFileSystem) -> Bool {
        do {
            _ = try fileSystem.regularContents((path as NSString).appendingPathComponent(".git"))
            return true
        } catch {
            return false
        }
    }

    private static func firstLine(_ path: String) -> String? {
        guard let data = try? WorktreeEvidenceFileSystem.live.regularContents(path) else { return nil }
        return firstLine(data)
    }

    static func firstLine(_ data: Data) -> String? {
        guard !data.contains(0), var contents = String(data: data, encoding: .utf8) else { return nil }
        if contents.last == "\n" {
            contents.removeLast()
        }
        return contents
    }

    static func resolve(_ target: String, relativeTo folder: String) -> String {
        (target as NSString).isAbsolutePath ? target : (folder as NSString).appendingPathComponent(target)
    }

    private static func link(at path: String) -> (target: String, style: WorktreeLinkStyle)? {
        // Git accepts symlink gitfiles. Inspection preserves their read-only
        // behavior; repair evidence separately rejects the symlink object.
        let gitfile = WorktreePaths.canonical((path as NSString).appendingPathComponent(".git"))
        guard let data = try? WorktreeEvidenceFileSystem.live.regularContents(gitfile) else { return nil }
        return link(data, at: path)
    }

    static func link(_ data: Data, at path: String) -> (target: String, style: WorktreeLinkStyle)? {
        guard let line = firstLine(data), line.hasPrefix("gitdir: ") else { return nil }
        let target = String(line.dropFirst(8))
        guard !target.isEmpty else { return nil }
        return (resolve(target, relativeTo: path), (target as NSString).isAbsolutePath ? .absolute : .relative)
    }

    static func movedPath(_ path: String, identifier: String, mainPath: String, commonDirectory: String) -> String? {
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
            if let link = link(at: candidate), WorktreePaths.identity(link.target) == WorktreePaths.identity(formerAdministrative),
               !FileManager.default.fileExists(atPath: link.target)
            {
                return candidate
            }
            formerMain = (formerMain as NSString).deletingLastPathComponent
        }
        return nil
    }
}
