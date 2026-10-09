import AppKit

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
    let rawPath: Data?
    let status: String
    let previousPath: String?
    let order: Int

    init(path: String, rawPath: Data? = nil, status: String, previousPath: String?, order: Int) {
        self.path = path
        self.rawPath = rawPath
        self.status = status
        self.previousPath = previousPath
        self.order = order
    }

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
        if let previousPath, Data(previousPath.utf8) != Data(path.utf8) {
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

        var nodes: [PBGitTree] = []
        if commit is PBUncommittedChanges {
            var byRawPath: [Data: PBGitTree] = [:]
            for case let leaf as PBWorkingTree in leafNodes(in: commit.tree) {
                if let rawPath = leaf.rawPath {
                    byRawPath[rawPath] = leaf
                }
            }
            for change in changes {
                guard let rawPath = change.rawPath, let node = byRawPath[rawPath] else { continue }
                nodes.append(node)
                metadata[ObjectIdentifier(node)] = change
            }
        } else {
            for change in changes {
                let node = HistoryCommittedTreeNode(rawPath: change.rawPath ?? Data(change.path.utf8))
                node.repository = repository
                node.sha = commit.sha
                node.path = change.path
                node.parent = root
                node.leaf = true
                nodes.append(node)
                metadata[ObjectIdentifier(node)] = change
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
        let task = repository.task(withArguments: ["diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-M", "-z", sha])
        task.separatesStandardError = true
        guard (try? task.launch()) != nil else { return [] }
        return parseNameStatus(task.standardOutputData)
    }

    private func workingChanges() -> [HistoryChangedPath] {
        let task = repository.task(withArguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        task.separatesStandardError = true
        guard (try? task.launch()) != nil else { return [] }
        let tokens = IndexFilePresentation.rawPaths(data: task.standardOutputData)
        var result: [HistoryChangedPath] = []
        var positions: [Data: Int] = [:]
        var index = 0
        while index < tokens.count {
            let record = tokens[index]
            guard record.count >= 3, record[record.startIndex + 2] == 0x20,
                  let statusField = String(data: record.prefix(2), encoding: .ascii) else { index += 1; continue }
            let status = statusField.trimmingCharacters(in: .whitespaces)
            let rawPath = Data(record.dropFirst(3))
            let rename = status.contains("R") || status.contains("C")
            let previous = rename && index + 1 < tokens.count
                ? IndexPathDisplayName.string(for: tokens[index + 1]) : nil
            if let path = IndexFilePresentation.safePath(rawPath: rawPath) {
                if let position = positions[rawPath] {
                    if result[position].status == "??", status != "??" {
                        result[position] = HistoryChangedPath(path: path, rawPath: rawPath, status: status, previousPath: previous, order: position)
                    }
                } else {
                    positions[rawPath] = result.count
                    result.append(HistoryChangedPath(path: path, rawPath: rawPath, status: status, previousPath: previous, order: result.count))
                }
            } else {
                NSLog("[GitX] Omitted unsupported filename from working-state tree: %@", IndexPathDisplayName.string(for: rawPath))
            }
            index += rename ? 2 : 1
        }
        return result
    }

    private func parseNameStatus(_ output: Data) -> [HistoryChangedPath] {
        let tokens = IndexFilePresentation.rawPaths(data: output)
        var result: [HistoryChangedPath] = []
        var index = 0
        while index < tokens.count {
            guard let status = String(data: tokens[index], encoding: .ascii) else { break }
            let rename = status.hasPrefix("R") || status.hasPrefix("C")
            let required = rename ? 3 : 2
            guard index + required - 1 < tokens.count else { break }
            let oldPath = rename ? IndexPathDisplayName.string(for: tokens[index + 1]) : nil
            let rawPath = tokens[index + required - 1]
            result.append(HistoryChangedPath(path: IndexPathDisplayName.string(for: rawPath), rawPath: rawPath,
                                             status: status, previousPath: oldPath, order: result.count))
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

    private func orderedBefore(_ left: PBGitTree, _ right: PBGitTree) -> Bool {
        let comparison = left.fullPath.localizedStandardCompare(right.fullPath)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        let leftBytes = metadata[ObjectIdentifier(left)]?.rawPath ?? Data(left.fullPath.utf8)
        let rightBytes = metadata[ObjectIdentifier(right)]?.rawPath ?? Data(right.fullPath.utf8)
        return leftBytes.lexicographicallyPrecedes(rightBytes)
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
                return orderedBefore($0, $1)
            }
        case .alphabetical:
            return nodes.sorted(by: orderedBefore)
        @unknown default:
            return nodes
        }
    }
}

/// Availability decisions are shared by opening and Quick Look; Cocoa callers
/// never construct file URLs from missing temporary paths.
@objc(PBHistoryFilePreview)
final class HistoryFilePreview: NSObject {
    @objc(urlForTree:)
    static func url(for tree: PBGitTree) -> URL? {
        if let raw = (tree as? HistoryCommittedTreeNode)?.rawPath, IndexFilePresentation.safePath(rawPath: raw) == nil {
            return nil
        }
        guard let path = tree.tmpFileNameForContents(), !path.isEmpty else {
            NSLog("[GitX] History preview path is unavailable for %@", tree.fullPath ?? "")
            return nil
        }
        return URL(fileURLWithPath: path)
    }
}

private extension PBGitTree {
    var objectIdentifier: ObjectIdentifier {
        ObjectIdentifier(self)
    }
}

/// Preserve Git's identity independently of Swift String equivalence. Unsafe
/// byte paths remain visible but never become an unrelated escaped argv path.
private final nonisolated class HistoryCommittedTreeNode: PBGitTree {
    @objc let rawPath: Data
    init(rawPath: Data) {
        self.rawPath = rawPath; super.init()
    }

    override var fullPath: String! {
        IndexPathDisplayName.string(for: rawPath)
    }

    private var canPreview: Bool {
        IndexFilePresentation.safePath(rawPath: rawPath) != nil
    }

    private var previewPath: String?
    private var previewModificationDate: Date?

    private var hasCurrentPreview: Bool {
        guard let previewPath, let previewModificationDate,
              let attributes = try? FileManager.default.attributesOfItem(atPath: previewPath),
              let modificationDate = attributes[.modificationDate] as? Date else { return false }
        return modificationDate == previewModificationDate
    }

    private func task(_ arguments: [String]) -> PBTask {
        // Git on macOS can precompose argv even when the committed tree keeps
        // both spellings. This leaf's immutable bytes must select its own blob.
        repository.task(withArguments: ["-c", "core.precomposeUnicode=false"] + arguments)
    }

    private func output(_ arguments: [String], diagnosticOnFailure: Bool = true) -> String? {
        let command = task(arguments)
        command.separatesStandardError = true
        do { try command.launch() } catch { return diagnosticOnFailure ? String(data: command.standardErrorData, encoding: .utf8) : nil }
        guard var text = command.standardOutputString() else { return nil }
        // Retain PBGitTree's existing one-newline stripping behavior.
        if text.utf16.count > 1, text.hasSuffix("\n") {
            text.removeLast()
        }
        return text
    }

    private var objectSpec: String {
        "\(sha ?? ""):\(fullPath ?? "")"
    }

    override var contents: String! {
        guard canPreview else { return "This filename cannot be represented for preview." }
        if hasCurrentPreview, let previewPath, let data = try? Data(contentsOf: URL(fileURLWithPath: previewPath)) {
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
        return output(["show", objectSpec])
    }

    private var unavailableText: String? {
        let attributes = output(["--literal-pathspecs", "check-attr", "binary", "--", fullPath], diagnosticOnFailure: false)
        let binaryAttribute = attributes?.hasSuffix("binary: set") == true
        let binaryExtension = [".pdf", ".jpg", ".jpeg", ".png", ".bmp", ".gif", ".o"].contains { fullPath.hasSuffix($0) }
        let binary = binaryAttribute || (attributes != nil && attributes?.hasSuffix("binary: unset") != true && binaryExtension)
        let size = fileSize()
        if binary {
            return "\(fullPath ?? "") appears to be a binary file of \(size) bytes"
        }
        if size > 52_428_800 {
            return "\(fullPath ?? "") is too big to be displayed (\(size) bytes)"
        }
        return nil
    }

    private func checkedText(_ text: String?) -> String? {
        guard let text else { return nil }
        if (text as NSString).range(of: "\0", options: [], range: NSRange(location: 0, length: text.utf16.count >= 8000 ? 7999 : text.utf16.count)).location != NSNotFound {
            return "\(fullPath ?? "") appears to be a binary file of \(fileSize()) bytes"
        }
        return text
    }

    override func textContents() -> String! {
        guard canPreview else { return contents }
        return unavailableText ?? checkedText(contents)
    }

    override func blame() -> String! {
        guard canPreview else { return contents }
        return unavailableText ?? checkedText(output(["--literal-pathspecs", "blame", "-p", sha, "--", fullPath]))
    }

    override func log(_ format: String!) -> String! {
        guard canPreview else { return contents }
        return unavailableText ?? checkedText(output(["--literal-pathspecs", "log", "--pretty=format:\(format ?? "")", "--follow", "--", fullPath]))
    }

    override func tmpFileNameForContents() -> String! {
        guard canPreview else { return nil }
        if hasCurrentPreview, let previewPath {
            return previewPath
        }
        let command = task(["show", objectSpec])
        command.separatesStandardError = true
        do {
            try command.launch()
            let destination: URL
            if let previewPath {
                destination = URL(fileURLWithPath: previewPath)
            } else {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitX-History-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                destination = directory.appendingPathComponent((fullPath as NSString).lastPathComponent)
            }
            try command.standardOutputData.write(to: destination, options: .atomic)
            previewPath = destination.path
            previewModificationDate = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.modificationDate] as? Date
            return previewPath
        } catch {
            NSLog("[GitX] History preview creation failed for %@: %@", fullPath ?? "", error.localizedDescription)
            return nil
        }
    }

    override func fileSize() -> Int64 {
        guard canPreview else { return 0 }
        return output(["cat-file", "-s", objectSpec]).flatMap(Int64.init) ?? -1
    }
}

@objc(PBHistoryFileOpening)
final class HistoryFileOpening: NSObject {
    @objc(openTree:outline:item:opener:)
    static func open(tree: PBGitTree, outline: NSOutlineView?, item: Any?, opener: (URL) -> Bool) -> Bool {
        if !tree.leaf {
            guard let outline, let item else { return false }
            if outline.isItemExpanded(item) {
                outline.collapseItem(item)
            } else {
                outline.expandItem(item)
            }
            NSLog("[GitX] Toggled history directory %@", tree.fullPath ?? "")
            return true
        }
        guard let url = HistoryFilePreview.url(for: tree) else { return false }
        NSLog("[GitX] Opening history leaf preview %@", tree.fullPath ?? "")
        return opener(url)
    }
}

// swiftlint:enable unused_declaration
