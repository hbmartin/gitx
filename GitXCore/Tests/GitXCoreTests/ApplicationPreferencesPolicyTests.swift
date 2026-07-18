import Foundation
@testable import GitXCore
import XCTest

final class ApplicationPreferencesPolicyTests: XCTestCase {
    func testApplicationPreferenceBoundsAndFallbacks() {
        XCTAssertEqual(ApplicationPreferencePolicy.validatedRawValue(2, validRange: 0 ... 3, fallback: 0), 2)
        XCTAssertEqual(ApplicationPreferencePolicy.validatedRawValue(4, validRange: 0 ... 3, fallback: 0), 0)
        XCTAssertEqual(ApplicationPreferencePolicy.diffContextLines(-1), 0)
        XCTAssertEqual(ApplicationPreferencePolicy.diffContextLines(21), 20)
        XCTAssertEqual(ApplicationPreferencePolicy.diffFontSize(8), 9)
        XCTAssertEqual(ApplicationPreferencePolicy.diffFontSize(37), 36)
        XCTAssertEqual(ApplicationPreferencePolicy.autoFetchIntervalMinutes(0), 1)
        XCTAssertEqual(ApplicationPreferencePolicy.autoFetchIntervalMinutes(2000), 1440)
    }

    func testApplicationPreferenceKeysAndRepositoryIdentityRemainStable() {
        XCTAssertEqual(ApplicationPreferenceKey.historySearchMode.rawValue, "PBHistorySearchMode")
        XCTAssertEqual(ApplicationPreferenceKey.diffLayout.rawValue, "PBDiffLayout")
        XCTAssertEqual(ApplicationPreferenceKey.applicationIconStyle.rawValue, "PBApplicationIconStyle")
        let url = URL(fileURLWithPath: "/tmp/example/../repository/.git", isDirectory: true)
        XCTAssertTrue(
            ApplicationPreferencePolicy.repositoryViewStateIdentifier(for: url)
                .hasSuffix("/tmp/repository/.git")
        )
    }
}
