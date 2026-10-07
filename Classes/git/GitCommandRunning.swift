import Foundation

@objc(PBGitCommandRunning)
protocol GitCommandRunning: AnyObject {
    nonisolated func output(arguments: [String]) throws -> String
    // Retained for Objective-C runner compatibility; the app-hosted harness exercises its selector.
    // swiftlint:disable:next unused_declaration
    nonisolated func historyOutput(arguments: [String]) throws -> String
    nonisolated func push(arguments: [String]) -> PBRepositoryPushCommandResult
    nonisolated func launch(arguments: [String]) throws
}

/// Recovery evidence must preserve bytes and keep diagnostics out of the result.
@objc(PBGitEvidenceCommandRunning)
protocol GitEvidenceCommandRunning: GitCommandRunning {
    nonisolated func evidenceData(arguments: [String], inputData: Data?, environment: [String: String]?) throws -> Data
    nonisolated var evidenceExecutableIdentity: String { get }
}

final nonisolated class RepositoryGitCommandRunner: GitEvidenceCommandRunning {
    private unowned let repository: PBGitRepository

    init(repository: PBGitRepository) {
        self.repository = repository
    }

    func output(arguments: [String]) throws -> String {
        try repository.outputOfTask(withArguments: arguments)
    }

    func historyOutput(arguments: [String]) throws -> String {
        try String(decoding: evidenceData(arguments: arguments, inputData: nil, environment: nil), as: UTF8.self)
    }

    var evidenceExecutableIdentity: String {
        IndexGitExecutableIdentity.identity(path: PBGitBinary.path() ?? "")
    }

    func evidenceData(arguments: [String], inputData: Data?, environment: [String: String]?) throws -> Data {
        let task = repository.task(withArguments: arguments)
        task.separatesStandardError = true
        task.standardInputData = inputData
        var additions = task.additionalEnvironment ?? [:]
        environment?.forEach { additions[$0.key] = $0.value }
        task.additionalEnvironment = Self.protectedHistoryEnvironment(additions)
        try task.launch()
        return task.standardOutputData
    }

    func push(arguments: [String]) -> PBRepositoryPushCommandResult {
        let task = repository.task(withArguments: arguments)
        let capture = PBTaskDiagnosticCapture()
        task.diagnosticCapture = capture
        task.separatesStandardError = true
        task.capturesStandardOutput = false
        task.timeout = 600
        task.additionalEnvironment = Self.protectedHistoryEnvironment(task.additionalEnvironment ?? [:])
        let failure: NSError?
        do {
            try task.launch()
            failure = nil
        } catch {
            failure = error as NSError
        }
        let artifact = capture.seal()
        let prefix = artifact.rawStandardOutputPrefix(maximumBytes: 64 * 1024)
        let browserHint: String
        if failure == nil {
            var firstURL: URL?
            artifact.forEachRawStandardErrorLine(maximumLineBytes: 64 * 1024) { line in
                if firstURL == nil {
                    firstURL = RepositoryPushBrowserHintPolicy.firstURL(in: line)
                }
            }
            browserHint = firstURL?.absoluteString ?? ""
        } else {
            browserHint = ""
        }
        let complete = artifact.captureComplete
        let safeError = failure.map { Self.capturedError($0, artifact: artifact) }
        let result = PBRepositoryPushCommandResult(
            standardOutput: String(decoding: prefix.data, as: UTF8.self),
            standardError: String(decoding: task.standardErrorData, as: UTF8.self),
            terminationStatus: failure == nil ? 0 : failure?.userInfo[PBTaskTerminationStatusKey] as? NSNumber,
            error: safeError,
            standardOutputComplete: prefix.complete,
            standardErrorComplete: complete,
            diagnosticArtifact: failure == nil ? nil : artifact,
            browserHintOutput: browserHint
        )
        if failure == nil {
            artifact.discard()
        }
        return result
    }

    func launch(arguments: [String]) throws {
        let task = repository.task(withArguments: arguments)
        _ = try task.launch()
    }

    private static func protectedHistoryEnvironment(_ inherited: [String: Any]) -> [String: Any] {
        var environment = inherited
        environment["GIT_NO_REPLACE_OBJECTS"] = "1"
        // /dev/null is a file, so this descendant can never be a graft file.
        environment["GIT_GRAFT_FILE"] = "/dev/null/gitx-recovery-grafts"
        return environment
    }

    private static func capturedError(_ error: NSError, artifact: PBTaskDiagnosticArtifact) -> NSError {
        var info = error.userInfo
        info[PushDiagnosticOwnership.errorKey] = artifact
        info[PBTaskTerminationOutputKey] = artifact.redactedSummary
        info[NSLocalizedDescriptionKey] = PBTaskDiagnostics.redacted(error.localizedDescription)
        info[NSLocalizedFailureReasonErrorKey] = PBTaskDiagnostics.redacted(error.localizedFailureReason ?? error.localizedDescription)
        if error.domain == PBTaskErrorDomain, error.code == Int(PBTaskErrorCode.timeoutError.rawValue) {
            info[NSLocalizedDescriptionKey] = "Push timed out"
            info[NSLocalizedFailureReasonErrorKey] = "GitX stopped waiting after ten minutes. The remote may have completed the push."
            info[NSLocalizedRecoverySuggestionErrorKey] = "Check the remote or fetch before starting another push."
        }
        return NSError(domain: error.domain, code: error.code, userInfo: info)
    }
}

