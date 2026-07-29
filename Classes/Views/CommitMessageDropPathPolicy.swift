import Foundation

/// Objective-C callers are not visible to SwiftLint's analyzer.
@objc(PBCommitMessageDropPathPolicy)
final nonisolated class CommitMessageDropPathPolicy: NSObject { // swiftlint:disable:this unused_declaration
    @objc(relativePathsFromFilenames:workingDirectory:)
    // swiftlint:disable:next unused_declaration
    static func relativePaths(filenames: [String], workingDirectory: String?) -> [String]? {
        guard let workingDirectory else { return nil }

        let baseDirectory = workingDirectory + "/"
        let baseDirectoryLength = (baseDirectory as NSString).length
        var rewrittenCount = 0
        let relativeNames = filenames.map { filename in
            let filenameValue = filename as NSString
            guard filenameValue.hasPrefix(baseDirectory) else { return filename }

            let relativeName = filenameValue.substring(from: baseDirectoryLength)
            guard !relativeName.isEmpty else { return filename }

            rewrittenCount += 1
            return relativeName
        }
        NSLog(
            "[GitX] Prepared commit-message file drop (%ld relative, %ld unchanged)",
            rewrittenCount,
            filenames.count - rewrittenCount
        )
        return relativeNames
    }
}
