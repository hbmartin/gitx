import AppKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

@objc(PBCommitPatchExportPolicy)
final nonisolated class CommitPatchExportPolicy: NSObject {
    @objc(filenamesForSubjects:)
    static func filenames(subjects: [String]) -> [String] {
        subjects.enumerated().map { offset, subject in
            String(format: "%04d-%@.patch", offset + 1, safeFilename(subject: subject))
        }
    }

    @objc(safeFilenameForSubject:)
    static func safeFilename(subject: String) -> String {
        let folded = subject.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let pieces = folded.unicodeScalars.map { allowed.contains($0) ? Character(String($0).lowercased()) : "-" }
        let collapsed = String(pieces).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((trimmed.isEmpty ? "commit" : trimmed).prefix(80))
    }

    @objc(revisionForOldestSHA:newestSHA:oldestIsRoot:)
    static func revision(oldestSHA: String, newestSHA: String, oldestIsRoot: Bool) -> String {
        oldestIsRoot ? newestSHA : "\(oldestSHA)^..\(newestSHA)"
    }

    @objc(seriesOutput:matchesSHAs:)
    static func series(output: String, matches shas: [String]) -> Bool {
        output.split(whereSeparator: \Character.isNewline).map(String.init) == shas
    }
}

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration
@objc(PBCommitPatchExportCoordinator)
final class CommitPatchExportCoordinator: NSObject {
    private enum ExportMode: String {
        case perCommit
        case singleFile
    }

    private static let rememberedModeKey = "PBPatchExportMode"
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "PatchExport")

    @objc(exportCommits:fromWindow:)
    func export(commits: [PBGitCommit], from window: NSWindow?) {
        guard let repository = commits.first?.repository, !commits.isEmpty else { return }
        let mode: ExportMode
        if commits.count == 1 {
            mode = .singleFile
        } else {
            guard let selectedMode = chooseMode(commitCount: commits.count, window: window) else { return }
            mode = selectedMode
        }

        switch mode {
        case .perCommit:
            exportPerCommit(commits: commits, from: window)
        case .singleFile:
            guard commits.count == 1 || commitsFormDirectFirstParentSeries(commits, repository: repository) else {
                presentError(
                    title: "One patch file isn’t available",
                    message: "The selected commits are not a contiguous first-parent series. Export them as one file per commit instead.",
                    window: window
                )
                return
            }
            exportSingleFile(commits: commits, repository: repository, from: window)
        }
    }

    private func chooseMode(commitCount: Int, window: NSWindow?) -> ExportMode? {
        let remembered = ExportMode(
            rawValue: UserDefaults.standard.string(forKey: Self.rememberedModeKey) ?? ""
        ) ?? .perCommit
        let alert = NSAlert()
        alert.messageText = "Create patches for \(commitCount) commits"
        alert.informativeText = "Would you like one patch file per commit, or one file containing the entire commit series?"
        if remembered == .perCommit {
            alert.addButton(withTitle: "One Per Commit")
            alert.addButton(withTitle: "One Patch File")
        } else {
            alert.addButton(withTitle: "One Patch File")
            alert.addButton(withTitle: "One Per Commit")
        }
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return nil }
        let choseFirst = response == .alertFirstButtonReturn
        let mode: ExportMode = choseFirst ? remembered : (remembered == .perCommit ? .singleFile : .perCommit)
        UserDefaults.standard.set(mode.rawValue, forKey: Self.rememberedModeKey)
        logger.info("Selected patch export mode: \(mode.rawValue, privacy: .public)")
        return mode
    }

    private func exportPerCommit(commits: [PBGitCommit], from window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder for Patch Files"
        panel.prompt = "Create Patches"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let ordered = commits.sorted { $0.date < $1.date }
        let names = CommitPatchExportPolicy.filenames(subjects: ordered.map(\.subject))
        let duplicateNames = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys
        let existingNames = names.filter {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard duplicateNames.isEmpty, existingNames.isEmpty else {
            let conflicts = Array(duplicateNames) + existingNames
            presentError(
                title: "Patch files were not created",
                message: "These filenames conflict:\n\n" + conflicts.sorted().joined(separator: "\n"),
                window: window
            )
            return
        }

        let temporaryDirectory = directory.appendingPathComponent(".gitx-patches-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
            for (index, commit) in ordered.enumerated() {
                guard let patch = commit.patch, !patch.isEmpty else {
                    throw PatchExportError.missingPatch(commit.shortName())
                }
                try Data(patch.utf8).write(to: temporaryDirectory.appendingPathComponent(names[index]), options: .atomic)
            }
            for name in names {
                try FileManager.default.moveItem(
                    at: temporaryDirectory.appendingPathComponent(name),
                    to: directory.appendingPathComponent(name)
                )
            }
            try FileManager.default.removeItem(at: temporaryDirectory)
            NSWorkspace.shared.activateFileViewerSelecting(names.map { directory.appendingPathComponent($0) })
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            presentError(title: "Patch files were not created", message: error.localizedDescription, window: window)
        }
    }

    private func exportSingleFile(
        commits: [PBGitCommit],
        repository: PBGitRepository,
        from window: NSWindow?
    ) {
        let ordered = commits.sorted { $0.date < $1.date }
        let panel = NSSavePanel()
        panel.title = commits.count == 1 ? "Create Patch" : "Create Patch Series"
        panel.prompt = "Create Patch"
        panel.nameFieldStringValue = commits.count == 1
            ? "0001-\(CommitPatchExportPolicy.safeFilename(subject: ordered[0].subject)).patch"
            : "\(CommitPatchExportPolicy.safeFilename(subject: ordered.first?.subject ?? "commit-series")).patch"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let patch: String
            if commits.count == 1 {
                guard let commitPatch = commits[0].patch, !commitPatch.isEmpty else {
                    throw PatchExportError.missingPatch(commits[0].shortName())
                }
                patch = commitPatch
            } else {
                let oldest = ordered[0]
                let newest = ordered[ordered.count - 1]
                var arguments = ["format-patch", "--stdout", "--reverse"]
                if oldest.parents.isEmpty {
                    arguments.append(contentsOf: ["--root", newest.sha])
                } else {
                    arguments.append("\(oldest.sha)^..\(newest.sha)")
                }
                patch = try repository.outputOfTask(withArguments: arguments)
            }
            try Data(patch.utf8).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentError(title: "Patch was not created", message: error.localizedDescription, window: window)
        }
    }

    private func commitsFormDirectFirstParentSeries(
        _ commits: [PBGitCommit],
        repository: PBGitRepository
    ) -> Bool {
        let ordered = commits.sorted { $0.date < $1.date }
        guard let oldest = ordered.first, let newest = ordered.last else { return false }
        let revision = CommitPatchExportPolicy.revision(
            oldestSHA: oldest.sha,
            newestSHA: newest.sha,
            oldestIsRoot: oldest.parents.isEmpty
        )
        guard let output = try? repository.outputOfTask(withArguments: [
            "rev-list", "--first-parent", "--reverse", revision,
        ]) else { return false }
        return CommitPatchExportPolicy.series(output: output, matches: ordered.map(\.sha))
    }

    private func presentError(title: String, message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

private enum PatchExportError: LocalizedError {
    case missingPatch(String)

    var errorDescription: String? {
        switch self {
        case let .missingPatch(commit): "Git did not return a patch for commit \(commit)."
        }
    }
}

// swiftlint:enable unused_declaration
