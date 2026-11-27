import Foundation

// MARK: - Pointers

/// A Git LFS pointer: the small text file Git stores in place of an LFS object.
///
/// Parsing follows version 1 of the pointer specification strictly. Real content that only resembles a pointer
/// would otherwise be hidden behind a placeholder, so anything unusual is treated as ordinary content.
public struct LFSPointer: Equatable, Hashable, Sendable {
    /// Pointer files are smaller than this many bytes.
    public static let maximumSize = 1024
    public static let specification = "https://git-lfs.github.com/spec/v1"
    /// The pre-release name of the specification, still found in old repositories.
    public static let legacySpecification = "https://hawser.github.com/spec/v1"

    /// The object's SHA-256 digest, as 64 lowercase hexadecimal digits.
    public let oid: String
    /// The object's size in bytes.
    public let size: Int64

    public init?(oid: String, size: Int64) {
        guard Self.isDigest(oid), size >= 0 else { return nil }
        self.oid = oid
        self.size = size
    }

    /// The pointer for data, or nil when the data is not exactly a version 1 pointer.
    public static func parse(_ data: Data) -> LFSPointer? {
        guard !data.isEmpty, data.count < maximumSize, data.last == 0x0A,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeLast()
        guard let version = lines.first,
              version == "version \(specification)" || version == "version \(legacySpecification)"
        else { return nil }
        var values: [Substring: Substring] = [:]
        var previousKey: Substring?
        for line in lines.dropFirst() {
            guard let space = line.firstIndex(of: " ") else { return nil }
            let key = line[..<space]
            let value = line[line.index(after: space)...]
            guard isKey(key), !value.isEmpty, previousKey.map({ $0 < key }) ?? true else { return nil }
            values[key] = value
            previousKey = key
        }
        guard let oidValue = values["oid"], oidValue.hasPrefix("sha256:"),
              let sizeValue = values["size"], isDecimal(sizeValue), let size = Int64(sizeValue)
        else { return nil }
        return LFSPointer(oid: String(oidValue.dropFirst("sha256:".count)), size: size)
    }

    /// The canonical pointer text for this object.
    public var text: String {
        "version \(Self.specification)\noid sha256:\(oid)\nsize \(size)\n"
    }

    /// The first eight digits of the digest, enough to tell objects apart in a sentence.
    public var abbreviatedOID: String {
        String(oid.prefix(8))
    }

    static func isDigest(_ value: some StringProtocol) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    private static func isKey(_ key: Substring) -> Bool {
        !key.isEmpty && key.utf8.allSatisfy { byte in
            (97 ... 122).contains(byte) || (48 ... 57).contains(byte) || byte == 0x2E || byte == 0x2D
        }
    }

    private static func isDecimal(_ value: Substring) -> Bool {
        value.utf8.count <= 19 && value.utf8.allSatisfy { (48 ... 57).contains($0) }
    }
}

// MARK: - Tool

/// Whether the installed git-lfs can serve GitX.
public enum LFSToolStatus: Equatable, Sendable {
    /// `git lfs` is not a Git command on this Mac.
    case missing
    /// git-lfs answered, but with output GitX does not recognize.
    case unrecognized
    /// git-lfs is older than ``LFSToolPolicy/minimumMajorVersion``.
    case unsupported(version: String)
    case available(version: String)

    public var isAvailable: Bool {
        if case .available = self {
            true
        } else {
            false
        }
    }
}

public enum LFSToolPolicy {
    /// Checkout of individual paths and the progress format GitX reads are stable from git-lfs 3.0.
    public static let minimumMajorVersion = 3

    /// Classifies the result of `git lfs version`, such as `git-lfs/3.4.1 (GitHub; darwin arm64; go 1.21.5)`.
    public static func status(terminationStatus: Int32, output: String) -> LFSToolStatus {
        guard terminationStatus == 0 else { return .missing }
        let firstLine = output.split(whereSeparator: \.isNewline).first ?? ""
        guard firstLine.hasPrefix("git-lfs/") else { return .unrecognized }
        let version = String(firstLine.dropFirst("git-lfs/".count).prefix { !$0.isWhitespace })
        let majorDigits = version.prefix { $0.isASCII && $0.isNumber }
        guard let major = Int(majorDigits), version.dropFirst(majorDigits.count).first == "." else {
            return .unrecognized
        }
        return major >= minimumMajorVersion ? .available(version: version) : .unsupported(version: version)
    }
}

// MARK: - Worktree

/// What a checkout holds for one LFS-tracked path.
public enum LFSFileState: String, Equatable, Sendable {
    /// The worktree holds the pointer text instead of the object.
    case notDownloaded
    /// The worktree holds a file of the object's size.
    case downloaded
    /// The worktree file differs from both the pointer and the object.
    case modified
    /// The worktree has no file at the path.
    case missing
}

