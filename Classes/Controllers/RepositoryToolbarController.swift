import AppKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

/// Objective-C callers are not visible to SwiftLint's analyzer.
@objc(PBRepositoryToolbarController)
final class RepositoryToolbarController: NSObject, NSToolbarDelegate { // swiftlint:disable:this unused_declaration
    private enum Mode {
        case history
        case commit

        var toolbarIdentifier: NSToolbar.Identifier {
            switch self {
            case .history: "GitX.Repository.HistoryToolbar"
            case .commit: "GitX.Repository.CommitToolbar"
            }
        }
    }

    private enum Item {
        static let history = NSToolbarItem.Identifier("GitX.Toolbar.History")
        static let commit = NSToolbarItem.Identifier("GitX.Toolbar.Commit")
        static let fetch = NSToolbarItem.Identifier("GitX.Toolbar.Fetch")
        static let pull = NSToolbarItem.Identifier("GitX.Toolbar.Pull")
        static let push = NSToolbarItem.Identifier("GitX.Toolbar.Push")
        static let refreshStatus = NSToolbarItem.Identifier("GitX.Toolbar.RefreshStatus")
        static let viewRemote = NSToolbarItem.Identifier("GitX.Toolbar.ViewRemote")
        static let reveal = NSToolbarItem.Identifier("GitX.Toolbar.Reveal")
        static let terminal = NSToolbarItem.Identifier("GitX.Toolbar.Terminal")
        static let repositorySettings = NSToolbarItem.Identifier("GitX.Toolbar.RepositorySettings")
        static let addRemote = NSToolbarItem.Identifier("GitX.Toolbar.AddRemote")
        static let createBranch = NSToolbarItem.Identifier("GitX.Toolbar.CreateBranch")
        static let createTag = NSToolbarItem.Identifier("GitX.Toolbar.CreateTag")
        static let jump = NSToolbarItem.Identifier("GitX.Toolbar.Jump")
        static let actions = NSToolbarItem.Identifier("GitX.Toolbar.Actions")
    }

    private weak var windowController: PBGitWindowController?
    private var mode: Mode = .history
    private weak var statusLabel: NSTextField?
    private weak var statusSpinner: NSProgressIndicator?
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryToolbar")

    @objc(initWithWindowController:)
    init(windowController: PBGitWindowController) {
        self.windowController = windowController
        super.init()
    }

    @objc func install() {
        installToolbar(for: .history)
    }

    @objc(setHistoryMode:)
    // swiftlint:disable:next unused_declaration
    func setHistoryMode(_ historyMode: Bool) {
        let requested: Mode = historyMode ? .history : .commit
        guard requested != mode || windowController?.window?.toolbar == nil else { return }
        installToolbar(for: requested)
    }

    @objc(updateWithStatus:busy:baseWindowTitle:)
    // swiftlint:disable:next unused_declaration
    func update(status: String, busy: Bool, baseWindowTitle: String) {
        statusLabel?.stringValue = status.isEmpty ? "Ready" : status
        if busy {
            statusSpinner?.startAnimation(nil)
            statusSpinner?.isHidden = false
        } else {
            statusSpinner?.stopAnimation(nil)
            statusSpinner?.isHidden = true
        }
        if let window = windowController?.window {
            window.title = status.isEmpty ? baseWindowTitle : "\(baseWindowTitle) — \(status)"
        }
    }

