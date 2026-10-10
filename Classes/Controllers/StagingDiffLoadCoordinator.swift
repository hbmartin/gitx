import CryptoKit
import Foundation

/// Authority follows exact Git bytes and content, independent of refresh generations.
nonisolated struct StagingDiffActionContext: Equatable, Sendable {
    let rawPath: Data
    let staged: Bool
    let parentTree: String
    let contentIdentity: String
    let contextLines: UInt
    let status: Int
    let hasStagedChanges: Bool
    let visualIdentity: String

    init(request: StagingDiffLoadRequest, diff: String, parentTree: String, visualIdentity: String) {
        self.init(rawPath: request.rawPath, staged: request.staged, parentTree: parentTree, diff: diff,
                  contextLines: request.contextLines, status: request.status,
                  hasStagedChanges: request.hasStagedChanges, visualIdentity: visualIdentity)
    }

    init(rawPath: Data, staged: Bool, parentTree: String, diff: String, contextLines: UInt,
         status: Int, hasStagedChanges: Bool, visualIdentity: String = "")
    {
        self.rawPath = rawPath
        self.staged = staged
        self.parentTree = parentTree
        self.contextLines = contextLines
        self.status = status
        self.hasStagedChanges = hasStagedChanges
        self.visualIdentity = visualIdentity
        var bytes = Data()
        for part in [rawPath, Data((staged ? "staged" : "unstaged").utf8), Data(parentTree.utf8), Data(diff.utf8),
                     Data(String(contextLines).utf8), Data(String(status).utf8), Data((hasStagedChanges ? "yes" : "no").utf8), Data(visualIdentity.utf8)]
        {
            bytes.append(Data(String(part.count).utf8)); bytes.append(0); bytes.append(part)
        }
        contentIdentity = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    var dictionary: [String: Any] {
        ["rawPath": rawPath, "staged": staged, "parentTree": parentTree, "contentIdentity": contentIdentity,
         "contextLines": contextLines, "status": status, "hasStagedChanges": hasStagedChanges, "visualIdentity": visualIdentity]
    }

    init?(dictionary: [String: Any]) {
        guard dictionary.count == 8,
              let path = dictionary["rawPath"] as? Data, !path.isEmpty, !path.contains(0),
              let side = dictionary["staged"] as? Bool,
              let tree = dictionary["parentTree"] as? String, !tree.isEmpty,
              let identity = dictionary["contentIdentity"] as? String, identity.utf8.count == 64,
              identity.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }),
              let lines = dictionary["contextLines"] as? UInt,
              let status = dictionary["status"] as? Int,
              let stagedChanges = dictionary["hasStagedChanges"] as? Bool,
              let visual = dictionary["visualIdentity"] as? String else { return nil }
        rawPath = path; staged = side; parentTree = tree; contentIdentity = identity
        contextLines = lines; self.status = status; hasStagedChanges = stagedChanges; visualIdentity = visual
    }

    func permits(_ action: String) -> Bool {
        switch action {
        case "stage", "discard": !staged
        case "unstage": staged
        default: false
        }
    }
}

struct StagingDiffLoadRequest: Equatable, Sendable {
    let path: String
    let rawPath: Data
    let status: Int
    let hasStagedChanges: Bool
    let staged: Bool
    let parentTree: String
    let contextLines: UInt
    let workingDirectoryURL: URL?
    let syntheticUntracked: Bool

    init(path: String, rawPath: Data? = nil, status: Int, hasStagedChanges: Bool, staged: Bool,
         parentTree: String, contextLines: UInt, workingDirectoryURL: URL?, syntheticUntracked: Bool)
    {
        self.path = path
        self.rawPath = rawPath ?? Data(path.utf8)
        self.status = status
        self.hasStagedChanges = hasStagedChanges
        self.staged = staged
        self.parentTree = parentTree
        self.contextLines = contextLines
        self.workingDirectoryURL = workingDirectoryURL
        self.syntheticUntracked = syntheticUntracked
    }
}

