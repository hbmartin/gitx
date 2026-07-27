import XCTest

@MainActor
final class StagingDiffPaneControllerTests: XCTestCase {
    func testDiffPaneOwnsTheRepositoryForQueuedBackgroundProductionWithoutACycle() {
        weak var weakRepository: PBGitRepository?
        var pane: PBStagingDiffPaneController?
        autoreleasepool {
            var repository: PBGitRepository? = PBGitRepository()
            weakRepository = repository
            pane = PBStagingDiffPaneController(repository: repository!)
            repository = nil
        }
        XCTAssertNotNil(pane)
        XCTAssertNotNil(
            weakRepository,
            "diff production runs on a background queue after the pane may be torn down and reaches "
                + "the repository through unowned services, so the pane must keep the repository alive"
        )

        autoreleasepool {
            pane = nil
        }
        XCTAssertNil(weakRepository, "releasing the pane must release the repository without a retain cycle")
    }
}
