import CoreGraphics

nonisolated struct InspectorActionViewport {
    let frame: CGRect

    init(visibleFrame: CGRect, primaryDisplayTop: CGFloat) {
        frame = CGRect(x: visibleFrame.minX, y: primaryDisplayTop - visibleFrame.maxY,
                       width: visibleFrame.width, height: visibleFrame.height)
    }

    func contains(_ action: CGRect) -> Bool {
        !action.isEmpty && frame.contains(action)
    }

    func displacement(toContain action: CGRect) -> CGVector? {
        guard !action.isEmpty, action.width <= frame.width, action.height <= frame.height else { return nil }
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
