import XCTest

final class GitBinaryTests: XCTestCase {
    func testDiscoveryVersionAndFallbackErrorRemainAvailable() {
        XCTAssertFalse(PBGitBinary.searchLocations().isEmpty)
        XCTAssertNotNil(PBGitBinary.version())
        XCTAssertFalse(PBGitBinary.notFoundError().isEmpty)
    }
}
