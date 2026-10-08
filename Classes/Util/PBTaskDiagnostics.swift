import Foundation

/// Presentation only. Execution arguments and captured process streams stay raw.
@objc(PBTaskDiagnostics)
final nonisolated class PBTaskDiagnostics: NSObject {
    @objc(redacted:)
    static func redacted(_ text: Any?) -> String {
        let value = text.map { String(describing: $0) } ?? "(null)"
        return PBTaskDiagnosticRedactor.redacted(value)
    }

    @objc(displayArguments:)
    static func displayArguments(_ arguments: [Any]) -> String { // swiftlint:disable:this unused_declaration
        arguments.map { redacted($0) }.joined(separator: " ")
    }

    static func pushFailure(stdout: String, stderr: String, porcelain: Bool,
                            stdoutComplete: Bool = true, stderrComplete: Bool = true) -> String
    {
        let safeStandardOutput = PBTaskDiagnosticRedactor.redacted(stdout, incomplete: !stdoutComplete)
        let output: String
        if porcelain {
            output = safeStandardOutput.components(separatedBy: "\n").compactMap { line -> String? in
                guard !line.isEmpty, line != "Done" else { return nil }
                let fields = line.components(separatedBy: "\t")
                guard fields.count == 3 else { return line }
                return "\(fields[1].replacingOccurrences(of: ":", with: " → ")): \(fields[2])"
            }.joined(separator: "\n")
        } else {
            output = safeStandardOutput
        }
        return [output,
                PBTaskDiagnosticRedactor.redacted(stderr, incomplete: !stderrComplete)]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
