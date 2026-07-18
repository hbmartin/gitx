import AppKit
import CryptoKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

@objc(PBOpenDisposition)
enum OpenDisposition: Int {
    case alwaysNewWindow
    case followSystem
    case preferTab
}

@objc(PBWindowRestorePolicy)
enum WindowRestorePolicy: Int {
    case always
    case followSystem
    case never
}

@objc(PBDiffLayout)
enum DiffLayout: Int {
    case unified
    case sideBySide
}

@objc(PBDiffAlgorithm)
enum DiffAlgorithm: Int {
    case myers
    case minimal
    case patience
    case histogram
}

@objc(PBSyntaxTheme)
enum SyntaxTheme: Int {
    case xcode
    case github
    case plain
}

@objc(PBBranchSortMode)
enum BranchSortMode: Int {
    case alphabetical
    case recentCommit
}

@objc(PBChangedFilesSortMode)
enum ChangedFilesSortMode: Int {
    case alphabetical
    case gitOrder
    case status
}

@objc(PBApplicationSettings)
final nonisolated class ApplicationSettings: NSObject {
    private enum Key {
        static let openDisposition = "PBOpenDisposition"
        static let restorePolicy = "PBWindowRestorePolicy"
        static let changedFilesOnly = "PBHistoryChangedFilesOnly"
        static let changedFilesSort = "PBHistoryChangedFilesSort"
        static let groupIncomingBranchCommits = "PBHistoryGroupIncomingBranchCommits"
        static let branchSort = "PBBranchSortMode"
        static let diffLayout = "PBDiffLayout"
        static let diffAlgorithm = "PBDiffAlgorithm"
        static let diffContext = "PBDiffContextLines"
        static let syntaxTheme = "PBSyntaxTheme"
        static let diffFontName = "PBDiffFontName"
        static let diffFontSize = "PBDiffFontSize"
        static let addedTextColor = "PBDiffAddedTextColor"
        static let removedTextColor = "PBDiffRemovedTextColor"
        static let addedBackgroundColor = "PBDiffAddedBackgroundColor"
        static let removedBackgroundColor = "PBDiffRemovedBackgroundColor"
        static let terminalBundleIdentifier = "PBTerminalBundleIdentifier"
        static let terminalInitialCommand = "PBTerminalInitialCommand"
        static let customTerminalExecutable = "PBCustomTerminalExecutable"
        static let customTerminalArguments = "PBCustomTerminalArguments"
        static let raycastScriptsDirectory = "PBRaycastScriptsDirectory"
        static let patchExportMode = "PBPatchExportMode"
    }

    // swift6-safety-justification: UserDefaults is internally synchronized; Swift 6 does not yet model that guarantee.
    private nonisolated(unsafe) static let defaults = UserDefaults.standard

    @objc static var openDisposition: OpenDisposition {
        get { enumValue(Key.openDisposition, fallback: .followSystem) }
        set { defaults.set(newValue.rawValue, forKey: Key.openDisposition) }
    }

    @objc static var restorePolicy: WindowRestorePolicy {
        get { enumValue(Key.restorePolicy, fallback: .followSystem) }
        set { defaults.set(newValue.rawValue, forKey: Key.restorePolicy) }
    }

    @objc static var changedFilesOnly: Bool {
        get {
            guard defaults.object(forKey: Key.changedFilesOnly) != nil else { return true }
            return defaults.bool(forKey: Key.changedFilesOnly)
        }
        set { defaults.set(newValue, forKey: Key.changedFilesOnly) }
    }

    @objc static var changedFilesSort: ChangedFilesSortMode {
        get { enumValue(Key.changedFilesSort, fallback: .alphabetical) }
        set { defaults.set(newValue.rawValue, forKey: Key.changedFilesSort) }
    }

    @objc static var groupIncomingBranchCommits: Bool {
        get {
            guard defaults.object(forKey: Key.groupIncomingBranchCommits) != nil else { return true }
            return defaults.bool(forKey: Key.groupIncomingBranchCommits)
        }
        set { defaults.set(newValue, forKey: Key.groupIncomingBranchCommits) }
    }

    @objc static var branchSort: BranchSortMode {
        get { enumValue(Key.branchSort, fallback: .alphabetical) }
        set { defaults.set(newValue.rawValue, forKey: Key.branchSort) }
    }

    @objc static var diffLayout: DiffLayout {
        get { enumValue(Key.diffLayout, fallback: .sideBySide) }
        set { defaults.set(newValue.rawValue, forKey: Key.diffLayout) }
    }

    @objc static var diffAlgorithm: DiffAlgorithm {
        get { enumValue(Key.diffAlgorithm, fallback: .myers) }
        set { defaults.set(newValue.rawValue, forKey: Key.diffAlgorithm) }
    }

    @objc static var diffContextLines: Int {
        get {
            guard defaults.object(forKey: Key.diffContext) != nil else { return 3 }
            return min(20, max(0, defaults.integer(forKey: Key.diffContext)))
        }
        set { defaults.set(min(20, max(0, newValue)), forKey: Key.diffContext) }
    }

    @objc static var syntaxTheme: SyntaxTheme {
        get { enumValue(Key.syntaxTheme, fallback: .xcode) }
        set { defaults.set(newValue.rawValue, forKey: Key.syntaxTheme) }
    }

    @objc static var diffFontName: String {
        get { defaults.string(forKey: Key.diffFontName) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName }
        set { defaults.set(newValue, forKey: Key.diffFontName) }
    }

    @objc static var diffFontSize: Double {
        get {
            guard defaults.object(forKey: Key.diffFontSize) != nil else { return 12 }
            return min(36, max(9, defaults.double(forKey: Key.diffFontSize)))
        }
        set { defaults.set(min(36, max(9, newValue)), forKey: Key.diffFontSize) }
    }

    @objc static var addedTextColor: NSColor {
        get { color(Key.addedTextColor, fallback: NSColor(red: 0.08, green: 0.46, blue: 0.18, alpha: 1)) }
        set { setColor(newValue, key: Key.addedTextColor) }
    }

    @objc static var removedTextColor: NSColor {
        get { color(Key.removedTextColor, fallback: NSColor(red: 0.72, green: 0.12, blue: 0.13, alpha: 1)) }
        set { setColor(newValue, key: Key.removedTextColor) }
    }

    @objc static var addedBackgroundColor: NSColor {
        get { color(Key.addedBackgroundColor, fallback: NSColor(red: 0.20, green: 0.70, blue: 0.30, alpha: 0.13)) }
        set { setColor(newValue, key: Key.addedBackgroundColor) }
    }

    @objc static var removedBackgroundColor: NSColor {
        get { color(Key.removedBackgroundColor, fallback: NSColor(red: 0.90, green: 0.20, blue: 0.20, alpha: 0.12)) }
        set { setColor(newValue, key: Key.removedBackgroundColor) }
    }

    @objc static var terminalBundleIdentifier: String? {
        get { defaults.string(forKey: Key.terminalBundleIdentifier) }
        set { defaults.set(newValue, forKey: Key.terminalBundleIdentifier) }
    }

    @objc static var terminalInitialCommand: String {
        get {
            guard defaults.object(forKey: Key.terminalInitialCommand) != nil else { return "git status" }
            return defaults.string(forKey: Key.terminalInitialCommand) ?? ""
        }
        set { defaults.set(newValue, forKey: Key.terminalInitialCommand) }
    }

    @objc static var customTerminalExecutable: String {
        get { defaults.string(forKey: Key.customTerminalExecutable) ?? "" }
        set { defaults.set(newValue, forKey: Key.customTerminalExecutable) }
    }

    @objc static var customTerminalArguments: String {
        get { defaults.string(forKey: Key.customTerminalArguments) ?? "--working-directory {directory}" }
        set { defaults.set(newValue, forKey: Key.customTerminalArguments) }
    }

    @objc static var raycastScriptsDirectory: String {
        get { defaults.string(forKey: Key.raycastScriptsDirectory) ?? "" }
        set { defaults.set(newValue, forKey: Key.raycastScriptsDirectory) }
    }

    @objc static var patchExportMode: Int {
        get { defaults.integer(forKey: Key.patchExportMode) }
        set { defaults.set(newValue, forKey: Key.patchExportMode) }
    }

    private static func enumValue<Value: RawRepresentable>(
        _ key: String,
        fallback: Value
    ) -> Value where Value.RawValue == Int {
        guard defaults.object(forKey: key) != nil,
              let value = Value(rawValue: defaults.integer(forKey: key)) else { return fallback }
        return value
    }

    private static func color(_ key: String, fallback: NSColor) -> NSColor {
        guard let data = defaults.data(forKey: key),
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
        else { return fallback }
        return color
    }

    private static func setColor(_ color: NSColor, key: String) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) {
            defaults.set(data, forKey: key)
        }
    }
}

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
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
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
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
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
        font.target = view
        font.action = #selector(SettingsPaneView.fontSizeChanged(_:))
        let fontField = NSTextField(labelWithString: "\(Int(ApplicationSettings.diffFontSize)) pt")
        font.nextKeyView = fontField
        let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
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

        let command = NSTextField(string: ApplicationSettings.terminalInitialCommand)
        command.target = view
        command.action = #selector(SettingsPaneView.terminalCommandChanged(_:))
        command.widthAnchor.constraint(equalToConstant: 360).isActive = true
        view.addRow("Initial command:", control: command, help: "Leave empty to open only the repository directory.")

        let executable = NSTextField(string: ApplicationSettings.customTerminalExecutable)
        executable.target = view
        executable.action = #selector(SettingsPaneView.customExecutableChanged(_:))
        executable.widthAnchor.constraint(equalToConstant: 360).isActive = true
        view.addRow("Custom executable:", control: executable)
        let arguments = NSTextField(string: ApplicationSettings.customTerminalArguments)
        arguments.target = view
        arguments.action = #selector(SettingsPaneView.customArgumentsChanged(_:))
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
    static let branchSidebarSettingsDidChange = Notification.Name("PBBranchSidebarSettingsDidChangeNotification")
    static let historyTraversalSettingsDidChange = Notification.Name("PBHistoryTraversalSettingsDidChangeNotification")
    static let historyTreeSettingsDidChange = Notification.Name("PBHistoryTreeSettingsDidChangeNotification")
}

