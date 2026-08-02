import AppKit
import ForgeKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

@MainActor
protocol RepositoryForgeLinkRouting: AnyObject {
    var providerName: String? { get }

    func resolve(_ request: RepositoryForgeDestinationRequest) -> RepositoryForgeDestinationResolution
    func resolveNumberReference(_ reference: String) -> RepositoryForgeNumberResolution
    func select(candidate: RepositoryForgeBindingCandidate) throws
    func route(_ destination: ForgeDestination) throws -> ForgeDestinationRoute
}

@MainActor
final class RepositoryForgeLinkCoordinatorRouting: RepositoryForgeLinkRouting {
    private let coordinator: RepositoryForgeCoordinator

    init(coordinator: RepositoryForgeCoordinator) {
        self.coordinator = coordinator
    }

    var providerName: String? {
        coordinator.resolveBinding().providerName
    }

    func resolve(_ request: RepositoryForgeDestinationRequest) -> RepositoryForgeDestinationResolution {
        coordinator.resolve(request)
    }

    func resolveNumberReference(_ reference: String) -> RepositoryForgeNumberResolution {
        coordinator.resolveNumberReference(reference)
    }

    func select(candidate: RepositoryForgeBindingCandidate) throws {
        _ = try coordinator.select(candidate: candidate)
    }

    func route(_ destination: ForgeDestination) throws -> ForgeDestinationRoute {
        try ForgeDestinationRouter().route(destination)
    }
}

@MainActor
protocol RepositoryForgeLinkURLOpening: AnyObject {
    func open(_ url: URL)
}

@MainActor
final class WorkspaceRepositoryForgeLinkOpener: RepositoryForgeLinkURLOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
protocol RepositoryForgeLinkAlertPresenting: AnyObject {
    func requestNumberReference(completion: @escaping (String?) -> Void)
    func chooseBinding(
        from candidates: [RepositoryForgeBindingCandidate],
        completion: @escaping (RepositoryForgeBindingCandidate?) -> Void
    )
    func chooseDestination(
        from choices: [ForgeDestinationChoice],
        completion: @escaping (ForgeDestinationChoice?) -> Void
    )
    func show(error: Error)
}

@MainActor
final class AppKitRepositoryForgeLinkAlertPresenter: NSObject, RepositoryForgeLinkAlertPresenting {
    typealias AlertPresentation = @MainActor (
        NSAlert,
        NSWindow?,
        @escaping (NSApplication.ModalResponse) -> Void
    ) -> Void

    private let windowProvider: () -> NSWindow?
    private let alertPresentation: AlertPresentation
    private let errorPresentation: (Error) -> Void

    init(
        windowProvider: @escaping () -> NSWindow?,
        alertPresentation: @escaping AlertPresentation = AppKitRepositoryForgeLinkAlertPresenter.present,
        errorPresentation: @escaping (Error) -> Void
    ) {
        self.windowProvider = windowProvider
        self.alertPresentation = alertPresentation
        self.errorPresentation = errorPresentation
        super.init()
    }

    func requestNumberReference(completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Open Pull Request or Issue"
        alert.informativeText = "Enter a provider reference such as #123. GitX will ask which kind to open."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "#123"
        field.setAccessibilityIdentifier("GitX.ForgeLinks.NumberedReference")
        field.setAccessibilityLabel("Pull Request or Issue reference")
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alertPresentation(alert, windowProvider()) { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            completion(field.stringValue)
        }
    }

