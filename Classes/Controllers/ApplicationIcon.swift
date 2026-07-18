import AppKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

@objc(PBApplicationIconStyle)
nonisolated enum ApplicationIconStyle: Int, CaseIterable {
    case plusEyes
    case bracketed
    case cursor
    case mixedDiff

    var displayName: String {
        switch self {
        case .plusEyes: "Plus Eyes"
        case .bracketed: "Bracketed"
        case .cursor: "Cursor"
        case .mixedDiff: "Mixed Diff"
        }
    }
}

@objc(PBApplicationIconController)
final class ApplicationIconController: NSObject {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "AppIcon")
    private static var renderedIcons: [ApplicationIconStyle: NSImage] = [:]

    @objc(imageForStyle:)
    static func image(for style: ApplicationIconStyle) -> NSImage {
        if let image = renderedIcons[style] {
            return image
        }

        let image = ApplicationIconRenderer.image(for: style)
        _ = image.setName(NSImage.Name("GitX.ApplicationIcon.\(style.rawValue)"))
        renderedIcons[style] = image
        return image
    }

    @objc static func applySelectedIcon() {
        let style = ApplicationSettings.applicationIconStyle
        NSApp.applicationIconImage = image(for: style)
        logger.info("Applied Dock icon style \(style.displayName, privacy: .public)")
    }
}

private enum ApplicationIconRenderer {
    private static let canvasSize = NSSize(width: 512, height: 512)
    private static let glyphColor = NSColor.white

    static func image(for style: ApplicationIconStyle) -> NSImage {
        NSImage(size: canvasSize, flipped: false) { bounds in
            drawBackground(in: bounds)
            drawFace(style)
            return true
        }
    }

    private static func drawBackground(in bounds: NSRect) {
        let bodyRect = bounds.insetBy(dx: 27, dy: 27)
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: 108, yRadius: 108)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.shadowBlurRadius = 17
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        NSColor(calibratedRed: 0.18, green: 0.47, blue: 0.96, alpha: 1).setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()

        let background = NSGradient(
            starting: NSColor(calibratedRed: 0.18, green: 0.48, blue: 0.97, alpha: 1),
            ending: NSColor(calibratedRed: 0.62, green: 0.81, blue: 1, alpha: 1)
        )
        background?.draw(in: body, angle: 90)

        NSColor.white.withAlphaComponent(0.72).setStroke()
        body.lineWidth = 3
        body.stroke()

        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        let glossRect = NSRect(
            x: bodyRect.minX,
            y: bodyRect.midY,
            width: bodyRect.width,
            height: bodyRect.height * 0.48
        )
        let gloss = NSGradient(
            starting: NSColor.white.withAlphaComponent(0),
            ending: NSColor.white.withAlphaComponent(0.22)
        )
        gloss?.draw(in: glossRect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawFace(_ style: ApplicationIconStyle) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        glyphColor.setFill()

        switch style {
        case .plusEyes:
            drawPlus(at: NSPoint(x: 170, y: 292), size: 68, thickness: 19)
            drawPlus(at: NSPoint(x: 342, y: 292), size: 68, thickness: 19)
            drawMinusRow(centers: [162, 256, 350], y: 176)

        case .bracketed:
            drawBracket(x: 117, y: 238, opensRight: true)
            drawPlus(at: NSPoint(x: 190, y: 292), size: 62, thickness: 18)
            drawPlus(at: NSPoint(x: 322, y: 292), size: 62, thickness: 18)
            drawBracket(x: 395, y: 238, opensRight: false)
            drawMinusRow(centers: [172, 256, 340], y: 170, width: 60)

        case .cursor:
            drawPlus(at: NSPoint(x: 170, y: 310), size: 66, thickness: 19)
            drawPlus(at: NSPoint(x: 342, y: 310), size: 66, thickness: 19)
            fillGlyph(NSRect(x: 247, y: 205, width: 18, height: 56))
            drawMinusRow(centers: [162, 256, 350], y: 148)

        case .mixedDiff:
            drawPlus(at: NSPoint(x: 170, y: 292), size: 66, thickness: 19)
            drawPlus(at: NSPoint(x: 342, y: 292), size: 66, thickness: 19)
            drawMinus(at: NSPoint(x: 164, y: 170), width: 66, thickness: 18)
            drawMinus(at: NSPoint(x: 256, y: 170), width: 66, thickness: 18)
            drawPlus(at: NSPoint(x: 348, y: 170), size: 62, thickness: 18)
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawPlus(at center: NSPoint, size: CGFloat, thickness: CGFloat) {
        drawMinus(at: center, width: size, thickness: thickness)
        fillGlyph(NSRect(
            x: center.x - thickness / 2,
            y: center.y - size / 2,
            width: thickness,
            height: size
        ))
    }

    private static func drawMinus(at center: NSPoint, width: CGFloat, thickness: CGFloat) {
        fillGlyph(NSRect(
            x: center.x - width / 2,
            y: center.y - thickness / 2,
            width: width,
            height: thickness
        ))
    }

    private static func drawMinusRow(
        centers: [CGFloat],
        y: CGFloat,
        width: CGFloat = 68,
        thickness: CGFloat = 18
    ) {
        for center in centers {
            drawMinus(at: NSPoint(x: center, y: y), width: width, thickness: thickness)
        }
    }

    private static func drawBracket(x: CGFloat, y: CGFloat, opensRight: Bool) {
        let thickness: CGFloat = 18
        let arm: CGFloat = 34
        let height: CGFloat = 108
        fillGlyph(NSRect(x: x - thickness / 2, y: y, width: thickness, height: height))
        let armX = opensRight ? x - thickness / 2 : x - arm + thickness / 2
        fillGlyph(NSRect(x: armX, y: y, width: arm, height: thickness))
        fillGlyph(NSRect(x: armX, y: y + height - thickness, width: arm, height: thickness))
    }

    private static func fillGlyph(_ rect: NSRect) {
        NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5).fill()
    }
}
