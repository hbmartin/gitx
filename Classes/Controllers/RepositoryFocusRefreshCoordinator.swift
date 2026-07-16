import Foundation
import OSLog // swiftlint:disable:this unused_import

// swift6-safety-justification: Every mutable field is protected by `lock`, including the result snapshot returned to the main queue.
private final nonisolated class RepositorySnapshotAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var components: [Data]
    private var failed = false

    init(componentCount: Int) {
        components = Array(repeating: Data(), count: componentCount)
    }

    func record(data: Data?, error: Error?, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        if let data, error == nil {
            components[index] = data
        } else {
            failed = true
        }
    }

    func result() -> (components: [Data], failed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (components, failed)
    }
}

// Objective-C lifecycle callbacks call this through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBRepositoryFocusRefreshCoordinator)
final class RepositoryFocusRefreshCoordinator: NSObject {
    private unowned let repository: PBGitRepository
    private let gitExecutablePath: String
    private let refreshHandler: () -> Void
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryFocusRefreshCoordinator")
    private var enabled = false
    private var generation = 0
    private var previousSnapshotComponents: [Data]?
    private var tasks: [PBTask] = []

    @objc(initWithRepository:gitExecutablePath:refreshHandler:)
    init(
        repository: PBGitRepository,
        gitExecutablePath: String,
        refreshHandler: @escaping () -> Void
    ) {
        self.repository = repository
        self.gitExecutablePath = gitExecutablePath
        self.refreshHandler = refreshHandler
        super.init()
    }

    @objc(updatePreferenceEnabled:)
    func updatePreference(enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        invalidate(resetSnapshot: true)
        logger.debug("Focus refresh preference changed")
        if enabled {
            refreshIfRepositoryChanged()
        }
    }

    @objc(applicationDidBecomeActive)
    func applicationDidBecomeActive() {
        guard enabled else { return }
        refreshIfRepositoryChanged()
    }

    @objc(cancel)
    func cancel() {
        enabled = false
        invalidate(resetSnapshot: true)
    }

    @objc(shouldRefreshForSnapshotComponents:)
    func shouldRefresh(for snapshotComponents: [Data]) -> Bool {
        defer { previousSnapshotComponents = snapshotComponents }
        guard let previousSnapshotComponents else { return false }
        return previousSnapshotComponents != snapshotComponents
    }

    @objc(resetSnapshot)
    func resetSnapshot() {
        previousSnapshotComponents = nil
    }

    private func refreshIfRepositoryChanged() {
        invalidate(resetSnapshot: false)
        let requestedGeneration = generation
        let directory = repository.workingDirectoryURL()?.path ?? repository.gitURL()?.path
        let commands = snapshotCommands(isBareRepository: repository.isBare())
        let accumulator = RepositorySnapshotAccumulator(componentCount: commands.count)
        let group = DispatchGroup()

        logger.debug("Capturing repository focus snapshot")
        tasks = commands.enumerated().map { index, arguments in
            group.enter()
            let task = PBTask(
                launchPath: gitExecutablePath,
                arguments: arguments,
                inDirectory: directory
            )
            task.timeout = 10
            task.perform { data, error in
                accumulator.record(data: data, error: error, at: index)
                group.leave()
            }
            return task
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard requestedGeneration == self.generation, self.enabled else {
                self.logger.debug("Discarded stale repository focus snapshot")
                return
            }
            self.tasks.removeAll()
            let result = accumulator.result()
            let changed = self.shouldRefresh(for: result.components)
            guard result.failed || changed else {
                self.logger.debug("Repository focus snapshot unchanged")
                return
            }
            self.logger.debug("Repository focus snapshot requires refresh")
            self.refreshHandler()
        }
    }

    private func snapshotCommands(isBareRepository: Bool) -> [[String]] {
        var commands = [
            ["for-each-ref", "--format=%(refname)%00%(objectname)%00"],
            ["remote"],
        ]
        if !isBareRepository {
            commands.append(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"])
        }
        return commands
    }

    private func invalidate(resetSnapshot: Bool) {
        generation += 1
        if !tasks.isEmpty {
            logger.debug("Cancelling repository focus snapshot")
        }
        tasks.forEach { $0.terminate() }
        tasks.removeAll()
        if resetSnapshot {
            previousSnapshotComponents = nil
        }
    }
}

// swiftlint:enable unused_declaration
