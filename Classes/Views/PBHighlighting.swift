import AppKit
import HighlightKit
import OSLog // swiftlint:disable:this unused_import

nonisolated struct NativeSyntaxRunBudget {
    private(set) var remainingRunCount: Int

    init(maximumRunCount: Int = PBHighlighting.maximumStyledRunCount) {
        remainingRunCount = maximumRunCount
    }

    var isExhausted: Bool {
        remainingRunCount == 0
    }

    mutating func consumeRuns(_ count: Int) {
        remainingRunCount = max(0, remainingRunCount - count)
    }
}

nonisolated struct NativeSyntaxStyleRun {
    let range: NSRange
    let attributes: [NSAttributedString.Key: Any]
}

nonisolated struct NativeLanguageRequest {
    let selection: LanguageSelection
    let options: HighlightOptions
    let cacheIdentity: String

    static func named(_ language: String) -> NativeLanguageRequest {
        NativeLanguageRequest(
            selection: .named(language),
            options: HighlightOptions(),
            cacheIdentity: "named:\(language)"
        )
    }

    static func automatic(_ languages: [String]) -> NativeLanguageRequest {
        let languages = Array(Set(languages)).sorted()
        return NativeLanguageRequest(
            selection: .automatic,
            options: HighlightOptions(automaticSubset: languages),
            cacheIdentity: "automatic:\(languages.joined(separator: ","))"
        )
    }
}

private nonisolated struct NativeRepositoryLanguageIndex {
    private let filenames: [String: [String]]
    private let extensions: [String: [String]]

    init(languages: [LanguageInfo]) {
        var filenames: [String: Set<String>] = [:]
        var extensions: [String: Set<String>] = [:]
        for language in languages {
            for filename in language.metadata.filenames {
                filenames[filename, default: []].insert(language.name)
            }
            for fileExtension in language.metadata.fileExtensions {
                extensions[fileExtension, default: []].insert(language.name)
            }
        }
        self.filenames = filenames.mapValues { $0.sorted() }
        self.extensions = extensions.mapValues { $0.sorted() }
    }

    func candidates(forPath path: String) -> [String] {
        let filename = (path as NSString).lastPathComponent.lowercased()
        if let exact = filenames[filename] {
            return exact
        }
        var longestExtensionLength = -1
        var candidates: [String] = []
        for (fileExtension, languages) in extensions
            where filename == fileExtension || filename.hasSuffix(".\(fileExtension)")
        {
            if fileExtension.count > longestExtensionLength {
                longestExtensionLength = fileExtension.count
                candidates = languages
            }
        }
        return Array(Set(candidates)).sorted()
    }
}

private final nonisolated class NativeSyntaxCacheKey: NSObject {
    let requestIdentity: String
    let text: String
    private let precomputedHash: Int

    init(requestIdentity: String, text: String) {
        self.requestIdentity = requestIdentity
        self.text = text
        var hasher = Hasher()
        hasher.combine(requestIdentity)
        hasher.combine(text)
        precomputedHash = hasher.finalize()
    }

    override var hash: Int {
        precomputedHash
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? NativeSyntaxCacheKey else { return false }
        return requestIdentity == other.requestIdentity && text == other.text
    }
}

private final nonisolated class NativeSyntaxCacheEntry: NSObject {
    let result: HighlightResult

    init(result: HighlightResult) {
        self.result = result
    }
}

