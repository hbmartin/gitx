import Foundation

public enum ForgePullRequestWorkflowError: Error, Equatable, LocalizedError, Sendable {
    case invalidTitle
    case invalidCommitSubject
    case invalidTemplatePath
    case mismatchedRepository
    case mismatchedForge
    case duplicateTemplatePath
    case invalidTransition
    case invalidRemoteName
    case invalidRemoteURL
    case invalidRefspec
    case unsafeWorkingState
    case headReferenceUnavailable
    case unsupportedRepositoryRelationship
    case editConflict

    public var errorDescription: String? {
        switch self {
        case .invalidTitle: "A Pull Request title must contain printable text."
        case .invalidCommitSubject: "A commit subject must contain printable text."
        case .invalidTemplatePath: "A Pull Request template path is invalid."
        case .mismatchedRepository: "The Pull Request value belongs to another Forge Repository."
        case .mismatchedForge: "The Pull Request value belongs to another Forge."
        case .duplicateTemplatePath: "The Pull Request template list contains a duplicate path."
        case .invalidTransition: "The Pull Request workflow event is not valid in its current state."
        case .invalidRemoteName: "The Pull Request checkout remote name is invalid."
        case .invalidRemoteURL: "The Pull Request checkout remote URL is invalid."
        case .invalidRefspec: "The Pull Request checkout refspec is invalid."
        case .unsafeWorkingState: "The working state must be clean before checking out a Pull Request."
        case .headReferenceUnavailable: "The Pull Request head reference is unavailable."
        case .unsupportedRepositoryRelationship: "This repository relationship is not supported by this workflow."
        case .editConflict: "The Pull Request changed after editing began."
        }
    }
}

public struct ForgePullRequestCreationForm: Codable, Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let base: ForgeBranchReference
    public let head: ForgeBranchReference
    public let title: String
    public let bodyMarkdown: String
    public let isDraft: Bool

    public init(
        repository: ForgeRepositoryIdentity,
        base: ForgeBranchReference,
        head: ForgeBranchReference,
        title: String,
        bodyMarkdown: String,
        isDraft: Bool = false
    ) throws {
        guard ForgePathComponent.isNonemptyPrintable(title) else {
            throw ForgePullRequestWorkflowError.invalidTitle
        }
        guard base.repository == repository else {
            throw ForgePullRequestWorkflowError.mismatchedRepository
        }
        guard head.repository.forge == repository.forge else {
            throw ForgePullRequestWorkflowError.mismatchedForge
        }
        self.repository = repository
        self.base = base
        self.head = head
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.isDraft = isDraft
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            base: container.decode(ForgeBranchReference.self, forKey: .base),
            head: container.decode(ForgeBranchReference.self, forKey: .head),
            title: container.decode(String.self, forKey: .title),
            bodyMarkdown: container.decode(String.self, forKey: .bodyMarkdown),
            isDraft: container.decode(Bool.self, forKey: .isDraft)
        )
    }

    public func editing(title: String, bodyMarkdown: String, isDraft: Bool) throws -> Self {
        try Self(
            repository: repository,
            base: base,
            head: head,
            title: title,
            bodyMarkdown: bodyMarkdown,
            isDraft: isDraft
        )
    }
}

public struct ForgePullRequestCommitSummary: Codable, Hashable, Sendable {
    public let id: ForgeCommitID
    public let subject: String
    public let body: String

    public init(id: ForgeCommitID, subject: String, body: String = "") throws {
        guard ForgePathComponent.isNonemptyPrintable(subject) else {
            throw ForgePullRequestWorkflowError.invalidCommitSubject
        }
        self.id = id
        self.subject = subject
        self.body = body
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ForgeCommitID.self, forKey: .id),
            subject: container.decode(String.self, forKey: .subject),
            body: container.decode(String.self, forKey: .body)
        )
    }
}

public struct ForgePullRequestTemplate: Codable, Hashable, Sendable {
    public let path: ForgeFilePath
    public let bodyMarkdown: String

