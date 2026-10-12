import AppKit

@objc(PBSidebarTableViewCell)
final class PBSidebarTableViewCell: NSTableCellView {
    @IBOutlet private weak var checkedOutImageView: NSImageView?

    @objc dynamic var isCheckedOut = false {
        didSet { updateCheckmarkImage() }
    }

    @objc dynamic var isLocked = false {
        didSet { updateCheckmarkImage() }
    }

    @objc dynamic var isUnavailable = false {
        didSet {
            textField?.textColor = isUnavailable ? .tertiaryLabelColor : .labelColor
            imageView?.alphaValue = isUnavailable ? 0.5 : 1
            checkedOutImageView?.alphaValue = isUnavailable ? 0.5 : 1
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateCheckmarkImage() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignMainNotification, object: nil)
        if let window {
            center.addObserver(self, selector: #selector(windowMainStateDidChange(_:)), name: NSWindow.didBecomeMainNotification, object: window)
            center.addObserver(self, selector: #selector(windowMainStateDidChange(_:)), name: NSWindow.didResignMainNotification, object: window)
        }
        updateCheckmarkImage()
    }

    @objc private func windowMainStateDidChange(_: Notification) {
        updateCheckmarkImage()
    }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    private func updateCheckmarkImage() {
        checkedOutImageView?.contentTintColor = nil
        if isCheckedOut {
            checkedOutImageView?.image = SourceViewBadge.checkedOutBadge(for: self)
        } else if isLocked {
            checkedOutImageView?.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")
            checkedOutImageView?.contentTintColor = SourceViewBadge.badgeColor(for: self)
        } else {
            checkedOutImageView?.image = nil
        }
        checkedOutImageView?.isHidden = !isCheckedOut && !isLocked
    }
}
