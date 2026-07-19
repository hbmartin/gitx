import AppKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

/// Objective-C callers are not visible to SwiftLint's analyzer.
@objc(PBPreferencesWindowLayoutPolicy)
final nonisolated class PreferencesWindowLayoutPolicy: NSObject { // swiftlint:disable:this unused_declaration
    @objc(minimumWidthForItemCount:)
    // swiftlint:disable:next unused_declaration
    static func minimumWidth(itemCount: Int) -> CGFloat {
        max(620, CGFloat(itemCount) * 104 + 28)
    }
}

@objc(PBDiffCommandOptions)
final nonisolated class DiffCommandOptions: NSObject { // swiftlint:disable:this unused_declaration
    @objc static var arguments: [String] {
        let algorithm = switch ApplicationSettings.diffAlgorithm {
        case .myers: "myers"
        case .minimal: "minimal"
        case .patience: "patience"
        case .histogram: "histogram"
        }
        return [
            "--diff-algorithm=\(algorithm)",
            "--unified=\(ApplicationSettings.diffContextLines)",
        ]
    }
}

private final class SettingsPaneView: NSView {
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "Settings")
    private let stack = NSStackView()

    init(title: String, detail: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 430))
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 760),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 430),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
        ])
        let heading = NSTextField(labelWithString: title)
        heading.font = .preferredFont(forTextStyle: .headline, options: [:])
        heading.setAccessibilityIdentifier("SettingsPaneHeading")
        stack.addArrangedSubview(heading)
        if let detail {
            let field = wrappingLabel(detail)
            field.textColor = .secondaryLabelColor
            stack.addArrangedSubview(field)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func addRow(_ title: String, control: NSView, help: String? = nil) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 180).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        stack.addArrangedSubview(row)
        if let help {
            let field = wrappingLabel(help)
            field.textColor = .secondaryLabelColor
            field.font = .preferredFont(forTextStyle: .footnote, options: [:])
            let spacer = NSView()
            spacer.widthAnchor.constraint(equalToConstant: 192).isActive = true
            let helpRow = NSStackView(views: [spacer, field])
            helpRow.orientation = .horizontal
            helpRow.alignment = .top
            stack.addArrangedSubview(helpRow)
        }
        resizeToFit()
    }

    func addCheckbox(_ title: String, state: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = state ? .on : .off
        stack.addArrangedSubview(button)
        resizeToFit()
        return button
    }

    func addSeparator() {
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 704).isActive = true
        stack.addArrangedSubview(separator)
        resizeToFit()
    }

    func addCustom(_ view: NSView) {
        stack.addArrangedSubview(view)
        resizeToFit()
    }

    private func wrappingLabel(_ string: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.maximumNumberOfLines = 3
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 690).isActive = true
        return label
    }

    private func resizeToFit() {
        layoutSubtreeIfNeeded()
        var size = frame.size
        size.width = max(760, stack.fittingSize.width + 56)
        size.height = max(430, stack.fittingSize.height + 48)
        setFrameSize(size)
    }

    @objc func openDispositionChanged(_ sender: NSPopUpButton) {
        ApplicationSettings.openDisposition = OpenDisposition(rawValue: sender.selectedTag()) ?? .followSystem
        logger.info("Open disposition changed")
    }

    @objc func restorePolicyChanged(_ sender: NSPopUpButton) {
        ApplicationSettings.restorePolicy = WindowRestorePolicy(rawValue: sender.selectedTag()) ?? .followSystem
        logger.info("Window restore policy changed")
    }

    @objc func changedOnlyChanged(_ sender: NSButton) {
        ApplicationSettings.changedFilesOnly = sender.state == .on
        NotificationCenter.default.post(name: .historyTreeSettingsDidChange, object: nil)
    }

    @objc func changedFilesSortChanged(_ sender: NSPopUpButton) {
        ApplicationSettings.changedFilesSort = ChangedFilesSortMode(rawValue: sender.selectedTag()) ?? .alphabetical
        NotificationCenter.default.post(name: .historyTreeSettingsDidChange, object: nil)
    }

    @objc func groupIncomingBranchCommitsChanged(_ sender: NSButton) {
        ApplicationSettings.groupIncomingBranchCommits = sender.state == .on
        NotificationCenter.default.post(name: .historyTraversalSettingsDidChange, object: nil)
        logger.info("History traversal setting changed")
    }

    @objc func branchSortChanged(_ sender: NSPopUpButton) {
        ApplicationSettings.branchSort = BranchSortMode(rawValue: sender.selectedTag()) ?? .alphabetical
        NotificationCenter.default.post(name: .branchSidebarSettingsDidChange, object: nil)
    }

    @objc func applicationIconChanged(_ sender: NSButton) {
        guard let style = ApplicationIconStyle(rawValue: sender.tag) else { return }
        for case let button as NSButton in sender.superview?.subviews ?? [] {
            button.state = button === sender ? .on : .off
        }
        ApplicationSettings.applicationIconStyle = style
        ApplicationIconController.applySelectedIcon()
        logger.info("Dock icon preference changed to \(style.displayName, privacy: .public)")
    }

    @objc func diffLayoutChanged(_ sender: NSPopUpButton) {
        ApplicationSettings.diffLayout = DiffLayout(rawValue: sender.selectedTag()) ?? .sideBySide
    }

    @objc func diffAlgorithmChanged(_ sender: NSPopUpButton) {
        ApplicationSettings.diffAlgorithm = DiffAlgorithm(rawValue: sender.selectedTag()) ?? .myers
    }

    @objc func syntaxThemeChanged(_ sender: NSPopUpButton) {
        ApplicationSettings.syntaxTheme = SyntaxTheme(rawValue: sender.selectedTag()) ?? .xcode
    }

    @objc func contextChanged(_ sender: NSStepper) {
        ApplicationSettings.diffContextLines = sender.integerValue
        (sender.nextKeyView as? NSTextField)?.integerValue = ApplicationSettings.diffContextLines
    }

    @objc func fontSizeChanged(_ sender: NSStepper) {
        ApplicationSettings.diffFontSize = sender.doubleValue
        (sender.nextKeyView as? NSTextField)?.doubleValue = ApplicationSettings.diffFontSize
    }

    @objc func fontChanged(_ sender: NSPopUpButton) {
        ApplicationSettings.diffFontName = sender.titleOfSelectedItem ?? ApplicationSettings.diffFontName
    }

    @objc func diffColorChanged(_ sender: NSColorWell) {
        switch sender.identifier?.rawValue {
        case "addedText": ApplicationSettings.addedTextColor = sender.color
        case "removedText": ApplicationSettings.removedTextColor = sender.color
        case "addedBackground": ApplicationSettings.addedBackgroundColor = sender.color
        case "removedBackground": ApplicationSettings.removedBackgroundColor = sender.color
        default: break
        }
    }

    @objc func terminalChanged(_ sender: NSPopUpButton) {
        ApplicationSettings.terminalBundleIdentifier = sender.selectedItem?.representedObject as? String
    }

    @objc func terminalCommandChanged(_ sender: NSTextField) {
        ApplicationSettings.terminalInitialCommand = sender.stringValue
    }

    @objc func customExecutableChanged(_ sender: NSTextField) {
        ApplicationSettings.customTerminalExecutable = sender.stringValue
    }

    @objc func customArgumentsChanged(_ sender: NSTextField) {
        ApplicationSettings.customTerminalArguments = sender.stringValue
    }

    @objc func chooseRaycastDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ApplicationSettings.raycastScriptsDirectory = url.path
        logger.info("Raycast scripts directory selected")
    }

    @objc func installRaycastScripts(_ sender: Any?) {
        IntegrationManager.shared.installRaycastScripts(presenting: window)
    }

    @objc func removeRaycastScripts(_ sender: Any?) {
        IntegrationManager.shared.removeRaycastScripts(presenting: window)
    }

    @objc func installCLITool(_ sender: Any?) {
        NSApp.sendAction(NSSelectorFromString("installCliTool:"), to: nil, from: sender)
    }
}

