import ForgeKit
import Foundation

nonisolated struct RepositoryPullRequestReviewDiffSelection: Hashable, Sendable {
    let anchor: ForgeReviewAnchor
    let contextLines: [String]
    let isTruncated: Bool
}

/// Exact native-text ranges occupied by one server review anchor. File anchors
/// map to the rendered file heading; line and range anchors map to every exact
/// same-side diff line. The ranges are presentation coordinates only and never
/// rewrite the immutable server anchor.
nonisolated struct RepositoryPullRequestReviewDiffAnchorPlacement: Hashable, Sendable {
    let anchor: ForgeReviewAnchor
    let characterRanges: [NSRange]
}

nonisolated enum RepositoryPullRequestReviewDiffAnchorError: Error, Equatable, LocalizedError,
    Sendable
{
    case unavailableAnchor
    case ambiguousAnchor

    var errorDescription: String? {
        switch self {
        case .unavailableAnchor:
            "The exact review-thread anchor is not present in the rendered local diff."
        case .ambiguousAnchor:
            "The review-thread anchor occurs more than once in the rendered local diff."
        }
    }
}

nonisolated enum RepositoryPullRequestReviewDiffSelectionError: Error, Equatable, LocalizedError,
    Sendable
{
    case emptySelection
    case malformedDiff
    case unavailableSelection
    case ambiguousSelection
    case mixedDiffSides

    var errorDescription: String? {
        switch self {
        case .emptySelection: "Select one or more local diff lines before adding an inline review comment."
        case .malformedDiff: "The local Pull Request diff is malformed."
        case .unavailableSelection: "The selected text does not identify an exact local diff anchor."
        case .ambiguousSelection: "The selected text occurs at more than one local diff anchor."
        case .mixedDiffSides: "An inline review range must stay on one side of the diff."
        }
    }
}

