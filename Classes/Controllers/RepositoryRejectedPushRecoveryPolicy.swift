import Foundation

/// Every field is captured before the original push. In particular, neither a
/// background fetch nor a moved local branch may change an approved retry.
nonisolated struct RepositoryPushSnapshot: Equatable, Sendable {
    let sourceRef: String
    let sourceOID: String
    let remoteName: String
    let endpoint: String
    let destinationRef: String
    let fetchedOID: String

    var branchName: String {
        String(sourceRef.dropFirst("refs/heads/".count))
    }

    var retryArguments: [String] {
        ["push", "--porcelain", "--force-with-lease=\(destinationRef):\(fetchedOID)",
         "--", endpoint, "\(sourceOID):\(destinationRef)"]
    }

    static func isOID(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0) || (65 ... 70).contains($0)
        }
    }
}

/// Resolve only exact or single-wildcard refspecs. Unknown syntax and negative
/// fetch mappings fail closed; they never justify replacing remote history.
nonisolated enum RepositoryPushRefspecPolicy {
    static func destination(source: String, pushMappings: [String]) -> String? {
        guard !pushMappings.isEmpty else { return source }
        return mappedReference(source, mappings: pushMappings)
    }

    static func trackingReference(destination: String, fetchMappings: [String]) -> String? {
        guard let tracking = mappedReference(destination, mappings: fetchMappings),
              !tracking.hasPrefix("refs/heads/"), !tracking.hasPrefix("refs/tags/")
        else { return nil }
        return tracking
    }

    private static func mappedReference(_ reference: String, mappings: [String]) -> String? {
        var matches = Set<String>()
        for mapping in mappings {
            let spec = mapping.hasPrefix("+") ? String(mapping.dropFirst()) : mapping
            let fields = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, fields.allSatisfy({ $0.hasPrefix("refs/") }) else { return nil }
            let source = fields[0].split(separator: "*", omittingEmptySubsequences: false).map(String.init)
            let target = fields[1].split(separator: "*", omittingEmptySubsequences: false).map(String.init)
            guard source.count == target.count, [1, 2].contains(source.count) else { return nil }
            if source.count == 1 {
                if reference == fields[0] {
                    matches.insert(fields[1])
                }
            } else if reference.hasPrefix(source[0]), reference.hasSuffix(source[1]),
                      reference.count >= source[0].count + source[1].count
            {
                let wildcard = reference.dropFirst(source[0].count).dropLast(source[1].count)
                matches.insert(target[0] + wildcard + target[1])
            }
        }
        guard matches.count == 1 else { return nil }
        return matches.first
    }
}

nonisolated enum RepositoryRejectedPushRecoveryPolicy {
    static func shouldOfferForceWithLease(for error: Error, snapshot: RepositoryPushSnapshot?) -> Bool {
        guard let snapshot, let output = taskOutput(for: error) else { return false }
        let statuses = output.components(separatedBy: .newlines).compactMap { line -> [String]? in
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 3, fields[0].count == 1,
                  " !=+-*".contains(fields[0]) else { return nil }
            return fields
        }
        guard statuses.count == 1 else { return false }
        let status = statuses[0]
        return status[0] == "!"
            && status[1] == "\(snapshot.sourceRef):\(snapshot.destinationRef)"
            && ["[rejected] (non-fast-forward)", "[rejected] (fetch first)"].contains(status[2])
    }

    static func taskOutput(for error: Error) -> String? {
        var current: NSError? = error as NSError
        var visited = Set<ObjectIdentifier>()
        while let error = current, visited.insert(ObjectIdentifier(error)).inserted {
            if error.domain == PBTaskErrorDomain,
               let output = error.userInfo[PBTaskTerminationOutputKey] as? String
            {
                return output
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }
}