/// One LFS-tracked index entry and what the worktree holds at its path.
public struct LFSWorktreeObservation: Equatable, Sendable {
    public enum Worktree: Equatable, Sendable {
        case missing
        /// A file, and the pointer it holds when it is small enough to be one.
        case file(size: Int64, pointer: LFSPointer?)
    }

    public let path: String
    /// The pointer stored in the index, or nil when the index holds ordinary content for a tracked path.
    public let pointer: LFSPointer?
    public let worktree: Worktree

    public init(path: String, pointer: LFSPointer?, worktree: Worktree) {
        self.path = path
        self.pointer = pointer
        self.worktree = worktree
    }
}

/// How many LFS objects a checkout has not downloaded.
public struct LFSWorktreeSummary: Equatable, Sendable {
    /// Index entries that store an LFS pointer.
    public let pointerCount: Int
    public let notDownloadedPaths: [String]
    public let notDownloadedBytes: Int64
    /// True when the scan stopped at ``LFSWorktreeClassifier/scanLimit``, so the counts are lower bounds.
    public let isTruncated: Bool

    public init(pointerCount: Int, notDownloadedPaths: [String], notDownloadedBytes: Int64, isTruncated: Bool) {
        self.pointerCount = pointerCount
        self.notDownloadedPaths = notDownloadedPaths
        self.notDownloadedBytes = notDownloadedBytes
        self.isTruncated = isTruncated
    }

    public static let empty = LFSWorktreeSummary(
        pointerCount: 0,
        notDownloadedPaths: [],
        notDownloadedBytes: 0,
        isTruncated: false
    )
}

public enum LFSWorktreeClassifier {
    /// The most tracked paths one status scan inspects.
    public static let scanLimit = 10000

    /// Nil when the index holds ordinary content, so the path is not an LFS object at all.
    public static func state(of observation: LFSWorktreeObservation) -> LFSFileState? {
        guard let pointer = observation.pointer else { return nil }
        switch observation.worktree {
        case .missing:
            return .missing
        case let .file(_, worktreePointer?):
            return worktreePointer == pointer ? .notDownloaded : .modified
        case let .file(size, nil):
            return size == pointer.size ? .downloaded : .modified
        }
    }

    public static func summary(of observations: [LFSWorktreeObservation], isTruncated: Bool) -> LFSWorktreeSummary {
        var pointerCount = 0
        var paths: [String] = []
        var bytes: Int64 = 0
        for observation in observations {
            guard let state = state(of: observation), let pointer = observation.pointer else { continue }
            pointerCount += 1
            if state == .notDownloaded {
                paths.append(observation.path)
                bytes = bytes.addingReportingOverflow(pointer.size).overflow ? .max : bytes + pointer.size
            }
        }
        return LFSWorktreeSummary(
            pointerCount: pointerCount,
            notDownloadedPaths: paths,
            notDownloadedBytes: bytes,
            isTruncated: isTruncated
        )
    }
}

// MARK: - Local store

/// Where git-lfs keeps downloaded objects, and whether a stored object can stand in for its pointer.
public enum LFSObjectStore {
    /// The largest object GitX hashes to show its content in place of the pointer.
    public static let previewByteLimit: Int64 = 64 * 1024 * 1024

    /// The `lfs.storage` directory, which is relative to the Git common directory unless absolute.
    public static func storageDirectory(commonDirectory: String, configuredStorage: String?) -> String {
        let configured = configuredStorage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if configured.isEmpty {
            return (commonDirectory as NSString).appendingPathComponent("lfs")
        }
        if configured.hasPrefix("/") {
            return configured
        }
        return (commonDirectory as NSString).appendingPathComponent(configured)
    }

    /// `objects/aa/bb/aabb…` beneath the storage directory.
    public static func objectPath(for pointer: LFSPointer, storageDirectory: String) -> String {
        let oid = pointer.oid
        return [String(oid.prefix(2)), String(oid.dropFirst(2).prefix(2)), oid].reduce(
            (storageDirectory as NSString).appendingPathComponent("objects")
        ) { ($0 as NSString).appendingPathComponent($1) }
    }

    public enum Decision: Equatable, Sendable {
        /// Not in the local store; show the not-downloaded placeholder.
        case missing
        /// Present and of the right size; hash it, then show it if the digest matches.
        case verify
        /// Present, but larger than ``LFSObjectStore/previewByteLimit``.
        case tooLargeToPreview
        /// Present with the wrong size, as an interrupted download leaves it.
        case incomplete
    }

    public static func decision(for pointer: LFSPointer, storedSize: Int64?) -> Decision {
        guard let storedSize else { return .missing }
        guard storedSize == pointer.size else { return .incomplete }
        return storedSize > previewByteLimit ? .tooLargeToPreview : .verify
    }
}

