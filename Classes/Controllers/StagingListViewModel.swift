import AppKit

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

@objc(PBStagingListSection)
enum StagingListSection: Int {
    case staged
    case unstaged
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
}

// swiftlint:enable unused_declaration
