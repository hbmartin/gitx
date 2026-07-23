import AppKit
import OSLog // swiftlint:disable:this unused_import -- Logger requires OSLog despite analyzer's false positive.

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

@objc(PBNativeRenderResult)
final nonisolated class NativeRenderResult: NSObject {
    @objc let attributedString: NSAttributedString
    @objc let linkPayloads: [String: [String: Any]]

    init(attributedString: NSAttributedString, linkPayloads: [String: [String: Any]] = [:]) {
        self.attributedString = NSAttributedString(attributedString: attributedString)
        self.linkPayloads = linkPayloads
        super.init()
    }
}

private nonisolated enum NativeLinkAction {
    case commit(sha: String)
    case collapse(key: String)
    case revealSuppressed(key: String)
    case image(key: String, path: String, section: Int)
    case diff(action: String, patch: String)
    case partialDiff(
        action: String,
        fileHeader: [String],
        hunkLines: [String],
        selectedIndexes: IndexSet,
        reverse: Bool
    )

    var payload: [String: Any] {
        switch self {
        case let .commit(sha):
            ["type": "commit", "sha": sha]
        case let .collapse(key):
            ["type": "collapse", "key": key]
        case let .revealSuppressed(key):
            ["type": "reveal-suppressed", "key": key]
        case let .image(key, path, section):
            ["type": "image", "key": key, "path": path, "section": section]
        case let .diff(action, patch):
            ["type": "diff", "action": action, "patch": patch]
        case let .partialDiff(action, fileHeader, hunkLines, selectedIndexes, reverse):
            [
                "type": "diff",
                "action": action,
                "fileHeader": fileHeader,
                "hunkLines": hunkLines,
                "selectedIndexes": selectedIndexes,
                "reverse": reverse,
            ]
        }
    }
}

