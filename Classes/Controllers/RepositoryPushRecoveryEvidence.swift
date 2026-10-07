import Foundation
import ObjectiveGit

nonisolated enum RepositoryPushEvidenceError: Error, Equatable {
    case malformedReferenceMappings
    case ambiguousReferenceMappings
    case malformedReflog
    case unavailableCommitObjects
    case malformedAncestryProof
}

/// Native refspec semantics determine both directions; the copied strings keep
/// libgit2 pointers local to each operation and make this value Sendable.
nonisolated struct RepositoryFetchRefspec: Equatable, Sendable {
    let raw: String
    let source: String
    let destination: String?
    let isNegative: Bool

    init(_ raw: String) throws {
        self.raw = raw
        isNegative = raw.hasPrefix("^")
        var pointer: OpaquePointer?
        guard !raw.utf8.contains(0), git_refspec_parse(&pointer, raw, 1) == 0, let pointer else {
            throw RepositoryPushEvidenceError.malformedReferenceMappings
        }
        defer { git_refspec_free(pointer) }
        guard let sourcePointer = git_refspec_src(pointer) else {
            throw RepositoryPushEvidenceError.malformedReferenceMappings
        }
        let nativeSource = String(cString: sourcePointer)
        source = isNegative ? String(nativeSource.dropFirst()) : nativeSource
        destination = git_refspec_dst(pointer).map { String(cString: $0) }
        let sourceStars = source.filter { $0 == "*" }.count
        guard source.hasPrefix("refs/"), sourceStars <= 1 else {
            throw RepositoryPushEvidenceError.malformedReferenceMappings
        }
        if isNegative {
            guard destination == nil else { throw RepositoryPushEvidenceError.malformedReferenceMappings }
        } else {
            guard let destination, destination.hasPrefix("refs/"),
                  destination.filter({ $0 == "*" }).count == sourceStars
            else { throw RepositoryPushEvidenceError.malformedReferenceMappings }
        }
    }

    func matchesSource(_ ref: String) throws -> Bool {
        try withParsed { pointer in
            (isNegative ? git_refspec_src_matches_negative(pointer, ref) : git_refspec_src_matches(pointer, ref)) == 1
        }
    }

    func matchesDestination(_ ref: String) throws -> Bool {
        guard !isNegative else { return false }
        return try withParsed { git_refspec_dst_matches($0, ref) == 1 }
    }

    func transform(_ ref: String, reverse: Bool = false) throws -> String {
        guard !isNegative else { throw RepositoryPushEvidenceError.malformedReferenceMappings }
        return try withParsed { pointer in
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            let status = reverse ? git_refspec_rtransform(&buffer, pointer, ref) : git_refspec_transform(&buffer, pointer, ref)
            guard status == 0, let transformed = buffer.ptr else {
                throw RepositoryPushEvidenceError.malformedReferenceMappings
            }
            return String(cString: transformed)
        }
    }

    private func withParsed<Result>(_ operation: (OpaquePointer) throws -> Result) throws -> Result {
        var pointer: OpaquePointer?
        guard git_refspec_parse(&pointer, raw, 1) == 0, let pointer else {
            throw RepositoryPushEvidenceError.malformedReferenceMappings
        }
        defer { git_refspec_free(pointer) }
        return try operation(pointer)
    }
}

nonisolated enum RepositoryPushFetchMapping {
    static func validate(_ raw: [String], destination: String, tracking: String) throws {
        let rules = try raw.map(RepositoryFetchRefspec.init)
        let negatives = rules.filter(\.isNegative)
        func excluded(_ source: String) throws -> Bool {
            try negatives.contains { try $0.matchesSource(source) }
        }
        guard try !excluded(destination) else { throw RepositoryPushEvidenceError.ambiguousReferenceMappings }
        let positives = rules.filter { !$0.isNegative }
        let forward = try positives.filter { try $0.matchesSource(destination) }
        guard forward.count == 1, try forward[0].transform(destination) == tracking else {
            throw RepositoryPushEvidenceError.ambiguousReferenceMappings
        }
        var reverse: [String] = []
        for rule in positives where try rule.matchesDestination(tracking) {
            let source = try rule.transform(tracking, reverse: true)
            if try !excluded(source) {
                reverse.append(source)
            }
        }
        guard reverse == [destination] else { throw RepositoryPushEvidenceError.ambiguousReferenceMappings }
    }
}

nonisolated struct RepositoryPushReflogEvidence: Equatable, Sendable {
    static let limit = 1024
    let retainedOIDs: [String]
    let isTruncated: Bool

    static func capture(_ data: Data, oidLength: Int) throws -> Self {
        guard let lines = RepositoryPushObjectEvidence.lines(data), lines.count <= limit + 1,
              lines.allSatisfy({ RepositoryPushSnapshot.isOID($0) && $0.count == oidLength })
        else { throw RepositoryPushEvidenceError.malformedReflog }
        return Self(retainedOIDs: Array(lines.prefix(limit)), isTruncated: lines.count > limit)
    }

    static func witnesses(sourceOID: String, reflogOIDs: [String]) -> [String] {
        var seen = Set<String>()
        return ([sourceOID] + reflogOIDs).filter { seen.insert($0).inserted }
    }
}

nonisolated enum RepositoryPushObjectEvidence {
    static func input(_ oids: [String]) -> Data {
        Data((oids.joined(separator: "\n") + "\n").utf8)
    }

    static func validateCommits(_ data: Data, expectedOIDs: [String]) throws {
        guard let lines = lines(data), lines.count == expectedOIDs.count else {
            throw RepositoryPushEvidenceError.unavailableCommitObjects
        }
        for (line, expected) in zip(lines, expectedOIDs) {
            let fields = line.components(separatedBy: " ")
            guard fields.count == 3, fields[0] == expected, fields[1] == "commit",
                  !fields[2].isEmpty, fields[2].utf8.allSatisfy({ (48 ... 57).contains($0) }),
                  let size = UInt64(fields[2]), size > 0
            else { throw RepositoryPushEvidenceError.unavailableCommitObjects }
        }
    }

    static func provesAncestry(_ data: Data, oidLength: Int) throws -> Bool {
        guard let lines = lines(data), lines.count <= 1,
              lines.allSatisfy({ RepositoryPushSnapshot.isOID($0) && $0.count == oidLength })
        else { throw RepositoryPushEvidenceError.malformedAncestryProof }
        return !lines.isEmpty
    }

    /// Plumbing emits ASCII records with terminal LF. Invalid UTF-8 and
    /// unterminated output cannot become a different successful identity.
    static func lines(_ data: Data) -> [String]? {
        guard !data.isEmpty else { return [] }
        guard data.last == 10, let output = String(data: data, encoding: .utf8) else { return nil }
        return Array(output.components(separatedBy: "\n").dropLast())
    }
}
