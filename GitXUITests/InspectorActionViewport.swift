import CoreGraphics
import Foundation

nonisolated struct InspectorActionViewport {
    let frame: CGRect

    init(visibleFrame: CGRect, primaryDisplayTop: CGFloat) {
        frame = CGRect(x: visibleFrame.minX, y: primaryDisplayTop - visibleFrame.maxY,
                       width: visibleFrame.width, height: visibleFrame.height)
    }

    static func isReady(_ action: CGRect) -> Bool {
        !action.isEmpty && [action.minX, action.minY, action.maxX, action.maxY, action.width, action.height].allSatisfy(\.isFinite)
    }

    func contains(_ action: CGRect) -> Bool {
        Self.isReady(action) && frame.contains(action)
    }

    func displacement(toContain action: CGRect) -> CGVector? {
        guard Self.isReady(action), action.width <= frame.width, action.height <= frame.height else { return nil }
        func correction(_ lower: CGFloat, _ upper: CGFloat, _ visibleLower: CGFloat, _ visibleUpper: CGFloat) -> CGFloat {
            let margin = min(8, (visibleUpper - visibleLower - (upper - lower)) / 2)
            if lower < visibleLower {
                return visibleLower + margin - lower
            }
            if upper > visibleUpper {
                return visibleUpper - margin - upper
            }
            return 0
        }
        return CGVector(dx: correction(action.minX, action.maxX, frame.minX, frame.maxX),
                        dy: correction(action.minY, action.maxY, frame.minY, frame.maxY))
    }
}

/// Each readiness or settling phase starts its own budget after the drag returns.
nonisolated struct InspectorActionGeometryWait {
    enum Observation: Equatable {
        case waiting, ready, oversized, timedOut
    }

    enum Reason: String {
        case missing, unfinished, moving, unchangedAfterDrag, stable, stableOversized
    }

    static let timeout: TimeInterval = 5
    let viewport: InspectorActionViewport
    let startedAt: TimeInterval
    let afterDragFrom: CGRect?
    var deadline: TimeInterval {
        startedAt + Self.timeout
    }

    private(set) var lastFrame = CGRect.zero
    private(set) var lastReason = Reason.missing
    private var observation = Observation.waiting
    private var previous: CGRect?

    init(viewport: InspectorActionViewport, startedAt: TimeInterval, afterDragFrom: CGRect? = nil) {
        self.viewport = viewport
        self.startedAt = startedAt
        self.afterDragFrom = afterDragFrom
    }

    mutating func observe(exists: Bool, frame: CGRect, at time: TimeInterval) -> Observation {
        guard time < deadline else { return record(.timedOut) }
        lastFrame = frame
        guard exists, InspectorActionViewport.isReady(frame) else {
            lastReason = exists ? .unfinished : .missing
            previous = nil
            return record(.waiting)
        }
        if let initial = afterDragFrom, frame == initial {
            previous = nil
            lastReason = .unchangedAfterDrag
            return record(.waiting)
        }
        let settled = previous == frame
        previous = frame
        guard settled else {
            lastReason = .moving
            return record(.waiting)
        }
        let oversized = viewport.displacement(toContain: frame) == nil
        lastReason = oversized ? .stableOversized : .stable
        return record(oversized ? .oversized : .ready)
    }

    mutating func finish(timedOut: Bool, at time: TimeInterval) -> Observation {
        if timedOut || time >= deadline && observation == .waiting {
            return record(.timedOut)
        }
        return observation
    }

    private mutating func record(_ value: Observation) -> Observation {
        observation = value
        return value
    }
}