    public init(path: ForgeFilePath, bodyMarkdown: String) throws {
        guard Self.isRecognized(path) else {
            throw ForgePullRequestWorkflowError.invalidTemplatePath
        }
        self.path = path
        self.bodyMarkdown = bodyMarkdown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            path: container.decode(ForgeFilePath.self, forKey: .path),
            bodyMarkdown: container.decode(String.self, forKey: .bodyMarkdown)
        )
    }

    public var displayName: String {
        let filename = path.components.last!
        return (filename as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
    }

    private static func isRecognized(_ path: ForgeFilePath) -> Bool {
        let lowered = path.components.map { $0.lowercased() }
        guard lowered.last?.hasSuffix(".md") == true else { return false }
        return lowered == ["pull_request_template.md"]
            || lowered == ["docs", "pull_request_template.md"]
            || lowered == [".github", "pull_request_template.md"]
            || lowered.count == 3 && lowered[0] == ".github" && lowered[1] == "pull_request_template"
    }
}

public enum ForgePullRequestTemplateSelection: Hashable, Sendable {
    case none
    case selected(ForgePullRequestTemplate)
    case requiresChoice([ForgePullRequestTemplate])
}

public enum ForgePullRequestInitialContentPolicy {
    public static func selectTemplate(
        _ templates: [ForgePullRequestTemplate]
    ) throws -> ForgePullRequestTemplateSelection {
        var seen: Set<String> = []
        for template in templates where !seen.insert(template.path.value.lowercased()).inserted {
            throw ForgePullRequestWorkflowError.duplicateTemplatePath
        }

        let sorted = templates.sorted {
            let lhs = priority($0.path)
            let rhs = priority($1.path)
            if lhs != rhs {
                return lhs < rhs
            }
            return $0.path.value.localizedStandardCompare($1.path.value) == .orderedAscending
        }
        guard let first = sorted.first else { return .none }
        let multiTemplate = sorted.filter { priority($0.path) == 3 }
        if sorted.count == multiTemplate.count, multiTemplate.count > 1 {
            return .requiresChoice(multiTemplate)
        }
        return .selected(first)
    }

    public static func content(
        branch: ForgeRefName,
        commitsOldestFirst: [ForgePullRequestCommitSummary],
        template: ForgePullRequestTemplate?
    ) -> (title: String, bodyMarkdown: String) {
        let title: String
        if commitsOldestFirst.count == 1, let commit = commitsOldestFirst.first {
            title = commit.subject
        } else if let last = commitsOldestFirst.last {
            title = last.subject
        } else {
            title = humanizedBranchName(branch.value)
        }

        if let template {
            return (title, template.bodyMarkdown)
        }
        guard !commitsOldestFirst.isEmpty else { return (title, "") }
        if commitsOldestFirst.count == 1 {
            return (title, commitsOldestFirst[0].body)
        }
        let body = commitsOldestFirst
            .map { "- \($0.subject) (`\($0.id.value.prefix(7))`)" }
            .joined(separator: "\n")
        return (title, body)
    }

    private static func priority(_ path: ForgeFilePath) -> Int {
        switch path.components.map({ $0.lowercased() }) {
        case [".github", "pull_request_template.md"]: 0
        case ["docs", "pull_request_template.md"]: 1
        case ["pull_request_template.md"]: 2
        default: 3
        }
    }

    private static func humanizedBranchName(_ value: String) -> String {
        let tail = String(value.split(separator: "/").last!)
        let words = tail
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return tail }
        let first = words.first!
        return String(first).uppercased() + words.dropFirst()
    }
}

public struct ForgePullRequestComparisonKey: Codable, Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let baseRepository: ForgeRepositoryIdentity
    public let base: ForgeRefName
    public let headRepository: ForgeRepositoryIdentity
    public let head: ForgeRefName

    public init(
        repository: ForgeRepositoryIdentity,
        baseRepository: ForgeRepositoryIdentity,
        base: ForgeRefName,
        headRepository: ForgeRepositoryIdentity,
        head: ForgeRefName
    ) throws {
        guard repository == baseRepository else {
            throw ForgePullRequestWorkflowError.mismatchedRepository
        }
        guard repository.forge == headRepository.forge else {
            throw ForgePullRequestWorkflowError.mismatchedForge
        }
        self.repository = repository
        self.baseRepository = baseRepository
        self.base = base
        self.headRepository = headRepository
        self.head = head
    }
}

public enum ForgeDuplicatePullRequestDecision: Hashable, Sendable {
    case create
    case openExisting(ForgePullRequestSummary)
}

