import AppKit

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration
@objc(PBCommitMessageEditCoordinator)
final class CommitMessageEditCoordinator: NSObject {
    @objc(transformMessage:inTextView:repository:error:)
    static func transform(
        message: String,
        in textView: NSTextView,
        repository: PBGitRepository
    ) throws -> String {
        let transformed = try CommitMessageTransformer(repository: repository).transform(message: message)
        guard transformed != message else { return message }
        let messageRange = NSRange(location: 0, length: textView.string.utf16.count)
        if textView.shouldChangeText(in: messageRange, replacementString: transformed) {
            textView.replaceCharacters(in: messageRange, with: transformed)
            textView.didChangeText()
        }
        NSLog("[GitX] Applied repository commit message replacement rules")
        return transformed
    }
}

// swiftlint:enable unused_declaration
