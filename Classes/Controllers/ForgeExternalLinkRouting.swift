import AppKit
import ForgeKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

extension Notification.Name {
    nonisolated static let forgeTrustedExternalOriginsDidChange = Notification.Name(
        "PBForgeTrustedExternalOriginsDidChangeNotification"
    )
}

/// App-wide persistence for exact trusted HTTPS origins. The stored value is
/// intentionally credential-free and independent of every Forge Account.
// swift6-safety-justification: The private lock serializes every read and mutation of UserDefaults-backed trust.
final nonisolated class ForgeTrustedExternalOriginStore: @unchecked Sendable {
    static let storageKey = "PBForgeTrustedExternalOrigins"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeExternalLinkTrust")

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func origins() -> Set<ForgeTrustedExternalOrigin> {
        lock.withLock { readLocked() }
    }

    func sortedOrigins() -> [ForgeTrustedExternalOrigin] {
        origins().sorted {
            $0.origin.url.absoluteString < $1.origin.url.absoluteString
        }
    }

    @discardableResult
    func add(_ origin: ForgeTrustedExternalOrigin) -> Bool {
        let changed = lock.withLock {
            var values = readLocked()
            guard values.insert(origin).inserted else { return false }
            persistLocked(values)
            return true
        }
        if changed {
            logger.info("Added one exact trusted external HTTPS origin")
            notifyChange()
        }
        return changed
    }

    @discardableResult
    func remove(_ origin: ForgeTrustedExternalOrigin) -> Bool {
        let changed = lock.withLock {
            var values = readLocked()
            guard values.remove(origin) != nil else { return false }
            persistLocked(values)
            return true
        }
        if changed {
            logger.info("Removed one exact trusted external HTTPS origin")
            notifyChange()
        }
        return changed
    }

    @discardableResult
    func removeAll() -> Bool {
        let changed = lock.withLock {
            guard !readLocked().isEmpty || defaults.object(forKey: Self.storageKey) != nil else {
                return false
            }
            defaults.removeObject(forKey: Self.storageKey)
            return true
        }
        if changed {
            logger.info("Cleared all trusted external HTTPS origins")
            notifyChange()
        }
        return changed
    }

    private func readLocked() -> Set<ForgeTrustedExternalOrigin> {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        do {
            return try Set(JSONDecoder().decode([ForgeTrustedExternalOrigin].self, from: data))
        } catch {
            logger.error("Ignored malformed trusted external origin preferences")
            return []
        }
    }

    private func persistLocked(_ origins: Set<ForgeTrustedExternalOrigin>) {
        let values = origins.sorted {
            $0.origin.url.absoluteString < $1.origin.url.absoluteString
        }
        do {
            try defaults.set(JSONEncoder().encode(values), forKey: Self.storageKey)
        } catch {
            logger.error("Could not persist trusted external origin preferences")
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(
            name: .forgeTrustedExternalOriginsDidChange,
            object: self
        )
    }
}

enum ForgeExternalLinkDecision: Equatable {
    case cancel
    case open(alwaysTrustOrigin: Bool)
}

enum ForgeMailLinkDecision: Equatable {
    case cancel
    case open
}

@MainActor
protocol ForgeLinkConfirmationPresenting: AnyObject {
    func confirmExternalLink(
        _ confirmation: ForgeExternalLinkConfirmation,
        completion: @escaping (ForgeExternalLinkDecision) -> Void
    )

    func confirmMailLink(
        _ confirmation: ForgeMailConfirmation,
        completion: @escaping (ForgeMailLinkDecision) -> Void
    )
}

@MainActor
final class AppKitForgeLinkConfirmationPresenter: ForgeLinkConfirmationPresenting {
    typealias AlertPresentation = @MainActor (
        NSAlert,
        NSWindow?,
        @escaping (NSApplication.ModalResponse) -> Void
    ) -> Void

    private let windowProvider: () -> NSWindow?
    private let alertPresentation: AlertPresentation

    init(
        windowProvider: @escaping () -> NSWindow?,
        alertPresentation: @escaping AlertPresentation = AppKitForgeLinkConfirmationPresenter.present
    ) {
        self.windowProvider = windowProvider
        self.alertPresentation = alertPresentation
    }

    func confirmExternalLink(
        _ confirmation: ForgeExternalLinkConfirmation,
        completion: @escaping (ForgeExternalLinkDecision) -> Void
    ) {
        let alert = Self.externalAlert(confirmation)
        alertPresentation(alert, windowProvider()) { response in
            guard response == .alertFirstButtonReturn else {
                completion(.cancel)
                return
            }
            completion(.open(alwaysTrustOrigin: alert.suppressionButton?.state == .on))
        }
    }

    func confirmMailLink(
        _ confirmation: ForgeMailConfirmation,
        completion: @escaping (ForgeMailLinkDecision) -> Void
    ) {
        let alert = Self.mailAlert(confirmation)
        alertPresentation(alert, windowProvider()) { response in
            completion(response == .alertFirstButtonReturn ? .open : .cancel)
        }
    }

    static func externalAlert(_ confirmation: ForgeExternalLinkConfirmation) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open External Link?"
        var lines = [
            "GitX will open this complete URL in your default browser:",
            confirmation.url.absoluteString,
            "",
            "Display host: \(confirmation.displayHost)",
        ]
        if confirmation.asciiHost != confirmation.displayHost {
            lines.append("ASCII host: \(confirmation.asciiHost)")
        }
        lines.append("")
        lines.append(
            "Trust applies only to \(confirmation.origin.origin.url.absoluteString) "
                + "and never to subdomains, parent domains, or alternate ports."
        )
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Open Link")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Always Allow Links to This Host"
        alert.suppressionButton?.setAccessibilityIdentifier("ForgeExternalLinkAlwaysAllow")
        alert.suppressionButton?.setAccessibilityLabel("Always allow links to this exact HTTPS origin")
        return alert
    }

    static func mailAlert(_ confirmation: ForgeMailConfirmation) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open Mail Link?"
        alert.informativeText = [
            "To: \(recipientSummary(confirmation.to))",
            "CC: \(recipientSummary(confirmation.cc))",
            "BCC: \(recipientSummary(confirmation.bcc))",
            "Subject: \(confirmation.subject ?? "None")",
            "Prefilled body: \(confirmation.hasBody ? "Yes" : "No")",
        ].joined(separator: "\n")
        alert.addButton(withTitle: "Open Mail")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    private static func recipientSummary(_ recipients: [String]) -> String {
        recipients.isEmpty ? "None" : recipients.joined(separator: ", ")
    }

    private static func present(
        _ alert: NSAlert,
        for window: NSWindow?,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

@MainActor
protocol ForgeExternalURLOpening: AnyObject {
    func open(_ url: URL)
}

@MainActor
final class WorkspaceForgeExternalURLOpener: ForgeExternalURLOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

enum ForgeNativeDestinationOpenResult: Equatable {
    case opened
    case unavailable
}

@MainActor
protocol ForgeNativeDestinationOpening: AnyObject {
    /// Implementations may consult existing local Git objects but must not
    /// fetch, clone, or mutate local Git state as a routing side effect.
    func open(_ destination: ForgeDestination) -> ForgeNativeDestinationOpenResult
}

/// One routing boundary shared by native read surfaces, sanitized Markdown,
/// and the validated destination values produced by the future deep-link
/// ingress. It never parses an untrusted deep-link URL itself.
@MainActor
final class ForgeCentralDestinationRouter: ForgeMarkdownNavigationRouting, ForgeReadDestinationRouting {
    private let repository: ForgeRepositoryIdentity
    private let trustedOrigins: ForgeTrustedExternalOriginStore
    private let nativeOpener: any ForgeNativeDestinationOpening
    private let externalOpener: any ForgeExternalURLOpening
    private let confirmations: any ForgeLinkConfirmationPresenting
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeCentralRouting")

    init(
        repository: ForgeRepositoryIdentity,
        trustedOrigins: ForgeTrustedExternalOriginStore,
        nativeOpener: any ForgeNativeDestinationOpening,
        externalOpener: any ForgeExternalURLOpening,
        confirmations: any ForgeLinkConfirmationPresenting
    ) {
        self.repository = repository
        self.trustedOrigins = trustedOrigins
        self.nativeOpener = nativeOpener
        self.externalOpener = externalOpener
        self.confirmations = confirmations
    }

    func activateMarkdownLink(_ target: ForgeMarkdownLinkTarget) {
        do {
            let activation = try ForgeMarkdownLinkActivationPolicy.activation(
                for: target,
                boundTo: repository,
                trustedExternalOrigins: trustedOrigins.origins()
            )
            handle(activation, source: "markdown")
        } catch {
            logger.error("Rejected invalid sanitized Markdown link activation")
        }
    }

    func openMarkdownLinkInBrowser(_ url: URL) {
        openValidatedHTTPS(url, source: "markdown-browser-escape")
    }

    func openNative(destination: ForgeDestination) {
        do {
            let activation = try ForgeMarkdownLinkActivationPolicy.activation(
                for: .native(destination),
                boundTo: repository,
                trustedExternalOrigins: trustedOrigins.origins()
            )
            handle(activation, source: "native-surface")
        } catch {
            logger.error("Rejected invalid native Forge destination")
        }
    }

    func openInBrowser(destination: ForgeDestination) {
        do {
            let url = try ForgeDestinationURLCodec.url(for: destination)
            openValidatedHTTPS(url, source: "native-browser-escape")
        } catch {
            logger.error("Rejected invalid Forge browser destination")
        }
    }

    private func handle(_ activation: ForgeMarkdownLinkActivation, source: String) {
        switch activation {
        case .scrollToHeading:
            logger.debug("Ignored heading activation outside the native Markdown view")
        case let .openNative(destination, browserURL):
            logger.info(
                "Routing native Forge destination source=\(source, privacy: .public) kind=\(destination.kind.rawValue, privacy: .public)"
            )
            switch nativeOpener.open(destination) {
            case .opened:
                logger.info("Opened native Forge destination kind=\(destination.kind.rawValue, privacy: .public)")
            case .unavailable:
                logger.info(
                    "Native Forge destination unavailable; routing validated browser fallback kind=\(destination.kind.rawValue, privacy: .public)"
                )
                openValidatedHTTPS(browserURL, source: "native-unavailable")
            }
        case let .openHTTPS(url):
            externalOpener.open(url)
            logger.info("Opened validated HTTPS Forge link source=\(source, privacy: .public)")
        case let .confirmHTTPS(confirmation):
            logger.info("Requesting confirmation for cross-origin HTTPS Forge link")
            confirmations.confirmExternalLink(confirmation) { [weak self] decision in
                guard let self else { return }
                guard case let .open(alwaysTrustOrigin) = decision else {
                    self.logger.info("Cancelled cross-origin HTTPS Forge link")
                    return
                }
                if alwaysTrustOrigin {
                    self.trustedOrigins.add(confirmation.origin)
                }
                self.externalOpener.open(confirmation.url)
                self.logger.info("Opened confirmed cross-origin HTTPS Forge link")
            }
        case let .confirmMail(confirmation):
            logger.info(
                "Requesting mail confirmation to=\(confirmation.to.count, privacy: .public) cc=\(confirmation.cc.count, privacy: .public) bcc=\(confirmation.bcc.count, privacy: .public) body=\(confirmation.hasBody, privacy: .public)"
            )
            confirmations.confirmMailLink(confirmation) { [weak self] decision in
                guard let self else { return }
                guard decision == .open else {
                    self.logger.info("Cancelled mail link")
                    return
                }
                self.externalOpener.open(confirmation.url)
                self.logger.info("Opened confirmed mail link")
            }
        }
    }

    private func openValidatedHTTPS(_ url: URL, source: String) {
        do {
            let link = try ForgeHTTPSLink(url.absoluteString)
            let activation = try ForgeMarkdownLinkActivationPolicy.activation(
                for: .https(link),
                boundTo: repository,
                trustedExternalOrigins: trustedOrigins.origins()
            )
            handle(activation, source: source)
        } catch {
            logger.error("Rejected non-HTTPS or malformed external URL")
        }
    }
}

private nonisolated extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
