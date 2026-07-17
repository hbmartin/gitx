import Foundation
import OSLog // swiftlint:disable:this unused_import -- Logger requires OSLog despite analyzer's false positive.

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

@objc(PBNativeContentSection)
final nonisolated class NativeContentSection: NSObject {
    @objc let title: String
    @objc let text: String
    @objc let path: String
    @objc let context: String
    @objc let entries: [[String: Any]]
    @objc let imageSource: [String: Any]
    @objc let displayTitle: String
    @objc let highlightingPath: String
    @objc let diffLayout: Int
    @objc let suppressionPatterns: [String]

    @objc(initWithDictionary:)
    init(dictionary: [String: Any]) {
        title = dictionary[PBNativeSectionTitleKey] as? String ?? ""
        text = dictionary[PBNativeSectionTextKey] as? String ?? ""
        path = dictionary[PBNativeSectionPathKey] as? String ?? ""
        context = dictionary[PBNativeSectionContextKey] as? String ?? "readOnly"
        entries = dictionary[PBNativeSectionEntriesKey] as? [[String: Any]] ?? []
        imageSource = dictionary[PBNativeSectionImageSourceKey] as? [String: Any] ?? [:]
        displayTitle = dictionary[PBNativeSectionTitleKey] as? String ??
            dictionary[PBNativeSectionPathKey] as? String ?? ""
        highlightingPath = dictionary[PBNativeSectionPathKey] as? String ?? displayTitle
        diffLayout = (dictionary[PBNativeSectionDiffLayoutKey] as? NSNumber)?.intValue ??
            ApplicationSettings.diffLayout.rawValue
        suppressionPatterns = dictionary[PBNativeSectionSuppressionPatternsKey] as? [String] ?? []
        super.init()
    }

    @objc(sectionsWithDictionaries:)
    static func sections(dictionaries: [[String: Any]]) -> [NativeContentSection] {
        dictionaries.map(NativeContentSection.init(dictionary:))
    }
}

@objc(PBNativeDiffFile)
final nonisolated class NativeDiffFile: NSObject {
    @objc let startIndex: Int
    @objc let path: String
    @objc let headerLines: [String]

    init(startIndex: Int, path: String, headerLines: [String]) {
        self.startIndex = startIndex
        self.path = path
        self.headerLines = headerLines
        super.init()
    }
}

@objc(PBNativeDiffHunk)
final nonisolated class NativeDiffHunk: NSObject {
    @objc let startIndex: Int
    @objc let endIndex: Int
    @objc let lines: [String]
    @objc let fileHeader: [String]
    @objc let patch: String

    init(startIndex: Int, endIndex: Int, lines: [String], fileHeader: [String]) {
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.lines = lines
        self.fileHeader = fileHeader
        patch = (fileHeader + lines).joined(separator: "\n") + "\n"
        super.init()
    }

    @objc(blockIndexesStartingAtIndex:)
    func blockIndexes(startingAt index: Int) -> IndexSet {
        guard lines.indices.contains(index), index > 0 else { return [] }
        let line = lines[index]
        guard line.hasPrefix("+") || line.hasPrefix("-") else { return [] }
        if index > 1 {
            let previous = lines[index - 1]
            guard !previous.hasPrefix("+"), !previous.hasPrefix("-") else { return [] }
        }

        var end = index
        while lines.indices.contains(end + 1) {
            let next = lines[end + 1]
            guard next.hasPrefix("+") || next.hasPrefix("-") || next.hasPrefix("\\") else { break }
            end += 1
        }
        return IndexSet(integersIn: index ... end)
    }
}

@objc(PBNativeDiffDocument)
final nonisolated class NativeDiffDocument: NSObject {
    @objc let lines: [String]
    @objc let fallbackPath: String
    @objc let filesByStartIndex: [NSNumber: NativeDiffFile]
    @objc let hunksByStartIndex: [NSNumber: NativeDiffHunk]

    init(
        lines: [String],
        fallbackPath: String,
        filesByStartIndex: [NSNumber: NativeDiffFile],
        hunksByStartIndex: [NSNumber: NativeDiffHunk]
    ) {
        self.lines = lines
        self.fallbackPath = fallbackPath
        self.filesByStartIndex = filesByStartIndex
        self.hunksByStartIndex = hunksByStartIndex
        super.init()
    }
}