public enum ForgeDuplicatePullRequestPolicy {
    public static func decision(
        for key: ForgePullRequestComparisonKey,
        among pullRequests: [ForgePullRequestSummary]
    ) -> ForgeDuplicatePullRequestDecision {
        let match = pullRequests
            .filter { summary in
                guard summary.repository == key.repository,
                      summary.state == .open,
                      case let .available(base) = summary.base,
                      case let .available(head) = summary.head,
                      let headRepository = head.repository
                else { return false }
                return base.repository == key.baseRepository
                    && base.name == key.base
                    && headRepository == key.headRepository
                    && head.name == key.head
            }
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.number.rawValue < $1.number.rawValue
            }
            .first
        return match.map(ForgeDuplicatePullRequestDecision.openExisting) ?? .create
    }
}

public struct ForgePullRequestEditableSnapshot: Codable, Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let number: ForgeItemNumber
    public let title: String
    public let bodyMarkdown: String
    public let updatedAt: Date

    public init(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        title: String,
        bodyMarkdown: String,
        updatedAt: Date
    ) throws {
        guard ForgePathComponent.isNonemptyPrintable(title) else {
            throw ForgePullRequestWorkflowError.invalidTitle
        }
        self.repository = repository
        self.number = number
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            number: container.decode(ForgeItemNumber.self, forKey: .number),
            title: container.decode(String.self, forKey: .title),
            bodyMarkdown: container.decode(String.self, forKey: .bodyMarkdown),
            updatedAt: container.decode(Date.self, forKey: .updatedAt)
        )
    }
}

public struct ForgePullRequestEdit: Codable, Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let number: ForgeItemNumber
    public let title: String
    public let bodyMarkdown: String
    public let expectedUpdatedAt: Date

    public init(snapshot: ForgePullRequestEditableSnapshot, title: String, bodyMarkdown: String) throws {
        guard ForgePathComponent.isNonemptyPrintable(title) else {
            throw ForgePullRequestWorkflowError.invalidTitle
        }
        repository = snapshot.repository
        number = snapshot.number
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        expectedUpdatedAt = snapshot.updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snapshot = try ForgePullRequestEditableSnapshot(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            number: container.decode(ForgeItemNumber.self, forKey: .number),
            title: container.decode(String.self, forKey: .title),
            bodyMarkdown: container.decode(String.self, forKey: .bodyMarkdown),
            updatedAt: container.decode(Date.self, forKey: .expectedUpdatedAt)
        )
        try self.init(snapshot: snapshot, title: snapshot.title, bodyMarkdown: snapshot.bodyMarkdown)
    }

    public func validate(current: ForgePullRequestEditableSnapshot) throws {
        guard current.repository == repository, current.number == number else {
            throw ForgePullRequestWorkflowError.mismatchedRepository
        }
        guard current.updatedAt == expectedUpdatedAt else {
            throw ForgePullRequestWorkflowError.editConflict
        }
    }
}

public struct ForgePushPullRequestIntent: Hashable, Sendable {
    public let form: ForgePullRequestCreationForm
    public let draftIdentity: ForgeDraftIdentity

    public init(form: ForgePullRequestCreationForm, draftIdentity: ForgeDraftIdentity) throws {
        guard case let .createPullRequest(repository, base, head) = draftIdentity.destination,
              repository == form.repository,
              base == form.base.name,
              head == form.head.name,
              draftIdentity.accountID.forge == form.repository.forge,
              draftIdentity.displayedPullRequestHead == nil
        else {
            throw ForgePullRequestWorkflowError.mismatchedRepository
        }
        self.form = form
        self.draftIdentity = draftIdentity
    }
}

public enum ForgePushPullRequestState: Hashable, Sendable {
    case idle
    case pushSheet(createPullRequestSelected: Bool, intent: ForgePushPullRequestIntent?)
    case pushing(createPullRequestAfterSuccess: Bool, intent: ForgePushPullRequestIntent?)
    case createSheet(ForgePushPullRequestIntent)
    case draftPreserved(ForgePushPullRequestIntent)
    case completed(ForgeDestination)

