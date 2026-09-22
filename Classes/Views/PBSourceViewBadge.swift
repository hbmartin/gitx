import AppKit

@MainActor
@objc(PBSourceViewBadge)
// Objective-C callers resolve this class through its preserved runtime name.
// swiftlint:disable:next unused_declaration
final class SourceViewBadge: NSObject {
    /// This immutable base is shared across draws; each badge adds its state-specific
    /// foreground color to a value-semantic dictionary copy.
    private static let baseTextAttributes: [NSAttributedString.Key: Any] = {
        let centeredStyle = NSMutableParagraphStyle()
        centeredStyle.alignment = .center
        return [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize - 2),
            .paragraphStyle: centeredStyle.copy(),
        ]
    }()

    @objc(badgeHighlightColor)
    class func badgeHighlightColor() -> NSColor {
        NSColor(calibratedHue: 0.612, saturation: 0.275, brightness: 0.735, alpha: 1)
    }

    @objc(badgeBackgroundColor)
    class func badgeBackgroundColor() -> NSColor {
        NSColor(calibratedWhite: 0.6, alpha: 1)
    }

    @objc(badgeColorForCell:)
    class func badgeColor(for cell: NSTableCellView) -> NSColor {
        if cell.backgroundStyle == .emphasized {
            return .white
        }
        if cell.window?.isMainWindow == true {
            return badgeHighlightColor()
        }
        return badgeBackgroundColor()
    }

    @objc(badgeTextColorForCell:)
    class func badgeTextColor(for cell: NSTableCellView) -> NSColor {
        guard cell.backgroundStyle == .emphasized else {
            return .white
        }
        guard cell.window?.isKeyWindow != true else {
            return badgeBackgroundColor()
        }
        if cell.window?.isMainWindow == true {
            return badgeHighlightColor()
        }
        return badgeBackgroundColor()
    }

    @objc(badge:forCell:)
    class func badge(_ badge: String, for cell: NSTableCellView) -> NSImage {
        var textAttributes = baseTextAttributes
        textAttributes[.foregroundColor] = badgeTextColor(for: cell)
        let badgeString = NSAttributedString(string: badge, attributes: textAttributes)

        let imageHeight = ceil(badgeString.size().height)
        let radius = ceil(imageHeight / 4) * 2
        let minimumWidth = ceil(radius * 2.5)
        let imageWidth = max(ceil(badgeString.size().width + radius), minimumWidth)
        let badgeRect = NSRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let badgePath = NSBezierPath(
            roundedRect: badgeRect,
            xRadius: radius,
            yRadius: radius
        )
        let fillColor = badgeColor(for: cell)

        return NSImage(size: badgeRect.size, flipped: false) { _ in
            fillColor.set()
            badgePath.fill()
            badgeString.draw(in: badgeRect)
            return true
        }
    }

    @objc(checkedOutBadgeForCell:)
    // Objective-C source-view cells call this preserved selector.
    // swiftlint:disable:next unused_declaration
    class func checkedOutBadge(for cell: NSTableCellView) -> NSImage {
        badge("✔", for: cell)
    }

    @objc(numericBadge:forCell:)
    // Objective-C source-view cells call this preserved selector.
    // swiftlint:disable:next unused_declaration
    class func numericBadge(_ number: Int, for cell: NSTableCellView) -> NSImage {
        badge(String(number), for: cell)
    }
}
