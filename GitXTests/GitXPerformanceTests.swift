import XCTest

/// Scheduled microbenchmarks for deterministic parsing and presentation policy.
/// Keep fixture creation outside each measured block and keep this class out of
/// correctness and sanitizer plans.
final class GitXPerformanceTests: XCTestCase {
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
                    )!
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
}
