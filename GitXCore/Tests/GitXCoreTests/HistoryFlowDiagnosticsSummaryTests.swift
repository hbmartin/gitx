import Foundation
@testable import GitXCore
import XCTest

final class HistoryFlowDiagnosticsSummaryTests: XCTestCase {
    func testCleanAnalysisProducesNoSummary() {
        XCTAssertNil(HistoryFlowDiagnosticsSummary.make(from: []))
        XCTAssertNil(HistoryFlowDiagnosticsSummary.make(from: [
            HistoryFlowDiagnosticInput(severity: .information, path: "A.swift", message: "note"),
        ]))
    }

    func testCountsSeveritiesAndListsErrorsBeforeWarnings() throws {
        let summary = try XCTUnwrap(HistoryFlowDiagnosticsSummary.make(from: [
            HistoryFlowDiagnosticInput(severity: .warning, path: "A.swift", message: "No flow graph for a()."),
            HistoryFlowDiagnosticInput(severity: .error, path: "B.swift", message: "Parse failed."),
            HistoryFlowDiagnosticInput(severity: .information, path: nil, message: "ignored"),
        ]))

        XCTAssertEqual(summary.headline, "Flow analysis is incomplete: 1 error and 1 warning.")
        XCTAssertEqual(summary.details, ["B.swift: Parse failed.", "A.swift: No flow graph for a()."])
        XCTAssertEqual(summary.omittedCount, 0)
    }

    func testCapsDetailsAndReportsTheRemainder() throws {
        let diagnostics = (1 ... 5).map {
            HistoryFlowDiagnosticInput(severity: .error, path: nil, message: "problem \($0)")
        }

        let summary = try XCTUnwrap(HistoryFlowDiagnosticsSummary.make(from: diagnostics, maximumDetails: 2))

        XCTAssertEqual(summary.headline, "Flow analysis is incomplete: 5 errors.")
        XCTAssertEqual(summary.details, ["problem 1", "problem 2"])
        XCTAssertEqual(summary.omittedCount, 3)
    }
}
