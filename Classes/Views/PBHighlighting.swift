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

    mutating func consumeRun() -> Bool {
        guard remainingRunCount > 0 else { return false }
        remainingRunCount -= 1
        return true
    }

    mutating func consumeRuns(_ count: Int) {
        remainingRunCount = max(0, remainingRunCount - count)
    }
}

nonisolated struct NativeSyntaxStyleRun {
    let range: NSRange
    let attributes: [NSAttributedString.Key: Any]
}

private final nonisolated class NativeSyntaxCacheKey: NSObject {
    let language: String
    let text: String

    init(language: String, text: String) {
        self.language = language
        self.text = text
    }

    override var hash: Int {
        language.hashValue &* 31 &+ text.hashValue
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? NativeSyntaxCacheKey else { return false }
        return language == other.language && text == other.text
    }
}

private final nonisolated class NativeSyntaxCacheEntry: NSObject {
    let result: HighlightResult

    init(result: HighlightResult) {
        self.result = result
    }
}

// swift6-safety-justification: NSCache synchronizes access and cached token results are immutable.
private final nonisolated class NativeSyntaxHighlightCache: @unchecked Sendable {
    static let shared = NativeSyntaxHighlightCache()

    private let cache = NSCache<NativeSyntaxCacheKey, NativeSyntaxCacheEntry>()
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "SyntaxHighlightCache")

    private init() {
        cache.countLimit = 64
        cache.totalCostLimit = 16 * 1024 * 1024
    }

    func result(for text: String, language: String) -> HighlightResult {
        let key = NativeSyntaxCacheKey(language: language, text: text)
        if let cached = cache.object(forKey: key) {
            logger.debug("Reusing cached syntax tokens")
            return cached.result
        }

        let result = Highlighter.shared.highlight(text, as: language)
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
    private let paragraphStyle: NSParagraphStyle

    init(
        baseAttributes: [NSAttributedString.Key: Any],
        syntaxTheme: SyntaxTheme = ApplicationSettings.syntaxTheme
    ) {
        self.baseAttributes = baseAttributes
        theme = switch syntaxTheme {
        case .xcode: .xcode
        case .github: .github
        case .plain: nil
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 32
        paragraph.lineBreakMode = .byClipping
        paragraphStyle = paragraph.copy() as! NSParagraphStyle
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
              let language = PBHighlighting.languageName(forPath: path)
        else {
            return NSAttributedString(string: text, attributes: defaultAttributes)
        }

        defaultAttributes[.foregroundColor] = theme.foregroundColor
        let attributed = NSMutableAttributedString(string: text, attributes: defaultAttributes)
        let result = NativeSyntaxHighlightCache.shared.result(for: text, language: language)
        let fullLength = (text as NSString).length
        var fontCache: [Int: NSFont] = [:]
        for token in result.tokens {
            guard NSMaxRange(token.range) <= fullLength,
                  let style = theme.style(for: token)
            else { continue }
            let styleAttributes = attributes(
                for: style,
                fontCache: &fontCache
            )
            if !styleAttributes.isEmpty {
                guard runBudget.consumeRun() else { break }
                attributed.addAttributes(styleAttributes, range: token.range)
            }
        }
        return attributed
    }

    func styleRuns(
        for text: String,
        path: String,
        targetRanges: [Int: NSRange],
        runBudget: inout NativeSyntaxRunBudget
    ) -> [Int: [NativeSyntaxStyleRun]] {
        guard let theme,
              !targetRanges.isEmpty,
              let language = PBHighlighting.languageName(forPath: path)
        else { return [:] }

        let result = NativeSyntaxHighlightCache.shared.result(for: text, language: language)
        let orderedRanges = targetRanges.sorted { lhs, rhs in
            lhs.value.location < rhs.value.location
        }
        var runs: [Int: [NativeSyntaxStyleRun]] = [:]
        var tokenIndex = 0
        var fontCache: [Int: NSFont] = [:]
        for (targetIndex, targetRange) in orderedRanges {
            while tokenIndex < result.tokens.count,
                  NSMaxRange(result.tokens[tokenIndex].range) <= targetRange.location
            {
                tokenIndex += 1
            }
            var candidateIndex = tokenIndex
            while candidateIndex < result.tokens.count {
                let token = result.tokens[candidateIndex]
                if token.range.location >= NSMaxRange(targetRange) {
                    break
                }
                let intersection = NSIntersectionRange(token.range, targetRange)
                if intersection.length > 0,
                   let style = theme.style(for: token)
                {
                    let styleAttributes = attributes(
                        for: style,
                        fontCache: &fontCache
                    )
                    if !styleAttributes.isEmpty {
                        guard runBudget.consumeRun() else { return runs }
                        runs[targetIndex, default: []].append(NativeSyntaxStyleRun(
                            range: NSRange(
                                location: intersection.location - targetRange.location,
                                length: intersection.length
                            ),
                            attributes: styleAttributes
                        ))
                    }
                }
                candidateIndex += 1
            }
        }
        return runs
    }

    private func attributes(
        for style: ScopeStyle,
        fontCache: inout [Int: NSFont]
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let color = style.color {
            attributes[.foregroundColor] = color
        }
        guard style.bold || style.italic,
              let baseFont = baseAttributes[.font] as? NSFont
        else { return attributes }

        let key = (style.bold ? 1 : 0) | (style.italic ? 2 : 0)
        if let cached = fontCache[key] {
            attributes[.font] = cached
            return attributes
        }
        var traits = baseFont.fontDescriptor.symbolicTraits
        if style.bold {
            traits.insert(.bold)
        }
        if style.italic {
            traits.insert(.italic)
        }
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
        var resolved = baseFont
        if let traitFont = NSFont(descriptor: descriptor, size: baseFont.pointSize) {
            resolved = traitFont
        }
        fontCache[key] = resolved
        attributes[.font] = resolved
        return attributes
    }
}

@objc(PBHighlighting)
final nonisolated class PBHighlighting: NSObject {
    private static let maximumHighlightedDocumentByteCount = 200 * 1024
    static let maximumStyledRunCount = 4096

    private static let extensionLanguages: [String: String] = [
        "ada": "ada", "adb": "ada", "ads": "ada",
        "applescript": "applescript", "s": "armasm", "asm": "armasm",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash",
        "c": "c", "h": "objectivec", "cc": "cpp", "cp": "cpp",
        "cpp": "cpp", "cxx": "cpp", "hh": "cpp", "hpp": "cpp",
        "cs": "csharp", "css": "css", "scss": "scss", "less": "less",
        "dart": "dart", "diff": "diff", "patch": "diff",
        "ex": "elixir", "exs": "elixir", "erl": "erlang", "hrl": "erlang",
        "fs": "fsharp", "fsi": "fsharp", "fsx": "fsharp",
        "f": "fortran", "f90": "fortran", "f95": "fortran",
        "go": "go", "groovy": "groovy", "hs": "haskell",
        "html": "xml", "htm": "xml", "xml": "xml", "svg": "xml",
        "ini": "ini", "toml": "ini", "java": "java",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "json": "json", "json5": "json", "kt": "kotlin", "kts": "kotlin",
        "lua": "lua", "md": "markdown", "markdown": "markdown",
        "m": "objectivec", "mm": "objectivec", "ml": "ocaml", "mli": "ocaml",
        "pl": "perl", "pm": "perl", "php": "php", "ps1": "powershell",
        "pro": "prolog", "properties": "properties", "py": "python",
        "r": "r", "rb": "ruby", "rs": "rust", "scala": "scala",
        "scm": "scheme", "sql": "sql", "swift": "swift",
        "ts": "typescript", "tsx": "typescript", "vim": "vim",
        "yaml": "yaml", "yml": "yaml",
    ]

    private static let supportedExtensionLanguages = extensionLanguages.filter {
        Highlighter.shared.hasLanguage(named: $0.value)
    }

    @objc(languageNameForPath:)
    static func languageName(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let specialLanguage: String? = switch name {
        case "dockerfile": "dockerfile"
        case "makefile", "gnumakefile": "makefile"
        case "cmakelists.txt": "cmake"
        default: nil
        }
        if let specialLanguage,
           Highlighter.shared.hasLanguage(named: specialLanguage)
        {
            return specialLanguage
        }
        return supportedExtensionLanguages[(name as NSString).pathExtension]
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
