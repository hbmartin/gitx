import XCTest

final class CommitMenuPresenterTests: XCTestCase {
    func testStageAndUnstageTitlesForZeroOneAndManyFiles() {
        let emptyStage = presentation("stageFiles:")
        XCTAssertEqual(emptyStage.title, "Stage")
        XCTAssertFalse(emptyStage.enabled)
        XCTAssertTrue(emptyStage.updatesHidden)
        XCTAssertTrue(emptyStage.hidden)

        let stagedFile = file("folder/staged.txt", status: 1, unstaged: false)
        let singleUnstage = presentation("unstageFiles:", files: [stagedFile])
        XCTAssertEqual(singleUnstage.title, "Unstage “staged.txt”")
        XCTAssertTrue(singleUnstage.enabled)
        XCTAssertFalse(singleUnstage.hidden)

        let manyStage = presentation(
            "stageFiles:",
            files: [file("one.txt"), file("folder/two.txt")]
        )
        XCTAssertEqual(manyStage.title, "Stage 2 Files")
        XCTAssertTrue(manyStage.enabled)
    }

    func testDiscardAndTrashPreserveNewAndMixedSelectionRules() {
        let newFile = file("new.txt")
        let discardNew = presentation("discardFiles:", files: [newFile])
        XCTAssertTrue(discardNew.enabled)
        XCTAssertTrue(discardNew.hidden)

        let trashNew = presentation("moveToTrash:", files: [newFile])
        XCTAssertEqual(trashNew.title, "Move “new.txt” to Trash")
        XCTAssertTrue(trashNew.enabled)
        XCTAssertFalse(trashNew.hidden)

        let modified = file("modified.txt", status: 1)
        let mixed = [newFile, modified]
        let discardMixed = presentation("discardFiles:", files: mixed)
        XCTAssertEqual(discardMixed.title, "Discard changes to 2 Files…")
        XCTAssertFalse(discardMixed.hidden)
        let forceMixed = presentation("discardFilesForcibly:", files: mixed)
        XCTAssertTrue(forceMixed.alternate)
        XCTAssertFalse(forceMixed.hidden)
        XCTAssertTrue(presentation("moveToTrash:", files: mixed).hidden)
    }

    func testDiscardRequiresAnUnstagedChangeAndHandlesEmptyBoundary() {
        let stagedOnly = file("staged.txt", status: 1, unstaged: false)
        XCTAssertFalse(presentation("discardFiles:", files: [stagedOnly]).enabled)

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
            presentation("openFiles:", files: selected).title,
            "Open “submodule”"
        )
        XCTAssertEqual(
            presentation("openFiles:", files: selected, submodule: true).title,
            "Open Submodule “folder/submodule” in GitX"
        )
        XCTAssertFalse(presentation("openFiles:").enabled)
    }

    func testIgnoreAndRevealRespectTableContextAndSelectionCount() {
        let selected = [file("one.txt")]
        let ignore = presentation("ignoreFiles:", files: selected)
        XCTAssertTrue(ignore.enabled)
        XCTAssertFalse(ignore.hidden)

        let stagedIgnore = presentation("ignoreFiles:")
        XCTAssertFalse(stagedIgnore.enabled)
        XCTAssertTrue(stagedIgnore.hidden)

        let reveal = presentation("revealInFinder:", files: selected)
        XCTAssertEqual(reveal.title, "Reveal “one.txt” in Finder")
        XCTAssertTrue(reveal.enabled)
        let manyReveal = presentation("revealInFinder:", files: [file("one"), file("two")])
        XCTAssertEqual(manyReveal.title, "Reveal 2 Files in Finder")
        XCTAssertTrue(manyReveal.enabled)
        XCTAssertFalse(manyReveal.hidden)
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
            files: [file("one.txt")],
            contextual: false
        )
        XCTAssertNil(result.title)
        XCTAssertFalse(result.updatesHidden)
        XCTAssertFalse(result.updatesAlternate)
        XCTAssertFalse(result.updatesState)
        XCTAssertTrue(result.enabled)

        let reveal = presentation(
            "revealInFinder:",
            files: [file("one.txt")],
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
        files: [PBCommitMenuFile] = [],
        contextual: Bool = true,
        submodule: Bool = false,
        amend: Bool = false,
        prepareHook: Bool = false,
        fallback: Bool = true
    ) -> PBCommitMenuPresentation {
        PBCommitMenuPresenter.presentation(
            action: NSSelectorFromString(action),
            resolvedFiles: files,
            allowsTrash: true,
            isContextualMenu: contextual,
            singleSelectionIsSubmodule: submodule,
            isAmend: amend,
            prepareHookExists: prepareHook,
            fallbackEnabled: fallback
        )
    }
}
