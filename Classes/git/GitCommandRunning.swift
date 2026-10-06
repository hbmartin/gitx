import Foundation

@objc(PBGitCommandRunning)
protocol GitCommandRunning: AnyObject {
    nonisolated func output(arguments: [String]) throws -> String
    nonisolated func historyOutput(arguments: [String]) throws -> String
    nonisolated func push(arguments: [String]) -> PBRepositoryPushCommandResult
    nonisolated func launch(arguments: [String]) throws
    nonisolated var lastOutput: String? { get }
}

final nonisolated class RepositoryGitCommandRunner: GitCommandRunning {
    private unowned let repository: PBGitRepository
    private(set) var lastOutput: String?

    init(repository: PBGitRepository) {
        self.repository = repository
    }

    func output(arguments: [String]) throws -> String {
        try repository.outputOfTask(withArguments: arguments)
    }

    func historyOutput(arguments: [String]) throws -> String {
        let task = repository.task(withArguments: arguments)
        var environment = task.additionalEnvironment ?? [:]
        environment["GIT_NO_REPLACE_OBJECTS"] = "1"
        environment["GIT_GRAFT_FILE"] = "/dev/null"
        task.additionalEnvironment = environment
        try task.launch()
        return String(decoding: task.standardOutputData, as: UTF8.self)
    }

    func push(arguments: [String]) -> PBRepositoryPushCommandResult {
        let task = repository.task(withArguments: arguments)
        task.separatesStandardError = true
        do {
            try task.launch()
            return PBRepositoryPushCommandResult(stdout: String(decoding: task.standardOutputData, as: UTF8.self),
                                                 stderr: String(decoding: task.standardErrorData, as: UTF8.self),
                                                 terminationStatus: 0, error: nil)
        } catch {
            return PBRepositoryPushCommandResult(stdout: String(decoding: task.standardOutputData, as: UTF8.self),
                                                 stderr: String(decoding: task.standardErrorData, as: UTF8.self),
                                                 terminationStatus: (error as NSError).userInfo[PBTaskTerminationStatusKey] as? NSNumber,
                                                 error: error as NSError)
        }
    }

    func launch(arguments: [String]) throws {
        let task = repository.task(withArguments: arguments)
        _ = try task.launch()
        lastOutput = task.standardOutputString()
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
    @objc let stdout: String
    @objc let stderr: String
    @objc let terminationStatus: NSNumber?
    @objc let error: NSError?

    @objc(initWithStdout:stderr:terminationStatus:error:)
    init(stdout: String, stderr: String, terminationStatus: NSNumber?, error: NSError?) {
        self.stdout = stdout
        self.stderr = stderr
        self.terminationStatus = terminationStatus
        self.error = error
        super.init()
    }
}
