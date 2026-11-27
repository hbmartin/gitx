import GitXCore
import XCTest

final class HistoryFlowReviewTests: XCTestCase {
    private let reviewing = HistoryFlowCommandContext(
        hasReport: true,
        hasFunction: true,
        hasSelectedNode: true,
        presentation: .delta,
        slice: .forward,
        noise: .hideCosmetic,
        groupsByConcern: true,
        canStartWalkthrough: true,
        walkthroughStep: nil,
        walkthroughStepCount: 0
    )

    func testPreferenceKeysAreStable() {
        XCTAssertEqual(ApplicationPreferenceKey.historyFlowPresentation.rawValue, "PBHistoryFlowPresentation")
        XCTAssertEqual(ApplicationPreferenceKey.historyFlowSliceDirection.rawValue, "PBHistoryFlowSliceDirection")
        XCTAssertEqual(ApplicationPreferenceKey.historyFlowNoiseLevel.rawValue, "PBHistoryFlowNoiseLevel")
        XCTAssertEqual(ApplicationPreferenceKey.historyFlowGroupsByConcern.rawValue, "PBHistoryFlowGroupsByConcern")
        XCTAssertEqual(ApplicationPreferenceKey.historyFlowExportFormat.rawValue, "PBHistoryFlowExportFormat")
    }

    func testMissingPreferencesHideCosmeticNoiseAndShowTheDeltaWithoutASlice() {
        let preferences = HistoryFlowReviewPreferences(reading: { _ in nil })
        XCTAssertEqual(preferences, .default)
        XCTAssertEqual(preferences.presentation, .delta)
        XCTAssertNil(preferences.slice)
        XCTAssertEqual(preferences.noise, .hideCosmetic)
        XCTAssertFalse(preferences.groupsByConcern)
        XCTAssertEqual(preferences.exportFormat, .markdown)
    }

    func testStoredPreferencesRoundTrip() {
        let chosen = HistoryFlowReviewPreferences(
            presentation: .beforeAfter,
            slice: .backward,
            noise: .showAll,
            groupsByConcern: true,
            exportFormat: .mermaid
        )
        var store: [String: Any] = [:]
        for (key, value) in chosen.storedValues {
            switch value {
            case let .string(text): store[key.rawValue] = text
            case let .bool(flag): store[key.rawValue] = flag
            }
        }
        XCTAssertEqual(store["PBHistoryFlowPresentation"] as? String, "before-after")
        XCTAssertEqual(store["PBHistoryFlowSliceDirection"] as? String, "backward")
        XCTAssertEqual(store["PBHistoryFlowNoiseLevel"] as? String, "show-all")
        XCTAssertEqual(store["PBHistoryFlowGroupsByConcern"] as? Bool, true)
        XCTAssertEqual(store["PBHistoryFlowExportFormat"] as? String, "mermaid")
        XCTAssertEqual(HistoryFlowReviewPreferences(reading: { store[$0.rawValue] }), chosen)

        var cleared = chosen
        cleared.slice = nil
        XCTAssertTrue(cleared.storedValues.contains { $0.key == .historyFlowSliceDirection && $0.value == .string("none") })
        store["PBHistoryFlowSliceDirection"] = "none"
        XCTAssertNil(HistoryFlowReviewPreferences(reading: { store[$0.rawValue] }).slice)
    }

    func testUnknownOrMistypedPreferencesFallBackOneByOne() {
        let store: [String: Any] = [
            "PBHistoryFlowPresentation": "graph",
            "PBHistoryFlowSliceDirection": 1,
            "PBHistoryFlowNoiseLevel": "hide-formatting",
            "PBHistoryFlowGroupsByConcern": "yes",
            "PBHistoryFlowExportFormat": "xml",
        ]
        let preferences = HistoryFlowReviewPreferences(reading: { store[$0.rawValue] })
        XCTAssertEqual(preferences.presentation, .delta)
        XCTAssertNil(preferences.slice)
        XCTAssertEqual(preferences.noise, .hideFormatting, "A valid value survives beside invalid ones")
        XCTAssertFalse(preferences.groupsByConcern)
        XCTAssertEqual(preferences.exportFormat, .markdown)

        let unknownSlice = HistoryFlowReviewPreferences(reading: { $0 == .historyFlowSliceDirection ? "sideways" : nil })
        XCTAssertNil(unknownSlice.slice)
    }

    func testNoiseLevelsUseFlowDeltaSpellingsAndMenuTitles() {
        XCTAssertEqual(HistoryFlowNoiseLevel.allCases.map(\.rawValue), ["show-all", "hide-formatting", "hide-cosmetic"])
        XCTAssertEqual(
            HistoryFlowNoiseLevel.allCases.map(\.menuTitle),
            ["Show All Changes", "Hide Formatting", "Hide Cosmetic Changes"]
        )
        XCTAssertEqual(HistoryFlowExportFormat.allCases.map(\.displayName), ["Markdown", "JSON", "Mermaid"])
        XCTAssertEqual(HistoryFlowExportFormat.allCases.map(\.fileExtension), ["md", "json", "mmd"])
    }

    func testEveryCommandHasAUniqueTagThatRoundTrips() {
        let tags = HistoryFlowCommand.all.map(\.tag)
        XCTAssertEqual(Set(tags).count, tags.count)
        XCTAssertEqual(HistoryFlowCommand.all.count, 16)
        for command in HistoryFlowCommand.all {
            XCTAssertEqual(HistoryFlowCommand(tag: command.tag), command)
        }
        XCTAssertNil(HistoryFlowCommand(tag: 0))
        XCTAssertNil(HistoryFlowCommand(tag: 103))
    }

