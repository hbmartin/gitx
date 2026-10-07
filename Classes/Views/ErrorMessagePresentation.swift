import Foundation

/// Error details are decided independently of the AppKit sheet and its layout.
@objc(PBErrorMessagePresentation)
final nonisolated class ErrorMessagePresentation: NSObject { // swiftlint:disable:this unused_declaration
    @objc(infoTextForError:)
    // swiftlint:disable:next unused_declaration
    static func infoText(for error: NSError) -> String {
        var parts: [String] = []
        append(localizedString(
            for: error,
            key: NSLocalizedFailureReasonErrorKey,
            fallback: error.localizedFailureReason
        ), to: &parts)
        if let recovery = localizedString(
            for: error,
            key: NSLocalizedRecoverySuggestionErrorKey,
            fallback: error.localizedRecoverySuggestion
        ), !recovery.isEmpty {
            parts.append(NSLocalizedString(
                "Maybe you could try the following:",
                comment: "PBGitXMessageSheet - localized recovery suggestion header"
            ) + "\n" + recovery)
        }
        guard let taskError = error.userInfo[NSUnderlyingErrorKey] as? NSError,
              taskError.domain == PBTaskErrorDomain
        else { return parts.joined(separator: "\n\n") }

        parts.append(NSLocalizedString(
            "The underlying task failed:",
            comment: "PBGitXMessageSheet - task failed header"
        ))
        append(taskError.localizedDescription, to: &parts)
        append(localizedString(
            for: taskError,
            key: NSLocalizedFailureReasonErrorKey,
            fallback: taskError.localizedFailureReason
        ), to: &parts)
        if taskError.code == Int(PBTaskErrorCode.nonZeroExitCodeError.rawValue) {
            let status = (taskError.userInfo[PBTaskTerminationStatusKey] as? NSNumber)?.stringValue ?? "?"
            parts.append(String(format: NSLocalizedString(
                "Return code: %@",
                comment: "PBGitXMessageSheet - task return code header"
            ), status))
            if let output = taskError.userInfo[PBTaskTerminationOutputKey] as? String, !output.isEmpty {
                parts.append(NSLocalizedString(
                    "Output:",
                    comment: "PBGitXMessageSheet - task output header"
                ) + "\n" + output)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func localizedString(
        for error: NSError,
        key: String,
        fallback: @autoclosure () -> String?
    ) -> String? {
        guard let value = error.userInfo[key] else { return fallback() }
        return value as? String
    }

    private static func append(_ value: String?, to parts: inout [String]) {
        if let value, !value.isEmpty, !parts.contains(value) {
            parts.append(value)
        }
    }
}
