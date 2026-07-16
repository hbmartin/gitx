import Dispatch
import Foundation
import OSLog // swiftlint:disable:this unused_import

// swift6-safety-justification: All fields are immutable after initialization, and status entries are immutable value snapshots.
@objc(PBIndexRefreshResult)
final nonisolated class IndexRefreshResult: NSObject, @unchecked Sendable {
    @objc let staged: [String: IndexStatusEntry]?
    @objc let unstaged: [String: IndexStatusEntry]?
    @objc let untracked: [String: IndexStatusEntry]?

    init(
        staged: [String: IndexStatusEntry]?,
        unstaged: [String: IndexStatusEntry]?,
        untracked: [String: IndexStatusEntry]?
    ) {
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        super.init()
    }
}

// swift6-safety-justification: The coordinator accesses each cycle only on its private serial state queue.
private final nonisolated class IndexRefreshCycle: @unchecked Sendable {
    var remainingComponents = 3
    var staged: [String: IndexStatusEntry]?
    var unstaged: [String: IndexStatusEntry]?
    var untracked: [String: IndexStatusEntry]?
}

// Objective-C lifecycle callbacks call this through GitX-Swift.h.
// swiftlint:disable unused_declaration
// swift6-safety-justification: Mutable coordination state and the stateless parser are confined to `stateQueue`; callbacks cross to the main queue with immutable snapshots.
@objc(PBIndexRefreshCoordinator)
final nonisolated class IndexRefreshCoordinator: NSObject, @unchecked Sendable {
    typealias StatusHandler = @Sendable (Bool, String) -> Void
    typealias ResultHandler = @Sendable (IndexRefreshResult) -> Void
    typealias IdleHandler = @Sendable () -> Void

    private struct Request: Sendable {
        let bareRepository: Bool
        let parentTree: String
    }

    private enum Component: Sendable {
        case staged
        case unstaged
        case untracked

        var commandName: String {
            switch self {
            case .staged: "diff-index"
            case .unstaged: "diff-files"
            case .untracked: "ls-files"
            }
        }
    }

    private let runner: IndexCommandRunning
    private let parser: IndexStatusParser
    private let statusHandler: StatusHandler
    private let resultHandler: ResultHandler
    private let idleHandler: IdleHandler
    private let stateQueue = DispatchQueue(label: "org.gitx.indexRefresh")
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "IndexRefreshCoordinator")
    private var refreshInProgress = false
    private var pendingRequest: Request?

    @objc(initWithRepository:parser:statusHandler:resultHandler:idleHandler:)
    convenience init(
        repository: PBGitRepository,
        parser: IndexStatusParser,
        statusHandler: @escaping StatusHandler,
        resultHandler: @escaping ResultHandler,
        idleHandler: @escaping IdleHandler
    ) {
        self.init(
            runner: IndexRepositoryCommandRunner(repository: repository),
            parser: parser,
            statusHandler: statusHandler,
            resultHandler: resultHandler,
            idleHandler: idleHandler
        )
    }

    @objc(initWithRunner:parser:statusHandler:resultHandler:idleHandler:)
    init(
        runner: IndexCommandRunning,
        parser: IndexStatusParser,
        statusHandler: @escaping StatusHandler,
        resultHandler: @escaping ResultHandler,
        idleHandler: @escaping IdleHandler
    ) {
        self.runner = runner
        self.parser = parser
        self.statusHandler = statusHandler
        self.resultHandler = resultHandler
        self.idleHandler = idleHandler
        super.init()
    }

    @objc(refreshBareRepository:parentTree:)
    func refresh(bareRepository: Bool, parentTree: String) {
        let request = Request(bareRepository: bareRepository, parentTree: parentTree)
        stateQueue.async { [weak self] in
            guard let self else { return }
            if refreshInProgress {
                pendingRequest = request
                logger.debug("Coalesced index refresh into one trailing replay")
                return
            }
            refreshInProgress = true
            start(request)
        }
    }

    @objc(refreshStatCacheForBareRepository:completion:)
    func refreshStatCache(
        bareRepository: Bool,
        completion: @escaping @Sendable () -> Void
    ) {
        guard !bareRepository else { return }
        runner.data(
            arguments: ["update-index", "-q", "--unmerged", "--ignore-missing", "--refresh"]
        ) { _, _ in
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func start(_ request: Request) {
        logger.debug("Started index refresh command fan-out")
        guard !request.bareRepository else {
            complete(IndexRefreshResult(staged: nil, unstaged: nil, untracked: nil))
            return
        }

        let cycle = IndexRefreshCycle()
        launch(
            .untracked,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"],
            cycle: cycle
        )
        launch(
            .staged,
            arguments: ["diff-index", "--cached", "-z", request.parentTree],
            cycle: cycle
        )
        launch(.unstaged, arguments: ["diff-files", "-z"], cycle: cycle)
    }

    private func launch(
        _ component: Component,
        arguments: [String],
        cycle: IndexRefreshCycle
    ) {
        runner.data(arguments: arguments) { [weak self] data, error in
            self?.stateQueue.async { [weak self] in
                self?.record(component, data: data, error: error, cycle: cycle)
            }
        }
    }

    private func record(
        _ component: Component,
        data: Data?,
        error: Error?,
        cycle: IndexRefreshCycle
    ) {
        var parseError: NSError?
        let entries: [String: IndexStatusEntry]?
        if error != nil {
            entries = nil
        } else {
            switch component {
            case .staged, .unstaged:
                entries = parser.parseTrackedData(data, error: &parseError)
            case .untracked:
                entries = parser.parseUntrackedData(data, error: &parseError)
            }
        }

        switch component {
        case .staged:
            cycle.staged = entries
        case .unstaged:
            cycle.unstaged = entries
        case .untracked:
            cycle.untracked = entries
        }

        let succeeded = error == nil && entries != nil
        let message = "\(component.commandName) \(succeeded ? "success" : "failed")"
        DispatchQueue.main.async { [statusHandler] in
            statusHandler(succeeded, message)
        }

        cycle.remainingComponents -= 1
        guard cycle.remainingComponents == 0 else { return }
        complete(
            IndexRefreshResult(
                staged: cycle.staged,
                unstaged: cycle.unstaged,
                untracked: cycle.untracked
            )
        )
    }

    private func complete(_ result: IndexRefreshResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            resultHandler(result)
            stateQueue.async { [weak self] in
                self?.finishCycle()
            }
        }
    }

    private func finishCycle() {
        if let pendingRequest {
            self.pendingRequest = nil
            logger.debug("Replaying one coalesced index refresh")
            start(pendingRequest)
            return
        }

        refreshInProgress = false
        logger.debug("Index refresh coordinator became idle")
        DispatchQueue.main.async { [idleHandler] in
            idleHandler()
        }
    }
}

// swiftlint:enable unused_declaration
