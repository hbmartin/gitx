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
}