private nonisolated struct NativeRenderingSupport {
    let typography: NativeContentTypography
    let baseAttributes: [NSAttributedString.Key: Any]
    let titleAttributes: [NSAttributedString.Key: Any]

    init(
        baseAttributes: [NSAttributedString.Key: Any],
        titleAttributes: [NSAttributedString.Key: Any]
    ) {
        let suppliedFont = baseAttributes[.font] as? NSFont ??
            NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        typography = NativeContentTypography(
            fontName: suppliedFont.fontName,
            baseSize: suppliedFont.pointSize
        )
        self.baseAttributes = typography.attributes(
            for: .body,
            merging: baseAttributes
        )
        self.titleAttributes = typography.attributes(
            for: .title,
            merging: titleAttributes
        )
    }

    func attributes(
        for role: NativeContentTypographyRole,
        merging attributes: [NSAttributedString.Key: Any] = [:]
    ) -> [NSAttributedString.Key: Any] {
        typography.attributes(for: role, merging: attributes)
    }

    func appendSectionTitle(_ title: String, to result: NSMutableAttributedString) {
        guard !title.isEmpty else { return }
        if result.length > 0 {
            result.append(NSAttributedString(string: "\n\n", attributes: baseAttributes))
        }
        result.append(NSAttributedString(string: title + "\n", attributes: titleAttributes))
    }

    @discardableResult
    func appendLink(
        title: String,
        action: NativeLinkAction,
        linkPayloads: inout [String: [String: Any]],
        to result: NSMutableAttributedString
    ) -> URL {
        let url = URL(string: "gitx-action://\(UUID().uuidString)")!
        linkPayloads[url.absoluteString] = action.payload
        result.append(NSAttributedString(
            string: title,
            attributes: attributes(for: .link, merging: [
                .link: url,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
        ))
        return url
    }
}

private nonisolated func nativeContentByteCount(
    of sections: [NativeContentSection]
) -> Int {
    sections.reduce(0) { byteCount, section in
        let (sum, overflow) = byteCount.addingReportingOverflow(
            section.text.lengthOfBytes(using: .utf8)
        )
        return overflow ? Int.max : sum
    }
}

private struct NativeBlameRecord {
    let sha: String
    let author: String
    let summary: String
    let code: String
}

typealias NativeRenderCancellation = @convention(block) () -> Bool

@objc(PBNativeTextRenderer)
final nonisolated class NativeTextRenderer: NSObject {
    private let support: NativeRenderingSupport
    private let syntaxStyler: NativeSyntaxStyler
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "NativeTextRenderer")

    @objc(initWithBaseAttributes:titleAttributes:)
    init(
        baseAttributes: [NSAttributedString.Key: Any],
        titleAttributes: [NSAttributedString.Key: Any]
    ) {
        let renderingSupport = NativeRenderingSupport(
            baseAttributes: baseAttributes,
            titleAttributes: titleAttributes
        )
        support = renderingSupport
        syntaxStyler = NativeSyntaxStyler(baseAttributes: renderingSupport.baseAttributes)
        super.init()
    }

    @objc(renderSourceSections:)
    func renderSource(sections: [NativeContentSection]) -> NativeRenderResult {
        renderSource(sections: sections, shouldCancel: { false })
    }

    @objc(renderSourceSections:shouldCancel:)
    func renderSource(
        sections: [NativeContentSection],
        shouldCancel: NativeRenderCancellation
    ) -> NativeRenderResult {
        let rendered = NSMutableAttributedString(string: "")
        let byteCount = nativeContentByteCount(of: sections)
        let syntaxEnabled = PBHighlighting.shouldHighlightSource(byteCount: UInt(byteCount))
        var runBudget = NativeSyntaxRunBudget()
        if !syntaxEnabled {
            logger.debug("Rendering large source document with lightweight coloring")
        }
        for section in sections {
            if shouldCancel() {
                logger.debug("Cancelled source rendering between sections")
                break
            }
            support.appendSectionTitle(section.displayTitle, to: rendered)
            rendered.append(syntaxStyler.attributedString(
                for: section.text,
                path: section.highlightingPath,
                syntaxEnabled: syntaxEnabled,
                runBudget: &runBudget
            ))
        }
        if runBudget.isExhausted {
            logger.debug("Syntax run budget exhausted while rendering source")
        }
        return NativeRenderResult(attributedString: rendered)
    }

    @objc(renderBlameSections:)
    func renderBlame(sections: [NativeContentSection]) -> NativeRenderResult {
        renderBlame(sections: sections, shouldCancel: { false })
    }

    @objc(renderBlameSections:shouldCancel:)
    func renderBlame(
        sections: [NativeContentSection],
        shouldCancel: NativeRenderCancellation
    ) -> NativeRenderResult {
        let rendered = NSMutableAttributedString(string: "")
        let syntaxEnabled = PBHighlighting.shouldHighlightSource(
            byteCount: UInt(nativeContentByteCount(of: sections))
        )
        var runBudget = NativeSyntaxRunBudget()
        if !syntaxEnabled {
            logger.debug("Rendering large blame document with lightweight coloring")
        }
        for section in sections {
            if shouldCancel() {
                logger.debug("Cancelled blame rendering between sections")
                break
            }
            let records = blameRecords(from: section.text)
            let code = records.map(\.code).joined(separator: "\n") + (records.isEmpty ? "" : "\n")
            let highlighted = syntaxStyler.attributedString(
                for: code,
                path: section.highlightingPath,
                syntaxEnabled: syntaxEnabled,
                runBudget: &runBudget
            )
            support.appendSectionTitle(section.displayTitle, to: rendered)
            var codeLocation = 0
            for record in records {
                let line = record.code + "\n"
                let sha = record.sha as NSString
                var shortSHA = sha.length >= 8 ? sha.substring(to: 8) : record.sha
                var author = record.author
                if (author as NSString).length > 18 {
                    author = (author as NSString).substring(to: 17) + "…"
                }
                shortSHA = (shortSHA as NSString).padding(
                    toLength: 8,
                    withPad: " ",
                    startingAt: 0
                )
                author = (author as NSString).padding(
                    toLength: 18,
                    withPad: " ",
                    startingAt: 0
                )
                let gutter = "\(shortSHA)  \(author) │ "
                rendered.append(NSAttributedString(
                    string: gutter,
                    attributes: support.attributes(for: .blameGutter, merging: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .backgroundColor: NSColor.controlBackgroundColor,
                    ])
                ))
                let range = NSRange(location: codeLocation, length: (line as NSString).length)
                rendered.append(highlighted.attributedSubstring(from: range))
                codeLocation += range.length
            }
        }
        if runBudget.isExhausted {
            logger.debug("Syntax run budget exhausted while rendering blame")
        }
        return NativeRenderResult(attributedString: rendered)
    }

    @objc(renderHistorySections:)
    func renderHistory(sections: [NativeContentSection]) -> NativeRenderResult {
        renderHistory(sections: sections, shouldCancel: { false })
    }

    @objc(renderHistorySections:shouldCancel:)
    func renderHistory(
        sections: [NativeContentSection],
        shouldCancel: NativeRenderCancellation
    ) -> NativeRenderResult {
        let rendered = NSMutableAttributedString(string: "")
        var linkPayloads: [String: [String: Any]] = [:]
        for section in sections {
            if shouldCancel() {
                logger.debug("Cancelled history rendering between sections")
                break
            }
            support.appendSectionTitle(section.displayTitle, to: rendered)
            for entry in section.entries {
                let subject = entry["subject"] as? String ?? ""
                rendered.append(NSAttributedString(
                    string: subject + "\n",
                    attributes: support.titleAttributes
                ))
                let author = entry["author"] as? String ?? ""
                let date = entry["date"] as? String ?? ""
                rendered.append(NSAttributedString(
                    string: "\(author)  •  \(date)  •  ",
                    attributes: support.attributes(for: .metadata, merging: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ])
                ))
                let sha = entry["sha"] as? String ?? ""
                let shortSHA = (sha as NSString).length > 12
                    ? (sha as NSString).substring(to: 12)
                    : sha
                support.appendLink(
                    title: shortSHA,
                    action: .commit(sha: sha),
                    linkPayloads: &linkPayloads,
                    to: rendered
                )
                rendered.append(NSAttributedString(
                    string: "\n\n",
                    attributes: support.baseAttributes
                ))
            }
        }
        return NativeRenderResult(attributedString: rendered, linkPayloads: linkPayloads)
    }

    private func blameRecords(from porcelain: String) -> [NativeBlameRecord] {
        var metadata: [String: (author: String, summary: String)] = [:]
        var result: [NativeBlameRecord] = []
        var sha = ""
        var author = ""
        var summary = ""
        for line in porcelain.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: " ")
            if parts.count >= 3, (parts[0] as NSString).length == 40 {
                sha = parts[0]
                if let cached = metadata[sha] {
                    author = cached.author
                    summary = cached.summary
                }
            } else if line.hasPrefix("author ") {
                author = String(line.dropFirst(7))
            } else if line.hasPrefix("summary ") {
                summary = String(line.dropFirst(8))
                if !sha.isEmpty {
                    metadata[sha] = (author, summary)
                }
            } else if line.hasPrefix("\t") {
                result.append(NativeBlameRecord(
                    sha: sha,
                    author: author,
                    summary: summary,
                    code: String(line.dropFirst())
                ))
            }
        }
        return result
    }
}

