import ForgeKit
import GitHubForgeAdapter
import XCTest

final class GitHubForgeAdapterBoundaryTests: XCTestCase {
    func testAdapterTargetDeclaresGitHubWithoutExposingTransportTypes() {
        XCTAssertEqual(GitHubForgeAdapterMetadata.forgeKind, ForgeKind.github)
        XCTAssertEqual(GitHubForgeAdapterMetadata.publicHost, "github.com")
    }
}