// swift6-safety-justification: NSCache synchronizes access and cached token results are immutable.
final nonisolated class NativeSyntaxHighlightCache: @unchecked Sendable {
    static let shared = NativeSyntaxHighlightCache()

    private let cache = NSCache<NativeSyntaxCacheKey, NativeSyntaxCacheEntry>()
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "SyntaxHighlightCache")

    init() {
        cache.countLimit = 64
        cache.totalCostLimit = 16 * 1024 * 1024
    }

    func result(for text: String, request: NativeLanguageRequest) -> HighlightResult {
        let key = NativeSyntaxCacheKey(requestIdentity: request.cacheIdentity, text: text)
        if let cached = cache.object(forKey: key) {
            logger.debug("Reusing cached syntax tokens")
            return cached.result
        }

        // Requests come only from the registered catalog. A bundled grammar failure is a
        // configuration defect and must remain visible instead of silently becoming plain text.
        let result = try! Highlighter.shared.highlight(
            text,
            selection: request.selection,
            options: request.options,
            budget: HighlightBudget(maximumTokens: PBHighlighting.maximumCachedTokenCount)
        )
        if result.isTruncated {
            logger.debug("Cached a truncated bounded syntax-token result")
        }
        let textCost = text.lengthOfBytes(using: .utf8)
        let estimatedCost = textCost + result.tokens.count * 64
        cache.setObject(
            NativeSyntaxCacheEntry(result: result),
            forKey: key,
            cost: estimatedCost
        )
        logger.debug("Cached syntax tokens")
        return result
    }
}

nonisolated struct NativeSyntaxStyler {
    private let baseAttributes: [NSAttributedString.Key: Any]
    private let theme: HighlightTheme?
    private let renderer: HighlightRenderer?
    private let paragraphStyle: NSParagraphStyle
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "SyntaxRenderer")

    init(
        baseAttributes: [NSAttributedString.Key: Any],
        syntaxTheme: SyntaxTheme = ApplicationSettings.syntaxTheme
    ) {
        self.baseAttributes = baseAttributes
        let resolvedTheme: HighlightTheme? = switch syntaxTheme {
        case .xcode: .xcode
        case .github: .github
        case .plain: nil
        }
        theme = resolvedTheme
        renderer = resolvedTheme.map { HighlightRenderer(theme: $0) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 32
        paragraph.lineBreakMode = .byClipping
        paragraphStyle = paragraph.copy() as! NSParagraphStyle
    }

    var hasTheme: Bool {
        renderer != nil
    }

    func attributedString(
        for text: String,
        path: String,
        syntaxEnabled: Bool,
        runBudget: inout NativeSyntaxRunBudget
    ) -> NSAttributedString {
        var defaultAttributes = baseAttributes
        defaultAttributes[.paragraphStyle] = paragraphStyle
        guard syntaxEnabled,
              let theme,
              let renderer,
              let request = PBHighlighting.languageRequest(forPath: path)
        else {
            return NSAttributedString(string: text, attributes: defaultAttributes)
        }

        defaultAttributes[.foregroundColor] = theme.foregroundColor
        let attributed = NSMutableAttributedString(string: text, attributes: defaultAttributes)
        let result = NativeSyntaxHighlightCache.shared.result(for: text, request: request)
        // Without explicit mappings, HighlightRenderer clips to the valid UTF-16 prefix.
        let summary = try! renderer.apply(
            result,
            to: attributed,
            options: HighlightRenderOptions(maximumRenderedRuns: runBudget.remainingRunCount)
        )
        runBudget.consumeRuns(summary.appliedRuns)
        if summary.isTruncated {
            logger.debug("Syntax rendering reached the bounded run limit")
        }
        return attributed
    }

    func styleRuns(
        for text: String,
        path: String,
        targetRanges: [Int: NSRange],
        runBudget: inout NativeSyntaxRunBudget
    ) -> [Int: [NativeSyntaxStyleRun]] {
        guard let renderer,
              !targetRanges.isEmpty,
              let request = PBHighlighting.languageRequest(forPath: path)
        else { return [:] }

        let result = NativeSyntaxHighlightCache.shared.result(for: text, request: request)
        let orderedRanges = targetRanges.sorted { lhs, rhs in
            lhs.value.location < rhs.value.location
        }
        var baseFont = renderer.regularFont
        if let configuredFont = baseAttributes[.font] as? NSFont {
            baseFont = configuredFont
        }
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: baseFont]
        )
        let mappings = orderedRanges.map {
            HighlightRangeMapping(sourceRange: $0.value, destinationRange: $0.value)
        }
        // Ranges are produced from this exact UTF-16 source, so invalid mappings are impossible.
        let summary = try! renderer.apply(
            result,
            to: attributed,
            mappings: mappings,
            options: HighlightRenderOptions(maximumRenderedRuns: runBudget.remainingRunCount)
        )
        runBudget.consumeRuns(summary.appliedRuns)
        if summary.isTruncated {
            logger.debug("Mapped syntax rendering reached the bounded run limit")
        }

        var runs: [Int: [NativeSyntaxStyleRun]] = [:]
        for (targetIndex, targetRange) in orderedRanges {
            attributed.enumerateAttributes(in: targetRange) { attributes, range, _ in
                var syntaxAttributes: [NSAttributedString.Key: Any] = [:]
                if let color = attributes[.foregroundColor] {
                    syntaxAttributes[.foregroundColor] = color
                }
                if let font = attributes[.font] as? NSFont, !font.isEqual(baseFont) {
                    syntaxAttributes[.font] = font
                }
                if !syntaxAttributes.isEmpty {
                    runs[targetIndex, default: []].append(NativeSyntaxStyleRun(
                        range: NSRange(
                            location: range.location - targetRange.location,
                            length: range.length
                        ),
                        attributes: syntaxAttributes
                    ))
                }
            }
        }
        return runs
    }
}

