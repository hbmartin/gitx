@testable import GitX
import ForgeKit
import XCTest

/// Reach Swift-only navigation through the app module without expanding production selectors.
@MainActor
enum SidebarLifecycleTestSupport {
    static func assertClosedNavigationIsInert(_ owner: NSObject) throws {
        let sidebar = try XCTUnwrap(owner as? GitX.PBGitSidebarController)
        XCTAssertFalse(sidebar.browseSelectedWorktreeHistory())
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "fixture", name: "closed-sidebar")
        #if DEBUG
            var attempts = 0
            sidebar.productProofForgeDestinationOpening = { _ in attempts += 1; return true }
            defer { sidebar.productProofForgeDestinationOpening = nil }
        #endif
        XCTAssertFalse(sidebar.openForgeDestination(.repository(repository)))
        #if DEBUG
            XCTAssertEqual(attempts, 0)
        #endif
    }
}
