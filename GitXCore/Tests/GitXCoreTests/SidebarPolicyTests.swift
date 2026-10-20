@testable import GitXCore
import XCTest

final class SidebarPolicyTests: XCTestCase {
    func testUnknownInventoryStatusRetainsStaleRecoveryGuidance() {
        for hasSnapshot in [false, true] {
            let presentation = WorktreeInventoryPresentation(rawStatus: Int.max, hasSnapshot: hasSnapshot, capabilityExplanation: "Git Preferences")
            XCTAssertTrue(presentation.warns)
            XCTAssertFalse(presentation.showsInitialProgress)
            XCTAssertTrue(presentation.message?.contains("Refresh Worktrees") == true)
        }
    }

    func testInventoryStatusSeparatesProgressRecoveryAndCapabilityGuidance() {
        for hasSnapshot in [false, true] {
            for status in [WorktreeInventoryStatus.checkingCapability, .updating, .fresh, .stale, .unsupported, .closed] {
                let presentation = WorktreeInventoryPresentation(status: status, hasSnapshot: hasSnapshot,
                                                                 capabilityExplanation: "Choose a supported Git in Git Preferences.")
                XCTAssertEqual(WorktreeInventoryPresentation(rawStatus: status.rawValue, hasSnapshot: hasSnapshot,
                                                             capabilityExplanation: "Choose a supported Git in Git Preferences."), presentation)
                XCTAssertEqual(presentation.showsInitialProgress, !hasSnapshot && (status == .updating || status == .checkingCapability))
                XCTAssertEqual(presentation.warns, status == .stale || status == .unsupported)
                switch status {
                case .fresh, .closed: XCTAssertNil(presentation.message)
                case .checkingCapability: XCTAssertTrue(presentation.message?.contains("Checking") == true)
                case .updating: XCTAssertEqual(presentation.message, hasSnapshot ? nil : "Loading worktrees…")
                case .stale: XCTAssertTrue(presentation.message?.contains("Refresh Worktrees") == true)
                case .unsupported:
                    XCTAssertTrue(presentation.message?.contains("Git Preferences") == true)
                    XCTAssertFalse(presentation.message?.contains("Refresh") == true)
                }
            }
        }
    }

    func testBackgroundInventoryReadsRetainSettledWarningsAndAccessibilityUntilRecovery() {
        var state = WorktreeInventoryHeaderState()
        let explanation = "Choose a supported Git in Git Preferences."
        let loading = state.presentation(rawStatus: WorktreeInventoryStatus.updating.rawValue, hasSnapshot: false, isSnapshotStale: true, capabilityExplanation: explanation)
        XCTAssertTrue(loading.showsInitialProgress)
        let fresh = state.presentation(rawStatus: WorktreeInventoryStatus.fresh.rawValue, hasSnapshot: true, isSnapshotStale: false, capabilityExplanation: explanation)
        for _ in 0 ..< 5 {
            XCTAssertEqual(state.presentation(rawStatus: WorktreeInventoryStatus.updating.rawValue, hasSnapshot: true, isSnapshotStale: true, capabilityExplanation: explanation), fresh)
        }
        let stale = state.presentation(rawStatus: WorktreeInventoryStatus.stale.rawValue, hasSnapshot: true, isSnapshotStale: true, capabilityExplanation: explanation)
        XCTAssertTrue(stale.warns)
        XCTAssertEqual(state.presentation(rawStatus: WorktreeInventoryStatus.updating.rawValue, hasSnapshot: true, isSnapshotStale: true, capabilityExplanation: explanation), stale)
        XCTAssertEqual(state.presentation(rawStatus: WorktreeInventoryStatus.fresh.rawValue, hasSnapshot: true, isSnapshotStale: false, capabilityExplanation: explanation), fresh)
    }

    func testNewHeaderStateHandlesBackgroundReadsAndUnknownCapabilityWithoutPriorRendering() {
        for isStale in [false, true] {
            var state = WorktreeInventoryHeaderState()
            let current = state.presentation(rawStatus: WorktreeInventoryStatus.updating.rawValue, hasSnapshot: true, isSnapshotStale: isStale, capabilityExplanation: "Git Preferences")
            XCTAssertEqual(current.warns, isStale)
            XCTAssertFalse(current.showsInitialProgress)
            XCTAssertEqual(current.message?.contains("Refresh Worktrees") == true, isStale)
            XCTAssertTrue(state.presentation(rawStatus: Int.max, hasSnapshot: true, isSnapshotStale: isStale, capabilityExplanation: "Git Preferences").warns)
        }
    }