/// Maps an explicit native-text selection back to one exact unified-diff
/// location. It never guesses among duplicate text and accepts only one file
/// and one diff side for a range.
nonisolated enum RepositoryPullRequestReviewDiffSelectionPolicy {
    private struct Line: Equatable {
        let path: ForgeFilePath
        let sectionID: Int
        let hunkID: Int
        let marker: Character
        let body: String
        let leftLine: Int?
        let rightLine: Int?
        let characterRange: NSRange
    }

    private struct FileHeader: Equatable {
        let path: ForgeFilePath
        let characterRange: NSRange
    }

    private struct ParsedDiff: Equatable {
        var lines: [Line] = []
        var fileHeaders: [FileHeader] = []
    }

    private struct RawLine {
        let text: String
        let characterRange: NSRange
    }

    // Decision-level app-hosted tests exercise text-only ambiguity and malformed-diff boundaries.
    // swiftlint:disable:next unused_declaration
    static func selection(
        patch: String,
        selectedText: String
    ) throws -> RepositoryPullRequestReviewDiffSelection {
        let selected = selectedText
            .components(separatedBy: .newlines)
            .dropTrailingEmpty()
        guard !selected.isEmpty else {
            throw RepositoryPullRequestReviewDiffSelectionError.emptySelection
        }
        let parsed = try parse(patch).lines
        guard !parsed.isEmpty else {
            throw RepositoryPullRequestReviewDiffSelectionError.malformedDiff
        }
        let candidates = parsed.indices.compactMap { start -> ArraySlice<Line>? in
            let end = start + selected.count
            guard end <= parsed.count else { return nil }
            let slice = parsed[start ..< end]
            guard zip(slice, selected).allSatisfy({ line, text in
                line.marker == text.first && String(text.dropFirst()) == line.body
            }) else { return nil }
            return slice
        }
        guard !candidates.isEmpty else {
            throw RepositoryPullRequestReviewDiffSelectionError.unavailableSelection
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw RepositoryPullRequestReviewDiffSelectionError.ambiguousSelection
        }
        return try makeSelection(from: candidate)
    }

    /// Maps a concrete native text selection by its presentation coordinates.
    /// The range is authoritative when available, so identical rendered lines
    /// remain independently selectable. The resulting provider-neutral anchor
    /// must still exist exactly in the immutable local patch.
    static func selection(
        patch: String,
        renderedText: String,
        selectedRange: NSRange
    ) throws -> RepositoryPullRequestReviewDiffSelection {
        let renderedLength = (renderedText as NSString).length
        guard selectedRange.location != NSNotFound,
              selectedRange.length > 0,
              NSMaxRange(selectedRange) <= renderedLength
        else {
            throw RepositoryPullRequestReviewDiffSelectionError.emptySelection
        }
        let parsed = try parse(renderedText)
        guard !parsed.lines.isEmpty else {
            throw RepositoryPullRequestReviewDiffSelectionError.malformedDiff
        }
        let selectedLines = parsed.lines.filter {
            NSIntersectionRange($0.characterRange, selectedRange).length > 0
        }
        guard !selectedLines.isEmpty else {
            throw RepositoryPullRequestReviewDiffSelectionError.unavailableSelection
        }
        let selection = try makeSelection(from: selectedLines[...])
        _ = try anchorPlacement(
            patch: patch,
            renderedText: renderedText,
            anchor: selection.anchor
        )
        return selection
    }

    private static func makeSelection(
        from candidate: ArraySlice<Line>
    ) throws -> RepositoryPullRequestReviewDiffSelection {
        guard let first = candidate.first else {
            throw RepositoryPullRequestReviewDiffSelectionError.emptySelection
        }
        guard candidate.allSatisfy({ $0.path == first.path }) else {
            throw RepositoryPullRequestReviewDiffSelectionError.unavailableSelection
        }
        guard candidate.allSatisfy({
            $0.sectionID == first.sectionID && $0.hunkID == first.hunkID
        }) else {
            throw RepositoryPullRequestReviewDiffSelectionError.unavailableSelection
        }

        let hasLeftOnly = candidate.contains { $0.marker == "-" }
        let hasRightOnly = candidate.contains { $0.marker == "+" }
        guard !(hasLeftOnly && hasRightOnly) else {
            throw RepositoryPullRequestReviewDiffSelectionError.mixedDiffSides
        }
        let side: ForgeReviewDiffSide = hasLeftOnly ? .left : .right
        let lineNumbers = candidate.compactMap { line in
            side == .left ? line.leftLine : line.rightLine
        }
        guard lineNumbers.count == candidate.count,
              let startLine = lineNumbers.first,
              let endLine = lineNumbers.last,
              zip(lineNumbers, lineNumbers.dropFirst()).allSatisfy({ current, next in
                  next == current + 1
              })
        else {
            throw RepositoryPullRequestReviewDiffSelectionError.unavailableSelection
        }
        let anchor = ForgeReviewAnchor(
            path: first.path,
            subject: .line,
            side: side,
            startSide: lineNumbers.count > 1 ? side : nil,
            startLine: lineNumbers.count > 1 ? startLine : nil,
            line: endLine,
            originalStartLine: side == .left && lineNumbers.count > 1 ? startLine : nil,
            originalLine: side == .left ? endLine : nil
        )
        return RepositoryPullRequestReviewDiffSelection(
            anchor: anchor,
            contextLines: candidate.map { $0.body },
            // RepositoryLocalPullRequestDiff is produced by an uncapped local
            // `git diff`, so an ordinary hunk boundary is not truncation. A
            // future capped producer must carry explicit truncation metadata
            // rather than inferring it from unified-diff context edges.
            isTruncated: false
        )
    }

    /// Locates an immutable server anchor in both the authoritative local patch
    /// and the native renderer's current text. Requiring both prevents a
    /// presentation-only string from manufacturing an anchor and makes
    /// duplicate or collapsed locations fail closed.
    static func anchorPlacement(
        patch: String,
        renderedText: String,
        anchor: ForgeReviewAnchor
    ) throws -> RepositoryPullRequestReviewDiffAnchorPlacement {
        do {
            _ = try characterRanges(for: anchor, in: parse(patch))
            let renderedRanges = try characterRanges(for: anchor, in: parse(renderedText))
            return RepositoryPullRequestReviewDiffAnchorPlacement(
                anchor: anchor,
                characterRanges: renderedRanges
            )
        } catch let error as RepositoryPullRequestReviewDiffAnchorError {
            throw error
        } catch {
            throw RepositoryPullRequestReviewDiffAnchorError.unavailableAnchor
        }
    }

    private static func parse(_ patch: String) throws -> ParsedDiff {
        var path: ForgeFilePath?
        var oldPath: ForgeFilePath?
        var oldLine: Int?
        var newLine: Int?
        var oldRemaining: Int?
        var newRemaining: Int?
        var recordedFileHeader = false
        var sectionID = 0
        var hunkID = 0
        var result = ParsedDiff()

        func requireCompletedHunk() throws {
            guard oldRemaining == nil && newRemaining == nil
                || oldRemaining == 0 && newRemaining == 0
            else {
                throw RepositoryPullRequestReviewDiffSelectionError.malformedDiff
            }
        }

        for record in rawLines(patch) {
            let raw = record.text
            if raw.hasPrefix("diff --git ") {
                try requireCompletedHunk()
                sectionID += 1
                path = diffHeaderPath(raw)
                guard path != nil else {
                    throw RepositoryPullRequestReviewDiffSelectionError.malformedDiff
                }
                oldPath = nil
                oldLine = nil
                newLine = nil
                oldRemaining = nil
                newRemaining = nil
                recordedFileHeader = path != nil
                if let path {
                    result.fileHeaders.append(FileHeader(
                        path: path,
                        characterRange: record.characterRange
                    ))
                }
                continue
            }
            if raw.hasPrefix("▾ ") || raw.hasPrefix("▸ ") {
                try requireCompletedHunk()
                sectionID += 1
                let displayedPath = String(raw.dropFirst(2))
                    .components(separatedBy: " — Diff hidden by repository setting")[0]
                path = try? ForgeFilePath(displayedPath)
                oldPath = path
                oldLine = nil
                newLine = nil
                oldRemaining = nil
                newRemaining = nil
                recordedFileHeader = path != nil
                if let path {
                    result.fileHeaders.append(FileHeader(
                        path: path,
                        characterRange: record.characterRange
                    ))
                }
                continue
            }
            if raw.hasPrefix("@@ ") {
                try requireCompletedHunk()
                guard let ranges = hunkRanges(raw) else {
                    throw RepositoryPullRequestReviewDiffSelectionError.malformedDiff
                }
                oldLine = ranges.old.start
                newLine = ranges.new.start
                oldRemaining = ranges.old.count
                newRemaining = ranges.new.count
                hunkID += 1
                continue
            }
            if oldRemaining != nil || newRemaining != nil {
                if raw.hasPrefix("\\ No newline at end of file") {
                    continue
                }
                guard let path,
                      let marker = raw.first,
                      marker == " " || marker == "+" || marker == "-",
                      let currentOldLine = oldLine,
                      let currentNewLine = newLine,
                      let currentOldRemaining = oldRemaining,
                      let currentNewRemaining = newRemaining
                else {
                    throw RepositoryPullRequestReviewDiffSelectionError.malformedDiff
                }
                let entry: Line
                switch marker {
                case "+":
                    guard currentNewRemaining > 0 else {
                        throw RepositoryPullRequestReviewDiffSelectionError.malformedDiff
                    }
                    entry = Line(
                        path: path,
                        sectionID: sectionID,
                        hunkID: hunkID,
                        marker: marker,
                        body: String(raw.dropFirst()),
                        leftLine: nil,
                        rightLine: currentNewLine,
                        characterRange: record.characterRange
                    )
                    newLine = currentNewLine + 1
                    newRemaining = currentNewRemaining - 1
                case "-":
                    guard currentOldRemaining > 0 else {
                        throw RepositoryPullRequestReviewDiffSelectionError.malformedDiff
                    }
                    entry = Line(
                        path: path,
                        sectionID: sectionID,
                        hunkID: hunkID,
                        marker: marker,
                        body: String(raw.dropFirst()),
                        leftLine: currentOldLine,
                        rightLine: nil,
                        characterRange: record.characterRange
                    )
                    oldLine = currentOldLine + 1
                    oldRemaining = currentOldRemaining - 1
                default:
                    guard currentOldRemaining > 0, currentNewRemaining > 0 else {
                        throw RepositoryPullRequestReviewDiffSelectionError.malformedDiff
                    }
                    entry = Line(
                        path: path,
                        sectionID: sectionID,
                        hunkID: hunkID,
                        marker: marker,
                        body: String(raw.dropFirst()),
                        leftLine: currentOldLine,
                        rightLine: currentNewLine,
                        characterRange: record.characterRange
                    )
                    oldLine = currentOldLine + 1
                    newLine = currentNewLine + 1
                    oldRemaining = currentOldRemaining - 1
                    newRemaining = currentNewRemaining - 1
                }
                result.lines.append(entry)
                continue
            }
            if raw.hasPrefix("--- ") {
                oldPath = filePath(String(raw.dropFirst(4)), strippingPrefix: "a/")
                continue
            }
            if raw.hasPrefix("+++ ") {
                let value = String(raw.dropFirst(4))
                if value == "/dev/null" {
                    path = oldPath
                } else {
                    path = filePath(value, strippingPrefix: "b/")
                }
                if let path, !recordedFileHeader {
                    result.fileHeaders.append(FileHeader(
                        path: path,
                        characterRange: record.characterRange
                    ))
                    recordedFileHeader = true
                }
                continue
            }
        }
        try requireCompletedHunk()
        return result
    }

    private static func characterRanges(
        for anchor: ForgeReviewAnchor,
        in parsed: ParsedDiff
    ) throws -> [NSRange] {
        switch anchor.subject {
        case .file:
            guard anchor.side == nil,
                  anchor.startSide == nil,
                  anchor.startLine == nil,
                  anchor.line == nil,
                  anchor.originalStartLine == nil,
                  anchor.originalLine == nil
            else {
                throw RepositoryPullRequestReviewDiffAnchorError.unavailableAnchor
            }
            let matches = parsed.fileHeaders.filter { $0.path == anchor.path }
            guard !matches.isEmpty else {
                throw RepositoryPullRequestReviewDiffAnchorError.unavailableAnchor
            }
            guard matches.count == 1 else {
                throw RepositoryPullRequestReviewDiffAnchorError.ambiguousAnchor
            }
            return [matches[0].characterRange]
        case .line:
            guard let side = anchor.side else {
                throw RepositoryPullRequestReviewDiffAnchorError.unavailableAnchor
            }
            guard (anchor.startSide == nil) == (anchor.startLine == nil),
                  anchor.startSide == nil || anchor.startSide == side
            else {
                throw RepositoryPullRequestReviewDiffAnchorError.unavailableAnchor
            }
            let end = side == .left
                ? anchor.originalLine ?? anchor.line
                : anchor.line
            guard let end else {
                throw RepositoryPullRequestReviewDiffAnchorError.unavailableAnchor
            }
            let start = side == .left
                ? anchor.originalStartLine ?? anchor.startLine ?? end
                : anchor.startLine ?? end
            guard start > 0, end >= start else {
                throw RepositoryPullRequestReviewDiffAnchorError.unavailableAnchor
            }
            let matches = try (start ... end).map { lineNumber in
                let matches = parsed.lines.filter { line in
                    guard line.path == anchor.path else { return false }
                    return side == .left
                        ? line.leftLine == lineNumber
                        : line.rightLine == lineNumber
                }
                guard !matches.isEmpty else {
                    throw RepositoryPullRequestReviewDiffAnchorError.unavailableAnchor
                }
                guard matches.count == 1 else {
                    throw RepositoryPullRequestReviewDiffAnchorError.ambiguousAnchor
                }
                return matches[0]
            }
            guard let first = matches.first,
                  matches.allSatisfy({
                      $0.sectionID == first.sectionID && $0.hunkID == first.hunkID
                  })
            else {
                throw RepositoryPullRequestReviewDiffAnchorError.unavailableAnchor
            }
            return matches.map(\.characterRange)
        }
    }

    private static func rawLines(_ text: String) -> [RawLine] {
        let source = text as NSString
        var result: [RawLine] = []
        var location = 0
        while location < source.length {
            let fullRange = source.lineRange(for: NSRange(location: location, length: 0))
            var contentRange = fullRange
            while contentRange.length > 0 {
                let last = source.character(at: NSMaxRange(contentRange) - 1)
                guard last == 10 || last == 13 else { break }
                contentRange.length -= 1
            }
            result.append(RawLine(
                text: source.substring(with: contentRange),
                characterRange: contentRange
            ))
            location = NSMaxRange(fullRange)
        }
        return result
    }

    private static func hunkRanges(
        _ line: String
    ) -> (old: (start: Int, count: Int), new: (start: Int, count: Int))? {
        let parts = line.split(separator: " ")
        guard parts.count >= 4,
              parts[3] == "@@",
              parts[1].first == "-",
              parts[2].first == "+",
              let oldRange = hunkRange(parts[1], marker: "-"),
              let newRange = hunkRange(parts[2], marker: "+")
        else { return nil }
        return (oldRange, newRange)
    }

    private static func hunkRange(_ value: Substring, marker: Character) -> (start: Int, count: Int)? {
        guard value.first == marker else { return nil }
        let components = value.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 1 || components.count == 2 else { return nil }
        guard let start = Int(components.first ?? ""), start >= 0 else { return nil }
        let count = components.count == 1 ? 1 : Int(components[1])
        guard let count, count >= 0, start > 0 || count == 0 else { return nil }
        return (start, count)
    }

    private static func filePath(_ value: String, strippingPrefix prefix: String) -> ForgeFilePath? {
        guard value != "/dev/null" else { return nil }
        guard let decoded = decodedGitPath(value) else { return nil }
        let normalized = decoded.hasPrefix(prefix) ? String(decoded.dropFirst(prefix.count)) : decoded
        return try? ForgeFilePath(normalized)
    }

    private static func diffHeaderPath(_ line: String) -> ForgeFilePath? {
        let value = String(line.dropFirst("diff --git ".count))
        var tokens: [String] = []
        var token = ""
        var isQuoted = false
        var isEscaped = false
        for character in value {
            if character == " " && !isQuoted {
                if !token.isEmpty {
                    tokens.append(token)
                    token = ""
                }
                continue
            }
            token.append(character)
            if isEscaped {
                isEscaped = false
            } else if character == "\\" && isQuoted {
                isEscaped = true
            } else if character == "\"" {
                isQuoted.toggle()
            }
        }
        guard !isQuoted, !isEscaped else { return nil }
        if !token.isEmpty {
            tokens.append(token)
        }
        guard tokens.count == 2 else { return nil }
        return filePath(tokens[1], strippingPrefix: "b/")
    }

    /// Git C-quotes unusual path bytes when `core.quotePath` is enabled. Use
    /// the same byte-level decoding as the native diff renderer before Forge
    /// path validation; malformed or unsafe results still fail closed there.
    private static func decodedGitPath(_ input: String) -> String? {
        let beginsQuoted = input.hasPrefix("\"")
        let endsQuoted = input.hasSuffix("\"")
        guard beginsQuoted == endsQuoted else { return nil }
        guard beginsQuoted, input.count >= 2 else { return input }
        let scalars = Array(input.dropFirst().dropLast().unicodeScalars)
        var bytes: [UInt8] = []
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\\" else {
                bytes.append(contentsOf: String(scalar).utf8)
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else { return nil }
            let escaped = scalars[index]
            if (48 ... 55).contains(escaped.value) {
                var value = 0
                var digitCount = 0
                while index < scalars.count,
                      digitCount < 3,
                      (48 ... 55).contains(scalars[index].value)
                {
                    value = value * 8 + Int(scalars[index].value - 48)
                    index += 1
                    digitCount += 1
                }
                guard value <= UInt8.max else { return nil }
                bytes.append(UInt8(value))
                continue
            }
            let escapedBytes: [UInt8]
            switch escaped {
            case "a": escapedBytes = [7]
            case "b": escapedBytes = [8]
            case "t": escapedBytes = [9]
            case "n": escapedBytes = [10]
            case "v": escapedBytes = [11]
            case "f": escapedBytes = [12]
            case "r": escapedBytes = [13]
            case "\"": escapedBytes = [UInt8(ascii: "\"")]
            case "\\": escapedBytes = [UInt8(ascii: "\\")]
            default: return nil
            }
            bytes.append(contentsOf: escapedBytes)
            index += 1
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

/// Converts GitHub's fenced suggestion plus immutable server diff context into
/// one local-edit value. It fails closed when the fence or anchor is ambiguous,
/// adjusted beyond the thread range, or absent from the supplied diff hunk.
nonisolated enum RepositoryPullRequestSuggestedChangePolicy {
    static func change(
        comment: ForgeReviewComment,
        anchor: ForgeReviewAnchor,
        pullRequest: ForgeItemNumber,
        displayedHead: ForgeCommitID
    ) -> ForgeSuggestedChange? {
        guard comment.replyToID == nil,
              !comment.isMinimized,
              let replacement = exactReplacement(
                  in: comment.bodyMarkdown,
                  repository: comment.repository,
                  displayedHead: displayedHead
              ),
              let diffHunk = comment.diffHunk,
              let originalLines = exactContextLines(diffHunk: diffHunk, anchor: anchor),
              !originalLines.isEmpty
        else { return nil }
        return try? ForgeSuggestedChange(
            repository: comment.repository,
            pullRequest: pullRequest,
            displayedHead: displayedHead,
            path: anchor.path,
            originalText: originalLines.joined(separator: "\n"),
            replacementText: replacement
        )
    }

    static func exactContextLines(
        diffHunk: String,
        anchor: ForgeReviewAnchor
    ) -> [String]? {
        guard anchor.subject == .line,
              anchor.side == .right,
              (anchor.startSide == nil) == (anchor.startLine == nil),
              anchor.startSide == nil || anchor.startSide == .right,
              let endLine = anchor.line
        else { return nil }
        let startLine = anchor.startLine ?? endLine
        guard startLine > 0, endLine >= startLine else { return nil }

        var newLine: Int?
        var oldRemaining: Int?
        var newRemaining: Int?
        var linesByNumber: [Int: String] = [:]
        var hunkID = 0
        var matchingHunkID: Int?
        for rawLine in diffHunk.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("@@ ") {
                guard (oldRemaining == nil && newRemaining == nil)
                    || (oldRemaining == 0 && newRemaining == 0),
                    let ranges = suggestionHunkRanges(rawLine)
                else { return nil }
                newLine = ranges.new.start
                oldRemaining = ranges.old.count
                newRemaining = ranges.new.count
                hunkID += 1
                continue
            }
            guard oldRemaining != nil || newRemaining != nil else { continue }
            if rawLine.hasPrefix("\\ No newline at end of file") {
                continue
            }
            guard let marker = rawLine.first,
                  let currentNewLine = newLine,
                  let currentOldRemaining = oldRemaining,
                  let currentNewRemaining = newRemaining
            else {
                guard oldRemaining == 0, newRemaining == 0 else { return nil }
                continue
            }
            switch marker {
            case "+":
                guard currentNewRemaining > 0 else { return nil }
                if startLine ... endLine ~= currentNewLine {
                    guard matchingHunkID == nil || matchingHunkID == hunkID else { return nil }
                    matchingHunkID = hunkID
                    guard linesByNumber[currentNewLine] == nil else { return nil }
                    linesByNumber[currentNewLine] = String(rawLine.dropFirst())
                }
                newLine = currentNewLine + 1
                newRemaining = currentNewRemaining - 1
            case "-":
                guard currentOldRemaining > 0 else { return nil }
                oldRemaining = currentOldRemaining - 1
            case " ":
                guard currentOldRemaining > 0, currentNewRemaining > 0 else { return nil }
                if startLine ... endLine ~= currentNewLine {
                    guard matchingHunkID == nil || matchingHunkID == hunkID else { return nil }
                    matchingHunkID = hunkID
                    guard linesByNumber[currentNewLine] == nil else { return nil }
                    linesByNumber[currentNewLine] = String(rawLine.dropFirst())
                }
                newLine = currentNewLine + 1
                oldRemaining = currentOldRemaining - 1
                newRemaining = currentNewRemaining - 1
            default:
                return nil
            }
        }
        let expectedNumbers = Array(startLine ... endLine)
        guard oldRemaining == 0,
              newRemaining == 0,
              expectedNumbers.allSatisfy({ linesByNumber[$0] != nil })
        else { return nil }
        return expectedNumbers.compactMap { linesByNumber[$0] }
    }

    private static func exactReplacement(
        in markdown: String,
        repository: ForgeRepositoryIdentity,
        displayedHead: ForgeCommitID
    ) -> String? {
        let document = ForgeMarkdownSanitizer().sanitize(
            markdown,
            context: ForgeMarkdownContext(
                repository: repository,
                location: .repository(defaultBranch: .commit(displayedHead))
            )
        )
        let replacements = document.blocks.compactMap { block -> String? in
            guard case let .codeBlock(language, code) = block,
                  language == "suggestion"
            else { return nil }
            // swift-markdown retains the source newline immediately before the
            // closing fence. It is syntax rather than replacement content.
            return code.hasSuffix("\n") ? String(code.dropLast()) : code
        }
        guard replacements.count == 1 else { return nil }
        return replacements[0]
    }

    private static func suggestionHunkRanges(
        _ line: String
    ) -> (old: (start: Int, count: Int), new: (start: Int, count: Int))? {
        let parts = line.split(separator: " ")
        guard parts.count >= 4,
              parts[3] == "@@",
              let old = suggestionHunkRange(parts[1], marker: "-"),
              let new = suggestionHunkRange(parts[2], marker: "+")
        else { return nil }
        return (old, new)
    }

    private static func suggestionHunkRange(
        _ value: Substring,
        marker: Character
    ) -> (start: Int, count: Int)? {
        guard value.first == marker else { return nil }
        let components = value.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 1 || components.count == 2,
              let start = Int(components[0])
        else { return nil }
        let parsedCount = components.count == 1 ? 1 : Int(components[1])
        guard let count = parsedCount,
              start >= 0,
              count >= 0,
              start > 0 || count == 0
        else { return nil }
        return (start, count)
    }
}

private extension Array where Element == String {
    nonisolated func dropTrailingEmpty() -> [String] {
        var values = Array(self)
        while values.last?.isEmpty == true {
            values.removeLast()
        }
        return values
    }
}
