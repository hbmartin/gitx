import Foundation
import OSLog // swiftlint:disable:this unused_import

// Objective-C actions call this through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBRepositoryActionContextResolver)
final class RepositoryActionContextResolver: NSObject {
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryActionContextResolver")

    @objc(refishForRepresentedObject:selectedCommit:allowedTypes:repository:)
    func refish(
        representedObject: Any?,
        selectedCommit: PBGitCommit?,
        allowedTypes: [String]?,
        repository: PBGitRepository
    ) -> PBGitRefish? {
        if let refish = representedObject as? PBGitRefish,
           allowedTypes == nil || refish.refishType().map({ allowedTypes?.contains($0) == true }) == true
        {
            logger.debug("Resolved action context from represented reference")
            return refish
        }

        if let remoteName = representedObject as? String,
           allowedTypes?.contains(kGitXRemoteType) == true,
           repository.remotes()?.contains(remoteName) == true
        {
            logger.debug("Resolved action context from configured remote name")
            return PBGitRef(string: kGitXRemoteRefPrefix + remoteName)
        }

        if representedObject != nil {
            logger.debug("Rejected invalid represented action context")
            return nil
        }

        guard allowedTypes == nil || allowedTypes?.contains(kGitXCommitType) == true else {
            logger.debug("Rejected action context without an allowed represented value")
            return nil
        }
        logger.debug("Resolved action context from history selection")
        return selectedCommit
    }

    @objc(selectedRefWithSidebarRef:sidebarRemoteName:historyRefs:)
    func selectedRef(
        sidebarRef: PBGitRef?,
        sidebarRemoteName: String?,
        historyRefs: [PBGitRef]?
    ) -> PBGitRef? {
        if let sidebarRemoteName {
            logger.debug("Resolved selected remote from sidebar context")
            return PBGitRef(string: kGitXRemoteRefPrefix + sidebarRemoteName)
        }
        if let sidebarRef {
            logger.debug("Resolved selected reference from sidebar context")
            return sidebarRef
        }

        let branchRefs = historyRefs?.filter(\.isBranch) ?? []
        guard branchRefs.count == 1 else {
            logger.debug("Rejected ambiguous history reference selection")
            return nil
        }
        logger.debug("Resolved selected branch from history context")
        return branchRefs[0]
    }
}

// swiftlint:enable unused_declaration
