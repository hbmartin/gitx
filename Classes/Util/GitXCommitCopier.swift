import AppKit
import OSLog // swiftlint:disable:this unused_import

/// Objective-C history actions use this through the generated GitX-Swift
/// interface.  Keeping the runtime name and selectors stable lets the small
/// conversion remain transparent to the existing controller façade.
// These selectors are called by Objective-C history actions.
// swiftlint:disable unused_declaration
@objc(GitXCommitCopier)
final nonisolated class GitXCommitCopier: ValueTransformer {
    @objc(canCopyImmutableCommits:)
    static func canCopyImmutableCommits(_ commits: [PBGitCommit]) -> Bool {
        CommitCopySelectionPolicy.canCopyImmutableCommits(shas: commits.map(\.sha))
    }

    @objc(toFullSHA:)
    static func toFullSHA(_ commits: [PBGitCommit]) -> String {
        transformed(commits) { $0.sha }
    }

    @objc(toShortName:)
    static func toShortName(_ commits: [PBGitCommit]) -> String {
        transformed(commits, separator: " ") { $0.shortName() }
    }

    @objc(toSHAAndHeadingString:)
    static func toSHAAndHeadingString(_ commits: [PBGitCommit]) -> String {
        transformed(commits) { "\($0.sha.prefix(10)) (\($0.subject))" }
    }

    @objc(toPatch:)
    static func toPatch(_ commits: [PBGitCommit]) -> String {
        patchCopyResult(commits).text
    }

    @objc(patchCopyResult:)
    static func patchCopyResult(_ commits: [PBGitCommit]) -> PBCommitPatchCopyResult {
        let result = PBCommitPatchCopyResult(result: CommitPatchCopyResult(patches: commits.map(\.patch)))
        Logger(subsystem: "com.gitx.gitx", category: "CommitCopy").debug("Patch copy prepared: copied=\(result.copiedCount), skipped=\(result.skippedCount)")
        return result
    }

    @objc(putStringToPasteboard:)
    static func putStringToPasteboard(_ string: String?) {
        guard let string, !string.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: self)
        pasteboard.setString(string, forType: .string)
    }

    private static func transformed<Value>(
        _ values: [Value],
        separator: String = "\n",
        transform: (Value) -> String
    ) -> String {
        values.reversed().map(transform).joined(separator: separator)
    }
}

/// Immutable result used by the Objective-C action; decisions live in the shared value type.
@objc(PBCommitPatchCopyResult)
final nonisolated class PBCommitPatchCopyResult: NSObject {
    private let result: CommitPatchCopyResult

    init(result: CommitPatchCopyResult) {
        self.result = result
        super.init()
    }

    @objc var text: String {
        result.text
    }

    @objc var copiedCount: Int {
        result.copiedCount
    }

    @objc var skippedCount: Int {
        result.skippedCount
    }

    @objc var warningMessage: String? {
        result.warningMessage
    }

    @objc var warningInfo: String {
        result.warningInfo
    }
}

// swiftlint:enable unused_declaration
