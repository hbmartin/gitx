import ForgeKit
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
            PBApplicationComposition(
                userDefaults: defaults,
                automaticallyStartsForgeServices: false
            )
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

        PBGitDefaults.setRecentCloneDestination("/tmp/injected-clone")
        XCTAssertEqual(PBGitDefaults.recentCloneDestination(), "/tmp/injected-clone")

        defaults.set(2, forKey: "PBHistorySearchMode")
        XCTAssertEqual(PBGitDefaults.historySearchMode(), 2)
    }

    func testAvatarDefaultsDoNotReenterSharedCompositionInitialization() {
        defaults.set(false, forKey: "PBLoadForgeAvatars")

        let composition = PBApplicationComposition(
            userDefaults: defaults,
            automaticallyStartsForgeServices: false
        )
        let firstShared = PBApplicationComposition.shared()
        let secondShared = PBApplicationComposition.shared()

        XCTAssertTrue(firstShared === secondShared)
        XCTAssertFalse(composition.applicationPreferences.bool(forKey: "PBLoadForgeAvatars"))
    }

    func testLegacyGeneralDefaultsExcludeCommitGuidesAndForwardRemainingToggles() {
        defaults.set(false, forKey: "PBEnableGist")
        defaults.set(false, forKey: "PBEnableGravatar")
        defaults.set(false, forKey: "PBConfirmPublicGists")
        defaults.set(true, forKey: "PBGistPublic")

        XCTAssertFalse(PBGitDefaults.isGistEnabled())
        XCTAssertFalse(PBGitDefaults.isGravatarEnabled())
        XCTAssertFalse(PBGitDefaults.confirmPublicGists())
        XCTAssertTrue(PBGitDefaults.isGistPublic())

        for removedKey in [
            "PBCommitMessageViewHasVerticalLine",
            "PBCommitMessageViewVerticalLineLength",
            "PBCommitMessageViewVerticalBodyLineLength",
        ] {
            XCTAssertNil(defaults.object(forKey: removedKey))
        }
    }

    func testPreferenceWrappersForwardEveryAccessorToTheInjectedDefaults() {
        let preferences = PBApplicationComposition.shared().applicationPreferences
        preferences.registerDefaults(["GitXTests.registered": "fallback"])
        XCTAssertEqual(preferences.string(forKey: "GitXTests.registered"), "fallback")

        preferences.setObject("value", forKey: "GitXTests.object")
        XCTAssertEqual(preferences.object(forKey: "GitXTests.object") as? String, "value")
        XCTAssertEqual(defaults.string(forKey: "GitXTests.object"), "value")
        preferences.setObject(["one"], forKey: "GitXTests.array")
        XCTAssertEqual(preferences.array(forKey: "GitXTests.array") as? [String], ["one"])
        XCTAssertEqual(defaults.array(forKey: "GitXTests.array") as? [String], ["one"])
        preferences.setObject(["key": "stored"], forKey: "GitXTests.dictionary")
        XCTAssertEqual(
            preferences.dictionary(forKey: "GitXTests.dictionary") as? [String: String],
            ["key": "stored"]
        )
        XCTAssertEqual(
            defaults.dictionary(forKey: "GitXTests.dictionary") as? [String: String],
            ["key": "stored"]
        )
        preferences.setObject(Data([0x67]), forKey: "GitXTests.data")
        XCTAssertEqual(preferences.data(forKey: "GitXTests.data"), Data([0x67]))
        XCTAssertEqual(defaults.data(forKey: "GitXTests.data"), Data([0x67]))

        preferences.setBool(true, forKey: "GitXTests.bool")
        XCTAssertTrue(preferences.bool(forKey: "GitXTests.bool"))
        XCTAssertTrue(defaults.bool(forKey: "GitXTests.bool"))
        preferences.setInteger(7, forKey: "GitXTests.integer")
        XCTAssertEqual(preferences.integer(forKey: "GitXTests.integer"), 7)
        XCTAssertEqual(defaults.integer(forKey: "GitXTests.integer"), 7)
        preferences.setDouble(1.5, forKey: "GitXTests.double")
        XCTAssertEqual(preferences.double(forKey: "GitXTests.double"), 1.5)
        XCTAssertEqual(defaults.double(forKey: "GitXTests.double"), 1.5)

        preferences.removeObject(forKey: "GitXTests.object")
        XCTAssertNil(preferences.object(forKey: "GitXTests.object"))
        XCTAssertNil(defaults.object(forKey: "GitXTests.object"))
        preferences.synchronize()
        XCTAssertEqual(
            defaults.persistentDomain(forName: suiteName)?["GitXTests.integer"] as? Int,
            7,
            "synchronize must persist values through the injected defaults"
        )
        XCTAssertNil(
            defaults.persistentDomain(forName: suiteName)?["GitXTests.registered"],
            "registered defaults stay in the registration domain and are never persisted"
        )
    }

    func testApplicationIconSettingPersistsAndRejectsUnknownValues() {
        XCTAssertEqual(PBApplicationSettings.applicationIconStyle, .plusEyes)

        PBApplicationSettings.applicationIconStyle = .mixedDiff
        XCTAssertEqual(defaults.integer(forKey: "PBApplicationIconStyle"), PBApplicationIconStyle.mixedDiff.rawValue)
        XCTAssertEqual(PBApplicationSettings.applicationIconStyle, .mixedDiff)

        defaults.set(99, forKey: "PBApplicationIconStyle")
        XCTAssertEqual(PBApplicationSettings.applicationIconStyle, .plusEyes)
    }

    func testAttentionSettingsPersistValidatedPollingAlertsAndViewState() {
        XCTAssertEqual(PBApplicationSettings.attentionPollingPreset, .balanced)
        XCTAssertTrue(PBApplicationSettings.attentionAlertCategories.isEmpty)
        XCTAssertTrue(PBApplicationSettings.attentionIncludesFailedChecksOnAuthoredPullRequests)
        XCTAssertFalse(PBApplicationSettings.attentionIncludesFailedChecksAwaitingReview)
        XCTAssertEqual(PBApplicationSettings.attentionViewState, .defaultValue)

        PBApplicationSettings.attentionPollingPreset = .conservative
        PBApplicationSettings.attentionAlertCategories = [.assignments, .mentionsAndReplies]
        PBApplicationSettings.attentionIncludesFailedChecksOnAuthoredPullRequests = false
        PBApplicationSettings.attentionIncludesFailedChecksAwaitingReview = true
        let state = ForgeAttentionViewState(
            scope: .all,
            visibility: .active,
            sortOrder: .oldestFirst,
            kinds: [.assignment, .mention],
            columns: [.repository, .title]
        )
        PBApplicationSettings.attentionViewState = state

        XCTAssertEqual(defaults.string(forKey: "PBForgeAttentionPollingPreset"), "conservative")
        XCTAssertEqual(
            defaults.stringArray(forKey: "PBForgeAttentionAlertCategories"),
            ["assignments", "mentionsAndReplies"]
        )
        XCTAssertEqual(PBApplicationSettings.attentionPollingPreset, .conservative)
        XCTAssertEqual(PBApplicationSettings.attentionAlertCategories, [.assignments, .mentionsAndReplies])
        XCTAssertFalse(PBApplicationSettings.attentionPolicy.includesFailedChecksOnAuthoredPullRequests)
        XCTAssertTrue(PBApplicationSettings.attentionPolicy.includesFailedChecksAwaitingReview)
        XCTAssertEqual(PBApplicationSettings.attentionViewState, state)

        defaults.set("future-preset", forKey: "PBForgeAttentionPollingPreset")
        defaults.set(["mentionsAndReplies", "future-category"], forKey: "PBForgeAttentionAlertCategories")
        defaults.set(Data([0x00]), forKey: "PBForgeAttentionViewState")
        XCTAssertEqual(PBApplicationSettings.attentionPollingPreset, .balanced)
        XCTAssertEqual(PBApplicationSettings.attentionAlertCategories, [.mentionsAndReplies])
        XCTAssertEqual(PBApplicationSettings.attentionViewState, .defaultValue)
    }
}
