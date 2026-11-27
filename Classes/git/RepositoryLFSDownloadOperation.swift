import AppKit
import GitXCore

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

/// Downloads Git LFS content for the current checkout in two phases (ADR 0014):
///
/// 1. `git lfs fetch` reads the remote and writes only the local object store, so it is a read: Cancel and Quit
///    terminate it, and nothing in the checkout changes.
/// 2. `git lfs checkout` rewrites worktree files and the index, so it is a local mutation: it waits for
///    mutation admission and, once started, runs to completion (ADR 0009).
@MainActor
final class RepositoryLFSDownloadOperation: NSObject {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "LFS")
    /// A fetch that reports no progress for this long has stalled.
    static let stallInterval: TimeInterval = 600

    enum Phase: Equatable {
        /// Fetching objects; the fraction is nil until git-lfs reports progress.
        case fetching(fraction: Double?, detail: String?)
        /// Writing the downloaded objects into the checkout; this cannot be cancelled.
        case finishing
        case finished(Outcome)
        case failed(String)
        case cancelled

        var isFinal: Bool {
            switch self {
            case .finished, .failed, .cancelled: true
            case .fetching, .finishing: false
            }
        }
    }

    enum Outcome: Equatable {
        case checkedOut
        /// The objects are in the local store, but GitX was quitting, so the checkout did not start.
        case checkoutDeferred
    }

    /// Builds the commands, so tests can substitute a fake git-lfs.
    typealias TaskFactory = @MainActor ([String]) -> PBTask

    let plan: LFSDownloadPlan
    private let makeTask: TaskFactory
    private let writer: IndexWriterCoordinator?
    private let mutations: RepositoryLocalMutationRegistry
    private let update: (Phase) -> Void
    private let now: () -> Date
    private(set) var phase: Phase = .fetching(fraction: nil, detail: nil)
    private var fetchTask: PBTask?
    private var progressDirectory: URL?
    private var progressReadOffset: UInt64 = 0
    private var progressRemainder = ""
    private var lastProgress = Date()
    private var pollTimer: Timer?
    private var terminationObserver: NSObjectProtocol?

    init(
        plan: LFSDownloadPlan,
        writer: IndexWriterCoordinator?,
        mutations: RepositoryLocalMutationRegistry = .shared,
        now: @escaping () -> Date = Date.init,
        makeTask: @escaping TaskFactory,
        update: @escaping (Phase) -> Void
    ) {
        self.plan = plan
        self.writer = writer
        self.mutations = mutations
        self.now = now
        self.makeTask = makeTask
        self.update = update
        super.init()
    }

    convenience init(repository: PBGitRepository, plan: LFSDownloadPlan, update: @escaping (Phase) -> Void) {
        self.init(
            plan: plan,
            writer: IndexWriterCoordinator.coordinator(for: repository),
            makeTask: { [weak repository] arguments in
                repository?.task(withArguments: arguments) ?? PBTask(launchPath: "/usr/bin/false", arguments: [], inDirectory: nil)
            },
            update: update
        )
    }

    var isCancellable: Bool {
        if case .fetching = phase {
            true
        } else {
            false
        }
    }

    func start() {
        Self.logger.notice("Downloading Git LFS content for \(plan.paths?.count ?? -1) paths (-1 is all)")
        let task = makeTask(plan.fetchArguments)
        task.timeout = 0
        task.separatesStandardError = true
        // The same credential helpers and askpass as a manual Fetch; there is no terminal to prompt in.
        var environment = task.additionalEnvironment ?? [:]
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if let progressFile = makeProgressFile() {
            environment["GIT_LFS_PROGRESS"] = progressFile.path
        }
        task.additionalEnvironment = environment
        fetchTask = task
        lastProgress = now()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // swift6-safety-justification: the observer is registered on the main queue.
            MainActor.assumeIsolated { self?.cancel(reason: "quit") }
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            // swift6-safety-justification: this Timer is installed only on RunLoop.main.
            MainActor.assumeIsolated { self?.pollProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        set(.fetching(fraction: nil, detail: nil))
        task.perform(on: .main, outputChunkHandler: nil) { [weak self] _, error in
            // swift6-safety-justification: PBTask's `.main` completion queue runs this on the main actor.
            MainActor.assumeIsolated { self?.fetchFinished(task: task, error: error) }
        }
    }

    /// Stops a fetch. A checkout that has started always runs to completion.
    func cancel() {
        cancel(reason: "user")
    }

    private func cancel(reason: String) {
        guard isCancellable, let fetchTask else { return }
        Self.logger.notice("Cancelling the Git LFS fetch (\(reason, privacy: .public))")
        self.fetchTask = nil
        stopPolling()
        fetchTask.terminate()
        set(.cancelled)
    }

    // MARK: Fetch

    private func fetchFinished(task: PBTask, error: Error?) {
        guard fetchTask === task else { return }
        fetchTask = nil
        pollProgress()
        stopPolling()
        if let error {
            let diagnostic = String(decoding: task.standardErrorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            Self.logger.error("git lfs fetch failed: \(diagnostic, privacy: .public)")
            set(.failed(Self.failureMessage(diagnostic: diagnostic, error: error)))
            return
        }
        Self.logger.info("Fetched Git LFS objects; checking them out")
        checkout()
    }

    private func pollProgress() {
        guard isCancellable else { return }
        if now().timeIntervalSince(lastProgress) > Self.stallInterval {
            Self.logger.error("git lfs fetch reported no progress for \(Self.stallInterval) seconds")
            let task = fetchTask
            fetchTask = nil
            stopPolling()
            task?.terminate()
            set(.failed("Git LFS stopped making progress. Check your network connection, then try again."))
            return
        }
        guard let file = progressDirectory?.appendingPathComponent("progress"),
              let handle = try? FileHandle(forReadingFrom: file)
        else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: progressReadOffset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        progressReadOffset += UInt64(data.count)
        let split = LFSProgressEvent.events(in: progressRemainder + String(decoding: data, as: UTF8.self))
        progressRemainder = split.remainder
        guard let event = split.events.last else { return }
        lastProgress = now()
        let detail = "\(event.completedFiles) of \(event.totalFiles) files — "
            + "\(LFSPresentation.byteCount(event.completedBytes)) of \(LFSPresentation.byteCount(event.totalBytes))"
        set(.fetching(fraction: event.fractionCompleted, detail: detail))
    }

    // MARK: Checkout

    private func checkout() {
        set(.finishing)
        let task = makeTask(plan.checkoutArguments)
        task.timeout = 0
        task.separatesStandardError = true
        var environment = task.additionalEnvironment ?? [:]
        environment["GIT_TERMINAL_PROMPT"] = "0"
        task.additionalEnvironment = environment
        let writer = writer
        let mutations = mutations
        let box = CheckoutBox(task: task)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = box.run(writer: writer, mutations: mutations)
            DispatchQueue.main.async { [weak self] in
                // swift6-safety-justification: DispatchQueue.main runs this block on the main thread.
                MainActor.assumeIsolated { self?.checkoutFinished(result) }
            }
        }
    }

    private func checkoutFinished(_ result: CheckoutBox.Result) {
        switch result {
        case .checkedOut:
            Self.logger.notice("Checked out the downloaded Git LFS content")
            set(.finished(.checkedOut))
        case .deferred:
            Self.logger.notice("Downloaded Git LFS content; the checkout was deferred because GitX is quitting")
            set(.finished(.checkoutDeferred))
        case let .failed(message):
            Self.logger.error("git lfs checkout failed: \(message, privacy: .public)")
            set(.failed(message))
        }
    }

    // MARK: Support

    private func set(_ phase: Phase) {
        self.phase = phase
        if phase.isFinal {
            stopPolling()
            removeProgressFile()
            if let observer = terminationObserver {
                NotificationCenter.default.removeObserver(observer)
                terminationObserver = nil
            }
        }
        update(phase)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// A private file for `GIT_LFS_PROGRESS`, in a directory only this user can read.
    private func makeProgressFile() -> URL? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitX-LFS-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("progress")
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                return nil
            }
            progressDirectory = directory
            return file
        } catch {
            Self.logger.error("Could not create the Git LFS progress file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func removeProgressFile() {
        guard let progressDirectory else { return }
        try? FileManager.default.removeItem(at: progressDirectory)
        self.progressDirectory = nil
    }

    static func failureMessage(diagnostic: String, error: Error) -> String {
        let detail = diagnostic.split(whereSeparator: \.isNewline).last.map(String.init) ?? error.localizedDescription
        return "Git LFS could not download the content. \(detail)"
    }
}

/// Runs the checkout on a background queue under the index writer; the task is created on the main actor and
/// transferred once.
// swift6-safety-justification: The task is created before transfer and only this box launches it, once.
private final nonisolated class CheckoutBox: @unchecked Sendable {
    enum Result {
        case checkedOut
        case deferred
        case failed(String)
    }

    private let task: PBTask

    init(task: PBTask) {
        self.task = task
    }

    /// The index writer admits through the shared registry; without one, `mutations` admits the checkout.
    func run(writer: IndexWriterCoordinator?, mutations: RepositoryLocalMutationRegistry) -> Result {
        do {
            if let writer {
                try writer.perform("lfs-checkout") { try task.launch() }
            } else {
                let activity = try mutations.admit()
                defer { mutations.finish(activity) }
                try task.launch()
            }
            return .checkedOut
        } catch RepositoryLocalMutationError.terminationPending {
            return .deferred
        } catch {
            let diagnostic = String(decoding: task.standardErrorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = diagnostic.split(whereSeparator: \.isNewline).last.map(String.init) ?? error.localizedDescription
            return .failed("Git LFS downloaded the content but could not write it into the checkout. \(detail)")
        }
    }
}