typealias NativeImageDataProvider = (String, Int, [String: Any]) -> Data?

@objc(PBNativeDiffRenderer)
final nonisolated class NativeDiffRenderer: NSObject {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "icns", "webp",
    ]

    private let support: NativeRenderingSupport
    private let syntaxStyler: NativeSyntaxStyler
    private let parser: DiffDocumentParser
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "NativeDiffRenderer")

    @objc(initWithBaseAttributes:titleAttributes:parser:)
    init(
        baseAttributes: [NSAttributedString.Key: Any],
        titleAttributes: [NSAttributedString.Key: Any],
        parser: DiffDocumentParser
    ) {
        let renderingSupport = NativeRenderingSupport(
            baseAttributes: baseAttributes,
            titleAttributes: titleAttributes
        )
        support = renderingSupport
        syntaxStyler = NativeSyntaxStyler(baseAttributes: renderingSupport.baseAttributes)
        self.parser = parser
        super.init()
    }

    @objc(renderSections:collapsedFiles:expandedImages:imageDataProvider:)
    func render(
        sections: [NativeContentSection],
        collapsedFiles: Set<String>,
        expandedImages: Set<String>,
        imageDataProvider: NativeImageDataProvider?
    ) -> NativeRenderResult {
        render(
            sections: sections,
            collapsedFiles: collapsedFiles,
            expandedImages: expandedImages,
            imageDataProvider: imageDataProvider,
            shouldCancel: { false }
        )
    }

    @objc(renderSections:collapsedFiles:expandedImages:imageDataProvider:shouldCancel:)
    func render(
        sections: [NativeContentSection],
        collapsedFiles: Set<String>,
        expandedImages: Set<String>,
        imageDataProvider: NativeImageDataProvider?,
        shouldCancel: NativeRenderCancellation
    ) -> NativeRenderResult {
        let rendered = NSMutableAttributedString(string: "")
        var linkPayloads: [String: [String: Any]] = [:]
        let diffByteCount = nativeContentByteCount(of: sections)
        let shouldHighlightSyntax = PBHighlighting.shouldHighlightDiff(byteCount: UInt(diffByteCount))
        var runBudget = NativeSyntaxRunBudget()
        var loggedRunBudgetExhaustion = false
        if !shouldHighlightSyntax {
            logger.debug("Rendering large diff document with lightweight coloring")
        }

        for (sectionIndex, section) in sections.enumerated() {
            if shouldCancel() {
                logger.debug("Cancelled diff rendering between sections")
                break
            }
            support.appendSectionTitle(section.title, to: rendered)
            if section.text.isEmpty {
                rendered.append(NSAttributedString(
                    string: "There are no differences.\n",
                    attributes: support.attributes(
                        for: .metadata,
                        merging: [.foregroundColor: NSColor.secondaryLabelColor]
                    )
                ))
            } else {
                renderDiffText(
                    section.text,
                    context: section.context,
                    sectionIndex: sectionIndex,
                    fallbackPath: section.path,
                    diffLayout: section.diffLayout,
                    suppressionPatterns: section.suppressionPatterns,
                    shouldHighlightSyntax: shouldHighlightSyntax,
                    runBudget: &runBudget,
                    loggedRunBudgetExhaustion: &loggedRunBudgetExhaustion,
                    collapsedFiles: collapsedFiles,
                    expandedImages: expandedImages,
                    imageSource: section.imageSource,
                    imageDataProvider: imageDataProvider,
                    shouldCancel: shouldCancel,
                    linkPayloads: &linkPayloads,
                    rendered: rendered
                )
            }
        }
        return NativeRenderResult(attributedString: rendered, linkPayloads: linkPayloads)
    }

    private func renderDiffText(
        _ diff: String,
        context: String,
        sectionIndex: Int,
        fallbackPath: String,
        diffLayout: Int,
        suppressionPatterns: [String],
        shouldHighlightSyntax: Bool,
        runBudget: inout NativeSyntaxRunBudget,
        loggedRunBudgetExhaustion: inout Bool,
        collapsedFiles: Set<String>,
        expandedImages: Set<String>,
        imageSource: [String: Any],
        imageDataProvider: NativeImageDataProvider?,
        shouldCancel: NativeRenderCancellation,
        linkPayloads: inout [String: [String: Any]],
        rendered: NSMutableAttributedString
    ) {
        let document = parser.parse(text: diff, fallbackPath: fallbackPath)
        let lines = document.lines
        var currentPath = document.fallbackPath
        var collapsed = false
        var currentHunk: NativeDiffHunk?
        var currentHunkSyntax: [Int: [NativeSyntaxStyleRun]] = [:]
        var sideBySideSkipThrough = -1

        for (index, line) in lines.enumerated() {
            if index.isMultiple(of: 128), shouldCancel() {
                logger.debug("Cancelled diff rendering between line batches")
                return
            }
            if index <= sideBySideSkipThrough {
                continue
            }
            if let file = document.filesByStartIndex[NSNumber(value: index)] {
                currentPath = file.path
                currentHunk = nil
                currentHunkSyntax = [:]
                let fileKey = "\(sectionIndex):\(currentPath)"
                let suppressed = matchesSuppression(path: currentPath, patterns: suppressionPatterns) &&
                    !expandedImages.contains("suppression:\(fileKey)")
                collapsed = collapsedFiles.contains(fileKey) || suppressed
                support.appendLink(
                    title: collapsed ? "▸ " : "▾ ",
                    action: suppressed ? .revealSuppressed(key: fileKey) : .collapse(key: fileKey),
                    linkPayloads: &linkPayloads,
                    to: rendered
                )
                rendered.append(NSAttributedString(
                    string: currentPath + (suppressed ? " — Diff hidden by repository setting" : "") + "\n",
                    attributes: support.titleAttributes
                ))
                continue
            }
            if collapsed {
                continue
            }
            // The blob-mode metadata is useful in a raw patch, but it is visual
            // noise in GitX's rendered Detail view. Keep it in the parsed hunk
            // headers so copying and partial staging continue to use a complete
            // patch; omit it only from the presentation layer.
            if line.hasPrefix("index ") {
                continue
            }
            if let hunk = document.hunksByStartIndex[NSNumber(value: index)] {
                if shouldCancel() {
                    logger.debug("Cancelled diff rendering between hunks")
                    return
                }
                currentHunk = hunk
                currentHunkSyntax = shouldHighlightSyntax
                    ? syntaxHighlights(
                        for: hunk.lines,
                        path: currentPath,
                        runBudget: &runBudget
                    )
                    : [:]
                if runBudget.isExhausted, !loggedRunBudgetExhaustion {
                    logger.debug("Syntax run budget exhausted; rendering remaining diff lines lightly")
                    loggedRunBudgetExhaustion = true
                }
                appendDiffLine(line, to: rendered)
                rendered.append(NSAttributedString(string: "  "))
                if context == "staged" {
                    support.appendLink(
                        title: NSLocalizedString(
                            "Unstage hunk",
                            comment: "Action to unstage all lines in a diff hunk"
                        ),
                        action: .diff(action: "unstage", patch: hunk.patch),
                        linkPayloads: &linkPayloads,
                        to: rendered
                    )
                } else if context == "unstaged" {
                    support.appendLink(
                        title: NSLocalizedString(
                            "Stage hunk",
                            comment: "Action to stage all lines in a diff hunk"
                        ),
                        action: .diff(action: "stage", patch: hunk.patch),
                        linkPayloads: &linkPayloads,
                        to: rendered
                    )
                    rendered.append(NSAttributedString(string: "   "))
                    support.appendLink(
                        title: NSLocalizedString(
                            "Discard hunk",
                            comment: "Action to discard all changes in a diff hunk"
                        ),
                        action: .diff(action: "discard", patch: hunk.patch),
                        linkPayloads: &linkPayloads,
                        to: rendered
                    )
                }
                rendered.append(NSAttributedString(string: "\n"))
                if diffLayout == DiffLayout.sideBySide.rawValue {
                    appendSideBySideHunk(
                        hunk,
                        syntaxHighlights: currentHunkSyntax,
                        to: rendered
                    )
                    sideBySideSkipThrough = hunk.endIndex - 1
                }
                continue
            }

            if isBinaryImageLine(line, path: currentPath), !currentPath.isEmpty {
                appendDiffLine(line, to: rendered)
                let imageKey = "\(sectionIndex):\(currentPath)"
                if !expandedImages.contains(imageKey) {
                    support.appendLink(
                        title: NSLocalizedString(
                            "Show image",
                            comment: "Action to expand an image changed by a diff"
                        ),
                        action: .image(key: imageKey, path: currentPath, section: sectionIndex),
                        linkPayloads: &linkPayloads,
                        to: rendered
                    )
                    rendered.append(NSAttributedString(string: "\n", attributes: support.baseAttributes))
                } else if let imageData = imageDataProvider?(currentPath, sectionIndex, imageSource),
                          !imageData.isEmpty
                {
                    if let imageString = imageAttributedString(data: imageData) {
                        rendered.append(imageString)
                    }
                    rendered.append(NSAttributedString(string: "\n", attributes: support.baseAttributes))
                }
                continue
            }

            let changedLine = (line.hasPrefix("+") && !line.hasPrefix("+++")) ||
                (line.hasPrefix("-") && !line.hasPrefix("---"))
            let counterpart: String?
            if line.hasPrefix("-"), lines.indices.contains(index + 1), lines[index + 1].hasPrefix("+") {
                counterpart = lines[index + 1]
            } else if line.hasPrefix("+"), index > 0, lines[index - 1].hasPrefix("-") {
                counterpart = lines[index - 1]
            } else {
                counterpart = nil
            }
            let syntaxRuns: [NativeSyntaxStyleRun]? = if let currentHunk, index < currentHunk.endIndex {
                currentHunkSyntax[index - currentHunk.startIndex]
            } else {
                nil
            }
            guard changedLine, context != "readOnly", let currentHunk else {
                appendDiffLine(
                    line,
                    counterpart: counterpart,
                    syntaxRuns: syntaxRuns,
                    newline: true,
                    to: rendered
                )
                continue
            }

            appendDiffLine(
                line,
                counterpart: counterpart,
                syntaxRuns: syntaxRuns,
                newline: false,
                to: rendered
            )
            rendered.append(NSAttributedString(string: "   ", attributes: support.baseAttributes))
            let relativeIndex = index - currentHunk.startIndex
            let reverse = context == "staged"
            let primaryAction = reverse ? "unstage" : "stage"
            support.appendLink(
                title: reverse
                    ? NSLocalizedString("Unstage line", comment: "Action to unstage one changed line")
                    : NSLocalizedString("Stage line", comment: "Action to stage one changed line"),
                action: .partialDiff(
                    action: primaryAction,
                    fileHeader: currentHunk.fileHeader,
                    hunkLines: currentHunk.lines,
                    selectedIndexes: IndexSet(integer: relativeIndex),
                    reverse: reverse
                ),
                linkPayloads: &linkPayloads,
                to: rendered
            )

            let blockIndexes = currentHunk.blockIndexes(startingAt: relativeIndex)
            if !blockIndexes.isEmpty {
                rendered.append(NSAttributedString(string: "   ", attributes: support.baseAttributes))
                support.appendLink(
                    title: reverse
                        ? NSLocalizedString(
                            "Unstage block",
                            comment: "Action to unstage a contiguous block of changed lines"
                        )
                        : NSLocalizedString(
                            "Stage block",
                            comment: "Action to stage a contiguous block of changed lines"
                        ),
                    action: .partialDiff(
                        action: primaryAction,
                        fileHeader: currentHunk.fileHeader,
                        hunkLines: currentHunk.lines,
                        selectedIndexes: blockIndexes,
                        reverse: reverse
                    ),
                    linkPayloads: &linkPayloads,
                    to: rendered
                )
            }
            if context == "unstaged" {
                rendered.append(NSAttributedString(string: "   ", attributes: support.baseAttributes))
                support.appendLink(
                    title: NSLocalizedString(
                        "Discard line",
                        comment: "Action to discard one changed line"
                    ),
                    action: .partialDiff(
                        action: "discard",
                        fileHeader: currentHunk.fileHeader,
                        hunkLines: currentHunk.lines,
                        selectedIndexes: IndexSet(integer: relativeIndex),
                        reverse: false
                    ),
                    linkPayloads: &linkPayloads,
                    to: rendered
                )
            }
            rendered.append(NSAttributedString(string: "\n", attributes: support.baseAttributes))
        }
    }

    private func matchesSuppression(path: String, patterns: [String]) -> Bool {
        let range = NSRange(path.startIndex..., in: path)
        return patterns.contains { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
            return expression.firstMatch(in: path, range: range) != nil
        }
    }

    private func appendSideBySideHunk(
        _ hunk: NativeDiffHunk,
        syntaxHighlights: [Int: [NativeSyntaxStyleRun]],
        to rendered: NSMutableAttributedString
    ) {
        rendered.append(NSAttributedString(
            string: "──────────────────────── Before ────────────────────────┬──────────────────────── After ─────────────────────────\n",
            attributes: support.attributes(for: .sideHeader, merging: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .backgroundColor: NSColor.controlBackgroundColor,
            ])
        ))
        let rows = pairedRowIndexes(hunk.lines)
        for (leftIndex, rightIndex) in rows {
            let left = leftIndex.map { hunk.lines[$0] }
            let right = rightIndex.map { hunk.lines[$0] }
            let leftString = sideColumn(left)
            let rightString = sideColumn(right)
            let leftRendered = attributedDiffLine(
                leftString,
                counterpart: right.map(sideColumn),
                syntaxRuns: leftIndex.flatMap { syntaxHighlights[$0] }
            )
            let rightRendered = attributedDiffLine(
                rightString,
                counterpart: left.map(sideColumn),
                syntaxRuns: rightIndex.flatMap { syntaxHighlights[$0] }
            )
            rendered.append(leftRendered)
            rendered.append(NSAttributedString(
                string: " │ ",
                attributes: support.attributes(for: .sideSeparator, merging: [
                    .foregroundColor: NSColor.separatorColor,
                ])
            ))
            rendered.append(rightRendered)
            rendered.append(NSAttributedString(string: "\n", attributes: support.baseAttributes))
        }
        rendered.append(NSAttributedString(string: "\n", attributes: support.baseAttributes))
    }

    private func pairedRowIndexes(_ lines: [String]) -> [(Int?, Int?)] {
        var result: [(Int?, Int?)] = []
        var index = 1
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("-") {
                var removed: [Int] = []
                var added: [Int] = []
                while index < lines.count, lines[index].hasPrefix("-") {
                    removed.append(index)
                    index += 1
                }
                while index < lines.count, lines[index].hasPrefix("+") {
                    added.append(index)
                    index += 1
                }
                for row in 0 ..< max(removed.count, added.count) {
                    result.append((
                        removed.indices.contains(row) ? removed[row] : nil,
                        added.indices.contains(row) ? added[row] : nil
                    ))
                }
            } else if line.hasPrefix("+") {
                result.append((nil, index))
                index += 1
            } else if line.hasPrefix("\\") {
                index += 1
            } else {
                result.append((index, index))
                index += 1
            }
        }
        return result
    }

    private func sideColumn(_ line: String?) -> String {
        let width = 58
        guard let line else { return String(repeating: " ", count: width) }
        let lineString = line as NSString
        if lineString.length > width {
            return lineString.substring(to: width - 1) + "…"
        }
        return lineString.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private func syntaxHighlights(
        for hunkLines: [String],
        path: String,
        runBudget: inout NativeSyntaxRunBudget
    ) -> [Int: [NativeSyntaxStyleRun]] {
        guard syntaxStyler.hasTheme,
              !runBudget.isExhausted,
              PBHighlighting.languageName(forPath: path) != nil
        else { return [:] }

        let oldText = NSMutableString()
        let newText = NSMutableString()
        var oldRanges: [Int: NSRange] = [:]
        var newRanges: [Int: NSRange] = [:]
        for index in 1 ..< hunkLines.count {
            let line = hunkLines[index]
            guard let prefix = line.first, prefix == " " || prefix == "+" || prefix == "-" else {
                continue
            }
            let body = String(line.dropFirst())
            let bodyLength = (body as NSString).length
            if prefix != "+" {
                let range = NSRange(location: oldText.length, length: bodyLength)
                oldText.append(body + "\n")
                if prefix == "-" {
                    oldRanges[index] = range
                }
            }
            if prefix != "-" {
                let range = NSRange(location: newText.length, length: bodyLength)
                newText.append(body + "\n")
                newRanges[index] = range
            }
        }

        var highlights: [Int: [NativeSyntaxStyleRun]] = [:]
        let splitBudget = !oldRanges.isEmpty && !newRanges.isEmpty
        let oldRunLimit = splitBudget
            ? max(1, runBudget.remainingRunCount / 2)
            : runBudget.remainingRunCount
        var oldRunBudget = NativeSyntaxRunBudget(maximumRunCount: oldRunLimit)
        if !oldRanges.isEmpty {
            let oldHighlights = syntaxStyler.styleRuns(
                for: oldText as String,
                path: path,
                targetRanges: oldRanges,
                runBudget: &oldRunBudget
            )
            for (index, runs) in oldHighlights {
                highlights[index] = runs
            }
            runBudget.consumeRuns(oldRunLimit - oldRunBudget.remainingRunCount)
        }
        if !newRanges.isEmpty, !runBudget.isExhausted {
            let newHighlights = syntaxStyler.styleRuns(
                for: newText as String,
                path: path,
                targetRanges: newRanges,
                runBudget: &runBudget
            )
            for (index, runs) in newHighlights {
                highlights[index] = runs
            }
        }
        return highlights
    }

    private func attributedDiffLine(
        _ line: String,
        counterpart: String?,
        syntaxRuns: [NativeSyntaxStyleRun]?
    ) -> NSMutableAttributedString {
        var attributes = support.baseAttributes
        if line.hasPrefix("+"), !line.hasPrefix("+++") {
            attributes[.foregroundColor] = ApplicationSettings.addedTextColor
            attributes[.backgroundColor] = ApplicationSettings.addedBackgroundColor
        } else if line.hasPrefix("-"), !line.hasPrefix("---") {
            attributes[.foregroundColor] = ApplicationSettings.removedTextColor
            attributes[.backgroundColor] = ApplicationSettings.removedBackgroundColor
        } else if line.hasPrefix("@@") {
            attributes[.foregroundColor] = NSColor.systemBlue
            attributes[.backgroundColor] = NSColor(red: 0.20, green: 0.45, blue: 0.90, alpha: 0.10)
        } else if line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        }

        let result = NSMutableAttributedString(string: line, attributes: attributes)
        let bodyRange = NSRange(location: 0, length: max(0, result.length - 1))
        for run in syntaxRuns ?? [] {
            let visibleRange = NSIntersectionRange(run.range, bodyRange)
            guard visibleRange.length > 0 else { continue }
            result.addAttributes(
                run.attributes,
                range: NSRange(location: visibleRange.location + 1, length: visibleRange.length)
            )
        }

        if let counterpart, (counterpart as NSString).length > 1, (line as NSString).length > 1 {
            let left = (line as NSString).substring(from: 1) as NSString
            let right = (counterpart as NSString).substring(from: 1) as NSString
            var prefix = 0
            let limit = min(left.length, right.length)
            while prefix < limit, left.character(at: prefix) == right.character(at: prefix) {
                prefix += 1
            }
            var suffix = 0
            while suffix < limit - prefix,
                  left.character(at: left.length - 1 - suffix) == right.character(at: right.length - 1 - suffix)
            {
                suffix += 1
            }
            let changedLength = left.length - prefix - suffix
            if changedLength > 0 {
                let emphasis = line.hasPrefix("+")
                    ? NSColor(red: 0.15, green: 0.66, blue: 0.25, alpha: 0.30)
                    : NSColor(red: 0.90, green: 0.18, blue: 0.18, alpha: 0.27)
                result.addAttribute(
                    .backgroundColor,
                    value: emphasis,
                    range: NSRange(location: 1 + prefix, length: changedLength)
                )
            }
        }
        return result
    }

    private func appendDiffLine(
        _ line: String,
        counterpart: String? = nil,
        syntaxRuns: [NativeSyntaxStyleRun]? = nil,
        newline: Bool = true,
        to rendered: NSMutableAttributedString
    ) {
        rendered.append(attributedDiffLine(line, counterpart: counterpart, syntaxRuns: syntaxRuns))
        if newline {
            rendered.append(NSAttributedString(string: "\n", attributes: support.baseAttributes))
        }
    }

    private func isBinaryImageLine(_ line: String, path: String) -> Bool {
        guard line.hasPrefix("Binary files ") || line == "GIT binary patch" else { return false }
        let pathExtension = (path as NSString).pathExtension.lowercased()
        return Self.imageExtensions.contains(pathExtension)
    }

    private func imageAttributedString(data: Data) -> NSAttributedString? {
        var imageString: NSAttributedString?
        let createImageString = {
            guard let image = NSImage(data: data) else { return }
            let size = image.size
            let scale = min(1, min(800 / max(1, size.width), 500 / max(1, size.height)))
            image.size = NSSize(width: size.width * scale, height: size.height * scale)
            let attachment = NSTextAttachment()
            attachment.image = image
            imageString = NSAttributedString(attachment: attachment)
        }
        if Thread.isMainThread {
            createImageString()
        } else {
            DispatchQueue.main.sync(execute: createImageString)
        }
        return imageString
    }
}

// swiftlint:enable unused_declaration
