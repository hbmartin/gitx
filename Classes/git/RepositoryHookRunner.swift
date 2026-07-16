import Foundation
import OSLog // swiftlint:disable:this unused_import

// SwiftLint's analyzer cannot see these entry points through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBRepositoryHookRunner)
final class RepositoryHookRunner: NSObject {
    private unowned let repository: PBGitRepository
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryHookRunner")

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        super.init()
    }

    @objc(pathForHook:)
    func path(forHook name: String) -> String {
        let customHooksPath: String?
        if let configuration = try? repository.gtRepo?.configuration() {
            customHooksPath = configuration.string(forKey: "core.hookspath")
        } else {
            customHooksPath = nil
        }

        let hooksPath: String
        if let customHooksPath {
            let expanded = NSString(string: customHooksPath).expandingTildeInPath
            hooksPath = URL(fileURLWithPath: expanded, relativeTo: repository.workingDirectoryURL()).path
        } else {
            hooksPath = repository.gitURL()?.appendingPathComponent("hooks").path ?? ""
        }
        return (hooksPath as NSString).appendingPathComponent(name)
    }

    @objc(hookExists:)
    func hookExists(_ name: String) -> Bool {
        let hookURL = URL(fileURLWithPath: path(forHook: name))
        return (try? hookURL.resourceValues(forKeys: [.isExecutableKey]).isExecutable) == true
    }

    @objc(executeHook:arguments:output:error:)
    func executeHook(
        _ name: String,
        arguments: [String],
        output outputPointer: AutoreleasingUnsafeMutablePointer<NSString?>?,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        guard hookExists(name) else { return true }
        logger.debug("Executing repository hook")
        let task = PBTask(
            launchPath: path(forHook: name),
            arguments: arguments,
            inDirectory: repository.workingDirectory()
        )
        let gitDirectory = repository.gitURL()?.path ?? ""
        task.additionalEnvironment = [
            "GIT_DIR": gitDirectory,
            "GIT_INDEX_FILE": (gitDirectory as NSString).appendingPathComponent("index"),
        ]
        do {
            try task.launch()
            outputPointer?.pointee = task.standardOutputString() as NSString?
            logger.debug("Repository hook completed")
            return true
        } catch {
            let taskError = error as NSError
            let hookOutput = taskError.userInfo[PBTaskTerminationOutputKey] as? String ?? ""
            let failureReason: String
            if hookOutput.isEmpty {
                failureReason = "The \(name) hook reported an error."
            } else {
                failureReason = "The \(name) hook reported an error and returned the following:\n\(hookOutput)"
            }
            let wrapped = RepositoryServiceError.make(
                description: "\(name) hook failed",
                failureReason: failureReason,
                underlyingError: taskError,
                userInfo: [PBHookNameErrorKey: name]
            )
            logger.error("Repository hook failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
        }
    }
}

// swiftlint:enable unused_declaration
