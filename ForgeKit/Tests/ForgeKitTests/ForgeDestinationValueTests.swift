@testable import ForgeKit
import Foundation
import XCTest

final class ForgeDestinationValueTests: XCTestCase {
    func testReferenceValidationCoversGitBoundariesAndUnicode() throws {
        for valid in ["main", "feature/naïve", "release-1.0", "topic_2"] {
            XCTAssertEqual(try ForgeRefName(valid).value, valid)
        }
        for invalid in [
            "", "-main", "/main", "main/", "main.", "feature//x", "feature..x", "@", "a@{b", ".hidden/x",
            "a/.hidden", "a.lock", "a/b.lock", "has space", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b", "a\\b",
        ] {
            XCTAssertThrowsError(try ForgeRefName(invalid), invalid)
        }
    }

    func testCommitFileLineAndNumberValidation() throws {
        XCTAssertEqual(try ForgeCommitID("AbC1234").value, "abc1234")
        for invalid in ["abc", String(repeating: "a", count: 65), "abcdefg!"] {
            XCTAssertThrowsError(try ForgeCommitID(invalid), invalid)
        }
        XCTAssertEqual(try ForgeFilePath("Sources/naïve file.swift").components, ["Sources", "naïve file.swift"])
        for invalid in ["", "/a", "a/", "a//b", "../a", "a/../b", "a\\b"] {
            XCTAssertThrowsError(try ForgeFilePath(invalid), invalid)
        }
        XCTAssertEqual(try ForgeLineSelection(line: 4), try ForgeLineSelection(start: 4, end: 4))
        XCTAssertTrue(try ForgeLineSelection(line: 4).isSingleLine)
        XCTAssertFalse(try ForgeLineSelection(start: 4, end: 8).isSingleLine)
        XCTAssertThrowsError(try ForgeLineSelection(line: 0))
        XCTAssertThrowsError(try ForgeLineSelection(start: 5, end: 4))
        XCTAssertThrowsError(try ForgeItemNumber(0))
    }

    func testValidatedDestinationValuesRoundTripThroughCodable() throws {
        let repository = try TestSupport.repository()
        let destinations: [ForgeDestination] = try [
            .repository(repository),
            .branch(repository, TestSupport.main),
            .commit(repository, TestSupport.commit),
            .file(
                repository,
                revision: .tag(ForgeRefName("v1.0")),
                path: ForgeFilePath("README.md"),
                selection: ForgeLineSelection(start: 1, end: 2)
            ),
            .compare(repository, base: .branch(TestSupport.main), head: .commit(TestSupport.commit)),
            .pullRequest(repository, ForgeItemNumber(1)),
            .issue(repository, ForgeItemNumber(2)),
        ]
        for destination in destinations {
            let data = try JSONEncoder().encode(destination)
            XCTAssertEqual(try JSONDecoder().decode(ForgeDestination.self, from: data), destination)
            XCTAssertEqual(destination.repository, repository)
        }
        let opaqueRevision = try ForgeRevision.opaque(ForgeRefName("release/1.0"))
        XCTAssertEqual(
            try JSONDecoder().decode(ForgeRevision.self, from: JSONEncoder().encode(opaqueRevision)),
            opaqueRevision
        )
        XCTAssertEqual(destinations.map(\.kind), ForgeDestinationKind.allCases)
    }
}
