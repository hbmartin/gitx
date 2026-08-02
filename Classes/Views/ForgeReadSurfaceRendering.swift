import AppKit
import ForgeKit

@MainActor
enum ForgeReadDateFormatting {
    private static let mediumDateAndShortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    static func dateAndTime(_ date: Date) -> String {
        mediumDateAndShortTime.string(from: date)
    }

    static func date(_ date: Date) -> String {
        shortDate.string(from: date)
    }
}

@MainActor
final class ForgeReadNativeMarkdownRenderer: ForgeReadMarkdownRendering {
    private weak var router: (any ForgeMarkdownNavigationRouting)?

    init(router: any ForgeMarkdownNavigationRouting) {
        self.router = router
    }

    func makeView(markdown: String, context: ForgeMarkdownContext) -> NSView {
        let document = ForgeMarkdownSanitizer().sanitize(markdown, context: context)
        return ForgeMarkdownNativeView(document: document, navigationRouter: router)
    }
}

@MainActor
final class ForgeReadNativeAvatarRenderer: ForgeReadAvatarRendering {
    private let owner: ForgeAvatarCacheOwner

    init(owner: ForgeAvatarCacheOwner) {
        self.owner = owner
    }

    func makeAvatarView(for actor: ForgeActor, size: NSSize) -> NSView {
        let view = ForgeAvatarView(
            frame: NSRect(origin: .zero, size: size),
            owner: owner
        )
        view.configure(displayName: actor.displayName ?? actor.login, avatarURL: actor.avatarURL)
        return view
    }
}