    private func installToolbar(for mode: Mode) {
        guard let window = windowController?.window else { return }
        self.mode = mode
        let toolbar = NSToolbar(identifier: mode.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconAndLabel
        toolbar.sizeMode = .regular
        window.toolbar = toolbar
        window.toolbarStyle = .expanded
        logger.info("Installed repository toolbar for primary mode")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        switch mode {
        case .history:
            [
                Item.commit,
                .flexibleSpace,
                Item.actions,
                Item.addRemote,
                Item.fetch,
                Item.pull,
                Item.push,
                .flexibleSpace,
                Item.jump,
                Item.viewRemote,
                Item.reveal,
                Item.terminal,
                Item.refreshStatus,
                Item.repositorySettings,
            ]
        case .commit:
            [
                Item.history,
                .flexibleSpace,
                Item.refreshStatus,
                Item.reveal,
                Item.terminal,
                Item.repositorySettings,
            ]
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Item.history,
            Item.commit,
            Item.fetch,
            Item.pull,
            Item.push,
            Item.refreshStatus,
            Item.viewRemote,
            Item.reveal,
            Item.terminal,
            Item.repositorySettings,
            Item.addRemote,
            Item.createBranch,
            Item.createTag,
            Item.jump,
            Item.actions,
            .space,
            .flexibleSpace,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == Item.refreshStatus {
            return statusItem(identifier: itemIdentifier)
        }
        if itemIdentifier == Item.actions {
            return actionsItem(identifier: itemIdentifier)
        }
        let descriptor = descriptor(for: itemIdentifier)
        guard let descriptor else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = descriptor.label
        item.paletteLabel = descriptor.label
        item.toolTip = descriptor.toolTip
        item.image = ToolbarIconFactory.image(
            symbol: descriptor.symbol,
            topColor: descriptor.topColor,
            bottomColor: descriptor.bottomColor
        )
        item.target = windowController
        item.action = descriptor.action
        return item
    }

    private func actionsItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = "Actions"
        item.paletteLabel = "Selected Reference Actions"
        item.toolTip = "Actions for the selected branch, tag, remote, or submodule"
        item.image = ToolbarIconFactory.image(
            symbol: "ellipsis.circle",
            topColor: NSColor(calibratedWhite: 0.82, alpha: 1),
            bottomColor: NSColor(calibratedWhite: 0.43, alpha: 1)
        )
        let menu = NSMenu(title: "Selected Reference Actions")
        menu.delegate = windowController?.sidebarViewController
        item.menu = menu
        return item
    }

    private func statusItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Refresh"
        item.paletteLabel = "Refresh & Status"
        item.toolTip = "Refresh the current view and show repository activity"

        let refresh = NSButton(
            image: ToolbarIconFactory.image(
                symbol: "arrow.clockwise",
                topColor: NSColor(calibratedRed: 0.30, green: 0.68, blue: 0.98, alpha: 1),
                bottomColor: NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.74, alpha: 1)
            ),
            target: windowController,
            action: #selector(PBGitWindowController.refresh(_:))
        )
        refresh.isBordered = false
        refresh.toolTip = "Refresh"
        refresh.setAccessibilityLabel("Refresh")

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true

        let label = NSTextField(labelWithString: "Ready")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true

