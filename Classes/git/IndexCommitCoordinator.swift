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

// swift6-safety-justification: Immutable service ownership and private serial work/event queues confine all coordination.
@objc(PBIndexCommitCoordinator)
final nonisolated class IndexCommitCoordinator: NSObject, @unchecked Sendable {
    private let service: IndexCommitService
    private let workQueue = DispatchQueue(
        label: "org.gitx.IndexCommitCoordinator.work",
        qos: .userInitiated
    )
    private let eventQueue = DispatchQueue(label: "org.gitx.IndexCommitCoordinator.events")
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "IndexCommitCoordinator")

    @objc(initWithService:)
    init(service: IndexCommitService) {
        self.service = service
        super.init()
    }

    @objc(commitWithRequest:eventHandler:)
    func commit(
        with request: IndexCommitRequest,
        eventHandler: @escaping @Sendable (IndexCommitEvent) -> Void
    ) {
        let delivery = IndexCommitEventDelivery(handler: eventHandler)
        logger.debug("Scheduling commit orchestration off the main thread")
        workQueue.async { [service, eventQueue, logger] in
            _ = service.commit(with: request) { event in
                eventQueue.async {
                    DispatchQueue.main.async {
                        delivery.deliver(event)
                    }
                }
            }
            logger.debug("Background commit orchestration completed")
        }
    }
}

// swiftlint:enable unused_declaration