struct TerminalApplication {
    let name: String
    let bundleIdentifier: String

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    static let all = [
        TerminalApplication(name: "Terminal", bundleIdentifier: "com.apple.Terminal"),
        TerminalApplication(name: "iTerm2", bundleIdentifier: "com.googlecode.iterm2"),
        TerminalApplication(name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty"),
        TerminalApplication(name: "Warp", bundleIdentifier: "dev.warp.Warp-Stable"),
        TerminalApplication(name: "WezTerm", bundleIdentifier: "com.github.wez.wezterm"),
        TerminalApplication(name: "kitty", bundleIdentifier: "net.kovidgoyal.kitty"),
        TerminalApplication(name: "Alacritty", bundleIdentifier: "org.alacritty"),
    ]
}

@objc(PBTerminalLauncher)
final class TerminalLauncher: NSObject {
    @objc static let shared = TerminalLauncher()
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "TerminalLauncher")

    @objc(openDirectory:presentingWindow:)
    func open(directory: URL, presenting window: NSWindow?) {
        guard let identifier = configuredIdentifier(presenting: window) else { return }
        do {
            if identifier == "custom" {
                try launchCustom(directory: directory)
            } else if identifier == "com.apple.Terminal" || identifier == "com.googlecode.iterm2" {
                UserDefaults.standard.set(identifier, forKey: "PBTerminalHandler")
                PBTerminalUtil.runCommand(ApplicationSettings.terminalInitialCommand, inDirectory: directory)
            } else {
                try launchApplication(identifier: identifier, directory: directory)
            }
            logger.info("Opened terminal for repository")
        } catch {
            let alert = NSAlert(error: error)
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    private func configuredIdentifier(presenting window: NSWindow?) -> String? {
        if let identifier = ApplicationSettings.terminalBundleIdentifier, !identifier.isEmpty {
            return identifier
        }
        let available = TerminalApplication.all.filter(\.isInstalled)
        let alert = NSAlert()
        alert.messageText = "Choose a Terminal Application"
        alert.informativeText = "GitX will remember this choice. You can change it later in Settings."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        for terminal in available {
            popup.addItem(withTitle: terminal.name)
            popup.lastItem?.representedObject = terminal.bundleIdentifier
        }
        popup.addItem(withTitle: "Custom")
        popup.lastItem?.representedObject = "custom"
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let identifier = popup.selectedItem?.representedObject as? String else { return nil }
        ApplicationSettings.terminalBundleIdentifier = identifier
        return identifier
    }

    private func launchApplication(identifier: String, directory: URL) throws {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            throw TerminalLaunchError.applicationUnavailable(identifier)
        }
        let command = ApplicationSettings.terminalInitialCommand
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.activates = true
        configuration.arguments = launchArguments(
            identifier: identifier,
            directory: directory.path,
            command: command
        )
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            if let error {
                self.logger.error("Terminal launch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @objc(launchArgumentsForIdentifier:directory:command:)
    func launchArguments(identifier: String, directory: String, command: String) -> [String] {
        switch identifier {
        case "com.mitchellh.ghostty":
            ["--working-directory=\(directory)"] + commandArguments(command)
        case "dev.warp.Warp-Stable":
            ["--new-window", "--cwd", directory] + commandArguments(command)
        case "com.github.wez.wezterm":
            ["start", "--cwd", directory, "--always-new-process"] + commandArguments(command)
        case "net.kovidgoyal.kitty":
            ["--directory", directory] + commandArguments(command)
        case "org.alacritty":
            ["--working-directory", directory] + commandArguments(command)
        default:
            []
        }
    }

    @objc(commandArguments:)
    func commandArguments(_ command: String) -> [String] {
        guard !command.isEmpty else { return [] }
        return ["-e", "/bin/zsh", "-lc", command]
    }

    private func launchCustom(directory: URL) throws {
        let executable = ApplicationSettings.customTerminalExecutable
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw TerminalLaunchError.invalidCustomExecutable
        }
        let command = ApplicationSettings.terminalInitialCommand
        let replaced = ApplicationSettings.customTerminalArguments
            .replacingOccurrences(of: "{directory}", with: directory.path)
            .replacingOccurrences(of: "{command}", with: command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = argumentTokens(replaced)
        process.currentDirectoryURL = directory
        try process.run()
    }

    @objc(argumentTokens:)
    func argumentTokens(_ string: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in string {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if quote != nil {
                if character == quote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if escaped {
            current.append("\\")
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}

private enum TerminalLaunchError: LocalizedError {
    case applicationUnavailable(String)
    case invalidCustomExecutable

    var errorDescription: String? {
        switch self {
        case let .applicationUnavailable(identifier):
            "The configured terminal application is not installed (\(identifier))."
        case .invalidCustomExecutable:
            "Choose an absolute path to an executable terminal launcher in Settings."
        }
    }
}

@objc(PBIntegrationManager)
final class IntegrationManager: NSObject {
    @objc static let shared = IntegrationManager()
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "Integration")
    private let managedPrefix = "gitx-raycast-"

    @objc func installRaycastScripts(presenting window: NSWindow?) {
        guard let directory = scriptsDirectory(presenting: window) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for script in raycastScripts {
                let destination = directory.appendingPathComponent(managedPrefix + script.filename)
                if FileManager.default.fileExists(atPath: destination.path),
                   let existing = try? String(contentsOf: destination, encoding: .utf8),
                   existing != script.contents,
                   !hasValidManagedChecksum(existing)
                {
                    let alert = NSAlert()
                    alert.messageText = "Replace Modified Raycast Script?"
                    alert.informativeText = destination.lastPathComponent
                    alert.addButton(withTitle: "Replace Modified")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                try script.contents.write(to: destination, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
            logger.info("Installed managed Raycast commands")
            present(title: "Raycast Commands Installed", message: "Four GitX commands are ready in Raycast.", window: window)
        } catch {
            present(error: error, window: window)
        }
    }

    @objc func removeRaycastScripts(presenting window: NSWindow?) {
        guard let directory = scriptsDirectory(presenting: window, promptIfMissing: false) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.lastPathComponent.hasPrefix(managedPrefix) {
                try FileManager.default.removeItem(at: file)
            }
            logger.info("Removed managed Raycast commands")
            present(title: "Raycast Commands Removed", message: "GitX left other scripts unchanged.", window: window)
        } catch {
            present(error: error, window: window)
        }
    }

    private func scriptsDirectory(presenting window: NSWindow?, promptIfMissing: Bool = true) -> URL? {
        if !ApplicationSettings.raycastScriptsDirectory.isEmpty {
            return URL(fileURLWithPath: ApplicationSettings.raycastScriptsDirectory, isDirectory: true)
        }
        guard promptIfMissing else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        let response = window.map { _ in panel.runModal() } ?? panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        ApplicationSettings.raycastScriptsDirectory = url.path
        return url
    }

    private var raycastScripts: [(filename: String, contents: String)] {
        let appLookup = "APP=$(mdfind \\\"kMDItemCFBundleIdentifier == 'net.phere.GitX'\\\" | head -1)"
        let header = "#!/bin/zsh\n# GitX managed Raycast command v1\n# @raycast.schemaVersion 1\n# @raycast.mode silent\n"
        return [
            ("open-repository.sh", header + "# @raycast.title Open Repository Path in GitX\n# @raycast.argument1 { \\\"type\\\": \\\"text\\\", \\\"placeholder\\\": \\\"Repository path\\\" }\n\(appLookup)\n\\\"$APP/Contents/Resources/gitx\\\" \\\"$1\\\"\n"),
            ("open-finder.sh", header + "# @raycast.title Open Frontmost Finder Folder in GitX\n\(appLookup)\nDIR=$(osascript -e 'tell application \\\"Finder\\\" to POSIX path of (target of front window as alias)')\n\\\"$APP/Contents/Resources/gitx\\\" \\\"$DIR\\\"\n"),
            ("show-recents.sh", header + "# @raycast.title Show GitX Recents\nopen -b net.phere.GitX --args --welcome\n"),
            ("start-clone.sh", header + "# @raycast.title Start GitX Clone\nopen -b net.phere.GitX --args --clone\n"),
        ].map { ($0.0, managedScript($0.1)) }
    }

    private func managedScript(_ body: String) -> String {
        let checksum = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        let lines = body.components(separatedBy: "\n")
        guard !lines.isEmpty else { return body }
        return ([lines[0], "# GitX checksum: \(checksum)"] + lines.dropFirst()).joined(separator: "\n")
    }

    private func hasValidManagedChecksum(_ script: String) -> Bool {
        let lines = script.components(separatedBy: "\n")
        guard lines.count > 2, lines[1].hasPrefix("# GitX checksum: ") else { return false }
        let recorded = String(lines[1].dropFirst("# GitX checksum: ".count))
        let body = ([lines[0]] + lines.dropFirst(2)).joined(separator: "\n")
        let actual = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        return recorded == actual
    }

    private func present(title: String, message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func present(error: Error, window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
