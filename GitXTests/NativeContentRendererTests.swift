import AppKit
import XCTest

final class NativeContentRendererTests: XCTestCase {
    private var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
    }

    func testTextRendererBuildsSourceBlameAndHistoryResults() {
        let renderer = PBNativeTextRenderer(
            baseAttributes: baseAttributes,
            titleAttributes: titleAttributes
        )
        let source = PBNativeContentSection(dictionary: [
            PBNativeSectionPathKey: "Example.swift",
            PBNativeSectionTextKey: "let value = 42\n",
        ])
        let sourceResult = renderer.renderSourceSections([source])
        XCTAssertTrue(sourceResult.attributedString.string.contains("Example.swift"))
        XCTAssertTrue(sourceResult.attributedString.string.contains("let value = 42"))
        XCTAssertTrue(sourceResult.linkPayloads.isEmpty)

        let sha = "0123456789abcdef0123456789abcdef01234567"
        let blame = PBNativeContentSection(dictionary: [
            PBNativeSectionPathKey: "Example.swift",
            PBNativeSectionTextKey: "\(sha) 1 1 1\nauthor An Extremely Long Author Name\nsummary First\n\tlet first = 1\n\(sha) 2 2\n\tlet second = 2\n",
        ])
        let blameResult = renderer.renderBlameSections([blame])
        XCTAssertTrue(blameResult.attributedString.string.contains("01234567"))
        XCTAssertTrue(blameResult.attributedString.string.contains("An Extremely Long…"))
        XCTAssertTrue(blameResult.attributedString.string.contains("let second = 2"))

        let history = PBNativeContentSection(dictionary: [
            PBNativeSectionTitleKey: "History",
            PBNativeSectionEntriesKey: [[
                "subject": "Subject",
                "author": "Ada",
                "date": "Today",
                "sha": sha,
            ]],
        ])
        let historyResult = renderer.renderHistorySections([history])
        XCTAssertTrue(historyResult.attributedString.string.contains("Ada  •  Today  •  0123456789ab"))
        XCTAssertEqual(historyResult.linkPayloads.values.first?["type"] as? String, "commit")
        XCTAssertEqual(historyResult.linkPayloads.values.first?["sha"] as? String, sha)
    }

    func testDiffRendererBuildsTypedActionsAndCollapsedResults() {
        let parser = PBDiffDocumentParser()
        let renderer = PBNativeDiffRenderer(
            baseAttributes: baseAttributes,
            titleAttributes: titleAttributes,
            parser: parser
        )
        let diff = """
        diff --git a/file.swift b/file.swift
        index 1111111..2222222 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,2 +1,2 @@
        -let old = 1
        +let new = 2
         tail

        """
        let section = PBNativeContentSection(dictionary: [
            PBNativeSectionTitleKey: "Changes",
            PBNativeSectionTextKey: diff,
            PBNativeSectionContextKey: "unstaged",
        ])

        let result = renderer.renderSections(
            [section],
            collapsedFiles: [],
            expandedImages: [],
            imageDataProvider: nil
        )

        XCTAssertTrue(result.attributedString.string.contains("Stage hunk"))
        XCTAssertTrue(result.attributedString.string.contains("Discard line"))
        XCTAssertTrue(result.linkPayloads.values.contains { $0["action"] as? String == "stage" })
        XCTAssertTrue(result.linkPayloads.values.contains { $0["selectedIndexes"] is IndexSet })

        let collapsed = renderer.renderSections(
            [section],
            collapsedFiles: ["0:file.swift"],
            expandedImages: [],
            imageDataProvider: nil
        )
        XCTAssertTrue(collapsed.attributedString.string.contains("▸ file.swift"))
        XCTAssertFalse(collapsed.attributedString.string.contains("let new = 2"))
    }

    func testDiffRendererHandlesEmptyAndReadOnlySections() {
        let renderer = PBNativeDiffRenderer(
            baseAttributes: baseAttributes,
            titleAttributes: titleAttributes,
            parser: PBDiffDocumentParser()
        )
        let empty = PBNativeContentSection(dictionary: [PBNativeSectionTitleKey: "Empty"])
        let readOnly = PBNativeContentSection(dictionary: [
            PBNativeSectionTextKey: "diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new\n",
        ])

        let result = renderer.renderSections(
            [empty, readOnly],
            collapsedFiles: [],
            expandedImages: [],
            imageDataProvider: nil
        )

        XCTAssertTrue(result.attributedString.string.contains("There are no differences."))
        XCTAssertTrue(result.attributedString.string.contains("+new"))
        XCTAssertFalse(result.attributedString.string.contains("Stage line"))
    }
}
