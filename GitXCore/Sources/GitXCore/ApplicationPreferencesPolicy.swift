import Foundation

public enum ApplicationPreferenceKey: String, CaseIterable, Sendable {
    case openDisposition = "PBOpenDisposition"
    case restorePolicy = "PBWindowRestorePolicy"
    case changedFilesOnly = "PBHistoryChangedFilesOnly"
    case changedFilesSort = "PBHistoryChangedFilesSort"
    case groupIncomingBranchCommits = "PBHistoryGroupIncomingBranchCommits"
    case branchSort = "PBBranchSortMode"
    case diffLayout = "PBDiffLayout"
    case diffAlgorithm = "PBDiffAlgorithm"
    case diffContextLines = "PBDiffContextLines"
    case syntaxTheme = "PBSyntaxTheme"
    case diffFontName = "PBDiffFontName"
    case diffFontSize = "PBDiffFontSize"
    case addedTextColor = "PBDiffAddedTextColor"
    case removedTextColor = "PBDiffRemovedTextColor"
    case addedBackgroundColor = "PBDiffAddedBackgroundColor"
    case removedBackgroundColor = "PBDiffRemovedBackgroundColor"
    case terminalBundleIdentifier = "PBTerminalBundleIdentifier"
    case terminalInitialCommand = "PBTerminalInitialCommand"
    case customTerminalExecutable = "PBCustomTerminalExecutable"
    case customTerminalArguments = "PBCustomTerminalArguments"
    case raycastScriptsDirectory = "PBRaycastScriptsDirectory"
    case patchExportMode = "PBPatchExportMode"
    case showStageView = "PBShowStageView"
    case branchFilter = "PBBranchFilter"
    case historySearchMode = "PBHistorySearchMode"
    case appearance = "PBAppearancePreference"
    case autoFetchScope = "PBAutoFetchScope"
    case autoFetchIntervalMinutes = "PBAutoFetchIntervalMinutes"
}

public enum ApplicationPreferencePolicy {
    public static func validatedRawValue(
        _ rawValue: Int,
        validRange: ClosedRange<Int>,
        fallback: Int
    ) -> Int {
        validRange.contains(rawValue) ? rawValue : fallback
    }

    public static func diffContextLines(_ value: Int) -> Int {
        min(20, max(0, value))
    }

    public static func diffFontSize(_ value: Double) -> Double {
        min(36, max(9, value))
    }

    public static func autoFetchIntervalMinutes(_ value: Int) -> Int {
        min(1440, max(1, value))
    }

    public static func repositoryViewStateIdentifier(for commonGitDirectory: URL) -> String {
        commonGitDirectory.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
