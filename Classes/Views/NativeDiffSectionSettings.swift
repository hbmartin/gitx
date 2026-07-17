// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration
@objc(PBNativeDiffSectionSettings)
final nonisolated class NativeDiffSectionSettings: NSObject {
    @objc(applyToSections:repository:)
    static func apply(
        to sections: [[String: Any]],
        repository: PBGitRepository
    ) -> [[String: Any]] {
        let store = RepositorySettingsStore(repository: repository)
        let configuredPatterns = store.string(forKey: RepositorySettingsStore.diffSuppressionKey)
        let patterns = configuredPatterns.components(separatedBy: .newlines).compactMap { line -> String? in
            let pattern = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return pattern.isEmpty || pattern.hasPrefix("#") ? nil : pattern
        }
        return sections.map { value in
            var section = value
            section[PBNativeSectionDiffLayoutKey] = ApplicationSettings.diffLayout.rawValue
            section[PBNativeSectionSuppressionPatternsKey] = patterns
            return section
        }
    }
}

// swiftlint:enable unused_declaration
