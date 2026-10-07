import Foundation

/// Preserve Git output and filesystem names while removing only their known terminators.
@objc(PBGitOutputFormatting)
final nonisolated class GitOutputFormatting: NSObject { // swiftlint:disable:this unused_declaration
    @objc(patchWithGitXIdentifier:)
    // swiftlint:disable:next unused_declaration
    static func patchWithGitXIdentifier(_ output: String) -> String {
        var scalars = output.unicodeScalars
        if scalars.last == "\n" {
            scalars.removeLast()
        }
        return String(scalars) + "+GitX"
    }

    @objc(normalizedExecutableCandidate:)
    // swiftlint:disable:next unused_declaration
    static func normalizedExecutableCandidate(_ candidate: String) -> String {
        var scalars = candidate.unicodeScalars
        while scalars.last == "\r" || scalars.last == "\n" {
            scalars.removeLast()
        }
        return String(scalars)
    }
}
