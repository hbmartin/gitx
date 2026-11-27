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
///
/// The syntax is read as Unicode scalars: Swift groups a delimiter with a following combining mark into
/// one `Character`, which would otherwise hide quotes and whitespace in front of combining marks.
public enum HistorySearchArgumentSyntax {
    public static func arguments(in text: String) -> Result<[String], HistorySearchArgumentIssue> {
        var scanner = Scanner(scalars: Array(text.unicodeScalars))
        return scanner.scan()
    }

    /// Returns `argument` in a form `arguments(in:)` reads back as exactly one argument.
    public static func quoted(_ argument: String) -> String {
        if !argument.isEmpty, !argument.unicodeScalars.contains(where: needsQuoting) {
            return argument
        }
        var quoted = String.UnicodeScalarView()
        quoted.append("'")
        for scalar in argument.unicodeScalars {
            if scalar == "'" {
                quoted.append(contentsOf: "'\\''".unicodeScalars)
            } else {
                quoted.append(scalar)
            }
        }
        quoted.append("'")
        return String(quoted)
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

    private static func needsQuoting(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || isQuoteOrBackslash(scalar)
    }

    private static func isQuoteOrBackslash(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "'" || scalar == "\"" || scalar == "\\"
    }

    private struct Scanner {
        let scalars: [Unicode.Scalar]
        var index = 0
        var arguments: [String] = []
        var current = String.UnicodeScalarView()
        var hasArgument = false

        init(scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        mutating func scan() -> Result<[String], HistorySearchArgumentIssue> {
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                if scalar.properties.isWhitespace {
                    finishArgument()
                } else if scalar == "'" || scalar == "\"" {
                    hasArgument = true
                    guard readQuoted(until: scalar) else { return .failure(.unclosedQuote(Character(scalar))) }
                } else if scalar == "\\" {
                    hasArgument = true
                    readEscape(escapable: { $0.properties.isWhitespace || HistorySearchArgumentSyntax.isQuoteOrBackslash($0) })
                } else {
                    hasArgument = true
                    current.append(scalar)
                }
            }
            finishArgument()
            if let empty = arguments.firstIndex(where: \.isEmpty) {
                return .failure(.emptyArgument(index: empty))
            }
            return .success(arguments)
        }

        private mutating func readQuoted(until quote: Unicode.Scalar) -> Bool {
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                if scalar == quote {
                    return true
                }
                if quote == "\"", scalar == "\\" {
                    readEscape(escapable: { $0 == "\"" || $0 == "\\" })
                } else {
                    current.append(scalar)
                }
            }
            return false
        }

        /// Appends the scalar after a backslash when it is escapable; otherwise the backslash is literal.
        private mutating func readEscape(escapable: (Unicode.Scalar) -> Bool) {
            guard index < scalars.count, escapable(scalars[index]) else {
                current.append("\\")
                return
            }
            current.append(scalars[index])
            index += 1
        }

        private mutating func finishArgument() {
            guard hasArgument else { return }
            arguments.append(String(current))
            current = String.UnicodeScalarView()
            hasArgument = false
        }
    }
}
