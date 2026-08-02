import Foundation

nonisolated struct RepositoryForgeRemoteDescriptor: Equatable, Sendable {
    let name: String
    let url: String
}

/// Shares immutable remote discovery across the short-lived coordinators used
/// by menu validation and sidebar rebuilding. A Git config revision change
/// invalidates the entry without another Git subprocess.
// swift6-safety-justification: every mutable cache access is protected by the private lock.
final nonisolated class RepositoryForgeRemoteDescriptorCache: @unchecked Sendable {
    struct Entry {
        let revision: String
        let dependencyRevisions: [String: String]
        let descriptors: [RepositoryForgeRemoteDescriptor]
    }

    static let shared = RepositoryForgeRemoteDescriptorCache()

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func descriptors(
        for key: String,
        revision: String,
        dependencyRevision: (String) -> String
    ) -> [RepositoryForgeRemoteDescriptor]? {
        lock.lock()
        let entry = entries[key]
        lock.unlock()
        guard let entry, entry.revision == revision else { return nil }
        guard entry.dependencyRevisions.allSatisfy({ dependencyRevision($0.key) == $0.value }) else {
            return nil
        }
        return entry.descriptors
    }

    func store(
        _ descriptors: [RepositoryForgeRemoteDescriptor],
        for key: String,
        revision: String,
        dependencyPaths: [String],
        dependencyRevision: (String) -> String
    ) {
        let dependencyRevisions = Dictionary(uniqueKeysWithValues: Set(dependencyPaths).map {
            ($0, dependencyRevision($0))
        })
        lock.lock()
        entries[key] = Entry(
            revision: revision,
            dependencyRevisions: dependencyRevisions,
            descriptors: descriptors
        )
        lock.unlock()
    }
}

struct RepositoryForgeRemoteDescriptorLoad: Equatable {
    let descriptors: [RepositoryForgeRemoteDescriptor]
    let reusedCache: Bool
    let isCacheable: Bool
}

struct RepositoryForgeRemoteDescriptorLoader {
    let cache: RepositoryForgeRemoteDescriptorCache

    func load(
        cacheKey: String,
        revision: String,
        remoteNames: () -> [String]?,
        remoteURL: (String) -> String?,
        dependencyPaths: () -> [String] = { [] },
        dependencyRevision: (String) -> String = { _ in "" }
    ) -> RepositoryForgeRemoteDescriptorLoad {
        if let cached = cache.descriptors(
            for: cacheKey,
            revision: revision,
            dependencyRevision: dependencyRevision
        ) {
            return RepositoryForgeRemoteDescriptorLoad(
                descriptors: cached,
                reusedCache: true,
                isCacheable: true
            )
        }

        guard let names = remoteNames() else {
            return RepositoryForgeRemoteDescriptorLoad(
                descriptors: [],
                reusedCache: false,
                isCacheable: false
            )
        }

        let sortedNames = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var descriptors: [RepositoryForgeRemoteDescriptor] = []
        var isCacheable = true
        descriptors.reserveCapacity(sortedNames.count)
        for name in sortedNames {
            guard let url = remoteURL(name) else {
                isCacheable = false
                continue
            }
            descriptors.append(RepositoryForgeRemoteDescriptor(name: name, url: url))
        }
        if isCacheable {
            cache.store(
                descriptors,
                for: cacheKey,
                revision: revision,
                dependencyPaths: dependencyPaths(),
                dependencyRevision: dependencyRevision
            )
        }
        return RepositoryForgeRemoteDescriptorLoad(
            descriptors: descriptors,
            reusedCache: false,
            isCacheable: isCacheable
        )
    }
}
