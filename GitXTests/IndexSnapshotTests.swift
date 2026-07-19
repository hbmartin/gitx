import XCTest

final class IndexSnapshotTests: XCTestCase {
    private let parser = PBIndexStatusParser()
    private let reducer = PBIndexSnapshotReducer()

    func testParserDecodesTrackedStatusesAndUnicodePaths() {
        let output = ":100644 100644 abc def M\0folder/spaced ünicode.txt\0" +
            ":100644 000000 abc 0000000000000000000000000000000000000000 D\0deleted.txt\0"
        var error: NSError?

        let entries = parser.parseTrackedData(output.data(using: .utf8), error: &error)

        XCTAssertNil(error)
        XCTAssertEqual(entries?["folder/spaced ünicode.txt"]?.status, 1)
        XCTAssertEqual(entries?["folder/spaced ünicode.txt"]?.commitBlobMode, "100644")
        XCTAssertEqual(entries?["folder/spaced ünicode.txt"]?.commitBlobSHA, "abc")
        XCTAssertEqual(entries?["deleted.txt"]?.status, 2)
    }

    func testParserHandlesEmptyUnterminatedAndMalformedData() {
        XCTAssertEqual(parser.parseUntrackedData(nil, error: nil)?.count, 0)
        XCTAssertEqual(parser.parseUntrackedData(Data(), error: nil)?.count, 0)
        XCTAssertEqual(
            parser.parseUntrackedData("one.txt\0two ü.txt".data(using: .utf8), error: nil)?.keys.sorted(),
            ["one.txt", "two ü.txt"]
        )

        var error: NSError?
        XCTAssertNil(parser.parseTrackedData(Data([0xFF]), error: &error))
        XCTAssertNotNil(error)
        error = nil
        XCTAssertNil(parser.parseTrackedData(":100644 100644 abc def M\0".data(using: .utf8), error: &error))
        XCTAssertNotNil(error)
    }

    func testParserClassifiesUnmergedEntriesAsModifiedNotNew() {
        // Unmerged (conflicted) entries carry mode :000000 like additions; they must be MODIFIED, not NEW,
        // so conflicted files don't display as brand-new untracked files.
        let zero = String(repeating: "0", count: 40)
        let output = ":000000 000000 \(zero) \(zero) U\0conflict.txt\0"
        let entries = parser.parseTrackedData(output.data(using: .utf8), error: nil)
        XCTAssertEqual(entries?["conflict.txt"]?.status, 1)
    }

