import Foundation
@testable import GitXCore
import XCTest

final class HistoryFlowChangeSetTests: XCTestCase {
    private func nameStatus(_ fields: [String]) -> Data {
        Data((fields.joined(separator: "\0") + "\0").utf8)
    }

    private func isSwift(_ path: String) -> Bool {
        path.hasSuffix(".swift")
    }

    func testReducesRenamesAcrossTheSupportedBoundaryToTheLoadableSide() throws {
        let data = nameStatus([
            "R100", "Foo.swift", "Foo.swift.bak",
            "R087", "Bar.txt", "Bar.swift",
            "R100", "Both.swift", "Renamed.swift",
        ])

        let files = try HistoryFlowChangeSet.changedFiles(nameStatus: data, isAnalyzable: isSwift)

        XCTAssertEqual(files, [
            HistoryFlowChangedFile(oldPath: "Foo.swift", newPath: nil),
            HistoryFlowChangedFile(oldPath: nil, newPath: "Bar.swift"),
            HistoryFlowChangedFile(oldPath: "Both.swift", newPath: "Renamed.swift"),
        ])
    }

    func testDropsRecordsWithoutAnAnalyzableSide() throws {
        let data = nameStatus([
            "M", "README.md",
            "A", "Added.swift",
            "D", "Deleted.swift",
            "R100", "Old.txt", "New.txt",
            "M", "Changed.swift",
            "C075", "Source.swift", "Copy.swift",
            "T", "Link.swift",
        ])

        let files = try HistoryFlowChangeSet.changedFiles(nameStatus: data, isAnalyzable: isSwift)

        XCTAssertEqual(files, [
            HistoryFlowChangedFile(oldPath: nil, newPath: "Added.swift"),
            HistoryFlowChangedFile(oldPath: "Deleted.swift", newPath: nil),
            HistoryFlowChangedFile(oldPath: "Changed.swift", newPath: "Changed.swift"),
            HistoryFlowChangedFile(oldPath: "Source.swift", newPath: "Copy.swift"),
            HistoryFlowChangedFile(oldPath: "Link.swift", newPath: "Link.swift"),
        ])
    }

    func testEmptyOutputYieldsNoFiles() throws {
        XCTAssertEqual(try HistoryFlowChangeSet.changedFiles(nameStatus: Data(), isAnalyzable: isSwift), [])
    }

    func testRejectsTruncatedAndNonUTF8Records() {
        XCTAssertThrowsError(
            try HistoryFlowChangeSet.changedFiles(nameStatus: nameStatus(["R100", "Only.swift"]), isAnalyzable: isSwift)
        ) { error in
            XCTAssertEqual(error as? HistoryFlowChangeSetError, .malformedNameStatus)
        }
        XCTAssertThrowsError(
            try HistoryFlowChangeSet.changedFiles(nameStatus: nameStatus(["A"]), isAnalyzable: isSwift)
        ) { error in
            XCTAssertEqual(error as? HistoryFlowChangeSetError, .malformedNameStatus)
        }
        XCTAssertThrowsError(
            try HistoryFlowChangeSet.changedFiles(nameStatus: Data([0x4D, 0x00, 0xFF, 0xFE, 0x00]), isAnalyzable: isSwift)
        ) { error in
            XCTAssertEqual(error as? HistoryFlowChangeSetError, .invalidUTF8)
        }
    }
}
