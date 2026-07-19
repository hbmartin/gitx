import Foundation
import OSLog // swiftlint:disable:this unused_import

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

@objc(PBIndexMutationService)
final nonisolated class IndexMutationService: NSObject {
    // `unowned` matches every sibling repository service. A strong reference here formed the cycle
    // PBGitRepository -> PBGitIndex -> mutationService -> repository, which leaked the whole repository
    // graph (and its live FSEvents watcher) on every document close.
    private unowned let repository: PBGitRepository
    private let runner: IndexCommandRunning
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "IndexMutationService")

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        runner = IndexRepositoryCommandRunner(repository: repository)
        super.init()
    }

    @objc(initWithRepository:runner:)
    init(repository: PBGitRepository, runner: IndexCommandRunning) {
        self.repository = repository
        self.runner = runner
        super.init()
    }

    @objc(stagePaths:error:)
    func stagePaths(
        _ paths: [String],
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        performChunks(paths, error: outputError) { chunk in
            let input = chunk.map { "\($0)\0" }.joined()
            _ = try runner.output(
                arguments: ["update-index", "--add", "--remove", "-z", "--stdin"],
                input: input,
                environment: nil
            )
        }
    }

    @objc(unstagePaths:parentTree:error:)
    func unstagePaths(
        _ paths: [String],
        parentTree: String,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        performChunks(paths, error: outputError) { chunk in
            _ = try runner.output(
                arguments: ["reset", "--quiet", parentTree, "--"] + chunk,
                input: nil,
                environment: nil
            )
        }
    }

    @objc(discardPaths:error:)
    func discardPaths(
        _ paths: [String],
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        do {
            _ = try runner.output(
                arguments: ["checkout-index", "--index", "--quiet", "--force", "-z", "--stdin"],
                input: paths.joined(separator: "\0"),
                environment: nil
            )
            logger.debug("Discarded worktree paths")
            return true
        } catch {
            outputError?.pointee = error as NSError
            logger.error("Discarding worktree paths failed")
            return false
        }
    }

    @objc(applyPatch:stage:reverse:error:)
    func applyPatch(
        _ patch: String,
        stage: Bool,
        reverse: Bool,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        let normalizedPatch = patch.hasSuffix("\n") ? patch : patch + "\n"
        var arguments = ["apply", "--unidiff-zero"]
        if stage {
            arguments.append("--cached")
        }
        if reverse {
            arguments.append("--reverse")
        }
        do {
            _ = try runner.output(arguments: arguments, input: normalizedPatch, environment: nil)
            logger.debug("Applied index patch")
            return true
        } catch {
            outputError?.pointee = error as NSError
            logger.error("Applying index patch failed")
            return false
        }
    }

    @objc(diffForPath:status:hasStagedChanges:staged:parentTree:contextLines:error:)
    func diff(
        forPath path: String,
        status: Int,
        hasStagedChanges: Bool,
        staged: Bool,
        parentTree: String,
        contextLines: UInt,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> String? {
        let context = "-U\(contextLines)"
        do {
            if staged {
                return try runner.output(
                    arguments: ["diff-index", context, "--cached", parentTree, "--", path],
                    input: nil,
                    environment: nil
                )
            }
            if status == 0, !hasStagedChanges {
                guard let workingDirectoryURL = repository.workingDirectoryURL() else {
                    throw NSError(
                        domain: "PBGitIndexMutationError",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Repository has no working directory"]
                    )
                }
                var encoding = String.Encoding.utf8
                return try String(
                    contentsOf: workingDirectoryURL.appendingPathComponent(path),
                    usedEncoding: &encoding
                )
            }
            return try runner.output(
                arguments: ["diff-files", context, "--", path],
                input: nil,
                environment: nil
            )
        } catch {
            outputError?.pointee = error as NSError
            return nil
        }
    }

    private func performChunks(
        _ paths: [String],
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?,
        operation: ([String]) throws -> Void
    ) -> Bool {
        do {
            for start in stride(from: 0, to: paths.count, by: 1000) {
                let end = min(start + 1000, paths.count)
                logger.debug("Mutating index paths \(start)-\(end) of \(paths.count)")
                try operation(Array(paths[start ..< end]))
            }
            return true
        } catch {
            outputError?.pointee = error as NSError
            logger.error("Index path mutation failed")
            return false
        }
    }
}

// swiftlint:enable unused_declaration
