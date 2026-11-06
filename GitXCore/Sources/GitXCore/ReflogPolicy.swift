import Foundation

/// A captured reflog event. Recovery always uses objectID, never the moving selector.
public struct ReflogEntry: Equatable, Sendable {
    public let objectID: String
    public let selector: String
    public let eventDate: Date
    public let action: String
    public let actor: String
    public let email: String
    public let subject: String
}

public enum ReflogReadError: Error, Equatable, LocalizedError {
    case incompleteOutput
    case invalidRecord

    public var errorDescription: String? {
        switch self {
        case .incompleteOutput: "Git returned an incomplete reflog. Refresh before recovering a commit."
        case .invalidRecord: "Git returned a reflog event that could not be identified safely."
        }
    }
}

public enum ReflogParser {
    public static func isObjectID(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    /// Input is `--date=iso-strict --format=%H%x00%gD%x00%gs%x00%gn%x00%ge%x00%s%x00`.
    public static func entries(from data: Data) throws -> [ReflogEntry] {
        if data.isEmpty {
            return []
        }
        guard let output = String(data: data, encoding: .utf8), output.hasSuffix("\0\n") else {
            throw ReflogReadError.incompleteOutput
        }
        let formatter = ISO8601DateFormatter()
        return try output.dropLast(2).components(separatedBy: "\0\n").map { row in
            let fields = row.components(separatedBy: "\0")
            guard fields.count == 6, isObjectID(fields[0]),
                  let start = fields[1].range(of: "@{", options: .backwards), fields[1].hasSuffix("}"),
                  let date = formatter.date(from: String(fields[1][start.upperBound...].dropLast()))
            else { throw ReflogReadError.invalidRecord }
            return ReflogEntry(objectID: fields[0], selector: fields[1], eventDate: date,
                               action: fields[2], actor: fields[3], email: fields[4], subject: fields[5])
        }
    }
}

public enum ReflogResetMode: String, CaseIterable, Sendable {
    case soft, mixed, hard

    public var explanation: String {
        switch self {
        case .soft: "Move HEAD; leave the index and working files unchanged."
        case .mixed: "Move HEAD and replace the index; leave working files unchanged and changes unstaged."
        case .hard: "Move HEAD and replace the index and working files; discard local changes and obstructing files."
        }
    }

    public var requiresDiscardConfirmation: Bool {
        self == .hard
    }
}

public enum ReflogRecoveryPolicy {
    public static func blocker(isBare: Bool, operationInProgress: Bool, hasHead: Bool,
                               targetAvailable: Bool, previewComplete: Bool) -> String?
    {
        if isBare {
            return "Reset requires a working checkout. Create a recovery branch instead."
        }
        if operationInProgress {
            return "Finish or abort the current Git operation before resetting."
        }
        if !hasHead {
            return "The checkout has no commit to preserve before reset."
        }
        if !targetAvailable {
            return "The selected commit is no longer available locally."
        }
        if !previewComplete {
            return "The affected files could not be inspected completely. Reset is unavailable."
        }
        return nil
    }
}
