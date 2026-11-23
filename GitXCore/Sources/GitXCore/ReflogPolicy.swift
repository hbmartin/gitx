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

    /// Display decoding must never change the identity passed back to Git.
    public static func displayText(_ data: Data) -> String {
        let bytes = Array(data)
        var result = ""
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            let count: Int
            switch byte {
            case 0 ... 127: count = 1
            case 194 ... 223: count = 2
            case 224 ... 239: count = 3
            case 240 ... 244: count = 4
            default: count = 0
            }
            if count > 0, index + count <= bytes.count,
               let text = String(bytes: bytes[index ..< index + count], encoding: .utf8)
            {
                result += text
                index += count
            } else {
                result += String(format: "\\x%02X", byte)
                index += 1
            }
        }
        return result
    }

    /// NUL-delimited fields followed by LF; only descriptive fields tolerate invalid UTF-8.
    public static func entries(from data: Data) throws -> [ReflogEntry] {
        if data.isEmpty {
            return []
        }
        let formatter = ISO8601DateFormatter()
        var cursor = data.startIndex
        var result: [ReflogEntry] = []
        while cursor < data.endIndex {
            var fields: [Data] = []
            for _ in 0 ..< 6 {
                guard let end = data[cursor...].firstIndex(of: 0) else { throw ReflogReadError.incompleteOutput }
                fields.append(Data(data[cursor ..< end]))
                cursor = data.index(after: end)
            }
            guard cursor < data.endIndex, data[cursor] == 10 else { throw ReflogReadError.incompleteOutput }
            cursor = data.index(after: cursor)
            guard let objectID = String(data: fields[0], encoding: .utf8), isObjectID(objectID),
                  let marker = fields[1].range(of: Data("@{".utf8), options: .backwards), fields[1].last == 125,
                  let timestamp = String(data: fields[1][marker.upperBound ..< fields[1].index(before: fields[1].endIndex)], encoding: .utf8),
                  let date = formatter.date(from: timestamp) else { throw ReflogReadError.invalidRecord }
            result.append(ReflogEntry(objectID: objectID, selector: displayText(fields[1]), eventDate: date,
                                      action: displayText(fields[2]), actor: displayText(fields[3]),
                                      email: displayText(fields[4]), subject: displayText(fields[5])))
        }
        return result
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
