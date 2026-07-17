import Foundation
import OSLog // swiftlint:disable:this unused_import

// SwiftLint's analyzer cannot see these entry points through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBRepositoryStashService)
final nonisolated class RepositoryStashService: NSObject {
    private unowned let repository: PBGitRepository
    private let runner: GitCommandRunning
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryStashService")

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        runner = RepositoryGitCommandRunner(repository: repository)
        super.init()
    }

    @objc(initWithRepository:runner:)
    init(repository: PBGitRepository, runner: GitCommandRunning) {
        self.repository = repository
        self.runner = runner
        super.init()
    }

    @objc(stashes)
    func stashes() -> [PBGitStash] {
        guard let gitRepository = repository.gtRepo else { return [] }
        var result: [PBGitStash] = []
        gitRepository.enumerateStashes { index, message, oid, _ in
            guard let oid, let message else { return }
            result.append(PBGitStash(
                repository: self.repository,
                stashOID: oid,
                index: Int(index),
                message: message
            ))
        }
        return result
    }

    @objc(stashForRef:)
    func stash(for ref: PBGitRef) -> PBGitStash? {
        stashes().first { $0.ref.ref == ref.ref }
    }

    @objc(popStash:error:)
    func pop(
        _ stash: PBGitStash,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        run(command: "pop", stash: stash, error: outputError)
    }

    @objc(applyStash:error:)
    func apply(
        _ stash: PBGitStash,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        run(command: "apply", stash: stash, error: outputError)
    }

    @objc(dropStash:error:)
    func drop(
        _ stash: PBGitStash,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        run(command: "drop", stash: stash, error: outputError)
    }

    @objc(saveWithKeepIndex:error:)
    func save(
        keepIndex: Bool,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        logger.debug("Saving repository stash")
        do {
            _ = try runner.output(arguments: [
                "stash", "save", keepIndex ? "--keep-index" : "--no-keep-index",
            ])
            logger.debug("Repository stash saved")
            return true
        } catch {
            let wrapped = RepositoryServiceError.make(
                description: "Stash save failed!",
                failureReason: "There was an error!",
                underlyingError: error,
                userInfo: [NSUnderlyingErrorKey: error]
            )
            logger.error("Repository stash save failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
        }
    }

    private func run(
        command: String,
        stash: PBGitStash,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        logger.debug("Running repository stash operation")
        do {
            _ = try runner.output(arguments: ["stash", command, stash.ref.refishName()])
            logger.debug("Repository stash operation completed")
            return true
        } catch {
            let wrapped = RepositoryServiceError.make(
                description: "Stash \(command) failed!",
                failureReason: "There was an error!",
                underlyingError: error,
                userInfo: [NSUnderlyingErrorKey: error]
            )
            logger.error("Repository stash operation failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
        }
    }
}

// swiftlint:enable unused_declaration
