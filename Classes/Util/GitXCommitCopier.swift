import AppKit

/// Objective-C history actions use this through the generated GitX-Swift
/// interface.  Keeping the runtime name and selectors stable lets the small
/// conversion remain transparent to the existing controller façade.
@objc(GitXCommitCopier)
final nonisolated class GitXCommitCopier: ValueTransformer {
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
        transformed(commits.compactMap(\.patch), separator: "\n\n\n") { $0 }
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
