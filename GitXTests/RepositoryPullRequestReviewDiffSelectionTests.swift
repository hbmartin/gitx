import ForgeKit
import XCTest

final class RepositoryPullRequestReviewDiffSelectionTests: XCTestCase {
    private let patch = """
    diff --git a/Sources/File.swift b/Sources/File.swift
    index 1111111..2222222 100644
    --- a/Sources/File.swift
    +++ b/Sources/File.swift
    @@ -8,4 +8,5 @@
     before
    -let old = true
    +let new = true
    +let second = true
     after
     tail
    """

    func testMapsExactSingleAndSameSideRangeToProviderNeutralAnchors() throws {
        let single = try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: patch,
            selectedText: "+let new = true"
        )
        XCTAssertEqual(single.anchor.path, try ForgeFilePath("Sources/File.swift"))
        XCTAssertEqual(single.anchor.side, .right)
        XCTAssertNil(single.anchor.startLine)
        XCTAssertEqual(single.anchor.line, 9)
        XCTAssertEqual(single.contextLines, ["let new = true"])
        XCTAssertFalse(single.isTruncated)

        let range = try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: patch,
            selectedText: "+let new = true\n+let second = true\n"
        )
        XCTAssertEqual(range.anchor.startSide, .right)
        XCTAssertEqual(range.anchor.startLine, 9)
        XCTAssertEqual(range.anchor.line, 10)
        XCTAssertEqual(range.contextLines, ["let new = true", "let second = true"])
    }

    func testMapsDeletedLineToLeftSideAndPreservesOriginalCoordinates() throws {
        let result = try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: patch,
            selectedText: "-let old = true"
        )
        XCTAssertEqual(result.anchor.side, .left)
        XCTAssertEqual(result.anchor.originalLine, 9)
        XCTAssertEqual(result.anchor.line, 9)
    }

    func testRejectsEmptyMissingMixedSideAndDuplicateSelectionsWithoutGuessing() throws {
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: patch,
            selectedText: ""
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffSelectionError, .emptySelection)
        }
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: patch,
            selectedText: "+missing"
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffSelectionError, .unavailableSelection)
        }
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: patch,
            selectedText: "-let old = true\n+let new = true"
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffSelectionError, .mixedDiffSides)
        }
        let duplicate = patch + "\n" + patch.replacingOccurrences(of: "File.swift", with: "Other.swift")
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: duplicate,
            selectedText: "+let new = true"
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffSelectionError, .ambiguousSelection)
        }
    }

    func testExactRenderedRangeDisambiguatesRepeatedDiffText() throws {
        let repeated = patch + "\n" + patch.replacingOccurrences(of: "File.swift", with: "Other.swift")
        let source = repeated as NSString
        let first = source.range(of: "+let new = true")
        let second = source.range(
            of: "+let new = true",
            options: [],
            range: NSRange(location: NSMaxRange(first), length: source.length - NSMaxRange(first))
        )

        let result = try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: repeated,
            renderedText: repeated,
            selectedRange: second
        )

        XCTAssertEqual(result.anchor.path, try ForgeFilePath("Sources/Other.swift"))
        XCTAssertEqual(result.anchor.side, .right)
        XCTAssertEqual(result.anchor.line, 9)
        XCTAssertEqual(result.contextLines, ["let new = true"])
    }

    func testRejectsNoncontiguousSameSideLinesAcrossHunks() throws {
        let separatedHunks = """
        diff --git a/Sources/File.swift b/Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -1 +1 @@
         first
        @@ -10 +10 @@
         second
        """

        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: separatedHunks,
            selectedText: " first\n second"
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffSelectionError, .unavailableSelection)
        }
    }

    func testSelectionAndAnchorRangeCannotCrossCompletedHunkHeader() throws {
        let adjacentHunks = """
        diff --git a/Sources/File.swift b/Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -1 +1 @@
         first
        @@ -2 +2 @@
         second
        """

        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: adjacentHunks,
            selectedText: " first\n second"
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffSelectionError, .unavailableSelection)
        }
        let range = try ForgeReviewAnchor(
            path: ForgeFilePath("Sources/File.swift"),
            subject: .line,
            side: .right,
            startSide: .right,
            startLine: 1,
            line: 2
        )
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
            patch: adjacentHunks,
            renderedText: adjacentHunks,
            anchor: range
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffAnchorError, .unavailableAnchor)
        }
    }

    func testSelectionAndAnchorCannotCrossRepeatedFileSections() throws {
        let repeatedFile = """
        diff --git a/Sources/File.swift b/Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -1 +1 @@
         first
        diff --git a/Sources/File.swift b/Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -2 +2 @@
         second
        """

        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: repeatedFile,
            selectedText: " first\n second"
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffSelectionError, .unavailableSelection)
        }
        let range = try ForgeReviewAnchor(
            path: ForgeFilePath("Sources/File.swift"),
            subject: .line,
            side: .right,
            startSide: .right,
            startLine: 1,
            line: 2
        )
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
            patch: repeatedFile,
            renderedText: repeatedFile,
            anchor: range
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffAnchorError, .unavailableAnchor)
        }
    }

    func testDoesNotInferTruncationFromOrdinaryHunkEdgesAndRejectsMalformedDiff() throws {
        let edge = try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: patch,
            selectedText: " before"
        )
        XCTAssertFalse(edge.isTruncated)
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: "not a diff",
            selectedText: "+line"
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffSelectionError, .malformedDiff)
        }
        XCTAssertTrue(RepositoryPullRequestReviewDiffSelectionError.allDescriptionsArePresent)
    }

    func testRejectsHunkHeaderWithoutClosingDelimiter() throws {
        let malformed = """
        diff --git a/Sources/File.swift b/Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -1 +1 invalid
         line
        """
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: malformed,
            selectedText: " line"
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffSelectionError, .malformedDiff)
        }
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
            patch: malformed,
            renderedText: malformed,
            anchor: ForgeReviewAnchor(
                path: ForgeFilePath("Sources/File.swift"),
                subject: .line,
                side: .right,
                line: 1
            )
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffAnchorError, .unavailableAnchor)
        }
    }

    func testMalformedHalfQuotedPathsFailClosed() {
        let malformedPaths = [
            "--- \"a/Sources/File.swift\n+++ \"b/Sources/File.swift",
            "--- a/Sources/File.swift\"\n+++ b/Sources/File.swift\"",
            "diff --git \"a/Sources/File.swift b/Sources/File.swift\n"
                + "--- a/Sources/File.swift\n+++ b/Sources/File.swift",
            "diff --git a/Sources/File.swift\" b/Sources/File.swift\n"
                + "--- a/Sources/File.swift\n+++ b/Sources/File.swift",
        ]
        for headers in malformedPaths {
            let malformed = """
            \(headers)
            @@ -1 +1 @@
             line
            """
            XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
                patch: malformed,
                selectedText: " line"
            ))
        }
    }

    func testRejectsOverfullAndUnderfullHunkBodies() throws {
        let overfull = """
        diff --git a/Sources/File.swift b/Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -1 +1 @@
         first
         extra
        """
        let underfull = """
        diff --git a/Sources/File.swift b/Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -1,2 +1,2 @@
         first
        """

        for malformed in [overfull, underfull] {
            XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
                patch: malformed,
                selectedText: " first"
            )) {
                XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffSelectionError, .malformedDiff)
            }
        }
    }

    func testAcceptsZeroCountNewAndDeletedFileHunks() throws {
        let newFile = """
        diff --git a/Sources/New.swift b/Sources/New.swift
        new file mode 100644
        --- /dev/null
        +++ b/Sources/New.swift
        @@ -0,0 +1,2 @@
        +first
        +second
        """
        let added = try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: newFile,
            selectedText: "+first\n+second"
        )
        XCTAssertEqual(added.anchor.path, try ForgeFilePath("Sources/New.swift"))
        XCTAssertEqual(added.anchor.startLine, 1)
        XCTAssertEqual(added.anchor.line, 2)
        XCTAssertEqual(added.anchor.side, .right)

        let deletedFile = """
        diff --git a/Sources/Old.swift b/Sources/Old.swift
        deleted file mode 100644
        --- a/Sources/Old.swift
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -first
        -second
        """
        let removed = try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: deletedFile,
            selectedText: "-second"
        )
        XCTAssertEqual(removed.anchor.path, try ForgeFilePath("Sources/Old.swift"))
        XCTAssertEqual(removed.anchor.originalLine, 2)
        XCTAssertEqual(removed.anchor.side, .left)
    }

    func testDecodesGitQuotedUnicodePathsBeforeValidatingTheAnchor() throws {
        let quotedPathPatch = """
        diff --git "a/Sources/\\303\\274.swift" "b/Sources/\\303\\274.swift"
        --- "a/Sources/\\303\\274.swift"
        +++ "b/Sources/\\303\\274.swift"
        @@ -1 +1 @@
        -old
        +new
        """
        let selection = try RepositoryPullRequestReviewDiffSelectionPolicy.selection(
            patch: quotedPathPatch,
            selectedText: "+new"
        )
        XCTAssertEqual(selection.anchor.path, try ForgeFilePath("Sources/ü.swift"))
    }

    func testPlacesServerLineRangeOnExactNativeRenderedDiffRanges() throws {
        let renderedText = """
        Changes
        ▾ Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -8,4 +8,5 @@
         before
        -let old = true
        +let new = true
        +let second = true
         after
         tail
        """
        let anchor = try ForgeReviewAnchor(
            path: ForgeFilePath("Sources/File.swift"),
            subject: .line,
            side: .right,
            startSide: .right,
            startLine: 9,
            line: 10
        )

        let placement = try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
            patch: patch,
            renderedText: renderedText,
            anchor: anchor
        )

        XCTAssertEqual(placement.anchor, anchor)
        XCTAssertEqual(
            placement.characterRanges.map { (renderedText as NSString).substring(with: $0) },
            ["+let new = true", "+let second = true"]
        )
    }

    func testPlacesLeftAndFileAnchorsWithoutRewritingServerCoordinates() throws {
        let renderedText = """
        Changes
        ▾ Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -8,4 +8,5 @@
         before
        -let old = true
        +let new = true
        +let second = true
         after
         tail
        """
        let path = try ForgeFilePath("Sources/File.swift")
        let leftAnchor = ForgeReviewAnchor(
            path: path,
            subject: .line,
            side: .left,
            line: 109,
            originalLine: 9
        )
        let fileAnchor = ForgeReviewAnchor(path: path, subject: .file)

        let leftPlacement = try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
            patch: patch,
            renderedText: renderedText,
            anchor: leftAnchor
        )
        let filePlacement = try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
            patch: patch,
            renderedText: renderedText,
            anchor: fileAnchor
        )

        XCTAssertEqual(leftPlacement.anchor, leftAnchor)
        XCTAssertEqual(
            try (renderedText as NSString).substring(with: XCTUnwrap(leftPlacement.characterRanges.first)),
            "-let old = true"
        )
        XCTAssertEqual(
            try (renderedText as NSString).substring(with: XCTUnwrap(filePlacement.characterRanges.first)),
            "▾ Sources/File.swift"
        )
    }

    func testPlacesBinaryFileAnchorFromDiffHeaderWithoutLineHunks() throws {
        let binaryPatch = """
        diff --git a/Assets/Icon.png b/Assets/Icon.png
        index 1111111..2222222 100644
        Binary files a/Assets/Icon.png and b/Assets/Icon.png differ
        """
        let renderedText = """
        Changes
        ▾ Assets/Icon.png
        Binary files a/Assets/Icon.png and b/Assets/Icon.png differ
        """
        let anchor = try ForgeReviewAnchor(
            path: ForgeFilePath("Assets/Icon.png"),
            subject: .file
        )

        let placement = try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
            patch: binaryPatch,
            renderedText: renderedText,
            anchor: anchor
        )

        XCTAssertEqual(
            try (renderedText as NSString).substring(with: XCTUnwrap(placement.characterRanges.first)),
            "▾ Assets/Icon.png"
        )
    }

    func testAnchorPlacementFailsClosedWhenRenderedRangeIsMissingOrAmbiguous() throws {
        let anchor = try ForgeReviewAnchor(
            path: ForgeFilePath("Sources/File.swift"),
            subject: .line,
            side: .right,
            startSide: .right,
            startLine: 9,
            line: 10
        )
        let oneLineRenderedDiff = """
        ▾ Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -8,1 +8,2 @@
         before
        +let new = true
        """
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
            patch: patch,
            renderedText: oneLineRenderedDiff,
            anchor: anchor
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffAnchorError, .unavailableAnchor)
        }

        let duplicateRenderedDiff = patch + "\n" + patch
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
            patch: patch,
            renderedText: duplicateRenderedDiff,
            anchor: anchor
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffAnchorError, .ambiguousAnchor)
        }

        let mixedSideAnchor = try ForgeReviewAnchor(
            path: ForgeFilePath("Sources/File.swift"),
            subject: .line,
            side: .right,
            startSide: .left,
            startLine: 9,
            line: 10
        )
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
            patch: patch,
            renderedText: patch,
            anchor: mixedSideAnchor
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffAnchorError, .unavailableAnchor)
        }

        let originalOnlyRightAnchor = try ForgeReviewAnchor(
            path: ForgeFilePath("Sources/File.swift"),
            subject: .line,
            side: .right,
            originalLine: 9
        )
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
            patch: patch,
            renderedText: patch,
            anchor: originalOnlyRightAnchor
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffAnchorError, .unavailableAnchor)
        }
    }

    func testFileAnchorRejectsEveryCoordinateField() throws {
        let path = try ForgeFilePath("Sources/File.swift")
        let invalidAnchors = [
            ForgeReviewAnchor(path: path, subject: .file, side: .right),
            ForgeReviewAnchor(path: path, subject: .file, startSide: .right),
            ForgeReviewAnchor(path: path, subject: .file, startLine: 9),
            ForgeReviewAnchor(path: path, subject: .file, line: 9),
            ForgeReviewAnchor(path: path, subject: .file, originalStartLine: 9),
            ForgeReviewAnchor(path: path, subject: .file, originalLine: 9),
        ]

        for anchor in invalidAnchors {
            XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
                patch: patch,
                renderedText: patch,
                anchor: anchor
            )) {
                XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffAnchorError, .unavailableAnchor)
            }
        }
    }

    func testLineAnchorRequiresSideAndPairedRangeMetadata() throws {
        let path = try ForgeFilePath("Sources/File.swift")
        let invalidAnchors = [
            ForgeReviewAnchor(path: path, subject: .line, line: 9),
            ForgeReviewAnchor(path: path, subject: .line, side: .right, startLine: 9, line: 10),
            ForgeReviewAnchor(path: path, subject: .line, side: .right, startSide: .right, line: 10),
            ForgeReviewAnchor(
                path: path,
                subject: .line,
                side: .right,
                startSide: .left,
                startLine: 9,
                line: 10
            ),
            ForgeReviewAnchor(path: path, subject: .line, side: .right, line: 0),
            ForgeReviewAnchor(
                path: path,
                subject: .line,
                side: .right,
                startSide: .right,
                startLine: 10,
                line: 9
            ),
            ForgeReviewAnchor(path: path, subject: .line, side: .right),
        ]

        for anchor in invalidAnchors {
            XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
                patch: patch,
                renderedText: patch,
                anchor: anchor
            )) {
                XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffAnchorError, .unavailableAnchor)
            }
        }
    }

    func testAuthoritativePatchMustContainOneUniqueAnchor() throws {
        let anchor = try ForgeReviewAnchor(
            path: ForgeFilePath("Sources/File.swift"),
            subject: .line,
            side: .right,
            line: 9
        )
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
            patch: patch + "\n" + patch,
            renderedText: patch,
            anchor: anchor
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffAnchorError, .ambiguousAnchor)
        }
    }

    func testRenderedTextCannotManufactureAnchorAbsentFromAuthoritativePatch() throws {
        let anchor = try ForgeReviewAnchor(
            path: ForgeFilePath("Sources/File.swift"),
            subject: .line,
            side: .right,
            line: 9
        )
        let otherPatch = patch.replacingOccurrences(of: "Sources/File.swift", with: "Sources/Other.swift")
        XCTAssertThrowsError(try RepositoryPullRequestReviewDiffSelectionPolicy.anchorPlacement(
            patch: otherPatch,
            renderedText: patch,
            anchor: anchor
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewDiffAnchorError, .unavailableAnchor)
        }
    }

    func testEveryAnchorErrorHasLocalizedDescription() {
        let errors: [RepositoryPullRequestReviewDiffAnchorError] = [
            .unavailableAnchor,
            .ambiguousAnchor,
        ]
        XCTAssertTrue(errors.allSatisfy { !($0.errorDescription ?? "").isEmpty })
    }

    func testBuildsSuggestedChangeOnlyFromOneExactFenceAndCompleteServerContext() throws {
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
        let path = try ForgeFilePath("Sources/File.swift")
        let comment = try ForgeReviewComment(
            repository: repository,
            id: ForgeObjectID(forge: forge, value: "comment"),
            bodyMarkdown: "Please use:\n```suggestion\nlet final = true\nlet second = false\n```",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            author: .unavailable(.partialResponse),
            diffHunk: "@@ -8,4 +8,4 @@\n before\n-let old = true\n+let new = true\n let second = true\n after"
        )
        let anchor = ForgeReviewAnchor(
            path: path,
            subject: .line,
            side: .right,
            startSide: .right,
            startLine: 9,
            line: 10
        )
        let change = try XCTUnwrap(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: comment,
            anchor: anchor,
            pullRequest: ForgeItemNumber(42),
            displayedHead: ForgeCommitID(String(repeating: "a", count: 40))
        ))
        XCTAssertEqual(change.originalText, "let new = true\nlet second = true")
        XCTAssertEqual(change.replacementText, "let final = true\nlet second = false")
        XCTAssertEqual(change.path, path)
        XCTAssertFalse(change.isTruncated)
    }

    func testSuggestedChangeFailsClosedForAdjustedAmbiguousOrIncompleteContext() throws {
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
        let path = try ForgeFilePath("Sources/File.swift")
        let anchor = ForgeReviewAnchor(path: path, subject: .line, side: .right, line: 9)

        func comment(
            body: String,
            hunk: String = "@@ -9 +9 @@\n line",
            replyToID: ForgeObjectID? = nil,
            isMinimized: Bool = false
        ) throws -> ForgeReviewComment {
            try ForgeReviewComment(
                repository: repository,
                id: ForgeObjectID(forge: forge, value: UUID().uuidString),
                bodyMarkdown: body,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1),
                author: .unavailable(.partialResponse),
                replyToID: replyToID,
                isMinimized: isMinimized,
                diffHunk: hunk
            )
        }

        let adjusted = try comment(body: "```suggestion:-1+0\nreplacement\n```")
        let ambiguous = try comment(body: "```suggestion\none\n```\n```suggestion\ntwo\n```")
        let incomplete = try comment(body: "```suggestion\nreplacement\n```", hunk: "@@ -10 +10 @@\n line")
        let malformedHunk = try comment(
            body: "```suggestion\nreplacement\n```",
            hunk: "@@ -9 +9 @@\n line\n extra"
        )
        let missingDelimiter = try comment(
            body: "```suggestion\nreplacement\n```",
            hunk: "@@ -9 +9 invalid\n line"
        )
        let reply = try comment(
            body: "```suggestion\nreplacement\n```",
            replyToID: ForgeObjectID(forge: forge, value: "root")
        )
        let minimized = try comment(
            body: "```suggestion\nreplacement\n```",
            isMinimized: true
        )
        let indentedLiteral = try comment(
            body: "    ```suggestion\n    replacement\n    ```"
        )
        let nestedLiteral = try comment(
            body: "````markdown\n```suggestion\nreplacement\n```\n````"
        )
        let valid = try comment(body: "```suggestion\nreplacement\n```")
        let emptyReplacement = try comment(body: "```suggestion\n```")
        let crossHunk = try comment(
            body: "```suggestion\none\ntwo\n```",
            hunk: "@@ -1 +1 @@\n one\n@@ -2 +2 @@\n two"
        )
        let number = try ForgeItemNumber(42)
        let head = try ForgeCommitID(String(repeating: "a", count: 40))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: adjusted, anchor: anchor, pullRequest: number, displayedHead: head
        ))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: ambiguous, anchor: anchor, pullRequest: number, displayedHead: head
        ))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: incomplete, anchor: anchor, pullRequest: number, displayedHead: head
        ))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: malformedHunk, anchor: anchor, pullRequest: number, displayedHead: head
        ))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: missingDelimiter, anchor: anchor, pullRequest: number, displayedHead: head
        ))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: reply, anchor: anchor, pullRequest: number, displayedHead: head
        ))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: minimized, anchor: anchor, pullRequest: number, displayedHead: head
        ))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: indentedLiteral, anchor: anchor, pullRequest: number, displayedHead: head
        ))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: nestedLiteral, anchor: anchor, pullRequest: number, displayedHead: head
        ))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: valid,
            anchor: ForgeReviewAnchor(path: path, subject: .file),
            pullRequest: number,
            displayedHead: head
        ))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: valid,
            anchor: ForgeReviewAnchor(path: path, subject: .line, side: .left, originalLine: 9),
            pullRequest: number,
            displayedHead: head
        ))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: valid,
            anchor: ForgeReviewAnchor(path: path, subject: .line, line: 9),
            pullRequest: number,
            displayedHead: head
        ))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: valid,
            anchor: ForgeReviewAnchor(
                path: path,
                subject: .line,
                side: .right,
                startLine: 9,
                line: 9
            ),
            pullRequest: number,
            displayedHead: head
        ))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: valid,
            anchor: ForgeReviewAnchor(
                path: path,
                subject: .line,
                side: .right,
                startSide: .right,
                line: 9
            ),
            pullRequest: number,
            displayedHead: head
        ))
        XCTAssertNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: crossHunk,
            anchor: ForgeReviewAnchor(
                path: path,
                subject: .line,
                side: .right,
                startSide: .right,
                startLine: 1,
                line: 2
            ),
            pullRequest: number,
            displayedHead: head
        ))
        XCTAssertNotNil(RepositoryPullRequestSuggestedChangePolicy.change(
            comment: emptyReplacement,
            anchor: anchor,
            pullRequest: number,
            displayedHead: head
        ))
    }
}

private extension RepositoryPullRequestReviewDiffSelectionError {
    static var allDescriptionsArePresent: Bool {
        let values: [Self] = [
            .emptySelection, .malformedDiff, .unavailableSelection,
            .ambiguousSelection, .mixedDiffSides,
        ]
        return values.allSatisfy { !($0.errorDescription ?? "").isEmpty }
    }
}
