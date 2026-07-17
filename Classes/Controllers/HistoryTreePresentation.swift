// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration
private final nonisolated class HistoryFlatTreeRoot: PBGitTree {
    var flatChildren: [PBGitTree] = []

    override var children: [Any]! {
        flatChildren
    }

    override var fullPath: String! {
        ""
    }
}

private struct HistoryChangedPath {
    let path: String
    let status: String
    let previousPath: String?
    let order: Int

    var statusRank: Int {
        switch status.first {
        case "A", "?": 0
        case "M", "T": 1
        case "R", "C": 2
        case "D": 3
        default: 4
        }
    }

    var displayTitle: String {
        let code = status.isEmpty ? "M" : String(status.prefix(1))
        if let previousPath, previousPath != path {
            return "\(code)  \(path)  ←  \(previousPath)"
        }
        return "\(code)  \(path)"
    }
}

@objc(PBHistoryTreePresentation)
final class HistoryTreePresentation: NSObject {
    private let repository: PBGitRepository
    private var metadata: [ObjectIdentifier: HistoryChangedPath] = [:]

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        super.init()
    }

    @objc(treeForCommit:)
    func tree(for commit: PBGitCommit) -> PBGitTree {
        guard ApplicationSettings.changedFilesOnly else { return commit.tree }
        metadata.removeAll()
        let changes = commit is PBUncommittedChanges
            ? workingChanges()
            : committedChanges(sha: commit.sha)
        let root = HistoryFlatTreeRoot()
        root.repository = repository
        root.sha = commit.sha
        root.path = ""
        root.leaf = false

        let nodes: [PBGitTree]
        if commit is PBUncommittedChanges {
            let leaves = leafNodes(in: commit.tree)
            let byPath = Dictionary(uniqueKeysWithValues: leaves.map { ($0.fullPath, $0) })
            nodes = changes.compactMap { byPath[$0.path] }
        } else {
            nodes = changes.map { change in
                let node = PBGitTree()
                node.repository = repository
                node.sha = commit.sha
                node.path = change.path
                node.parent = root
                node.leaf = true
                return node
            }
        }

        let metadataByPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        for node in nodes {
            if let value = metadataByPath[node.fullPath] {
                metadata[ObjectIdentifier(node)] = value
            }
        }
        root.flatChildren = sorted(nodes)
        NSLog("[GitX] Built flat changed-file tree with %lu items", root.flatChildren.count)
        return root
    }

    @objc(displayTitleForTree:)
    func displayTitle(for tree: PBGitTree) -> String {
        metadata[ObjectIdentifier(tree)]?.displayTitle ?? tree.displayPath
    }

    @objc(toolTipForTree:)
    func toolTip(for tree: PBGitTree) -> String {
        guard let value = metadata[ObjectIdentifier(tree)] else { return tree.fullPath }
        if let previousPath = value.previousPath {
            return "\(value.path)\nRenamed from \(previousPath)"
        }
        return value.path
    }

    private func committedChanges(sha: String) -> [HistoryChangedPath] {
        guard let output = try? repository.outputOfTask(withArguments: [
            "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-M", "-z", sha,
        ]) else { return [] }
        return parseNameStatus(output)
    }

    private func workingChanges() -> [HistoryChangedPath] {
        guard let output = try? repository.outputOfTask(withArguments: [
            "status", "--porcelain=v1", "-z", "--untracked-files=all",
        ]) else { return [] }
        let tokens = output.components(separatedBy: "\0").filter { !$0.isEmpty }
        var result: [HistoryChangedPath] = []
        var index = 0
        while index < tokens.count {
            let record = tokens[index]
            guard record.count >= 3 else { index += 1; continue }
            let status = String(record.prefix(2)).trimmingCharacters(in: .whitespaces)
            let path = String(record.dropFirst(3))
            let rename = status.contains("R") || status.contains("C")
            let previous = rename && index + 1 < tokens.count ? tokens[index + 1] : nil
            result.append(HistoryChangedPath(path: path, status: status, previousPath: previous, order: result.count))
            index += rename ? 2 : 1
        }
        return result
    }

    private func parseNameStatus(_ output: String) -> [HistoryChangedPath] {
        let tokens = output.components(separatedBy: "\0").filter { !$0.isEmpty }
        var result: [HistoryChangedPath] = []
        var index = 0
        while index < tokens.count {
            let status = tokens[index]
            let rename = status.hasPrefix("R") || status.hasPrefix("C")
            let required = rename ? 3 : 2
            guard index + required - 1 < tokens.count else { break }
            let oldPath = rename ? tokens[index + 1] : nil
            let path = tokens[index + required - 1]
            result.append(HistoryChangedPath(path: path, status: status, previousPath: oldPath, order: result.count))
            index += required
        }
        return result
    }

    private func leafNodes(in root: PBGitTree) -> [PBGitTree] {
        var result: [PBGitTree] = []
        var pending = (root.children as? [PBGitTree]) ?? []
        while let node = pending.popLast() {
            if node.leaf {
                result.append(node)
            } else {
                pending.append(contentsOf: (node.children as? [PBGitTree]) ?? [])
            }
        }
        return result
    }

    private func sorted(_ nodes: [PBGitTree]) -> [PBGitTree] {
        switch ApplicationSettings.changedFilesSort {
        case .gitOrder:
            return nodes.sorted { metadata[$0.objectIdentifier]?.order ?? 0 < metadata[$1.objectIdentifier]?.order ?? 0 }
        case .status:
            return nodes.sorted {
                let left = metadata[ObjectIdentifier($0)]
                let right = metadata[ObjectIdentifier($1)]
                if left?.statusRank != right?.statusRank {
                    return left?.statusRank ?? 4 < right?.statusRank ?? 4
                }
                return $0.fullPath.localizedStandardCompare($1.fullPath) == .orderedAscending
            }
        case .alphabetical:
            return nodes.sorted { $0.fullPath.localizedStandardCompare($1.fullPath) == .orderedAscending }
        @unknown default:
            return nodes
        }
    }
}

private extension PBGitTree {
    var objectIdentifier: ObjectIdentifier {
        ObjectIdentifier(self)
    }
}

// swiftlint:enable unused_declaration
