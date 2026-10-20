import AppKit

@objc(PBSidebarTableViewCell)
final class PBSidebarTableViewCell: NSTableCellView {
    @IBOutlet private weak var checkedOutImageView: NSImageView?
    private var inventoryProgress: NSProgressIndicator?
    private var showsInventoryProgress = false

    func setInventoryProgress(visible: Bool, message: String?) {
        showsInventoryProgress = visible
        if visible, inventoryProgress == nil {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.isIndeterminate = true
            progress.isDisplayedWhenStopped = false
            progress.identifier = NSUserInterfaceItemIdentifier("RepositoryWorktreesInitialProgress")
            progress.setAccessibilityIdentifier("RepositoryWorktreesInitialProgress")
            progress.translatesAutoresizingMaskIntoConstraints = false
            addSubview(progress)
            NSLayoutConstraint.activate([
                progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                progress.centerYAnchor.constraint(equalTo: centerYAnchor),
                progress.widthAnchor.constraint(equalToConstant: 16),
                progress.heightAnchor.constraint(equalToConstant: 16),
            ])
            inventoryProgress = progress
        }
        inventoryProgress?.setAccessibilityLabel(message)
        inventoryProgress?.isHidden = !visible
        updateInventoryProgressAnimation()
    }

    private func updateInventoryProgressAnimation() {
        if showsInventoryProgress, window != nil {
            inventoryProgress?.startAnimation(nil)
        } else {
            inventoryProgress?.stopAnimation(nil)
        }
    }

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
        updateInventoryProgressAnimation()
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