/// Objective-C callers are not visible to SwiftLint's analyzer.
@objc(PBSettingsViewFactory)
final class SettingsViewFactory: NSObject { // swiftlint:disable:this unused_declaration
    @objc(generalViewWithLegacyView:)
    // swiftlint:disable:next unused_declaration
    static func generalView(legacyView: NSView) -> NSView {
        let view = SettingsPaneView(
            title: "General",
            detail: "Choose the default repository browsing behavior. Repository-specific choices live in Repository Settings."
        )
        _ = view.addCheckbox(
            "Show only changed files in commit tree views",
            state: ApplicationSettings.changedFilesOnly,
            action: #selector(SettingsPaneView.changedOnlyChanged(_:))
        )
        let changedSort = popup(items: [
            ("Full Path", ChangedFilesSortMode.alphabetical.rawValue),
            ("Git Order", ChangedFilesSortMode.gitOrder.rawValue),
            ("Status, then Path", ChangedFilesSortMode.status.rawValue),
        ], selected: ApplicationSettings.changedFilesSort.rawValue)
        changedSort.target = view
        changedSort.action = #selector(SettingsPaneView.changedFilesSortChanged(_:))
        view.addRow("Changed-file order:", control: changedSort)
        _ = view.addCheckbox(
            "Group commits by branch",
            state: ApplicationSettings.groupIncomingBranchCommits,
            action: #selector(SettingsPaneView.groupIncomingBranchCommitsChanged(_:))
        )
        let branchSort = popup(items: [
            ("Alphabetical", BranchSortMode.alphabetical.rawValue),
            ("Most Recent Commit", BranchSortMode.recentCommit.rawValue),
        ], selected: ApplicationSettings.branchSort.rawValue)
        branchSort.target = view
        branchSort.action = #selector(SettingsPaneView.branchSortChanged(_:))
        view.addRow("Branch order:", control: branchSort)
        view.addSeparator()
        legacyView.autoresizingMask = [.width]
        view.addCustom(legacyView)
        return view
    }