// MARK: - Downloads

/// What the user asked to download.
public enum LFSDownloadScope: Equatable, Sendable {
    case paths([String])
    /// Every LFS object the current revision needs.
    case all
}

public enum LFSDownloadPlanIssue: Error, Equatable, Sendable {
    case noPaths
    /// git-lfs cannot name this path on its own; Download All still can.
    case inexpressiblePath(String)
    case tooManyPaths(count: Int)

    public var message: String {
        switch self {
        case .noPaths:
            "Choose a file whose Git LFS content is not downloaded."
        case let .inexpressiblePath(path):
            "Git LFS cannot download “\(path)” on its own because of the characters in its name. "
                + "Use Download All instead."
        case let .tooManyPaths(count):
            "\(count) files are too many to download one by one. Use Download All instead."
        }
    }
}

/// The two git-lfs commands that download objects and then write them into the checkout.
public struct LFSDownloadPlan: Equatable, Sendable {
    public static let maximumPathCount = 500
    public static let maximumPatternBytes = 64 * 1024

    /// `git lfs fetch`, which only reads the remote and writes the local store, so it can be cancelled.
    public let fetchArguments: [String]
    /// `git lfs checkout`, which rewrites worktree files and the index, so it runs to completion.
    public let checkoutArguments: [String]
    public let paths: [String]?

    public static func make(_ scope: LFSDownloadScope) -> Result<LFSDownloadPlan, LFSDownloadPlanIssue> {
        guard case let .paths(requested) = scope else {
            return .success(LFSDownloadPlan(fetchArguments: ["lfs", "fetch"], checkoutArguments: ["lfs", "checkout"], paths: nil))
        }
        var seen = Set<String>()
        let paths = requested.filter { seen.insert($0).inserted }
        guard !paths.isEmpty else { return .failure(.noPaths) }
        guard paths.count <= maximumPathCount else { return .failure(.tooManyPaths(count: paths.count)) }
        var patterns: [String] = []
        for path in paths {
            guard let pattern = pattern(for: path) else { return .failure(.inexpressiblePath(path)) }
            patterns.append(pattern)
        }
        let include = patterns.joined(separator: ",")
        guard include.utf8.count <= maximumPatternBytes else { return .failure(.tooManyPaths(count: paths.count)) }
        return .success(LFSDownloadPlan(
            fetchArguments: ["lfs", "fetch", "--include=\(include)"],
            checkoutArguments: ["lfs", "checkout", "--"] + patterns,
            paths: paths
        ))
    }

    /// A pattern matching exactly one repository-relative path: anchored with `/`, with wildcard characters escaped.
    /// Nil when git-lfs cannot express the path: it splits `--include` at commas and trims surrounding whitespace.
    public static func pattern(for path: String) -> String? {
        let forbidden: Set<Character> = [",", "\n", "\r", "\0"]
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(where: forbidden.contains),
              path.last?.isWhitespace == false
        else { return nil }
        var pattern = "/"
        for character in path {
            if "\\*?[]".contains(character) {
                pattern.append("\\")
            }
            pattern.append(character)
        }
        return pattern
    }
}

/// Which selected paths a Download LFS Content command acts on.
public enum LFSDownloadEligibility {
    /// The files not downloaded that the selection names, directly or as a folder holding them, in status order.
    /// Empty when git-lfs cannot download.
    public static func paths(_ selected: [String], summary: LFSWorktreeSummary, tool: LFSToolStatus) -> [String] {
        guard tool.isAvailable else { return [] }
        let exact = Set(selected)
        let folders = selected.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        return summary.notDownloadedPaths.filter { path in
            exact.contains(path) || folders.contains { path.hasPrefix($0) }
        }
    }

    /// Whether to offer Download LFS Content at all: only in a checkout with LFS pointers.
    public static func isOffered(summary: LFSWorktreeSummary) -> Bool {
        summary.pointerCount > 0
    }
}

/// One line of the file git-lfs writes progress to when `GIT_LFS_PROGRESS` names it.
public struct LFSProgressEvent: Equatable, Sendable {
    public let direction: String
    public let completedFiles: Int
    public let totalFiles: Int
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let name: String

    /// Parses `<direction> <file>/<files> <bytes>/<total bytes> <name>`.
    public static func parse(line: String) -> LFSProgressEvent? {
        let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4, !fields[0].isEmpty,
              let files = pair(fields[1], { Int($0) }), let bytes = pair(fields[2], { Int64($0) })
        else { return nil }
        return LFSProgressEvent(
            direction: String(fields[0]),
            completedFiles: files.0,
            totalFiles: files.1,
            completedBytes: bytes.0,
            totalBytes: bytes.1,
            name: String(fields[3])
        )
    }

