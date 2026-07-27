import XCTest

final class StagingListViewModelTests: XCTestCase {
    private func file(
        _ path: String,
        status: PBChangedFileStatus = .MODIFIED,
        staged: Bool = false,
        unstaged: Bool = true
    ) -> PBChangedFile {
        let file = PBChangedFile(path: path)
        file.status = status
        file.hasStagedChanges = staged
        file.hasUnstagedChanges = unstaged
        return file
    }

    func testSectionMembershipIncludesPartiallyStagedFilesOnBothSides() {
        let model = PBStagingListViewModel()
        let changes = [
            file("staged.txt", staged: true, unstaged: false),
            file("partial.txt", staged: true, unstaged: true),
            file("unstaged.txt"),
            file("untracked.txt", status: .NEW),
        ]

        let staged = model.files(in: .staged, fromChanges: changes)
        let unstaged = model.files(in: .unstaged, fromChanges: changes)

        XCTAssertEqual(staged.map(\.path), ["partial.txt", "staged.txt"])
        XCTAssertEqual(unstaged.map(\.path), ["partial.txt", "unstaged.txt", "untracked.txt"])
    }

    func testSearchFilterMatchesPathSubstringCaseInsensitively() {
        let model = PBStagingListViewModel()
        model.searchText = "  Weather "
        let changes = [
            file("components/WeatherApp.tsx"),
            file("components/WeeklyWeather.tsx"),
            file("lib/utils.ts"),
        ]

        let unstaged = model.files(in: .unstaged, fromChanges: changes)

        XCTAssertEqual(
            unstaged.map(\.path),
            ["components/WeatherApp.tsx", "components/WeeklyWeather.tsx"]
        )
    }

    func testStagedCountIgnoresSearchFiltering() {
        let model = PBStagingListViewModel()
        model.searchText = "visible"
        let changes = [
            file("hidden-staged.txt", staged: true, unstaged: false),
            file("visible-unstaged.txt"),
        ]

        XCTAssertTrue(model.files(in: .staged, fromChanges: changes).isEmpty)
        XCTAssertEqual(model.stagedFileCount(fromChanges: changes), 1)
    }

    func testSectionedActionSelectionsUseTheCorrectSideAndDeduplicatedUnion() {
        let model = PBStagingListViewModel()
        let staged = file("staged.txt", staged: true, unstaged: false)
        let partial = file("partial.txt", staged: true, unstaged: true)
        let unstaged = file("unstaged.txt")
        let stagedSelection = [staged, partial]
        let unstagedSelection = [partial, unstaged]

        for action in [
            PBStagingFileAction.stage,
            .discard,
            .forceDiscard,
            .ignore,
            .trash,
        ] {
            XCTAssertEqual(
                model.resolvedFiles(
                    for: action,
                    context: .sectioned,
                    stagedSelection: stagedSelection,
                    unstagedSelection: unstagedSelection
                ).map(\.path),
                ["partial.txt", "unstaged.txt"]
            )
        }
        XCTAssertEqual(
            model.resolvedFiles(
                for: .unstage,
                context: .sectioned,
                stagedSelection: stagedSelection,
                unstagedSelection: unstagedSelection
            ).map(\.path),
            ["staged.txt", "partial.txt"]
        )
        for action in [PBStagingFileAction.open, .reveal] {
            XCTAssertEqual(
                model.resolvedFiles(
                    for: action,
                    context: .sectioned,
                    stagedSelection: stagedSelection,
                    unstagedSelection: unstagedSelection
                ).map(\.path),
                ["staged.txt", "partial.txt", "unstaged.txt"],
                "sectioned navigation is staged-first and de-duplicates a partially staged path"
            )
        }
    }

