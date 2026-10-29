import CoreGraphics
import XCTest

final class InspectorActionGeometryTests: XCTestCase {
    func testWaiterTimeoutFinalizesCachedGeometryWithoutAnotherPoll() {
        let viewport = InspectorActionViewport(visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), primaryDisplayTop: 800)
        let frame = CGRect(x: 10, y: 10, width: 100, height: 25)
        var wait = InspectorActionGeometryWait(viewport: viewport, startedAt: 0)
        XCTAssertEqual(wait.observe(exists: true, frame: frame, at: 4.9), .waiting)
        XCTAssertEqual(wait.finish(timedOut: true, at: 5), .timedOut)
        XCTAssertEqual(wait.lastReason, .moving)
        XCTAssertEqual(wait.lastFrame, frame)
    }

    func testExpiredPolicyFinalizesEvenWhenWaiterCompletionArrivesLate() {
        let viewport = InspectorActionViewport(visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), primaryDisplayTop: 800)
        var wait = InspectorActionGeometryWait(viewport: viewport, startedAt: 0)
        XCTAssertEqual(wait.observe(exists: true, frame: .zero, at: 4.9), .waiting)
        XCTAssertEqual(wait.finish(timedOut: false, at: 5), .timedOut)
        XCTAssertEqual(wait.lastReason, .unfinished)
    }

    func testFinalizationPreservesTheLastFailureReasonAndFixedBudget() {
        let viewport = InspectorActionViewport(visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), primaryDisplayTop: 800)
        let initial = CGRect(x: -20, y: 10, width: 100, height: 25)
        var missing = InspectorActionGeometryWait(viewport: viewport, startedAt: 10)
        XCTAssertEqual(missing.finish(timedOut: true, at: 15), .timedOut)
        XCTAssertEqual(missing.lastReason, .missing)
        var stale = InspectorActionGeometryWait(viewport: viewport, startedAt: 20, afterDragFrom: initial)
        XCTAssertEqual(stale.observe(exists: true, frame: initial, at: 24.9), .waiting)
        XCTAssertEqual(stale.finish(timedOut: true, at: 25), .timedOut)
        XCTAssertEqual(stale.lastReason, .unchangedAfterDrag)
        XCTAssertEqual(stale.deadline, 25)
        var oversized = InspectorActionGeometryWait(viewport: viewport, startedAt: 0)
        let wide = CGRect(x: 0, y: 0, width: 1100, height: 25)
        XCTAssertEqual(oversized.observe(exists: true, frame: wide, at: 4), .waiting)
        XCTAssertEqual(oversized.observe(exists: true, frame: wide, at: 4.9), .oversized)
        XCTAssertEqual(oversized.finish(timedOut: true, at: 5), .timedOut)
        XCTAssertEqual(oversized.lastReason, .stableOversized)
        XCTAssertEqual(oversized.lastFrame, wide)
    }

    func testFinalizationCannotAcceptLateGeometryOrExtendTheBudget() {
        let viewport = InspectorActionViewport(visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), primaryDisplayTop: 800)
        let frame = CGRect(x: 10, y: 10, width: 100, height: 25)
        var wait = InspectorActionGeometryWait(viewport: viewport, startedAt: 0)
        XCTAssertEqual(wait.observe(exists: true, frame: frame, at: 4.9), .waiting)
        XCTAssertEqual(wait.finish(timedOut: false, at: 4.95), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: frame, at: 5), .timedOut)
        XCTAssertEqual(wait.finish(timedOut: false, at: 5.1), .timedOut)
        XCTAssertEqual(wait.deadline, 5)
        var ready = InspectorActionGeometryWait(viewport: viewport, startedAt: 10)
        XCTAssertEqual(ready.observe(exists: true, frame: frame, at: 14), .waiting)
        XCTAssertEqual(ready.observe(exists: true, frame: frame, at: 14.9), .ready)
        XCTAssertEqual(ready.finish(timedOut: false, at: 15.1), .ready)
        XCTAssertEqual(ready.lastReason, .stable)
    }

    func testInspectorDisplacementCorrectsObservedClampingOnce() throws {
        let viewport = InspectorActionViewport(visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), primaryDisplayTop: 800)
        let clipped = CGRect(x: -2.25, y: 790.5, width: 995, height: 25)
        let first = try XCTUnwrap(viewport.displacement(toContain: clipped))
        // Simulate a window manager applying less than the requested movement.
        let observed = clipped.offsetBy(dx: first.dx / 4, dy: first.dy / 4)
        XCTAssertFalse(viewport.contains(observed))
        let correction = try XCTUnwrap(viewport.displacement(toContain: observed))
        let final = observed.offsetBy(dx: correction.dx, dy: correction.dy)
        XCTAssertTrue(viewport.contains(final))
        let settled = try XCTUnwrap(viewport.displacement(toContain: final))
        XCTAssertEqual(settled, .zero)
    }

    func testOversizedInspectorActionsHaveNoSafeDisplacement() {
        let viewport = InspectorActionViewport(visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), primaryDisplayTop: 800)
        XCTAssertNil(viewport.displacement(toContain: CGRect(x: -2, y: 0, width: 1001, height: 25)))
        XCTAssertNil(viewport.displacement(toContain: CGRect(x: 0, y: -2, width: 25, height: 801)))
        XCTAssertNil(viewport.displacement(toContain: .zero))
    }

    func testInspectorGeometryWaitsForLayoutAndRejectsOversizedControls() {
        let viewport = InspectorActionViewport(visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), primaryDisplayTop: 800)
        var wait = InspectorActionGeometryWait(viewport: viewport, startedAt: 0)
        XCTAssertEqual(wait.observe(exists: false, frame: .zero, at: 0), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: .zero, at: 1), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 25), at: 2), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: CGRect(x: 0, y: 0, width: 100, height: 25), at: 4), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: CGRect(x: 0, y: 0, width: 100, height: 25), at: 4.1), .ready)
        var oversized = InspectorActionGeometryWait(viewport: viewport, startedAt: 0)
        XCTAssertEqual(oversized.observe(exists: true, frame: CGRect(x: 0, y: 0, width: 1001, height: 25), at: 1), .waiting)
        XCTAssertEqual(oversized.observe(exists: true, frame: CGRect(x: 0, y: 0, width: 1001, height: 25), at: 2), .oversized)
    }

    func testInspectorSettlingIgnoresStaleAndTransientGeometry() {
        let viewport = InspectorActionViewport(visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), primaryDisplayTop: 800)
        let initial = CGRect(x: -20, y: 100, width: 100, height: 25)
        let partial = initial.offsetBy(dx: 5, dy: 0)
        let final = initial.offsetBy(dx: 28, dy: 0)
        var wait = InspectorActionGeometryWait(viewport: viewport, startedAt: 12, afterDragFrom: initial)
        XCTAssertEqual(wait.observe(exists: true, frame: initial, at: 12), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: initial, at: 13), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: CGRect(x: 0, y: 0, width: 1001, height: 25), at: 13.5), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: partial, at: 14), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: final, at: 15), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: final, at: 16), .ready)
        XCTAssertTrue(viewport.contains(final))
    }

    func testInspectorSettlingClampedMovementAndIndependentTimeouts() {
        let viewport = InspectorActionViewport(visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), primaryDisplayTop: 800)
        let initial = CGRect(x: -20, y: 100, width: 100, height: 25)
        let clamped = initial.offsetBy(dx: 5, dy: 0)
        var first = InspectorActionGeometryWait(viewport: viewport, startedAt: 20, afterDragFrom: initial)
        XCTAssertEqual(first.observe(exists: true, frame: clamped, at: 24), .waiting)
        XCTAssertEqual(first.observe(exists: true, frame: clamped, at: 24.9), .ready)
        XCTAssertFalse(viewport.contains(clamped))
        var second = InspectorActionGeometryWait(viewport: viewport, startedAt: 40, afterDragFrom: clamped)
        XCTAssertEqual(second.observe(exists: true, frame: clamped, at: 44.9), .waiting)
        XCTAssertEqual(second.observe(exists: true, frame: clamped, at: 45), .timedOut)
        var delayed = InspectorActionGeometryWait(viewport: viewport, startedAt: 50)
        XCTAssertEqual(delayed.observe(exists: true, frame: .zero, at: 55), .timedOut)
    }

    func testInitialGeometryWaitsThroughOversizedAndMovingLayout() {
        let viewport = InspectorActionViewport(visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), primaryDisplayTop: 800)
        let transient = CGRect(x: 0, y: 0, width: 1100, height: 25)
        let first = CGRect(x: 10, y: 10, width: 100, height: 25)
        let final = first.offsetBy(dx: 10, dy: 10)
        var wait = InspectorActionGeometryWait(viewport: viewport, startedAt: 0)
        XCTAssertEqual(wait.observe(exists: true, frame: transient, at: 0.1), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: first, at: 0.2), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: final, at: 0.3), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: final, at: 0.4), .ready)
    }

    func testInitialGeometryResetsAfterUnfinishedLayoutAndTimesOut() {
        let viewport = InspectorActionViewport(visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), primaryDisplayTop: 800)
        let frame = CGRect(x: 10, y: 10, width: 100, height: 25)
        var wait = InspectorActionGeometryWait(viewport: viewport, startedAt: 0)
        XCTAssertEqual(wait.observe(exists: true, frame: frame, at: 0), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: .zero, at: 1), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: frame, at: 2), .waiting)
        XCTAssertEqual(wait.observe(exists: false, frame: frame, at: 3), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: frame, at: 4.9), .waiting)
        XCTAssertEqual(wait.observe(exists: true, frame: frame, at: 5), .timedOut)
    }
}
