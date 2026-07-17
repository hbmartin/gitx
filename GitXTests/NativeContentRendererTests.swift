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
            PBNativeSectionDiffLayoutKey: 0,
        ])

        let result = renderer.renderSections(
            [section],
            collapsedFiles: [],
            expandedImages: [],
            imageDataProvider: nil
        )

        XCTAssertTrue(result.attributedString.string.contains("Stage hunk"))
        XCTAssertTrue(result.attributedString.string.contains("Discard line"))
        XCTAssertFalse(result.attributedString.string.contains("index 1111111..2222222 100644"))
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

    func testDiffRendererSupportsSideBySideAndSuppressedFiles() {
        let renderer = PBNativeDiffRenderer(
            baseAttributes: baseAttributes,
            titleAttributes: titleAttributes,
            parser: PBDiffDocumentParser()
        )
        let diff = """
        diff --git a/generated/output.swift b/generated/output.swift
        index 1111111..2222222 100644
        --- a/generated/output.swift
        +++ b/generated/output.swift
        @@ -1,2 +1,2 @@
        -let old = 1
        +let new = 2
         tail

        """
        let sideBySide = PBNativeContentSection(dictionary: [
            PBNativeSectionTextKey: diff,
            PBNativeSectionContextKey: "unstaged",
            PBNativeSectionDiffLayoutKey: 1,
        ])
        let sideBySideResult = renderer.renderSections(
            [sideBySide],
            collapsedFiles: [],
            expandedImages: [],
            imageDataProvider: nil
        )
        XCTAssertTrue(sideBySideResult.attributedString.string.contains("Before"))
        XCTAssertTrue(sideBySideResult.attributedString.string.contains("After"))
        XCTAssertTrue(sideBySideResult.attributedString.string.contains("Stage hunk"))
        XCTAssertFalse(sideBySideResult.attributedString.string.contains("index 1111111..2222222 100644"))

        let suppressed = PBNativeContentSection(dictionary: [
            PBNativeSectionTextKey: diff,
            PBNativeSectionContextKey: "unstaged",
            PBNativeSectionSuppressionPatternsKey: [#"^generated/"#],
        ])
        let suppressedResult = renderer.renderSections(
            [suppressed],
            collapsedFiles: [],
            expandedImages: [],
            imageDataProvider: nil
        )
        XCTAssertTrue(suppressedResult.attributedString.string.contains("Diff hidden by repository setting"))
        XCTAssertFalse(suppressedResult.attributedString.string.contains("let new = 2"))

        let revealedResult = renderer.renderSections(
            [suppressed],
            collapsedFiles: [],
            expandedImages: ["suppression:0:generated/output.swift"],
            imageDataProvider: nil
        )
        XCTAssertTrue(revealedResult.attributedString.string.contains("let new = 2"))
    }

    @MainActor
    func testSideBySideTruncatesLongSyntaxLinesAndRendersImagesOnMainThread() throws {
        let renderer = PBNativeDiffRenderer(
            baseAttributes: baseAttributes,
            titleAttributes: titleAttributes,
            parser: PBDiffDocumentParser()
        )
        let longValue = String(repeating: "value", count: 20)
        let textDiff = """
        diff --git a/Long.swift b/Long.swift
        --- a/Long.swift
        +++ b/Long.swift
        @@ -1 +1 @@
        -let old = \(longValue)
        +let new = \(longValue)
        \\ No newline at end of file

        """
        let sideBySide = PBNativeContentSection(dictionary: [
            PBNativeSectionTextKey: textDiff,
            PBNativeSectionContextKey: "readOnly",
            PBNativeSectionDiffLayoutKey: 1,
        ])
        let textResult = renderer.renderSections(
            [sideBySide],
            collapsedFiles: [],
            expandedImages: [],
            imageDataProvider: nil
        )
        XCTAssertTrue(textResult.attributedString.string.contains("…"))
        XCTAssertFalse(textResult.attributedString.string.contains(longValue))

        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let imageData = try XCTUnwrap(image.tiffRepresentation)
        let imageDiff = "diff --git a/image.png b/image.png\nBinary files a/image.png and b/image.png differ\n"
        let imageSection = PBNativeContentSection(dictionary: [PBNativeSectionTextKey: imageDiff])
        let imageResult = renderer.renderSections(
            [imageSection],
            collapsedFiles: [],
            expandedImages: ["0:image.png"],
            imageDataProvider: { _, _, _ in imageData }
        )
        XCTAssertTrue((0 ..< imageResult.attributedString.length).contains {
            imageResult.attributedString.attribute(.attachment, at: $0, effectiveRange: nil) != nil
        })
    }
}
