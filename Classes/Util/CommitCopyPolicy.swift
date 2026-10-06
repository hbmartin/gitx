nonisolated enum CommitCopySelectionPolicy {
    static func canCopyImmutableCommits(shas: [String]) -> Bool {
        !shas.isEmpty && shas.allSatisfy { !$0.isEmpty }
    }
}

/// Formatting and warning counts are independent of AppKit and commit loading.
nonisolated struct CommitPatchCopyResult: Equatable, Sendable {
    let text: String
    let copiedCount: Int
    let skippedCount: Int

    init(patches: [String?]) {
        let available = patches.compactMap { patch in
            patch.flatMap { $0.isEmpty ? nil : $0 }
        }
        text = available.reversed().joined(separator: "\n\n\n")
        copiedCount = available.count
        skippedCount = patches.count - available.count
    }

    var warningMessage: String? {
        guard skippedCount > 0 else { return nil }
        return copiedCount == 0 ? "No patches available" : "Some patches could not be copied"
    }

    var warningInfo: String {
        "Copied \(copiedCount) \(copiedCount == 1 ? "patch" : "patches"); skipped \(skippedCount) \(skippedCount == 1 ? "commit" : "commits") because Git did not return a patch."
    }
}