    func testEveryCommandIsDisabledWithoutAReport() {
        for command in HistoryFlowCommand.all {
            XCTAssertEqual(
                HistoryFlowCommandPolicy.state(for: command, in: .unavailable),
                HistoryFlowCommandState(isEnabled: false, isChecked: false),
                "\(command)"
            )
        }
    }

    func testPresentationsAndSlicesNeedAFunctionAndSlicesNeedASelectedNodeInTheDelta() {
        XCTAssertEqual(
            HistoryFlowCommandPolicy.state(for: .presentation(.delta), in: reviewing),
            HistoryFlowCommandState(isEnabled: true, isChecked: true)
        )
        XCTAssertEqual(
            HistoryFlowCommandPolicy.state(for: .presentation(.calls), in: reviewing),
            HistoryFlowCommandState(isEnabled: true, isChecked: false)
        )
        XCTAssertEqual(
            HistoryFlowCommandPolicy.state(for: .slice(.forward), in: reviewing),
            HistoryFlowCommandState(isEnabled: true, isChecked: true)
        )
        XCTAssertEqual(
            HistoryFlowCommandPolicy.state(for: .slice(.backward), in: reviewing),
            HistoryFlowCommandState(isEnabled: true, isChecked: false)
        )

        var unselected = reviewing
        unselected.hasSelectedNode = false
        XCTAssertEqual(
            HistoryFlowCommandPolicy.state(for: .slice(.forward), in: unselected),
            HistoryFlowCommandState(isEnabled: false, isChecked: false)
        )
        XCTAssertTrue(HistoryFlowCommandPolicy.state(for: .presentation(.calls), in: unselected).isEnabled)

        var calls = reviewing
        calls.presentation = .calls
        XCTAssertEqual(
            HistoryFlowCommandPolicy.state(for: .slice(.forward), in: calls),
            HistoryFlowCommandState(isEnabled: false, isChecked: false)
        )

        var entity = reviewing
        entity.hasFunction = false
        XCTAssertEqual(
            HistoryFlowCommandPolicy.state(for: .presentation(.delta), in: entity),
            HistoryFlowCommandState(isEnabled: false, isChecked: false)
        )
        XCTAssertEqual(
            HistoryFlowCommandPolicy.state(for: .slice(.forward), in: entity),
            HistoryFlowCommandState(isEnabled: false, isChecked: false)
        )
        XCTAssertTrue(HistoryFlowCommandPolicy.state(for: .noise(.showAll), in: entity).isEnabled)
        XCTAssertTrue(HistoryFlowCommandPolicy.state(for: .copyReport(.json), in: entity).isEnabled)
        XCTAssertTrue(HistoryFlowCommandPolicy.state(for: .exportReport, in: entity).isEnabled)
    }

    func testNoiseAndGroupingReflectTheReview() {
        XCTAssertEqual(
            HistoryFlowNoiseLevel.allCases.map { HistoryFlowCommandPolicy.state(for: .noise($0), in: reviewing) },
            [
                HistoryFlowCommandState(isEnabled: true, isChecked: false),
                HistoryFlowCommandState(isEnabled: true, isChecked: false),
                HistoryFlowCommandState(isEnabled: true, isChecked: true),
            ]
        )
        XCTAssertEqual(
            HistoryFlowCommandPolicy.state(for: .toggleGroupByConcern, in: reviewing),
            HistoryFlowCommandState(isEnabled: true, isChecked: true)
        )
    }

    func testWalkthroughCommandsFollowTheStepOnScreen() {
        func enabled(_ command: HistoryFlowCommand, step: Int?, canStart: Bool = true) -> Bool {
            var context = reviewing
            context.canStartWalkthrough = canStart
            context.walkthroughStep = step
            context.walkthroughStepCount = step == nil ? 0 : 3
            return HistoryFlowCommandPolicy.state(for: command, in: context).isEnabled
        }
        XCTAssertTrue(enabled(.startWalkthrough, step: nil))
        XCTAssertFalse(enabled(.startWalkthrough, step: nil, canStart: false), "No function changed")
        XCTAssertFalse(enabled(.startWalkthrough, step: 0), "A walkthrough is already running")
        XCTAssertFalse(enabled(.nextWalkthroughStep, step: nil))
        XCTAssertFalse(enabled(.previousWalkthroughStep, step: nil))
        XCTAssertTrue(enabled(.nextWalkthroughStep, step: 0))
        XCTAssertFalse(enabled(.previousWalkthroughStep, step: 0))
        XCTAssertTrue(enabled(.nextWalkthroughStep, step: 1))
        XCTAssertTrue(enabled(.previousWalkthroughStep, step: 1))
        XCTAssertFalse(enabled(.nextWalkthroughStep, step: 2))
        XCTAssertTrue(enabled(.previousWalkthroughStep, step: 2))
    }

    func testExportFileNamesAbbreviateRevisionsAndDropUnsafeCharacters() {
        XCTAssertEqual(
            HistoryFlowExportPolicy.fileName(
                base: "58b966582ddd632593afb6101a147740c244ec89",
                target: "39d18d4b9960adf8bf01026a5471c98d62fa3f64",
                format: .markdown
            ),
            "Flow 58b96658..39d18d4b.md"
        )
        XCTAssertEqual(
            HistoryFlowExportPolicy.fileName(base: "a/b:c", target: "HEAD", format: .json),
            "Flow abc..HEAD.json"
        )
        XCTAssertEqual(
            HistoryFlowExportPolicy.fileName(base: "../", target: "", format: .mermaid),
            "Flow revision..revision.mmd"
        )
    }
}
