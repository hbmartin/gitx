import AppKit

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

@objc(PBStagingListSection)
enum StagingListSection: Int {
    case staged
    case unstaged
}

/// File-list commands whose selection semantics depend on the staging side.
@objc(PBStagingFileAction)
enum StagingFileAction: Int {
    case stage
    case unstage
    case discard
    case forceDiscard
    case open
    case reveal
    case ignore
    case trash
}

/// Describes which staging-list surface originated a command. Sectioned
/// commands may intentionally operate across both visual sections, while
/// split commands remain scoped to their sole active table.
@objc(PBStagingSelectionContext)
enum StagingSelectionContext: Int {
    case sectioned
    case splitStaged
    case splitUnstaged
    case splitAutomatic
}

/// Captures one action-specific selection when a menu is presented so menu
/// titles, validation, and execution all operate on the same file set.
@objc(PBStagingActionSelection)
final nonisolated class StagingActionSelection: NSObject {
    @objc let action: StagingFileAction
    @objc let files: [PBChangedFile]

    @objc(initWithAction:files:)
    init(action: StagingFileAction, files: [PBChangedFile]) {
        self.action = action
        self.files = files
        super.init()
    }
}

/// One row of the single sectioned staging list: either a section header or a
/// file inside a section.
@objc(PBStagingListRow)
final nonisolated class StagingListRow: NSObject {
    @objc let isHeader: Bool
    @objc let section: StagingListSection
    @objc let file: PBChangedFile?

    private init(isHeader: Bool, section: StagingListSection, file: PBChangedFile?) {
        self.isHeader = isHeader
        self.section = section
        self.file = file
        super.init()
    }

    static func header(_ section: StagingListSection) -> StagingListRow {
        StagingListRow(isHeader: true, section: section, file: nil)
    }

    static func file(_ file: PBChangedFile, section: StagingListSection) -> StagingListRow {
        StagingListRow(isHeader: false, section: section, file: file)
    }
}

/// A file whose diff the staging pane should render, with the side it was
/// selected from.
@objc(PBStagingDiffRequest)
final nonisolated class StagingDiffRequest: NSObject {
    @objc let file: PBChangedFile
    @objc let staged: Bool

    @objc(initWithFile:staged:)
    init(file: PBChangedFile, staged: Bool) {
        self.file = file
        self.staged = staged
        super.init()
    }
}