@objc(PBHighlighting)
final nonisolated class PBHighlighting: NSObject {
    private static let maximumHighlightedDocumentByteCount = 200 * 1024
    static let maximumStyledRunCount = 4096
    static let maximumCachedTokenCount = maximumStyledRunCount * 2

    private static let languageIndex = NativeRepositoryLanguageIndex(
        languages: Highlighter.shared.languages
    )
    private static let compatibilityExtensionLanguages = [
        "h": "objectivec",
        "json5": "json",
        "m": "objectivec",
        "pro": "prolog",
        "properties": "properties",
        "zsh": "bash",
    ]

    private static func languageCandidates(forPath path: String) -> [String] {
        let candidates = languageIndex.candidates(forPath: path)
        if !candidates.isEmpty {
            return candidates
        }
        let fileExtension = (path as NSString).pathExtension.lowercased()
        if let language = compatibilityExtensionLanguages[fileExtension],
           Highlighter.shared.hasLanguage(named: language)
        {
            return [language]
        }
        return []
    }

    static func languageRequest(forPath path: String) -> NativeLanguageRequest? {
        let candidates = languageCandidates(forPath: path)
        guard let language = candidates.first else { return nil }
        return candidates.count == 1 ? .named(language) : .automatic(candidates)
    }

    @objc(languageNameForPath:)
    static func languageName(forPath path: String) -> String? {
        let candidates = languageCandidates(forPath: path)
        guard candidates.count > 1 else { return candidates.first }
        let fileExtension = (path as NSString).pathExtension.lowercased()
        let preferred = compatibilityExtensionLanguages[fileExtension]
        return (candidates.filter { $0 == preferred } + candidates).first
    }

    @objc(shouldHighlightDiffWithByteCount:)
    static func shouldHighlightDiff(byteCount: UInt) -> Bool { // swiftlint:disable:this unused_declaration
        byteCount <= maximumHighlightedDocumentByteCount
    }

    @objc(shouldHighlightSourceWithByteCount:)
    static func shouldHighlightSource(byteCount: UInt) -> Bool { // swiftlint:disable:this unused_declaration
        byteCount <= maximumHighlightedDocumentByteCount
    }

    @objc(highlightedStringForText:path:)
    static func highlightedString(forText text: String, path: String) -> NSAttributedString {
        let typography = NativeContentTypography.currentTypography()
        let styler = NativeSyntaxStyler(baseAttributes: typography.bodyAttributes)
        var runBudget = NativeSyntaxRunBudget()
        return styler.attributedString(
            for: text,
            path: path,
            syntaxEnabled: shouldHighlightSource(byteCount: UInt(text.utf8.count)),
            runBudget: &runBudget
        )
    }
}
