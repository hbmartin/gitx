import XCTest

final class CommitMenuPresenterTests: XCTestCase {
    func testStageAndUnstageTitlesForZeroOneAndManyFiles() {
        let emptyStage = presentation("stageFiles:")
        XCTAssertEqual(emptyStage.title, "Stage")
        XCTAssertFalse(emptyStage.enabled)
        XCTAssertTrue(emptyStage.updatesHidden)
        XCTAssertTrue(emptyStage.hidden)

        let stagedFile = file("folder/staged.txt", status: 1, unstaged: false)
        let singleUnstage = presentation("unstageFiles:", staged: [stagedFile])
        XCTAssertEqual(singleUnstage.title, "Unstage “staged.txt”")
        XCTAssertTrue(singleUnstage.enabled)
        XCTAssertFalse(singleUnstage.hidden)

        let manyStage = presentation(
            "stageFiles:",
            unstaged: [file("one.txt"), file("folder/two.txt")]
        )
        XCTAssertEqual(manyStage.title, "Stage 2 Files")
        XCTAssertTrue(manyStage.enabled)
    }

    func testDiscardAndTrashPreserveNewAndMixedSelectionRules() {
        let newFile = file("new.txt")
        let discardNew = presentation("discardFiles:", unstaged: [newFile])
        XCTAssertTrue(discardNew.enabled)
        XCTAssertTrue(discardNew.hidden)

        let trashNew = presentation("moveToTrash:", unstaged: [newFile])
        XCTAssertEqual(trashNew.title, "Move “new.txt” to Trash")
        XCTAssertTrue(trashNew.enabled)
        XCTAssertFalse(trashNew.hidden)

        let modified = file("modified.txt", status: 1)
        let mixed = [newFile, modified]
        let discardMixed = presentation("discardFiles:", unstaged: mixed)
        XCTAssertEqual(discardMixed.title, "Discard changes to 2 Files…")
        XCTAssertFalse(discardMixed.hidden)
        let forceMixed = presentation("discardFilesForcibly:", unstaged: mixed)
        XCTAssertTrue(forceMixed.alternate)
        XCTAssertFalse(forceMixed.hidden)
        XCTAssertTrue(presentation("moveToTrash:", unstaged: mixed).hidden)
    }

    func testDiscardRequiresAnUnstagedChangeAndHandlesEmptyBoundary() {
        let stagedOnly = file("staged.txt", status: 1, unstaged: false)
        XCTAssertFalse(presentation("discardFiles:", unstaged: [stagedOnly]).enabled)

        let emptyDiscard = presentation("discardFiles:")
        XCTAssertFalse(emptyDiscard.enabled)
        XCTAssertTrue(emptyDiscard.hidden)
        let emptyTrash = presentation("moveToTrash:")
        XCTAssertFalse(emptyTrash.enabled)
        XCTAssertFalse(emptyTrash.hidden)
    }

    func testOpenTitlesHandleFilesAndSubmodules() {
        let selected = [file("folder/submodule", status: 1)]
        XCTAssertEqual(
            presentation("openFiles:", unstaged: selected).title,
            "Open “submodule”"
        )
        XCTAssertEqual(
            presentation("openFiles:", unstaged: selected, submodule: true).title,
            "Open Submodule “folder/submodule” in GitX"
        )
        XCTAssertFalse(presentation("openFiles:").enabled)
    }

    func testIgnoreAndRevealRespectTableContextAndSelectionCount() {
        let selected = [file("one.txt")]
        let ignore = presentation("ignoreFiles:", unstaged: selected)
        XCTAssertTrue(ignore.enabled)
        XCTAssertFalse(ignore.hidden)

        let stagedIgnore = presentation(
            "ignoreFiles:",
            unstaged: selected,
            staged: selected,
            stagedContext: true
        )
        XCTAssertFalse(stagedIgnore.enabled)
        XCTAssertTrue(stagedIgnore.hidden)

        let reveal = presentation("revealInFinder:", unstaged: selected)
        XCTAssertEqual(reveal.title, "Reveal “one.txt” in Finder")
        XCTAssertTrue(reveal.enabled)
        let manyReveal = presentation("revealInFinder:", unstaged: [file("one"), file("two")])
        XCTAssertEqual(manyReveal.title, "Reveal in Finder")
        XCTAssertFalse(manyReveal.enabled)
        XCTAssertTrue(manyReveal.hidden)
    }

    func testAmendPrepareAndUnknownActionsReturnExternalState() {
        let amend = presentation("toggleAmendCommit:", amend: true)
        XCTAssertTrue(amend.enabled)
        XCTAssertTrue(amend.updatesState)
        XCTAssertEqual(amend.state, 1)
        XCTAssertFalse(presentation("prepareCommitMessage:", prepareHook: false).enabled)
        XCTAssertTrue(presentation("prepareCommitMessage:", prepareHook: true).enabled)
        XCTAssertTrue(presentation("copy:", fallback: true).enabled)
        XCTAssertFalse(presentation("copy:", fallback: false).enabled)
    }

    func testMainMenuPresentationDoesNotOverwriteContextualProperties() {
        let result = presentation(
            "stageFiles:",
            unstaged: [file("one.txt")],
            contextual: false
        )
        XCTAssertNil(result.title)
        XCTAssertFalse(result.updatesHidden)
        XCTAssertFalse(result.updatesAlternate)
        XCTAssertFalse(result.updatesState)
        XCTAssertTrue(result.enabled)

        let reveal = presentation(
            "revealInFinder:",
            unstaged: [file("one.txt")],
            contextual: false
        )
        XCTAssertNil(reveal.title)
        XCTAssertFalse(reveal.updatesHidden)
        XCTAssertTrue(reveal.enabled)
    }

    private func file(_ path: String, status: Int = 0, unstaged: Bool = true) -> PBCommitMenuFile {
        PBCommitMenuFile(path: path, status: status, hasUnstagedChanges: unstaged)
    }

    private func presentation(
        _ action: String,
        unstaged: [PBCommitMenuFile] = [],
        staged: [PBCommitMenuFile] = [],
        stagedContext: Bool = false,
        contextual: Bool = true,
        submodule: Bool = false,
        amend: Bool = false,
        prepareHook: Bool = false,
        fallback: Bool = true
    ) -> PBCommitMenuPresentation {
        PBCommitMenuPresenter.presentation(
            action: NSSelectorFromString(action),
            unstagedFiles: unstaged,
            stagedFiles: staged,
            isStagedContext: stagedContext,
            allowsTrash: !stagedContext,
            isContextualMenu: contextual,
            singleSelectionIsSubmodule: submodule,
            isAmend: amend,
            prepareHookExists: prepareHook,
            fallbackEnabled: fallback
        )
    }
}
