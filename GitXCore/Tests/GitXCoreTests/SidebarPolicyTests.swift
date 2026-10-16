@testable import GitXCore
import XCTest

final class SidebarPolicyTests: XCTestCase {
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

    func testRepairPresentationRequiresExplicitConsentForEveryReclaimAndRenewedPlan() {
        let cases: [(Bool, Bool, WorktreeRepairPresentation)] = [
            (false, false, .perform),
            (false, true, .renewed),
            (true, false, .reclaim),
            (true, true, .reclaim),
        ]
        for (reclaim, changed, expected) in cases {
            XCTAssertEqual(WorktreePresentationPolicy.repair(requiresReclaim: reclaim, changed: changed), expected)
        }
    }

    func testOnlyAnInitiallyApprovedProvenRepairCanProceedBehindAnotherSheet() {
        let cases: [(WorktreeRepairPresentation, Bool, Bool)] = [
            (.perform, false, true),
            (.perform, true, true),
            (.reclaim, false, true),
            (.reclaim, true, false),
            (.renewed, false, true),
            (.renewed, true, false),
        ]
        for (presentation, occupied, expected) in cases {
            XCTAssertEqual(WorktreePresentationPolicy.canDeliverRepair(presentation, hasAttachedSheet: occupied), expected)
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
