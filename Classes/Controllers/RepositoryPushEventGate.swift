/// Each push attempt, including its optional retry, owns a single terminal event.
nonisolated struct RepositoryPushEventGate {
    private enum Phase {
        case awaitingConfirmation, active, finished
    }

    private var phase = Phase.awaitingConfirmation

    var isActive: Bool {
        phase == .active
    }

    mutating func accept(_ event: RepositoryPushEvent) -> Bool {
        guard phase != .finished else { return false }
        switch event {
        case .began:
            guard phase == .awaitingConfirmation else { return false }
            phase = .active
        case .cancelled:
            guard phase == .awaitingConfirmation else { return false }
            phase = .finished
        case .succeeded, .failed:
            phase = .finished
        }
        return true
    }
}