nonisolated enum RepositoryServiceError {
    static func make(
        description: String,
        failureReason: String,
        underlyingError: Error? = nil,
        userInfo: [String: Any] = [:]
    ) -> NSError {
        var info = userInfo
        info[NSLocalizedDescriptionKey] = description
        info[NSLocalizedFailureReasonErrorKey] = failureReason
        if let underlyingError {
            info[NSUnderlyingErrorKey] = underlyingError
        }
        return NSError(domain: PBGitXErrorDomain, code: 0, userInfo: info)
    }

    static func assign(_ error: NSError, to output: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool {
        output?.pointee = error
        return false
    }
}

/// Separate immutable streams keep transport diagnostics out of status parsing.
@objc(PBRepositoryPushCommandResult)
final nonisolated class PBRepositoryPushCommandResult: NSObject {
    @objc let standardOutput: String
    @objc let standardError: String
    @objc let standardOutputComplete: Bool
    @objc let standardErrorComplete: Bool
    @objc let diagnosticArtifact: PBTaskDiagnosticArtifact?
    @objc let browserHintOutput: String
    @objc let terminationStatus: NSNumber?
    @objc let error: NSError?

    @objc(initWithStandardOutput:standardError:terminationStatus:error:)
    convenience init(standardOutput: String, standardError: String, terminationStatus: NSNumber?, error: NSError?) {
        self.init(standardOutput: standardOutput, standardError: standardError, terminationStatus: terminationStatus, error: error,
                  standardOutputComplete: true, standardErrorComplete: true, diagnosticArtifact: nil, browserHintOutput: standardError)
    }

    @objc(initWithStandardOutput:standardError:terminationStatus:error:standardOutputComplete:standardErrorComplete:diagnosticArtifact:browserHintOutput:)
    init(standardOutput: String, standardError: String, terminationStatus: NSNumber?, error: NSError?,
         standardOutputComplete: Bool, standardErrorComplete: Bool, diagnosticArtifact: PBTaskDiagnosticArtifact?, browserHintOutput: String)
    {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputComplete = standardOutputComplete
        self.standardErrorComplete = standardErrorComplete
        self.diagnosticArtifact = diagnosticArtifact
        self.browserHintOutput = browserHintOutput
        self.terminationStatus = terminationStatus
        self.error = error
        super.init()
    }
}