    @objc static func dockIconView() -> NSView {
        let view = SettingsPaneView(
            title: "Dock Icon",
            detail: "Choose the robot face GitX shows in the Dock. Changes apply immediately and persist across launches."
        )
        let iconChoices = NSStackView()
        iconChoices.orientation = .horizontal
        iconChoices.alignment = .centerY
        iconChoices.spacing = 10
        iconChoices.setAccessibilityIdentifier("DockIconPicker")
        for style in ApplicationIconStyle.allCases {
            let button = NSButton(
                title: style.displayName,
                image: ApplicationIconController.image(for: style),
                target: view,
                action: #selector(SettingsPaneView.applicationIconChanged(_:))
            )
            button.tag = style.rawValue
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageAbove
            button.imageScaling = .scaleProportionallyDown
            button.state = style == ApplicationSettings.applicationIconStyle ? .on : .off
            button.toolTip = style.displayName
            button.setAccessibilityIdentifier("DockIcon.\(style.rawValue)")
            button.setAccessibilityLabel("\(style.displayName) Dock icon")
            button.widthAnchor.constraint(equalToConstant: 108).isActive = true
            button.heightAnchor.constraint(equalToConstant: 104).isActive = true
            iconChoices.addArrangedSubview(button)
        }
        view.addRow("Robot face:", control: iconChoices)
        return view
    }

    @objc static func windowsView() -> NSView {
        let view = SettingsPaneView(
            title: "Windows",
            detail: "These choices apply to File > Open, Open Recent, Finder, the command-line tool, Raycast, and submodules."
        )
        let open = popup(items: [
            ("Always New Window", OpenDisposition.alwaysNewWindow.rawValue),
            ("Follow macOS", OpenDisposition.followSystem.rawValue),
            ("Prefer Tab", OpenDisposition.preferTab.rawValue),
        ], selected: ApplicationSettings.openDisposition.rawValue)
        open.target = view
        open.action = #selector(SettingsPaneView.openDispositionChanged(_:))
        view.addRow("Open repositories:", control: open, help: "Hold Command to force a tab or Option to force a new window.")

        let restore = popup(items: [
            ("Always", WindowRestorePolicy.always.rawValue),
            ("Follow macOS", WindowRestorePolicy.followSystem.rawValue),
            ("Never", WindowRestorePolicy.never.rawValue),
        ], selected: ApplicationSettings.restorePolicy.rawValue)
        restore.target = view
        restore.action = #selector(SettingsPaneView.restorePolicyChanged(_:))
        view.addRow("Reopen last windows:", control: restore, help: "Missing repositories are skipped and removed from the saved session.")
        return view
    }