    /// The events in the complete lines of text, and the incomplete line left over.
    public static func events(in text: String) -> (events: [LFSProgressEvent], remainder: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let remainder = String(lines.removeLast())
        return (lines.compactMap { parse(line: String($0)) }, remainder)
    }

    /// Progress through the bytes, or through the files when git-lfs did not know the size.
    public var fractionCompleted: Double {
        if totalBytes > 0 {
            return min(1, Double(completedBytes) / Double(totalBytes))
        }
        return totalFiles > 0 ? min(1, Double(completedFiles) / Double(totalFiles)) : 0
    }

    private static func pair<Value: SignedInteger>(
        _ field: Substring,
        _ make: (Substring) -> Value?
    ) -> (Value, Value)? {
        let parts = field.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let done = make(parts[0]), let total = make(parts[1]), done >= 0, total >= 0 else {
            return nil
        }
        return (done, total)
    }
}

// MARK: - Presentation

public enum LFSPresentation {
    /// Shown in place of content whose LFS object has not been downloaded.
    public static func placeholder(for pointer: LFSPointer) -> String {
        "Git LFS object not downloaded — \(byteCount(pointer.size)) (sha256 \(pointer.abbreviatedOID)…)"
    }

    /// Shown in place of a downloaded object too large to preview.
    public static func tooLargePlaceholder(for pointer: LFSPointer) -> String {
        "Git LFS object too large to preview — \(byteCount(pointer.size)) (sha256 \(pointer.abbreviatedOID)…)"
    }

    /// Why Flow skips a file whose LFS object has not been downloaded.
    public static let flowSkipReason = "Git LFS object not downloaded"

    /// The status bar's LFS label, or nil when the repository needs no attention.
    public static func statusText(summary: LFSWorktreeSummary, tool: LFSToolStatus) -> String? {
        guard summary.pointerCount > 0 else { return nil }
        switch tool {
        case .missing:
            return "Uses Git LFS, but git-lfs is not installed"
        case let .unsupported(version):
            return "Git LFS \(version) is too old; Half Dark needs \(LFSToolPolicy.minimumMajorVersion).0 or later"
        case .unrecognized:
            return "Uses Git LFS, but git-lfs did not report its version"
        case .available:
            let count = summary.notDownloadedPaths.count
            guard count > 0 else { return nil }
            let more = summary.isTruncated ? "+" : ""
            let files = count == 1 && !summary.isTruncated ? "1 file" : "\(count)\(more) files"
            return "LFS: \(files) not downloaded (\(byteCount(summary.notDownloadedBytes))\(more))"
        }
    }

    /// The Details sheet's explanation of the status label.
    public static func detailsText(summary: LFSWorktreeSummary, tool: LFSToolStatus) -> String {
        switch tool {
        case .missing:
            return "This repository stores files with Git LFS, but git-lfs is not installed. Install git-lfs "
                + "\(LFSToolPolicy.minimumMajorVersion).0 or later, for example with “brew install git-lfs”, then refresh."
        case let .unsupported(version):
            return "Half Dark needs git-lfs \(LFSToolPolicy.minimumMajorVersion).0 or later to download Git LFS content, "
                + "and this Mac has \(version). Update git-lfs, then refresh."
        case .unrecognized:
            return "git-lfs did not report a version Half Dark recognizes. Check its installation, then refresh."
        case .available:
            let count = summary.notDownloadedPaths.count
            guard count > 0 else { return "Every Git LFS file in this checkout is downloaded." }
            let more = summary.isTruncated ? " or more" : ""
            let files = count == 1 && !summary.isTruncated ? "1 file holds a Git LFS pointer" : "\(count)\(more) files hold Git LFS pointers"
            return "\(files) instead of \(count == 1 && !summary.isTruncated ? "its" : "their") content "
                + "(\(byteCount(summary.notDownloadedBytes))\(more)). Half Dark shows a placeholder until the content is downloaded."
        }
    }

    /// A decimal byte count in the manner of the Finder: "512 bytes", "4 KB", "12.4 MB".
    public static func byteCount(_ bytes: Int64) -> String {
        switch bytes {
        case ..<1: return "Zero bytes"
        case 1: return "1 byte"
        case ..<1000: return "\(bytes) bytes"
        case ..<999_500: return "\(Int((Double(bytes) / 1000).rounded())) KB"
        default:
            let units = ["MB", "GB", "TB", "PB", "EB"]
            var value = Double(bytes) / 1_000_000
            var unit = 0
            while value >= 999.95, unit < units.count - 1 {
                value /= 1000
                unit += 1
            }
            return "\(String(format: "%.1f", value)) \(units[unit])"
        }
    }
}
