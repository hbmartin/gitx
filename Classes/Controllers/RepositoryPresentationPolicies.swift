import AppKit
import GitXCore

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

@objc(PBCommitMessageTransformer)
final class CommitMessageTransformer: NSObject {
    private let store: RepositorySettingsStore

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        store = ApplicationComposition.shared.repositoryConfiguration(for: repository)
        super.init()
    }

    @objc(transformMessage:error:)
    func transform(message: String) throws -> String {
        let configuredRules = store.string(forKey: RepositorySettingsStore.commitRulesKey)
        do {
            return try RepositoryConfigurationPolicy.transformedCommitMessage(
                message,
                configuredRules: configuredRules
            )
        } catch let CommitMessageRuleError.missingSeparator(line) {
            throw CommitMessageTransformError.invalidRule(line: line)
        } catch let CommitMessageRuleError.invalidRegularExpression(line, description) {
            throw CommitMessageTransformError.invalidRegularExpression(
                line: line,
                underlying: NSError(
                    domain: NSCocoaErrorDomain,
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: description]
                )
            )
        }
    }
}

/// Objective-C callers are not visible to SwiftLint's analyzer.
@objc(PBBranchSidebarPresentation)
final class BranchSidebarPresentation: NSObject { // swiftlint:disable:this unused_declaration
    private let repository: PBGitRepository
    private var commitDates: [String: TimeInterval] = [:]
    private var containedBranches: Set<String> = []

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        super.init()
    }

    @objc var usesRecentSorting: Bool {
        ApplicationSettings.branchSort == .recentCommit
    }

    @objc func toggleSorting() {
        ApplicationSettings.branchSort = usesRecentSorting ? .alphabetical : .recentCommit
    }

    @objc func reload() {
        commitDates = branchCommitDates()
        containedBranches = mergedBranches()
    }

    @objc(shouldShowRevision:)
    // swiftlint:disable:next unused_declaration
    func shouldShow(revision: PBGitRevSpecifier) -> Bool {
        guard let ref = revision.ref(), ref.isBranch else { return true }
        let settings = ApplicationComposition.shared.repositoryViewState(for: repository)
        guard settings.hideContainedBranches else { return true }
        let primary = ApplicationComposition.shared.repositoryConfiguration(for: repository).detectedPrimaryBranch()
        let current = repository.headRef()?.ref()?.shortName()
        let name = ref.shortName()
        return name == primary || name == current || !containedBranches.contains(name)
    }

    @objc(sortedBranchItems:)
    // swiftlint:disable:next unused_declaration
    func sortedBranchItems(_ items: [PBSourceViewItem]) -> [PBSourceViewItem] {
        guard usesRecentSorting else { return items }
        return items.sorted { lhs, rhs in
            let left = commitDates[lhs.ref()?.ref ?? ""] ?? 0
            let right = commitDates[rhs.ref()?.ref ?? ""] ?? 0
            if left != right {
                return left > right
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private func branchCommitDates() -> [String: TimeInterval] {
        guard let output = try? repository.outputOfTask(withArguments: [
            "for-each-ref", "--format=%(refname)%00%(committerdate:unix)", "refs/heads",
        ]) else { return [:] }
        var result: [String: TimeInterval] = [:]
        for line in output.components(separatedBy: .newlines) {
            let fields = line.components(separatedBy: "\0")
            guard fields.count == 2, let timestamp = TimeInterval(fields[1]) else { continue }
            result[fields[0]] = timestamp
        }
        return result
    }

    private func mergedBranches() -> Set<String> {
        let settings = ApplicationComposition.shared.repositoryViewState(for: repository)
        guard settings.hideContainedBranches else { return [] }
        let primary = ApplicationComposition.shared.repositoryConfiguration(for: repository).detectedPrimaryBranch()
        guard let output = try? repository.outputOfTask(withArguments: [
            "branch", "--merged", primary, "--format=%(refname:short)",
        ]) else { return [] }
        return Set(output.components(separatedBy: .newlines).filter { !$0.isEmpty })
    }
}

private enum CommitMessageTransformError: LocalizedError {
    case invalidRule(line: Int)
    case invalidRegularExpression(line: Int, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .invalidRule(line):
            "Commit message replacement rule \(line) does not contain =>."
        case let .invalidRegularExpression(line, underlying):
            "Commit message replacement rule \(line) is invalid: \(underlying.localizedDescription)"
        }
    }
}

@objc(PBRepositoryRemoteURLCoordinator)
final class RepositoryRemoteURLCoordinator: NSObject {
    @objc static let shared = RepositoryRemoteURLCoordinator()
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryRemoteURL")

    @objc(handleSuccessfulPushOutput:repository:remote:presentingWindow:)
    func handleSuccessfulPush(
        output: String,
        repository: PBGitRepository,
        remote: PBGitRef?,
        presenting window: NSWindow?
    ) {
        let settings = ApplicationComposition.shared.repositoryConfiguration(for: repository)
        guard settings.bool(forKey: RepositorySettingsStore.autoOpenURLKey, defaultValue: false),
              let url = firstHTTPURL(in: output) else { return }
        if settings.bool(forKey: RepositorySettingsStore.requireHostMatchKey, defaultValue: true) {
            guard let expectedHost = gitHost(
                remoteURL(for: remoteName(for: remote, repository: repository), repository: repository)
            ), expectedHost.caseInsensitiveCompare(url.host ?? "") == .orderedSame else {
                logger.info("Ignored pushed URL because its host did not match the Git remote")
                return
            }
        }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
            self.logger.info("Opened URL returned by successful push")
        }
    }

    /// Objective-C callers are not visible to SwiftLint's analyzer.
    @objc(viewRemoteForRepository:presentingWindow:)
    // swiftlint:disable:next unused_declaration
    func viewRemote(repository: PBGitRepository, presenting window: NSWindow?) {
        guard let remoteName = chooseRemoteName(repository: repository, presenting: window),
              let remoteURL = remoteURL(for: remoteName, repository: repository),
              let baseURL = webBaseURL(for: remoteURL)
        else {
            present(
                title: "No Web Remote Available",
                message: "Configure a Git remote or a custom web URL template in Repository Settings.",
                window: window
            )
            return
        }

        let head = repository.headRef()?.ref()
        let branch = head?.isBranch == true ? head?.shortName() ?? "" : ""
        let sha = (try? repository.outputOfTask(withArguments: ["rev-parse", "HEAD"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let settings = ApplicationComposition.shared.repositoryConfiguration(for: repository)
        let template = settings.string(forKey: RepositorySettingsStore.webURLTemplateKey)
        let url: URL?
        if !template.isEmpty {
            let expanded = template
                .replacingOccurrences(of: "{remoteURL}", with: baseURL.absoluteString)
                .replacingOccurrences(of: "{branch}", with: urlComponent(branch))
                .replacingOccurrences(of: "{sha}", with: urlComponent(sha))
            url = URL(string: expanded)
        } else {
            url = providerURL(baseURL: baseURL, branch: branch, sha: sha)
        }
        guard let url else {
            present(
                title: "Remote URL Is Invalid",
                message: "Check the remote and custom template in Repository Settings.",
                window: window
            )
            return
        }
        NSWorkspace.shared.open(url)
        logger.info("Opened repository remote in browser")
    }

    @objc(firstHTTPURLInOutput:)
    func firstHTTPURL(in output: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(output.startIndex..., in: output)
        var result: URL?
        detector.enumerateMatches(in: output, range: range) { match, _, stop in
            guard let candidate = match?.url,
                  candidate.scheme == "http" || candidate.scheme == "https" else { return }
            result = candidate
            stop.pointee = true
        }
        return result
    }

    @objc(webURLForRemoteURL:branch:sha:)
    // swiftlint:disable:next unused_declaration
    func webURL(remoteURL: String, branch: String, sha: String) -> URL? {
        guard let baseURL = webBaseURL(for: remoteURL) else { return nil }
        return providerURL(baseURL: baseURL, branch: branch, sha: sha)
    }

    private func remoteName(for remote: PBGitRef?, repository: PBGitRepository) -> String? {
        if let name = remote?.remoteName, !name.isEmpty {
            return name
        }
        guard let head = repository.headRef()?.ref(), head.isBranch,
              let tracking = try? repository.remoteRef(forBranch: head) else { return nil }
        return tracking.remoteName
    }

    private func chooseRemoteName(repository: PBGitRepository, presenting window: NSWindow?) -> String? {
        if let name = remoteName(for: nil, repository: repository) {
            return name
        }
        let remotes = repository.remotes() ?? []
        if remotes.count == 1 {
            return remotes[0]
        }
        guard !remotes.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = "Choose a Remote"
        alert.informativeText = "The current commit has no upstream remote."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        popup.addItems(withTitles: remotes)
        alert.accessoryView = popup
        alert.addButton(withTitle: "View Remote")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? popup.titleOfSelectedItem : nil
    }

    private func remoteURL(for remoteName: String?, repository: PBGitRepository) -> String? {
        guard let remoteName, !remoteName.isEmpty else { return nil }
        let output = try? repository.outputOfTask(withArguments: ["remote", "get-url", remoteName])
        let value = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func webBaseURL(for remoteURL: String) -> URL? {
        var candidate = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("git@"), let colon = candidate.firstIndex(of: ":") {
            let hostStart = candidate.index(candidate.startIndex, offsetBy: 4)
            candidate = "https://" + candidate[hostStart ..< colon] + "/" + candidate[candidate.index(after: colon)...]
        } else if candidate.hasPrefix("ssh://") {
            guard var components = URLComponents(string: candidate) else { return nil }
            components.scheme = "https"
            components.user = nil
            components.port = nil
            candidate = components.string ?? candidate
        } else if candidate.hasPrefix("git://") {
            candidate = "https://" + candidate.dropFirst(6)
        }
        if candidate.hasSuffix(".git") {
            candidate.removeLast(4)
        }
        return URL(string: candidate)
    }

    private func providerURL(baseURL: URL, branch: String, sha: String) -> URL? {
        let revision = branch.isEmpty ? sha : branch
        guard !revision.isEmpty else { return baseURL }
        let suffix: String
        switch baseURL.host?.lowercased() ?? "" {
        case let host where host.contains("gitlab"):
            suffix = "/-/tree/\(urlComponent(revision))"
        case let host where host.contains("bitbucket"):
            suffix = "/src/\(urlComponent(revision))"
        default:
            suffix = "/tree/\(urlComponent(revision))"
        }
        return URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + suffix)
    }

    private func gitHost(_ remoteURL: String?) -> String? {
        guard let remoteURL else { return nil }
        if remoteURL.hasPrefix("git@"), let colon = remoteURL.firstIndex(of: ":") {
            return String(remoteURL[remoteURL.index(remoteURL.startIndex, offsetBy: 4) ..< colon])
        }
        return webBaseURL(for: remoteURL)?.host
    }

    private func urlComponent(_ string: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private func present(title: String, message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension Notification.Name {
    static let repositorySettingsDidChange = Notification.Name("PBRepositorySettingsDidChangeNotification")
}
