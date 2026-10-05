import Foundation

enum RepositoryRejectedPushRecoveryPolicy {
    static func shouldOfferForceWithLease(for error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            let text = [
                error.localizedDescription,
                error.localizedFailureReason,
                error.userInfo[PBTaskTerminationOutputKey] as? String,
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: "\n")
            if text.contains("non-fast-forward") || text.contains("[rejected]") || text.contains("fetch first") {
                return true
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func recoveryReference(
        requested: PBGitRef?,
        head: PBGitRef?
    ) -> PBGitRef? {
        if let requested, requested.isBranch || requested.isTag {
            return requested
        }
        guard requested == nil, let head, head.isBranch else { return nil }
        return head
    }
}