    public func applying(_ event: ForgePushPullRequestEvent) throws -> Self {
        switch (self, event) {
        case (.idle, let .newPullRequest(branchAlreadyPushed, intent)):
            return branchAlreadyPushed
                ? .createSheet(intent)
                : .pushSheet(createPullRequestSelected: true, intent: intent)
        case let (.idle, .ordinaryPush(intent)):
            return .pushSheet(createPullRequestSelected: false, intent: intent)
        case let (.pushSheet(_, intent), .beginPush(createPullRequestSelected)):
            if createPullRequestSelected, intent == nil {
                throw ForgePullRequestWorkflowError.invalidTransition
            }
            return .pushing(
                createPullRequestAfterSuccess: createPullRequestSelected,
                intent: intent
            )
        case (.pushing(false, _), .pushSucceeded):
            return .idle
        case let (.pushing(true, intent?), .pushSucceeded):
            return .createSheet(intent)
        case let (.pushing(true, intent?), .pushFailed),
             let (.pushSheet(true, intent?), .cancel):
            return .draftPreserved(intent)
        case (.pushing, .pushFailed), (.pushSheet, .cancel):
            return .idle
        case let (.createSheet(intent), .cancel):
            return .draftPreserved(intent)
        case let (.createSheet(intent), .creationFailed):
            return .draftPreserved(intent)
        case let (.createSheet, .creationSucceeded(destination)),
             let (.createSheet, .existingPullRequest(destination)):
            return .completed(destination)
        case let (.draftPreserved(intent), .reopenDraft):
            return .createSheet(intent)
        case (.completed, .reset), (.draftPreserved, .discardDraft):
            return .idle
        default:
            throw ForgePullRequestWorkflowError.invalidTransition
        }
    }
}

public enum ForgePushPullRequestEvent: Hashable, Sendable {
    case newPullRequest(branchAlreadyPushed: Bool, intent: ForgePushPullRequestIntent)
    case ordinaryPush(intent: ForgePushPullRequestIntent?)
    case beginPush(createPullRequestSelected: Bool)
    case pushSucceeded
    case pushFailed
    case cancel
    case creationSucceeded(ForgeDestination)
    case existingPullRequest(ForgeDestination)
    case creationFailed
    case reopenDraft
    case discardDraft
    case reset
}

public struct ForgeLocalWorkingState: Codable, Hashable, Sendable {
    public let stagedCount: Int
    public let unstagedCount: Int
    public let untrackedCount: Int
    public let conflictCount: Int
    public let operationName: String?

    public init(
        stagedCount: Int,
        unstagedCount: Int,
        untrackedCount: Int,
        conflictCount: Int,
        operationName: String? = nil
    ) {
        self.stagedCount = max(0, stagedCount)
        self.unstagedCount = max(0, unstagedCount)
        self.untrackedCount = max(0, untrackedCount)
        self.conflictCount = max(0, conflictCount)
        self.operationName = operationName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            stagedCount: container.decode(Int.self, forKey: .stagedCount),
            unstagedCount: container.decode(Int.self, forKey: .unstagedCount),
            untrackedCount: container.decode(Int.self, forKey: .untrackedCount),
            conflictCount: container.decode(Int.self, forKey: .conflictCount),
            operationName: container.decodeIfPresent(String.self, forKey: .operationName)
        )
    }

    public var isClean: Bool {
        stagedCount == 0 && unstagedCount == 0 && untrackedCount == 0 && conflictCount == 0 && operationName == nil
    }
}

public struct ForgeGitRemote: Codable, Hashable, Sendable {
    public let name: String
    public let repository: ForgeRepositoryIdentity?
    public let fetchURL: URL

    public init(name: String, repository: ForgeRepositoryIdentity?, fetchURL: URL) throws {
        guard (try? ForgeRefName(name)) != nil else {
            throw ForgePullRequestWorkflowError.invalidRemoteName
        }
        guard let components = URLComponents(url: fetchURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["https", "ssh", "git"].contains(scheme),
              components.host?.isEmpty == false,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              scheme == "ssh" ? (components.user == nil || components.user == "git") : components.user == nil
        else {
            throw ForgePullRequestWorkflowError.invalidRemoteURL
        }
        self.name = name
        self.repository = repository
        self.fetchURL = fetchURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: container.decode(String.self, forKey: .name),
            repository: container.decodeIfPresent(ForgeRepositoryIdentity.self, forKey: .repository),
            fetchURL: container.decode(URL.self, forKey: .fetchURL)
        )
    }
}

