@testable import GitXCore
import XCTest

final class ReflogBrowserRequestPolicyTests: XCTestCase {
    func testRequestPolicyProtectsPagesAndPreviewsButAllowsDetailReplacement() {
        var policy = ReflogBrowserRequestPolicy()
        policy.stale = false
        XCTAssertTrue(policy.permitsRecovery)
        for kind in [ReflogBrowserRequestKind.page, .preview, .mutation] {
            policy.active = kind
            XCTAssertFalse(policy.permitsSelection)
            XCTAssertFalse(policy.permits(.details))
            XCTAssertFalse(policy.permitsRecovery)
        }
        policy.active = .details
        XCTAssertTrue(policy.permitsSelection)
        XCTAssertTrue(policy.permits(.details))
        policy.active = .mutation
        for kind in [ReflogBrowserRequestKind.page, .details, .preview, .mutation] {
            XCTAssertFalse(policy.permits(kind))
        }
        policy.active = nil
        XCTAssertTrue(policy.permits(.page))
        policy.stale = true
        XCTAssertFalse(policy.permitsRecovery)
    }
}
