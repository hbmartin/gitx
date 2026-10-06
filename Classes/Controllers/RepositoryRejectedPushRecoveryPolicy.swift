import Foundation

/// Evidence captured before the original command. Rejection-time checks only
/// validate these IDs; they never substitute live branch or tracking tips.
nonisolated struct RepositoryPushSnapshot: Equatable, Sendable {
    let sourceRef: String
    let sourceOID: String
    let remoteName: String
    let endpoint: String
    let destinationRef: String
    let fetchedOID: String
    let trackingRef: String
    let reflogOIDs: [String]
    let configuration: [String: [String]]

    init(sourceRef: String, sourceOID: String, remoteName: String, endpoint: String, destinationRef: String,
         fetchedOID: String, trackingRef: String = "", reflogOIDs: [String] = [], configuration: [String: [String]] = [:])
    {
        self.sourceRef = sourceRef
        self.sourceOID = sourceOID
        self.remoteName = remoteName
        self.endpoint = endpoint
        self.destinationRef = destinationRef
        self.fetchedOID = fetchedOID
        self.trackingRef = trackingRef
        self.reflogOIDs = reflogOIDs
        self.configuration = configuration
    }

    var branchName: String {
        String(sourceRef.dropFirst("refs/heads/".count))
    }

    var retryArguments: [String] {
        ["push", "--porcelain", "--force-with-lease=\(destinationRef):\(fetchedOID)",
         "--", remoteName, "\(sourceOID):\(destinationRef)"]
    }

    static func isOID(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0) || (65 ... 70).contains($0)
        }
    }
}

nonisolated enum RepositoryPushRecoveryDecision: Equatable {
    case eligible
    case excluded(String)
}

nonisolated enum RepositoryRejectedPushRecoveryPolicy {
    static func decision(stdout: String, snapshot: RepositoryPushSnapshot?) -> RepositoryPushRecoveryDecision {
        guard let snapshot else { return .excluded("No captured branch evidence") }
        // Literal LF matters: Unicode separators in hook diagnostics are data.
        let lines = stdout.components(separatedBy: "\n")
        guard lines.count == 4, lines[0].hasPrefix("To "), lines[0].count > 3,
              lines[2] == "Done", lines[3].isEmpty,
              !stdout.contains("\r"), !stdout.contains("\u{2028}"), !stdout.contains("\u{2029}")
        else { return .excluded("Incomplete or ambiguous push status envelope") }
        let fields = lines[1].components(separatedBy: "\t")
        guard fields.count == 3, fields[0] == "!",
              fields[1] == "\(snapshot.sourceRef):\(snapshot.destinationRef)"
        else { return .excluded("Push status does not describe the captured branch") }
        guard fields[2] == "[rejected] (non-fast-forward)" else {
            return .excluded("Only a non-fast-forward rejection supports recovery")
        }
        return .eligible
    }
}

nonisolated enum RepositoryPushConfiguration {
    static func values(_ output: String) -> [String: [String]] {
        var values: [String: [String]] = [:]
        for entry in output.split(separator: "\0") {
            let fields = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            values[String(fields[0]), default: []].append(fields.count == 2 ? String(fields[1]) : "true")
        }
        return values
    }

    static func relevant(_ values: [String: [String]], remote: String, branch: String) -> [String: [String]] {
        values.filter { key, _ in
            key.hasPrefix("remote.\(remote).") || key.hasPrefix("branch.\(branch).")
                || ["url.", "push.", "http.", "credential.", "protocol.", "ssh.", "receive.", "transfer.", "extensions."].contains { key.hasPrefix($0) }
                || ["remote.pushdefault", "core.sshcommand", "core.gitproxy", "core.hookspath"].contains(key)
        }
    }
}
