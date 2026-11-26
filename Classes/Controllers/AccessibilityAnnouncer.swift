import AppKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

/// Posts VoiceOver announcements for state changes that have no focused control of their own.
@objc(GitXAccessibilityAnnouncer)
final class AccessibilityAnnouncer: NSObject {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "Accessibility")

    /// Delivers an announcement. Tests replace it to observe announcements without VoiceOver.
    @objc static var post: (_ message: String, _ element: Any) -> Void = { message, element in
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// Announces `message` from `element`, or from the application when `element` is nil.
    @objc(announce:from:)
    static func announce(_ message: String, from element: Any?) {
        guard !message.isEmpty else { return }
        logger.info("Accessibility announcement: \(message, privacy: .public)")
        post(message, element ?? NSApp as Any)
    }
}
