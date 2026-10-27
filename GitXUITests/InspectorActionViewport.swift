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

    static let timeout: TimeInterval = 5
    let viewport: InspectorActionViewport
    let startedAt: TimeInterval
    let afterDragFrom: CGRect?
    private var previous: CGRect?

    init(viewport: InspectorActionViewport, startedAt: TimeInterval, afterDragFrom: CGRect? = nil) {
        self.viewport = viewport
        self.startedAt = startedAt
        self.afterDragFrom = afterDragFrom
    }

    mutating func observe(exists: Bool, frame: CGRect, at time: TimeInterval) -> Observation {
        guard time - startedAt < Self.timeout else { return .timedOut }
        guard exists, InspectorActionViewport.isReady(frame) else {
            previous = nil
            return .waiting
        }
        if let initial = afterDragFrom, frame == initial {
            previous = nil
            return .waiting
        }
        let settled = previous == frame
        previous = frame
        guard settled else { return .waiting }
        return viewport.displacement(toContain: frame) == nil ? .oversized : .ready
    }
}
