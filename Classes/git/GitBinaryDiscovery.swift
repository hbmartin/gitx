import Foundation

/// Shared parsing and search-location policy; no command execution or AppKit work.
@objc(PBGitBinaryDiscoveryPolicy)
final nonisolated class GitBinaryDiscoveryPolicy: NSObject {
    @objc(extractGitVersion:)
    static func extractGitVersion(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value as NSString
        let range = text.range(of: "git version [0-9.]+", options: .regularExpression)
        guard range.location != NSNotFound else { return nil }
        return text.substring(with: NSRange(location: range.location + 12, length: range.length - 12))
    }

    @objc static let searchLocations = [
        "/opt/homebrew/bin/git", "/opt/local/bin/git", "/sw/bin/git", "/opt/git/bin/git",
        "/usr/local/bin/git", "/usr/local/git/bin/git", ("~/bin/git" as NSString).expandingTildeInPath,
        "/usr/bin/git",
    ]
}
