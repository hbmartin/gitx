import AppKit
import XCTest

/// Scheduled microbenchmarks for deterministic parsing and presentation policy.
/// Keep fixture creation outside each measured block and keep this class out of
/// correctness and sanitizer plans.
@MainActor
final class GitXPerformanceTests: XCTestCase {
    private func largeDiff(path: String, lineCount: Int) -> String {
        var diff = """
        diff --git a/\(path) b/\(path)
        --- a/\(path)
        +++ b/\(path)
        @@ -1,\(lineCount) +1,\(lineCount) @@

        """
        for index in 0 ..< lineCount {
            diff += "-let oldValue\(index) = \(index)\n"
            diff += "+let newValue\(index) = \(index + 1)\n"
        }
        return diff
    }

    private func renderedDiff() throws -> (
        window: NSWindow,
        view: PBNativeContentView,
        scrollView: NSScrollView
    ) {
        XCTAssertTrue(Thread.isMainThread)
        let view = PBNativeContentView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.layoutIfNeeded()
        let path = "Large.swift"
        let diff = largeDiff(path: path, lineCount: 4500)
        XCTAssertFalse(PBHighlighting.shouldHighlightDiff(withByteCount: UInt(diff.utf8.count)))
        view.showDiffSections([
            [
                PBNativeSectionTextKey: diff,
                PBNativeSectionPathKey: path,
                PBNativeSectionContextKey: "readOnly",
            ],
        ])
        let rendered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                view.textView.string.contains("+let newValue4499 = 4500")
            },
            object: view.textView
        )
        wait(for: [rendered], timeout: 20)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let scrollView = try XCTUnwrap(view.textView.enclosingScrollView)
        XCTAssertGreaterThan(
            try XCTUnwrap(scrollView.documentView).frame.height,
            scrollView.contentView.bounds.height
        )
        return (window, view, scrollView)
    }

    private func scrollWorkload(
        window: NSWindow,
        view: PBNativeContentView,
        scrollView: NSScrollView
    ) -> CGFloat {
        let clipView = scrollView.contentView
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let maximumY = max(0, documentHeight - clipView.bounds.height)
        let viewportSize = clipView.bounds.size
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(viewportSize.width),
            pixelsHigh: Int(viewportSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return 0 }
        var checksum: CGFloat = 0
        for step in 0 ..< 40 {
            let fraction = CGFloat((step * 37) % 101) / 100
            clipView.scroll(to: NSPoint(x: 0, y: maximumY * fraction))
            scrollView.reflectScrolledClipView(clipView)
            view.layoutSubtreeIfNeeded()
            let viewport = NSRect(origin: clipView.bounds.origin, size: viewportSize)
            view.textView.cacheDisplay(in: viewport, to: bitmap)
            window.displayIfNeeded()
            checksum += clipView.bounds.origin.y
        }
        return checksum
    }

    func testRevisionSpecifierParsingPerformance() {
        let parameterSets = [
            ["refs/heads/main"],
            ["refs/remotes/origin/topic"],
            ["HEAD~25"],
            ["main..topic"],
            ["HEAD", "--", "Classes/Controllers"],
        ]
        let workload = { () -> Int in
            var classifiedCount = 0
            for iteration in 0 ..< 2000 {
                autoreleasepool {
                    let specifier = PBGitRevSpecifier(
                        parameters: parameterSets[iteration % parameterSets.count]
                    )
                    classifiedCount += specifier.isSimpleRef ? 1 : 0
                    classifiedCount += specifier.hasPathLimiter() ? 1 : 0
                    _ = specifier.title()
                }
            }
            return classifiedCount
        }
        _ = workload()

        var classifiedCount = 0
        measure {
            classifiedCount = workload()
        }

        XCTAssertGreaterThan(classifiedCount, 0)
    }

    func testSourceLanguageClassificationPerformance() {
        let paths = [
            "Classes/Controllers/PBGitWindowController.m",
            "Classes/Views/PBHighlighting.swift",
            "Resources/source.css",
            "Dockerfile",
            "README.markdown",
        ]
        let workload = { () -> String? in
            var lastLanguage: String?
            for iteration in 0 ..< 20000 {
                lastLanguage = PBHighlighting.languageName(
                    forPath: paths[iteration % paths.count]
                )
            }
            return lastLanguage
        }
        _ = workload()

        var lastLanguage: String?
        measure {
            lastLanguage = workload()
        }

        XCTAssertNotNil(lastLanguage)
    }

    func testLargeIndexSnapshotParsingAndReductionPerformance() {
        let parser = PBIndexStatusParser()
        let reducer = PBIndexSnapshotReducer()
        var stagedOutput = ""
        var unstagedOutput = ""
        for index in 0 ..< 5000 {
            let path = "folder/file-\(index).txt"
            stagedOutput += ":100644 100644 old\(index) staged\(index) M\0\(path)\0"
            unstagedOutput += ":100644 100644 staged\(index) working\(index) M\0\(path)\0"
        }
        let stagedData = stagedOutput.data(using: .utf8)
        let unstagedData = unstagedOutput.data(using: .utf8)
        var resultCount = 0
        let workload = {
            let staged = parser.parseTrackedData(stagedData, error: nil)
            let unstaged = parser.parseTrackedData(unstagedData, error: nil)
            resultCount = reducer.reducePrevious(
                [],
                staged: staged,
                unstaged: unstaged,
                untracked: [:]
            ).count
        }
        workload()

        measure {
            workload()
        }

        XCTAssertEqual(resultCount, 5000)
    }

    func testLargeNativeDiffScrollingPerformance() throws {
        let fixture = try renderedDiff()
        _ = scrollWorkload(window: fixture.window, view: fixture.view, scrollView: fixture.scrollView)
        _ = scrollWorkload(window: fixture.window, view: fixture.view, scrollView: fixture.scrollView)

        var checksum: CGFloat = 0
        measure {
            checksum = scrollWorkload(
                window: fixture.window,
                view: fixture.view,
                scrollView: fixture.scrollView
            )
        }

        XCTAssertGreaterThan(checksum, 0)
    }
}