    func testSplitActionSelectionsRemainScopedToTheSoleActiveSide() {
        let model = PBStagingListViewModel()
        let staged = file("staged.txt", staged: true, unstaged: false)
        let unstaged = file("unstaged.txt")

        XCTAssertEqual(
            model.resolvedFiles(
                for: .open,
                context: .splitStaged,
                stagedSelection: [staged],
                unstagedSelection: [unstaged]
            ).map(\.path),
            ["staged.txt"]
        )
        XCTAssertTrue(model.resolvedFiles(
            for: .discard,
            context: .splitStaged,
            stagedSelection: [staged],
            unstagedSelection: [unstaged]
        ).isEmpty)
        XCTAssertEqual(
            model.resolvedFiles(
                for: .ignore,
                context: .splitUnstaged,
                stagedSelection: [staged],
                unstagedSelection: [unstaged]
            ).map(\.path),
            ["unstaged.txt"]
        )
        XCTAssertEqual(
            model.resolvedFiles(
                for: .reveal,
                context: .splitAutomatic,
                stagedSelection: [staged],
                unstagedSelection: []
            ).map(\.path),
            ["staged.txt"]
        )
        XCTAssertTrue(model.resolvedFiles(
            for: .open,
            context: .splitAutomatic,
            stagedSelection: [staged],
            unstagedSelection: [unstaged]
        ).isEmpty, "ambiguous split selections cannot accidentally become a union")
    }

    func testStatusSortOrdersDeletionsFirstThenPath() {
        let model = PBStagingListViewModel()
        model.sortOrder = .status
        let changes = [
            file("b-modified.txt", status: .MODIFIED),
            file("a-untracked.txt", status: .NEW),
            file("z-deleted.txt", status: .DELETED),
            file("a-modified.txt", status: .MODIFIED),
        ]

        let unstaged = model.files(in: .unstaged, fromChanges: changes)

        XCTAssertEqual(
            unstaged.map(\.path),
            ["z-deleted.txt", "a-modified.txt", "b-modified.txt", "a-untracked.txt"]
        )
    }

