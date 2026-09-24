#if DEBUG
    import FlowDeltaCore
    import Foundation
    import Synchronization

    @objc(PBHistoryFlowRevisionProviderTestOperation)
    final nonisolated class HistoryFlowRevisionProviderTestOperation: NSObject, @unchecked Sendable {
        private let task = Mutex<Task<Void, Never>?>(nil)

        fileprivate func install(_ task: Task<Void, Never>) {
            self.task.withLock { $0 = task }
        }

        @objc func cancel() {
            task.withLock { $0?.cancel() }
        }
    }

    @objc(PBHistoryFlowRevisionProviderTestHarness)
    final nonisolated class HistoryFlowRevisionProviderTestHarness: NSObject {
        @objc(
            compareRepositoryAtURL:gitExecutableURL:base:target:maximumChangedFiles:maximumBlobBytes:completionHandler:
        )
        static func compare(
            repositoryURL: URL,
            gitExecutableURL: URL,
            base: String,
            target: String,
            maximumChangedFiles: Int,
            maximumBlobBytes: Int,
            completionHandler: @escaping @Sendable (Data?, String?) -> Void
        ) -> HistoryFlowRevisionProviderTestOperation {
            let operation = HistoryFlowRevisionProviderTestOperation()
            let task = Task.detached {
                do {
                    let comparison = try await HistoryFlowRevisionProvider(gitExecutableURL: gitExecutableURL)
                        .comparison(
                            repositoryURL: repositoryURL,
                            base: base,
                            target: target,
                            limits: AnalysisLimits(
                                maximumChangedFiles: maximumChangedFiles,
                                maximumBlobBytes: maximumBlobBytes
                            )
                        )
                    let data = try JSONEncoder().encode(comparison)
                    completionHandler(data, nil)
                } catch {
                    completionHandler(nil, String(describing: error))
                }
            }
            operation.install(task)
            return operation
        }
    }
#endif