/// Pure presentation logic shared by both staging file-list layouts: section
/// membership, search filtering, sorting, sectioned-row flattening, checkbox
/// states, and the selection-to-diff derivation. Owns no views.
@objc(PBStagingListViewModel)
final nonisolated class StagingListViewModel: NSObject {
    private enum DragPayloadKey {
        static let path = "path"
        static let sourceSection = "sourceSection"
    }

    @objc var searchText = ""
    @objc var sortOrder: StagingFileSortOrder = .path

    @objc(filesInSection:fromChanges:)
    func files(in section: StagingListSection, from changes: [PBChangedFile]) -> [PBChangedFile] {
        let members = changes.filter { file in
            switch section {
            case .staged: file.hasStagedChanges
            case .unstaged: file.hasUnstagedChanges
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty
            ? members
            : members.filter { $0.path.localizedCaseInsensitiveContains(query) }
        return sorted(matching)
    }

    @objc(flattenedRowsFromChanges:)
    func flattenedRows(from changes: [PBChangedFile]) -> [StagingListRow] {
        var rows: [StagingListRow] = []
        for section in [StagingListSection.staged, .unstaged] {
            let files = files(in: section, from: changes)
            guard !files.isEmpty else { continue }
            rows.append(.header(section))
            rows.append(contentsOf: files.map { .file($0, section: section) })
        }
        return rows
    }

    /// Commit eligibility is index membership, not presentation state. Search
    /// filtering affects visible rows and headers but never this total.
    @objc(stagedFileCountFromChanges:)
    func stagedFileCount(from changes: [PBChangedFile]) -> Int {
        changes.filter(\.hasStagedChanges).count
    }

    /// Resolves the file set for one command. Sectioned Open and Reveal use a
    /// staged-first union, while mutating worktree commands never inherit a
    /// staged-only selection. Split commands remain on the single active side.
    @objc(resolvedFilesForAction:context:stagedSelection:unstagedSelection:)
    func resolvedFiles(
        for action: StagingFileAction,
        context: StagingSelectionContext,
        stagedSelection: [PBChangedFile],
        unstagedSelection: [PBChangedFile]
    ) -> [PBChangedFile] {
        let staged = deduplicated(stagedSelection)
        let unstaged = deduplicated(unstagedSelection)

        switch context {
        case .sectioned:
            switch action {
            case .stage, .discard, .forceDiscard, .ignore, .trash:
                return unstaged
            case .unstage:
                return staged
            case .open, .reveal:
                return deduplicated(staged + unstaged)
            }
        case .splitStaged:
            return resolvedSplitFiles(for: action, staged: staged, unstaged: [])
        case .splitUnstaged:
            return resolvedSplitFiles(for: action, staged: [], unstaged: unstaged)
        case .splitAutomatic:
            guard staged.isEmpty != unstaged.isEmpty else { return [] }
            return resolvedSplitFiles(for: action, staged: staged, unstaged: unstaged)
        }
    }

    /// Stable sectioned-list drag payload. Row positions are deliberately not
    /// serialized because filtering, sorting, and index refreshes can reorder
    /// them before a drop is accepted.
    @objc(sectionedDragPayloadForRows:selectedIndexes:)
    func sectionedDragPayload(
        rows: [StagingListRow],
        selectedIndexes: IndexSet
    ) -> [[String: Any]] {
        selectedIndexes.compactMap { index -> [String: Any]? in
            guard rows.indices.contains(index), let file = rows[index].file else { return nil }
            return [
                DragPayloadKey.path: file.path,
                DragPayloadKey.sourceSection: rows[index].section.rawValue,
            ]
        }
    }

    /// Strictly decodes a stable drag payload, resolves it against current
    /// rows, ignores stale entries, filters same-section entries, and
    /// de-duplicates paths without changing their payload order. `nil` means
    /// the payload itself was malformed; an empty array is valid but cannot
    /// produce a drop.
    @objc(resolvedDropFilesFromPropertyList:rows:destinationSection:)
    func resolvedDropFiles(
        from propertyList: Any?,
        rows: [StagingListRow],
        destinationSection: StagingListSection
    ) -> [PBChangedFile]? {
        guard let dictionaries = propertyList as? [[String: Any]] else { return nil }
        var entries: [(path: String, source: StagingListSection)] = []
        for dictionary in dictionaries {
            guard dictionary.count == 2,
                  let path = dictionary[DragPayloadKey.path] as? String,
                  !path.isEmpty,
                  let rawSection = dictionary[DragPayloadKey.sourceSection] as? Int,
                  let source = StagingListSection(rawValue: rawSection)
            else { return nil }
            entries.append((path, source))
        }

        var seenPaths = Set<String>()
        var resolved: [PBChangedFile] = []
        for entry in entries where entry.source != destinationSection {
            guard !seenPaths.contains(entry.path),
                  let file = rows.first(where: {
                      $0.section == entry.source && $0.file?.path == entry.path
                  })?.file
            else { continue }
            seenPaths.insert(entry.path)
            resolved.append(file)
        }
        return resolved
    }

    /// Row checkboxes read staging membership: a fully staged file is checked
    /// in the Staged section, a partially staged file shows mixed on both
    /// sides, and unstaged-only files are unchecked.
    @objc(rowCheckboxStateForFile:inSection:)
    func rowCheckboxState(for file: PBChangedFile, in section: StagingListSection) -> Int {
        switch section {
        case .staged:
            file.hasUnstagedChanges ? NSControl.StateValue.mixed.rawValue : NSControl.StateValue.on.rawValue
        case .unstaged:
            file.hasStagedChanges ? NSControl.StateValue.mixed.rawValue : NSControl.StateValue.off.rawValue
        }
    }

    /// The master checkbox summarizes its section: Staged reads on when every
    /// member is fully staged and mixed when some still have unstaged
    /// changes; Unstaged always reads off so clicking it means "stage all".
    @objc(masterCheckboxStateForChanges:inSection:)
    func masterCheckboxState(for changes: [PBChangedFile], in section: StagingListSection) -> Int {
        let files = files(in: section, from: changes)
        guard !files.isEmpty else { return NSControl.StateValue.off.rawValue }
        switch section {
        case .staged:
            return files.contains(where: \.hasUnstagedChanges)
                ? NSControl.StateValue.mixed.rawValue
                : NSControl.StateValue.on.rawValue
        case .unstaged:
            return NSControl.StateValue.off.rawValue
        }
    }

    /// Staged selections render before unstaged ones, matching the historic
    /// stage-diff pane ordering.
    @objc(diffRequestsForStagedSelection:unstagedSelection:)
    func diffRequests(
        stagedSelection: [PBChangedFile],
        unstagedSelection: [PBChangedFile]
    ) -> [StagingDiffRequest] {
        stagedSelection.map { StagingDiffRequest(file: $0, staged: true) } +
            unstagedSelection.map { StagingDiffRequest(file: $0, staged: false) }
    }

    @objc(diffRequestsForRows:selectedIndexes:)
    func diffRequests(rows: [StagingListRow], selectedIndexes: IndexSet) -> [StagingDiffRequest] {
        let selected = selectedIndexes
            .filter { rows.indices.contains($0) }
            .compactMap { index -> StagingDiffRequest? in
                let row = rows[index]
                guard let file = row.file else { return nil }
                return StagingDiffRequest(file: file, staged: row.section == .staged)
            }
        return selected.filter(\.staged) + selected.filter { !$0.staged }
    }

    private func sorted(_ files: [PBChangedFile]) -> [PBChangedFile] {
        switch sortOrder {
        case .path:
            files.sorted {
                $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
            }
        case .status:
            files.sorted {
                if $0.status != $1.status {
                    $0.status.rawValue > $1.status.rawValue
                } else {
                    $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
                }
            }
        }
    }

    private func resolvedSplitFiles(
        for action: StagingFileAction,
        staged: [PBChangedFile],
        unstaged: [PBChangedFile]
    ) -> [PBChangedFile] {
        switch action {
        case .stage, .discard, .forceDiscard, .ignore, .trash:
            unstaged
        case .unstage:
            staged
        case .open, .reveal:
            staged.isEmpty ? unstaged : staged
        }
    }

    private func deduplicated(_ files: [PBChangedFile]) -> [PBChangedFile] {
        var seenPaths = Set<String>()
        return files.filter { seenPaths.insert($0.path).inserted }
    }
}

// swiftlint:enable unused_declaration