public struct ForgePullRequestCheckoutPlan: Codable, Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let pullRequest: ForgeItemNumber
    public let remote: ForgeGitRemote
    public let fetchRefspec: String
    public let localBranch: ForgeRefName
    public let expectedHead: ForgeCommitID
    public let addsRemote: Bool

    public init(
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        remote: ForgeGitRemote,
        fetchRefspec: String,
        localBranch: ForgeRefName,
        expectedHead: ForgeCommitID,
        addsRemote: Bool
    ) throws {
        guard remote.repository?.forge == nil || remote.repository?.forge == repository.forge else {
            throw ForgePullRequestWorkflowError.mismatchedForge
        }
        let halves = fetchRefspec.split(separator: ":", omittingEmptySubsequences: false)
        let sourcePrefix = "+refs/heads/"
        guard halves.count == 2,
              halves[0].hasPrefix(sourcePrefix),
              let branch = try? ForgeRefName(String(halves[0].dropFirst(sourcePrefix.count))),
              halves[1] == "refs/remotes/\(remote.name)/\(branch.value)"
        else {
            throw ForgePullRequestWorkflowError.invalidRefspec
        }
        self.repository = repository
        self.pullRequest = pullRequest
        self.remote = remote
        self.fetchRefspec = fetchRefspec
        self.localBranch = localBranch
        self.expectedHead = expectedHead
        self.addsRemote = addsRemote
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            pullRequest: container.decode(ForgeItemNumber.self, forKey: .pullRequest),
            remote: container.decode(ForgeGitRemote.self, forKey: .remote),
            fetchRefspec: container.decode(String.self, forKey: .fetchRefspec),
            localBranch: container.decode(ForgeRefName.self, forKey: .localBranch),
            expectedHead: container.decode(ForgeCommitID.self, forKey: .expectedHead),
            addsRemote: container.decode(Bool.self, forKey: .addsRemote)
        )
    }
}

public enum ForgePullRequestCheckoutPolicy {
    public static func plan(
        pullRequest: ForgePullRequestSummary,
        workingState: ForgeLocalWorkingState,
        remotes: [ForgeGitRemote],
        existingLocalBranches: Set<ForgeRefName>,
        headRemoteURL: URL
    ) throws -> ForgePullRequestCheckoutPlan {
        guard workingState.isClean else { throw ForgePullRequestWorkflowError.unsafeWorkingState }
        guard case let .available(headValue) = pullRequest.head,
              let head = headValue.reference
        else {
            throw ForgePullRequestWorkflowError.headReferenceUnavailable
        }
        let remote: ForgeGitRemote
        let addsRemote: Bool
        if let existing = remotes.first(where: { $0.repository == head.repository }) {
            remote = existing
            addsRemote = false
        } else {
            let name = collisionSafeRemoteName(owner: head.repository.owner, existing: Set(remotes.map(\.name)))
            remote = try ForgeGitRemote(name: name, repository: head.repository, fetchURL: headRemoteURL)
            addsRemote = true
        }
        guard remoteURL(remote.fetchURL, exactlyMatches: head.repository) else {
            throw ForgePullRequestWorkflowError.invalidRemoteURL
        }
        let localBranch = try collisionSafeBranchName(
            pullRequest: pullRequest.number,
            headOwner: head.repository.owner,
            existing: existingLocalBranches
        )
        let refspec = "+refs/heads/\(head.name.value):refs/remotes/\(remote.name)/\(head.name.value)"
        return try ForgePullRequestCheckoutPlan(
            repository: pullRequest.repository,
            pullRequest: pullRequest.number,
            remote: remote,
            fetchRefspec: refspec,
            localBranch: localBranch,
            expectedHead: head.commit,
            addsRemote: addsRemote
        )
    }

    private static func collisionSafeRemoteName(owner: String, existing: Set<String>) -> String {
        let normalized = safeComponent(String(owner.split(separator: "/").last!))
        let root = "github-\(normalized.isEmpty ? "contributor" : normalized)"
        return collisionSafeName(root: root, existing: existing)
    }

    private static func collisionSafeBranchName(
        pullRequest: ForgeItemNumber,
        headOwner: String,
        existing: Set<ForgeRefName>
    ) throws -> ForgeRefName {
        let names = Set(existing.map(\.value))
        let root = "pr/\(pullRequest.rawValue)"
        if !names.contains(root) {
            return try ForgeRefName(root)
        }
        let owner = safeComponent(String(headOwner.split(separator: "/").last!))
        let qualified = "\(root)-\(owner.isEmpty ? "contributor" : owner)"
        return try ForgeRefName(collisionSafeName(root: qualified, existing: names))
    }