    @objc static func diffAndTextView() -> NSView {
        let view = SettingsPaneView(
            title: "Diff & Text",
            detail: "Side-by-side is the default. A repository window can temporarily override the layout from its diff toolbar."
        )
        let layout = popup(items: [
            ("Unified", DiffLayout.unified.rawValue),
            ("Side-by-Side", DiffLayout.sideBySide.rawValue),
        ], selected: ApplicationSettings.diffLayout.rawValue)
        layout.target = view
        layout.action = #selector(SettingsPaneView.diffLayoutChanged(_:))
        view.addRow("Default layout:", control: layout)

        let algorithm = popup(items: [
            ("Myers", DiffAlgorithm.myers.rawValue),
            ("Minimal", DiffAlgorithm.minimal.rawValue),
            ("Patience", DiffAlgorithm.patience.rawValue),
            ("Histogram", DiffAlgorithm.histogram.rawValue),
        ], selected: ApplicationSettings.diffAlgorithm.rawValue)
        algorithm.target = view
        algorithm.action = #selector(SettingsPaneView.diffAlgorithmChanged(_:))
        view.addRow("Algorithm:", control: algorithm)

        let theme = popup(items: [
            ("Xcode", SyntaxTheme.xcode.rawValue),
            ("GitHub", SyntaxTheme.github.rawValue),
            ("Plain", SyntaxTheme.plain.rawValue),
        ], selected: ApplicationSettings.syntaxTheme.rawValue)
        theme.target = view
        theme.action = #selector(SettingsPaneView.syntaxThemeChanged(_:))
        view.addRow("Syntax theme:", control: theme)

        let context = stepper(value: Double(ApplicationSettings.diffContextLines), minimum: 0, maximum: 20)
        context.target = view
        context.action = #selector(SettingsPaneView.contextChanged(_:))
        let contextField = NSTextField(labelWithString: "\(ApplicationSettings.diffContextLines) lines")
        context.nextKeyView = contextField
        view.addRow("Context:", control: NSStackView(views: [context, contextField]))

        let font = stepper(value: ApplicationSettings.diffFontSize, minimum: 9, maximum: 36)
        font.setAccessibilityIdentifier("DiffFontSizeStepper")
        font.target = view
        font.action = #selector(SettingsPaneView.fontSizeChanged(_:))
        let fontField = NSTextField(labelWithString: "\(Int(ApplicationSettings.diffFontSize)) pt")
        fontField.setAccessibilityIdentifier("DiffFontSizeValue")
        font.nextKeyView = fontField
        let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fontPopup.setAccessibilityIdentifier("DiffFontFamily")
        let fixedPitchFonts = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask)
        }
        fontPopup.addItems(withTitles: fixedPitchFonts)
        if fontPopup.item(withTitle: ApplicationSettings.diffFontName) == nil {
            fontPopup.addItem(withTitle: ApplicationSettings.diffFontName)
        }
        fontPopup.selectItem(withTitle: ApplicationSettings.diffFontName)
        fontPopup.target = view
        fontPopup.action = #selector(SettingsPaneView.fontChanged(_:))
        view.addRow("Diff font:", control: NSStackView(views: [fontPopup, font, fontField]))

        let colorStack = NSStackView(views: [
            colorWell(ApplicationSettings.addedTextColor, identifier: "addedText", target: view),
            NSTextField(labelWithString: "Added text"),
            colorWell(ApplicationSettings.addedBackgroundColor, identifier: "addedBackground", target: view),
            NSTextField(labelWithString: "Added background"),
        ])
        colorStack.spacing = 7
        view.addRow("Additions:", control: colorStack)
        let removedColorStack = NSStackView(views: [
            colorWell(ApplicationSettings.removedTextColor, identifier: "removedText", target: view),
            NSTextField(labelWithString: "Removed text"),
            colorWell(ApplicationSettings.removedBackgroundColor, identifier: "removedBackground", target: view),
            NSTextField(labelWithString: "Removed background"),
        ])
        removedColorStack.spacing = 7
        view.addRow("Deletions:", control: removedColorStack)
        return view
    }

    @objc static func terminalView() -> NSView {
        let view = SettingsPaneView(
            title: "Terminal",
            detail: "GitX always opens a new terminal window. Unavailable applications remain visible but disabled."
        )
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for terminal in TerminalApplication.all {
            popup.addItem(withTitle: terminal.name)
            popup.lastItem?.representedObject = terminal.bundleIdentifier
            popup.lastItem?.isEnabled = terminal.isInstalled
        }
        popup.addItem(withTitle: "Custom")
        popup.lastItem?.representedObject = "custom"
        let selected = ApplicationSettings.terminalBundleIdentifier
        popup.selectItem(at: popup.itemArray.firstIndex { ($0.representedObject as? String) == selected } ?? 0)
        popup.target = view
        popup.action = #selector(SettingsPaneView.terminalChanged(_:))
        view.addRow("Default application:", control: popup, help: "GitX asks on first use if no default has been chosen.")

        // sendsActionOnEndEditing so typing a value and clicking away (rather than pressing Return) still
        // commits the edit instead of silently discarding it.
        let command = NSTextField(string: ApplicationSettings.terminalInitialCommand)
        command.target = view
        command.action = #selector(SettingsPaneView.terminalCommandChanged(_:))
        command.cell?.sendsActionOnEndEditing = true
        command.widthAnchor.constraint(equalToConstant: 360).isActive = true
        view.addRow("Initial command:", control: command, help: "Leave empty to open only the repository directory.")

        let executable = NSTextField(string: ApplicationSettings.customTerminalExecutable)
        executable.target = view
        executable.action = #selector(SettingsPaneView.customExecutableChanged(_:))
        executable.cell?.sendsActionOnEndEditing = true
        executable.widthAnchor.constraint(equalToConstant: 360).isActive = true
        view.addRow("Custom executable:", control: executable)
        let arguments = NSTextField(string: ApplicationSettings.customTerminalArguments)
        arguments.target = view
        arguments.action = #selector(SettingsPaneView.customArgumentsChanged(_:))
        arguments.cell?.sendsActionOnEndEditing = true
        arguments.widthAnchor.constraint(equalToConstant: 360).isActive = true
        view.addRow("Custom arguments:", control: arguments, help: "Use {directory} and optionally {command}. Arguments are launched directly, never through a shell.")
        return view
    }

    @objc static func integrationView() -> NSView {
        let view = SettingsPaneView(
            title: "Integration",
            detail: "Manage the bundled gitx command-line tool and Raycast Script Commands from one place."
        )
        let cli = NSButton(title: "Install or Update Command-Line Tool…", target: view, action: #selector(SettingsPaneView.installCLITool(_:)))
        view.addRow("Command line:", control: cli)
        view.addSeparator()
        let choose = NSButton(title: "Choose Raycast Scripts Folder…", target: view, action: #selector(SettingsPaneView.chooseRaycastDirectory(_:)))
        view.addRow("Scripts folder:", control: choose, help: ApplicationSettings.raycastScriptsDirectory.isEmpty ? "No folder selected." : ApplicationSettings.raycastScriptsDirectory)
        let install = NSButton(title: "Install / Update", target: view, action: #selector(SettingsPaneView.installRaycastScripts(_:)))
        let remove = NSButton(title: "Remove", target: view, action: #selector(SettingsPaneView.removeRaycastScripts(_:)))
        view.addRow("Raycast commands:", control: NSStackView(views: [install, remove]), help: "Installs Open Repository Path, Open Frontmost Finder Folder, Show GitX Recents, and Start Clone.")
        return view
    }

    private static func popup(items: [(String, Int)], selected: Int) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (title, tag) in items {
            popup.addItem(withTitle: title)
            popup.lastItem?.tag = tag
        }
        popup.selectItem(withTag: selected)
        return popup
    }

    private static func stepper(value: Double, minimum: Double, maximum: Double) -> NSStepper {
        let stepper = NSStepper()
        stepper.minValue = minimum
        stepper.maxValue = maximum
        stepper.doubleValue = value
        stepper.increment = 1
        return stepper
    }

    private static func colorWell(_ color: NSColor, identifier: String, target: SettingsPaneView) -> NSColorWell {
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        well.color = color
        well.identifier = NSUserInterfaceItemIdentifier(identifier)
        well.target = target
        well.action = #selector(SettingsPaneView.diffColorChanged(_:))
        return well
    }
}

extension Notification.Name {
    nonisolated static let branchSidebarSettingsDidChange = Notification.Name("PBBranchSidebarSettingsDidChangeNotification")
    nonisolated static let diffTextTypographyDidChange = Notification.Name(
        ApplicationSettings.diffTextTypographyDidChangeNotificationName
    )
    nonisolated static let historyTraversalSettingsDidChange = Notification.Name("PBHistoryTraversalSettingsDidChangeNotification")
    nonisolated static let historyTreeSettingsDidChange = Notification.Name("PBHistoryTreeSettingsDidChangeNotification")
}
