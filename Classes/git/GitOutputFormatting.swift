import Foundation

/// Preserve Git output and filesystem names while removing only their known terminators.
@objc(PBGitOutputFormatting)
final nonisolated class GitOutputFormatting: NSObject { // swiftlint:disable:this unused_declaration
    @objc(patchWithGitXIdentifier:)
    // swiftlint:disable:next unused_declaration
    static func patchWithGitXIdentifier(_ output: String) -> String {
        guard !output.isEmpty else { return "" }
        let terminated = output.unicodeScalars.last == "\n" ? output : output + "\n"
        return terminated + "\n-- \n+GitX\n"
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
