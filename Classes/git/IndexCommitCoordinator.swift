import Dispatch
import Foundation
import OSLog // swiftlint:disable:this unused_import

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

// swift6-safety-justification: The stored callback is invoked only on the main queue by the coordinator's serial event pipeline.
private final nonisolated class IndexCommitEventDelivery: @unchecked Sendable {
    private let handler: (IndexCommitEvent) -> Void

    init(handler: @escaping (IndexCommitEvent) -> Void) {
        self.handler = handler
    }

    func deliver(_ event: IndexCommitEvent) {
        handler(event)
    }
}

// Only holds a strong reference for a background commit; the repository is never accessed through this box off-main.
// swift6-safety-justification: The token is handed to the main queue before its final release.
private final nonisolated class RepositoryLifetimeToken: @unchecked Sendable {
    let repository: PBGitRepository?

    init(_ repository: PBGitRepository?) {
        self.repository = repository
    }
}

// swift6-safety-justification: Immutable service ownership and private serial work/event queues confine all coordination.
@objc(PBIndexCommitCoordinator)
final nonisolated class IndexCommitCoordinator: NSObject, @unchecked Sendable {
    private let service: IndexCommitService
    // Held weakly so it never contributes to a retain cycle; strong-captured per operation (see `commit`).
    private weak var repository: PBGitRepository?
    private let workQueue = DispatchQueue(
        label: "org.gitx.IndexCommitCoordinator.work",
        qos: .userInitiated
    )
    private let eventQueue = DispatchQueue(label: "org.gitx.IndexCommitCoordinator.events")
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "IndexCommitCoordinator")

    @objc(initWithService:repository:)
    init(service: IndexCommitService, repository: PBGitRepository?) {
        self.service = service
        self.repository = repository
        super.init()
    }

    @objc(commitWithRequest:eventHandler:)
    func commit(
        with request: IndexCommitRequest,
        eventHandler: @escaping @Sendable (IndexCommitEvent) -> Void
    ) {
        let delivery = IndexCommitEventDelivery(handler: eventHandler)
        logger.debug("Scheduling commit orchestration off the main thread")
        // The commit runners reference the repository `unowned`. Capture a strong reference for the whole
        // background operation so a document closed mid-commit cannot deallocate the repository underneath them.
        let lifetimeToken = RepositoryLifetimeToken(repository)
        workQueue.async { [service, eventQueue, logger, lifetimeToken] in
            withExtendedLifetime(lifetimeToken) {
                _ = service.commit(with: request) { event in
                    eventQueue.async {
                        DispatchQueue.main.async {
                            delivery.deliver(event)
                        }
                    }
                }
            }
            DispatchQueue.main.async { [lifetimeToken, logger] in
                withExtendedLifetime(lifetimeToken) {
                    logger.debug("Background commit orchestration completed; releasing repository lifetime on main")
                }
            }
        }
    }
}

// swiftlint:enable unused_declaration
