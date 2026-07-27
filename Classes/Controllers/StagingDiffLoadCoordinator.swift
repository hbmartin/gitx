import Foundation

struct StagingDiffLoadRequest: Equatable, Sendable {
    let path: String
    let status: Int
    let hasStagedChanges: Bool
    let staged: Bool
    let parentTree: String
    let contextLines: UInt
    let workingDirectoryURL: URL?
    let syntheticUntracked: Bool
}

enum StagingDiffProduction: Equatable, Sendable {
    case success(String)
    case failure(String)
}

struct StagingDiffSectionDescriptor: Equatable, Sendable {
    let title: String
    let path: String
    let text: String
    let context: String
    let stagingChrome: Bool
}

struct StagingDiffLoadOutput: Equatable, Sendable {
    let sections: [StagingDiffSectionDescriptor]
    let cacheIdentifier: String
}

/// Serializes staging-diff production while letting the main thread continue
/// displaying the last completed result. Generations are intentionally not
/// cancelled: completed obsolete work is discarded at the delivery boundary.
// swift6-safety-justification: The producer and request values are Sendable, and stateLock protects all mutable state.
final nonisolated class StagingDiffLoadCoordinator: @unchecked Sendable {
    typealias Producer = @Sendable (StagingDiffLoadRequest) -> StagingDiffProduction
    typealias Delivery = @MainActor @Sendable (StagingDiffLoadOutput) -> Void

    private struct State {
        var latestGeneration: UInt = 0
        var pendingGeneration: UInt?
    }

    private let producer: Producer
    private let queue = DispatchQueue(label: "com.gitx.staging-diff-load", qos: .userInitiated)
    private let stateLock = NSLock()
    private var state = State()

    init(producer: @escaping Producer) {
        self.producer = producer
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
            let output = load(requests, generation: generation)
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
    ) -> StagingDiffLoadOutput {
        let sections = requests.map { request in
            NSLog(
                "[GitX] Loading staging diff generation %llu for %@",
                UInt64(generation),
                request.path
            )
            switch producer(request) {
            case let .success(diff):
                return successfulSection(for: request, diff: diff)
            case let .failure(detail):
                NSLog(
                    "[GitX] Staging diff generation %llu failed for %@: %@",
                    UInt64(generation),
                    request.path,
                    detail
                )
                return failedSection(for: request, detail: detail)
            }
        }
        let selection = requests
            .map { "\($0.staged ? "s" : "u"):\($0.path)" }
            .joined(separator: "|")
        let contextLines = requests.first?.contextLines ?? 0
        return StagingDiffLoadOutput(
            sections: sections,
            cacheIdentifier: "staging:\(selection):ctx\(contextLines)"
        )
    }

    private func successfulSection(
        for request: StagingDiffLoadRequest,
        diff: String
    ) -> StagingDiffSectionDescriptor {
        let sideTitle = request.staged
            ? NSLocalizedString("Staged", comment: "Staging diff section prefix for staged changes")
            : NSLocalizedString("Unstaged", comment: "Staging diff section prefix for unstaged changes")
        return StagingDiffSectionDescriptor(
            title: "\(sideTitle) — \(request.path)",
            path: request.path,
            text: diff,
            context: request.staged ? "staged" : "unstaged",
            stagingChrome: true
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
                "GitX could not load the diff for %@.",
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