        let view = NSStackView(views: [refresh, spinner, label])
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 5
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 118).isActive = true
        view.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        item.view = view
        statusLabel = label
        statusSpinner = spinner
        return item
    }

    private struct Descriptor {
        let label: String
        let toolTip: String
        let symbol: String
        let action: Selector
        let topColor: NSColor
        let bottomColor: NSColor
    }

    private func descriptor(for identifier: NSToolbarItem.Identifier) -> Descriptor? {
        let blueTop = NSColor(calibratedRed: 0.43, green: 0.72, blue: 0.96, alpha: 1)
        let blueBottom = NSColor(calibratedRed: 0.12, green: 0.36, blue: 0.70, alpha: 1)
        let greenTop = NSColor(calibratedRed: 0.49, green: 0.82, blue: 0.45, alpha: 1)
        let greenBottom = NSColor(calibratedRed: 0.16, green: 0.48, blue: 0.18, alpha: 1)
        let orangeTop = NSColor(calibratedRed: 1.00, green: 0.73, blue: 0.33, alpha: 1)
        let orangeBottom = NSColor(calibratedRed: 0.75, green: 0.34, blue: 0.08, alpha: 1)
        let grayTop = NSColor(calibratedWhite: 0.82, alpha: 1)
        let grayBottom = NSColor(calibratedWhite: 0.43, alpha: 1)

        switch identifier {
        case Item.history:
            return Descriptor(label: "History", toolTip: "Show repository history", symbol: "clock.arrow.circlepath", action: #selector(PBGitWindowController.showHistoryView(_:)), topColor: blueTop, bottomColor: blueBottom)
        case Item.commit:
            return Descriptor(label: "Commit", toolTip: "Show the commit view", symbol: "checkmark.circle", action: #selector(PBGitWindowController.showCommitView(_:)), topColor: greenTop, bottomColor: greenBottom)
        case Item.fetch:
            return Descriptor(label: "Fetch", toolTip: "Fetch all remotes", symbol: "arrow.down", action: NSSelectorFromString("toolbarFetch:"), topColor: blueTop, bottomColor: blueBottom)
        case Item.pull:
            return Descriptor(label: "Pull", toolTip: "Pull the checked-out branch", symbol: "arrow.down.to.line", action: NSSelectorFromString("toolbarPull:"), topColor: greenTop, bottomColor: greenBottom)
        case Item.push:
            return Descriptor(label: "Push", toolTip: "Push the checked-out branch", symbol: "arrow.up.to.line", action: NSSelectorFromString("toolbarPush:"), topColor: orangeTop, bottomColor: orangeBottom)
        case Item.viewRemote:
            return Descriptor(label: "View Remote", toolTip: "Open the checked-out branch on its Git host", symbol: "safari", action: NSSelectorFromString("viewRemote:"), topColor: blueTop, bottomColor: blueBottom)
        case Item.reveal:
            return Descriptor(label: "Show in Finder", toolTip: "Reveal the repository in Finder", symbol: "folder", action: #selector(PBGitWindowController.revealInFinder(_:)), topColor: blueTop, bottomColor: blueBottom)
        case Item.terminal:
            return Descriptor(label: "Terminal", toolTip: "Open the repository in the configured terminal", symbol: "terminal", action: #selector(PBGitWindowController.openInTerminal(_:)), topColor: grayTop, bottomColor: grayBottom)
        case Item.repositorySettings:
            return Descriptor(label: "Repo Settings", toolTip: "Open settings for this repository", symbol: "gearshape", action: #selector(PBGitWindowController.showRepositorySettings(_:)), topColor: grayTop, bottomColor: grayBottom)
        case Item.addRemote:
            return Descriptor(label: "Add Remote", toolTip: "Add a repository remote", symbol: "network.badge.shield.half.filled", action: #selector(PBGitWindowController.addRemote(_:)), topColor: blueTop, bottomColor: blueBottom)
        case Item.createBranch:
            return Descriptor(label: "New Branch", toolTip: "Create a branch", symbol: "arrow.triangle.branch", action: #selector(PBGitWindowController.createBranch(_:)), topColor: greenTop, bottomColor: greenBottom)
        case Item.createTag:
            return Descriptor(label: "New Tag", toolTip: "Create a tag", symbol: "tag", action: #selector(PBGitWindowController.createTag(_:)), topColor: orangeTop, bottomColor: orangeBottom)
        case Item.jump:
            return Descriptor(label: "Current Branch", toolTip: "Jump to the checked-out branch", symbol: "scope", action: #selector(PBGitWindowController.jumpToCheckedOutBranch(_:)), topColor: blueTop, bottomColor: blueBottom)
        default:
            return nil
        }
    }
}

private enum ToolbarIconFactory {
    static func image(symbol: String, topColor: NSColor, bottomColor: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 28), flipped: false) { rect in
            let background = rect.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6)
            NSGradient(starting: topColor, ending: bottomColor)?.draw(in: path, angle: -90)
            NSColor(calibratedWhite: 0.15, alpha: 0.45).setStroke()
            path.lineWidth = 0.7
            path.stroke()
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
            {
                let glyphRect = NSRect(x: 7, y: 7, width: 14, height: 14)
                NSColor.white.set()
                glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 0.95)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
