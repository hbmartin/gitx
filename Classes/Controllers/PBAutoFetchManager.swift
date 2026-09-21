import AppKit
import Foundation
import ObjectiveGit
import UserNotifications

private let autoFetchTimerResolution: TimeInterval = 30
private let autoFetchRetryBaseInterval: TimeInterval = 60
private let autoFetchRetryMaximumInterval: TimeInterval = 15 * 60

/// Coordinates unattended remote refreshes for the repositories selected by
/// the global auto-fetch preference. Failures retry with bounded exponential
/// backoff independently for each repository.
// swift6-safety-justification: NSLock protects generation/tasks; AppKit state stays on MainActor.
@objc(PBAutoFetchManager)
nonisolated class PBAutoFetchManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static let singleton = PBAutoFetchManager()

    private var timer: Timer?
    private let fetchQueue = DispatchQueue(label: "com.gitx.autofetch")
    @objc private dynamic var nextFetchDates = NSMutableDictionary()
    @objc private dynamic var inFlightRepositories = NSMutableDictionary()
    @objc private dynamic var failureCounts = NSMutableDictionary()
    private var lastScope: PBAutoFetchScope = .none
    private var started = false
    private var requestedNotificationAuthorization = false
    private let lifecycleLock = NSLock()
    private var generation: UInt = 0
    private var activeTasks: [String: PBTask] = [:]

    @objc(sharedManager)
    class func shared() -> PBAutoFetchManager {
        singleton
    }

    @MainActor @objc
    dynamic func start() {
        guard !started else { return }
        started = true
        lastScope = PBGitDefaults.autoFetchScope()

        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(autoFetchPreferencesChanged(_:)),
            name: .PBAutoFetchPreferencesDidChange,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        timer = Timer.scheduledTimer(
            timeInterval: autoFetchTimerResolution,
            target: self,
            selector: #selector(timerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        if lastScope != .none {
            ensureNotificationAuthorization()
            evaluateRepositoriesForImmediateFetch(true)
        }
    }

    /// Invalidates the polling timer and removes observers installed by `start`.
    /// Safe to call when not started, and `start` may be called again afterwards.
    @MainActor @objc
    dynamic func stop() {
        stop(immediately: false)
    }

    /// Stops polling and synchronously sends SIGTERM to active fetches before
    /// application teardown can prevent delayed cancellation work from running.
    @MainActor @objc
    dynamic func stopForApplicationTermination() {
        stop(immediately: true)
    }

    @MainActor
    private func stop(immediately: Bool) {
        let tasks = invalidateCurrentGeneration()
        inFlightRepositories.removeAllObjects()
        for task in tasks {
            if immediately {
                task.terminate()
            } else {
                task.terminate(afterGracePeriod: 2, forceKillAfter: 5)
            }
        }
        guard started else { return }
        started = false
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(
            self,
            name: .PBAutoFetchPreferencesDidChange,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        let center = UNUserNotificationCenter.current()
        if center.delegate === self {
            center.delegate = nil
        }
    }

    @MainActor @objc
    dynamic func ensureNotificationAuthorization() {
        guard !requestedNotificationAuthorization else { return }
        requestedNotificationAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor @objc
    dynamic func autoFetchPreferencesChanged(_ notification: Notification?) {
        let scope = PBGitDefaults.autoFetchScope()
        let wasDisabled = lastScope == .none
        lastScope = scope
        guard scope != .none else { return }
        ensureNotificationAuthorization()
        if wasDisabled {
            nextFetchDates.removeAllObjects()
            failureCounts.removeAllObjects()
        }
        evaluateRepositoriesForImmediateFetch(wasDisabled)
    }

    @MainActor @objc
    dynamic func timerFired(_ timer: Timer) {
        evaluateRepositoriesForImmediateFetch(false)
    }

    @MainActor @objc
    dynamic func workspaceDidWake(_ notification: Notification?) {
        failureCounts.removeAllObjects()
        evaluateRepositoriesForImmediateFetch(true)
    }

    @MainActor @objc(retryDelayForFailureCount:)
    dynamic class func retryDelay(forFailureCount failureCount: UInt) -> TimeInterval {
        guard failureCount > 0 else { return 0 }
        let exponent = min(failureCount - 1, 4)
        return min(autoFetchRetryBaseInterval * TimeInterval(1 << exponent), autoFetchRetryMaximumInterval)
    }

    @objc(keyForURL:)
    dynamic func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    @MainActor @objc
    dynamic func candidateRepositoryURLs() -> [String: URL] {
        let scope = PBGitDefaults.autoFetchScope()
        guard scope != .none else { return [:] }

        let documentController = NSDocumentController.shared
        var openURLs: [String: URL] = [:]
        for case let document as PBGitRepositoryDocument in documentController.documents {
            if let url = document.repository.workingDirectoryURL() {
                openURLs[key(for: url)] = url
            }
        }

        if scope == .activeRepository {
            let activeDocument = NSApp.keyWindow?.windowController?.document ?? documentController.currentDocument
            guard let document = activeDocument as? PBGitRepositoryDocument,
                  let url = document.repository.workingDirectoryURL() else { return [:] }
            return [key(for: url): url]
        }

        if scope == .openAndRecentRepositories {
            for url in documentController.recentDocumentURLs where url.isFileURL && !url.path.isEmpty {
                openURLs[key(for: url)] = url
            }
        }
        return openURLs
    }

    @MainActor @objc(evaluateRepositoriesForImmediateFetch:)
    dynamic func evaluateRepositoriesForImmediateFetch(_ immediate: Bool) {
        guard PBGitDefaults.autoFetchScope() != .none else { return }
        let now = Date()
        for (key, url) in candidateRepositoryURLs() {
            guard inFlightRepositories[key] == nil else { continue }
            if !immediate, let next = nextFetchDates[key] as? Date, next > now {
                continue
            }
            let scheduledGeneration = currentGeneration()
            inFlightRepositories[key] = NSNumber(value: scheduledGeneration)
            fetchQueue.async { [self] in
                fetchRepository(at: url, key: key, generation: scheduledGeneration)
            }
        }
    }

    @objc(taskForRepositoryURL:arguments:)
    dynamic func task(forRepositoryURL url: URL, arguments: [String]) -> PBTask {
        let task = PBTask(
            launchPath: PBGitBinary.path(),
            arguments: arguments,
            inDirectory: url.path
        )
        task.timeout = 10 * 60
        task.additionalEnvironment = [
            "GIT_TERMINAL_PROMPT": "0",
            "GCM_INTERACTIVE": "never",
            "GIT_ASKPASS": "/usr/bin/false",
        ]
        return task
    }

    @objc(outputForRepositoryURL:arguments:error:)
    dynamic func output(
        forRepositoryURL url: URL,
        arguments: [String],
        error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> String? {
        let task = task(forRepositoryURL: url, arguments: arguments)
        guard launch(task, error: error) else { return nil }
        return task.standardOutputString() ?? ""
    }

    private func launch(
        _ task: PBTask,
        error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        do {
            try task.launch()
            return true
        } catch let launchError {
            error?.pointee = launchError as NSError
            return false
        }
    }

    @objc(remoteSnapshotForURL:error:)
    dynamic func remoteSnapshot(
        for url: URL,
        error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> [String: String]? {
        guard let output = output(
            forRepositoryURL: url,
            arguments: ["for-each-ref", "--format=%(refname)\t%(objectname)", "refs/remotes"],
            error: error
        ) else { return nil }
        var snapshot: [String: String] = [:]
        output.enumerateLines { line, _ in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2, !parts[0].hasSuffix("/HEAD") else { return }
            snapshot[parts[0]] = parts[1]
        }
        return snapshot
    }

    @objc(isAncestor:of:repositoryURL:)
    dynamic func isAncestor(_ oldSHA: String, of newSHA: String, repositoryURL url: URL) -> Bool {
        var error: NSError?
        let ancestorTask = task(
            forRepositoryURL: url,
            arguments: ["merge-base", "--is-ancestor", oldSHA, newSHA]
        )
        return launch(ancestorTask, error: &error)
    }

    @objc(commitCountFrom:to:repositoryURL:)
    dynamic func commitCount(from oldSHA: String, to newSHA: String, repositoryURL url: URL) -> Int {
        var error: NSError?
        let output = output(
            forRepositoryURL: url,
            arguments: ["rev-list", "--count", "\(oldSHA)..\(newSHA)"],
            error: &error
        )
        return max(0, (output as NSString?)?.integerValue ?? 0)
    }

    @objc(commitTimestampForSHA:repositoryURL:)
    dynamic func commitTimestamp(forSHA sha: String, repositoryURL url: URL) -> TimeInterval {
        var error: NSError?
        let output = output(
            forRepositoryURL: url,
            arguments: ["show", "-s", "--format=%ct", sha],
            error: &error
        )
        return error == nil ? (output as NSString?)?.doubleValue ?? 0 : 0
    }

    @objc(fetchRepositoryAtURL:key:)
    dynamic func fetchRepository(at url: URL, key: String) {
        fetchRepository(at: url, key: key, generation: currentGeneration())
    }

    @objc(fetchRepositoryAtURL:key:generation:)
    dynamic func fetchRepository(at url: URL, key: String, generation: UInt) {
        defer {
            DispatchQueue.main.async { [self] in
                completeInFlightRepository(key: key, generation: generation)
            }
        }
        guard isCurrentGeneration(generation) else { return }
        var error: NSError?
        var before = remoteSnapshot(for: url, error: &error)
        guard isCurrentGeneration(generation) else { return }
        if before != nil {
            let fetch = task(forRepositoryURL: url, arguments: ["fetch", "--all"])
            guard registerActiveTask(fetch, key: key, generation: generation) else { return }
            defer { unregisterActiveTask(fetch, key: key) }
            if !launch(fetch, error: &error) {
                before = nil
            }
        }
        guard isCurrentGeneration(generation) else { return }
        let after = before == nil ? nil : remoteSnapshot(for: url, error: &error)
        guard isCurrentGeneration(generation) else { return }

        var advances: [[String: Any]] = []
        if let before, let after {
            for (ref, newSHA) in after {
                guard let oldSHA = before[ref], oldSHA != newSHA,
                      isAncestor(oldSHA, of: newSHA, repositoryURL: url) else { continue }
                let count = commitCount(from: oldSHA, to: newSHA, repositoryURL: url)
                if count > 0 {
                    advances.append([
                        "ref": ref,
                        "sha": newSHA,
                        "count": count,
                        "timestamp": commitTimestamp(forSHA: newSHA, repositoryURL: url),
                    ])
                }
            }
        }

        DispatchQueue.main.async { [self] in
            guard isCurrentGeneration(generation) else { return }
            guard before != nil, after != nil else {
                let failureCount = (failureCounts[key] as? NSNumber)?.uintValue ?? 0
                let nextFailureCount = failureCount + 1
                failureCounts[key] = NSNumber(value: nextFailureCount)
                nextFetchDates[key] = Date().addingTimeInterval(
                    PBAutoFetchManager.retryDelay(forFailureCount: nextFailureCount)
                )
                if nextFailureCount == 1 {
                    postFailureNotification(for: url, error: error)
                }
                return
            }
            failureCounts.removeObject(forKey: key)
            nextFetchDates[key] = Date().addingTimeInterval(
                TimeInterval(PBGitDefaults.autoFetchIntervalMinutes()) * 60
            )
            refreshOpenRepository(at: url)
            if !advances.isEmpty, PBGitDefaults.notifyAboutFetchedCommits(forRepositoryURL: url) {
                postAdvanceNotification(for: url, advances: advances)
            }
        }
    }

    private func currentGeneration() -> UInt {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return generation
    }

    private func isCurrentGeneration(_ candidate: UInt) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return generation == candidate
    }

    private func registerActiveTask(_ task: PBTask, key: String, generation candidate: UInt) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard generation == candidate else { return false }
        activeTasks[key] = task
        return true
    }

    private func unregisterActiveTask(_ task: PBTask, key: String) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if activeTasks[key] === task {
            activeTasks.removeValue(forKey: key)
        }
    }

    private func invalidateCurrentGeneration() -> [PBTask] {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        generation &+= 1
        let tasks = Array(activeTasks.values)
        activeTasks.removeAll()
        return tasks
    }

    @MainActor
    private func completeInFlightRepository(key: String, generation candidate: UInt) {
        guard (inFlightRepositories[key] as? NSNumber)?.uintValue == candidate else { return }
        inFlightRepositories.removeObject(forKey: key)
    }

    @MainActor @objc(openDocumentForRepositoryURL:)
    dynamic func openDocument(forRepositoryURL url: URL) -> PBGitRepositoryDocument? {
        let repositoryKey = key(for: url)
        for case let document as PBGitRepositoryDocument in NSDocumentController.shared.documents {
            if let candidateURL = document.repository.workingDirectoryURL(),
               key(for: candidateURL) == repositoryKey
            {
                return document
            }
        }
        return nil
    }

    @MainActor @objc(refreshOpenRepositoryAtURL:)
    dynamic func refreshOpenRepository(at url: URL) {
        guard let repository = openDocument(forRepositoryURL: url)?.repository else { return }
        repository.reloadRefs()
        repository.forceUpdateRevisions()
    }

    @MainActor @objc(postFailureNotificationForURL:error:)
    dynamic func postFailureNotification(for url: URL, error: Error?) {
        let content = UNMutableNotificationContent()
        content.title = "Auto-fetch failed for \(url.lastPathComponent)"
        let nsError = error as NSError?
        let reason = nsError?.localizedFailureReason
            ?? nsError?.localizedDescription
            ?? "Git could not refresh this repository."
        content.body = reason + " GitX will retry automatically."
        content.sound = .default
        content.userInfo = ["repository": url.path, "kind": "failure"]
        let request = UNNotificationRequest(
            identifier: "gitx-fetch-failure-\(key(for: url))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    @MainActor @objc(postAdvanceNotificationForURL:advances:)
    dynamic func postAdvanceNotification(for url: URL, advances: [[String: Any]]) {
        var total = 0
        var summaries: [String] = []
        var newest = advances.first ?? [:]
        for advance in advances {
            let count = advance["count"] as? Int ?? 0
            total += count
            let branch = (advance["ref"] as? String ?? "")
                .replacingOccurrences(of: "refs/remotes/", with: "")
            summaries.append("\(branch) (+\(count))")
            if (advance["timestamp"] as? TimeInterval ?? 0) > (newest["timestamp"] as? TimeInterval ?? 0) {
                newest = advance
            }
        }
        let content = UNMutableNotificationContent()
        content.title = "\(url.lastPathComponent) fetched \(total) new commit\(total == 1 ? "" : "s")"
        content.body = summaries.joined(separator: ", ")
        content.sound = .default
        content.userInfo = [
            "repository": url.path,
            "kind": "advance",
            "sha": newest["sha"] as? String ?? "",
            "ref": newest["ref"] as? String ?? "",
            "multipleBranches": advances.count > 1,
        ]
        let request = UNNotificationRequest(
            identifier: "gitx-fetch-advance-\(key(for: url))-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    @MainActor @objc(recordManualFetchSucceededForRepositoryURL:)
    dynamic func recordManualFetchSucceeded(forRepositoryURL repositoryURL: URL) {
        let repositoryKey = key(for: repositoryURL)
        failureCounts.removeObject(forKey: repositoryKey)
        nextFetchDates[repositoryKey] = Date().addingTimeInterval(
            TimeInterval(PBGitDefaults.autoFetchIntervalMinutes()) * 60
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        guard let path = info["repository"] as? String, !path.isEmpty else {
            completionHandler()
            return
        }
        let multipleBranches = info["multipleBranches"] as? Bool == true
        let refName = info["ref"] as? String
        let sha = info["sha"] as? String
        DispatchQueue.main.async { [self] in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let showDocument: (PBGitRepositoryDocument) -> Void = { document in
                guard let windowController = document.windowController() else { return }
                windowController.showHistoryView(self)
                windowController.window?.makeKeyAndOrderFront(self)
                NSApp.activate(ignoringOtherApps: true)
                if multipleBranches {
                    document.repository.currentBranchFilter = Int(kGitXAllBranchesFilter.rawValue)
                    PBGitDefaults.setBranchFilter(Int(kGitXAllBranchesFilter.rawValue))
                } else if let refName, !refName.isEmpty {
                    let ref = PBGitRef(string: refName)
                    if document.repository.refExists(ref) {
                        let specifier = PBGitRevSpecifier(ref: ref)
                        specifier.workingDirectory = document.repository.workingDirectoryURL()
                        document.repository.currentBranch = document.repository.addBranch(specifier)
                        document.repository.currentBranchFilter = Int(kGitXSelectedBranchFilter.rawValue)
                        PBGitDefaults.setBranchFilter(Int(kGitXSelectedBranchFilter.rawValue))
                    }
                }
                document.repository.forceUpdateRevisions()
                if let sha, !sha.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                        windowController.historyViewController?.selectCommit(GTOID(sha: sha))
                    }
                }
            }

            if let document = openDocument(forRepositoryURL: url) {
                showDocument(document)
            } else {
                PBRepositoryDocumentController.shared.openDocument(
                    withContentsOf: url,
                    display: true
                ) { document, _, _ in
                    if let repositoryDocument = document as? PBGitRepositoryDocument {
                        showDocument(repositoryDocument)
                    }
                }
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