    func testParserToleratesNonUTF8PathInsteadOfAbortingEntireParse() {
        // A single non-UTF-8 path must not fail the whole-payload decode (which froze the entire file list);
        // it survives with a lossy path and the record still parses.
        var data = Data(":100644 100644 abc def M\0".utf8)
        data.append(0xFF)
        data.append(0x00)
        let entries = parser.parseTrackedData(data, error: nil)
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.values.first?.status, 1)
    }

    func testReducerPreservesStagedDeletionWhenPathAlsoUntracked() {
        // `git rm --cached foo` (kept on disk) reports foo as both staged-deleted and untracked; the
        // untracked entry must not erase the staged deletion, or the user cannot see or unstage it.
        let zero = String(repeating: "0", count: 40)
        let stagedOutput = ":100644 000000 abc \(zero) D\0foo.txt\0"
        let staged = parser.parseTrackedData(stagedOutput.data(using: .utf8), error: nil)
        let untracked = parser.parseUntrackedData("foo.txt\0".data(using: .utf8), error: nil)

        let result = reducer.reducePrevious([], staged: staged, unstaged: [:], untracked: untracked)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, "foo.txt")
        XCTAssertEqual(result[0].status, 2)
        XCTAssertTrue(result[0].hasStagedChanges)
    }

    func testReducerPreservesStagedMetadataForPartialAddition() {
        let stagedOutput = ":000000 100644 0000000000000000000000000000000000000000 stagedsha A\0new.txt\0"
        let unstagedOutput = ":100644 100644 stagedsha workingsha M\0new.txt\0"
        let staged = parser.parseTrackedData(stagedOutput.data(using: .utf8), error: nil)
        let unstaged = parser.parseTrackedData(unstagedOutput.data(using: .utf8), error: nil)

        let result = reducer.reducePrevious([], staged: staged, unstaged: unstaged, untracked: [:])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, "new.txt")
        XCTAssertEqual(result[0].status, 0)
        XCTAssertEqual(result[0].commitBlobMode, "000000")
        XCTAssertEqual(result[0].commitBlobSHA, "0000000000000000000000000000000000000000")
        XCTAssertTrue(result[0].hasStagedChanges)
        XCTAssertTrue(result[0].hasUnstagedChanges)
    }

    func testReducerRemovesStalePathsAndPreservesSnapshotAfterCommandFailure() {
        let previous = PBIndexFileSnapshot(
            path: "tracked.txt",
            status: 1,
            commitBlobMode: "100644",
            commitBlobSHA: "abc",
            hasStagedChanges: true,
            hasUnstagedChanges: true
        )

        let preserved = reducer.reducePrevious([previous], staged: nil, unstaged: nil, untracked: nil)
        XCTAssertEqual(preserved.count, 1)
        XCTAssertTrue(preserved[0].hasStagedChanges)
        XCTAssertTrue(preserved[0].hasUnstagedChanges)

        let removed = reducer.reducePrevious([previous], staged: [:], unstaged: [:], untracked: [:])
        XCTAssertTrue(removed.isEmpty)
    }

    func testSuccessfulRefreshRemovesIgnoredUntrackedPathAndRetainsTrackedChange() {
        let ignored = PBIndexFileSnapshot(
            path: "ignored ü.txt",
            status: 0,
            commitBlobMode: nil,
            commitBlobSHA: nil,
            hasStagedChanges: false,
            hasUnstagedChanges: true
        )
        let tracked = PBIndexFileSnapshot(
            path: "tracked.txt",
            status: 1,
            commitBlobMode: "100644",
            commitBlobSHA: "old",
            hasStagedChanges: false,
            hasUnstagedChanges: true
        )
        let refreshedTracked = parser.parseTrackedData(
            ":100644 100644 old new M\0tracked.txt\0".data(using: .utf8),
            error: nil
        )

        let result = reducer.reducePrevious(
            [ignored, tracked],
            staged: [:],
            unstaged: refreshedTracked,
            untracked: [:]
        )

        XCTAssertEqual(result.map(\.path), ["tracked.txt"])
        XCTAssertFalse(result[0].hasStagedChanges)
        XCTAssertTrue(result[0].hasUnstagedChanges)
        XCTAssertEqual(result[0].commitBlobSHA, "old")
    }

    func testReducerCombinesStagedUnstagedAndUntrackedEntries() {
        let staged = parser.parseTrackedData(
            ":100644 100644 old staged M\0partial.txt\0".data(using: .utf8),
            error: nil
        )
        let unstaged = parser.parseTrackedData(
            ":100644 100644 staged working M\0partial.txt\0".data(using: .utf8),
            error: nil
        )
        let untracked = parser.parseUntrackedData("new ü.txt\0".data(using: .utf8), error: nil)

        let result = reducer.reducePrevious([], staged: staged, unstaged: unstaged, untracked: untracked)
        let byPath = Dictionary(uniqueKeysWithValues: result.map { ($0.path, $0) })

        XCTAssertEqual(byPath["partial.txt"]?.commitBlobSHA, "old")
        XCTAssertTrue(byPath["partial.txt"]?.hasStagedChanges == true)
        XCTAssertTrue(byPath["partial.txt"]?.hasUnstagedChanges == true)
        XCTAssertEqual(byPath["new ü.txt"]?.status, 0)
        XCTAssertFalse(byPath["new ü.txt"]?.hasStagedChanges == true)
        XCTAssertTrue(byPath["new ü.txt"]?.hasUnstagedChanges == true)
    }
}