@objc(PBDiffDocumentParser)
final nonisolated class DiffDocumentParser: NSObject {
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "DiffDocumentParser")

    @objc(parseText:fallbackPath:)
    func parse(text: String, fallbackPath: String) -> NativeDiffDocument {
        let lines = text.components(separatedBy: "\n")
        var files: [NSNumber: NativeDiffFile] = [:]
        var hunks: [NSNumber: NativeDiffHunk] = [:]
        var fileHeader: [String] = []

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("diff --git ") {
                fileHeader = [line]
                let file = NativeDiffFile(
                    startIndex: index,
                    path: path(forDiffHeaderAt: index, lines: lines),
                    headerLines: fileHeader
                )
                files[NSNumber(value: index)] = file
                index += 1
                continue
            }
            if line.hasPrefix("@@") {
                var end = index + 1
                while end < lines.count,
                      !lines[end].hasPrefix("@@"),
                      !lines[end].hasPrefix("diff --git ")
                {
                    end += 1
                }
                let hunk = NativeDiffHunk(
                    startIndex: index,
                    endIndex: end,
                    lines: Array(lines[index ..< end]),
                    fileHeader: fileHeader
                )
                hunks[NSNumber(value: index)] = hunk
                index = end
                continue
            }
            if !fileHeader.isEmpty, isFileHeaderDetail(line) {
                fileHeader.append(line)
            }
            index += 1
        }

        logger.debug("Parsed diff document")
        return NativeDiffDocument(
            lines: lines,
            fallbackPath: fallbackPath,
            filesByStartIndex: files,
            hunksByStartIndex: hunks
        )
    }

    @objc(pathForDiffHeaderAtIndex:lines:)
    func path(forDiffHeaderAt headerIndex: Int, lines: [String]) -> String {
        guard lines.indices.contains(headerIndex) else { return "" }
        var oldPath: String?
        var index = headerIndex + 1
        while index < lines.count, !lines[index].hasPrefix("diff --git ") {
            let line = lines[index]
            if line.hasPrefix("rename to ") {
                return normalizedPath(String(line.dropFirst(10)))
            }
            if line.hasPrefix("copy to ") {
                return normalizedPath(String(line.dropFirst(8)))
            }
            if line.hasPrefix("+++ "), line != "+++ /dev/null" {
                return normalizedPath(String(line.dropFirst(4)))
            }
            if line.hasPrefix("--- "), line != "--- /dev/null" {
                oldPath = normalizedPath(String(line.dropFirst(4)))
            }
            index += 1
        }
        if let oldPath, !oldPath.isEmpty {
            return oldPath
        }

        let header = lines[headerIndex]
        if let destination = header.range(of: " b/", options: .backwards) {
            let pathStart = header.index(destination.upperBound, offsetBy: -2)
            return normalizedPath(String(header[pathStart...]))
        }
        return header
    }

    private func normalizedPath(_ input: String) -> String {
        var path = input
        if path.hasPrefix("\""), path.hasSuffix("\""), path.utf16.count >= 2 {
            path = String(path.dropFirst().dropLast())
        }
        path = path.replacingOccurrences(of: "\\\"", with: "\"")
        path = path.replacingOccurrences(of: "\\\\", with: "\\")
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            path = String(path.dropFirst(2))
        }
        return path
    }

    private func isFileHeaderDetail(_ line: String) -> Bool {
        line.hasPrefix("index ") ||
            line.hasPrefix("new file ") ||
            line.hasPrefix("deleted file ") ||
            line.hasPrefix("--- ") ||
            line.hasPrefix("+++ ")
    }
}

@objc(PBPartialPatchBuilder)
final nonisolated class PartialPatchBuilder: NSObject {
    private static let hunkExpression = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: "^@@ -(\\d+)(?:,\\d+)? \\+(\\d+)(?:,\\d+)? @@(.*)$"
    )

    @objc(patchWithFileHeader:hunkLines:selectedIndexes:reverse:)
    func patch(
        fileHeader: [String],
        hunkLines: [String],
        selectedIndexes: IndexSet,
        reverse: Bool
    ) -> String? {
        guard hunkLines.count >= 2, hunkLines[0].hasPrefix("@@") else { return nil }
        let header = hunkLines[0] as NSString
        guard let match = Self.hunkExpression.firstMatch(
            in: hunkLines[0],
            range: NSRange(location: 0, length: header.length)
        ), match.numberOfRanges >= 4 else { return nil }

        let oldStart = header.substring(with: match.range(at: 1))
        let newStart = header.substring(with: match.range(at: 2))
        let suffix = header.substring(with: match.range(at: 3))
        var body: [String] = []
        var oldCount = 0
        var newCount = 0
        var previousLineWasEmittedVerbatim = false

        for index in 1 ..< hunkLines.count {
            var line = hunkLines[index]
            guard let first = line.first else { continue }
            if first == "\\" {
                if previousLineWasEmittedVerbatim {
                    body.append(line)
                }
                continue
            }

            var prefix = first
            var emittedVerbatim = true
            if !selectedIndexes.contains(index) {
                let contextualChange: Character = reverse ? "+" : "-"
                let omittedChange: Character = reverse ? "-" : "+"
                if prefix == contextualChange {
                    line = " " + String(line.dropFirst())
                    prefix = " "
                    emittedVerbatim = false
                }
                if prefix == omittedChange {
                    previousLineWasEmittedVerbatim = false
                    continue
                }
            }

            body.append(line)
            previousLineWasEmittedVerbatim = emittedVerbatim
            switch prefix {
            case "-":
                oldCount += 1
            case "+":
                newCount += 1
            default:
                oldCount += 1
                newCount += 1
            }
        }
        guard oldCount > 0 || newCount > 0 else { return nil }

        let hunkHeader = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\(suffix)"
        return (fileHeader + [hunkHeader] + body).joined(separator: "\n") + "\n"
    }
}

// swiftlint:enable unused_declaration
