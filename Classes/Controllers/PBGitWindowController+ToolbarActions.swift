import AppKit
import ForgeKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

extension PBGitWindowController {
    private static let forgeLinkLogger = Logger(subsystem: "com.gitx.gitx", category: "ForgeLinks")

    @IBAction dynamic func toolbarFetch(_ sender: Any?) {
        fetchAllRemotes(sender)
    }

    @IBAction dynamic func toolbarPull(_ sender: Any?) {
        guard let head = repository?.headRef()?.ref(), head.isBranch else { return }
        performPull(forBranch: head, remote: nil, rebase: false)
    }

    @IBAction dynamic func toolbarPush(_ sender: Any?) {
        guard let head = repository?.headRef()?.ref(), head.isBranch else { return }
        performPush(forBranch: head, toRemote: nil)
    }

    @IBAction dynamic func viewRemote(_ sender: Any?) {
        guard let repository else { return }
        RepositoryRemoteURLCoordinator.shared.viewRemote(repository: repository, presenting: window)
    }

    @IBAction dynamic func viewForgeRepository(_ sender: Any?) {
        openForge(.repository, event: "repository")
    }

    @IBAction dynamic func viewForgeCheckedOutRevision(_ sender: Any?) {
        switch forgeLinkContext.checkedOutRevision {
        case let .branch(name):
            openForge(.branch(name), event: "checked-out-branch")
        case let .commit(identifier):
            openForge(.commit(identifier), event: "checked-out-commit")
        case nil:
            return
        }
    }

    @IBAction dynamic func viewForgeSelectedCommit(_ sender: Any?) {
        guard forgeLinkContext.selectedCommitIdentifiers.count == 1,
              let identifier = forgeLinkContext.selectedCommitIdentifiers.first
        else { return }
        openForge(.commit(identifier), event: "selected-commit")
    }

    @IBAction dynamic func viewForgeSelectedComparison(_ sender: Any?) {
        let identifiers = forgeLinkContext.selectedCommitIdentifiers
        guard identifiers.count == 2 else { return }
        openForge(
            .compare(base: .commit(identifiers[1]), head: .commit(identifiers[0])),
            event: "selected-compare"
        )
    }

    @IBAction dynamic func showForgePullRequestOrIssue(_ sender: Any?) {
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
        presentForgeAlert(alert) { [weak self, weak field] response in
            guard response == .alertFirstButtonReturn, let reference = field?.stringValue else { return }
            self?.openForgeNumberReference(reference)
        }
    }

    private func openForge(
        _ request: RepositoryForgeDestinationRequest,
        event: String
    ) {
        guard let coordinator = forgeCoordinator else { return }
        let providerName = forgeLinkContext.providerName ?? "unresolved"
        Self.forgeLinkLogger.info(
            "Requested Forge destination kind=\(event, privacy: .public) provider=\(providerName, privacy: .public)"
        )
        switch coordinator.resolve(request) {
        case let .route(route):
            NSWorkspace.shared.open(route.browserURL)
            Self.forgeLinkLogger.info("Opened Forge destination kind=\(event, privacy: .public)")
        case let .requiresBindingChoice(candidates):
            chooseForgeBinding(from: candidates) { [weak self] in
                self?.openForge(request, event: event)
            }
        case let .failure(error):
            showErrorSheet(error)
        }
    }

    private func openForgeNumberReference(_ reference: String) {
        guard let coordinator = forgeCoordinator else { return }
        switch coordinator.resolveNumberReference(reference) {
        case let .route(route):
            NSWorkspace.shared.open(route.browserURL)
            Self.forgeLinkLogger.info("Opened numbered Forge destination without chooser")
        case let .requiresBindingChoice(candidates):
            chooseForgeBinding(from: candidates) { [weak self] in
                self?.openForgeNumberReference(reference)
            }
        case let .requiresDestinationChoice(choices):
            chooseForgeDestination(from: choices)
        case let .failure(error):
            showErrorSheet(error)
        }
    }

    private func chooseForgeBinding(
        from candidates: [RepositoryForgeBindingCandidate],
        completion: @escaping () -> Void
    ) {
        guard !candidates.isEmpty, let coordinator = forgeCoordinator else { return }
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
        Self.forgeLinkLogger.info(
            "Presenting Forge Repository Binding choices count=\(candidates.count, privacy: .public)"
        )
        presentForgeAlert(alert) { [weak self, weak popup] response in
            guard response == .alertFirstButtonReturn,
                  let index = popup?.indexOfSelectedItem,
                  candidates.indices.contains(index)
            else { return }
            do {
                _ = try coordinator.select(candidate: candidates[index])
                completion()
            } catch {
                self?.showErrorSheet(error)
            }
        }
    }

    private func chooseForgeDestination(from choices: [ForgeDestinationChoice]) {
        guard !choices.isEmpty else { return }
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
        presentForgeAlert(alert) { [weak self, weak popup] response in
            guard response == .alertFirstButtonReturn,
                  let index = popup?.indexOfSelectedItem,
                  choices.indices.contains(index)
            else { return }
            do {
                let route = try ForgeDestinationRouter().route(choices[index].destination)
                NSWorkspace.shared.open(route.browserURL)
                Self.forgeLinkLogger.info("Opened numbered Forge destination after chooser")
            } catch {
                self?.showErrorSheet(error)
            }
        }
    }

    private func presentForgeAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
