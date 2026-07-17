import Foundation
import OSLog // swiftlint:disable:this unused_import

// SwiftLint's analyzer cannot see these entry points through GitX-Swift.h.
// swiftlint:disable unused_declaration
/// Objective-C repository services use these immutable snapshots from their existing worker queues.
@objc(PBRepositoryReferenceSnapshot)
final nonisolated class RepositoryReferenceSnapshot: NSObject {
    @objc let references: NSMutableDictionary
    @objc let branches: [PBGitRevSpecifier]
    @objc let submodules: [GTSubmodule]

    init(
        references: NSMutableDictionary,
        branches: [PBGitRevSpecifier],
        submodules: [GTSubmodule]
    ) {
        self.references = references
        self.branches = branches
        self.submodules = submodules
    }
}

/// This store preserves the pre-Swift synchronous Objective-C API, including background diff callers.
@objc(PBRepositoryReferenceStore)
final nonisolated class RepositoryReferenceStore: NSObject {
    private unowned let repository: PBGitRepository
    private let runner: GitCommandRunning
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryReferenceStore")
    private var cachedHeadRef: PBGitRevSpecifier?
    private var cachedHeadOID: GTOID?

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        runner = RepositoryGitCommandRunner(repository: repository)
        super.init()
    }

    @objc(initWithRepository:runner:)
    init(repository: PBGitRepository, runner: GitCommandRunning) {
        self.repository = repository
        self.runner = runner
        super.init()
    }

    @objc(invalidateHeadCache)
    func invalidateHeadCache() {
        cachedHeadRef = nil
        cachedHeadOID = nil
        logger.debug("Repository HEAD cache invalidated")
    }

    @objc(loadReferenceSnapshot)
    func loadReferenceSnapshot() -> RepositoryReferenceSnapshot {
        invalidateHeadCache()
        guard let gitRepository = repository.gtRepo else {
            return RepositoryReferenceSnapshot(
                references: NSMutableDictionary(),
                branches: [],
                submodules: []
            )
        }
        let references = NSMutableDictionary()
        var branches: [PBGitRevSpecifier] = []
        var submodules: [GTSubmodule] = []
        do {
            var referenceNames = try gitRepository.referenceNames()
            if gitRepository.isHEADDetached {
                referenceNames.append("HEAD")
            }
            for referenceName in referenceNames {
                guard let reference = try? gitRepository.lookUpReference(withName: referenceName) else {
                    logger.error("Repository reference disappeared during reload")
                    continue
                }
                if reference.isRemote, reference.referenceType == .symbolic {
                    continue
                }
                let ref = PBGitRef(string: referenceName)
                branches.append(PBGitRevSpecifier(ref: ref))
                add(reference, to: references)
            }
        } catch {
            logger.error("Repository reference reload failed")
        }
        gitRepository.enumerateSubmodulesRecursively(false) { submodule, _, _ in
            if let submodule {
                submodules.append(submodule)
            }
        }
        logger.debug("Repository reference snapshot loaded")
        return RepositoryReferenceSnapshot(
            references: references,
            branches: branches,
            submodules: submodules
        )
    }

    private func add(_ reference: GTReference, to references: NSMutableDictionary) {
        guard let target = reference.resolvedTarget as? GTObject else {
            logger.error("Repository reference target could not be resolved")
            return
        }
        let oid = target.oid
        let ref = PBGitRef(string: reference.name)
        if let current = references[oid] as? NSMutableArray {
            guard !current.contains(ref) else { return }
            current.add(ref)
        } else {
            references[oid] = NSMutableArray(object: ref)
        }
    }

    @objc(headRef)
    func headRef() -> PBGitRevSpecifier? {
        if let cachedHeadRef, cachedHeadOID != nil {
            return cachedHeadRef
        }
        guard let gitRepository = repository.gtRepo else { return nil }
        do {
            let head = try gitRepository.lookUpReference(withName: "HEAD")
            let branch: GTReference
            if gitRepository.isHEADUnborn {
                branch = head
            } else {
                branch = head.resolved
            }
            cachedHeadRef = PBGitRevSpecifier(ref: PBGitRef(string: branch.name))
            cachedHeadOID = branch.oid
            logger.debug("Repository HEAD cache populated")
            return cachedHeadRef
        } catch {
            logger.error("Repository HEAD resolution failed")
            return nil
        }
    }

    @objc(headOID)
    func headOID() -> GTOID? {
        if cachedHeadOID == nil {
            _ = headRef()
        }
        return cachedHeadOID
    }

    @objc(OIDForRef:)
    func oid(for ref: PBGitRef?) -> GTOID? {
        guard let ref else { return nil }
        if let refs = repository.refs {
            for (key, value) in refs {
                guard let oid = key as? GTOID, let values = value as? [PBGitRef] else { continue }
                if values.contains(where: { $0.isEqual(to: ref) }) {
                    return oid
                }
            }
        }
        do {
            return try repository.gtRepo?.lookUpReference(withName: ref.ref).oid
        } catch {
            logger.error("Repository reference lookup failed")
            return nil
        }
    }

    @objc(commitForOID:fromCommits:)
    func commit(for oid: GTOID?, from commits: [PBGitCommit]?) -> PBGitCommit? {
        guard let oid, let commits else { return nil }
        return commits.first { $0.oid == oid }
    }

    @objc(isOID:onSameBranchAsOID:commits:)
    func isOID(
        _ branchOID: GTOID?,
        onSameBranchAs testOID: GTOID?,
        commits: [PBGitCommit]?
    ) -> Bool {
        guard let branchOID, let testOID, let commits else { return false }
        if testOID == branchOID {
            return true
        }
        let searchOIDs = NSMutableSet(object: branchOID)
        for commit in commits {
            let commitOID = commit.oid
            if searchOIDs.contains(commitOID) {
                if testOID == commitOID {
                    return true
                }
                searchOIDs.remove(commitOID)
                searchOIDs.addObjects(from: commit.parents)
            } else if testOID == commitOID {
                return false
            }
        }
        return false
    }

    @objc(checkRefFormat:)
    func checkRefFormat(_ name: String) -> Bool {
        GTReference.isValidReferenceName(name)
    }

    @objc(refExists:)
    func refExists(_ ref: PBGitRef?) -> Bool {
        guard let ref, !ref.ref.isEmpty else { return false }
        return (try? repository.gtRepo?.lookUpReference(withName: ref.ref)) != nil
    }

    @objc(refForName:)
    func ref(forName name: String?) -> PBGitRef? {
        guard let name else { return nil }
        guard let output = try? runner.output(arguments: ["show-ref", name]), !output.isEmpty else {
            return nil
        }
        let parts = output.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2 else { return nil }
        return PBGitRef(string: String(parts[1]))
    }

    @objc(revisionExists:)
    func revisionExists(_ specification: String) -> Bool {
        guard let gitRepository = repository.gtRepo else { return false }
        return (try? gitRepository.lookUpObject(byRevParse: specification)) != nil
    }

    @objc(submoduleAtPath:error:)
    func submodule(
        atPath path: String,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> GTSubmodule? {
        let standardizedPath = (path as NSString).standardizingPath
        for case let submodule as GTSubmodule in repository.submodules {
            if standardizedPath.hasSuffix(submodule.path) {
                return submodule
            }
        }
        outputError?.pointee = RepositoryServiceError.make(
            description: "Submodule not found",
            failureReason: "The submodule at path \"\(path)\" couldn't be found."
        )
        return nil
    }
}

// swiftlint:enable unused_declaration
