import AppKit
import Carbon.HIToolbox
import ForgeKit
import OSLog // swiftlint:disable:this unused_import

@MainActor
final class ForgeDeepLinkApplicationRouter: NSObject {
    static let shared = ForgeDeepLinkApplicationRouter()

    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeDeepLink")
    private var installed = false

    func installIfNeeded() {
        guard !installed else { return }
        installed = true
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        logger.notice("Registered exact x-gitx read-only deep-link handler")
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent _: NSAppleEventDescriptor) {
        guard let rawURL = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: rawURL)
        else {
            presentError(ForgeDeepLinkError.invalidURL)
            return
        }
        route(url)
    }

    func route(_ url: URL) {
        let windows = repositoryWindows()
        // Parsing identifies the repository, while the router intentionally
        // resolves ambiguity between multiple open checkouts of that identity.
        // Do not let duplicate windows turn an otherwise exact repository path
        // into a parser-level ambiguity.
        let identities = Array(Set(windows.compactMap { $0.identity }))
        let destination: ForgeDestination
        do {
            destination = try parse(url, knownRepositories: identities)
        } catch {
            presentError(error)
            logger.error("Rejected malformed or unsupported x-gitx deep link")
            return
        }
        let checkouts = windows.compactMap { window -> ForgeOpenCheckout? in
            guard let identity = window.identity else { return nil }
            return try? ForgeOpenCheckout(
                identifier: window.identifier,
                repository: identity,
                frontmostRank: window.frontmostRank,
                availableCommits: availableCommits(for: destination, in: window.controller)
            )
        }
        handle(
            ForgeDeepLinkRouter.route(destination, openCheckouts: checkouts),
            windows: windows
        )
    }

    func parse(
        _ url: URL,
        knownRepositories: [ForgeRepositoryIdentity]
    ) throws -> ForgeDestination {
        do {
            return try ForgeDeepLinkCodec.parse(url, knownRepositories: knownRepositories)
        } catch ForgeDeepLinkError.unknownRepository {
            // GitHub.com repository ownership has exactly one owner path
            // component. Inferring that identity makes the explicit
            // No-Matching-Checkout browser choice reachable without treating a
            // recent repository as open or ever auto-cloning it.
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.host?.lowercased() == "github.com",
                  components.port == nil
            else {
                throw ForgeDeepLinkError.unknownRepository
            }
            let path = components.percentEncodedPath
                .split(separator: "/")
                .compactMap { String($0).removingPercentEncoding }
            guard path.count >= 3 else { throw ForgeDeepLinkError.unknownRepository }
            let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
            let inferred = try ForgeRepositoryIdentity(forge: forge, owner: path[0], name: path[1])
            return try ForgeDeepLinkCodec.parse(url, knownRepositories: [inferred])
        }
    }

    private func handle(_ route: ForgeDeepLinkRouteDecision, windows: [RepositoryWindow]) {
        switch route {
        case let .open(identifier, destination):
            guard let window = windows.first(where: { $0.identifier == identifier }) else {
                presentError(RepositoryPullRequestServiceError.deepLinkUnavailable)
                return
            }
            open(destination, in: window.controller)
        case let .chooseCheckout(identifiers, destination):
            chooseCheckout(identifiers: identifiers, destination: destination, windows: windows)
        case let .missingLocalObject(identifier, destination, actions):
            guard let window = windows.first(where: { $0.identifier == identifier }) else {
                presentError(RepositoryPullRequestServiceError.deepLinkUnavailable)
                return
            }
            presentMissingObject(destination, actions: actions, in: window.controller)
        case let .noMatchingCheckout(destination):
            presentNoCheckout(destination)
        }
    }

    private func open(_ destination: ForgeDestination, in controller: PBGitWindowController) {
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        switch destination {
        case .repository:
            break
        case .pullRequest, .issue:
            guard controller.sidebarViewController?.openForgeDestination(destination) == true else {
                openInBrowser(destination)
                return
            }
        case let .branch(_, branch):
            guard controller.openForgeRevision(branch.value) else {
                presentMissingObject(destination, actions: ForgeDeepLinkMissingObjectAction.allCases, in: controller)
                return
            }
        case let .commit(_, commit):
            guard controller.openForgeRevision(commit.value) else {
                presentMissingObject(destination, actions: ForgeDeepLinkMissingObjectAction.allCases, in: controller)
                return
            }
        case let .file(_, revision, _, _):
            guard controller.openForgeRevision(revision.value) else {
                presentMissingObject(destination, actions: ForgeDeepLinkMissingObjectAction.allCases, in: controller)
                return
            }
        case let .compare(_, base, head):
            guard controller.openForgeComparison(base: base.value, head: head.value) else {
                presentMissingObject(destination, actions: ForgeDeepLinkMissingObjectAction.allCases, in: controller)
                return
            }
        }
        logger.notice("Opened validated x-gitx destination kind=\(destination.kind.rawValue, privacy: .public)")
    }

    private func chooseCheckout(
        identifiers: [String],
        destination: ForgeDestination,
        windows: [RepositoryWindow]
    ) {
        let candidates = identifiers.compactMap { identifier in windows.first { $0.identifier == identifier } }
        guard !candidates.isEmpty else {
            presentNoCheckout(destination)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Choose an Open Checkout"
        alert.informativeText = "More than one open checkout matches this GitX deep link."
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for candidate in candidates {
            popup.addItem(withTitle: candidate.controller.window?.title ?? candidate.identifier)
            popup.lastItem?.representedObject = candidate.identifier
        }
        popup.setAccessibilityIdentifier("GitX.DeepLink.CheckoutChooser")
        popup.setAccessibilityLabel("Open checkout for GitX deep link")
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let parent = NSApp.keyWindow ?? candidates.first?.controller.window
        present(alert, parent: parent) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let identifier = popup.selectedItem?.representedObject as? String,
                  let selected = candidates.first(where: { $0.identifier == identifier })
            else { return }
            self?.open(destination, in: selected.controller)
        }
    }

    private func presentMissingObject(
        _ destination: ForgeDestination,
        actions: [ForgeDeepLinkMissingObjectAction],
        in controller: PBGitWindowController
    ) {
        let alert = NSAlert()
        alert.messageText = "Git Object Is Not Available Locally"
        alert.informativeText = "GitX will not fetch automatically. Fetch explicitly or open the validated destination in your browser."
        if actions.contains(.fetch) {
            alert.addButton(withTitle: "Fetch")
        }
        if actions.contains(.openInBrowser) {
            alert.addButton(withTitle: "Open in Browser")
        }
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.setAccessibilityIdentifier("GitX.DeepLink.Fetch")
        present(alert, parent: controller.window) { [weak self, weak controller] response in
            guard let self, let controller else { return }
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0, index < actions.count else { return }
            switch actions[index] {
            case .fetch:
                controller.fetchAllRemotes(self)
            case .openInBrowser:
                self.openInBrowser(destination)
            }
        }
    }

    private func presentNoCheckout(_ destination: ForgeDestination) {
        let alert = NSAlert()
        alert.messageText = "No Matching Checkout Is Open"
        alert.informativeText = "Open a checkout for \(destination.repository.owner)/\(destination.repository.name), or continue in the browser. GitX will not clone it automatically."
        alert.addButton(withTitle: "Open in Browser")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.setAccessibilityIdentifier("GitX.DeepLink.OpenInBrowser")
        present(alert, parent: NSApp.keyWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.openInBrowser(destination)
        }
    }

    private func openInBrowser(_ destination: ForgeDestination) {
        guard let url = try? ForgeDestinationURLCodec.url(for: destination) else { return }
        NSWorkspace.shared.open(url)
        logger.info("Opened validated deep-link browser fallback")
    }

    private func repositoryWindows() -> [RepositoryWindow] {
        let ordered = NSApp.orderedWindows
        return NSDocumentController.shared.documents.flatMap { document in
            document.windowControllers.compactMap { $0 as? PBGitWindowController }
        }.enumerated().compactMap { fallbackRank, controller in
            guard let repository = controller.repository else { return nil }
            let resolution = RepositoryForgeCoordinator(repository: repository).resolveBinding()
            let rank = controller.window.flatMap { ordered.firstIndex(of: $0) } ?? ordered.count + fallbackRank
            return RepositoryWindow(
                identifier: String(ObjectIdentifier(controller).hashValue),
                controller: controller,
                identity: resolution.binding?.primaryRepository,
                frontmostRank: rank
            )
        }
    }

    private func availableCommits(
        for destination: ForgeDestination,
        in controller: PBGitWindowController
    ) -> Set<ForgeCommitID> {
        let required: [ForgeCommitID] = switch destination {
        case let .commit(_, commit): [commit]
        case let .file(_, .commit(commit), _, _): [commit]
        case let .compare(_, base, head): [base, head].compactMap { revision in
                guard case let .commit(commit) = revision else { return nil }
                return commit
            }
        default: []
        }
        guard let repository = controller.repository else { return [] }
        return Set(required.filter { commit in
            (try? repository.outputOfTask(withArguments: [
                "cat-file", "-e", "\(commit.value)^{commit}",
            ])) != nil
        })
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        present(alert, parent: NSApp.keyWindow, completion: nil)
    }

    private func present(
        _ alert: NSAlert,
        parent: NSWindow?,
        completion: ((NSApplication.ModalResponse) -> Void)?
    ) {
        if let parent {
            alert.beginSheetModal(for: parent) { completion?($0) }
        } else {
            completion?(alert.runModal())
        }
    }

    private struct RepositoryWindow {
        let identifier: String
        let controller: PBGitWindowController
        let identity: ForgeRepositoryIdentity?
        let frontmostRank: Int
    }
}