    private static func collisionSafeName(root: String, existing: Set<String>) -> String {
        if !existing.contains(root) {
            return root
        }
        var suffix = 2
        while existing.contains("\(root)-\(suffix)") {
            suffix += 1
        }
        return "\(root)-\(suffix)"
    }

    private static func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
    }

    private static func remoteURL(
        _ url: URL,
        exactlyMatches repository: ForgeRepositoryIdentity
    ) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == repository.forge.origin.host.lowercased(),
              components.port == repository.forge.origin.port,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.scheme?.lowercased() == "ssh"
              ? (components.user == nil || components.user == "git")
              : components.user == nil
        else { return false }

        guard components.percentEncodedPath.hasPrefix("/") else { return false }
        let encodedPath = components.percentEncodedPath.dropFirst()
            .split(separator: "/", omittingEmptySubsequences: false)
        guard !encodedPath.isEmpty,
              encodedPath.allSatisfy({ !$0.isEmpty })
        else { return false }
        var actual: [String] = []
        for component in encodedPath {
            guard let decoded = String(component).removingPercentEncoding else { return false }
            actual.append(decoded.precomposedStringWithCanonicalMapping)
        }
        if actual[actual.count - 1].lowercased().hasSuffix(".git") {
            actual[actual.count - 1].removeLast(4)
        }
        let expected = repository.ownerPathComponents + [repository.name]
        if repository.forge.kind == .github {
            return actual.map { $0.lowercased() } == expected.map { $0.lowercased() }
        }
        return actual == expected
    }
}

public enum ForgeCloneRepositoryRelationship: String, Codable, Hashable, Sendable {
    case owned
    case organization
    case starred
}

public enum ForgeCloneTransport: String, Codable, Hashable, Sendable {
    case ssh
    case https
}

public struct ForgeCloneRequest: Codable, Hashable, Sendable {
    public let accountID: ForgeAccountID
    public let repository: ForgeRepositoryIdentity
    public let relationship: ForgeCloneRepositoryRelationship
    public let transport: ForgeCloneTransport

    public init(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        relationship: ForgeCloneRepositoryRelationship,
        transport: ForgeCloneTransport
    ) throws {
        guard accountID.forge == repository.forge else {
            throw ForgePullRequestWorkflowError.mismatchedForge
        }
        guard relationship != .starred else {
            throw ForgePullRequestWorkflowError.unsupportedRepositoryRelationship
        }
        self.accountID = accountID
        self.repository = repository
        self.relationship = relationship
        self.transport = transport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: container.decode(ForgeAccountID.self, forKey: .accountID),
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            relationship: container.decode(ForgeCloneRepositoryRelationship.self, forKey: .relationship),
            transport: container.decode(ForgeCloneTransport.self, forKey: .transport)
        )
    }
}

public struct ForgeSyncForkPlan: Codable, Hashable, Sendable {
    public let fork: ForgeRepositoryIdentity
    public let parent: ForgeRepositoryIdentity
    public let branch: ForgeRefName
    public let localFetchRemoteName: String

    public init(
        fork: ForgeRepositoryIdentity,
        parent: ForgeRepositoryIdentity,
        branch: ForgeRefName,
        localFetchRemoteName: String
    ) throws {
        guard fork.forge == parent.forge else { throw ForgePullRequestWorkflowError.mismatchedForge }
        guard fork != parent else { throw ForgePullRequestWorkflowError.unsupportedRepositoryRelationship }
        guard (try? ForgeRefName(localFetchRemoteName)) != nil else {
            throw ForgePullRequestWorkflowError.invalidRemoteName
        }
        self.fork = fork
        self.parent = parent
        self.branch = branch
        self.localFetchRemoteName = localFetchRemoteName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            fork: container.decode(ForgeRepositoryIdentity.self, forKey: .fork),
            parent: container.decode(ForgeRepositoryIdentity.self, forKey: .parent),
            branch: container.decode(ForgeRefName.self, forKey: .branch),
            localFetchRemoteName: container.decode(String.self, forKey: .localFetchRemoteName)
        )
    }

    /// Sync Fork is server-side. A dirty or diverged checkout never disables
    /// this plan; local state is inspected only after the mutation when the
    /// caller offers the explicit fetch/report step.
    public func remainsEligible(workingState _: ForgeLocalWorkingState) -> Bool {
        true
    }
}
