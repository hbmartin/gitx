import AppKit
import CoreServices
import GitXCore

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

/// The AppleScript `search` command. `named` runs an app-wide saved search with its own string and mode, and
/// wins over `string` and `in mode`; an unknown name is reported to the script as a missing object.
extension PBGitRepositoryDocument {
    private static let historySearchScriptingLogger = Logger(subsystem: "com.gitx.gitx", category: "HistorySearch")

    /// The cocoa keys of the search command's parameters in GitX.sdef.
    private enum HistorySearchScriptKey {
        static let string = "searchString"
        static let mode = "inMode"
        static let savedSearchName = "savedSearchName"
    }

    // GitX.sdef routes the search command here by its Objective-C selector.
    // swiftlint:disable:next unused_declaration
    @objc(findInModeScriptCommand:)
    func find(inModeScriptCommand command: NSScriptCommand) {
        let arguments = command.arguments ?? [:]
        let text = arguments[HistorySearchScriptKey.string] as? String
        let name = arguments[HistorySearchScriptKey.savedSearchName] as? String
        let mode = HistorySearchPolicy.validatedMode(rawValue: (arguments[HistorySearchScriptKey.mode] as? NSNumber)?.intValue ?? 0)
        let library = name == nil ? SavedHistorySearchLibrary() : SavedHistorySearchStore().library

        switch HistorySearchScriptRequest.resolve(savedSearchName: name, text: text, mode: mode, library: library) {
        case let .failure(issue):
            Self.historySearchScriptingLogger.error(
                "Script asked for an unknown saved history search \(name ?? "", privacy: .private)"
            )
            command.scriptErrorNumber = Int(errAENoSuchObject)
            command.scriptErrorString = issue.message
        case let .success(query):
            // An empty string still shows the history view, as the search command always has.
            guard let search = query ?? text.map({ HistorySearchQuery(mode: mode, text: $0) }) else { return }
            Self.historySearchScriptingLogger.info(
                "Script search \(search.text, privacy: .private) in mode \(search.mode.rawValue), named=\(name != nil)"
            )
            windowController()?.showHistoryView(self)
            windowController()?.setHistorySearch(search.text, mode: PBSearchModeForInteger(search.mode.rawValue))
        }
    }
}
