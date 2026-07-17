import XCTest

final class NativeContentModelsTests: XCTestCase {
    private let parser = PBDiffDocumentParser()
    private let patchBuilder = PBPartialPatchBuilder()

    func testSectionAdapterPreservesFallbacksAndTypedValues() {
        let pathOnly = PBNativeContentSection(dictionary: [
            PBNativeSectionPathKey: "Folder/ünicode.swift",
        ])

        XCTAssertEqual(pathOnly.title, "")
        XCTAssertEqual(pathOnly.text, "")
        XCTAssertEqual(pathOnly.path, "Folder/ünicode.swift")
        XCTAssertEqual(pathOnly.displayTitle, "Folder/ünicode.swift")
        XCTAssertEqual(pathOnly.highlightingPath, "Folder/ünicode.swift")
        XCTAssertEqual(pathOnly.context, "readOnly")
        XCTAssertTrue(pathOnly.entries.isEmpty)
        XCTAssertTrue(pathOnly.imageSource.isEmpty)

        let titleOnly = PBNativeContentSection(dictionary: [
            PBNativeSectionTitleKey: "Fallback title",
            PBNativeSectionTextKey: "text",
            PBNativeSectionContextKey: "staged",
            PBNativeSectionEntriesKey: [["sha": "abc"]],
            PBNativeSectionImageSourceKey: ["workingTree": true],
        ])
        XCTAssertEqual(titleOnly.displayTitle, "Fallback title")
        XCTAssertEqual(titleOnly.highlightingPath, "Fallback title")
        XCTAssertEqual(titleOnly.text, "text")
        XCTAssertEqual(titleOnly.context, "staged")
        XCTAssertEqual(titleOnly.entries.first?["sha"] as? String, "abc")
        XCTAssertEqual(titleOnly.imageSource["workingTree"] as? Bool, true)
    }

    func testParserSplitsFilesHunksHeadersAndChangedBlocks() {
        let diff = """
        diff --git a/old name.swift b/new name.swift
        similarity index 90%
        rename from old name.swift
        rename to new name.swift
        index 1111111..2222222 100644
        --- a/old name.swift
        +++ b/new name.swift
        @@ -1,2 +1,2 @@ declaration
        -old
        +new
         tail
        @@ -8 +8 @@
        -before
        +after
        diff --git a/image.png b/copied image.png
        copy from image.png
        copy to copied image.png
        """

        let document = parser.parseText(diff, fallbackPath: "fallback.txt")

        XCTAssertEqual(document.fallbackPath, "fallback.txt")
        XCTAssertEqual(document.filesByStartIndex[0]?.path, "new name.swift")
        XCTAssertEqual(document.filesByStartIndex[14]?.path, "copied image.png")
        let firstHunk = document.hunksByStartIndex[7]
        XCTAssertEqual(firstHunk?.startIndex, 7)
        XCTAssertEqual(firstHunk?.endIndex, 11)
        XCTAssertEqual(firstHunk?.fileHeader.count, 4)
        XCTAssertTrue(firstHunk?.patch.hasSuffix(" tail\n") == true)
        XCTAssertEqual(firstHunk?.blockIndexesStarting(at: 1), IndexSet(integersIn: 1 ... 2))
        XCTAssertTrue(firstHunk?.blockIndexesStarting(at: 2).isEmpty == true)
    }

    func testParserNormalizesQuotedDeletedAndMalformedPaths() {
        let quoted = ["diff --git a/old.txt b/new.txt", "+++ \"b/quoted\\\"name.txt\""]
        XCTAssertEqual(parser.pathForDiffHeader(at: 0, lines: quoted), "quoted\"name.txt")

        let deleted = ["diff --git a/deleted.txt b/deleted.txt", "--- a/deleted.txt", "+++ /dev/null"]
        XCTAssertEqual(parser.pathForDiffHeader(at: 0, lines: deleted), "deleted.txt")

        XCTAssertEqual(parser.pathForDiffHeader(at: 0, lines: ["not a diff header"]), "not a diff header")
        XCTAssertEqual(parser.pathForDiffHeader(at: 2, lines: ["short"]), "")
    }

    func testPatchBuilderSelectsForwardAndReverseChanges() {
        let fileHeader = ["diff --git a/file.txt b/file.txt", "--- a/file.txt", "+++ b/file.txt"]
        let hunk = ["@@ -1,3 +1,3 @@ label", " context", "-old", "+new", " tail"]

        let forward = patchBuilder.patch(
            withFileHeader: fileHeader,
            hunkLines: hunk,
            selectedIndexes: IndexSet(integer: 3),
            reverse: false
        )
        XCTAssertEqual(
            forward,
            (fileHeader + ["@@ -1,3 +1,4 @@ label", " context", " old", "+new", " tail"]).joined(separator: "\n") + "\n"
        )

        let reverse = patchBuilder.patch(
            withFileHeader: fileHeader,
            hunkLines: hunk,
            selectedIndexes: IndexSet(integer: 2),
            reverse: true
        )
        XCTAssertEqual(
            reverse,
            (fileHeader + ["@@ -1,4 +1,3 @@ label", " context", "-old", " new", " tail"]).joined(separator: "\n") + "\n"
        )
    }

    func testPatchBuilderHandlesMarkersAndMalformedOrEmptySelections() {
        let hunk = ["@@ -1 +1 @@", "-old", "\\ No newline at end of file", "+new"]
        let selected = patchBuilder.patch(
            withFileHeader: [],
            hunkLines: hunk,
            selectedIndexes: IndexSet(integer: 1),
            reverse: false
        )
        XCTAssertEqual(selected, "@@ -1,1 +1,0 @@\n-old\n\\ No newline at end of file\n")

        XCTAssertNil(
            patchBuilder.patch(
                withFileHeader: [],
                hunkLines: ["malformed", "+line"],
                selectedIndexes: IndexSet(integer: 1),
                reverse: false
            )
        )
        XCTAssertNil(
            patchBuilder.patch(
                withFileHeader: [],
                hunkLines: ["@@ -1 +1 @@", "+line"],
                selectedIndexes: [],
                reverse: false
            )
        )
    }
}
