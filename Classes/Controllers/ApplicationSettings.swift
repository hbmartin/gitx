import AppKit
import GitXCore

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
    @objc static let diffTextTypographyDidChangeNotificationName =
        "PBDiffTextTypographyDidChangeNotification"

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

    private static var defaults: UserDefaults {
        ApplicationComposition.shared.applicationPreferences.userDefaults
    }

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
            return ApplicationPreferencePolicy.diffContextLines(defaults.integer(forKey: Key.diffContext))
        }
        set { defaults.set(ApplicationPreferencePolicy.diffContextLines(newValue), forKey: Key.diffContext) }
    }

    @objc static var syntaxTheme: SyntaxTheme {
        get { enumValue(Key.syntaxTheme, fallback: .xcode) }
        set { defaults.set(newValue.rawValue, forKey: Key.syntaxTheme) }
    }

    @objc static var diffFontName: String {
        get { defaults.string(forKey: Key.diffFontName) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName }
        set {
            guard newValue != diffFontName else { return }
            defaults.set(newValue, forKey: Key.diffFontName)
            NotificationCenter.default.post(
                name: .diffTextTypographyDidChange,
                object: nil
            )
        }
    }

    @objc static var diffFontSize: Double {
        get {
            guard defaults.object(forKey: Key.diffFontSize) != nil else { return 12 }
            return ApplicationPreferencePolicy.diffFontSize(defaults.double(forKey: Key.diffFontSize))
        }
        set {
            let clamped = ApplicationPreferencePolicy.diffFontSize(newValue)
            guard clamped != diffFontSize else { return }
            defaults.set(clamped, forKey: Key.diffFontSize)
            NotificationCenter.default.post(
                name: .diffTextTypographyDidChange,
                object: nil
            )
        }
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