enum StagingDiffProduction: Equatable, Sendable {
    case validated(diff: String, parentTree: String, visualIdentity: String)
    case failure(String)
    case readOnly(diff: String, detail: String)
}

nonisolated struct StagingDiffSectionDescriptor: Equatable, Sendable {
    let title: String
    let path: String
    let text: String
    let context: String
    let stagingChrome: Bool
    let actionContext: StagingDiffActionContext?

    init(title: String, path: String, text: String, context: String, stagingChrome: Bool,
         actionContext: StagingDiffActionContext? = nil)
    {
        self.title = title
        self.path = path
        self.text = text
        self.context = context
        self.stagingChrome = stagingChrome
        self.actionContext = actionContext
    }
}

struct StagingDiffLoadOutput: Equatable, Sendable {
    let sections: [StagingDiffSectionDescriptor]
    let cacheIdentifier: String
}

/// Serializes staging-diff production while letting the main thread continue
/// displaying the last completed result. Superseded generations are skipped
/// before production and between sections; running obsolete work cannot publish.
// swift6-safety-justification: The producer and request values are Sendable, and stateLock protects all mutable state.
final nonisolated class StagingDiffLoadCoordinator: @unchecked Sendable {
    typealias Producer = @Sendable (StagingDiffLoadRequest) -> StagingDiffProduction
    typealias Delivery = @MainActor @Sendable (StagingDiffLoadOutput) -> Void

    private struct State {
        var latestGeneration: UInt = 0
        var pendingGeneration: UInt?
    }

    private let producer: @Sendable (StagingDiffLoadRequest, @Sendable () -> Bool) -> StagingDiffProduction
    private let queue = DispatchQueue(label: "com.gitx.staging-diff-load", qos: .userInitiated)
    private let stateLock = NSLock()
    private var state = State()

    init(producer: @escaping Producer) {
        self.producer = { request, _ in producer(request) }
    }

    init(cancellableProducer: @escaping @Sendable (StagingDiffLoadRequest, @Sendable () -> Bool) -> StagingDiffProduction) {
        producer = cancellableProducer
    }

    @discardableResult
    func schedule(
        _ requests: [StagingDiffLoadRequest],
        delivery: @escaping Delivery
    ) -> UInt {
        let (generation, supersededGeneration) = mutateState { state in
            state.latestGeneration &+= 1
            let supersededGeneration = state.pendingGeneration
            state.pendingGeneration = state.latestGeneration
            return (state.latestGeneration, supersededGeneration)
        }
        if let supersededGeneration {
            NSLog(
                "[GitX] Superseding staging diff generation %llu with %llu",
                UInt64(supersededGeneration),
                UInt64(generation)
            )
        }
        NSLog(
            "[GitX] Scheduled staging diff generation %llu with %ld request(s)",
            UInt64(generation),
            requests.count
        )

        queue.async { [self] in
            guard let output = load(requests, generation: generation) else { return }
            DispatchQueue.main.async { [self] in
                let isCurrent = mutateState { state in
                    guard state.latestGeneration == generation else { return false }
                    state.pendingGeneration = nil
                    return true
                }
                guard isCurrent else {
                    NSLog("[GitX] Discarded stale staging diff generation %llu", UInt64(generation))
                    return
                }
                NSLog(
                    "[GitX] Delivering staging diff generation %llu with %ld section(s)",
                    UInt64(generation),
                    output.sections.count
                )
                delivery(output)
            }
        }
        return generation
    }

    @discardableResult
    func invalidate() -> UInt {
        let (generation, supersededGeneration) = mutateState { state in
            state.latestGeneration &+= 1
            let supersededGeneration = state.pendingGeneration
            state.pendingGeneration = nil
            return (state.latestGeneration, supersededGeneration)
        }
        if let supersededGeneration {
            NSLog(
                "[GitX] Invalidated staging diff generation %llu with generation %llu",
                UInt64(supersededGeneration),
                UInt64(generation)
            )
        } else {
            NSLog("[GitX] Invalidated staging diff delivery at generation %llu", UInt64(generation))
        }
        return generation
    }

    private func load(
        _ requests: [StagingDiffLoadRequest],
        generation: UInt
    ) -> StagingDiffLoadOutput? {
        var sections: [StagingDiffSectionDescriptor] = []
        let start = ProcessInfo.processInfo.systemUptime
        for request in requests {
            guard mutateState({ $0.latestGeneration == generation }) else {
                NSLog("[GitX] Skipped superseded staging producer generation %llu", UInt64(generation))
                return nil
            }
            NSLog(
                "[GitX] Loading staging diff generation %llu for %@",
                UInt64(generation),
                request.path
            )
            switch producer(request, { [self] in mutateState { $0.latestGeneration != generation } }) {
            case let .validated(diff, parentTree, visualIdentity):
                let token = StagingDiffActionContext(request: request, diff: diff, parentTree: parentTree, visualIdentity: visualIdentity)
                sections.append(successfulSection(for: request, diff: diff, actionContext: token))
            case let .readOnly(diff, detail):
                sections.append(StagingDiffSectionDescriptor(title: "Actions unavailable — " + request.path, path: request.path,
                                                             text: diff, context: "read-only", stagingChrome: false))
                NSLog("[GitX] Staging image actions unavailable: %@", detail)
            case let .failure(detail):
                NSLog(
                    "[GitX] Staging diff generation %llu failed for %@: %@",
                    UInt64(generation),
                    request.path,
                    detail
                )
                sections.append(failedSection(for: request, detail: detail))
            }
        }
        NSLog("[GitX] Staging producer generation %llu produced %ld sections in %.3f ms", UInt64(generation), sections.count, (ProcessInfo.processInfo.systemUptime - start) * 1000)
        let selection = requests
            .map { "\($0.staged ? "s" : "u"):\($0.rawPath.base64EncodedString())" }
            .joined(separator: "|")
        let contextLines = requests.first?.contextLines ?? 0
        return StagingDiffLoadOutput(
            sections: sections,
            cacheIdentifier: "staging:\(selection):ctx\(contextLines)"
        )
    }

    private func successfulSection(
        for request: StagingDiffLoadRequest,
        diff: String,
        actionContext: StagingDiffActionContext
    ) -> StagingDiffSectionDescriptor {
        let sideTitle = request.staged
            ? NSLocalizedString("Staged", comment: "Staging diff section prefix for staged changes")
            : NSLocalizedString("Unstaged", comment: "Staging diff section prefix for unstaged changes")
        return StagingDiffSectionDescriptor(
            title: "\(sideTitle) — \(request.path)",
            path: request.path,
            text: diff,
            context: request.staged ? "staged" : "unstaged",
            stagingChrome: true,
            actionContext: actionContext
        )
    }

    private func failedSection(
        for request: StagingDiffLoadRequest,
        detail: String
    ) -> StagingDiffSectionDescriptor {
        let title = String(
            format: NSLocalizedString(
                "Diff unavailable — %@",
                comment: "Staging diff section title when one selected file cannot be loaded"
            ),
            request.path
        )
        let explanation = String(
            format: NSLocalizedString(
                "Half Dark could not load the diff for %@.",
                comment: "Staging diff explanation when one selected file cannot be loaded"
            ),
            request.path
        )
        return StagingDiffSectionDescriptor(
            title: title,
            path: request.path,
            text: explanation + "\n\n" + detail,
            context: "readOnly",
            stagingChrome: false
        )
    }

    private func mutateState<Result>(_ mutation: (inout State) -> Result) -> Result {
        stateLock.lock()
        defer { stateLock.unlock() }
        return mutation(&state)
    }
}
