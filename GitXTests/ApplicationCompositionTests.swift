import XCTest

final class ApplicationCompositionTests: XCTestCase {
    private var originalComposition: PBApplicationComposition!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        originalComposition = PBApplicationComposition.shared()
        suiteName = "GitXTests.ApplicationComposition.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        PBApplicationComposition.setShared(
            PBApplicationComposition(userDefaults: defaults)
        )
    }

    override func tearDown() {
        PBApplicationComposition.setShared(originalComposition)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        originalComposition = nil
        super.tearDown()
    }

    func testApplicationSettingsAndLegacyDefaultsUseInjectedPreferences() {
        PBApplicationSettings.diffContextLines = 99
        XCTAssertEqual(defaults.integer(forKey: "PBDiffContextLines"), 20)

        PBGitDefaults.setBranchFilter(3)
        XCTAssertEqual(defaults.integer(forKey: "PBBranchFilter"), 3)

        defaults.set(2, forKey: "PBHistorySearchMode")
        XCTAssertEqual(PBGitDefaults.historySearchMode(), 2)
    }
}
