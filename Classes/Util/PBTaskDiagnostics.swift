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
        return formattedPushFailure(stdout: safeStandardOutput,
                                    stderr: PBTaskDiagnosticRedactor.redacted(stderr, incomplete: !stderrComplete),
                                    porcelain: porcelain)
    }

    static func formattedPushFailure(stdout: String, stderr: String, porcelain: Bool) -> String {
        let output: String
        if porcelain {
            output = stdout.components(separatedBy: "\n").compactMap { line -> String? in
                guard !line.isEmpty, line != "Done" else { return nil }
                let fields = line.components(separatedBy: "\t")
                guard fields.count == 3 else { return line }
                return "\(fields[1].replacingOccurrences(of: ":", with: " → ")): \(fields[2])"
            }.joined(separator: "\n")
        } else {
            output = stdout
        }
        return [output, stderr]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Deadline decisions are separate from Objective-C process and exception handling.
@objc(PBTaskDrainPolicy)
final nonisolated class PBTaskDrainPolicy: NSObject {
    @objc(deadlineWithLeaderExit:lastProgress:taskDeadline:)
    static func deadline(leaderExit: TimeInterval, lastProgress: TimeInterval, taskDeadline: TimeInterval) -> TimeInterval {
        min(max(leaderExit, lastProgress) + 1, leaderExit + 10,
            taskDeadline > 0 ? taskDeadline : .infinity)
    }
}
