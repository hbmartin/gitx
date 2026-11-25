@testable import GitXCore
import XCTest

final class ReflogBrowserRequestPolicyTests: XCTestCase {
    func testRequestPolicyProtectsPagesAndPreviewsButAllowsDetailReplacement() {
        var policy = ReflogBrowserRequestPolicy()
        policy.refreshSucceeded()
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
        policy.beginRefresh()
        XCTAssertFalse(policy.permitsRecovery)
    }

    func testPreviewAuthorityAndRefreshRetryFollowTheRepositoryRevision() {
        var policy = ReflogBrowserRequestPolicy()
        policy.refreshSucceeded()
        let original = policy.revision
        XCTAssertTrue(policy.permitsResetPreview(at: original))

        policy.repositoryDidChange()
        XCTAssertTrue(policy.shouldRefresh)
        policy.active = .page
        XCTAssertFalse(policy.shouldRefresh)
        policy.active = nil
        policy.refreshFailed()
        XCTAssertFalse(policy.shouldRefresh)
        XCTAssertFalse(policy.permitsResetPreview(at: original))

        policy.repositoryDidChange()
        XCTAssertTrue(policy.shouldRefresh)
        policy.refreshSucceeded()
        XCTAssertFalse(policy.shouldRefresh)
        XCTAssertFalse(policy.permitsResetPreview(at: original))
        XCTAssertTrue(policy.permitsResetPreview(at: policy.revision))
    }
}