    func testFlattenedRowsSkipEmptySectionsAndKeepHeaderOrder() {
        let model = PBStagingListViewModel()
        let changes = [
            file("one.txt"),
            file("two.txt"),
        ]

        let rows = model.flattenedRows(fromChanges: changes)

        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].isHeader)
        XCTAssertEqual(rows[0].section, .unstaged)
        XCTAssertEqual(rows[1].file?.path, "one.txt")
        XCTAssertEqual(rows[2].file?.path, "two.txt")

        let mixed = model.flattenedRows(fromChanges: changes + [file("staged.txt", staged: true, unstaged: false)])
        XCTAssertTrue(mixed[0].isHeader)
        XCTAssertEqual(mixed[0].section, .staged)
        XCTAssertEqual(mixed[1].file?.path, "staged.txt")
        XCTAssertEqual(mixed[2].section, .unstaged)
        XCTAssertTrue(mixed[2].isHeader)
    }

    func testCheckboxStatesReflectFullAndPartialStaging() {
        let model = PBStagingListViewModel()
        let fullyStaged = file("staged.txt", staged: true, unstaged: false)
        let partial = file("partial.txt", staged: true, unstaged: true)
        let unstagedOnly = file("unstaged.txt")

        XCTAssertEqual(model.rowCheckboxState(for: fullyStaged, in: .staged), NSControl.StateValue.on.rawValue)
        XCTAssertEqual(model.rowCheckboxState(for: partial, in: .staged), NSControl.StateValue.mixed.rawValue)
        XCTAssertEqual(model.rowCheckboxState(for: partial, in: .unstaged), NSControl.StateValue.mixed.rawValue)
        XCTAssertEqual(model.rowCheckboxState(for: unstagedOnly, in: .unstaged), NSControl.StateValue.off.rawValue)

        XCTAssertEqual(
            model.masterCheckboxState(forChanges: [fullyStaged], in: .staged),
            NSControl.StateValue.on.rawValue
        )
        XCTAssertEqual(
            model.masterCheckboxState(forChanges: [fullyStaged, partial], in: .staged),
            NSControl.StateValue.mixed.rawValue
        )
        XCTAssertEqual(
            model.masterCheckboxState(forChanges: [unstagedOnly], in: .staged),
            NSControl.StateValue.off.rawValue
        )
        XCTAssertEqual(
            model.masterCheckboxState(forChanges: [unstagedOnly], in: .unstaged),
            NSControl.StateValue.off.rawValue
        )
    }

    func testDiffRequestsOrderStagedSelectionsFirst() {
        let model = PBStagingListViewModel()
        let staged = file("staged.txt", staged: true, unstaged: false)
        let unstaged = file("unstaged.txt")

        let fromTables = model.diffRequests(forStagedSelection: [staged], unstagedSelection: [unstaged])
        XCTAssertEqual(fromTables.map(\.file.path), ["staged.txt", "unstaged.txt"])
        XCTAssertEqual(fromTables.map(\.staged), [true, false])

        let rows = model.flattenedRows(fromChanges: [staged, unstaged])
        // rows: [staged header, staged.txt, unstaged header, unstaged.txt]
        let requests = model.diffRequests(
            for: rows,
            selectedIndexes: IndexSet([0, 1, 3])
        )
        XCTAssertEqual(requests.map(\.file.path), ["staged.txt", "unstaged.txt"])
        XCTAssertEqual(requests.map(\.staged), [true, false])
    }

    func testSectionedDragPayloadUsesStablePathsAndSourceSections() {
        let model = PBStagingListViewModel()
        let staged = file("staged.txt", staged: true, unstaged: false)
        let partial = file("partial.txt", staged: true, unstaged: true)
        let unstaged = file("unstaged.txt")
        let rows = model.flattenedRows(fromChanges: [staged, partial, unstaged])
        let partialRows = rows.indices.filter { rows[$0].file?.path == "partial.txt" }
        XCTAssertEqual(partialRows.count, 2)

        let payload = model.sectionedDragPayload(for: rows, selectedIndexes: IndexSet(partialRows))
        XCTAssertEqual(payload.compactMap { $0["path"] as? String }, ["partial.txt", "partial.txt"])
        XCTAssertEqual(payload.compactMap { $0["sourceSection"] as? Int }, [0, 1])

        XCTAssertEqual(
            model.resolvedDropFiles(
                fromPropertyList: [payload[0]],
                rows: rows,
                destinationSection: .staged
            )?.map(\.path),
            [],
            "dragging the staged side back to Staged cannot stage the remaining worktree side"
        )
        XCTAssertEqual(
            model.resolvedDropFiles(
                fromPropertyList: [payload[1]],
                rows: rows,
                destinationSection: .staged
            )?.map(\.path),
            ["partial.txt"]
        )
    }

    func testSectionedDropResolutionRejectsMalformedAndFiltersMixedStaleDuplicateEntries() {
        let model = PBStagingListViewModel()
        let staged = file("staged.txt", staged: true, unstaged: false)
        let unstaged = file("unstaged.txt")
        let rows = model.flattenedRows(fromChanges: [staged, unstaged])
        let mixed: [[String: Any]] = [
            ["path": "staged.txt", "sourceSection": PBStagingListSection.staged.rawValue],
            ["path": "unstaged.txt", "sourceSection": PBStagingListSection.unstaged.rawValue],
            ["path": "unstaged.txt", "sourceSection": PBStagingListSection.unstaged.rawValue],
            ["path": "stale.txt", "sourceSection": PBStagingListSection.unstaged.rawValue],
        ]

        XCTAssertEqual(
            model.resolvedDropFiles(
                fromPropertyList: mixed,
                rows: rows,
                destinationSection: .staged
            )?.map(\.path),
            ["unstaged.txt"]
        )
        XCTAssertEqual(
            model.resolvedDropFiles(
                fromPropertyList: mixed,
                rows: rows,
                destinationSection: .unstaged
            )?.map(\.path),
            ["staged.txt"]
        )
        XCTAssertEqual(
            model.resolvedDropFiles(fromPropertyList: [], rows: rows, destinationSection: .staged),
            []
        )

        let malformed: [Any] = [
            [0, 1],
            [["path": "unstaged.txt"]],
            [["path": "unstaged.txt", "sourceSection": "unstaged"]],
            [["path": "unstaged.txt", "sourceSection": 1, "extra": true]],
            [["path": "", "sourceSection": 1]],
        ]
        for propertyList in malformed {
            XCTAssertNil(model.resolvedDropFiles(
                fromPropertyList: propertyList,
                rows: rows,
                destinationSection: .staged
            ))
        }
    }
}
