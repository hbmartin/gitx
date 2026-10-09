import Foundation
import OSLog // swiftlint:disable:this unused_import

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

@objc(PBIndexMutationService)
final nonisolated class IndexMutationService: NSObject {
    // A strong reference here formed the cycle
    // PBGitRepository -> PBGitIndex -> mutationService -> repository, which leaked the whole repository
    // graph (and its live FSEvents watcher) on every document close. Weak ownership also lets an
    // externally retained service fail normally after the repository closes.
    private weak var repository: PBGitRepository?
    private let runner: IndexCommandRunning
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "IndexMutationService")
    private let capabilitiesLock = NSLock()
    private var cachedCapabilities: (identity: String, value: IndexGitPathCapabilities)?

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

    @objc(stageRawPaths:unstageRawPaths:parentTree:error:)
    func mutate(stageRawPaths: [Data], unstageRawPaths: [Data], parentTree: String,
                error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
    {
        let operation = {
            var stageError: NSError?
            var unstageError: NSError?
            let staged = self.stageRawPaths(stageRawPaths, error: &stageError)
            let unstaged = self.unstageRawPaths(unstageRawPaths, parentTree: parentTree, error: &unstageError)
            let failures = [stageError, unstageError].compactMap { $0 }
            if let failure = failures.first {
                outputError?.pointee = NSError(domain: failure.domain, code: failure.code, userInfo: [
                    NSLocalizedDescriptionKey: failures.map { IndexOperationErrorPresentation.detail(for: $0) }.joined(separator: "\n\n"),
                ])
            }
            return staged && unstaged
        }
        if let native = runner as? IndexRepositoryCommandRunner {
            do { return try native.writerCoordinator.perform("stage then unstage batch", operation) }
            catch { outputError?.pointee = error as NSError; return false }
        }
        return operation()
    }

    @objc(stagePaths:error:)
    func stagePaths(
        _ paths: [String],
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        stageRawPaths(paths.map { Data($0.utf8) }, error: outputError)
    }

    @objc(stageRawPaths:error:)
    func stageRawPaths(
        _ rawPaths: [Data],
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        guard validate(rawPaths, error: outputError) else { return false }
        return performChunks(rawPaths, error: outputError) { chunk in
            _ = try output(
                arguments: ["update-index", "--add", "--remove", "-z", "--stdin"],
                inputData: nulDelimited(chunk)
            )
        }
    }

    @objc(unstagePaths:parentTree:error:)
    func unstagePaths(
        _ paths: [String],
        parentTree: String,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        unstageRawPaths(paths.map { Data($0.utf8) }, parentTree: parentTree, error: outputError)
    }

    @objc(unstageRawPaths:parentTree:error:)
    func unstageRawPaths(
        _ rawPaths: [Data],
        parentTree: String,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        guard validate(rawPaths, error: outputError) else { return false }
        guard !rawPaths.isEmpty else { return true }
        let decoded = rawPaths.compactMap { IndexFilenameUTF8.decode($0) }
        let allDecoded = decoded.count == rawPaths.count
        let legacySafe = allDecoded && decoded.allSatisfy(IndexGitPathCapabilities.isLegacyLiteral)
        // Prefer the byte-preserving reset command whenever supported. Git
        // 1.6 retains its argv fallback only for unambiguously literal names.
        let capabilities = pathCapabilities()
        guard legacySafe || capabilities.literalPathspecs == true,
              allDecoded || capabilities.nulReset == true
        else {
            outputError?.pointee = unsupportedLiteralPathError()
            return false
        }
        return performChunks(rawPaths, error: outputError) { chunk in
            let prefix = capabilities.literalPathspecs == true ? ["--literal-pathspecs"] : []
            if capabilities.nulReset && capabilities.literalPathspecs {
                _ = try output(
                    arguments: prefix + [
                        "reset", "--quiet", parentTree,
                        "--pathspec-from-file=-", "--pathspec-file-nul", "--",
                    ],
                    inputData: nulDelimited(chunk)
                )
            } else {
                let paths = chunk.compactMap { IndexFilenameUTF8.decode($0) }
                _ = try runner.output(
                    arguments: prefix + ["reset", "--quiet", parentTree, "--"] + paths,
                    input: nil, environment: nil
                )
            }
        }
    }

    @objc(discardPaths:error:)
    func discardPaths(
        _ paths: [String],
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        discardRawPaths(paths.map { Data($0.utf8) }, error: outputError)
    }

    @objc(discardRawPaths:error:)
    func discardRawPaths(
        _ rawPaths: [Data],
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        guard validate(rawPaths, error: outputError) else { return false }
        return performChunks(rawPaths, error: outputError) { chunk in
            _ = try output(
                arguments: ["checkout-index", "--index", "--quiet", "--force", "-z", "--stdin"],
                inputData: nulDelimited(chunk)
            )
            logger.debug("Discarded worktree paths")
        }
    }

    @objc(applyPatch:stage:reverse:error:)
    func applyPatch(
        _ patch: String,
        stage: Bool,
        reverse: Bool,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        guard !patch.isEmpty else {
            outputError?.pointee = NSError(
                domain: "PBGitIndexMutationError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The patch is empty and cannot be applied."]
            )
            logger.error("Rejected an empty index patch")
            return false
        }
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
        diff(
            forPath: path,
            status: status,
            hasStagedChanges: hasStagedChanges,
            staged: staged,
            parentTree: parentTree,
            contextLines: contextLines,
            ignoreWhitespace: false,
            error: outputError
        )
    }

    @objc(diffForPath:status:hasStagedChanges:staged:parentTree:contextLines:ignoreWhitespace:error:)
    func diff(
        forPath path: String,
        status: Int,
        hasStagedChanges: Bool,
        staged: Bool,
        parentTree: String,
        contextLines: UInt,
        ignoreWhitespace: Bool,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> String? {
        diff(
            forRawPath: Data(path.utf8), displayPath: path, status: status,
            hasStagedChanges: hasStagedChanges, staged: staged, parentTree: parentTree,
            contextLines: contextLines, ignoreWhitespace: ignoreWhitespace, error: outputError
        )
    }

    @objc(diffForRawPath:displayPath:status:hasStagedChanges:staged:parentTree:contextLines:ignoreWhitespace:error:)
    func diff(
        forRawPath rawPath: Data,
        displayPath: String,
        status: Int,
        hasStagedChanges: Bool,
        staged: Bool,
        parentTree: String,
        contextLines: UInt,
        ignoreWhitespace: Bool,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> String? {
        guard let path = IndexFilePresentation.safePath(rawPath: rawPath) else {
            outputError?.pointee = NSError(
                domain: "PBGitIndexMutationError", code: 3,
                userInfo: [NSLocalizedDescriptionKey: String(
                    format: NSLocalizedString(
                        "The non-UTF-8 path “%@” cannot safely be used for this preview.",
                        comment: "Unsupported raw Git filename preview"
                    ), displayPath
                )]
            )
            logger.error("Refused an unsupported raw path preview")
            return nil
        }
        var diffOptions = ["-U\(contextLines)"]
        if ignoreWhitespace {
            diffOptions.append("-w")
        }
        do {
            if !staged, status == 0 {
                guard let workingDirectoryURL = repository?.workingDirectoryURL() else {
                    throw NSError(
                        domain: "PBGitIndexMutationError", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Repository has no working directory"]
                    )
                }
                var encoding = String.Encoding.utf8
                return try String(contentsOf: workingDirectoryURL.appendingPathComponent(path), usedEncoding: &encoding)
            }
            let literal = !IndexGitPathCapabilities.isLegacyLiteral(path)
            if literal, !pathCapabilities().literalPathspecs {
                throw unsupportedLiteralPathError()
            }
            let prefix = literal ? ["--literal-pathspecs"] : []
            if staged {
                return try runner.output(
                    arguments: prefix + ["diff-index"] + diffOptions + ["--cached", parentTree, "--", path],
                    input: nil,
                    environment: nil
                )
            }
            return try runner.output(
                arguments: prefix + ["diff-files"] + diffOptions + ["--", path],
                input: nil,
                environment: nil
            )
        } catch {
            outputError?.pointee = error as NSError
            return nil
        }
    }

    @objc(diffToolArgumentsForRawPath:staged:error:)
    func diffToolArguments(
        forRawPath rawPath: Data,
        staged: Bool,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> [String]? {
        literalArguments(
            forRawPath: rawPath,
            commandArguments: ["difftool", "-y", "--no-prompt"] + (staged ? ["--cached"] : []),
            error: outputError
        )
    }

    @objc(literalArgumentsForRawPath:commandArguments:error:)
    func literalArguments(
        forRawPath rawPath: Data,
        commandArguments: [String],
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> [String]? {
        guard let path = IndexFilePresentation.safePath(rawPath: rawPath) else {
            outputError?.pointee = unsupportedRepresentationError()
            return nil
        }
        let needsLiteral = !IndexGitPathCapabilities.isLegacyLiteral(path)
        guard !needsLiteral || pathCapabilities().literalPathspecs else {
            outputError?.pointee = unsupportedLiteralPathError()
            return nil
        }
        let prefix = needsLiteral ? ["--literal-pathspecs"] : []
        return prefix + commandArguments + ["--", path]
    }

    private func performChunks<Element>(
        _ paths: [Element],
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?,
        operation: ([Element]) throws -> Void
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

    private func output(arguments: [String], inputData: Data) throws -> String {
        if let binaryRunner = runner as? IndexBinaryCommandRunning {
            return try binaryRunner.output(arguments: arguments, inputData: inputData, environment: nil)
        }
        guard let input = IndexFilenameUTF8.decode(inputData) else {
            throw unsupportedRepresentationError()
        }
        return try runner.output(arguments: arguments, input: input, environment: nil)
    }

    private func nulDelimited(_ paths: [Data]) -> Data {
        var input = Data()
        for path in paths {
            input.append(path)
            input.append(0)
        }
        return input
    }

    private func validate(_ paths: [Data], error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool {
        guard paths.allSatisfy({ !$0.isEmpty && !$0.contains(0) }) else {
            outputError?.pointee = NSError(
                domain: "PBGitIndexMutationError", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "A Git filename is empty or contains a NUL byte."]
            )
            return false
        }
        let supportsBytes = runner is IndexBinaryCommandRunning
        guard supportsBytes || paths.allSatisfy({ IndexFilenameUTF8.decode($0) != nil }) else {
            outputError?.pointee = unsupportedRepresentationError()
            return false
        }
        return true
    }

    private func unsupportedRepresentationError() -> NSError {
        logger.error("Rejected an unsupported filename representation")
        return NSError(domain: "PBGitIndexMutationError", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "This filename cannot be represented for this action. Whole-file byte-based Git operations remain available.",
        ])
    }

    private func unsupportedLiteralPathError() -> NSError {
        NSError(
            domain: "PBGitIndexMutationError", code: 4,
            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                "The configured Git cannot safely address this filename. Select a newer Git executable in preferences.",
                comment: "Git lacks filename-preserving pathspec support"
            )]
        )
    }

    private func pathCapabilities() -> IndexGitPathCapabilities {
        capabilitiesLock.lock()
        defer { capabilitiesLock.unlock() }
        let identity = IndexGitExecutableIdentity.identity(path: PBGitBinary.path() ?? "")
        if let cachedCapabilities, cachedCapabilities.identity == identity {
            return cachedCapabilities.value
        }
        let value = IndexGitPathCapabilities.probe(runner: runner)
        cachedCapabilities = (identity, value)
        logger.debug("Probed Git literal filename capabilities: literal=\(value.literalPathspecs), NUL reset=\(value.nulReset)")
        return value
    }
}

// swiftlint:enable unused_declaration

/// The executable target controls capabilities. Symlink metadata alone does
/// not change when a package manager replaces the binary behind that link.
@objc(PBIndexGitExecutableIdentity)
final nonisolated class IndexGitExecutableIdentity: NSObject {
    @objc(identityForPath:)
    static func identity(path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let attributes = (try? FileManager.default.attributesOfItem(atPath: resolved)) ?? [:]
        return [
            resolved,
            String(describing: attributes[.systemNumber]),
            String(describing: attributes[.systemFileNumber]),
            String(describing: attributes[.size]),
            String(describing: (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate),
        ].joined(separator: "|")
    }
}

private nonisolated struct IndexGitPathCapabilities {
    let literalPathspecs: Bool
    let nulReset: Bool

    static func isLegacyLiteral(_ path: String) -> Bool {
        !path.hasPrefix(":") && !path.unicodeScalars.contains { "*?[]\\".unicodeScalars.contains($0) }
    }

    static func probe(runner: IndexCommandRunning) -> Self {
        let environment: [String: Any] = ["LC_ALL": "C", "LANG": "C"]
        let help: String
        do {
            help = try runner.output(arguments: ["reset", "-h"], input: nil, environment: environment)
        } catch {
            let error = error as NSError
            help = (error.userInfo[PBTaskTerminationStatusKey] as? NSNumber)?.intValue == 129
                ? (error.userInfo[PBTaskTerminationOutputKey] as? String ?? "") : ""
        }
        let normalizedHelp = help.replacingOccurrences(of: "[no-]", with: "")
        let nulReset = normalizedHelp.contains("usage: git reset") &&
            normalizedHelp.contains("--pathspec-from-file") && normalizedHelp.contains("--pathspec-file-nul")
        let version = try? runner.output(
            arguments: ["--literal-pathspecs", "--version"], input: nil, environment: environment
        )
        return Self(literalPathspecs: version?.hasPrefix("git version ") == true, nulReset: nulReset)
    }
}