    func testSupportedCapabilityRecoveryCannotRestoreObsoleteUnsupportedGuidance() {
        for hasSnapshot in [false, true] {
            var state = WorktreeInventoryHeaderState()
            let explanation = "Choose a supported Git in Git Preferences."
            let unsupported = state.presentation(rawStatus: WorktreeInventoryStatus.unsupported.rawValue, hasSnapshot: hasSnapshot, isSnapshotStale: true, capabilityExplanation: explanation)
            XCTAssertEqual(unsupported.message, explanation)
            let checking = state.presentation(rawStatus: WorktreeInventoryStatus.checkingCapability.rawValue, hasSnapshot: hasSnapshot, isSnapshotStale: true, capabilityExplanation: explanation)
            XCTAssertEqual(checking.showsInitialProgress, !hasSnapshot)
            XCTAssertFalse(checking.warns)
            let supportedRead = state.presentation(rawStatus: WorktreeInventoryStatus.updating.rawValue, hasSnapshot: hasSnapshot, isSnapshotStale: true, capabilityExplanation: explanation)
            XCTAssertNotEqual(supportedRead.message, explanation)
            XCTAssertEqual(supportedRead.warns, hasSnapshot)
            XCTAssertEqual(supportedRead.showsInitialProgress, !hasSnapshot)
            let recovered = state.presentation(rawStatus: WorktreeInventoryStatus.fresh.rawValue, hasSnapshot: true, isSnapshotStale: false, capabilityExplanation: explanation)
            XCTAssertNil(recovered.message)
            XCTAssertFalse(recovered.showsInitialProgress)
            let closed = state.presentation(rawStatus: WorktreeInventoryStatus.closed.rawValue, hasSnapshot: true, isSnapshotStale: true, capabilityExplanation: explanation)
            XCTAssertNil(closed.message)
            XCTAssertFalse(closed.showsInitialProgress)
        }
    }

    func testDeferredPresentationRequiresTheActiveVisibleKeyOwnerWithoutAnotherSheet() {
        for mask in 0 ..< 32 {
            let active = mask & 1 != 0
            let visible = mask & 2 != 0
            let key = mask & 4 != 0
            let mini = mask & 8 != 0
            let sheet = mask & 16 != 0
            XCTAssertEqual(WorktreePresentationPolicy.canPresent(isApplicationActive: active, isWindowVisible: visible,
                                                                 isWindowKey: key, isMiniaturized: mini, hasAttachedSheet: sheet), mask == 7)
        }
    }

    func testConsentWordingTracksPreviousClicks() {
        XCTAssertEqual(WorktreePresentationPolicy.consentUpdateMessage(action: "Reclaim", previouslyConfirmed: false, updated: false), "")
        XCTAssertFalse(WorktreePresentationPolicy.consentUpdateMessage(action: "Reclaim", previouslyConfirmed: false, updated: true).contains("again"))
        XCTAssertTrue(WorktreePresentationPolicy.consentUpdateMessage(action: "Reclaim", previouslyConfirmed: true, updated: true).contains("Reclaim again"))
        XCTAssertTrue(WorktreePresentationPolicy.consentUpdateMessage(action: "Prune", previouslyConfirmed: true, updated: false).contains("Prune again"))
    }

    func testPrunePresentationPrioritizesMovedLinksAndUsesTheAuthoritativeReport() {
        let cases: [(String, Bool, WorktreePrunePresentation)] = [
            ("", false, .empty),
            (" \t\n\r\u{2003}", false, .empty),
            ("Removing worktrees/topic: gitdir file points to non-existent location", false,
             .confirmation("Removing worktrees/topic: gitdir file points to non-existent location")),
            (" \nfirst path\nsecond café path\n ", false, .confirmation("first path\nsecond café path")),
            ("", true, .repair),
            (" \t\n", true, .repair),
            ("Removing worktrees/topic: gitdir file points to non-existent location", true, .repair),
        ]
        for (report, moved, expected) in cases {
            XCTAssertEqual(WorktreePresentationPolicy.prune(report: report, hasMovedWorktrees: moved), expected)
        }
    }

    func testRepairOfferKeepsUnsafeObjectsOnTheManualGuidanceRoute() {
        let cases: [(Bool, Bool, WorktreeRepairOfferPresentation)] = [
            (false, false, .none),
            (false, true, .chooseStyle),
            (true, false, .manualGuidance),
            (true, true, .manualGuidance),
        ]
        for (manual, broken, expected) in cases {
            XCTAssertEqual(WorktreePresentationPolicy.repairOffer(hasManualRepairPaths: manual, hasBrokenLinks: broken), expected)
        }
    }

