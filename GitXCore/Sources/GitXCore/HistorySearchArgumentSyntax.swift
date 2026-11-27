import Foundation

public enum HistorySearchArgumentIssue: Error, Equatable, Sendable {
    /// A quote opened with `quote` is never closed.
    case unclosedQuote(Character)
    /// Quotes at `index` (zero-based) produce an empty argument, which Git rejects as a pathspec.
    case emptyArgument(index: Int)
}

/// Shell-like argument syntax for raw and path history searches.
///
/// - Unquoted whitespace separates arguments.
/// - Single quotes preserve everything up to the next single quote.
/// - Double quotes preserve everything up to the next unescaped double quote; inside them only `\"`
///   and `\\` are escapes.
/// - Outside quotes, a backslash escapes whitespace, a quote, or another backslash. Any other
///   backslash is literal, so regular expressions such as `--grep=a\.b` pass through unchanged.
/// - Adjacent quoted and unquoted text forms one argument, as in a shell.
public enum HistorySearchArgumentSyntax {
    public static func arguments(in text: String) -> Result<[String], HistorySearchArgumentIssue> {
        var scanner = Scanner(characters: Array(text))
        return scanner.scan()
    }

    /// Returns `argument` in a form `arguments(in:)` reads back as exactly one argument.
    public static func quoted(_ argument: String) -> String {
        if !argument.isEmpty, !argument.contains(where: needsQuoting) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func joined(_ arguments: [String]) -> String {
        arguments.map(quoted).joined(separator: " ")
    }

    /// A short, unambiguous rendering of parsed arguments for diagnostics and tooltips.
    public static func preview(_ arguments: [String]) -> String {
        arguments.map { "[\($0)]" }.joined(separator: " ")
    }

    public static func summary(for issue: HistorySearchArgumentIssue) -> String {
        switch issue {
        case .unclosedQuote:
            "Unclosed quote"
        case .emptyArgument:
            "Empty argument"
        }
    }

    public static func message(for issue: HistorySearchArgumentIssue) -> String {
        switch issue {
        case let .unclosedQuote(quote):
            "Close the \(quote == "'" ? "single" : "double") quote or escape it with a backslash."
        case let .emptyArgument(index):
            "Argument \(index + 1) is empty. Remove the empty quotes."
        }
    }

    private static func needsQuoting(_ character: Character) -> Bool {
        character.isWhitespace || character == "'" || character == "\"" || character == "\\"
    }

    private struct Scanner {
        let characters: [Character]
        var index = 0
        var arguments: [String] = []
        var current = ""
        var hasArgument = false

        init(characters: [Character]) {
            self.characters = characters
        }

        mutating func scan() -> Result<[String], HistorySearchArgumentIssue> {
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character.isWhitespace {
                    finishArgument()
                } else if character == "'" || character == "\"" {
                    hasArgument = true
                    guard readQuoted(until: character) else { return .failure(.unclosedQuote(character)) }
                } else if character == "\\" {
                    hasArgument = true
                    let escaped = readEscape(escapable: { $0.isWhitespace || Self.isQuoteOrBackslash($0) })
                    current.append(escaped)
                } else {
                    hasArgument = true
                    current.append(character)
                }
            }
            finishArgument()
            if let empty = arguments.firstIndex(where: \.isEmpty) {
                return .failure(.emptyArgument(index: empty))
            }
            return .success(arguments)
        }

        private mutating func readQuoted(until quote: Character) -> Bool {
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == quote {
                    return true
                }
                if quote == "\"", character == "\\" {
                    let escaped = readEscape(escapable: { $0 == "\"" || $0 == "\\" })
                    current.append(escaped)
                } else {
                    current.append(character)
                }
            }
            return false
        }

        /// Consumes the character after a backslash when it is escapable; otherwise the backslash is literal.
        private mutating func readEscape(escapable: (Character) -> Bool) -> String {
            guard index < characters.count, escapable(characters[index]) else { return "\\" }
            let escaped = characters[index]
            index += 1
            return String(escaped)
        }

        private static func isQuoteOrBackslash(_ character: Character) -> Bool {
            character == "'" || character == "\"" || character == "\\"
        }

        private mutating func finishArgument() {
            guard hasArgument else { return }
            arguments.append(current)
            current = ""
            hasArgument = false
        }
    }
}