    func chooseBinding(
        from candidates: [RepositoryForgeBindingCandidate],
        completion: @escaping (RepositoryForgeBindingCandidate?) -> Void
    ) {
        guard !candidates.isEmpty else {
            completion(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Choose Primary Repository"
        alert.informativeText = "Choose the remote GitX should use for browser links in this repository."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        popup.addItems(withTitles: candidates.map {
            "\($0.providerName) — \($0.repositoryLabel) (\($0.localRemoteName))"
        })
        popup.setAccessibilityIdentifier("GitX.ForgeLinks.RepositoryChoice")
        popup.setAccessibilityLabel("Primary repository")
        alert.accessoryView = popup
        alert.addButton(withTitle: "Use Repository")
        alert.addButton(withTitle: "Cancel")
        alertPresentation(alert, windowProvider()) { response in
            let index = popup.indexOfSelectedItem
            guard response == .alertFirstButtonReturn, candidates.indices.contains(index) else {
                completion(nil)
                return
            }
            completion(candidates[index])
        }
    }

    func chooseDestination(
        from choices: [ForgeDestinationChoice],
        completion: @escaping (ForgeDestinationChoice?) -> Void
    ) {
        guard !choices.isEmpty else {
            completion(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Choose a Destination"
        alert.informativeText = "This number can identify either a Pull Request or an Issue."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        popup.addItems(withTitles: choices.map(\.title))
        popup.setAccessibilityIdentifier("GitX.ForgeLinks.DestinationChoice")
        popup.setAccessibilityLabel("Pull Request or Issue destination")
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alertPresentation(alert, windowProvider()) { response in
            let index = popup.indexOfSelectedItem
            guard response == .alertFirstButtonReturn, choices.indices.contains(index) else {
                completion(nil)
                return
            }
            completion(choices[index])
        }
    }

    func show(error: Error) {
        errorPresentation(error)
    }

    static func present(
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

/// Resolves and presents Forge browser-link actions without owning responder-chain wiring.
@MainActor
final class RepositoryForgeLinkUseCase {
    private let routing: RepositoryForgeLinkRouting
    private let opener: RepositoryForgeLinkURLOpening
    private let alerts: RepositoryForgeLinkAlertPresenting
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeLinks")

    init(
        routing: RepositoryForgeLinkRouting,
        opener: RepositoryForgeLinkURLOpening,
        alerts: RepositoryForgeLinkAlertPresenting
    ) {
        self.routing = routing
        self.opener = opener
        self.alerts = alerts
    }

    convenience init(coordinator: RepositoryForgeCoordinator, windowController: PBGitWindowController) {
        let presenter = AppKitRepositoryForgeLinkAlertPresenter(
            windowProvider: { [weak windowController] in windowController?.window },
            errorPresentation: { [weak windowController] error in
                windowController?.showErrorSheet(error)
            }
        )
        self.init(
            routing: RepositoryForgeLinkCoordinatorRouting(coordinator: coordinator),
            opener: WorkspaceRepositoryForgeLinkOpener(),
            alerts: presenter
        )
    }

    func openRepository() {
        open(.repository, event: "repository")
    }

    func openCheckedOutRevision(_ revision: RepositoryForgeLinkRevision?) {
        switch revision {
        case let .branch(name):
            open(.branch(name), event: "checked-out-branch")
        case let .commit(identifier):
            open(.commit(identifier), event: "checked-out-commit")
        case nil:
            return
        }
    }

    func openSelectedCommit(_ identifiers: [String]) {
        guard identifiers.count == 1, let identifier = identifiers.first else { return }
        open(.commit(identifier), event: "selected-commit")
    }

    func openSelectedComparison(_ identifiers: [String]) {
        guard identifiers.count == 2 else { return }
        open(
            .compare(base: .commit(identifiers[1]), head: .commit(identifiers[0])),
            event: "selected-compare"
        )
    }

    func requestNumberReference() {
        alerts.requestNumberReference { [weak self] reference in
            guard let self, let reference else { return }
            self.openNumberReference(reference)
        }
    }

    private func open(_ request: RepositoryForgeDestinationRequest, event: String) {
        let providerName = routing.providerName ?? "unresolved"
        logger.info(
            "Requested Forge destination kind=\(event, privacy: .public) provider=\(providerName, privacy: .public)"
        )
        switch routing.resolve(request) {
        case let .route(route):
            opener.open(route.browserURL)
            logger.info("Opened Forge destination kind=\(event, privacy: .public)")
        case let .requiresBindingChoice(candidates):
            alerts.chooseBinding(from: candidates) { [weak self] candidate in
                guard let self, let candidate else { return }
                do {
                    try self.routing.select(candidate: candidate)
                    self.open(request, event: event)
                } catch {
                    self.alerts.show(error: error)
                }
            }
        case let .failure(error):
            alerts.show(error: error)
        }
    }

    private func openNumberReference(_ reference: String) {
        switch routing.resolveNumberReference(reference) {
        case let .route(route):
            opener.open(route.browserURL)
            logger.info("Opened numbered Forge destination without chooser")
        case let .requiresBindingChoice(candidates):
            alerts.chooseBinding(from: candidates) { [weak self] candidate in
                guard let self, let candidate else { return }
                do {
                    try self.routing.select(candidate: candidate)
                    self.openNumberReference(reference)
                } catch {
                    self.alerts.show(error: error)
                }
            }
        case let .requiresDestinationChoice(choices):
            alerts.chooseDestination(from: choices) { [weak self] choice in
                guard let self, let choice else { return }
                do {
                    let route = try self.routing.route(choice.destination)
                    self.opener.open(route.browserURL)
                    self.logger.info("Opened numbered Forge destination after chooser")
                } catch {
                    self.alerts.show(error: error)
                }
            }
        case let .failure(error):
            alerts.show(error: error)
        }
    }
}