    func testOnlyTheStandardUserCancellationSuppressesWorktreeErrors() {
        XCTAssertTrue(WorktreePresentationPolicy.isExpectedCancellation(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
        XCTAssertFalse(WorktreePresentationPolicy.isExpectedCancellation(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
        XCTAssertFalse(WorktreePresentationPolicy.isExpectedCancellation(NSError(domain: "GitXRepositoryServiceError", code: NSUserCancelledError)))
    }

    func testNestedSelectionControlUpdatesFlushOnlyWhenTheOuterOwnerFinishes() {
        var state = SidebarSelectionControlsRefreshState()
        state.begin()
        state.begin()
        state.begin()
        XCTAssertFalse(state.finish(), "The delegate contributes to its enclosing selection")
        XCTAssertFalse(state.finish(), "Restoration contributes to the reference rebuild")
        state.begin()
        XCTAssertFalse(state.finish())
        XCTAssertTrue(state.finish(), "The completed rebuild refreshes controls once")
        XCTAssertFalse(state.finish(), "An unmatched finish cannot manufacture another refresh")
    }

    func testSeparateSelectionControlUpdatesEachFlushAtTheirOwnCompletion() {
        var state = SidebarSelectionControlsRefreshState()
        XCTAssertFalse(state.finish())
        for _ in 0 ..< 3 {
            state.begin()
            XCTAssertTrue(state.finish())
        }
    }

    func testWorktreeReferenceMenuRequiresTheExactRawLocalBranch() {
        let reference = "refs/heads/topic"
        XCTAssertTrue(SidebarWorktreeMenuPolicy.canUseReferenceMenu(reference: reference, branchIdentity: Data(reference.utf8)))
        XCTAssertFalse(SidebarWorktreeMenuPolicy.canUseReferenceMenu(reference: reference, branchIdentity: nil))
        XCTAssertFalse(SidebarWorktreeMenuPolicy.canUseReferenceMenu(reference: reference, branchIdentity: Data("refs/heads/other".utf8)))
        for nonlocal in ["refs/tags/topic", "refs/remotes/origin/topic", "refs/gitx/topic", "HEAD", "refs/heads", "refs/heads/"] {
            XCTAssertFalse(SidebarWorktreeMenuPolicy.canUseReferenceMenu(reference: nonlocal, branchIdentity: Data(nonlocal.utf8)))
        }
        let composed = "refs/heads/café"
        let decomposed = "refs/heads/cafe\u{301}"
        XCTAssertTrue(SidebarWorktreeMenuPolicy.canUseReferenceMenu(reference: composed, branchIdentity: Data(composed.utf8)))
        XCTAssertFalse(SidebarWorktreeMenuPolicy.canUseReferenceMenu(reference: composed, branchIdentity: Data(decomposed.utf8)))
        let rawInvalidUTF8 = Data(Array("refs/heads/".utf8) + [0xFF])
        let displayedInvalidUTF8 = String(decoding: rawInvalidUTF8, as: UTF8.self)
        XCTAssertFalse(SidebarWorktreeMenuPolicy.canUseReferenceMenu(reference: displayedInvalidUTF8, branchIdentity: rawInvalidUTF8))
    }

    func testRemoteSyncAddsAndRemovesOnlySafeNames() {
        let plan = SidebarRemotePolicy.syncPlan(
            configuredRemoteNames: ["zeta", "origin", "alpha", "upstream"],
            existingRemoteNames: ["backup", "origin", "stale", "archive"],
            nonEmptyRemoteNames: ["stale"]
        )
        XCTAssertEqual(
            plan,
            SidebarRemoteSyncPlan(
                namesToAdd: ["alpha", "upstream", "zeta"],
                namesToRemove: ["archive", "backup"]
            )
        )
    }

    func testRevisionPlacementPreservesSidebarGrouping() {
        let cases: [(String?, Bool, Bool, SidebarRevisionPlan)] = [
            (nil, true, false, SidebarRevisionPlan(placement: .other)),
            ("HEAD", true, false, SidebarRevisionPlan(placement: .branchRoot)),
            ("refs/heads/feature/topic", false, false, SidebarRevisionPlan(placement: .hidden)),
            ("refs/heads/feature/topic", true, true, SidebarRevisionPlan(placement: .branchRoot)),
            (
                "refs/heads/feature/topic",
                true,
                false,
                SidebarRevisionPlan(placement: .branchPath, path: ["feature", "topic"])
            ),
            ("refs/tags/v1", true, false, SidebarRevisionPlan(placement: .tagPath, path: ["v1"])),
            (
                "refs/remotes/origin/main",
                true,
                false,
                SidebarRevisionPlan(placement: .remotePath, path: ["origin", "main"])
            ),
            ("refs/notes/review", true, false, SidebarRevisionPlan(placement: .unsupported)),
        ]

        for (reference, shouldShow, recent, expected) in cases {
            XCTAssertEqual(
                SidebarRevisionPolicy.plan(
                    simpleReference: reference,
                    shouldShowBranch: shouldShow,
                    usesRecentBranchSorting: recent
                ),
                expected
            )
        }
    }
}
