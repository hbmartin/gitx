@testable import GitXCore
import XCTest

final class SidebarPolicyTests: XCTestCase {
    func testRemoteSyncAddsAndRemovesOnlySafeNames() {
        let plan = SidebarRemotePolicy.syncPlan(
            configuredRemoteNames: ["origin", "upstream"],
            existingRemoteNames: ["backup", "origin", "stale"],
            nonEmptyRemoteNames: ["stale"]
        )
        XCTAssertEqual(
            plan,
            SidebarRemoteSyncPlan(namesToAdd: ["upstream"], namesToRemove: ["backup"])
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
